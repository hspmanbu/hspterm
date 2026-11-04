//! Cancellable, generation-bound temporary file downloads. No credentials or
//! file contents in the registry, configuration store or diagnostics.
use anyhow::{Context, Result, bail};
use hspterm_ssh_core::{
    ManagedSession, SessionPhase,
    transfer::{self, FileDisposition},
};
use hspterm_storage_sync::{
    file_open_settings::FileOpenSettings,
    preview_cache::{PreviewCache, PreviewSlot},
};
use parking_lot::Mutex;
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        Arc, OnceLock, Weak,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio::{sync::watch, task::JoinHandle};
use tokio_util::sync::CancellationToken;

#[derive(Clone)]
pub struct FileOpenPreferences {
    /// Zero asks for every file; otherwise ask strictly above this many MiB.
    pub confirmation_mib: u32,
}
pub(crate) fn preferences() -> Result<FileOpenPreferences> {
    crate::api::with_vault(|v| {
        Ok(FileOpenPreferences {
            confirmation_mib: FileOpenSettings::load(v)?.confirmation_mib,
        })
    })
}
pub(crate) fn save_preferences(value: FileOpenPreferences) -> Result<()> {
    crate::api::with_vault(|v| {
        Ok(FileOpenSettings {
            confirmation_mib: value.confirmation_mib,
            ..FileOpenSettings::default()
        }
        .save(v)?)
    })
}
#[derive(Clone)]
pub struct FilePreview {
    pub token: String,
    pub phase: String,
    pub received: u64,
    pub total: Option<u64>,
    /// Snapshot from the first preparation; changing settings cannot change an
    /// already displayed confirmation or the consented preparation.
    pub confirmation_mib: Option<u32>,
    pub local_path: Option<String>,
    pub remote_path: String,
    pub name: String,
    pub error: Option<String>,
}
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    Reserved,
    Waiting,
    Downloading,
    NeedsConfirmation,
    Ready,
    Failed,
    Cancelled,
}
#[derive(Clone, Copy)]
pub(crate) enum Purpose {
    /// Explicit open may resolve a user-selected link to its target.
    Open,
    /// A drag-copy source must remain an ordinary final path component.
    ExplorerCopy,
}
struct PreviewRuntime {
    phase: Phase,
    received: u64,
    total: Option<u64>,
    confirmation_mib: Option<u32>,
    slot: Option<PreviewSlot>,
    error: Option<String>,
    version: u64,
    worker: Option<JoinHandle<()>>,
}
struct PreviewJob {
    purpose: Purpose,
    channels: crate::transfer_channels::Channels,
    token: String,
    terminal: u32,
    generation: u64,
    session: Weak<ManagedSession>,
    closing: Arc<AtomicBool>,
    remote: String,
    name: String,
    stop: CancellationToken,
    state: Mutex<PreviewRuntime>,
    finished: watch::Sender<u64>,
}
#[derive(Default)]
struct PreviewRegistry {
    cache: Option<Arc<PreviewCache>>,
    base: Option<PathBuf>,
    closing: bool,
    jobs: HashMap<String, Arc<PreviewJob>>,
}
fn registry() -> &'static Mutex<PreviewRegistry> {
    static VALUE: OnceLock<Mutex<PreviewRegistry>> = OnceLock::new();
    VALUE.get_or_init(Default::default)
}
fn lifecycle() -> &'static tokio::sync::Mutex<()> {
    static VALUE: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
    VALUE.get_or_init(Default::default)
}
pub(crate) async fn initialize(base: String) -> Result<u32> {
    let _lifecycle = lifecycle().lock().await;
    let base = tokio::task::spawn_blocking(move || std::fs::canonicalize(base)).await??;
    {
        let r = registry().lock();
        if r.base.as_ref().is_some_and(|p| p != &base) {
            bail!("预览缓存已在另一目录初始化");
        }
        if let Some(cache) = &r.cache {
            return Ok(cache.deferred_cleanup as u32);
        }
    }
    let directory = base.clone();
    let cache = tokio::task::spawn_blocking(move || PreviewCache::new_in(&directory)).await??;
    let deferred = cache.deferred_cleanup as u32;
    let mut r = registry().lock();
    r.base = Some(base);
    r.cache = Some(Arc::new(cache));
    r.closing = false;
    Ok(deferred)
}
pub(crate) fn reserve(
    connection: crate::transfers::Connection,
    remote: String,
    purpose: Purpose,
) -> Result<String> {
    let status = connection.session.status();
    if status.phase != SessionPhase::Connected
        || status.generation != connection.generation
        || connection.closing.load(Ordering::Acquire)
    {
        bail!("关联SSH会话已改变或断开");
    }
    let mut r = registry().lock();
    if r.closing || r.cache.is_none() {
        bail!("临时文件预览缓存尚未就绪或正在关闭");
    }
    if r.jobs
        .values()
        .filter(|j| {
            matches!(
                j.state.lock().phase,
                Phase::Reserved | Phase::Waiting | Phase::Downloading | Phase::NeedsConfirmation
            ) || !j.channels.is_empty()
        })
        .count()
        >= 32
    {
        bail!("待处理预览过多，请先完成或关闭现有预览");
    }
    let token = format!("preview-{:032x}", rand::random::<u128>());
    let name = remote.rsplit('/').next().unwrap_or("file").to_owned();
    let (finished, _) = watch::channel(0);
    r.jobs.insert(
        token.clone(),
        Arc::new(PreviewJob {
            purpose,
            channels: Default::default(),
            token: token.clone(),
            terminal: connection.terminal_id,
            generation: connection.generation,
            session: Arc::downgrade(&connection.session),
            closing: connection.closing,
            remote,
            name,
            stop: CancellationToken::new(),
            finished,
            state: Mutex::new(PreviewRuntime {
                phase: Phase::Reserved,
                received: 0,
                total: None,
                confirmation_mib: None,
                slot: None,
                error: None,
                version: 0,
                worker: None,
            }),
        }),
    );
    Ok(token)
}
fn get(token: &str) -> Result<Arc<PreviewJob>> {
    registry()
        .lock()
        .jobs
        .get(token)
        .cloned()
        .context("文件预览已释放")
}
fn snapshot(job: &PreviewJob) -> Result<FilePreview> {
    let state = job.state.lock();
    Ok(FilePreview {
        token: job.token.clone(),
        phase: format!("{:?}", state.phase),
        received: state.received,
        total: state.total,
        confirmation_mib: state.confirmation_mib,
        local_path: state
            .slot
            .as_ref()
            .map(|s| {
                s.path()
                    .to_str()
                    .map(str::to_owned)
                    .context("预览缓存路径无法编码")
            })
            .transpose()?,
        remote_path: job.remote.clone(),
        name: job.name.clone(),
        error: state.error.clone(),
    })
}
pub(crate) fn progress(token: String) -> Result<FilePreview> {
    let job = get(&token)?;
    snapshot(&job)
}
pub(crate) async fn prepare(token: String, allow_large: bool) -> Result<FilePreview> {
    let job = get(&token)?;
    let mut finished = job.finished.subscribe();
    // A completed result is published just before its supervisor returns. Join
    // that supervisor outside all locks before a confirmation starts new work.
    let previous = {
        let mut state = job.state.lock();
        if state.phase == Phase::NeedsConfirmation && allow_large {
            state.worker.take()
        } else {
            None
        }
    };
    if let Some(previous) = previous {
        previous.await.context("预览工作线程异常")?;
    }
    let version = {
        let r = registry().lock();
        if r.closing || !r.jobs.get(&token).is_some_and(|j| Arc::ptr_eq(j, &job)) {
            bail!("文件预览已关闭");
        }
        let mut state = job.state.lock();
        if job.stop.is_cancelled() {
            bail!("文件预览已取消");
        }
        if state.phase == Phase::Reserved
            || (state.phase == Phase::NeedsConfirmation && allow_large)
        {
            let cache = r.cache.clone().context("临时缓存尚未初始化")?;
            state.version += 1;
            let version = state.version;
            state.phase = Phase::Waiting;
            state.error = None;
            state.received = 0;
            let task = job.clone();
            let handle = tokio::runtime::Handle::current();
            state.worker = Some(tokio::spawn(async move {
                let work = task.clone();
                let result = tokio::task::spawn_blocking(move || {
                    // The permit lives outside the fallible run future, until
                    // its real channel cleanup (including unwind) has finished.
                    let mut permit = None;
                    handle.block_on(work.channels.supervise(run(
                        &work,
                        cache,
                        allow_large,
                        &mut permit,
                    )))
                })
                .await
                .map_err(|_| anyhow::anyhow!("预览工作线程异常；未发布部分文件"))
                .and_then(|r| r);
                let mut state = task.state.lock();
                match result {
                    Ok(Prepared::Large(size)) => {
                        state.phase = Phase::NeedsConfirmation;
                        state.total = Some(size);
                    }
                    Ok(Prepared::Ready(slot, size)) => {
                        state.phase = Phase::Ready;
                        state.total = Some(size);
                        state.received = size;
                        state.slot = Some(slot);
                    }
                    Err(error) => {
                        state.phase = if task.stop.is_cancelled() {
                            Phase::Cancelled
                        } else {
                            Phase::Failed
                        };
                        state.error = Some(crate::public_errors::summary(&error));
                    }
                }
                task.finished.send_replace(version);
            }));
        }
        state.version
    };
    while *finished.borrow_and_update() < version {
        tokio::select! { biased;
            _ = job.stop.cancelled() => bail!("文件预览已取消"),
            changed = finished.changed() => { changed.context("预览完成状态不可用")?; }
        }
    }
    if job.stop.is_cancelled() {
        bail!("文件预览已取消");
    }
    snapshot(&job)
}
enum Prepared {
    Large(u64),
    Ready(PreviewSlot, u64),
}
async fn run(
    job: &PreviewJob,
    cache: Arc<PreviewCache>,
    allow_large: bool,
    permit: &mut Option<hspterm_ssh_core::task_scheduler::TaskPermit>,
) -> Result<Prepared> {
    // This function runs on the storage worker. Do not read SQLite from the
    // synchronous ticket reservation or Flutter progress query.
    let saved_limit = job.state.lock().confirmation_mib;
    let limit = match saved_limit {
        Some(limit) => limit,
        None => {
            let limit = preferences()?.confirmation_mib;
            job.state.lock().confirmation_mib = Some(limit);
            limit
        }
    };
    let settings = FileOpenSettings {
        confirmation_mib: limit,
        ..FileOpenSettings::default()
    };
    let session = job.session.upgrade().context("关联SSH终端已关闭")?;
    let mut states = session.subscribe();
    let changed = async {
        loop {
            let status = states.borrow_and_update().clone();
            if status.phase != SessionPhase::Connected
                || status.generation != job.generation
                || job.closing.load(Ordering::Acquire)
            {
                break;
            }
            if states.changed().await.is_err() {
                break;
            }
        }
    };
    let work = async {
        let remote = job
            .channels
            .open(&session, job.generation, &job.stop)
            .await
            .context("无法建立预览SFTP子通道")?;
        let result: Result<Prepared> = async {
            let canonical = match job.purpose {
                Purpose::Open => remote
                    .canonicalize(job.remote.clone())
                    .await
                    .context("无法解析远端预览文件路径")?,
                // Canonicalize the parent only. Using the ordinary preview
                // resolver here could silently follow a replaced final link.
                // The subsequent lstat and transfer primitive reject that link.
                Purpose::ExplorerCopy => transfer::object_path(&remote, &job.remote).await?,
            };
            if !canonical.starts_with('/') || canonical.contains('\0') || canonical.len() > 131072 {
                bail!("服务器返回无效文件路径");
            }
            let attrs = remote
                .symlink_metadata(canonical.clone())
                .await
                .context("无法读取远端预览文件属性")?;
            if !attrs.is_regular() || attrs.is_symlink() {
                match job.purpose {
                    Purpose::Open => bail!("只能预览普通文件"),
                    Purpose::ExplorerCopy => bail!("拖出源已不是普通文件；未跟随符号链接"),
                }
            }
            let total = attrs.size.context("服务器未返回文件大小")?;
            job.state.lock().total = Some(total);
            if !allow_large && settings.requires_confirmation(total) {
                return Ok(Prepared::Large(total));
            }
            let (admission, limiter) = crate::transfers::preview_admission()?;
            *permit = Some(admission.enter(&job.stop).await?);
            let slot = cache.allocate(&job.name).context("无法创建临时预览文件")?;
            job.state.lock().phase = Phase::Downloading;
            let transfer_stop = job.stop.child_token();
            let mut larger = None;
            let result = transfer::download_file_limited(
                &remote,
                &canonical,
                slot.path(),
                FileDisposition::CreateNew,
                &transfer_stop,
                |p| {
                    if !allow_large && settings.requires_confirmation(p.total) {
                        larger = Some(p.total);
                        transfer_stop.cancel();
                    }
                    let mut state = job.state.lock();
                    state.received = p.acknowledged;
                    state.total = Some(p.total);
                },
                &limiter,
            )
            .await;
            if let Some(total) = larger {
                return Ok(Prepared::Large(total));
            }
            let complete = result?;
            Ok(Prepared::Ready(slot, complete.total))
        }
        .await;
        result
    };
    // The worker's outer Channels::supervise owns normal/error/unwind cleanup.
    // Do not apply a second full close timeout inside this cancellable body.
    tokio::select! { biased;
        _ = job.stop.cancelled() => Err(anyhow::anyhow!("文件预览已取消")),
        _ = changed => Err(anyhow::anyhow!("关联SSH会话已改变或断开")),
        result = work => result,
    }
}

