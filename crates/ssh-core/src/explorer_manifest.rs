//! A Windows virtual-file descriptor inventory, never a list of local URIs.
//! Built from the same immutable tree used by the download task. Includes every
//! parent and empty directory and fails atomically on unsupported names/types.
use crate::{
    local_path::windows_component_supported,
    tree_transfer::{Direction, NodeKind, NodeState, TreeTransfer},
};
use std::collections::HashSet;

// FILEDESCRIPTORW has 260 UTF-16 units including its terminating NUL. Limit the
// entire native descriptor allocation too (one descriptor is 592 bytes).
const MAX_NAME_UNITS: usize = 259;
pub const MAX_ENTRIES: usize = 32_768;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ManifestError {
    #[error("Explorer导出清单无效；必须重新明确发起下载")]
    InvalidPlan,
    #[error("Explorer不支持所选名称或完整相对路径；请使用下载并明确选择本地名称")]
    UnsupportedName,
    #[error("所选名称在Windows中重复；请分别下载")]
    NameCollision,
    #[error("导出包含链接、特殊文件或扫描失败项；未向Explorer发布部分清单")]
    UnsupportedNode,
    #[error("Explorer虚拟项目数量超出安全容量；请改用目录下载")]
    Capacity,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Descriptor {
    /// Index in the original task tree, not an independent file task.
    pub node_index: usize,
    /// Rooted at the selected basename, using Windows relative separators.
    pub name: String,
    pub directory: bool,
    pub bytes: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SelectionDescriptor {
    /// Original ordered selection, each root remains one independent task.
    pub root_index: usize,
    pub descriptor: Descriptor,
}

/// Validate the whole selection before registering any native provider. Limits
/// apply to the entire IDataObject, not separately to each selected folder.
pub fn selection_descriptors(
    roots: &[(&str, &TreeTransfer)],
) -> Result<Vec<SelectionDescriptor>, ManifestError> {
    if roots.is_empty() || roots.len() > 128 {
        return Err(ManifestError::Capacity);
    }
    let total = roots
        .iter()
        .try_fold(0usize, |total, (_, plan)| {
            total
                .checked_add(plan.nodes.len())
                .filter(|n| *n <= MAX_ENTRIES)
        })
        .ok_or(ManifestError::Capacity)?;
    let mut result = Vec::with_capacity(total);
    let mut seen = HashSet::new();
    for (root_index, (name, plan)) in roots.iter().enumerate() {
        for descriptor in descriptors(name, plan)? {
            if !seen.insert(descriptor.name.to_uppercase()) {
                return Err(ManifestError::NameCollision);
            }
            result.push(SelectionDescriptor {
                root_index,
                descriptor,
            });
        }
    }
    Ok(result)
}

fn component(name: &str) -> bool {
    name != "."
        && name != ".."
        && name.encode_utf16().count() <= 255
        && !name.contains('\u{7f}')
        && windows_component_supported(name)
}
pub fn validate_root_name(name: &str) -> Result<(), ManifestError> {
    if component(name) {
        Ok(())
    } else {
        Err(ManifestError::UnsupportedName)
    }
}

/// Pure projection: no SFTP calls, creation, reordering, truncation or renaming.
/// `root_name` comes from the frozen user selection, never a local cache path.
pub fn descriptors(root_name: &str, plan: &TreeTransfer) -> Result<Vec<Descriptor>, ManifestError> {
    if plan.nodes.len() > MAX_ENTRIES {
        return Err(ManifestError::Capacity);
    }
    if plan.direction != Direction::Download || plan.validate().is_err() {
        return Err(ManifestError::InvalidPlan);
    }
    if !component(root_name) {
        return Err(ManifestError::UnsupportedName);
    }
    let mut seen = HashSet::new();
    let mut result = Vec::with_capacity(plan.nodes.len());
    for (node_index, node) in plan.nodes.iter().enumerate() {
        if node.size > i64::MAX as u64 {
            return Err(ManifestError::Capacity);
        }
        if node.kind == NodeKind::Unsupported
            || matches!(
                node.state,
                NodeState::Failed | NodeState::Skipped | NodeState::Conflict
            )
        {
            return Err(ManifestError::UnsupportedNode);
        }
        if node.destination_name.is_some() {
            // The native inventory must not diverge from the original snapshot.
            return Err(ManifestError::InvalidPlan);
        }
        if !node.relative.is_empty() && !node.relative.split('/').all(component) {
            return Err(ManifestError::UnsupportedName);
        }
        let name = if node.relative.is_empty() {
            root_name.to_owned()
        } else {
            format!("{}\\{}", root_name, node.relative.replace('/', "\\"))
        };
        if name.encode_utf16().count() > MAX_NAME_UNITS {
            return Err(ManifestError::UnsupportedName);
        }
        // Conservative Unicode folding can reject some distinct NTFS names,
        // but must never silently merge them or normalize their spelling.
        if !seen.insert(name.to_uppercase()) {
            return Err(ManifestError::NameCollision);
        }
        result.push(Descriptor {
            node_index,
            name,
            directory: node.kind == NodeKind::Directory,
            bytes: node.size,
        });
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree_transfer::{ConflictDecision, TransferNode};

    fn node(relative: &str, kind: NodeKind) -> TransferNode {
        TransferNode {
            relative: relative.into(),
            kind,
            size: 0,
            acknowledged: 0,
            started: false,
            state: NodeState::Pending,
            decision: ConflictDecision::Ask,
            destination_name: None,
            error: None,
            default_policy_pending: false,
        }
    }
    fn plan(nodes: Vec<TransferNode>) -> TreeTransfer {
        TreeTransfer {
            version: 1,
            direction: Direction::Download,
            local: std::env::temp_dir().join("hspterm-test-manifest-only"),
            remote: "/payload".into(),
            nodes,
        }
    }
    #[test]
    fn preserves_parent_order_empty_directories_unicode_and_original_node_identity() {
        let p = plan(vec![
            node("", NodeKind::Directory),
            node("空目录", NodeKind::Directory),
            node("中文 é 😀.txt", NodeKind::File),
        ]);
        let items = descriptors("项目", &p).unwrap();
        assert_eq!(items.len(), 3);
        assert!(items[0].directory && items[1].directory && !items[2].directory);
        assert_eq!(items[1].name, "项目\\空目录");
        assert_eq!(items[2].name, "项目\\中文 é 😀.txt");
        assert_eq!(items[2].node_index, 2);
        assert_eq!(p.nodes[2].relative, "中文 é 😀.txt");
    }
    #[test]
    fn rejects_aliases_collisions_and_whole_path_utf16_overflow_without_sanitizing() {
        for name in ["CONIN$", "conın$", "a:b", "a\\b", "tail.", ".."] {
            assert_eq!(
                descriptors(name, &plan(vec![node("", NodeKind::File)])),
                Err(ManifestError::UnsupportedName)
            );
        }
        let p = plan(vec![
            node("", NodeKind::Directory),
            node("Readme", NodeKind::File),
            node("README", NodeKind::File),
        ]);
        assert_eq!(descriptors("root", &p), Err(ManifestError::NameCollision));
        let p = plan(vec![
            node("", NodeKind::Directory),
            node(&"😀".repeat(126), NodeKind::File),
        ]);
        assert!(descriptors("123456", &p).is_ok()); // 6 + 1 + 252 = 259
        assert_eq!(
            descriptors("1234567", &p),
            Err(ManifestError::UnsupportedName)
        );
    }
    #[test]
    fn incomplete_scans_and_links_never_publish_a_partial_drag_inventory() {
        let mut link = node("link", NodeKind::Unsupported);
        link.state = NodeState::Failed;
        assert_eq!(
            descriptors("root", &plan(vec![node("", NodeKind::Directory), link])),
            Err(ManifestError::UnsupportedNode)
        );
        let mut p = plan(vec![
            node("", NodeKind::Directory),
            node("ok", NodeKind::File),
        ]);
        p.nodes[0].state = NodeState::Failed;
        assert_eq!(descriptors("root", &p), Err(ManifestError::UnsupportedNode));
        assert_eq!(
            descriptors("root", &plan(vec![node("missing/child", NodeKind::File)])),
            Err(ManifestError::InvalidPlan)
        );
    }

    #[test]
    fn multi_root_selection_has_one_inventory_and_stable_per_task_indices() {
        let a = plan(vec![
            node("", NodeKind::Directory),
            node("empty", NodeKind::Directory),
        ]);
        let b = plan(vec![node("", NodeKind::File)]);
        let items = selection_descriptors(&[("A", &a), ("B", &b)]).unwrap();
        assert_eq!(
            items
                .iter()
                .map(|i| (i.root_index, i.descriptor.node_index))
                .collect::<Vec<_>>(),
            vec![(0, 0), (0, 1), (1, 0)]
        );
        assert_eq!(
            selection_descriptors(&[("A", &a), ("a", &b)]),
            Err(ManifestError::NameCollision)
        );
        assert_eq!(selection_descriptors(&[]), Err(ManifestError::Capacity));
    }
}
