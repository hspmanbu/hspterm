//! Real transfer jobs: one tree per FIFO slot, explicit session binding and
//! device-local encrypted checkpoints. No SSH reconnection or cloud payloads.
use crate::api::with_vault;
use anyhow::{Context, Result, bail};
use hspterm_ssh_core::{
    ManagedSession, SessionPhase,
    bandwidth::BandwidthLimiter,
    task_scheduler::TaskScheduler,
    tree_transfer::{
        ConflictDecision, Direction, NodeKind, NodeState, TreeOutcome, TreeStats, TreeTransfer,
    },
};
use hspterm_storage_sync::{
    local_tasks::LocalTaskJournal,
    transfer_settings::{DefaultConflict, TransferSettings},
};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    path::PathBuf,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

mod checkpoints;
pub(crate) mod explorer;
pub(crate) mod export_cleanup;
pub(crate) mod reconnect;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Target {
    pub host_id: String,
    pub address: String,
    pub port: u16,
    pub username: String,
    pub fingerprint: String,
}
#[derive(Clone)]
pub(crate) struct Connection {
    pub terminal_id: u32,
    pub session: Arc<ManagedSession>,
    pub generation: u64,
    pub target: Target,
    pub closing: Arc<AtomicBool>,
}
#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Debug)]
pub(crate) enum State {
    Waiting,
    Scanning,
    Running,
    Paused,
    Failed,
    Partial,
    Complete,
    CompleteWithSkips,
    ExportReady,
    Cancelled,
}
impl State {
    pub(crate) fn ended(self) -> bool {
        matches!(
            self,
            Self::Complete | Self::CompleteWithSkips | Self::Cancelled
        )
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    version: u32,
    id: String,
    target: Target,
    local: PathBuf,
    remote: String,
    upload: bool,
    state: State,
    error: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    rescan: Vec<u32>,
    #[serde(default)]
    rename_conflicts: bool,
    #[serde(default)]
    default_conflict: DefaultConflict,
    #[serde(default)]
    export_name: Option<String>,
}
#[derive(Clone)]
pub struct TransferActiveFile {
    pub path: String,
    pub acknowledged: u64,
    pub total: u64,
}
#[derive(Clone)]
pub struct TransferTaskView {
    pub id: String,
    pub terminal_id: Option<u32>,
    pub terminal_generation: Option<u64>,
    pub source_terminal_id: Option<u32>,
    pub source_terminal_generation: Option<u64>,
    pub source_deletions_confirmed: Option<u32>,
    pub source_deletions_total: Option<u32>,
    pub source_host_id: Option<String>,
    pub source_remote: Option<String>,
    pub remote_operation: Option<String>,
    pub remote_transport: Option<String>,
    pub remote_move_phase: Option<String>,
    pub host_id: String,
    pub name: String,
    pub local: String,
    pub remote: String,
    pub upload: bool,
    pub folder: bool,
    pub state: String,
    pub busy: bool,
    pub discovered: u32,
    pub files: u32,
    pub directories: u32,
    pub completed: u32,
    pub failed: u32,
    pub conflicts: u32,
    pub skipped: u32,
    pub acknowledged: u64,
    pub total: Option<u64>,
    pub current: Option<String>,
    pub active_files: Option<Vec<TransferActiveFile>>,
    pub error: Option<String>,
}
pub struct TransferFailure {
    pub node: u32,
    pub path: String,
    pub error: String,
    pub conflict: bool,
    pub rescan: bool,
}
struct Runtime {
    header: Header,
    terminal_id: Option<u32>,
    terminal_generation: Option<u64>,
    busy: bool,
    requested: Option<State>,
    stop: CancellationToken,
    folder: bool,
    discovered: u32,
    stats: Option<TreeStats>,
    current: Option<String>,
    active_files: Vec<TransferActiveFile>,
    run_version: u64,
    reconnect_candidate: bool,
}
struct Job {
    data: Mutex<Runtime>,
    finished: watch::Sender<u64>,
    channels: crate::transfer_channels::Channels,
    export_slot: Mutex<Option<hspterm_storage_sync::export_cache::ExportSlot>>,
    export_readers: std::sync::atomic::AtomicUsize,
    export_scan_only: AtomicBool,
    export_lease: Mutex<Option<explorer::Lease>>,
}
struct Registry {
    loaded: bool,
    jobs: Vec<Arc<Job>>,
    scheduler: TaskScheduler,
    upload: BandwidthLimiter,
    download: BandwidthLimiter,
    settings: TransferSettings,
}
static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
fn registry() -> &'static Mutex<Registry> {
    REGISTRY.get_or_init(|| {
        Mutex::new(Registry {
            loaded: false,
            jobs: Vec::new(),
            scheduler: TaskScheduler::default(),
            upload: BandwidthLimiter::default(),
            download: BandwidthLimiter::default(),
            settings: TransferSettings::default(),
        })
    })
}
pub(crate) fn preview_admission() -> Result<(
    hspterm_ssh_core::task_scheduler::Admission,
    BandwidthLimiter,
)> {
    content_admission(false)
}
pub(crate) fn content_admission(
    upload: bool,
) -> Result<(
    hspterm_ssh_core::task_scheduler::Admission,
    BandwidthLimiter,
)> {
    let mut state = registry().lock();
    // Ephemeral previews need the limits, not restored task manifests. A bad or
    // newer device-local checkpoint must not block unrelated file viewing.
    if !state.loaded {
        let settings = with_vault(|v| Ok(TransferSettings::load(v)?))?;
        apply_settings(&mut state, settings);
    }
    Ok((
        state.scheduler.enqueue(),
        if upload {
            state.upload.clone()
        } else {
            state.download.clone()
        },
    ))
}
fn view(job: &Job) -> TransferTaskView {
    let data = job.data.lock();
    let h = &data.header;
    let stats = data.stats.unwrap_or_default();
    TransferTaskView {
        id: h.id.clone(),
        terminal_id: data.terminal_id,
        terminal_generation: data.terminal_generation,
        source_terminal_id: None,
        source_terminal_generation: None,
        source_deletions_confirmed: None,
        source_deletions_total: None,
        source_host_id: None,
        source_remote: None,
        remote_operation: None,
        remote_transport: h.export_name.as_ref().map(|_| "explorer_snapshot".into()),
        remote_move_phase: None,
        host_id: h.target.host_id.clone(),
        name: if let Some(name) = &h.export_name {
            name.clone()
        } else if h.upload {
            h.local
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "文件夹".into())
        } else {
            h.remote
                .rsplit('/')
                .find(|n| !n.is_empty())
                .unwrap_or("文件夹")
                .into()
        },
        local: h.local.to_string_lossy().into_owned(),
        remote: h.remote.clone(),
        upload: h.upload,
        folder: data.folder,
        state: if data.requested.is_some() {
            "Stopping".into()
        } else {
            format!("{:?}", h.state)
        },
        busy: data.busy,
        discovered: data.discovered,
        files: stats.files as u32,
        directories: stats.directories as u32,
        completed: stats.complete as u32,
        failed: stats.failed as u32,
        conflicts: stats.conflicts as u32,
        skipped: stats.skipped as u32,
        acknowledged: stats.acknowledged,
        total: data
            .stats
            .filter(|s| {
                s.total_known
                    && h.state != State::Scanning
                    && h.rescan.is_empty()
                    && !h.rename_conflicts
            })
            .map(|s| s.total),
        current: data.current.clone(),
        active_files: Some(data.active_files.clone()),
        error: h.error.clone(),
    }
}