async fn release(job: &Arc<PreviewJob>) -> Result<()> {
    job.stop.cancel();
    let mut finished = job.finished.subscribe();
    let (worker, version) = {
        let mut state = job.state.lock();
        (state.worker.take(), state.version)
    };
    let joined = if let Some(worker) = worker {
        let result = worker.await.context("预览工作线程异常");
        if result.is_err() {
            job.finished.send_replace(version);
        }
        result
    } else {
        // A concurrent cancellation may own the JoinHandle. Its absence is
        // not proof that the actual preview worker has already finished.
        while *finished.borrow_and_update() < version {
            finished.changed().await.context("预览完成状态不可用")?;
        }
        Ok(())
    };
    // Keep the job/slot and task owner if retirement is still uncertain. A
    // later explicit cancel/shutdown can retry cleanup after the Root ends.
    job.channels.supervise(async { Ok(()) }).await?;
    joined?;
    let slot = {
        let mut state = job.state.lock();
        state.phase = Phase::Cancelled;
        state.slot.take()
    };
    tokio::task::spawn_blocking(move || drop(slot)).await?;
    Ok(())
}
pub(crate) async fn cancel(token: String) -> Result<()> {
    let job = registry().lock().jobs.get(&token).cloned();
    if let Some(job) = job {
        release(&job).await?;
        let mut state = registry().lock();
        if state
            .jobs
            .get(&token)
            .is_some_and(|current| Arc::ptr_eq(current, &job))
        {
            state.jobs.remove(&token);
        }
    }
    Ok(())
}
pub(crate) async fn stop_terminal(id: u32) -> Result<()> {
    let jobs: Vec<_> = {
        let r = registry().lock();
        r.jobs
            .values()
            .filter(|j| j.terminal == id && j.state.lock().phase != Phase::Ready)
            .cloned()
            .collect()
    };
    let mut problem = None;
    for job in jobs {
        if let Err(e) = cancel(job.token.clone()).await {
            problem.get_or_insert(e);
        }
    }
    if let Some(e) = problem {
        return Err(e);
    }
    Ok(())
}
pub(crate) async fn shutdown() -> Result<()> {
    let _lifecycle = lifecycle().lock().await;
    let jobs: Vec<_> = {
        let mut r = registry().lock();
        r.closing = true;
        r.jobs.values().cloned().collect()
    };
    let mut error = None;
    for job in jobs {
        if let Err(e) = cancel(job.token.clone()).await {
            error.get_or_insert(e);
        }
    }
    if let Some(e) = error.take() {
        // Do not drop the run lock/cache while a retained worker or stream
        // may still use it. Shutdown can be explicitly retried.
        return Err(e);
    }
    let cache = {
        let mut r = registry().lock();
        r.base = None;
        r.cache.take()
    };
    if let Some(cache) = cache {
        let result = tokio::task::spawn_blocking(move || {
            Arc::try_unwrap(cache)
                .map_err(|_| anyhow::anyhow!("预览缓存仍在使用"))?
                .close()
                .context("清理预览缓存失败")
        })
        .await?;
        if let Err(e) = result {
            error.get_or_insert(e);
        }
    }
    if let Some(e) = error {
        return Err(e);
    }
    Ok(())
}
