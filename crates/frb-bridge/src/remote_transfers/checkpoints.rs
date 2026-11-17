//! Distinct remote-task inventory; roots and 256-node chunks commit atomically.
use super::*;
use hspterm_ssh_core::tree_transfer::TransferNode;
use hspterm_storage_sync::{
    Vault,
    local_tasks::{MAX_CHECKPOINT, TaskCheckpoint},
};

pub(super) const NODES_PER_PART: usize = 256;
const MAX_NODES: usize = 1_000_000;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CopyMetadata {
    version: u32,
    header: CopyHeader,
    tree: Option<CopyPlanMetadata>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CopyPlanMetadata {
    version: u32,
    source: String,
    destination: String,
    staging_id: String,
    nodes: usize,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Node {
    entry: TransferNode,
    phase: StagingPhase,
}
pub(super) struct CopyEncoded {
    metadata: Zeroizing<Vec<u8>>,
    parts: Vec<(usize, Zeroizing<Vec<u8>>)>,
}
impl CopyEncoded {
    pub fn encode(
        header: &CopyHeader,
        plan: Option<&RemoteTree>,
        dirty: Option<&BTreeSet<usize>>,
    ) -> Result<Self> {
        validate_header(header)?;
        validate_operation(header, plan.is_some())?;
        if let Some(p) = plan {
            if p.nodes.is_empty()
                || p.nodes.len() > MAX_NODES
                || p.nodes.len() != p.stages.len()
                || p.source != header.source
                || p.destination != header.destination
                || p.staging_id != header.id[5..]
            {
                bail!("远端复制检查点根或节点无效");
            }
            // Full validation at structural barriers. Per-progress dirty writes
            // do not rescan the whole tree; mutations come from RemoteTree.
            if dirty.is_none() {
                p.validate()?;
            }
        } else if dirty.is_some() {
            bail!("空清单不能写入进度块");
        }
        validate_rescan(header, plan)?;
        validate_cleanup(header, plan)?;
        validate_retirement(header, plan, dirty.is_none())?;
        let metadata = Zeroizing::new(serde_json::to_vec(&CopyMetadata {
            version: 1,
            header: header.clone(),
            tree: plan.map(|p| CopyPlanMetadata {
                version: p.version,
                source: p.source.clone(),
                destination: p.destination.clone(),
                staging_id: p.staging_id.clone(),
                nodes: p.nodes.len(),
            }),
        })?);
        let mut bytes = metadata.len();
        let mut parts = Vec::new();
        if let Some(p) = plan {
            let indices = dirty
                .cloned()
                .unwrap_or_else(|| (0..p.nodes.len().div_ceil(NODES_PER_PART)).collect());
            for index in indices {
                let start = index
                    .checked_mul(NODES_PER_PART)
                    .context("复制检查点块溢出")?;
                let end = start.saturating_add(NODES_PER_PART).min(p.nodes.len());
                if start >= end {
                    bail!("复制检查点块不存在");
                }
                let nodes: Vec<_> = (start..end)
                    .map(|i| Node {
                        entry: p.nodes[i].clone(),
                        phase: p.stages[i],
                    })
                    .collect();
                let raw = Zeroizing::new(serde_json::to_vec(&nodes)?);
                bytes = bytes.checked_add(raw.len()).context("复制检查点容量溢出")?;
                if bytes > MAX_CHECKPOINT {
                    bail!("复制检查点超过设备容量，原状态未覆盖");
                }
                parts.push((index, raw));
            }
        }
        if bytes > MAX_CHECKPOINT {
            bail!("复制检查点超过设备容量");
        }
        Ok(Self { metadata, parts })
    }
    pub fn replace(&self, vault: &mut Vault, id: &str) -> Result<()> {
        LocalTaskJournal::remote_copies(vault).replace_parts(
            id,
            &self.metadata,
            &self
                .parts
                .iter()
                .map(|(_, p)| p.as_slice())
                .collect::<Vec<_>>(),
        )?;
        Ok(())
    }
    pub fn patch(&self, vault: &mut Vault, id: &str) -> Result<()> {
        LocalTaskJournal::remote_copies(vault).update_parts(
            id,
            &self.metadata,
            &self
                .parts
                .iter()
                .map(|(i, p)| (*i, p.as_slice()))
                .collect::<Vec<_>>(),
        )?;
        Ok(())
    }
}
fn validate_header(h: &CopyHeader) -> Result<()> {
    if h.version != 1
        || h.id.len() != 37
        || !h.id.starts_with("task-")
        || !h.id.as_bytes()[5..]
            .iter()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(c))
        || [&h.source, &h.destination]
            .iter()
            .any(|s| !s.starts_with('/') || s.contains('\0') || s.len() > 131072)
        || [&h.source_target, &h.destination_target].iter().any(|t| {
            t.host_id.is_empty()
                || t.address.is_empty()
                || t.port == 0
                || t.username.is_empty()
                || t.fingerprint.is_empty()
        })
    {
        bail!("远端复制任务头格式或实际端点身份无效");
    }
    Ok(())
}
fn validate_cleanup(header: &CopyHeader, plan: Option<&RemoteTree>) -> Result<()> {
    if header.cleanup_abandoned && header.operation == CopyOperation::Move {
        bail!("移动任务不能带复制暂存清理记录");
    }
    if let Some(cleanup) = &header.cleanup {
        if header.operation == CopyOperation::Move {
            bail!("移动任务不能带复制暂存清理记录");
        }
        cleanup.validate(plan.context("暂存清理记录缺少原复制清单")?)?;
    }
    Ok(())
}
fn validate_retirement(header: &CopyHeader, plan: Option<&RemoteTree>, full: bool) -> Result<()> {
    if let Some(ledger) = &header.source_retirement {
        let p = plan.context("来源清理缺少完整复制清单")?;
        if header.operation != CopyOperation::Relocate
            || !header.rescan.is_empty()
            || header.rename_conflicts
            || header.cleanup_abandoned
            || header.cleanup.is_some()
        {
            bail!("来源清理与任务操作或复制恢复意图不一致");
        }
        ledger.validate_metadata(&p.staging_id, p.nodes.len())?;
        if full {
            ledger.validate(p)?;
        }
    }
    if header.operation == CopyOperation::Relocate
        && (header.state == State::CompleteWithSkips
            || (header.state == State::Complete
                && header
                    .source_retirement
                    .as_ref()
                    .is_none_or(|s| !s.complete())))
    {
        bail!("来源尚未全部确认删除，不能标记移动完成");
    }
    Ok(())
}
fn validate_operation(h: &CopyHeader, has_tree: bool) -> Result<()> {
    if (h.operation == CopyOperation::Move
        && (has_tree || h.rename_conflicts || !h.rescan.is_empty()))
        || (h.operation != CopyOperation::Move
            && (h.move_phase != MovePhase::Pending || h.move_directory))
        || (h.operation == CopyOperation::Move
            && h.state == State::Complete
            && h.move_phase != MovePhase::Confirmed)
        || (h.operation == CopyOperation::Move
            && h.move_phase == MovePhase::UserEnded
            && h.state != State::Cancelled)
    {
        bail!("任务操作类型与清单或移动确认状态不一致");
    }
    Ok(())
}
fn validate_rescan(header: &CopyHeader, plan: Option<&RemoteTree>) -> Result<()> {
    if header.rescan.is_empty() {
        return Ok(());
    }
    let p = plan.context("重扫意图缺少原清单")?;
    if matches!(header.state, State::Complete | State::CompleteWithSkips)
        || header.rescan.len() > p.nodes.len()
    {
        bail!("目录重扫意图与任务完成状态或清单不一致");
    }
    let mut seen = BTreeSet::new();
    for index in &header.rescan {
        let node = p.nodes.get(*index as usize).context("重扫意图节点不存在")?;
        if !seen.insert(index) || node.kind == NodeKind::File || node.state != NodeState::Failed {
            bail!("目录重扫意图不是独立的失败目录/未发现项目");
        }
    }
    Ok(())
}
pub(super) fn decode(
    id: &str,
    checkpoint: TaskCheckpoint,
) -> Result<(CopyHeader, Option<RemoteTree>)> {
    let TaskCheckpoint::Partitioned { metadata, parts } = checkpoint else {
        bail!("不支持的远端复制检查点格式");
    };
    let m: CopyMetadata = serde_json::from_slice(&metadata).context("远端复制检查点格式无效")?;
    validate_header(&m.header)?;
    validate_operation(&m.header, m.tree.is_some())?;
    if m.version != 1 || m.header.id != id {
        bail!("远端复制检查点版本或ID不符");
    }
    let plan = if let Some(p) = m.tree {
        if p.nodes == 0 || p.nodes > MAX_NODES || parts.len() != p.nodes.div_ceil(NODES_PER_PART) {
            bail!("远端复制清单分块数量无效");
        }
        let mut nodes = Vec::with_capacity(p.nodes);
        let mut stages = Vec::with_capacity(p.nodes);
        for (i, raw) in parts.into_iter().enumerate() {
            let block: Vec<Node> = serde_json::from_slice(&raw).context("远端复制清单分块无效")?;
            if block.len() != (p.nodes - i * NODES_PER_PART).min(NODES_PER_PART) {
                bail!("远端复制清单分块长度不符");
            }
            for n in block {
                nodes.push(n.entry);
                stages.push(n.phase);
            }
        }
        let p = RemoteTree {
            version: p.version,
            source: p.source,
            destination: p.destination,
            staging_id: p.staging_id,
            nodes,
            stages,
        };
        p.validate()?;
        if p.source != m.header.source
            || p.destination != m.header.destination
            || p.staging_id != id[5..]
        {
            bail!("远端复制清单与任务身份不符");
        }
        Some(p)
    } else {
        if !parts.is_empty() {
            bail!("空清单不能包含分块");
        }
        None
    };
    validate_rescan(&m.header, plan.as_ref())?;
    validate_cleanup(&m.header, plan.as_ref())?;
    validate_retirement(&m.header, plan.as_ref(), true)?;
    Ok((m.header, plan))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (CopyHeader, RemoteTree) {
        let target = Target {
            host_id: "synthetic-host".into(),
            address: "127.0.0.1".into(),
            port: 22,
            username: "synthetic-user".into(),
            fingerprint: "synthetic-test-fingerprint".into(),
        };
        let h = CopyHeader {
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
            operation: CopyOperation::Copy,
            move_phase: MovePhase::Pending,
            move_directory: false,
            rescan: Vec::new(),
            cleanup: None,
            cleanup_abandoned: false,
            source_retirement: None,
            entries: Vec::new(),
        };
        let p = RemoteTree {
            version: 1,
            source: h.source.clone(),
            destination: h.destination.clone(),
            staging_id: h.id[5..].into(),
            nodes: (0..513)
                .map(|i| TransferNode {
                    relative: if i == 0 {
                        String::new()
                    } else {
                        format!("synthetic-file-{i}")
                    },
                    kind: if i == 0 {
                        NodeKind::Directory
                    } else {
                        NodeKind::File
                    },
                    size: if i == 0 { 0 } else { 8192 },
                    acknowledged: 0,
                    started: false,
                    state: NodeState::Pending,
                    decision: ConflictDecision::Ask,
                    destination_name: None,
                    error: None,
                    default_policy_pending: true,
                })
                .collect(),
            stages: vec![StagingPhase::Absent; 513],
        };
        (h, p)
    }
    fn copied_relocation() -> (CopyHeader, RemoteTree) {
        let (mut h, mut p) = fixture();
        h.operation = CopyOperation::Relocate;
        h.destination_target.port = 2222;
        for (i, node) in p.nodes.iter_mut().enumerate() {
            node.state = NodeState::Complete;
            node.started = node.kind == NodeKind::File;
            node.acknowledged = node.size;
            node.default_policy_pending = false;
            if node.kind == NodeKind::File {
                p.stages[i] = StagingPhase::Published;
            }
        }
        h.source_retirement =
            Some(hspterm_ssh_core::remote_tree::SourceRetirement::new(&p).unwrap());
        (h, p)
    }
    #[test]
    fn source_retirement_metadata_patch_preserves_all_copied_parts_and_unknown_intent() {
        let (mut h, p) = copied_relocation();
        let temp = tempfile::tempdir().unwrap();
        let mut v = Vault::create(
            &temp.path().join("synthetic-retirement.vault"),
            b"synthetic-retirement-master",
        )
        .unwrap();
        CopyEncoded::encode(&h, Some(&p), None)
            .unwrap()
            .replace(&mut v, &h.id)
            .unwrap();
        let before = LocalTaskJournal::remote_copies(&mut v)
            .load_parts(&h.id)
            .unwrap()
            .unwrap();
        let TaskCheckpoint::Partitioned {
            parts: original, ..
        } = before
        else {
            panic!("partitioned");
        };
        let mut ledger = serde_json::to_value(h.source_retirement.as_ref().unwrap()).unwrap();
        ledger["intent"] = serde_json::json!(1); // first child precedes root directory
        h.source_retirement = Some(serde_json::from_value(ledger).unwrap());
        h.state = State::Failed;
        let patch = CopyEncoded::encode(&h, Some(&p), Some(&BTreeSet::new())).unwrap();
        assert!(patch.parts.is_empty());
        assert!(patch.metadata.len() < 8192);
        patch.patch(&mut v, &h.id).unwrap();
        let after = LocalTaskJournal::remote_copies(&mut v)
            .load_parts(&h.id)
            .unwrap()
            .unwrap();
        let TaskCheckpoint::Partitioned { parts, .. } = &after else {
            panic!("partitioned");
        };
        assert_eq!(parts, &original);
        let (restored, copied) = decode(&h.id, after).unwrap();
        assert_eq!(copied.unwrap().nodes.len(), 513);
        assert_eq!(
            restored
                .source_retirement
                .as_ref()
                .unwrap()
                .uncertain_index(),
            Some(1)
        );
        assert!(check_move_resume(&restored, "continue").is_err());
        assert!(retain_checkpoint(&restored, Some(&p)));
    }
    #[test]
    fn source_retirement_codec_rejects_false_completion_rebinding_and_mutated_copy() {
        let (h, p) = copied_relocation();
        let mut bad = h.clone();
        bad.state = State::Complete;
        assert!(CopyEncoded::encode(&bad, Some(&p), None).is_err());
        bad.state = State::CompleteWithSkips;
        assert!(CopyEncoded::encode(&bad, Some(&p), None).is_err());
        bad = h.clone();
        bad.operation = CopyOperation::Copy;
        assert!(CopyEncoded::encode(&bad, Some(&p), None).is_err());
        bad = h.clone();
        bad.rescan = vec![0];
        assert!(CopyEncoded::encode(&bad, Some(&p), None).is_err());
        let mut changed = p.clone();
        changed.nodes[1].size += 1;
        changed.nodes[1].acknowledged += 1;
        assert!(CopyEncoded::encode(&h, Some(&changed), None).is_err());
        changed = p.clone();
        changed.nodes[1].state = NodeState::Skipped;
        assert!(CopyEncoded::encode(&h, Some(&changed), None).is_err());
        let encoded = CopyEncoded::encode(&h, Some(&p), None).unwrap();
        let mut metadata: serde_json::Value = serde_json::from_slice(&encoded.metadata).unwrap();
        metadata["header"]["source_retirement"]["intent"] = serde_json::json!(0);
        assert!(
            decode(
                &h.id,
                TaskCheckpoint::Partitioned {
                    metadata: Zeroizing::new(serde_json::to_vec(&metadata).unwrap()),
                    parts: encoded.parts.into_iter().map(|(_, b)| b).collect(),
                }
            )
            .is_err()
        );
    }
    #[test]
    fn cleanup_unknown_intent_is_durable_bound_to_the_original_staging_name_and_copy_only() {
        use hspterm_ssh_core::remote_tree::{StagingCleanup, StagingCleanupState};
        let (mut h, mut p) = fixture();
        p.stages[1] = StagingPhase::Writing;
        p.nodes[1].started = true;
        let original = serde_json::json!({"version": 1, "staging_id": p.staging_id,
            "index": 1, "path": p.staging_path(1).unwrap(), "original": "Writing",
            "size": 0, "permissions": 0o100600, "state": "RemoveIntent"});
        let cleanup: StagingCleanup = serde_json::from_value(original.clone()).unwrap();
        h.cleanup = Some(cleanup);
        let encoded = CopyEncoded::encode(&h, Some(&p), None).unwrap();
        let (decoded, plan) = decode(
            &h.id,
            TaskCheckpoint::Partitioned {
                metadata: encoded.metadata,
                parts: encoded.parts.into_iter().map(|(_, b)| b).collect(),
            },
        )
        .unwrap();
        assert!(
            decoded
                .cleanup
                .as_ref()
                .is_some_and(|c| c.state == StagingCleanupState::RemoveIntent)
        );
        assert!(check_move_resume(&decoded, "continue").is_err());
        assert!(retain_checkpoint(&decoded, plan.as_ref()));
        let mut foreign = original;
        foreign["path"] = serde_json::json!("/unrelated/private-file");
        h.cleanup = Some(serde_json::from_value(foreign).unwrap());
        assert!(CopyEncoded::encode(&h, Some(&p), None).is_err());
        h.cleanup = None;
        h.cleanup_abandoned = true;
        assert!(check_move_resume(&h, "continue").is_err());
        h.operation = CopyOperation::Move;
        assert!(CopyEncoded::encode(&h, None, None).is_err());
    }
    #[test]
    fn legacy_copy_headers_keep_their_operation_and_move_states_cannot_adopt_copy_trees() {
        let (h, p) = fixture();
        let encoded = CopyEncoded::encode(&h, Some(&p), None).unwrap();
        let mut metadata: serde_json::Value = serde_json::from_slice(&encoded.metadata).unwrap();
        let header = metadata["header"].as_object_mut().unwrap();
        for name in [
            "operation",
            "move_phase",
            "move_directory",
            "rescan",
            "relay_permitted",
            "direct_permitted",
        ] {
            header.remove(name);
        }
        let checkpoint = TaskCheckpoint::Partitioned {
            metadata: Zeroizing::new(serde_json::to_vec(&metadata).unwrap()),
            parts: encoded.parts.iter().map(|(_, p)| p.clone()).collect(),
        };
        let (legacy, plan) = decode(&h.id, checkpoint).unwrap();
        assert!(legacy.operation == CopyOperation::Copy && legacy.move_phase == MovePhase::Pending);
        assert!(legacy.rescan.is_empty());
        assert!(legacy.relay_permitted);
        assert!(!legacy.direct_permitted);
        assert_eq!(plan.unwrap().nodes.len(), 513);
        let mut mixed = h.clone();
        mixed.operation = CopyOperation::Move;
        assert!(CopyEncoded::encode(&mixed, Some(&p), None).is_err());
        mixed.state = State::Complete;
        assert!(CopyEncoded::encode(&mixed, None, None).is_err());
        mixed.move_phase = MovePhase::Confirmed;
        assert!(CopyEncoded::encode(&mixed, None, None).is_ok());
        mixed.move_phase = MovePhase::UserEnded;
        assert!(CopyEncoded::encode(&mixed, None, None).is_err());
        mixed.state = State::Cancelled;
        assert!(CopyEncoded::encode(&mixed, None, None).is_ok());
        mixed.state = State::Failed;
        assert!(CopyEncoded::encode(&mixed, None, None).is_err());
        mixed.state = State::Cancelled;
        mixed.operation = CopyOperation::Copy;
        assert!(CopyEncoded::encode(&mixed, None, None).is_err());
    }
    #[test]
    fn rescan_intent_roundtrips_and_rejects_files_duplicates_missing_nodes_and_move_tasks() {
        let (mut h, mut p) = fixture();
        p.nodes[0].state = NodeState::Failed;
        h.rescan = vec![0];
        let encoded = CopyEncoded::encode(&h, Some(&p), None).unwrap();
        let checkpoint = || TaskCheckpoint::Partitioned {
            metadata: encoded.metadata.clone(),
            parts: encoded.parts.iter().map(|(_, p)| p.clone()).collect(),
        };
        let (restored, _) = decode(&h.id, checkpoint()).unwrap();
        assert_eq!(restored.rescan, [0]);
        for indices in [vec![0, 0], vec![1], vec![513], vec![u32::MAX]] {
            let mut bad = h.clone();
            bad.rescan = indices.clone();
            assert!(CopyEncoded::encode(&bad, Some(&p), None).is_err());
            let mut metadata: serde_json::Value =
                serde_json::from_slice(&encoded.metadata).unwrap();
            metadata["header"]["rescan"] = serde_json::json!(indices);
            let invalid = TaskCheckpoint::Partitioned {
                metadata: Zeroizing::new(serde_json::to_vec(&metadata).unwrap()),
                parts: encoded.parts.iter().map(|(_, p)| p.clone()).collect(),
            };
            assert!(decode(&h.id, invalid).is_err());
        }
        assert!(CopyEncoded::encode(&h, None, None).is_err());
        h.rename_conflicts = true;
        // Independent pending metadata intents are ordered: source rescan is
        // published first, then the existing target rename intent is honored.
        assert!(CopyEncoded::encode(&h, Some(&p), None).is_ok());
        h.rename_conflicts = false;
        h.state = State::Complete;
        assert!(CopyEncoded::encode(&h, Some(&p), None).is_err());
        h.state = State::Paused;
        p.nodes[0].state = NodeState::Complete;
        assert!(CopyEncoded::encode(&h, Some(&p), None).is_err());
        h.operation = CopyOperation::Move;
        assert!(CopyEncoded::encode(&h, None, None).is_err());
    }
    #[test]
    fn remote_manifest_partitions_restore_both_endpoint_identities_and_patch_only_dirty_parts() {
        let (h, mut p) = fixture();
        let temp = tempfile::tempdir().unwrap();
        let mut v = Vault::create(
            &temp.path().join("synthetic-copy-parts.vault"),
            b"synthetic-copy-parts-password",
        )
        .unwrap();
        CopyEncoded::encode(&h, Some(&p), None)
            .unwrap()
            .replace(&mut v, &h.id)
            .unwrap();
        let checkpoint = LocalTaskJournal::remote_copies(&mut v)
            .load_parts(&h.id)
            .unwrap()
            .unwrap();
        let TaskCheckpoint::Partitioned { parts, .. } = &checkpoint else {
            panic!("partitioned");
        };
        assert_eq!(parts.len(), 3);
        let first = parts[0].to_vec();
        let (actual_h, actual) = decode(&h.id, checkpoint).unwrap();
        assert!(
            actual_h.source_target == h.source_target
                && actual_h.destination_target == h.destination_target
        );
        assert_eq!(actual.unwrap().nodes.len(), 513);
        p.nodes[257].started = true;
        p.nodes[257].acknowledged = 1024;
        p.stages[257] = StagingPhase::Writing;
        let dirty = BTreeSet::from([1]);
        CopyEncoded::encode(&h, Some(&p), Some(&dirty))
            .unwrap()
            .patch(&mut v, &h.id)
            .unwrap();
        let checkpoint = LocalTaskJournal::remote_copies(&mut v)
            .load_parts(&h.id)
            .unwrap()
            .unwrap();
        let TaskCheckpoint::Partitioned { parts, .. } = &checkpoint else {
            panic!("partitioned");
        };
        assert_eq!(parts[0].as_slice(), first);
        let (_, actual) = decode(&h.id, checkpoint).unwrap();
        let actual = actual.unwrap();
        assert_eq!(actual.nodes[257].acknowledged, 1024);
        assert_eq!(actual.stages[257], StagingPhase::Writing);
        assert!(LocalTaskJournal::new(&mut v).list().unwrap().is_empty());
    }
    #[test]
    fn direct_only_permission_survives_device_checkpoint_without_implicit_relay() {
        let (mut h, p) = fixture();
        h.relay_permitted = false;
        h.direct_permitted = true;
        let encoded = CopyEncoded::encode(&h, Some(&p), None).unwrap();
        let (restored, _) = decode(
            &h.id,
            TaskCheckpoint::Partitioned {
                metadata: encoded.metadata,
                parts: encoded.parts.into_iter().map(|(_, p)| p).collect(),
            },
        )
        .unwrap();
        assert!(!restored.relay_permitted);
        assert!(restored.direct_permitted);
    }
    #[test]
    fn malformed_remote_parts_do_not_become_empty_or_rebind_to_another_task() {
        let (h, p) = fixture();
        let encoded = CopyEncoded::encode(&h, Some(&p), None).unwrap();
        let checkpoint = || TaskCheckpoint::Partitioned {
            metadata: encoded.metadata.clone(),
            parts: encoded.parts.iter().map(|(_, p)| p.clone()).collect(),
        };
        assert!(decode("task-ffffffffffffffffffffffffffffffff", checkpoint()).is_err());
        let TaskCheckpoint::Partitioned {
            metadata,
            mut parts,
        } = checkpoint()
        else {
            panic!("partitioned");
        };
        parts.pop();
        assert!(decode(&h.id, TaskCheckpoint::Partitioned { metadata, parts }).is_err());
        let TaskCheckpoint::Partitioned {
            metadata,
            mut parts,
        } = checkpoint()
        else {
            panic!("partitioned");
        };
        parts.swap(0, 1);
        assert!(decode(&h.id, TaskCheckpoint::Partitioned { metadata, parts }).is_err());
        let mut future = h.clone();
        future.version = 2;
        assert!(CopyEncoded::encode(&future, Some(&p), None).is_err());
        let mut mismatch = p.clone();
        mismatch.staging_id = "ffffffffffffffffffffffffffffffff".into();
        assert!(CopyEncoded::encode(&h, Some(&mismatch), None).is_err());
        assert!(CopyEncoded::encode(&h, Some(&p), Some(&BTreeSet::from([3]))).is_err());
        assert!(
            decode(
                &h.id,
                TaskCheckpoint::Legacy(Zeroizing::new(b"other task schema".to_vec()))
            )
            .is_err()
        );
    }
}