/// Global lock order: local transfer gate -> remote registry -> job -> vault.
/// Remote tasks share the actual scheduler and limiters, rather than creating
/// an independent pool that could exceed the configured global concurrency.
pub(crate) fn with_relay_resources<T>(
    action: impl FnOnce(
        &TaskScheduler,
        &BandwidthLimiter,
        &BandwidthLimiter,
        DefaultConflict,
    ) -> Result<T>,
) -> Result<T> {
    let mut state = registry().lock();
    if !state.loaded {
        let settings = with_vault(|v| Ok(TransferSettings::load(v)?))?;
        apply_settings(&mut state, settings);
    }
    action(
        &state.scheduler,
        &state.upload,
        &state.download,
        state.settings.default_conflict,
    )
}
fn save(header: &Header, plan: Option<&TreeTransfer>) -> Result<()> {
    let encoded = checkpoints::Encoded::encode(header, plan, None)?;
    with_vault(|v| encoded.replace(v, &header.id))
}
fn save_dirty(
    header: &Header,
    plan: &TreeTransfer,
    dirty: &std::collections::BTreeSet<usize>,
) -> Result<()> {
    let encoded = checkpoints::Encoded::encode(header, Some(plan), Some(dirty))?;
    with_vault(|v| encoded.patch(v, &header.id))
}
fn load(id: &str) -> Result<(Header, Option<TreeTransfer>)> {
    let checkpoint = with_vault(|v| {
        LocalTaskJournal::new(v)
            .load_parts(id)?
            .context("任务检查点已不存在")
    })?;
    let (header, plan) = checkpoints::decode(checkpoint)?;
    if header.version != 1
        || header.id != id
        || !header.local.is_absolute()
        || !header.remote.starts_with('/')
    {
        bail!("任务检查点格式或版本无效");
    }
    if let Some(plan) = &plan {
        plan.validate()?;
        if plan.local != header.local
            || plan.remote != header.remote
            || (plan.direction == Direction::Upload) != header.upload
        {
            bail!("任务清单与目标不一致");
        }
    }
    if let Some(name) = &header.export_name {
        hspterm_ssh_core::explorer_manifest::validate_root_name(name)?;
        if header.state == State::ExportReady && plan.is_none() {
            bail!("就绪导出缺少原始完整清单");
        }
        if header.upload || !header.rescan.is_empty() || header.rename_conflicts {
            bail!("Explorer源任务不能上传或改变已冻结清单");
        }
        if let Some(plan) = &plan
            && header.state == State::ExportReady
        {
            explorer::validate_inventory(name, plan)?;
            if plan
                .nodes
                .iter()
                .any(|node| node.state != NodeState::Complete)
            {
                bail!("就绪导出清单含未确认项目");
            }
        }
    } else if header.state == State::ExportReady {
        bail!("普通传输检查点不能包含Explorer就绪状态");
    }
    if header.rename_conflicts
        && !plan.as_ref().is_some_and(|p| {
            p.nodes
                .iter()
                .any(|n| n.kind == NodeKind::File && n.state == NodeState::Conflict)
        })
    {
        bail!("批次更名检查点缺少原始冲突文件");
    }
    let mut rescans = HashSet::new();
    for &index in &header.rescan {
        if !rescans.insert(index) {
            bail!("重扫检查点包含重复节点");
        }
        let node = plan
            .as_ref()
            .and_then(|p| p.nodes.get(index as usize))
            .context("重扫检查点缺少原始失败节点")?;
        if node.kind == NodeKind::File || node.state != NodeState::Failed {
            bail!("重扫检查点不再对应失败目录");
        }
    }
    Ok((header, plan))
}
fn remove(id: &str) -> Result<()> {
    with_vault(|v| {
        LocalTaskJournal::new(v).remove(&[id.into()])?;
        Ok(())
    })
}
fn new_job(header: Header, terminal_id: Option<u32>, plan: Option<&TreeTransfer>) -> Arc<Job> {
    let (finished, _) = watch::channel(0);
    Arc::new(Job {
        export_slot: Default::default(),
        export_readers: Default::default(),
        export_scan_only: AtomicBool::new(false),
        export_lease: Default::default(),
        channels: Default::default(),
        data: Mutex::new(Runtime {
            header,
            terminal_id,
            terminal_generation: None,
            busy: false,
            requested: None,
            stop: CancellationToken::new(),
            folder: plan.is_some_and(|p| p.nodes[0].kind == NodeKind::Directory),
            discovered: plan.map_or(0, |p| p.nodes.len() as u32),
            stats: plan.map(TreeTransfer::stats),
            current: None,
            active_files: Vec::new(),
            run_version: 0,
            reconnect_candidate: false,
        }),
        finished,
    })
}
#[derive(Clone)]
pub struct TransferPreferences {
    pub concurrency: u32,
    pub upload_bytes_per_second: u64,
    pub download_bytes_per_second: u64,
    /// None on save preserves the current setting for older UI callers.
    pub default_conflict: Option<String>,
    /// None preserves the setting for callers predating this preference.
    pub resume_on_reconnect: Option<bool>,
}
impl From<TransferSettings> for TransferPreferences {
    fn from(s: TransferSettings) -> Self {
        Self {
            concurrency: s.concurrency,
            upload_bytes_per_second: s.upload_bytes_per_second,
            download_bytes_per_second: s.download_bytes_per_second,
            default_conflict: Some(s.default_conflict.as_str().into()),
            resume_on_reconnect: Some(s.resume_on_reconnect),
        }
    }
}
fn apply_settings(state: &mut Registry, settings: TransferSettings) {
    if state.settings == settings {
        return;
    }
    state.upload.set_rate(settings.upload_bytes_per_second);
    state.download.set_rate(settings.download_bytes_per_second);
    state
        .scheduler
        .set_limit(settings.concurrency as usize)
        .expect("validated concurrency");
    state.settings = settings;
}
/// Publish restored global limits without retiring active tasks. Registry is
/// acquired before Vault, matching admission/checkpoint lock order.
pub(crate) fn restore_configuration<T>(
    action: impl FnOnce() -> Result<(T, TransferSettings)>,
) -> Result<T> {
    let mut state = registry().lock();
    let (result, settings) = action()?;
    apply_settings(&mut state, settings);
    Ok(result)
}
pub(crate) fn preferences() -> Result<TransferPreferences> {
    let mut state = registry().lock();
    restore(&mut state)?;
    Ok(state.settings.into())
}
pub(crate) fn save_preferences(value: TransferPreferences) -> Result<()> {
    let mut settings = TransferSettings {
        version: 1,
        resume_on_reconnect: value.resume_on_reconnect.unwrap_or(false),
        concurrency: value.concurrency,
        upload_bytes_per_second: value.upload_bytes_per_second,
        download_bytes_per_second: value.download_bytes_per_second,
        default_conflict: value
            .default_conflict
            .as_deref()
            .map(DefaultConflict::parse)
            .transpose()?
            .unwrap_or_default(),
    };
    settings
        .validate()
        .context("并发数须为1–32，带宽须为0–1TiB/s；0表示不限速")?;
    let mut state = registry().lock();
    restore(&mut state)?;
    if value.default_conflict.is_none() {
        settings.default_conflict = state.settings.default_conflict;
    }
    if value.resume_on_reconnect.is_none() {
        settings.resume_on_reconnect = state.settings.resume_on_reconnect;
    }
    with_vault(|v| Ok(settings.save(v)?))?;
    // Only publish live changes after encrypted persistence succeeds.
    apply_settings(&mut state, settings);
    Ok(())
}
fn restore(registry: &mut Registry) -> Result<()> {
    if registry.loaded {
        return Ok(());
    }
    let settings = with_vault(|v| Ok(TransferSettings::load(v)?))?;
    let ids = with_vault(|v| Ok(LocalTaskJournal::new(v).list()?))?;
    let mut jobs = Vec::new();
    for id in ids {
        let (mut header, plan) = load(&id)?;
        if header.state.ended() {
            if header.export_name.is_some() {
                explorer::retire_cache(&header.local)?;
            }
            remove(&id)?;
            continue;
        }
        if matches!(
            header.state,
            State::Waiting | State::Scanning | State::Running
        ) {
            header.state = State::Paused;
        }
        jobs.push(new_job(header, None, plan.as_ref()));
    }
    apply_settings(registry, settings);
    registry.jobs = jobs;
    registry.loaded = true;
    Ok(())
}
pub(crate) fn switch_vault<T>(action: impl FnOnce() -> Result<T>) -> Result<T> {
    let mut state = registry().lock();
    if state
        .jobs
        .iter()
        .any(|j| j.export_readers.load(Ordering::Acquire) != 0)
    {
        bail!("请先完成或结束Explorer交付，再切换配置库");
    }
    if state.jobs.iter().any(|j| {
        j.data.lock().busy
            || !j.channels.is_empty()
            || j.export_readers.load(Ordering::Acquire) != 0
    }) {
        bail!("请先暂停活动传输并完成子通道本机收尾，再切换配置库");
    }
    let result = crate::remote_transfers::switch_vault(action)?;
    state.jobs.clear();
    state.loaded = false;
    Ok(result)
}
pub(crate) fn list() -> Result<Vec<TransferTaskView>> {
    let mut state = registry().lock();
    restore(&mut state)?;
    Ok(state.jobs.iter().map(|j| view(j)).collect())
}
fn job_by_id(state: &Registry, id: &str) -> Result<Arc<Job>> {
    state
        .jobs
        .iter()
        .find(|j| j.data.lock().header.id == id)
        .cloned()
        .context("传输任务已不存在")
}
pub(crate) fn check_connection(connection: &Connection) -> Result<()> {
    if connection.closing.load(Ordering::Acquire) {
        bail!("关联终端正在关闭或断开");
    }
    let status = connection.session.status();
    if status.phase != SessionPhase::Connected || status.generation != connection.generation {
        bail!("关联SSH会话已改变或断开");
    }
    Ok(())
}
pub(crate) fn enqueue(
    connection: Connection,
    local: String,
    remote: String,
    upload: bool,
) -> Result<String> {
    let local = PathBuf::from(local);
    if !local.is_absolute() || !remote.starts_with('/') || remote.contains('\0') {
        bail!("传输需要绝对本地与远端路径");
    }
    check_connection(&connection)?;
    let mut state = registry().lock();
    restore(&mut state)?;
    check_connection(&connection)?;
    let header = Header {
        version: 1,
        id: format!("task-{:032x}", rand::random::<u128>()),
        target: connection.target.clone(),
        local,
        remote,
        upload,
        state: State::Waiting,
        error: None,
        rescan: Vec::new(),
        rename_conflicts: false,
        default_conflict: state.settings.default_conflict,
        export_name: None,
    };
    save(&header, None)?;
    let id = header.id.clone();
    let job = new_job(header, Some(connection.terminal_id), None);
    state.jobs.push(job.clone());
    launch(&state, job, connection);
    Ok(id)
}
fn launch(registry: &Registry, job: Arc<Job>, connection: Connection) {
    let limiter = if job.data.lock().header.upload {
        registry.upload.clone()
    } else {
        registry.download.clone()
    };
    let stop = {
        let mut data = job.data.lock();
        data.busy = true;
        data.reconnect_candidate = false;
        data.run_version += 1;
        data.requested = None;
        data.stop = CancellationToken::new();
        data.header.state = State::Waiting;
        data.header.error = None;
        data.terminal_id = Some(connection.terminal_id);
        data.terminal_generation = Some(connection.generation);
        data.stop.clone()
    };
    let admission = registry.scheduler.enqueue();
    tokio::spawn(async move {
        let result = match admission.enter(&stop).await {
            Ok(permit) => {
                let worker_job = job.clone();
                let handle = tokio::runtime::Handle::current();
                tokio::task::spawn_blocking(move || {
                    let _permit = permit;
                    let result = handle.block_on(worker_job.channels.supervise(run(
                        worker_job.clone(),
                        connection,
                        limiter,
                    )));
                    if let Err(error) = &result {
                        persist_failure(&worker_job, error)
                            .context("传输异常状态保存未确认，请保留本次运行和原检查点")?;
                    }
                    result
                })
                .await
                .map_err(|_| anyhow::anyhow!("传输工作线程异常，保留上次检查点"))
                .and_then(|r| r)
            }
            Err(_) => {
                let worker_job = job.clone();
                tokio::task::spawn_blocking(move || {
                    if !worker_job.channels.is_empty() {
                        bail!("传输子通道仍在收尾，未确认取消；请保留原任务或先断开关联SSH");
                    }
                    let (mut h, plan) = load(&worker_job.data.lock().header.id)?;
                    h.state = worker_job.data.lock().requested.unwrap_or(State::Paused);
                    if h.state == State::Cancelled
                        && h.export_name.is_none()
                        && worker_job.channels.is_empty()
                    {
                        remove(&h.id)?;
                    } else {
                        save(&h, plan.as_ref())?;
                    }
                    worker_job.data.lock().header = h;
                    Ok(())
                })
                .await
                .map_err(|_| anyhow::anyhow!("保存传输状态的工作线程异常"))
                .and_then(|r| r)
            }
        };
        let mut data = job.data.lock();
        if let Err(error) = result {
            data.header.state = State::Failed;
            data.header.error = Some(crate::public_errors::summary(&error));
        }
        data.busy = false;
        data.requested = None;
        data.current = None;
        data.active_files.clear();
        job.finished.send_replace(data.run_version);
    });
}
fn persist_failure(job: &Job, error: &anyhow::Error) -> Result<()> {
    let id = job.data.lock().header.id.clone();
    let (mut header, plan) = load(&id)?;
    header.state = State::Failed;
    header.error = Some(crate::public_errors::summary(error));
    save(&header, plan.as_ref())?;
    job.data.lock().header = header;
    Ok(())
}
fn update(job: &Job, plan: &TreeTransfer, current: Option<usize>) {
    update_stats(job, plan, current, plan.stats(), &[]);
}
fn update_stats(
    job: &Job,
    plan: &TreeTransfer,
    current: Option<usize>,
    stats: TreeStats,
    active: &[usize],
) {
    let mut data = job.data.lock();
    data.folder = plan.nodes[0].kind == NodeKind::Directory;
    data.discovered = plan.nodes.len() as u32;
    data.stats = Some(stats);
    data.active_files = active
        .iter()
        .take(8)
        .filter_map(|index| {
            let n = plan.nodes.get(*index)?;
            (n.kind == NodeKind::File && n.state == NodeState::Pending).then(|| {
                TransferActiveFile {
                    path: n.relative.clone(),
                    acknowledged: n.acknowledged,
                    total: n.size,
                }
            })
        })
        .collect();
    data.current = current
        .filter(|i| plan.nodes[*i].kind == NodeKind::File)
        .map(|i| plan.nodes[i].relative.clone());
}
async fn run(job: Arc<Job>, connection: Connection, limiter: BandwidthLimiter) -> Result<()> {
    let id = job.data.lock().header.id.clone();
    let (mut header, mut plan) = load(&id)?;
    if header.export_name.is_some() {
        explorer::ensure_slot(&job, &header.local)?;
    }
    let stop = job.data.lock().stop.clone();
    let result: Result<TreeOutcome> = async {
        check_connection(&connection)?;
        let mut sftp = tokio::select! { biased;
            _ = stop.cancelled() => return Ok(TreeOutcome::Paused),
            result = job.channels.open(&connection.session, connection.generation, &stop) => result?,
        };
        let work: Result<TreeOutcome> = async {
            check_connection(&connection)?;
            if plan.is_none() {
                header.state = State::Scanning;
                job.data.lock().header = header.clone();
                save(&header, None)?;
                let mut last = Instant::now();
                let scanned = TreeTransfer::scan_with_entry_limit(
                    if header.upload {
                        Direction::Upload
                    } else {
                        Direction::Download
                    },
                    header.local.clone(),
                    header.remote.clone(),
                    &sftp,
                    &stop,
                    if header.export_name.is_some() { hspterm_ssh_core::explorer_manifest::MAX_ENTRIES } else { hspterm_ssh_core::tree_transfer::MAX_ENTRIES },
                    |count| {
                        if last.elapsed() >= Duration::from_millis(100) {
                            job.data.lock().discovered = count as u32;
                            last = Instant::now();
                        }
                    },
                )
                .await;
                match scanned {
                    Ok(p) => plan = Some(p),
                    Err(hspterm_ssh_core::tree_transfer::TreeError::Cancelled) => {
                        return Ok(TreeOutcome::Paused);
                    }
                    Err(error) => return Err(error.into()),
                }
            }
            if let Some(name) = &header.export_name {
                let p = plan.as_ref().context("Explorer源清单缺失")?;
                explorer::validate_inventory(name, p)?;
                if job.export_scan_only.load(Ordering::Acquire) {
                    return Ok(TreeOutcome::Paused);
                }
            }
            if !header.rescan.is_empty() {
                header.state = State::Scanning;
                job.data.lock().header = header.clone();
                let indices: Vec<_> = header.rescan.iter().map(|i| *i as usize).collect();
                let p = plan.as_ref().context("重扫需要原始清单")?;
                let mut last = Instant::now();
                let candidate = p
                    .rescan_failed(&indices, &sftp, &stop, |count| {
                        if last.elapsed() >= Duration::from_millis(100) {
                            job.data.lock().discovered = count as u32;
                            last = Instant::now();
                        }
                    })
                    .await;
                let candidate = match candidate {
                    Ok(p) => p,
                    Err(hspterm_ssh_core::tree_transfer::TreeError::Cancelled) => {
                        return Ok(TreeOutcome::Paused);
                    }
                    Err(error) => return Err(error.into()),
                };
                // Publish candidate and clear intent in one durable transaction.
                // Failure/cancellation before this point retains the old plan.
                let mut ready = header.clone();
                ready.rescan.clear();
                save(&ready, Some(&candidate))?;
                header = ready;
                plan = Some(candidate);
            }
            if header.rename_conflicts {
                header.state = State::Scanning;
                job.data.lock().header = header.clone();
                // Metadata preflight runs off the registry/PTY actor. Persist
                // selected names before creating even the first new target.
                let p = plan.as_ref().context("更名需要原始冲突清单")?;
                let candidate = match p.rename_conflicts(&sftp, &stop).await {
                    Ok(p) => p,
                    Err(hspterm_ssh_core::tree_transfer::TreeError::Cancelled) => {
                        return Ok(TreeOutcome::Paused);
                    }
                    Err(error) => return Err(error.into()),
                };
                let mut ready = header.clone();
                ready.rename_conflicts = false;
                ready.local = candidate.local.clone();
                ready.remote = candidate.remote.clone();
                save(&ready, Some(&candidate))?;
                header = ready;
                plan = Some(candidate);
            }
            header.state = State::Running;
            job.data.lock().header = header.clone();
            let p = plan.as_mut().context("传输清单缺失")?;
            update(&job, p, None);
            // A full acknowledged manifest must be durable before any write.
            save(&header, Some(p))?;
            let mut last_ui = Instant::now();
            let mut last_save = Instant::now();
            let mut storage_error = None;
            let mut dirty = std::collections::BTreeSet::new();
            let mut channel_retries = 0u8;
            let outcome = loop {
                let result = p
                    .run_parallel_observed(
                        &sftp,
                        &stop,
                        3,
                        |p, progress, active| {
                            dirty.insert(progress.index / checkpoints::NODES_PER_PART);
                            if last_ui.elapsed() >= Duration::from_millis(100) {
                                update_stats(&job, p, progress.current, progress.stats, active);
                                last_ui = Instant::now();
                            }
                            if storage_error.is_none()
                                && last_save.elapsed() >= Duration::from_millis(250)
                            {
                                if let Err(error) = save_dirty(&header, p, &dirty) {
                                    storage_error = Some(error);
                                    stop.cancel();
                                } else {
                                    dirty.clear();
                                }
                                last_save = Instant::now();
                            }
                        },
                        &limiter,
                    )
                    .await;
                if let Some(error) = storage_error.take() {
                    return Err(error.context("检查点保存失败，已停止后续写入"));
                }
                let outcome = match result {
                    Err(hspterm_ssh_core::tree_transfer::TreeError::TransientChannel(indices))
                        if channel_retries < 2 && !stop.is_cancelled() => {
                        check_connection(&connection)?;
                        // Retire actual old local IO before another channel may
                        // write these paths. No SSH reconnect or file truncation.
                        sftp.close().await.context("原SFTP通道本机收尾未确认，未继续写入")?;
                        check_connection(&connection)?;
                        for index in indices {
                            let node = p.nodes.get_mut(index).context("通道恢复节点已不存在")?;
                            if node.kind == NodeKind::Unsupported || node.state != NodeState::Failed {
                                bail!("通道恢复节点状态已改变；未继续写入");
                            }
                            node.state = NodeState::Pending;
                            node.error = None;
                        }
                        save(&header, Some(p))?;
                        dirty.clear();
                        update(&job, p, None);
                        channel_retries += 1;
                        sftp = job.channels.open(&connection.session, connection.generation, &stop).await?;
                        check_connection(&connection)?;
                        continue;
                    }
                    other => other?,
                };
                if outcome == TreeOutcome::Paused || header.default_conflict == DefaultConflict::Ask
                {
                    break outcome;
                }
                let indices: Vec<_> = p
                    .nodes
                    .iter()
                    .enumerate()
                    .filter(|(_, n)| {
                        n.kind == NodeKind::File
                            && n.state == NodeState::Conflict
                            && n.default_policy_pending
                    })
                    .map(|(i, _)| i)
                    .collect();
                if indices.is_empty() {
                    break outcome;
                }
                if stop.is_cancelled() {
                    break TreeOutcome::Paused;
                }
                let mut candidate = if header.default_conflict == DefaultConflict::Rename {
                    match p.rename_selected_conflicts(&indices, &sftp, &stop).await {
                        Ok(p) => p,
                        Err(hspterm_ssh_core::tree_transfer::TreeError::Cancelled) => {
                            break TreeOutcome::Paused;
                        }
                        Err(error) => return Err(error.into()),
                    }
                } else {
                    p.clone()
                };
                if header.default_conflict != DefaultConflict::Rename {
                    for index in indices {
                        candidate.retry(
                            index,
                            match header.default_conflict {
                                DefaultConflict::Overwrite => ConflictDecision::Overwrite,
                                DefaultConflict::Skip => ConflictDecision::Skip,
                                _ => unreachable!("non-rename, non-ask default"),
                            },
                        )?;
                    }
                }
                let mut ready = header.clone();
                ready.local = candidate.local.clone();
                ready.remote = candidate.remote.clone();
                // The enqueue-time policy and chosen per-file decisions become
                // durable before a second pass can replace any file contents.
                save(&ready, Some(&candidate))?;
                dirty.clear();
                header = ready;
                *p = candidate;
                job.data.lock().header = header.clone();
                update(&job, p, None);
            };
            // Final ACK/state deltas must be durable before releasing IO or
            // deleting a completed task's inventory. A failed journal removal
            // must not make a successful file appear pending on explicit retry.
            if !dirty.is_empty() { save_dirty(&header, p, &dirty)?; }
            Ok(outcome)
        }
        .await;
        let closed = sftp.close().await;
        if let Ok(outcome) = work {
            if !stop.is_cancelled() {
                closed.context("释放传输子通道失败")?;
            }
            Ok(outcome)
        } else {
            work
        }
    }
    .await;
    if let Some(p) = &plan {
        update(&job, p, None);
    }
    header.state = match result {
        Ok(TreeOutcome::Complete) if header.export_name.is_some() => State::ExportReady,
        Ok(TreeOutcome::Complete) => State::Complete,
        Ok(TreeOutcome::CompleteWithSkips) => State::CompleteWithSkips,
        Ok(TreeOutcome::Partial) => State::Partial,
        Ok(TreeOutcome::Paused) => State::Paused,
        Err(error) => {
            header.error = Some(crate::public_errors::summary(&error));
            State::Failed
        }
    };
    {
        let mut data = job.data.lock();
        if let Some(requested) = data.requested {
            header.state = requested;
        } else if !header.state.ended() && check_connection(&connection).is_err() {
            data.reconnect_candidate = true;
        }
    }
    if header.state.ended() && header.export_name.is_none() && job.channels.is_empty() {
        remove(&id)?;
    } else {
        save(&header, plan.as_ref())?;
    }
    job.data.lock().header = header;
    Ok(())
}
pub(crate) async fn stop(id: String, cancel: bool) -> Result<()> {
    stop_inner(id, cancel, false).await
}
async fn stop_inner(id: String, cancel: bool, reconnect: bool) -> Result<()> {
    let job = {
        let state = registry().lock();
        job_by_id(&state, &id)?
    };
    let mut finished = job.finished.subscribe();
    let active = {
        let mut data = job.data.lock();
        if cancel && let Some(lease) = job.export_lease.lock().as_ref() {
            lease.stop.cancel();
        }
        if reconnect {
            data.reconnect_candidate |= data.busy && data.requested.is_none();
        } else {
            data.reconnect_candidate = false;
        }
        if data.header.state.ended() && !data.busy {
            if !job.channels.is_empty() {
                bail!("传输子通道仍在收尾，未确认取消；请保留原任务或先断开关联SSH");
            }
            return Ok(());
        }
        if data.busy {
            data.requested = Some(if cancel || data.requested == Some(State::Cancelled) {
                State::Cancelled
            } else {
                State::Paused
            });
            data.stop.cancel();
            Some(data.run_version)
        } else {
            None
        }
    };
    if let Some(version) = active {
        while *finished.borrow_and_update() < version {
            finished.changed().await.context("传输完成状态不可用")?;
        }
    } else if cancel {
        if !job.channels.is_empty() {
            bail!("传输子通道仍在收尾，未确认取消；请保留原任务或先断开关联SSH");
        }
        let job = job.clone();
        tokio::task::spawn_blocking(move || {
            let _registry = registry().lock();
            let mut data = job.data.lock();
            if data.busy {
                bail!("任务状态已改变，请重试取消");
            }
            if !job.channels.is_empty() {
                bail!("传输子通道仍在收尾，未确认取消；请保留原任务或先断开关联SSH");
            }
            if data.header.export_name.is_some() {
                let (_, plan) = load(&data.header.id)?;
                let mut header = data.header.clone();
                header.state = State::Cancelled;
                save(&header, plan.as_ref())?;
            } else {
                remove(&data.header.id)?;
            }
            data.header.state = State::Cancelled;
            Ok::<_, anyhow::Error>(())
        })
        .await??;
    }
    Ok(())
}
pub(crate) async fn stop_terminal(terminal_id: u32) -> Result<()> {
    let ids: Vec<_> = registry()
        .lock()
        .jobs
        .iter()
        .filter_map(|j| {
            let d = j.data.lock();
            (d.terminal_id == Some(terminal_id) && d.busy).then(|| d.header.id.clone())
        })
        .collect();
    let mut first_error = None;
    for id in ids {
        if let Err(error) = stop_inner(id, false, true).await {
            first_error.get_or_insert(error);
        }
    }
    let remote = crate::remote_transfers::stop_terminal(terminal_id).await;
    match (first_error, remote) {
        (Some(error), Err(remote)) => Err(error.context(format!("远端复制暂停也失败：{remote}"))),
        (Some(error), _) => Err(error),
        (None, result) => result,
    }
}
pub(crate) fn resume(
    connection: Connection,
    id: String,
    node: Option<u32>,
    decision: String,
    rename: Option<String>,
) -> Result<()> {
    if !matches!(
        decision.as_str(),
        "continue"
            | "retry"
            | "rescan"
            | "overwrite"
            | "skip"
            | "overwrite_conflicts"
            | "skip_conflicts"
            | "rename_conflicts"
    ) {
        bail!("未知冲突处理动作");
    }
    if rename.is_some() && (node.is_none() || decision != "retry") {
        bail!("更名必须明确选择单个文件并使用重试动作");
    }
    if decision == "continue" && (node.is_some() || rename.is_some()) {
        bail!("继续任务不能混用单项处理参数");
    }
    check_connection(&connection)?;
    let mut state = registry().lock();
    restore(&mut state)?;
    check_connection(&connection)?;
    let job = job_by_id(&state, &id)?;
    {
        let data = job.data.lock();
        if data.busy || data.header.state.ended() {
            bail!("任务仍在运行或已经结束");
        }
        if data.header.target != connection.target {
            bail!("实际服务器、用户或主机指纹与原任务不同，拒绝续传");
        }
    }
    let (mut header, mut plan) = load(&id)?;
    if header.export_name.is_some() {
        explorer::check_resume_lease(&job, &connection)?;
        if rename.is_some() || !matches!(decision.as_str(), "continue" | "retry") {
            bail!("Explorer冻结清单只允许继续或重试原文件；请重新拖出以改变清单");
        }
        if header.state == State::ExportReady {
            bail!("源快照已就绪，请从任务条目拖到Explorer继续交付");
        }
        explorer::ensure_slot(&job, &header.local)?;
        job.export_scan_only.store(false, Ordering::Release);
    }
    if decision != "continue" {
        let conflicts_only = matches!(
            decision.as_str(),
            "overwrite_conflicts" | "skip_conflicts" | "rename_conflicts"
        );
        if conflicts_only && (node.is_some() || rename.is_some()) {
            bail!("批次同名冲突操作不能混用单文件或更名参数");
        }
        let p = plan.as_mut().context("扫描未完成，请先继续扫描")?;
        let indices: Vec<usize> = if let Some(node) = node {
            vec![node as usize]
        } else {
            p.nodes
                .iter()
                .enumerate()
                .filter(|(_, n)| {
                    (n.kind == NodeKind::File || matches!(decision.as_str(), "retry" | "rescan"))
                        && (decision != "rescan" || n.kind != NodeKind::File)
                        && if conflicts_only {
                            n.state == NodeState::Conflict
                        } else {
                            matches!(n.state, NodeState::Failed | NodeState::Conflict)
                        }
                })
                .map(|(i, _)| i)
                .collect()
        };
        if indices.is_empty() {
            if conflicts_only {
                bail!("本任务当前没有待处理的同名冲突");
            }
            bail!("没有可重试的失败项目");
        }
        if conflicts_only {
            header.rename_conflicts = decision == "rename_conflicts";
        }
        let mut rescans: HashSet<_> = header.rescan.iter().copied().collect();
        for index in indices {
            if decision == "rename_conflicts" {
                continue;
            }
            let entry = p.nodes.get(index).context("失败项目已不存在")?;
            if entry.kind != NodeKind::File
                && rename.is_none()
                && matches!(decision.as_str(), "retry" | "rescan")
                && entry.state == NodeState::Failed
            {
                if header.export_name.is_some() {
                    bail!("Explorer冻结清单不能重扫目录；请重新发起拖出");
                }
                if rescans.insert(index as u32) {
                    header.rescan.push(index as u32);
                }
                continue;
            }
            if decision == "rescan" {
                bail!("重扫仅适用于失败目录或未完成发现的项目");
            }
            if let Some(name) = &rename {
                p.rename_destination(index, name)?;
                if p.nodes[index].relative.is_empty() {
                    // A single-file root's destination changed. Persist and
                    // display the actual target, while retaining source identity.
                    if header.upload {
                        let parent = p.remote.rsplit_once('/').context("目标路径无效")?.0;
                        p.remote = format!("{parent}/{name}");
                        header.remote = p.remote.clone();
                    } else {
                        p.local = p.local.parent().context("目标路径无效")?.join(name);
                        header.local = p.local.clone();
                    }
                    p.nodes[index].destination_name = None;
                }
            } else {
                p.retry(
                    index,
                    match decision.as_str() {
                        "retry" => ConflictDecision::Ask,
                        "overwrite" | "overwrite_conflicts" => ConflictDecision::Overwrite,
                        "skip" | "skip_conflicts" => ConflictDecision::Skip,
                        _ => bail!("未知冲突处理动作"),
                    },
                )?;
            }
        }
    }
    if !plan.as_ref().is_some_and(|p| {
        p.nodes
            .iter()
            .any(|n| n.kind == NodeKind::File && n.state == NodeState::Conflict)
    }) {
        header.rename_conflicts = false;
    }
    header.state = State::Waiting;
    header.error = None;
    save(&header, plan.as_ref())?;
    job.data.lock().header = header;
    // Refresh the accepted checkpoint's counters before FIFO admission, so
    // the UI cannot keep offering the conflict that was already resolved.
    if let Some(plan) = &plan {
        update(&job, plan, None);
    }
    launch(&state, job, connection);
    Ok(())
}
pub(crate) fn failures(id: String, offset: u32, limit: u32) -> Result<Vec<TransferFailure>> {
    if limit == 0 || limit > 1000 {
        bail!("无效的失败列表分页大小");
    }
    let (header, plan) = load(&id)?;
    let _ = header;
    Ok(plan
        .into_iter()
        .flat_map(|p| p.nodes.into_iter().enumerate())
        .filter(|(_, n)| matches!(n.state, NodeState::Failed | NodeState::Conflict))
        .skip(offset as usize)
        .take(limit as usize)
        .map(|(i, n)| TransferFailure {
            node: i as u32,
            path: n.relative,
            error: n.error.unwrap_or_else(|| "文件传输失败".into()),
            conflict: n.state == NodeState::Conflict,
            rescan: n.kind != NodeKind::File,
        })
        .collect())
}
pub(crate) fn clear_ended() {
    registry().lock().jobs.retain(|j| {
        let data = j.data.lock();
        data.busy
            || !data.header.state.ended()
            || !j.channels.is_empty()
            || j.export_readers.load(Ordering::Acquire) != 0
            || j.export_slot.lock().is_some()
    });
}
