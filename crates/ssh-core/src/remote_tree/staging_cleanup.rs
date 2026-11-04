//! Explicit cleanup of one inventoried staging pathname. The task owner must
//! exclude transfer/resume/edit operations and persist each callback atomically.
use super::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum StagingCleanupState {
    Prepared,
    RemoveIntent,
    Retired,
    ReleasedUnknown,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StagingCleanup {
    version: u32,
    staging_id: String,
    pub index: usize,
    pub path: String,
    original: StagingPhase,
    size: Option<u64>,
    permissions: Option<u32>,
    pub state: StagingCleanupState,
}
impl StagingCleanup {
    pub fn bytes(&self) -> Option<u64> {
        self.size
    }
    pub fn missing(&self) -> bool {
        self.size.is_none()
    }
    pub fn uncertain_operation(&self) -> bool {
        matches!(
            self.original,
            StagingPhase::Intent | StagingPhase::Direct { .. } | StagingPhase::Publishing
        )
    }
    pub fn validate(&self, plan: &RemoteTree) -> Result<()> {
        plan.validate()?;
        if self.version != 1
            || self.staging_id != plan.staging_id
            || self.index >= plan.nodes.len()
            || self.path != plan.staging_path(self.index)?
            || plan.nodes[self.index].kind != NodeKind::File
            || self.original == StagingPhase::Absent
            || self.size.is_some() != self.permissions.is_some()
        {
            return Err(RemoteTreeError::InvalidPlan);
        }
        if self.state != StagingCleanupState::Retired && plan.stages[self.index] != self.original {
            return Err(RemoteTreeError::InvalidPlan);
        }
        Ok(())
    }
}
async fn metadata(target: &SftpSession, path: &str) -> Result<Option<(u64, u32)>> {
    match target.symlink_metadata(path).await {
        Ok(attrs) if attrs.is_regular() && !attrs.is_symlink() => {
            let size = attrs.size.ok_or(RemoteTreeError::Uncertain)?;
            let permissions = attrs.permissions.ok_or(RemoteTreeError::Uncertain)?;
            if permissions & 0o077 != 0 || permissions & 0o600 != 0o600 {
                return Err(RemoteTreeError::Uncertain);
            }
            Ok(Some((size, permissions)))
        }
        Ok(_) => Err(RemoteTreeError::Uncertain),
        Err(SftpError::Status(status)) if status.status_code == StatusCode::NoSuchFile => Ok(None),
        Err(error) => Err(error.into()),
    }
}
impl RemoteTree {
    /// Reads only the application's exact random staging name. Does not adopt,
    /// delete, mark copied, follow a final link, or infer a missing rename ACK.
    pub async fn prepare_staging_cleanup(
        &self,
        index: usize,
        target: &SftpSession,
        stop: &CancellationToken,
    ) -> Result<StagingCleanup> {
        self.validate()?;
        let node = self.nodes.get(index).ok_or(RemoteTreeError::InvalidPlan)?;
        let original = *self.stages.get(index).ok_or(RemoteTreeError::InvalidPlan)?;
        if node.kind != NodeKind::File
            || original == StagingPhase::Absent
            || node.state == NodeState::Complete
        {
            return Err(RemoteTreeError::InvalidPlan);
        }
        let path = self.staging_path(index)?;
        let observed = cancellable(stop, async {
            guard_parent(target, &path).await?;
            metadata(target, &path).await
        })
        .await?;
        Ok(StagingCleanup {
            version: 1,
            staging_id: self.staging_id.clone(),
            index,
            path,
            original,
            size: observed.map(|(size, _)| size),
            permissions: observed.map(|(_, permissions)| permissions),
            state: StagingCleanupState::Prepared,
        })
    }

    /// The caller's explicit confirmation includes uncertainty about a lost
    /// CREATE/publish ACK. Size/permissions are stale-view checks, NOT identity
    /// proofs. There is no automatic retry after RemoveIntent, even if absent.
    pub async fn cleanup_staging(
        &mut self,
        review: &mut StagingCleanup,
        target: &SftpSession,
        allow_uncertain: bool,
        stop: &CancellationToken,
        mut checkpoint: impl FnMut(&Self, &StagingCleanup) -> Result<()>,
    ) -> Result<()> {
        review.validate(self)?;
        if review.state == StagingCleanupState::Retired {
            return checkpoint(self, review).map_err(|_| RemoteTreeError::Checkpoint);
        }
        if review.state != StagingCleanupState::Prepared
            || (review.uncertain_operation() && !allow_uncertain)
        {
            return Err(RemoteTreeError::Uncertain);
        }
        cancellable(stop, async {
            guard_parent(target, &review.path).await?;
            let current = metadata(target, &review.path).await?;
            if current != review.size.zip(review.permissions) {
                return Err(RemoteTreeError::Uncertain);
            }
            Ok(())
        })
        .await?;
        review.state = StagingCleanupState::RemoveIntent;
        checkpoint(self, review).map_err(|_| RemoteTreeError::Checkpoint)?;
        stopped(stop)?;
        if review.size.is_some() {
            cancellable(stop, async {
                target.remove_file(&review.path).await?;
                Ok(())
            })
            .await?;
        }
        // Missing on an explicit review only retires the reference; it does not
        // claim the old CREATE/rename/remove request succeeded.
        review.state = StagingCleanupState::Retired;
        if review.original != StagingPhase::Published {
            let node = &mut self.nodes[review.index];
            node.started = false;
            node.acknowledged = 0;
            node.state = NodeState::Failed;
            node.error = Some("暂存引用已明确清理，原始来源保留；需要显式重试复制".into());
            node.default_policy_pending = false;
            self.stages[review.index] = StagingPhase::Absent;
        } else {
            // Publication was already durably acknowledged; only its private
            // snapshot cleanup remained. Do not rewrite the final destination.
            self.nodes[review.index].state = NodeState::Complete;
            self.nodes[review.index].error = None;
        }
        checkpoint(self, review).map_err(|_| RemoteTreeError::Checkpoint)
    }
}
