//! One owned file operation, shared by sequential and parallel coordinators.
//! Paths retain the original manifest index; no one-file sub-plan renumbering.
use super::*;

pub(super) struct FileWork {
    pub node: TransferNode,
    pub phase: StagingPhase,
    source: String,
    destination: String,
    staged: String,
}
impl FileWork {
    pub fn new(plan: &RemoteTree, index: usize) -> Result<Self> {
        Ok(Self {
            node: plan
                .nodes
                .get(index)
                .ok_or(RemoteTreeError::InvalidPlan)?
                .clone(),
            phase: *plan.stages.get(index).ok_or(RemoteTreeError::InvalidPlan)?,
            source: join(&plan.source, &plan.nodes[index].relative),
            destination: plan.destination_path(index)?,
            staged: plan.staging_path(index)?,
        })
    }
    pub fn apply(&self, plan: &mut RemoteTree, index: usize) {
        plan.nodes[index] = self.node.clone();
        plan.stages[index] = self.phase;
    }
    async fn confirm_direct(
        &mut self,
        target: &SftpSession,
        stop: &CancellationToken,
    ) -> Result<()> {
        let attrs = cancellable(stop, async {
            Ok(target.symlink_metadata(&self.staged).await?)
        })
        .await?;
        if !attrs.is_regular()
            || attrs.is_symlink()
            || attrs.size != Some(self.node.size)
            || attrs.permissions.is_none_or(|p| p & 0o777 != 0o600)
        {
            return Err(RemoteTreeError::DirectUncertain);
        }
        self.node.started = true;
        self.node.acknowledged = self.node.size;
        self.phase = StagingPhase::Ready;
        Ok(())
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn run(
        &mut self,
        source: &SftpSession,
        target: &SftpSession,
        stop: &CancellationToken,
        upload: &BandwidthLimiter,
        download: &BandwidthLimiter,
        notify: &mut impl FnMut(&Self) -> Result<()>,
    ) -> Result<()> {
        self.run_with_direct(source, target, stop, upload, download, None, notify)
            .await
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn run_with_direct(
        &mut self,
        source: &SftpSession,
        target: &SftpSession,
        stop: &CancellationToken,
        upload: &BandwidthLimiter,
        download: &BandwidthLimiter,
        direct: Option<&crate::direct_transfer::DirectRoute>,
        notify: &mut impl FnMut(&Self) -> Result<()>,
    ) -> Result<()> {
        let source_path = self.source.clone();
        let target_path = self.destination.clone();
        let staged = self.staged.clone();
        if staged == source_path || staged == target_path {
            return Err(RemoteTreeError::InvalidPlan);
        }
        cancellable(stop, guard_parent(target, &target_path)).await?;
        let phase = self.phase;
        if phase != StagingPhase::Published
            && self.node.decision == ConflictDecision::Skip
            && cancellable(stop, exists(target, &target_path)).await?
        {
            self.node.state = NodeState::Skipped;
            return Ok(());
        }
        if phase == StagingPhase::Absent {
            let existing = cancellable(stop, exists(target, &target_path)).await?;
            if existing {
                match self.node.decision {
                    ConflictDecision::Skip => {
                        self.node.state = NodeState::Skipped;
                        return Ok(());
                    }
                    ConflictDecision::Ask => {
                        return Err(RemoteTreeError::Copy(TransferError::Conflict.into()));
                    }
                    ConflictDecision::Overwrite => {}
                }
            }
            self.phase = StagingPhase::Intent;
            notify(self)?;
        }
        if let StagingPhase::Direct { nonce, attempt } = self.phase {
            use crate::direct_transfer::ReceiptStatus;
            let route = direct.ok_or(RemoteTreeError::DirectUnavailable)?;
            let receipt = route
                .inspect(&staged, self.node.size, &nonce, stop)
                .await
                .map_err(|_| {
                    if stop.is_cancelled() {
                        RemoteTreeError::Cancelled
                    } else {
                        RemoteTreeError::DirectUncertain
                    }
                })?;
            if receipt.attempt.is_some_and(|epoch| epoch > attempt) {
                return Err(RemoteTreeError::DirectUncertain);
            }
            match receipt.status {
                ReceiptStatus::Complete => {}
                ReceiptStatus::Partial | ReceiptStatus::Unclaimed => {
                    cancellable(stop, guard_parent(source, &source_path)).await?;
                    stopped(stop)?;
                    let next = attempt
                        .checked_add(1)
                        .ok_or(RemoteTreeError::DirectUncertain)?;
                    self.phase = StagingPhase::Direct {
                        nonce,
                        attempt: next,
                    };
                    // The next claim is durable first. Delayed older attempts
                    // cannot overwrite an already claimed/completed receipt.
                    notify(self)?;
                    route
                        .resume(
                            &source_path,
                            &staged,
                            self.node.size,
                            &nonce,
                            next,
                            receipt.attempt,
                            stop,
                        )
                        .await
                        .map_err(|_| {
                            if stop.is_cancelled() {
                                RemoteTreeError::Cancelled
                            } else {
                                RemoteTreeError::DirectUncertain
                            }
                        })?;
                }
                ReceiptStatus::Busy | ReceiptStatus::Unavailable => {
                    return Err(RemoteTreeError::DirectUncertain);
                }
            }
            self.confirm_direct(target, stop).await?;
            notify(self)?;
        }
        if matches!(self.phase, StagingPhase::Intent | StagingPhase::Writing) {
            cancellable(stop, guard_parent(source, &source_path)).await?;
            let mode = if self.phase == StagingPhase::Writing {
                RemoteCopyMode::Resume {
                    offset: self.node.acknowledged,
                }
            } else {
                // Never adopt an object after an unacknowledged OPEN, including
                // an old zero-byte private file with this unique pathname.
                if cancellable(stop, exists(target, &staged)).await? {
                    return Err(RemoteTreeError::Uncertain);
                }
                RemoteCopyMode::CreateNew
            };
            if let Some(route) = direct.filter(|route| {
                self.phase == StagingPhase::Intent && route.can_stage(&source_path, &staged)
            }) {
                stopped(stop)?;
                let nonce = rand::random::<[u8; 32]>();
                self.phase = StagingPhase::Direct { nonce, attempt: 1 };
                notify(self)?;
                route
                    .stage(
                        &source_path,
                        &staged,
                        self.node.size,
                        &nonce,
                        1,
                        target,
                        stop,
                    )
                    .await
                    .map_err(|_| {
                        if stop.is_cancelled() {
                            RemoteTreeError::Cancelled
                        } else {
                            RemoteTreeError::DirectUncertain
                        }
                    })?;
                self.confirm_direct(target, stop).await?;
                notify(self)?;
            } else {
                if direct.is_some_and(|r| !r.relay_permitted) {
                    return Err(RemoteTreeError::DirectUnavailable);
                }
                if let Some(route) = direct {
                    route.mark_relay();
                }
                let stream_stop = stop.child_token();
                let mut failed_checkpoint = false;
                let result = transfer::stage_remote_file_limited(
                    source,
                    &source_path,
                    target,
                    &staged,
                    mode,
                    &stream_stop,
                    upload,
                    download,
                    |p| {
                        self.phase = StagingPhase::Writing;
                        let node = &mut self.node;
                        node.started = true;
                        node.size = p.total;
                        node.acknowledged = p.acknowledged;
                        if notify(self).is_err() {
                            failed_checkpoint = true;
                            stream_stop.cancel();
                        }
                    },
                )
                .await;
                if failed_checkpoint {
                    return Err(RemoteTreeError::Checkpoint);
                }
                match result {
                    Ok(_) => {
                        self.phase = StagingPhase::Ready;
                        notify(self)?;
                    }
                    Err(RemoteCopyError::Transfer(TransferError::Cancelled)) => {
                        return Err(RemoteTreeError::Cancelled);
                    }
                    Err(error) => return Err(error.into()),
                }
            }
        }
        if matches!(self.phase, StagingPhase::Ready | StagingPhase::Publishing) {
            stopped(stop)?;
            // Persist this barrier before the destructive remote request.
            self.phase = StagingPhase::Publishing;
            notify(self)?;
            let overwrite = self.node.decision == ConflictDecision::Overwrite;
            let size = self.node.size;
            let publish = transfer::publish_staged_remote_file(
                target,
                &staged,
                &target_path,
                size,
                overwrite,
                stop,
            )
            .await;
            match publish {
                Ok(RemotePublishResult::Published) => {}
                Ok(RemotePublishResult::AtomicReplacementUnsupported) => {
                    if direct.is_some_and(|r| !r.relay_permitted) {
                        // The explicit capability response guarantees no write.
                        // Keep a known complete snapshot rather than inventing
                        // an unknown publish or violating the no-relay policy.
                        self.phase = StagingPhase::Ready;
                        notify(self)?;
                        return Err(RemoteTreeError::RelayRequired);
                    }
                    if let Some(route) = direct {
                        route.mark_relay();
                    }
                    let result = transfer::overwrite_from_staged_remote_file(
                        target,
                        &staged,
                        &target_path,
                        size,
                        stop,
                        upload,
                        download,
                        |_| {},
                    )
                    .await;
                    match result {
                        Ok(_) => {}
                        Err(RemoteCopyError::Transfer(TransferError::Cancelled)) => {
                            return Err(RemoteTreeError::Cancelled);
                        }
                        Err(error) => return Err(error.into()),
                    }
                }
                Err(RemoteCopyError::PublishCancelled) => return Err(RemoteTreeError::Cancelled),
                Err(error) => return Err(error.into()),
            }
            self.phase = StagingPhase::Published;
            notify(self)?;
        }
        if self.phase == StagingPhase::Published {
            stopped(stop)?;
            // POSIX rename consumes the staging entry. Streaming fallback does
            // not, so clean only the known snapshot after the durable ACK.
            let cleanup = async {
                if exists(target, &staged).await? {
                    let attrs = target.symlink_metadata(&staged).await?;
                    if !attrs.is_regular()
                        || attrs.is_symlink()
                        || attrs.size != Some(self.node.size)
                        || attrs
                            .permissions
                            .is_none_or(|p| p & 0o077 != 0 || p & 0o600 != 0o600)
                    {
                        return Err(RemoteTreeError::Uncertain);
                    }
                    target.remove_file(&staged).await?;
                }
                Ok(())
            };
            cancellable(stop, cleanup).await?;
        }
        Ok(())
    }
}
