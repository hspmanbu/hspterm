//! Compact, monotonic source retirement after a fully acknowledged copy. The
//! owner binds both actual endpoints, excludes editing and persists each
//! checkpoint atomically. Unknown REMOVE/RMDIR is never retried or inferred.
use super::*;
use sha2::{Digest, Sha256};

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceRetirement {
    version: u32,
    staging_id: String,
    plan: [u8; 32],
    nodes: usize,
    next: usize,
    intent: Option<usize>,
    ended_unknown: bool,
}
fn text(hash: &mut Sha256, value: &str) {
    hash.update((value.len() as u64).to_le_bytes());
    hash.update(value.as_bytes());
}
fn fingerprint(plan: &RemoteTree) -> [u8; 32] {
    // Stable, versioned metadata projection, not JSON serialization of future
    // optional fields and never a content hash of the user's files.
    let mut hash = Sha256::new();
    hash.update(b"HSPTerm source retirement plan v1\0");
    text(&mut hash, &plan.source);
    text(&mut hash, &plan.destination);
    text(&mut hash, &plan.staging_id);
    hash.update((plan.nodes.len() as u64).to_le_bytes());
    for node in &plan.nodes {
        text(&mut hash, &node.relative);
        hash.update([match node.kind {
            NodeKind::File => 0,
            NodeKind::Directory => 1,
            NodeKind::Unsupported => 2,
        }]);
        hash.update(node.size.to_le_bytes());
        match &node.destination_name {
            None => hash.update([0]),
            Some(name) => {
                hash.update([1]);
                text(&mut hash, name);
            }
        }
    }
    hash.finalize().into()
}
fn copied(plan: &RemoteTree) -> Result<()> {
    plan.validate()?;
    if plan.source == "/"
        || plan.nodes.iter().enumerate().any(|(i, n)| {
            n.state != NodeState::Complete
                || n.kind == NodeKind::Unsupported
                || (n.kind == NodeKind::File
                    && (plan.stages[i] != StagingPhase::Published || n.acknowledged != n.size))
        })
    {
        return Err(RemoteTreeError::SourceCopyIncomplete);
    }
    Ok(())
}
fn order(plan: &RemoteTree) -> Vec<usize> {
    let mut indices: Vec<_> = (0..plan.nodes.len()).collect();
    // All children precede their parent, even when a failed subtree was
    // rescanned and its discoveries appended instead of traversed in DFS order.
    indices.sort_unstable_by_key(|i| {
        let path = &plan.nodes[*i].relative;
        (
            std::cmp::Reverse(
                path.bytes().filter(|b| *b == b'/').count() + usize::from(!path.is_empty()),
            ),
            *i,
        )
    });
    indices
}
impl SourceRetirement {
    pub fn new(plan: &RemoteTree) -> Result<Self> {
        copied(plan)?;
        Ok(Self {
            version: 1,
            staging_id: plan.staging_id.clone(),
            plan: fingerprint(plan),
            nodes: plan.nodes.len(),
            next: 0,
            intent: None,
            ended_unknown: false,
        })
    }
    pub fn confirmed(&self) -> usize {
        self.next
    }
    pub fn total(&self) -> usize {
        self.nodes
    }
    pub fn uncertain_index(&self) -> Option<usize> {
        self.intent
    }
    pub fn ended_unknown(&self) -> bool {
        self.ended_unknown
    }
    pub fn complete(&self) -> bool {
        self.next == self.nodes && self.intent.is_none() && !self.ended_unknown
    }
    /// Cheap structure check for owner-controlled metadata-only progress writes.
    /// This does not authorize IO; start/recovery must call validate(plan).
    pub fn validate_metadata(&self, staging_id: &str, nodes: usize) -> Result<()> {
        if self.version != 1
            || self.staging_id != staging_id
            || self.nodes != nodes
            || nodes == 0
            || self.next > nodes
            || (self.ended_unknown && self.intent.is_none())
            || self
                .intent
                .is_some_and(|index| index >= nodes || self.next >= nodes)
        {
            return Err(RemoteTreeError::InvalidPlan);
        }
        Ok(())
    }
    pub fn validate(&self, plan: &RemoteTree) -> Result<()> {
        copied(plan)?;
        self.validate_metadata(&plan.staging_id, plan.nodes.len())?;
        if self.plan != fingerprint(plan) {
            return Err(RemoteTreeError::InvalidPlan);
        }
        if let Some(index) = self.intent
            && (self.next >= self.nodes || order(plan)[self.next] != index)
        {
            return Err(RemoteTreeError::InvalidPlan);
        }
        Ok(())
    }
    /// Local audit only. Neither success nor permission to send a second
    /// destructive request. The original intent/path remains inventoried.
    pub fn end_waiting(
        &mut self,
        plan: &RemoteTree,
        mut checkpoint: impl FnMut(&Self) -> Result<()>,
    ) -> Result<()> {
        self.validate(plan)?;
        if self.intent.is_none() || self.ended_unknown {
            return Err(RemoteTreeError::SourceRetirementUncertain);
        }
        self.ended_unknown = true;
        checkpoint(self).map_err(|_| RemoteTreeError::Checkpoint)
    }
}
impl RemoteTree {
    /// Delete only the original source tree, after EVERY node completed its
    /// copy. No links, partial-copy cleanup, guessed missing-file success or
    /// replay of an unknown request. This never writes/deletes the destination.
    /// Size/type checks catch stale views, not file identity races. The owner
    /// must show that risk at explicit cross-server move confirmation.
    pub async fn retire_copied_sources(
        &self,
        ledger: &mut SourceRetirement,
        source: &SftpSession,
        stop: &CancellationToken,
        mut checkpoint: impl FnMut(&SourceRetirement) -> Result<()>,
    ) -> Result<()> {
        ledger.validate(self)?;
        if ledger.intent.is_some() || ledger.ended_unknown {
            return Err(RemoteTreeError::SourceRetirementUncertain);
        }
        if ledger.complete() {
            return checkpoint(ledger).map_err(|_| RemoteTreeError::Checkpoint);
        }
        let indices = order(self);
        while ledger.next < indices.len() {
            if stop.is_cancelled() {
                return Err(RemoteTreeError::SourceRetirementStopped);
            }
            let index = indices[ledger.next];
            let node = &self.nodes[index];
            let path = join(&self.source, &node.relative);
            cancellable(stop, async {
                guard_parent(source, &path).await?;
                let attrs = source.symlink_metadata(&path).await?;
                if attrs.is_symlink()
                    || match node.kind {
                        NodeKind::File => !attrs.is_regular() || attrs.size != Some(node.size),
                        NodeKind::Directory => !attrs.is_dir(),
                        NodeKind::Unsupported => true,
                    }
                {
                    return Err(RemoteTreeError::SourceChanged);
                }
                Ok(())
            })
            .await
            .map_err(|error| {
                if matches!(error, RemoteTreeError::Cancelled) {
                    RemoteTreeError::SourceRetirementStopped
                } else {
                    error
                }
            })?;
            ledger.intent = Some(index);
            checkpoint(ledger).map_err(|_| RemoteTreeError::Checkpoint)?;
            if stop.is_cancelled() {
                return Err(RemoteTreeError::SourceRetirementUncertain);
            }
            cancellable(stop, async {
                match node.kind {
                    NodeKind::File => source.remove_file(&path).await?,
                    NodeKind::Directory => source.remove_dir(&path).await?,
                    NodeKind::Unsupported => return Err(RemoteTreeError::SourceKind),
                }
                Ok(())
            })
            .await
            .map_err(|_| RemoteTreeError::SourceRetirementUncertain)?;
            ledger.next += 1;
            ledger.intent = None;
            checkpoint(ledger).map_err(|_| RemoteTreeError::Checkpoint)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn postorder_remains_stable_for_appended_descendants() {
        use crate::tree_transfer::TransferNode;
        let mut plan = RemoteTree {
            version: 1,
            source: "/source".into(),
            destination: "/target".into(),
            staging_id: "0123456789abcdef0123456789abcdef".into(),
            stages: vec![StagingPhase::Absent; 5],
            nodes: Vec::new(),
        };
        for relative in ["", "a", "b", "a/child", "a/child/grandchild"] {
            plan.nodes.push(TransferNode {
                relative: relative.into(),
                kind: NodeKind::Directory,
                size: 0,
                acknowledged: 0,
                started: false,
                state: NodeState::Complete,
                decision: ConflictDecision::Ask,
                destination_name: None,
                error: None,
                default_policy_pending: false,
            });
        }
        let ledger = SourceRetirement::new(&plan).unwrap();
        assert_eq!(order(&plan), [4, 3, 1, 2, 0]);
        ledger.validate(&plan).unwrap();
        plan.nodes[2].relative = "changed".into();
        assert!(ledger.validate(&plan).is_err());
    }
}
