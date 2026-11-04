//! Two authenticated endpoints, shared FIFO and device-only checkpoints. No
//! implicit Transport connection, remote credentials or direct-transfer claims.
use crate::{
    api::with_vault,
    transfers::{
        self, Connection, State, Target, TransferActiveFile, TransferFailure, TransferTaskView,
    },
};
use anyhow::{Context, Result, bail};
use hspterm_ssh_core::{
    SessionPhase,
    bandwidth::BandwidthLimiter,
    remote_tree::{RemoteTree, RemoteTreeError, StagingPhase},
    task_scheduler::Admission,
    tree_transfer::{ConflictDecision, NodeKind, NodeState, TreeOutcome, TreeStats},
};
use hspterm_storage_sync::{local_tasks::LocalTaskJournal, transfer_settings::DefaultConflict};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeSet,
    sync::{Arc, OnceLock},
    time::{Duration, Instant},
};
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

mod checkpoints;
pub(crate) mod direct;
mod move_resolution;
pub(crate) mod reconnect;
mod relocation;
pub(crate) mod source_resolution;
pub(crate) mod staging_cleanup;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
enum CopyOperation {
    #[default]
    Copy,
    Move,
    /// Fully acknowledged cross-account copy followed by explicit source retirement.
    Relocate,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
enum MovePhase {
    #[default]
    Pending,
    Intent,
    Confirmed,
    /// User ended local waiting without deciding whether rename succeeded.
    /// A retained device record is an audit, never permission to send again.
    UserEnded,
}

pub struct RemoteMoveInspection {
    pub ticket: String,
    pub account: String,
    pub source_path: String,
    pub destination_path: String,
    pub source_kind: String,
    pub destination_kind: String,
    pub source_size: Option<u64>,
    pub destination_size: Option<u64>,
}

/// Local original-task review only. It makes no statement about current files
/// and grants no network access, credential rebinding or transfer continuation.
pub struct RemoteMoveEndReview {
    pub ticket: String,
    pub account: String,
    pub fingerprint: String,
    pub source_path: String,
    pub destination_path: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CopyHeader {
    version: u32,
    id: String,
    source_target: Target,
    destination_target: Target,
    source: String,
    destination: String,
    state: State,
    error: Option<String>,
    default_conflict: DefaultConflict,
    #[serde(default = "legacy_relay_permitted")]
    relay_permitted: bool,
    #[serde(default)]
    direct_permitted: bool,
    rename_conflicts: bool,
    #[serde(default)]
    operation: CopyOperation,
    #[serde(default)]
    move_phase: MovePhase,
    #[serde(default)]
    move_directory: bool,
    #[serde(default)]
    rescan: Vec<u32>,
    #[serde(default)]
    cleanup: Option<hspterm_ssh_core::remote_tree::StagingCleanup>,
    #[serde(default)]
    cleanup_abandoned: bool,
    #[serde(default)]
    source_retirement: Option<hspterm_ssh_core::remote_tree::SourceRetirement>,
}
fn legacy_relay_permitted() -> bool {
    true
}
struct CopyRuntime {
    transport: Option<&'static str>,
    header: CopyHeader,
    source_terminal: Option<u32>,
    source_generation: Option<u64>,
    destination_terminal: Option<u32>,
    destination_generation: Option<u64>,
    busy: bool,
    requested: Option<State>,
    stop: CancellationToken,
    revision: u64,
    folder: bool,
    discovered: u32,
    stats: Option<TreeStats>,
    current: Option<String>,
    active_files: Vec<TransferActiveFile>,
    inspection: Option<move_resolution::InspectionTicket>,
    local_end: Option<move_resolution::LocalEndTicket>,
    source_end: Option<source_resolution::EndTicket>,
    cleanup_review: Option<Arc<staging_cleanup::Review>>,
    cleaning: bool,
    cleanup_inspection_epoch: u64,
    cleanup_only: bool,
    reconnect_candidate: bool,
    retiring_sources: bool,
}
struct CopyJob {
    data: Mutex<CopyRuntime>,
    finished: watch::Sender<u64>,
    channels: crate::transfer_channels::Channels,
    direct: Mutex<Option<hspterm_ssh_core::direct_transfer::DirectRoute>>,
}
impl CopyJob {
    fn io_empty(&self) -> bool {
        self.channels.is_empty() && self.direct.lock().as_ref().is_none_or(|r| r.is_idle())
    }
    async fn retire_direct(&self) -> Result<()> {
        let direct = self.direct.lock().clone();
        if let Some(route) = direct {
            tokio::time::timeout(Duration::from_secs(2), route.wait_idle())
                .await
                .context("直传子通道收尾未确认；保留原任务，请先断开原SSH再继续")?;
        }
        Ok(())
    }
    async fn supervise<T>(&self, work: impl std::future::Future<Output = Result<T>>) -> Result<T> {
        self.retire_direct().await?;
        let result = self.channels.supervise(work).await;
        self.retire_direct().await?;
        result
    }
}
#[derive(Default)]
struct CopyRegistry {
    loaded: bool,
    jobs: Vec<Arc<CopyJob>>,
}
fn registry() -> &'static Mutex<CopyRegistry> {
    static VALUE: OnceLock<Mutex<CopyRegistry>> = OnceLock::new();
    VALUE.get_or_init(Default::default)
}
fn save(
    header: &CopyHeader,
    plan: Option<&RemoteTree>,
    dirty: Option<&BTreeSet<usize>>,
) -> Result<()> {
    let encoded = checkpoints::CopyEncoded::encode(header, plan, dirty)?;
    with_vault(|v| {
        if dirty.is_some() {
            encoded.patch(v, &header.id)
        } else {
            encoded.replace(v, &header.id)
        }
    })
}
fn load(id: &str) -> Result<(CopyHeader, Option<RemoteTree>)> {
    let checkpoint = with_vault(|v| Ok(LocalTaskJournal::remote_copies(v).load_parts(id)?))?
        .context("远端复制检查点已不存在")?;
    checkpoints::decode(id, checkpoint)
}
fn remove(id: &str) -> Result<()> {
    with_vault(|v| {
        LocalTaskJournal::remote_copies(v).remove(&[id.into()])?;
        Ok(())
    })
}
fn new_job(
    header: CopyHeader,
    source: Option<u32>,
    destination: Option<u32>,
    plan: Option<&RemoteTree>,
) -> Arc<CopyJob> {
    let (finished, _) = watch::channel(0);
    let folder =
        plan.is_some_and(|p| p.nodes[0].kind == NodeKind::Directory) || header.move_directory;
    let stats = plan.map(RemoteTree::stats).or_else(|| {
        (header.operation == CopyOperation::Move && header.move_phase != MovePhase::Pending)
            .then(|| move_stats(&header))
    });
    Arc::new(CopyJob {
        channels: Default::default(),
        direct: Mutex::new(None),
        finished,
        data: Mutex::new(CopyRuntime {
            transport: None,
            header,
            source_terminal: source,
            source_generation: None,
            destination_terminal: destination,
            destination_generation: None,
            busy: false,
            requested: None,
            stop: CancellationToken::new(),
            revision: 0,
            folder,
            discovered: plan.map_or(0, |p| p.nodes.len() as u32),
            stats,
            current: None,
            active_files: Vec::new(),
            inspection: None,
            local_end: None,
            source_end: None,
            cleanup_review: None,
            cleaning: false,
            cleanup_inspection_epoch: 0,
            cleanup_only: false,
            reconnect_candidate: false,
            retiring_sources: false,
        }),
    })
}
fn restore(state: &mut CopyRegistry) -> Result<()> {
    if state.loaded {
        return Ok(());
    }
    let ids = with_vault(|v| Ok(LocalTaskJournal::remote_copies(v).list()?))?;
    let mut jobs = Vec::new();
    for id in ids {
        let (mut header, plan) = load(&id)?;
        if header
            .source_retirement
            .as_ref()
            .is_some_and(|s| s.uncertain_index().is_some() && !s.ended_unknown())
        {
            header.state = State::Failed;
            header.error = Some("上次来源删除结果未确认；不重发，请检查原来源和副本".into());
        } else if header.cleanup.as_ref().is_some_and(|c| {
            c.state == hspterm_ssh_core::remote_tree::StagingCleanupState::RemoveIntent
        }) {
            header.state = State::Failed;
            header.error = Some("上次暂存删除结果未确认；不会自动再次删除或继续复制".into());
        } else if header.operation == CopyOperation::Move && header.move_phase == MovePhase::Intent
        {
            header.state = State::Failed;
            header.error =
                Some("上次移动请求结果未确认；请检查源与目标，不能盲目重发rename".into());
        } else if header.state.ended() {
            if !retain_checkpoint(&header, plan.as_ref()) {
                remove(&id)?;
            }
            // Cleanup-only records are available through explicit inventory,
            // never resurrect completed/cancelled transfer rows after restart.
            if retain_checkpoint(&header, plan.as_ref()) {
                let archived = new_job(header, None, None, plan.as_ref());
                archived.data.lock().cleanup_only = true;
                jobs.push(archived);
            }
            continue;
        }
        if matches!(
            header.state,
            State::Waiting | State::Scanning | State::Running
        ) {
            header.state = State::Paused;
        }
        jobs.push(new_job(header, None, None, plan.as_ref()));
    }
    state.jobs = jobs;
    state.loaded = true;
    Ok(())
}
fn has_snapshots(plan: Option<&RemoteTree>) -> bool {
    plan.is_some_and(|p| {
        p.stages.iter().zip(&p.nodes).any(|(phase, node)| {
            !matches!(phase, StagingPhase::Absent | StagingPhase::Published)
                || (*phase == StagingPhase::Published && node.state != NodeState::Complete)
        })
    })
}
fn retain_checkpoint(header: &CopyHeader, plan: Option<&RemoteTree>) -> bool {
    header
        .cleanup
        .as_ref()
        .is_some_and(|c| c.state != hspterm_ssh_core::remote_tree::StagingCleanupState::Retired)
        || header
            .source_retirement
            .as_ref()
            .is_some_and(|s| !s.complete())
        || has_snapshots(plan)
        || (header.operation == CopyOperation::Move
            && matches!(header.move_phase, MovePhase::Intent | MovePhase::UserEnded))
}
fn apply_requested(header: &mut CopyHeader, requested: State) {
    if header.operation == CopyOperation::Relocate
        && header
            .source_retirement
            .as_ref()
            .is_some_and(|s| s.uncertain_index().is_some() && !s.ended_unknown())
    {
        header.state = State::Failed;
        header.error = Some("已停止等待，但来源删除结果未确认；目标副本保留，不能重发".into());
    } else if header.operation == CopyOperation::Move
        && header.move_phase == MovePhase::Intent
        && requested == State::Cancelled
    {
        header.state = State::Failed;
        header.error =
            Some("已停止等待，但rename可能已执行；保留唯一记录，请检查源与目标后处理".into());
    } else {
        header.state = requested;
    }
}
fn move_stats(header: &CopyHeader) -> TreeStats {
    TreeStats {
        files: usize::from(!header.move_directory),
        directories: usize::from(header.move_directory),
        complete: usize::from(header.move_phase == MovePhase::Confirmed),
        total_known: true,
        ..TreeStats::default()
    }
}
pub(crate) fn switch_vault<T>(action: impl FnOnce() -> Result<T>) -> Result<T> {
    let mut state = registry().lock();
    if state
        .jobs
        .iter()
        .any(|j| j.data.lock().busy || !j.io_empty())
    {
        bail!("请先暂停远端复制并完成子通道本机收尾，再切换配置库");
    }
    let result = action()?;
    state.jobs.clear();
    state.loaded = false;
    Ok(result)
}
fn view(job: &CopyJob) -> TransferTaskView {
    let d = job.data.lock();
    let h = &d.header;
    let s = d.stats.unwrap_or_default();
    TransferTaskView {
        id: h.id.clone(),
        terminal_id: d.destination_terminal,
        terminal_generation: d.destination_generation,
        source_terminal_id: d.source_terminal,
        source_terminal_generation: d.source_generation,
        source_deletions_confirmed: h.source_retirement.as_ref().map(|s| s.confirmed() as u32),
        source_deletions_total: h.source_retirement.as_ref().map(|s| s.total() as u32),
        source_host_id: Some(h.source_target.host_id.clone()),
        source_remote: Some(h.source.clone()),
        remote_transport: d.transport.map(|transport| {
            if transport == "direct" && job.direct.lock().as_ref().is_some_and(|r| r.used_relay()) {
                "mixed".to_owned()
            } else {
                transport.to_owned()
            }
        }),
        remote_move_phase: if h.operation == CopyOperation::Move {
            Some(format!("{:?}", h.move_phase))
        } else {
            h.source_retirement.as_ref().map(|s| {
                if s.ended_unknown() {
                    "UserEnded"
                } else if s.uncertain_index().is_some() {
                    "Intent"
                } else if s.complete() {
                    "Confirmed"
                } else {
                    "Retiring"
                }
                .into()
            })
        },
        remote_operation: Some(
            match h.operation {
                CopyOperation::Copy => "copy",
                CopyOperation::Move => "move",
                CopyOperation::Relocate => "relocate",
            }
            .into(),
        ),
        host_id: h.destination_target.host_id.clone(),
        name: h.source.rsplit('/').next().unwrap_or("远端文件").into(),
        local: String::new(),
        remote: h.destination.clone(),
        upload: true,
        folder: d.folder,
        state: if d.cleaning {
            "Cleaning".into()
        } else if d.requested.is_some() {
            "Stopping".into()
        } else if d.retiring_sources {
            "RetiringSource".into()
        } else {
            format!("{:?}", h.state)
        },
        busy: d.busy,
        discovered: d.discovered,
        files: s.files as u32,
        directories: s.directories as u32,
        completed: s.complete as u32,
        failed: s.failed as u32,
        conflicts: s.conflicts as u32,
        skipped: s.skipped as u32,
        acknowledged: s.acknowledged,
        total: d
            .stats
            .filter(|s| s.total_known && h.state != State::Scanning)
            .map(|s| s.total),
        current: d.current.clone(),
        active_files: Some(d.active_files.clone()),
        error: h.error.clone(),
    }
}
pub(crate) fn list() -> Result<Vec<TransferTaskView>> {
    transfers::with_relay_resources(|_, _, _, _| {
        let mut state = registry().lock();
        restore(&mut state)?;
        Ok(state
            .jobs
            .iter()
            .filter(|j| !j.data.lock().cleanup_only)
            .map(|j| view(j))
            .collect())
    })
}
fn job(state: &CopyRegistry, id: &str) -> Result<Arc<CopyJob>> {
    state
        .jobs
        .iter()
        .find(|j| j.data.lock().header.id == id)
        .cloned()
        .context("远端复制任务已不存在")
}
fn check_pair(source: &Connection, target: &Connection) -> Result<()> {
    transfers::check_connection(source)?;
    transfers::check_connection(target)?;
    Ok(())
}
pub(crate) fn enqueue(
    source: Connection,
    target: Connection,
    source_path: String,
    destination: String,
    allow_memory_relay: bool,
    expected_scope: String,
    allow_direct: bool,
) -> Result<String> {
    enqueue_operation(
        source,
        target,
        source_path,
        destination,
        allow_memory_relay,
        expected_scope,
        allow_direct,
        CopyOperation::Copy,
    )
}
pub(crate) async fn prepare_move_source(source: &Connection, path: String) -> Result<String> {
    relocation::prepare_source(source, path).await
}
pub(crate) fn enqueue_move(
    source: Connection,
    target: Connection,
    source_path: String,
    destination: String,
    allow_memory_relay: bool,
    expected_scope: String,
    allow_direct: bool,
) -> Result<String> {
    let origin = source.target.clone();
    let path = source_path.clone();
    let operation = if same_account(&source.target, &target.target) {
        CopyOperation::Move
    } else {
        CopyOperation::Relocate
    };
    crate::editors::with_move_source_guard(&origin, &path, move || {
        enqueue_operation(
            source,
            target,
            source_path,
            destination,
            allow_memory_relay,
            expected_scope,
            allow_direct,
            operation,
        )
    })
}
pub(crate) fn check_editor_path(
    target: &hspterm_storage_sync::local_edits::EditTarget,
    path: &str,
) -> Result<()> {
    let mut state = registry().lock();
    restore(&mut state)?;
    for job in &state.jobs {
        let d = job.data.lock();
        let h = &d.header;
        if ((h.operation == CopyOperation::Move && (d.busy || h.move_phase == MovePhase::Intent))
            || (h.operation == CopyOperation::Relocate
                && !h.state.ended()
                && !h
                    .source_retirement
                    .as_ref()
                    .is_some_and(|s| s.complete() || s.ended_unknown())))
            && h.source_target.fingerprint == target.fingerprint
            && (path == h.source
                || path
                    .strip_prefix(&h.source)
                    .is_some_and(|suffix| suffix.starts_with('/')))
        {
            bail!("该路径正在移动或移动结果尚未确认，暂不能打开或关联编辑文档");
        }
    }
    Ok(())
}
fn source_paths_overlap(a: &str, b: &str) -> bool {
    a == b
        || a == "/"
        || b == "/"
        || a.strip_prefix(b).is_some_and(|rest| rest.starts_with('/'))
        || b.strip_prefix(a).is_some_and(|rest| rest.starts_with('/'))
}
fn same_account(source: &Target, target: &Target) -> bool {
    source.address == target.address
        && source.port == target.port
        && source.username == target.username
        && source.fingerprint == target.fingerprint
}
fn check_move_resume(header: &CopyHeader, decision: &str) -> Result<()> {
    if let Some(source) = &header.source_retirement {
        if source.uncertain_index().is_some() || source.ended_unknown() {
            bail!("来源删除结果未知或已结束等待，不能重发；请检查原来源与副本");
        }
        if decision != "continue" {
            bail!("来源清理开始后只允许继续，不再重扫或修改已确认复制树");
        }
    }
    if header.cleanup_abandoned {
        bail!("旧暂存删除结果未判定，为避免复用旧路径，请明确创建新的复制任务");
    }
    if header
        .cleanup
        .as_ref()
        .is_some_and(|c| c.state != hspterm_ssh_core::remote_tree::StagingCleanupState::Retired)
    {
        bail!("暂存清理结果尚未确认，不能继续写入；请先处理清理记录");
    }
    if header.operation == CopyOperation::Move
        && (matches!(header.move_phase, MovePhase::Intent | MovePhase::UserEnded)
            || decision != "continue")
    {
        bail!("移动结果未知或已人工结束时不能重发，也不隐式覆盖同名对象；请检查原源与目标");
    }
    Ok(())
}
#[allow(
    clippy::too_many_arguments,
    reason = "Keep source, target, authorization and copy or move policy explicit at one admission boundary."
)]
fn enqueue_operation(
    source: Connection,
    target: Connection,
    source_path: String,
    destination: String,
    allow_memory_relay: bool,
    expected_scope: String,
    allow_direct: bool,
    operation: CopyOperation,
) -> Result<String> {
    if operation == CopyOperation::Move && !same_account(&source.target, &target.target) {
        bail!("直接更名仅支持实际地址、端口、用户及指纹均一致的同账户移动，未移动来源");
    }
    if !source_path.starts_with('/')
        || !destination.starts_with('/')
        || source_path.contains('\0')
        || destination.contains('\0')
        || source_path.len() > 131072
        || destination.len() > 131072
    {
        bail!("远端复制需要有效绝对路径");
    }
    check_pair(&source, &target)?;
    transfers::with_relay_resources(|scheduler, up, down, default_conflict| {
        with_vault(|v| {
            if v.instance_id() != expected_scope {
                bail!("直传准备期间原加密配置库已改变，未创建任务");
            }
            Ok(())
        })?;
        let mut state = registry().lock();
        restore(&mut state)?;
        check_pair(&source, &target)?;
        if operation != CopyOperation::Copy
            && state.jobs.iter().any(|j| {
                let d = j.data.lock();
                ((d.header.operation == CopyOperation::Move
                    && (d.busy || d.header.move_phase == MovePhase::Intent))
                    || (d.header.operation == CopyOperation::Relocate && !d.header.state.ended()))
                    && d.header.source_target.fingerprint == source.target.fingerprint
                    && source_paths_overlap(&d.header.source, &source_path)
            })
        {
            bail!("该来源或重叠目录已有排队、活动或结果未确认的移动任务，未重复入队");
        }
        let header = CopyHeader {
            version: 1,
            id: format!("task-{:032x}", rand::random::<u128>()),
            source_target: source.target.clone(),
            destination_target: target.target.clone(),
            source: source_path,
            destination,
            state: State::Waiting,
            error: None,
            default_conflict,
            relay_permitted: allow_memory_relay,
            direct_permitted: allow_direct,
            rename_conflicts: false,
            operation,
            move_phase: MovePhase::Pending,
            move_directory: false,
            rescan: Vec::new(),
            cleanup: None,
            cleanup_abandoned: false,
            source_retirement: None,
        };
        save(&header, None, None)?;
        let id = header.id.clone();
        let j = new_job(
            header,
            Some(source.terminal_id),
            Some(target.terminal_id),
            None,
        );
        state.jobs.push(j.clone());
        launch(
            j,
            source,
            target,
            scheduler.enqueue(),
            up.clone(),
            down.clone(),
        );
        Ok(id)
    })
}
fn launch(
    j: Arc<CopyJob>,
    source: Connection,
    target: Connection,
    admission: Admission,
    upload: BandwidthLimiter,
    download: BandwidthLimiter,
) {
    let stop = {
        let mut d = j.data.lock();
        d.busy = true;
        d.reconnect_candidate = false;
        d.revision += 1;
        d.inspection = None;
        d.local_end = None;
        d.source_end = None;
        d.retiring_sources = false;
        d.transport = None;
        d.requested = None;
        d.stop = CancellationToken::new();
        d.header.state = State::Waiting;
        d.header.error = None;
        d.source_terminal = Some(source.terminal_id);
        d.source_generation = Some(source.generation);
        d.destination_terminal = Some(target.terminal_id);
        d.destination_generation = Some(target.generation);
        d.stop.clone()
    };
    // Watch only status events; no polling and no reconnect. Both endpoints
    // cancel admission/active work as soon as their generation stops matching.
    let mut source_states = source.session.subscribe();
    let mut target_states = target.session.subscribe();
    let sg = source.generation;
    let tg = target.generation;
    let monitor_stop = stop.clone();
    let monitor = tokio::spawn(async move {
        loop {
            let a = source_states.borrow_and_update().clone();
            let b = target_states.borrow_and_update().clone();
            if a.phase != SessionPhase::Connected
                || a.generation != sg
                || b.phase != SessionPhase::Connected
                || b.generation != tg
            {
                monitor_stop.cancel();
                break;
            }
            tokio::select! { biased; _ = monitor_stop.cancelled() => break,
            r = source_states.changed() => { if r.is_err() { monitor_stop.cancel(); break; } },
            r = target_states.changed() => { if r.is_err() { monitor_stop.cancel(); break; } } }
        }
    });
    let source_check = source.clone();
    let target_check = target.clone();
    tokio::spawn(async move {
        let result = match admission.enter(&stop).await {
            Ok(permit) => {
                let worker = j.clone();
                let handle = tokio::runtime::Handle::current();
                tokio::task::spawn_blocking(move || {
                    let _permit = permit;
                    let result = handle.block_on(worker.supervise(run(
                        worker.clone(),
                        source,
                        target,
                        upload,
                        download,
                    )));
                    if let Err(error) = &result {
                        persist_failure(&worker, error)
                            .context("复制异常状态保存未确认，请保留本次运行和原检查点")?;
                    }
                    result
                })
                .await
                .map_err(|_| anyhow::anyhow!("远端复制工作线程异常，保留上次检查点"))
                .and_then(|r| r)
            }
            Err(_) => {
                let worker = j.clone();
                tokio::task::spawn_blocking(move || {
                    if !worker.io_empty() {
                        bail!("复制子通道仍在收尾，未确认取消；请保留原任务或先断开关联SSH");
                    }
                    let (mut h, plan) = load(&worker.data.lock().header.id)?;
                    h.state = worker.data.lock().requested.unwrap_or(State::Paused);
                    save(&h, plan.as_ref(), None)?;
                    worker.data.lock().header = h;
                    Ok::<_, anyhow::Error>(())
                })
                .await
                .map_err(|_| anyhow::anyhow!("远端复制状态保存线程异常"))
                .and_then(|r| r)
            }
        };
        monitor.abort();
        let _monitor_result = monitor.await;
        let mut d = j.data.lock();
        if let Err(error) = result {
            d.header.state = State::Failed;
            d.header.error = Some(crate::public_errors::summary(&error));
        }
        if d.requested.is_none()
            && !d.header.state.ended()
            && d.header.operation == CopyOperation::Copy
            && check_pair(&source_check, &target_check).is_err()
        {
            d.reconnect_candidate = true;
        }
        d.busy = false;
        d.retiring_sources = false;
        d.requested = None;
        d.current = None;
        d.active_files.clear();
        j.finished.send_replace(d.revision);
    });
}
fn update(j: &CopyJob, p: &RemoteTree, stats: TreeStats, current: Option<usize>) {
    update_active(j, p, stats, current, &[]);
}
fn persist_failure(job: &CopyJob, error: &anyhow::Error) -> Result<()> {
    let id = job.data.lock().header.id.clone();
    let (mut header, plan) = load(&id)?;
    header.state = State::Failed;
    header.error = Some(crate::public_errors::summary(error));
    save(&header, plan.as_ref(), None)?;
    job.data.lock().header = header;
    Ok(())
}
fn update_active(
    j: &CopyJob,
    p: &RemoteTree,
    stats: TreeStats,
    current: Option<usize>,
    active: &[usize],
) {
    let mut d = j.data.lock();
    d.folder = p.nodes[0].kind == NodeKind::Directory;
    d.discovered = p.nodes.len() as u32;
    d.stats = Some(stats);
    d.current = current.map(|i| p.nodes[i].relative.clone());
    d.active_files = active
        .iter()
        .take(8)
        .filter_map(|i| {
            let n = p.nodes.get(*i)?;
            (n.kind == NodeKind::File && n.state == NodeState::Pending).then(|| {
                TransferActiveFile {
                    path: n.relative.clone(),
                    acknowledged: n.acknowledged,
                    total: n.size,
                }
            })
        })
        .collect();
}
async fn run_move(
    j: &CopyJob,
    h: &mut CopyHeader,
    sftp: &hspterm_ssh_core::SftpSession,
    stop: &CancellationToken,
) -> Result<TreeOutcome> {
    use hspterm_ssh_core::transfer::{RemoteMoveError, move_remote_path, prepare_remote_move};
    if matches!(h.move_phase, MovePhase::Intent | MovePhase::UserEnded) {
        bail!("上次rename结果未确认或已人工结束，未重发；请检查原源与目标");
    }
    if h.move_phase == MovePhase::Confirmed {
        return Ok(TreeOutcome::Complete);
    }
    let prepared = prepare_remote_move(sftp, &h.source, &h.destination, stop).await?;
    let attrs = tokio::select! { biased;
        _ = stop.cancelled() => return Ok(TreeOutcome::Paused),
        r = sftp.symlink_metadata(&prepared.source) => r?,
    };
    h.source = prepared.source;
    h.destination = prepared.destination;
    h.move_directory = attrs.is_dir() && !attrs.is_symlink();
    h.state = State::Running;
    // A lost reply cannot be retried as if nothing happened. Persist the exact
    // object paths before sending the destructive request, even for tiny moves.
    let origin = h.source_target.clone();
    let path = h.source.clone();
    crate::editors::with_move_source_guard(&origin, &path, || {
        h.move_phase = MovePhase::Intent;
        if let Err(error) = save(h, None, None) {
            // No rename has been sent; a failed local barrier must not turn an
            // ordinary editor/DB failure into an ambiguous remote mutation.
            h.move_phase = MovePhase::Pending;
            return Err(error);
        }
        {
            let mut d = j.data.lock();
            d.header = h.clone();
            d.folder = h.move_directory;
            d.discovered = 1;
            d.stats = Some(move_stats(h));
        }
        Ok(())
    })?;
    let moved = move_remote_path(sftp, &h.source, &h.destination, stop).await;
    match moved {
        Ok(moved) => {
            h.source = moved.source;
            h.destination = moved.destination;
            h.move_phase = MovePhase::Confirmed;
            // Confirm the ACK before channel cleanup. A later resume must never
            // rename a newly created object at the former source pathname.
            save(h, None, None)?;
            let mut d = j.data.lock();
            d.header = h.clone();
            d.stats = Some(move_stats(h));
            Ok(TreeOutcome::Complete)
        }
        Err(
            error @ (RemoteMoveError::Conflict
            | RemoteMoveError::SelfMove
            | RemoteMoveError::InvalidPath),
        ) => {
            // These are local metadata checks in move_remote_path, before RENAME.
            h.move_phase = MovePhase::Pending;
            Err(error.into())
        }
        Err(error) => Err(error.into()),
    }
}
async fn run(
    j: Arc<CopyJob>,
    source: Connection,
    target: Connection,
    upload: BandwidthLimiter,
    download: BandwidthLimiter,
) -> Result<()> {
    let id = j.data.lock().header.id.clone();
    let (mut h, mut plan) = load(&id)?;
    let stop = j.data.lock().stop.clone();
    let result: Result<TreeOutcome> = async {
        check_pair(&source, &target)?;
        let mut a = tokio::select! { biased; _ = stop.cancelled() => return Ok(TreeOutcome::Paused), r = j.channels.open(&source.session, source.generation, &stop) => r? };
        let b = tokio::select! { biased; _ = stop.cancelled() => { a.close().await.context("释放源SFTP通道失败")?; return Ok(TreeOutcome::Paused); }, r = j.channels.open(&target.session, target.generation, &stop) => r };
        let mut b = match b { Ok(b) => b, Err(error) => { let closed = a.close().await; return Err(anyhow::anyhow!(error).context(if closed.is_err() { "建立目标通道失败；源通道关闭也未成功" } else { "建立目标通道失败" })); } };
        let work: Result<TreeOutcome> = async {
            check_pair(&source, &target)?;
            if h.operation == CopyOperation::Move {
                if !same_account(&source.target, &target.target) { bail!("原移动端点不再属于同一账户"); }
                return run_move(&j, &mut h, &a, &stop).await;
            }
            if h.operation == CopyOperation::Relocate && h.source_retirement.is_some() {
                let p = plan.as_ref().context("来源清理缺少原复制清单")?;
                return relocation::run(&j, &mut h, p, &source, &target, &a, &stop).await;
            }
            let route = direct::select(&source, &target, h.relay_permitted, h.direct_permitted, &stop).await?;
            *j.direct.lock() = route.clone();
            j.data.lock().transport = Some(if route.is_some() { "direct" } else { "relay" });
            if plan.is_none() {
                h.state = State::Scanning; j.data.lock().header = h.clone(); save(&h, None, None)?;
                // Hostname/port aliases must not evade self-copy protection. Equal
                // host keys may share a filesystem; conservatively reject equal
                // or nested roots even if the saved host IDs/addresses differ.
                let same_server = source.target.fingerprint == target.target.fingerprint;
                let mut last = Instant::now();
                let scanned = RemoteTree::scan(&a, &b, h.source.clone(), h.destination.clone(), same_server,
                    h.id[5..].into(), &stop, |count| { if last.elapsed() >= Duration::from_millis(100) {
                        j.data.lock().discovered = count as u32; last = Instant::now(); } }).await;
                match scanned { Ok(p) => plan = Some(p), Err(RemoteTreeError::Cancelled) => return Ok(TreeOutcome::Paused), Err(error) => return Err(error.into()) }
            }
            if !h.rescan.is_empty() {
                h.state = State::Scanning; j.data.lock().header = h.clone();
                let p = plan.as_ref().context("目录重扫缺少原清单")?;
                let indices: Vec<_> = h.rescan.iter().map(|i| *i as usize).collect();
                let mut last = Instant::now();
                let candidate = match p.rescan_failed(&indices, &a, &stop, |count| {
                    if last.elapsed() >= Duration::from_millis(100) {
                        j.data.lock().discovered = count as u32; last = Instant::now();
                    }
                }).await {
                    Ok(candidate) => candidate,
                    Err(RemoteTreeError::Cancelled) => return Ok(TreeOutcome::Paused),
                    Err(error) => return Err(error.into()),
                };
                candidate.validate_endpoints(source.target.fingerprint == target.target.fingerprint)?;
                let mut ready = h.clone(); ready.rescan.clear();
                // A structural barrier: publish all new chunks together with
                // clearing intent. Failure retains the original plan/intent.
                save(&ready, Some(&candidate), None)?;
                h = ready; plan = Some(candidate);
            }
            if h.rename_conflicts {
                let p = plan.as_ref().context("批量更名缺少原清单")?;
                let indices: Vec<_> = p.nodes.iter().enumerate().filter(|(_, n)|
                    n.kind == NodeKind::File && n.state == NodeState::Conflict).map(|(i, _)| i).collect();
                let candidate = match p.rename_conflicts(&indices, &b, &stop).await {
                    Ok(candidate) => candidate,
                    Err(RemoteTreeError::Cancelled) => return Ok(TreeOutcome::Paused),
                    Err(error) => return Err(error.into()),
                };
                let mut ready = h.clone(); ready.destination = candidate.destination.clone(); ready.rename_conflicts = false;
                save(&ready, Some(&candidate), None)?;
                h = ready; plan = Some(candidate);
            }
            let p = plan.as_mut().context("远端复制清单缺失")?;
            p.validate_endpoints(source.target.fingerprint == target.target.fingerprint)?;
            h.source = p.source.clone(); h.destination = p.destination.clone(); h.state = State::Running;
            if h.operation == CopyOperation::Relocate {
                let origin = h.source_target.clone(); let path = h.source.clone();
                crate::editors::with_move_source_guard(&origin, &path, || save(&h, Some(p), None))?;
            } else { save(&h, Some(p), None)?; }
            j.data.lock().header = h.clone();
            let mut channel_retries = 0;
            loop {
            let mut phases = p.stages.clone(); let mut states: Vec<_> = p.nodes.iter().map(|n| n.state).collect();
            let mut dirty = BTreeSet::new(); let mut last_save = Instant::now();
            let mut persistence_error = None;
            let outcome = p.run_parallel_with_direct(&a, &b, &stop, &upload, &download, 3, route.as_ref(), |p, progress, active| {
                update_active(&j, p, progress.stats, progress.current, active);
                let i = progress.index; dirty.insert(i / checkpoints::NODES_PER_PART);
                let barrier = phases[i] != p.stages[i] || states[i] != p.nodes[i].state;
                if barrier || last_save.elapsed() >= Duration::from_millis(250) {
                    match save(&h, Some(p), Some(&dirty)) {
                        Ok(()) => { dirty.clear(); phases[i] = p.stages[i]; states[i] = p.nodes[i].state; last_save = Instant::now(); }
                        Err(error) => { persistence_error = Some(error); return Err(RemoteTreeError::Checkpoint); }
                    }
                }
                Ok(())
            }).await;
            if let Some(error) = persistence_error { return Err(error.context("持久化失败，已停止远端复制")); }
                let outcome = match outcome {
                    Err(RemoteTreeError::TransientChannel { indices })
                        if channel_retries < 2 && !stop.is_cancelled() => {
                        check_pair(&source, &target)?;
                        // Drain BOTH original local IO owners even if one close
                        // fails. No new channel may overlap unknown retirement.
                        let closed_a = a.close().await;
                        let closed_b = b.close().await;
                        if closed_a.is_err() || closed_b.is_err() {
                            bail!("复制子通道未能完整释放，已停止自动恢复并保留原确认偏移");
                        }
                        check_pair(&source, &target)?;
                        for index in indices {
                            let node = p.nodes.get_mut(index).context("复制恢复节点已不存在")?;
                            if node.state != NodeState::Failed { bail!("复制恢复节点状态已变化"); }
                            node.state = NodeState::Pending;
                            node.error = None;
                        }
                        // Keep the exact phase, offsets and successful siblings.
                        // A full barrier precedes any replacement channel work.
                        save(&h, Some(p), None)?;
                        update(&j, p, p.stats(), None);
                        channel_retries += 1;
                        a = j.channels.open(&source.session, source.generation, &stop).await?;
                        check_pair(&source, &target)?;
                        b = j.channels.open(&target.session, target.generation, &stop).await?;
                        check_pair(&source, &target)?;
                        continue;
                    }
                    other => other?,
                };
                if outcome == TreeOutcome::Paused || h.default_conflict == DefaultConflict::Ask {
                    break Ok(outcome);
                }
                let indices: Vec<_> = p.nodes.iter().enumerate().filter(|(_, n)|
                    n.kind == NodeKind::File && n.state == NodeState::Conflict && n.default_policy_pending)
                    .map(|(i, _)| i).collect();
                if indices.is_empty() { break Ok(outcome); }
                if stop.is_cancelled() { break Ok(TreeOutcome::Paused); }
                let mut candidate = if h.default_conflict == DefaultConflict::Rename {
                    match p.rename_conflicts(&indices, &b, &stop).await {
                        Ok(candidate) => candidate,
                        Err(RemoteTreeError::Cancelled) => break Ok(TreeOutcome::Paused),
                        Err(error) => return Err(error.into()),
                    }
                } else { p.clone() };
                if h.default_conflict != DefaultConflict::Rename {
                    for index in indices { candidate.retry(index, if h.default_conflict == DefaultConflict::Overwrite {
                        ConflictDecision::Overwrite } else { ConflictDecision::Skip })?; }
                }
                h.destination = candidate.destination.clone();
                save(&h, Some(&candidate), None)?;
                *p = candidate;
                j.data.lock().header = h.clone();
            }
        }.await;
        let work = match work {
            Ok(TreeOutcome::Complete) if h.operation == CopyOperation::Relocate && h.source_retirement.is_none() => {
                let p = plan.as_ref().context("跨服务器移动缺少完整复制清单")?;
                relocation::run(&j, &mut h, p, &source, &target, &a, &stop).await
            }
            Ok(TreeOutcome::CompleteWithSkips) if h.operation == CopyOperation::Relocate => {
                h.error = Some("部分项目被跳过，来源未开始删除；请核对副本后明确处理".into());
                Ok(TreeOutcome::Partial)
            }
            other => other,
        };
        // Always close both dedicated channels, including after cancellation or
        // a lost OPEN response. Preserve both operation and cleanup failures.
        let ca = a.close().await; let cb = b.close().await;
        if ca.is_err() || cb.is_err() {
            return Err(work.err().unwrap_or_else(|| anyhow::anyhow!("复制子通道本机收尾未确认"))
                .context("释放复制子通道未确认；保留确认状态，未标记任务完成"));
        }
        work
    }.await;
    if let Some(p) = &plan {
        update(&j, p, p.stats(), None);
    }
    let mut preserve_journal = false;
    h.state = match result {
        Ok(TreeOutcome::Complete) => State::Complete,
        Ok(TreeOutcome::CompleteWithSkips) => State::CompleteWithSkips,
        Ok(TreeOutcome::Partial) => State::Partial,
        Ok(TreeOutcome::Paused) => State::Paused,
        Err(error) => {
            preserve_journal = error.is::<relocation::JournalUnknown>();
            h.error = Some(crate::public_errors::summary(&error));
            State::Failed
        }
    };
    if preserve_journal {
        let mut d = j.data.lock();
        // Keep the last acknowledged runtime ledger too, not the speculative
        // local cursor that failed persistence/readback.
        d.header.state = State::Failed;
        d.header.error = Some("来源删除日志未能重新读取；保留原记录，禁止以内存状态覆盖".into());
        return Err(relocation::JournalUnknown.into());
    }
    if let Some(requested) = j.data.lock().requested {
        apply_requested(&mut h, requested);
    }
    // Preserve unknown/partial staging references even for cancelled/skipped
    // jobs. Removing a UI row must never erase their only recovery inventory.
    if h.state.ended() && !retain_checkpoint(&h, plan.as_ref()) && j.io_empty() {
        remove(&id)?;
    } else {
        save(&h, plan.as_ref(), None)?;
    }
    j.data.lock().header = h;
    Ok(())
}
pub(crate) async fn inspect_move(
    source: Connection,
    target: Connection,
    id: String,
) -> Result<RemoteMoveInspection> {
    move_resolution::inspect(source, target, id).await
}
pub(crate) fn acknowledge_move(
    source: Connection,
    target: Connection,
    id: String,
    ticket: String,
) -> Result<()> {
    move_resolution::acknowledge(source, target, id, ticket)
}
pub(crate) fn prepare_move_end(id: String) -> Result<RemoteMoveEndReview> {
    move_resolution::prepare_local(id)
}
pub(crate) fn end_move_wait(id: String, ticket: String) -> Result<()> {
    move_resolution::end_local(id, ticket)
}
pub(crate) async fn stop(id: String, cancel: bool) -> Result<()> {
    stop_inner(id, cancel, false).await
}
async fn stop_inner(id: String, cancel: bool, reconnect: bool) -> Result<()> {
    let j = {
        let state = registry().lock();
        job(&state, &id)?
    };
    let mut done = j.finished.subscribe();
    let revision = {
        let mut d = j.data.lock();
        if reconnect {
            d.reconnect_candidate |= d.busy
                && d.requested.is_none()
                && !d.cleaning
                && d.header.operation == CopyOperation::Copy;
        } else {
            d.reconnect_candidate = false;
        }
        if d.header.state.ended() && !d.busy {
            if !j.io_empty() {
                bail!("复制子通道仍在收尾，未确认取消；请保留原任务或先断开关联SSH");
            }
            return Ok(());
        }
        if d.busy {
            d.requested = Some(if cancel || d.requested == Some(State::Cancelled) {
                State::Cancelled
            } else {
                State::Paused
            });
            d.stop.cancel();
            Some(d.revision)
        } else {
            None
        }
    };
    if let Some(revision) = revision {
        while *done.borrow_and_update() < revision {
            done.changed().await.context("远端复制完成状态不可用")?;
        }
    } else if cancel {
        if !j.io_empty() {
            bail!("复制子通道仍在收尾，未确认取消；请保留原任务或先断开关联SSH");
        }
        tokio::task::spawn_blocking(move || {
            transfers::with_relay_resources(|_, _, _, _| {
                let state = registry().lock();
                let current = job(&state, &id)?;
                let mut d = current.data.lock();
                if d.busy {
                    bail!("任务状态已改变");
                }
                if !current.io_empty() {
                    bail!("复制子通道仍在收尾，未确认取消；请保留原任务或先断开关联SSH");
                }
                let (mut h, p) = load(&id)?;
                apply_requested(&mut h, State::Cancelled);
                if retain_checkpoint(&h, p.as_ref()) {
                    save(&h, p.as_ref(), None)?;
                } else {
                    remove(&id)?;
                }
                d.header = h;
                Ok(())
            })
        })
        .await??;
    }
    Ok(())
}
pub(crate) async fn stop_terminal(id: u32) -> Result<()> {
    let ids: Vec<_> = registry()
        .lock()
        .jobs
        .iter()
        .filter_map(|j| {
            let d = j.data.lock();
            (d.busy && (d.source_terminal == Some(id) || d.destination_terminal == Some(id)))
                .then(|| d.header.id.clone())
        })
        .collect();
    let mut first = None;
    for id in ids {
        if let Err(error) = stop_inner(id, false, true).await {
            first.get_or_insert(error);
        }
    }
    if let Some(error) = first {
        Err(error)
    } else {
        Ok(())
    }
}
pub(crate) fn resume(
    source: Connection,
    target: Connection,
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
    ) || (decision.ends_with("_conflicts") && (node.is_some() || rename.is_some()))
        || (rename.is_some() && (node.is_none() || decision != "retry"))
        || (decision == "continue" && (node.is_some() || rename.is_some()))
    {
        bail!("远端复制恢复参数无效");
    }
    check_pair(&source, &target)?;
    transfers::with_relay_resources(|scheduler, up, down, _| {
        let mut state = registry().lock();
        restore(&mut state)?;
        check_pair(&source, &target)?;
        let j = job(&state, &id)?;
        {
            let d = j.data.lock();
            if d.busy || d.header.state.ended() {
                bail!("任务仍在运行或已经结束");
            }
            if d.header.source_target != source.target
                || d.header.destination_target != target.target
            {
                bail!("源或目标实际服务器、用户或指纹与原任务不同，拒绝恢复");
            }
        }
        let (mut h, mut plan) = load(&id)?;
        j.data.lock().header = h.clone();
        check_move_resume(&h, &decision)?;
        if decision == "rename_conflicts" {
            if plan.as_ref().is_none_or(|p| {
                !p.nodes
                    .iter()
                    .any(|n| n.kind == NodeKind::File && n.state == NodeState::Conflict)
            }) {
                bail!("没有适用的同名冲突");
            }
            h.rename_conflicts = true;
        } else if decision != "continue" {
            let p = plan.as_mut().context("任务尚未完成扫描，请使用继续")?;
            let selected: Vec<_> = match node {
                Some(i) => vec![i as usize],
                None => p
                    .nodes
                    .iter()
                    .enumerate()
                    .filter(|(_, n)| {
                        (n.kind == NodeKind::File
                            || matches!(decision.as_str(), "retry" | "rescan"))
                            && (decision != "rescan" || n.kind != NodeKind::File)
                            && if decision.ends_with("_conflicts") {
                                n.state == NodeState::Conflict
                            } else {
                                matches!(n.state, NodeState::Failed | NodeState::Conflict)
                            }
                    })
                    .map(|(i, _)| i)
                    .collect(),
            };
            if selected.is_empty() {
                bail!("没有适用的失败项目或冲突");
            }
            let mut rescans: BTreeSet<_> = h.rescan.iter().copied().collect();
            for i in selected {
                let entry = p.nodes.get(i).context("失败项目已不存在")?;
                if entry.kind != NodeKind::File
                    && entry.state == NodeState::Failed
                    && rename.is_none()
                    && matches!(decision.as_str(), "retry" | "rescan")
                {
                    if rescans.insert(i as u32) {
                        h.rescan.push(i as u32);
                    }
                    continue;
                }
                if decision == "rescan" {
                    bail!("重扫仅适用于失败目录或未完成发现的项目");
                }
                if let Some(name) = &rename {
                    p.rename_destination(i, name)?;
                } else {
                    p.retry(
                        i,
                        if decision.starts_with("overwrite") {
                            ConflictDecision::Overwrite
                        } else if decision.starts_with("skip") {
                            ConflictDecision::Skip
                        } else {
                            ConflictDecision::Ask
                        },
                    )?;
                }
            }
        }
        if let Some(p) = &plan {
            h.destination = p.destination.clone();
        }
        if let Some(p) = &plan {
            p.validate_endpoints(source.target.fingerprint == target.target.fingerprint)?;
        }
        h.state = State::Waiting;
        h.error = None;
        save(&h, plan.as_ref(), None)?;
        j.data.lock().header = h;
        launch(
            j,
            source,
            target,
            scheduler.enqueue(),
            up.clone(),
            down.clone(),
        );
        Ok(())
    })
}
pub(crate) fn failures(id: &str, offset: usize, limit: usize) -> Result<Vec<TransferFailure>> {
    if limit == 0 || limit > 256 {
        bail!("详情分页大小应为1–256");
    }
    let (_, p) = load(id)?;
    Ok(p.into_iter()
        .flat_map(|p| p.nodes.into_iter().enumerate())
        .filter(|(_, n)| matches!(n.state, NodeState::Failed | NodeState::Conflict))
        .skip(offset)
        .take(limit)
        .map(|(i, n)| TransferFailure {
            node: i as u32,
            path: n.relative,
            error: n.error.unwrap_or_else(|| "未成功".into()),
            conflict: n.state == NodeState::Conflict,
            rescan: n.kind != NodeKind::File && n.state == NodeState::Failed,
        })
        .collect())
}
pub(crate) fn clear_ended() -> Result<()> {
    transfers::with_relay_resources(|_, _, _, _| {
        let mut state = registry().lock();
        let durable: BTreeSet<String> =
            with_vault(|v| Ok(LocalTaskJournal::remote_copies(v).list()?))?
                .into_iter()
                .collect();
        state.jobs.retain(|j| {
            let mut d = j.data.lock();
            if d.busy || !j.io_empty() || !d.header.state.ended() {
                return true;
            }
            if durable.contains(&d.header.id) {
                // Only an actual retained journal requires a cleanup owner.
                // Do not accumulate invisible completed jobs after manual clear.
                d.cleanup_only = true;
                return true;
            }
            d.header.operation == CopyOperation::Move && d.header.move_phase == MovePhase::Intent
        });
        Ok(())
    })
}

