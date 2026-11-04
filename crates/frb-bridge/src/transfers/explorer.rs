//! Delayed virtual-file delivery owns one ordinary download tree per root.
//! The cache is persistent for paused work; native consumers own a separate,
//! generation-bound lease. Explorer destination paths are never guessed.
use super::*;
use hspterm_ssh_core::explorer_manifest;
use hspterm_storage_sync::export_cache::{self, ExportSlot};

#[derive(Clone)]
pub struct ExportTicket {
    pub task: String,
    pub lease: String,
}
#[derive(Clone)]
pub struct ExportDescriptor {
    pub node: u32,
    pub name: String,
    pub directory: bool,
    pub bytes: u64,
}
#[derive(Clone)]
pub struct ExportFile {
    pub local: Option<String>,
    pub bytes: u64,
    pub read: Option<String>,
}

#[derive(Clone)]
pub(super) struct Lease {
    token: String,
    connection: Option<Connection>,
    pub(super) stop: CancellationToken,
    started: Arc<AtomicBool>,
    reads: Arc<Mutex<HashSet<String>>>,
    inventory: Arc<Mutex<Option<Arc<TreeTransfer>>>>,
    ready_plan: Arc<Mutex<Option<Arc<TreeTransfer>>>>,
}

pub(super) fn validate_inventory(name: &str, plan: &TreeTransfer) -> Result<()> {
    // A failed already-scanned regular file can be retried without changing
    // the descriptor inventory. Failed discovery/directories and links cannot.
    let mut projected = plan.clone();
    for node in &mut projected.nodes {
        if node.kind == NodeKind::File && node.state == NodeState::Failed {
            node.state = NodeState::Pending;
        }
    }
    explorer_manifest::descriptors(name, &projected)?;
    Ok(())
}
pub(super) fn ensure_slot(job: &Job, path: &std::path::Path) -> Result<()> {
    let mut slot = job.export_slot.lock();
    if slot.is_none() {
        *slot = Some(ExportSlot::lease(path)?);
    }
    if slot.as_ref().context("导出缓存租约缺失")?.path() != path {
        bail!("原导出缓存路径已改变");
    }
    Ok(())
}
pub(super) fn check_resume_lease(job: &Job, connection: &Connection) -> Result<()> {
    if let Some(lease) = job.export_lease.lock().as_ref()
        && let Some(original) = &lease.connection
        && (original.terminal_id != connection.terminal_id
            || original.generation != connection.generation)
    {
        bail!("请先结束旧Explorer交付，再从当前会话继续源任务");
    }
    Ok(())
}
pub(super) fn retire_cache(path: &std::path::Path) -> Result<()> {
    match ExportSlot::lease(path) {
        Ok(mut slot) => {
            slot.remove()?;
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}
fn check_scope(scope: &str) -> Result<()> {
    with_vault(|v| {
        if v.instance_id() != scope {
            bail!("原配置库已改变，导出没有继续");
        }
        Ok(())
    })
}
fn current(job: &Job, token: &str) -> Result<Lease> {
    let lease = job
        .export_lease
        .lock()
        .clone()
        .context("原Explorer交付租约已结束")?;
    if lease.token != token {
        bail!("原Explorer交付租约已过期");
    }
    // Registry switching is blocked by this job's native/read leases. A
    // configuration restore in the same open Vault must preserve active file
    // IO; its proposal-scope rotation is not a new export destination.
    Ok(lease)
}
fn bind(job: &Job, connection: Option<Connection>) -> Result<ExportTicket> {
    if job.export_readers.load(Ordering::Acquire) != 0 || job.export_lease.lock().is_some() {
        bail!("本任务仍由另一个Explorer接收方持有，请先结束原拖出");
    }
    let token = format!("explorer-{:032x}", rand::random::<u128>());
    *job.export_lease.lock() = Some(Lease {
        token: token.clone(),
        connection,
        stop: CancellationToken::new(),
        started: Arc::new(AtomicBool::new(false)),
        reads: Default::default(),
        inventory: Default::default(),
        ready_plan: Default::default(),
    });
    job.export_readers.store(1, Ordering::Release);
    Ok(ExportTicket {
        task: job.data.lock().header.id.clone(),
        lease: token,
    })
}

pub(crate) fn enqueue(
    connection: Connection,
    base: String,
    remote: String,
    name: String,
    scope: String,
) -> Result<ExportTicket> {
    explorer_manifest::validate_root_name(&name)?;
    check_connection(&connection)?;
    let mut state = registry().lock();
    check_scope(&scope)?;
    restore(&mut state)?;
    check_connection(&connection)?;
    if state
        .jobs
        .iter()
        .filter(|j| j.export_readers.load(Ordering::Acquire) != 0)
        .count()
        >= 128
    {
        bail!("活动Explorer源过多，请先结束现有拖出");
    }
    let owner = with_vault(|v| export_cache::vault_owner(v, true)?.context("导出缓存归属缺失"))?;
    let mut slot = export_cache::allocate_for_owner(std::path::Path::new(&base), &owner)?;
    let header = Header {
        version: 1,
        id: format!("task-{:032x}", rand::random::<u128>()),
        target: connection.target.clone(),
        local: slot.path(),
        remote,
        upload: false,
        state: State::Waiting,
        error: None,
        rescan: Vec::new(),
        rename_conflicts: false,
        default_conflict: DefaultConflict::Ask,
        export_name: Some(name),
    };
    if let Err(error) = save(&header, None) {
        slot.remove().context("未入队导出缓存清理未确认")?;
        return Err(error);
    }
    let job = new_job(header, Some(connection.terminal_id), None);
    *job.export_slot.lock() = Some(slot);
    job.export_scan_only.store(true, Ordering::Release);
    let ticket = bind(&job, Some(connection.clone()))?;
    state.jobs.push(job.clone());
    launch(&state, job, connection);
    Ok(ticket)
}

/// Re-dragging a ready snapshot is local-only, including after restart. A
/// partial task must first be explicitly continued in its authenticated SSH.
pub(crate) fn attach_ready(task: String, scope: String) -> Result<ExportTicket> {
    let mut state = registry().lock();
    check_scope(&scope)?;
    restore(&mut state)?;
    let job = job_by_id(&state, &task)?;
    let (header, plan) = load(&task)?;
    if header.export_name.is_none() || header.state != State::ExportReady || job.data.lock().busy {
        bail!("请先继续并完成源快照下载，再从队列拖到Explorer");
    }
    validate_inventory(
        header.export_name.as_deref().context("导出名称缺失")?,
        plan.as_ref().context("源快照清单缺失")?,
    )?;
    ensure_slot(&job, &header.local)?;
    bind(&job, None)
}

fn find(task: &str, token: &str) -> Result<(Arc<Job>, Lease)> {
    let state = registry().lock();
    let job = job_by_id(&state, task)?;
    let lease = current(&job, token)?;
    Ok((job, lease))
}
async fn wait_run(job: &Arc<Job>, lease: &Lease) -> Result<()> {
    let mut finished = job.finished.subscribe();
    loop {
        let (busy, version) = {
            let data = job.data.lock();
            (data.busy, data.run_version)
        };
        if !busy && *finished.borrow_and_update() >= version {
            break;
        }
        tokio::select! { biased;
            _ = lease.stop.cancelled() => bail!("Explorer接收已取消"),
            changed = finished.changed() => { changed.context("源任务完成状态不可用")?; }
        }
    }
    Ok(())
}
pub(crate) async fn inventory(task: String, token: String) -> Result<Vec<ExportDescriptor>> {
    let (job, lease) = find(&task, &token)?;
    wait_run(&job, &lease).await?;
    tokio::task::spawn_blocking(move || {
        let _state = registry().lock();
        let lease = current(&job, &token)?;
        if lease.stop.is_cancelled() {
            bail!("Explorer接收已取消");
        }
        if let Some(connection) = &lease.connection {
            check_connection(connection)?;
        }
        let header = job.data.lock().header.clone();
        let name = header.export_name.context("不是Explorer源任务")?;
        if matches!(
            header.state,
            State::Failed | State::Partial | State::Cancelled
        ) {
            bail!("目录扫描未完整确认，请检查源任务");
        }
        let mut inventory = lease.inventory.lock();
        if inventory.is_none() {
            let (_, plan) = load(&task)?;
            *inventory = Some(Arc::new(plan.context("目录扫描未完成，请检查源任务")?));
        }
        let plan = inventory.as_ref().context("原清单未确认")?;
        Ok(explorer_manifest::descriptors(&name, plan)?
            .into_iter()
            .map(|d| ExportDescriptor {
                node: d.node_index as u32,
                name: d.name,
                directory: d.directory,
                bytes: d.bytes,
            })
            .collect())
    })
    .await?
}

/// Starts one whole source task once, regardless of how many FILECONTENTS
/// calls arrive. Only a completed tree and retired actual IO publish a path.
pub(crate) async fn prepare(task: String, token: String, node: u32) -> Result<ExportFile> {
    let (job, lease) = find(&task, &token)?;
    let start_job = job.clone();
    let start_token = token.clone();
    tokio::task::spawn_blocking(move || {
        let state = registry().lock();
        let job = start_job;
        let lease = current(&job, &start_token)?;
        if let Some(connection) = &lease.connection {
            let data = job.data.lock();
            if data.terminal_id != Some(connection.terminal_id)
                || data.terminal_generation != Some(connection.generation)
            {
                bail!("原Explorer源会话代次已改变，请重新拖出");
            }
        }
        if lease.stop.is_cancelled() {
            bail!("Explorer接收已取消");
        }
        let header = job.data.lock().header.clone();
        if header.state.ended() {
            bail!("源任务已结束，未重新开始交付");
        }
        if header.export_name.is_none()
            || lease
                .inventory
                .lock()
                .as_ref()
                .and_then(|p| p.nodes.get(node as usize))
                .is_none()
        {
            bail!("原导出节点已不存在");
        }
        if header.state != State::ExportReady
            && !lease.started.swap(true, Ordering::AcqRel)
            && !job.data.lock().busy
        {
            let connection = lease
                .connection
                .clone()
                .context("请在队列中明确继续源下载")?;
            check_connection(&connection)?;
            job.export_scan_only.store(false, Ordering::Release);
            launch(&state, job.clone(), connection);
        }
        Ok::<_, anyhow::Error>(())
    })
    .await??;
    wait_run(&job, &lease).await?;
    tokio::task::spawn_blocking(move || {
        let _state = registry().lock();
        let lease = current(&job, &token)?;
        if lease.stop.is_cancelled() {
            bail!("Explorer接收已取消");
        }
        let header = job.data.lock().header.clone();
        if header.state != State::ExportReady || job.data.lock().busy || !job.channels.is_empty() {
            bail!("源快照尚未完整就绪；可在队列继续后重新拖出");
        }
        let plan = {
            let mut cached = lease.ready_plan.lock();
            if cached.is_none() {
                let (_, plan) = load(&task)?;
                *cached = Some(Arc::new(plan.context("源快照清单缺失")?));
            }
            cached.as_ref().context("源快照清单缺失")?.clone()
        };
        let entry = plan
            .nodes
            .get(node as usize)
            .context("原导出节点已不存在")?;
        if entry.state != NodeState::Complete {
            bail!("原导出节点未完成");
        }
        if entry.kind == NodeKind::Directory {
            return Ok(ExportFile {
                local: None,
                bytes: 0,
                read: None,
            });
        }
        if entry.kind != NodeKind::File {
            bail!("导出不跟随符号链接或特殊文件");
        }
        let mut path = header.local;
        if !entry.relative.is_empty() {
            for component in entry.relative.split('/') {
                path.push(component);
            }
        }
        let metadata = std::fs::symlink_metadata(&path)?;
        if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() != entry.size
        {
            bail!("完整导出源缓存已改变，未交付内容");
        }
        let local = path.to_str().context("导出缓存路径无法编码")?.to_owned();
        let mut reads = lease.reads.lock();
        if reads.len() >= 64 {
            bail!("待释放的Explorer读取租约过多");
        }
        let read = format!("read-{:032x}", rand::random::<u128>());
        reads.insert(read.clone());
        job.export_readers.fetch_add(1, Ordering::AcqRel);
        Ok(ExportFile {
            local: Some(local),
            bytes: entry.size,
            read: Some(read),
        })
    })
    .await?
}

pub(crate) async fn cancel(task: String, token: String) -> Result<()> {
    let (job, lease) = find(&task, &token)?;
    lease.stop.cancel();
    stop(task, false).await?;
    if !job.channels.is_empty() {
        bail!("导出源IO仍在收尾，未结束交付租约");
    }
    Ok(())
}
pub(crate) fn release(task: String, token: String, delivered: bool) -> Result<()> {
    let state = registry().lock();
    let job = job_by_id(&state, &task)?;
    let lease = current(&job, &token)?;
    if !lease.reads.lock().is_empty() || job.export_readers.load(Ordering::Acquire) != 1 {
        bail!("Explorer本机文件仍在读取，未释放源缓存");
    }
    if job.data.lock().busy || !job.channels.is_empty() {
        bail!("导出源仍在运行，未释放缓存");
    }
    let (mut header, plan) = load(&task)?;
    if delivered && header.state == State::ExportReady {
        // This is source/data delivery only; the UI never claims external disk ACK.
        header.state = State::Complete;
        save(&header, plan.as_ref())?;
        job.data.lock().header = header.clone();
    }
    if header.state.ended() {
        let mut slot = job.export_slot.lock();
        if let Some(slot) = slot.as_mut() {
            slot.remove()?;
        }
        slot.take();
        remove(&task)?;
    } else {
        // Paused/failed/ready source data and encrypted offsets survive. No
        // external receiver is assumed to survive this lease or application.
        job.export_slot.lock().take();
    }
    lease.stop.cancel();
    job.export_lease.lock().take();
    job.export_readers.store(0, Ordering::Release);
    Ok(())
}
pub(crate) fn release_file(task: String, token: String, read: String) -> Result<()> {
    let (job, lease) = find(&task, &token)?;
    if lease.reads.lock().remove(&read) {
        job.export_readers.fetch_sub(1, Ordering::AcqRel);
    }
    Ok(())
}
