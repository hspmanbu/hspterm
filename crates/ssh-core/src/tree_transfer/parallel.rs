//! Cooperative, bounded per-tree file concurrency. The caller still owns one
//! FIFO admission and one original SFTP session. No detached file workers.
use super::*;
use crate::bandwidth::BandwidthLimiter;
use futures_util::{StreamExt, stream::FuturesUnordered};
use parking_lot::Mutex;
use std::{collections::BTreeMap, sync::Arc};
use tokio::sync::Notify;

const MAX_FILES: usize = 8;
fn transient_remote(error: &RemoteError) -> bool {
    matches!(error, RemoteError::Timeout | RemoteError::ConnectionClosed)
}
fn transient_transfer(error: &TransferError) -> bool {
    match error {
        TransferError::Remote(error) => transient_remote(error),
        TransferError::Io(error) | TransferError::RemoteClose(error) => error
            .get_ref()
            .and_then(|source| source.downcast_ref::<RemoteError>())
            .is_some_and(transient_remote),
        _ => false,
    }
}

#[derive(Default)]
struct Updates {
    // At most one replaceable progress snapshot per admitted file. ACKs remain
    // in the worker too, so final/error/cancel always publishes the last one.
    latest: Mutex<BTreeMap<usize, transfer::FileProgress>>,
    changed: Notify,
}
struct FileWork {
    index: usize,
    direction: Direction,
    local: PathBuf,
    remote: String,
    mode: FileDisposition,
}
struct Finished {
    index: usize,
    latest: Option<transfer::FileProgress>,
    result: std::result::Result<transfer::FileProgress, TransferError>,
}
impl FileWork {
    async fn run(
        self,
        sftp: &SftpSession,
        stop: &CancellationToken,
        limiter: &BandwidthLimiter,
        updates: Arc<Updates>,
    ) -> Finished {
        let mut latest = None;
        let result = {
            let mut progress = |value: transfer::FileProgress| {
                latest = Some(value);
                updates.latest.lock().insert(self.index, value);
                updates.changed.notify_one();
            };
            match self.direction {
                Direction::Upload => {
                    transfer::upload_file_limited(
                        sftp,
                        &self.local,
                        &self.remote,
                        self.mode,
                        stop,
                        &mut progress,
                        limiter,
                    )
                    .await
                }
                Direction::Download => {
                    transfer::download_file_limited(
                        sftp,
                        &self.remote,
                        &self.local,
                        self.mode,
                        stop,
                        &mut progress,
                        limiter,
                    )
                    .await
                }
            }
        };
        Finished {
            index: self.index,
            latest,
            result,
        }
    }
}
fn location(plan: &TreeTransfer, index: usize) -> Result<(PathBuf, String)> {
    let node = &plan.nodes[index];
    let relative = &node.relative;
    let mapped = if plan.direction == Direction::Download {
        mapped_relative(node, node.destination_name.as_deref())
    } else {
        relative.clone()
    };
    if !crate::local_path::supported_relative(&mapped) {
        return Err(TreeError::InvalidLocalPath);
    }
    let mut local = local_join(&plan.local, &mapped);
    let mut remote = remote_join(&plan.remote, relative);
    if let Some(name) = &node.destination_name {
        match plan.direction {
            Direction::Upload => {
                let parent = remote.rsplit_once('/').ok_or(TreeError::InvalidPlan)?.0;
                remote = format!("{parent}/{name}");
            }
            Direction::Download if relative.is_empty() => {
                local = plan
                    .local
                    .parent()
                    .ok_or(TreeError::InvalidPlan)?
                    .join(name);
            }
            Direction::Download => {}
        }
    }
    Ok((local, remote))
}
fn notify(
    plan: &TreeTransfer,
    index: usize,
    before: stats::Contribution,
    stats: &mut stats::Accumulator,
    active: &[usize],
    changed: &mut impl FnMut(&TreeTransfer, TreeProgress, &[usize]),
) {
    stats.replace(before, stats::Contribution::from(&plan.nodes[index]));
    changed(
        plan,
        TreeProgress {
            index,
            current: active.first().copied(),
            stats: stats.snapshot(),
        },
        active,
    );
}
fn apply_progress(plan: &mut TreeTransfer, index: usize, p: transfer::FileProgress) {
    let node = &mut plan.nodes[index];
    node.started = true;
    node.size = p.total;
    node.acknowledged = p.acknowledged;
}
fn flush(
    plan: &mut TreeTransfer,
    updates: &Updates,
    stats: &mut stats::Accumulator,
    active: &[usize],
    changed: &mut impl FnMut(&TreeTransfer, TreeProgress, &[usize]),
) {
    let latest = std::mem::take(&mut *updates.latest.lock());
    for (index, p) in latest {
        let before = stats::Contribution::from(&plan.nodes[index]);
        apply_progress(plan, index, p);
        notify(plan, index, before, stats, active, changed);
    }
}
impl TreeTransfer {
    /// Sequential parent-directory validation followed by 1..=8 simultaneous
    /// file streams. Active indices are borrowed only for this notification;
    /// no transient Running state is ever serialized into the real manifest.
    /// All successful/error/cancel worker results are joined before return.
    pub async fn run_parallel_observed(
        &mut self,
        sftp: &SftpSession,
        stop: &CancellationToken,
        files: usize,
        mut changed: impl FnMut(&Self, TreeProgress, &[usize]),
        limiter: &BandwidthLimiter,
    ) -> Result<TreeOutcome> {
        self.validate()?;
        if !(1..=MAX_FILES).contains(&files) {
            return Err(TreeError::InvalidPlan);
        }
        let mut stats = stats::Accumulator::new(&self.nodes);
        let mut blocked: HashSet<String> = self
            .nodes
            .iter()
            .filter(|n| n.kind == NodeKind::Directory && n.state == NodeState::Failed)
            .map(|n| n.relative.clone())
            .collect();
        // Keep ordering dependencies out of file workers; a completed directory
        // is checked again, exactly as in the original sequential runner.
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
            let before = stats::Contribution::from(node);
            let result = if blocked_parent(&node.relative, &blocked) {
                Err(TreeError::InvalidPlan)
            } else {
                match location(self, index) {
                    Ok((local, remote)) => {
                        cancellable(
                            stop,
                            ensure_directory(self.direction, sftp, &local, &remote),
                        )
                        .await
                    }
                    Err(error) => Err(error),
                }
            };
            if matches!(result, Err(TreeError::Cancelled)) {
                return Ok(TreeOutcome::Paused);
            }
            let transient =
                matches!(&result, Err(TreeError::Remote(error)) if transient_remote(error));
            let node = &mut self.nodes[index];
            match result {
                Ok(()) => {
                    node.state = NodeState::Complete;
                    node.error = None;
                }
                Err(error) => {
                    node.state = NodeState::Failed;
                    node.error = Some(error.to_string());
                    blocked.insert(node.relative.clone());
                }
            }
            notify(self, index, before, &mut stats, &[], &mut changed);
            if transient {
                return Err(TreeError::TransientChannel(vec![index]));
            }
        }
        let updates = Arc::new(Updates::default());
        let run_stop = stop.child_token();
        let mut channel_errors = Vec::new();
        let mut running = FuturesUnordered::new();
        let mut active = Vec::with_capacity(files);
        let mut active_targets = BTreeMap::<usize, String>::new();
        let mut cursor = 0usize;
        loop {
            flush(self, &updates, &mut stats, &active, &mut changed);
            while !run_stop.is_cancelled() && running.len() < files && cursor < self.nodes.len() {
                let index = cursor;
                cursor += 1;
                if index.is_multiple_of(128) {
                    tokio::task::yield_now().await;
                }
                // Cancellation may have arrived during the scheduler yield.
                if stop.is_cancelled() {
                    break;
                }
                let node = &self.nodes[index];
                if node.kind != NodeKind::File || node.state != NodeState::Pending {
                    continue;
                }
                let before = stats::Contribution::from(node);
                let paths = location(self, index);
                if blocked_parent(&node.relative, &blocked) || paths.is_err() {
                    let error = paths.err().map_or_else(
                        || "父目录未成功创建或不能安全访问".into(),
                        |e| e.to_string(),
                    );
                    let node = &mut self.nodes[index];
                    node.state = NodeState::Failed;
                    node.error = Some(error);
                    notify(self, index, before, &mut stats, &active, &mut changed);
                    continue;
                }
                if node.decision == ConflictDecision::Skip {
                    self.nodes[index].state = NodeState::Skipped;
                    notify(self, index, before, &mut stats, &active, &mut changed);
                    continue;
                }
                let mode = if node.started {
                    FileDisposition::Resume {
                        offset: node.acknowledged,
                    }
                } else if node.decision == ConflictDecision::Overwrite {
                    FileDisposition::Overwrite
                } else {
                    FileDisposition::CreateNew
                };
                let (local, remote) = paths?;
                let key = match self.direction {
                    Direction::Upload => remote.clone(),
                    Direction::Download if cfg!(windows) => local.to_string_lossy().to_lowercase(),
                    Direction::Download => local.to_string_lossy().into_owned(),
                };
                // Explicit renames (or Windows case aliases) may map two source
                // rows to one target. Preserve manifest order for that target;
                // never run overlapping overwrite/resume streams concurrently.
                if active_targets.values().any(|target| *target == key) {
                    cursor -= 1;
                    break;
                }
                active_targets.insert(index, key);
                active.push(index);
                running.push(
                    FileWork {
                        index,
                        local,
                        remote,
                        mode,
                        direction: self.direction,
                    }
                    .run(sftp, &run_stop, limiter, updates.clone()),
                );
                notify(self, index, before, &mut stats, &active, &mut changed);
            }
            if running.is_empty() {
                break;
            }
            let finished = tokio::select! {
                value = running.next() => value,
                _ = updates.changed.notified() => None,
            };
            if let Some(done) = finished {
                // Publish coalesced ACKs before the final state. A failure or
                // cancellation must not erase an acknowledged prefix.
                flush(self, &updates, &mut stats, &active, &mut changed);
                let index = done.index;
                let before = stats::Contribution::from(&self.nodes[index]);
                if let Some(p) = done.latest {
                    apply_progress(self, index, p);
                }
                let node = &mut self.nodes[index];
                match done.result {
                    Ok(p) => {
                        node.started = true;
                        node.size = p.total;
                        node.acknowledged = p.acknowledged;
                        node.state = NodeState::Complete;
                        node.error = None;
                    }
                    Err(TransferError::Cancelled) => {}
                    Err(TransferError::Conflict) => {
                        node.state = NodeState::Conflict;
                        node.error = Some("目标已存在，等待覆盖、跳过或更名决定".into());
                    }
                    Err(error) => {
                        if transient_transfer(&error) {
                            channel_errors.push(index);
                            run_stop.cancel();
                        }
                        node.state = NodeState::Failed;
                        node.error = Some(error.to_string());
                    }
                }
                active.retain(|i| *i != index);
                active_targets.remove(&index);
                notify(self, index, before, &mut stats, &active, &mut changed);
            }
        }
        // No worker was dropped due to an unrelated file failing or a stop.
        flush(self, &updates, &mut stats, &active, &mut changed);
        if !stop.is_cancelled() && !channel_errors.is_empty() {
            return Err(TreeError::TransientChannel(channel_errors));
        }
        let stats = stats.snapshot();
        Ok(if stop.is_cancelled() {
            TreeOutcome::Paused
        } else if stats.failed != 0 || stats.conflicts != 0 {
            TreeOutcome::Partial
        } else if stats.skipped != 0 {
            TreeOutcome::CompleteWithSkips
        } else {
            TreeOutcome::Complete
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovery_only_accepts_typed_channel_faults_not_local_disk_or_protocol_errors() {
        assert!(transient_transfer(&TransferError::Remote(
            RemoteError::Timeout
        )));
        assert!(transient_transfer(&TransferError::Remote(
            RemoteError::ConnectionClosed
        )));
        assert!(transient_transfer(&TransferError::RemoteClose(
            std::io::Error::other(RemoteError::ConnectionClosed)
        )));
        assert!(!transient_transfer(&TransferError::Io(
            std::io::Error::new(std::io::ErrorKind::TimedOut, "synthetic local disk timeout")
        )));
        assert!(!transient_transfer(&TransferError::Remote(
            RemoteError::UnexpectedPacket
        )));
        assert!(!transient_transfer(&TransferError::Remote(
            RemoteError::Status(russh_sftp::protocol::Status {
                id: 1,
                status_code: StatusCode::PermissionDenied,
                error_message: "synthetic private server message".into(),
                language_tag: String::new()
            })
        )));
        assert!(!transient_transfer(&TransferError::InvalidResume));
        assert!(!transient_transfer(&TransferError::Conflict));
    }

    #[test]
    fn file_locations_preserve_posix_names_and_root_or_child_rename_semantics() {
        let mut plan = TreeTransfer {
            version: 1,
            direction: Direction::Download,
            local: PathBuf::from("/synthetic/base"),
            remote: "/remote".into(),
            nodes: vec![TransferNode {
                relative: "nested/old name".into(),
                kind: NodeKind::File,
                size: 10,
                acknowledged: 0,
                started: false,
                state: NodeState::Pending,
                decision: ConflictDecision::Ask,
                destination_name: Some("new ' name".into()),
                error: None,
                default_policy_pending: false,
            }],
        };
        assert_eq!(
            location(&plan, 0).unwrap(),
            (
                PathBuf::from("/synthetic/base/nested/new ' name"),
                "/remote/nested/old name".into()
            )
        );
        plan.direction = Direction::Upload;
        assert_eq!(
            location(&plan, 0).unwrap(),
            (
                PathBuf::from("/synthetic/base/nested/old name"),
                "/remote/nested/new ' name".into()
            )
        );
        plan.direction = Direction::Download;
        plan.nodes[0].relative.clear();
        assert_eq!(
            location(&plan, 0).unwrap(),
            (PathBuf::from("/synthetic/new ' name"), "/remote".into())
        );
    }
}