#[cfg(test)]
mod move_tests {
    use super::*;
    #[test]
    fn source_reservations_include_ancestors_but_not_sibling_prefixes() {
        for (a, b) in [("/a", "/a"), ("/a", "/a/b"), ("/a/b", "/a"), ("/", "/a")] {
            assert!(source_paths_overlap(a, b));
        }
        assert!(!source_paths_overlap("/a", "/ab"));
        assert!(!source_paths_overlap("/a/b", "/a/c"));
    }
    fn header() -> CopyHeader {
        let target = Target {
            host_id: "host-synthetic".into(),
            address: "127.0.0.1".into(),
            port: 22,
            username: "synthetic".into(),
            fingerprint: "synthetic-fingerprint".into(),
        };
        CopyHeader {
            version: 1,
            id: "task-0123456789abcdef0123456789abcdef".into(),
            source_target: target.clone(),
            destination_target: target,
            source: "/source".into(),
            destination: "/destination".into(),
            state: State::Paused,
            error: None,
            default_conflict: DefaultConflict::Ask,
            relay_permitted: true,
            direct_permitted: false,
            rename_conflicts: false,
            operation: CopyOperation::Move,
            move_phase: MovePhase::Pending,
            move_directory: false,
            rescan: Vec::new(),
            cleanup: None,
            cleanup_abandoned: false,
            source_retirement: None,
        }
    }
    #[test]
    fn uncertain_rename_retains_its_record_and_cannot_be_replayed_as_continue_or_overwrite() {
        let mut h = header();
        check_move_resume(&h, "continue").unwrap();
        h.move_phase = MovePhase::Intent;
        apply_requested(&mut h, State::Cancelled);
        assert!(h.state == State::Failed);
        assert!(retain_checkpoint(&h, None));
        for state in [
            State::Running,
            State::Paused,
            State::Failed,
            State::Cancelled,
        ] {
            h.state = state;
            assert!(retain_checkpoint(&h, None));
            for action in ["continue", "retry", "overwrite", "rename_conflicts"] {
                assert!(check_move_resume(&h, action).is_err());
            }
        }
        h.move_phase = MovePhase::Confirmed;
        assert!(!retain_checkpoint(&h, None));
        check_move_resume(&h, "continue").unwrap();
        assert_eq!(move_stats(&h).complete, 1);
        h.move_phase = MovePhase::UserEnded;
        assert!(retain_checkpoint(&h, None));
        assert_eq!(move_stats(&h).complete, 0);
        assert!(check_move_resume(&h, "continue").is_err());
        h.operation = CopyOperation::Copy;
        h.move_phase = MovePhase::Pending;
        check_move_resume(&h, "overwrite").unwrap();
    }
    #[test]
    fn rename_requires_the_actual_same_account_instead_of_a_saved_host_label_or_shared_key_alone() {
        let a = header().source_target;
        let mut b = a.clone();
        b.host_id = "independent-saved-host".into();
        assert!(same_account(&a, &b));
        b.address = "localhost".into();
        assert!(!same_account(&a, &b));
        b = a.clone();
        b.port = 2222;
        assert!(!same_account(&a, &b));
        b = a.clone();
        b.username = "another-user".into();
        assert!(!same_account(&a, &b));
        b = a.clone();
        b.fingerprint = "another-fingerprint".into();
        assert!(!same_account(&a, &b));
    }
}
