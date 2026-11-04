//! Versioned metadata and bounded node chunks. Runtime progress updates only
//! dirty chunks; structural decisions always replace the full durable plan.
use super::*;
use hspterm_ssh_core::tree_transfer::TransferNode;
use hspterm_storage_sync::local_tasks::{MAX_CHECKPOINT, TaskCheckpoint};
use std::collections::BTreeSet;

pub(super) const NODES_PER_PART: usize = 256;
const MAX_NODES: usize = 1_000_000;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Metadata {
    version: u32,
    header: Header,
    tree: Option<PlanMetadata>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PlanMetadata {
    version: u32,
    direction: Direction,
    local: PathBuf,
    remote: String,
    nodes: usize,
}
pub(super) struct Encoded {
    pub metadata: Zeroizing<Vec<u8>>,
    pub parts: Vec<(usize, Zeroizing<Vec<u8>>)>,
}
impl Encoded {
    pub fn encode(
        header: &Header,
        plan: Option<&TreeTransfer>,
        dirty: Option<&BTreeSet<usize>>,
    ) -> Result<Self> {
        if plan.is_some_and(|p| p.nodes.is_empty() || p.nodes.len() > MAX_NODES)
            || (plan.is_none() && dirty.is_some())
        {
            bail!("检查点清单节点数量无效");
        }
        let metadata = Zeroizing::new(serde_json::to_vec(&Metadata {
            version: 1,
            header: header.clone(),
            tree: plan.map(|p| PlanMetadata {
                version: p.version,
                direction: p.direction,
                local: p.local.clone(),
                remote: p.remote.clone(),
                nodes: p.nodes.len(),
            }),
        })?);
        let mut bytes = metadata.len();
        let mut parts = Vec::new();
        if let Some(plan) = plan {
            let indices = dirty
                .cloned()
                .unwrap_or_else(|| (0..plan.nodes.len().div_ceil(NODES_PER_PART)).collect());
            for index in indices {
                let start = index
                    .checked_mul(NODES_PER_PART)
                    .context("检查点块序号溢出")?;
                let end = start.saturating_add(NODES_PER_PART).min(plan.nodes.len());
                if start >= end {
                    bail!("检查点块已不存在");
                }
                let raw = Zeroizing::new(serde_json::to_vec(&plan.nodes[start..end])?);
                bytes = bytes.checked_add(raw.len()).context("检查点大小溢出")?;
                if bytes > MAX_CHECKPOINT {
                    bail!("本机传输状态超过安全容量；原检查点未修改");
                }
                parts.push((index, raw));
            }
        }
        Ok(Self { metadata, parts })
    }
    pub fn replace(&self, vault: &mut hspterm_storage_sync::Vault, id: &str) -> Result<()> {
        LocalTaskJournal::new(vault).replace_parts(
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
    pub fn patch(&self, vault: &mut hspterm_storage_sync::Vault, id: &str) -> Result<()> {
        LocalTaskJournal::new(vault).update_parts(
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

pub(super) fn decode(value: TaskCheckpoint) -> Result<(Header, Option<TreeTransfer>)> {
    let (metadata, parts) = match value {
        TaskCheckpoint::Legacy(raw) => {
            return serde_json::from_slice(&raw).context("旧任务检查点格式无效");
        }
        TaskCheckpoint::Partitioned { metadata, parts } => (metadata, parts),
    };
    let metadata: Metadata = serde_json::from_slice(&metadata).context("任务元数据格式无效")?;
    if metadata.version != 1 {
        bail!("不支持的任务检查点版本");
    }
    let plan = if let Some(tree) = metadata.tree {
        if tree.nodes == 0
            || tree.nodes > MAX_NODES
            || parts.len() != tree.nodes.div_ceil(NODES_PER_PART)
        {
            bail!("任务检查点节点或分块数量无效");
        }
        let mut nodes = Vec::with_capacity(tree.nodes);
        for part in parts {
            let chunk: Vec<TransferNode> =
                serde_json::from_slice(&part).context("任务分块格式无效")?;
            if chunk.len() != NODES_PER_PART.min(tree.nodes - nodes.len()) {
                bail!("任务分块节点数量无效");
            }
            nodes.extend(chunk);
        }
        Some(TreeTransfer {
            version: tree.version,
            direction: tree.direction,
            local: tree.local,
            remote: tree.remote,
            nodes,
        })
    } else {
        if !parts.is_empty() {
            bail!("扫描中的任务不能包含旧清单分块");
        }
        None
    };
    Ok((metadata.header, plan))
}

/// Cache-protection only. A root header remains protected even if a body chunk
/// is missing. Never feed this into task execution without full load/validate.
pub(super) fn protected_local_reference(
    vault: &mut hspterm_storage_sync::Vault,
    id: &str,
) -> Result<PathBuf> {
    use hspterm_storage_sync::local_tasks::CheckpointMetadata;
    let metadata = LocalTaskJournal::new(vault)
        .load_metadata(id)?
        .context("任务检查点已不存在")?;
    let header = match metadata {
        CheckpointMetadata::Legacy(raw) => {
            let (header, _): (Header, serde::de::IgnoredAny) =
                serde_json::from_slice(&raw).context("旧任务检查点格式无效")?;
            header
        }
        CheckpointMetadata::Partitioned(raw) => {
            let metadata: Metadata = serde_json::from_slice(&raw).context("任务元数据格式无效")?;
            if metadata.version != 1 {
                bail!("不支持的任务检查点版本");
            }
            metadata.header
        }
    };
    if header.version != 1 || header.id != id || !header.local.is_absolute() {
        bail!("任务检查点格式或版本无效");
    }
    Ok(header.local)
}

#[cfg(test)]
mod tests {
    use super::*;
    use hspterm_storage_sync::Vault;
    #[test]
    fn cache_reference_reads_header_without_authorizing_missing_body_resume() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &temp.path().join("cache-reference.vault"),
            b"synthetic-cache-reference",
        )
        .unwrap();
        let (header, plan) = fixture(2);
        Encoded::encode(&header, Some(&plan), None)
            .unwrap()
            .replace(&mut vault, &header.id)
            .unwrap();
        vault
            .delete(&format!("local-transfer-{}-part-0", header.id))
            .unwrap();
        assert_eq!(
            protected_local_reference(&mut vault, &header.id).unwrap(),
            header.local
        );
        assert!(
            LocalTaskJournal::new(&mut vault)
                .load_parts(&header.id)
                .is_err()
        );
    }

    fn fixture(count: usize) -> (Header, TreeTransfer) {
        let local = std::env::temp_dir().join("hspterm-checkpoint-fixture");
        let remote = "/checkpoint-fixture".to_owned();
        let header = Header {
            export_name: None,
            version: 1,
            id: "task-00000000000000000000000000000009".into(),
            target: Target {
                host_id: "host-fixture".into(),
                address: "fixture.invalid".into(),
                port: 22,
                username: "fixture".into(),
                fingerprint: "fixture-fingerprint".into(),
            },
            local: local.clone(),
            remote: remote.clone(),
            upload: true,
            state: State::Running,
            error: None,
            rescan: vec![],
            rename_conflicts: false,
            default_conflict: DefaultConflict::Ask,
        };
        let plan = TreeTransfer {
            version: 1,
            direction: Direction::Upload,
            local,
            remote,
            nodes: (0..count)
                .map(|i| TransferNode {
                    relative: if i == 0 {
                        String::new()
                    } else {
                        format!("file-{i:06}")
                    },
                    kind: if i == 0 {
                        NodeKind::Directory
                    } else {
                        NodeKind::File
                    },
                    size: if i == 0 { 0 } else { 4096 },
                    acknowledged: 0,
                    started: false,
                    state: NodeState::Pending,
                    decision: ConflictDecision::Ask,
                    destination_name: None,
                    error: None,
                    default_policy_pending: true,
                })
                .collect(),
        };
        (header, plan)
    }
    #[test]
    fn partitioned_roundtrip_dirty_patch_legacy_upgrade_and_structural_replacement() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &temp.path().join("chunks.vault"),
            b"test-only-chunk-checkpoint",
        )
        .unwrap();
        let (mut header, mut plan) = fixture(700);
        plan.validate().unwrap();
        // An old installed checkpoint is readable and upgrades on its next save.
        let legacy = serde_json::to_vec(&(&header, Some(&plan))).unwrap();
        LocalTaskJournal::new(&mut vault)
            .save(&header.id, &legacy)
            .unwrap();
        let (_, old) = decode(
            LocalTaskJournal::new(&mut vault)
                .load_parts(&header.id)
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(old.unwrap().nodes.len(), 700);
        let full = Encoded::encode(&header, Some(&plan), None).unwrap();
        assert_eq!(full.parts.len(), 3);
        full.replace(&mut vault, &header.id).unwrap();
        plan.nodes[300].acknowledged = 128;
        plan.nodes[300].started = true;
        plan.nodes[511].state = NodeState::Skipped;
        header.state = State::Paused;
        let patch = Encoded::encode(&header, Some(&plan), Some(&BTreeSet::from([1]))).unwrap();
        assert_eq!(patch.parts.len(), 1);
        patch.patch(&mut vault, &header.id).unwrap();
        let (saved, restored) = decode(
            LocalTaskJournal::new(&mut vault)
                .load_parts(&header.id)
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        let restored = restored.unwrap();
        restored.validate().unwrap();
        assert_eq!(saved.state, State::Paused);
        assert!(saved.target == header.target);
        assert_eq!(
            serde_json::to_vec(&restored).unwrap(),
            serde_json::to_vec(&plan).unwrap()
        );
        assert!(
            Encoded::encode(&header, Some(&plan), Some(&BTreeSet::from([usize::MAX]))).is_err()
        );
        // Rescanning starts from metadata only; old tail chunks must disappear.
        Encoded::encode(&header, None, None)
            .unwrap()
            .replace(&mut vault, &header.id)
            .unwrap();
        let (_, restored) = decode(
            LocalTaskJournal::new(&mut vault)
                .load_parts(&header.id)
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        assert!(restored.is_none());
        for index in 0..3 {
            assert!(
                vault
                    .get(&format!("local-transfer-{}-part-{index}", header.id))
                    .unwrap()
                    .is_none()
            );
        }
    }

    #[test]
    fn malformed_node_counts_and_future_metadata_versions_are_rejected() {
        let (header, plan) = fixture(700);
        for bad in ["missing", "extra", "wrong count", "future", "no tree"] {
            let encoded = Encoded::encode(&header, Some(&plan), None).unwrap();
            let mut metadata: Metadata = serde_json::from_slice(&encoded.metadata).unwrap();
            let mut parts: Vec<_> = encoded.parts.into_iter().map(|(_, p)| p).collect();
            match bad {
                "missing" => {
                    parts.pop();
                }
                "extra" => {
                    parts.push(Zeroizing::new(b"[]".to_vec()));
                }
                "wrong count" => {
                    parts[0] = Zeroizing::new(b"[]".to_vec());
                }
                "future" => metadata.version = 2,
                "no tree" => metadata.tree = None,
                _ => unreachable!(),
            }
            assert!(
                decode(TaskCheckpoint::Partitioned {
                    metadata: Zeroizing::new(serde_json::to_vec(&metadata).unwrap()),
                    parts
                })
                .is_err(),
                "{bad}"
            );
        }
    }

    #[test]
    fn checkpoint_serialization_and_encrypted_commit_work_sample() {
        use std::{hint::black_box, time::Instant};
        const NODES: usize = 20_000;
        const EVENTS: usize = 8;
        let temp = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &temp.path().join("cost.vault"),
            b"test-only-checkpoint-cost",
        )
        .unwrap();
        let (header, mut plan) = fixture(NODES);
        LocalTaskJournal::new(&mut vault)
            .save(
                &header.id,
                &serde_json::to_vec(&(&header, Some(&plan))).unwrap(),
            )
            .unwrap();
        let legacy_key = format!("local-transfer-{}", header.id);
        let start = Instant::now();
        let mut full_bytes = 0;
        for i in 0..EVENTS {
            plan.nodes[1 + i * 997].acknowledged = 64;
            plan.nodes[1 + i * 997].started = true;
            let raw = Zeroizing::new(serde_json::to_vec(&(&header, Some(&plan))).unwrap());
            full_bytes += raw.len();
            // Reference the old algorithm directly. The compatibility writer
            // now also detects chunk roots and would add an extra whole-record
            // decrypt that was absent from the pre-partitioning implementation.
            let ids = LocalTaskJournal::new(&mut vault).list().unwrap();
            let inventory =
                serde_json::to_vec(&serde_json::json!({"version":1,"ids":ids})).unwrap();
            vault
                .put_many(&[("local-transfer-index-v1", &inventory), (&legacy_key, &raw)])
                .unwrap();
        }
        let full_us = start.elapsed().as_micros();
        let expected = serde_json::to_vec(&plan).unwrap();
        for node in &mut plan.nodes[1..] {
            node.acknowledged = 0;
            node.started = false;
        }
        // The mandatory initial full checkpoint is outside the periodic-update sample.
        let initial = Instant::now();
        Encoded::encode(&header, Some(&plan), None)
            .unwrap()
            .replace(&mut vault, &header.id)
            .unwrap();
        let initial_us = initial.elapsed().as_micros();
        let start = Instant::now();
        let mut patch_bytes = 0;
        for i in 0..EVENTS {
            let index = 1 + i * 997;
            plan.nodes[index].acknowledged = 64;
            plan.nodes[index].started = true;
            let encoded = Encoded::encode(
                &header,
                Some(&plan),
                Some(&BTreeSet::from([index / NODES_PER_PART])),
            )
            .unwrap();
            patch_bytes +=
                encoded.metadata.len() + encoded.parts.iter().map(|(_, p)| p.len()).sum::<usize>();
            encoded.patch(&mut vault, &header.id).unwrap();
            black_box(&encoded);
        }
        let patch_us = start.elapsed().as_micros();
        let (_, restored) = decode(
            LocalTaskJournal::new(&mut vault)
                .load_parts(&header.id)
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(serde_json::to_vec(&restored.unwrap()).unwrap(), expected);
        println!(
            "{{\"nodes\":{NODES},\"updates\":{EVENTS},\"full_serialized_bytes\":{full_bytes},\"patch_metadata_and_nodes_bytes\":{patch_bytes},\"full_encode_encrypt_commit_us\":{full_us},\"patch_encode_encrypt_commit_us\":{patch_us},\"initial_partitioned_encode_encrypt_commit_us\":{initial_us}}}"
        );
    }
}
