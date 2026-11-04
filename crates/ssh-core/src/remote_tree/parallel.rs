//! Cooperative relay concurrency. One authoritative manifest and synchronous
//! persistence barriers, with one small owned node per admitted file. No spawned
//! file worker, detached checkpoint, or full plan copy for each file.
use super::*;
use file::FileWork;
use futures_util::{StreamExt, stream::FuturesUnordered};
use parking_lot::Mutex;
use std::sync::Arc;

struct Shared<'a, F> {
    plan: &'a mut RemoteTree,
    stats: Accumulator,
    changed: F,
    active: Vec<usize>,
    checkpoint_failed: bool,
    admission_error: Option<RemoteTreeError>,
}
impl<F: FnMut(&RemoteTree, TreeProgress, &[usize]) -> Result<()>> Shared<'_, F> {
    fn notify(&mut self, index: usize) -> Result<()> {
        if self.checkpoint_failed {
            return Err(RemoteTreeError::Checkpoint);
        }
        let result = (self.changed)(
            self.plan,
            TreeProgress {
                index,
                current: self.active.first().copied(),
                stats: self.stats.snapshot(),
            },
            &self.active,
        );
        if result.is_err() {
            self.checkpoint_failed = true;
            return Err(RemoteTreeError::Checkpoint);
        }
        Ok(())
    }
    fn apply(&mut self, index: usize, work: &FileWork) -> Result<()> {
        let before = Contribution::from(&self.plan.nodes[index]);
        work.apply(self.plan, index);
        self.stats
            .replace(before, Contribution::from(&self.plan.nodes[index]));
        self.notify(index)
    }
}
#[allow(clippy::too_many_arguments)]
async fn worker<F: FnMut(&RemoteTree, TreeProgress, &[usize]) -> Result<()>>(
    index: usize,
    mut work: FileWork,
    source: &SftpSession,
    target: &SftpSession,
    stop: &CancellationToken,
    upload: &BandwidthLimiter,
    download: &BandwidthLimiter,
    direct: Option<&crate::direct_transfer::DirectRoute>,
    shared: Arc<Mutex<Shared<'_, F>>>,
) -> (usize, FileWork, Result<()>) {
    let result = work
        .run_with_direct(
            source,
            target,
            stop,
            upload,
            download,
            direct,
            &mut |work| {
                // This lock never crosses await. The barrier is ACKed synchronously by
                // the owner before this worker can issue its next destructive request.
                let result = shared.lock().apply(index, work);
                if result.is_err() {
                    stop.cancel();
                }
                result
            },
        )
        .await;
    (index, work, result)
}
impl RemoteTree {
    #[allow(clippy::too_many_arguments)]
    pub async fn run_parallel_observed(
        &mut self,
        source: &SftpSession,
        target: &SftpSession,
        stop: &CancellationToken,
        upload: &BandwidthLimiter,
        download: &BandwidthLimiter,
        files: usize,
        changed: impl FnMut(&Self, TreeProgress, &[usize]) -> Result<()>,
    ) -> Result<TreeOutcome> {
        self.run_parallel_with_direct(source, target, stop, upload, download, files, None, changed)
            .await
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn run_parallel_with_direct(
        &mut self,
        source: &SftpSession,
        target: &SftpSession,
        stop: &CancellationToken,
        upload: &BandwidthLimiter,
        download: &BandwidthLimiter,
        files: usize,
        direct: Option<&crate::direct_transfer::DirectRoute>,
        mut changed: impl FnMut(&Self, TreeProgress, &[usize]) -> Result<()>,
    ) -> Result<TreeOutcome> {
        self.validate()?;
        if !(1..=8).contains(&files) {
            return Err(RemoteTreeError::InvalidPlan);
        }
        changed(
            self,
            TreeProgress {
                index: 0,
                current: None,
                stats: self.stats(),
            },
            &[],
        )
        .map_err(|_| RemoteTreeError::Checkpoint)?;
        let mut stats = Accumulator::new(&self.nodes);
        let mut blocked: HashSet<String> = self
            .nodes
            .iter()
            .filter(|n| n.kind == NodeKind::Directory && n.state == NodeState::Failed)
            .map(|n| n.relative.clone())
            .collect();
        // All directory dependencies are checked before file admission. Keep
        // the sequential runner's revalidation of already-created directories.
        for index in 0..self.nodes.len() {
            if index.is_multiple_of(128) {
                tokio::task::yield_now().await;
            }
            if stop.is_cancelled() {
                return Ok(TreeOutcome::Paused);
            }
            let node = &self.nodes[index];
            if node.kind != NodeKind::Directory
                || !matches!(node.state, NodeState::Pending | NodeState::Complete)
            {
                continue;
            }
            let before = Contribution::from(node);
            let relative = node.relative.clone();
            let result = if blocked_parent(&relative, &blocked) {
                Err(RemoteTreeError::UnsafeParent)
            } else {
                let path = self.destination_path(index)?;
                cancellable(stop, async {
                    guard_parent(target, &path).await?;
                    ensure_directory(target, &path).await
                })
                .await
            };
            if matches!(&result, Err(RemoteTreeError::Cancelled)) {
                return Ok(TreeOutcome::Paused);
            }
            let transient = result
                .as_ref()
                .err()
                .is_some_and(|e| recovery::retryable(e, NodeKind::Directory, StagingPhase::Absent));
            let node = &mut self.nodes[index];
            match result {
                Ok(()) => {
                    node.state = NodeState::Complete;
                    node.error = None;
                }
                Err(error) => {
                    node.state = NodeState::Failed;
                    node.error = Some(error.to_string());
                    blocked.insert(relative);
                }
            }
            stats.replace(before, Contribution::from(&self.nodes[index]));
            changed(
                self,
                TreeProgress {
                    index,
                    current: None,
                    stats: stats.snapshot(),
                },
                &[],
            )
            .map_err(|_| RemoteTreeError::Checkpoint)?;
            if transient {
                return Err(RemoteTreeError::TransientChannel {
                    indices: vec![index],
                });
            }
        }
        let shared = Arc::new(Mutex::new(Shared {
            plan: self,
            stats,
            changed,
            active: Vec::with_capacity(files),
            checkpoint_failed: false,
            admission_error: None,
        }));
        let run_stop = stop.child_token();
        let mut running = FuturesUnordered::new();
        let mut cursor: usize = 0;
        let mut channel_errors = Vec::new();
        loop {
            while !run_stop.is_cancelled() && running.len() < files {
                if cursor.is_multiple_of(128) {
                    tokio::task::yield_now().await;
                }
                if run_stop.is_cancelled() {
                    break;
                }
                let next = {
                    let mut state = shared.lock();
                    if cursor >= state.plan.nodes.len() {
                        None
                    } else {
                        let index = cursor;
                        cursor += 1;
                        let node = &state.plan.nodes[index];
                        if node.kind != NodeKind::File || node.state != NodeState::Pending {
                            Some((index, None))
                        } else {
                            let blocked = blocked_parent(&node.relative, &blocked);
                            match FileWork::new(state.plan, index) {
                                Err(error) => {
                                    state.admission_error = Some(error);
                                    run_stop.cancel();
                                    Some((index, None))
                                }
                                Ok(mut work) if blocked => {
                                    work.node.state = NodeState::Failed;
                                    work.node.error =
                                        Some("父目录未成功读取或创建，未跟随链接".into());
                                    if state.apply(index, &work).is_err() {
                                        run_stop.cancel();
                                    }
                                    Some((index, None))
                                }
                                Ok(work) => {
                                    state.active.push(index);
                                    if state.notify(index).is_err() {
                                        run_stop.cancel();
                                    }
                                    Some((index, Some(work)))
                                }
                            }
                        }
                    }
                };
                match next {
                    None => break,
                    Some((index, Some(work))) => running.push(worker(
                        index,
                        work,
                        source,
                        target,
                        &run_stop,
                        upload,
                        download,
                        direct,
                        shared.clone(),
                    )),
                    Some((_, None)) => {}
                }
            }
            let Some((index, mut work, result)) = running.next().await else {
                break;
            };
            // No file Future is dropped on a sibling failure. Draining keeps
            // CLOSE/last ACKs and the worker's exact staging boundary intact.
            match result {
                Ok(()) if work.node.state != NodeState::Skipped => {
                    work.node.state = NodeState::Complete;
                    work.node.error = None;
                }
                Ok(()) => {}
                Err(RemoteTreeError::Checkpoint) => {
                    shared.lock().checkpoint_failed = true;
                    run_stop.cancel();
                }
                Err(ref error)
                    if matches!(error, RemoteTreeError::Cancelled)
                        || (run_stop.is_cancelled()
                            && !stop.is_cancelled()
                            && recovery::cancelled_channel_cleanup(error)) =>
                {
                    if !stop.is_cancelled()
                        && matches!(
                            work.phase,
                            StagingPhase::Intent
                                | StagingPhase::Direct { .. }
                                | StagingPhase::Publishing
                                | StagingPhase::Published
                        )
                    {
                        // Sibling channel/checkpoint failure may interrupt an
                        // unacknowledged mutation. Do not auto-run it again.
                        work.node.state = NodeState::Failed;
                        work.node.error =
                            Some("暂存创建或发布被中断，结果未确认；需明确检查后继续".into());
                    }
                }
                Err(RemoteTreeError::Copy(RemoteCopyError::Transfer(TransferError::Conflict))) => {
                    work.node.state = NodeState::Conflict;
                    work.node.error = Some("目标已存在，等待覆盖、跳过或更名".into());
                }
                Err(error) => {
                    if recovery::channel_fault(&error) {
                        run_stop.cancel();
                        if recovery::retryable(&error, NodeKind::File, work.phase) {
                            channel_errors.push(index);
                        }
                    }
                    work.node.state = NodeState::Failed;
                    work.node.error = Some(error.to_string());
                }
            }
            let mut state = shared.lock();
            state.active.retain(|i| *i != index);
            if state.apply(index, &work).is_err() {
                run_stop.cancel();
            }
        }
        let mut state = shared.lock();
        if state.checkpoint_failed {
            return Err(RemoteTreeError::Checkpoint);
        }
        if let Some(error) = state.admission_error.take() {
            return Err(error);
        }
        if stop.is_cancelled() {
            return Ok(TreeOutcome::Paused);
        }
        if !channel_errors.is_empty() {
            return Err(RemoteTreeError::TransientChannel {
                indices: channel_errors,
            });
        }
        let stats = state.stats.snapshot();
        Ok(if stats.failed != 0 || stats.conflicts != 0 {
            TreeOutcome::Partial
        } else if stats.skipped != 0 {
            TreeOutcome::CompleteWithSkips
        } else {
            TreeOutcome::Complete
        })
    }
}
