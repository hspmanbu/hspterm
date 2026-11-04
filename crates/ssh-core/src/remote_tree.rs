//! One remote tree, one task. The owner binds both authenticated endpoints,
//! supplies FIFO admission/limits and persists every mutation barrier. This
//! module opens no Transport and follows no child links. Copy/staging cleanup
//! never deletes sources; explicit source_retirement is a separate post-copy
//! operation whose caller must bind actual endpoints and user authorization.
use crate::{
    SftpSession,
    bandwidth::BandwidthLimiter,
    directory::{DirectoryError, DirectoryReader},
    transfer::{self, RemoteCopyError, RemoteCopyMode, RemotePublishResult, TransferError},
    tree_transfer::{
        ConflictDecision, NodeKind, NodeState, TransferNode, TreeOutcome, TreeProgress, TreeStats,
        stats::{Accumulator, Contribution},
    },
};
use russh_sftp::{client::error::Error as SftpError, protocol::StatusCode};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet, VecDeque};
use tokio_util::sync::CancellationToken;

const MAX_NODES: usize = 1_000_000;
const MAX_PATH_BYTES: usize = 32 * 1024 * 1024;
const MAX_PATH: usize = 131072;
mod file;
mod parallel;
mod recovery;
mod source_retirement;
mod staging_cleanup;
pub use source_retirement::SourceRetirement;
pub use staging_cleanup::{StagingCleanup, StagingCleanupState};

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub enum StagingPhase {
    Absent,
    /// Unique pathname durably reserved, but no successful OPEN observed yet.
    Intent,
    /// Capability/attempt durably recorded before direct marker/exec. Neither
    /// a retained byte length nor channel close proves a completed snapshot.
    Direct {
        nonce: [u8; 32],
        attempt: u64,
    },
    /// Private file opened; acknowledged bytes may still lack final CLOSE.
    Writing,
    /// Complete snapshot, including both file CLOSE acknowledgements.
    Ready,
    /// Intent saved before rename/truncate. A lost reply is not success.
    Publishing,
    /// Target acknowledged and verified. Only known staging cleanup remains.
    Published,
}
impl std::fmt::Debug for StagingPhase {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Absent => "Absent",
            Self::Intent => "Intent",
            Self::Direct { .. } => "Direct",
            Self::Writing => "Writing",
            Self::Ready => "Ready",
            Self::Publishing => "Publishing",
            Self::Published => "Published",
        })
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemoteTree {
    pub version: u32,
    pub source: String,
    pub destination: String,
    /// Random, device task identifier, never a name supplied by the remote peer.
    pub staging_id: String,
    pub nodes: Vec<TransferNode>,
    pub stages: Vec<StagingPhase>,
}

#[derive(thiserror::Error)]
pub enum RemoteTreeError {
    #[error("当前文件安全直传条件不可用且未允许中转；未开始该文件的暂存写入")]
    DirectUnavailable,
    #[error("目标不支持原子覆盖且当前策略不允许中转；完整暂存保留，未覆盖目标")]
    RelayRequired,
    #[error("服务器直传仍在运行或回执未确认；保留暂存，明确继续时先只读核对，不盲重发或改中转")]
    DirectUncertain,
    #[error("远端目录任务已暂停；源文件、完整副本和部分写入均保留")]
    Cancelled,
    #[error("远端目录清单、路径或暂存状态无效")]
    InvalidPlan,
    #[error("远端目录项目或路径超过单任务安全容量；扫描未完成")]
    Capacity,
    #[error("目录已变为链接或父目录不再属于原路径；未跟随")]
    UnsafeParent,
    #[error("来源类型已改变或不是普通文件/目录；未丢弃原清单或跟随链接")]
    SourceKind,
    #[error("暂存创建或发布结果未确认；保留原始来源，请检查任务详情")]
    Uncertain,
    #[error("本机传输状态未能持久化；已停止后续远端修改")]
    Checkpoint,
    #[error("复制尚未全部确认，未开始删除来源")]
    SourceCopyIncomplete,
    #[error("来源删除结果未确认；不重复删除，目标副本保留，请检查原任务")]
    SourceRetirementUncertain,
    #[error("来源清理已停止；目标副本保留，已经确认删除的来源不会恢复")]
    SourceRetirementStopped,
    #[error("来源当前类型或大小与已复制记录不一致，未继续删除")]
    SourceChanged,
    /// Only a typed transport fault at a replay-safe staging boundary. The
    /// owner must retire both channels and persist before resetting this node.
    #[error("复制子通道暂时不可用；保留原暂存阶段和确认偏移")]
    TransientChannel { indices: Vec<usize> },
    #[error(transparent)]
    Directory(#[from] DirectoryError),
    #[error("远端目录操作未成功")]
    Sftp(#[from] SftpError),
    #[error(transparent)]
    Copy(#[from] RemoteCopyError),
}
impl std::fmt::Debug for RemoteTreeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(self, f)
    }
}
type Result<T> = std::result::Result<T, RemoteTreeError>;

fn named_path(path: &str) -> bool {
    path.len() <= MAX_PATH
        && path.starts_with('/')
        && path.len() > 1
        && !path.contains('\0')
        && path[1..]
            .split('/')
            .all(|p| !p.is_empty() && p != "." && p != "..")
}
fn relative_path(path: &str) -> bool {
    path.is_empty()
        || (!path.starts_with('/')
            && !path.contains('\0')
            && path
                .split('/')
                .all(|p| !p.is_empty() && p != "." && p != ".."))
}
fn join(root: &str, relative: &str) -> String {
    if relative.is_empty() {
        root.into()
    } else {
        format!("{root}/{relative}")
    }
}
fn below(path: &str, parent: &str) -> bool {
    path == parent
        || path
            .strip_prefix(parent)
            .is_some_and(|s| s.starts_with('/'))
}
fn blocked_parent(relative: &str, blocked: &HashSet<String>) -> bool {
    if blocked.contains("") {
        return true;
    }
    let mut path = relative;
    while let Some((parent, _)) = path.rsplit_once('/') {
        if blocked.contains(parent) {
            return true;
        }
        path = parent;
    }
    false
}
fn stopped(stop: &CancellationToken) -> Result<()> {
    if stop.is_cancelled() {
        Err(RemoteTreeError::Cancelled)
    } else {
        Ok(())
    }
}
async fn cancellable<T>(
    stop: &CancellationToken,
    future: impl std::future::Future<Output = Result<T>>,
) -> Result<T> {
    tokio::select! { biased; _ = stop.cancelled() => Err(RemoteTreeError::Cancelled), result = future => result }
}
async fn guard_parent(sftp: &SftpSession, path: &str) -> Result<()> {
    let parent = path.rsplit_once('/').ok_or(RemoteTreeError::InvalidPlan)?.0;
    let parent = if parent.is_empty() { "/" } else { parent };
    if sftp.canonicalize(parent).await? != parent {
        return Err(RemoteTreeError::UnsafeParent);
    }
    let attrs = sftp.symlink_metadata(parent).await?;
    if !attrs.is_dir() || attrs.is_symlink() {
        return Err(RemoteTreeError::UnsafeParent);
    }
    Ok(())
}
async fn exists(sftp: &SftpSession, path: &str) -> Result<bool> {
    match sftp.symlink_metadata(path).await {
        Ok(_) => Ok(true),
        Err(SftpError::Status(s)) if s.status_code == StatusCode::NoSuchFile => Ok(false),
        Err(error) => Err(error.into()),
    }
}

impl RemoteTree {
    /// Metadata only; target remains untouched. `same_server` is established by
    /// the owner from both actual endpoint identities, never a UI host label.
    #[allow(clippy::too_many_arguments)]
    pub async fn scan(
        source_sftp: &SftpSession,
        target_sftp: &SftpSession,
        source: String,
        destination: String,
        same_server: bool,
        staging_id: String,
        stop: &CancellationToken,
        mut discovered: impl FnMut(usize),
    ) -> Result<Self> {
        cancellable(stop, async {
            let source = transfer::object_path(source_sftp, &source)
                .await
                .map_err(|_| RemoteTreeError::InvalidPlan)?;
            let destination = transfer::object_path(target_sftp, &destination)
                .await
                .map_err(|_| RemoteTreeError::InvalidPlan)?;
            let mut plan = Self {
                version: 1,
                source,
                destination,
                staging_id,
                nodes: Vec::new(),
                stages: Vec::new(),
            };
            plan.validate_roots()?;
            let root = source_sftp.symlink_metadata(&plan.source).await?;
            if same_server
                && (plan.source == plan.destination
                    || (root.is_dir()
                        && !root.is_symlink()
                        && below(&plan.destination, &plan.source)))
            {
                return Err(RemoteTreeError::InvalidPlan);
            }
            let mut queue = VecDeque::from([String::new()]);
            let mut bytes = 0usize;
            while let Some(relative) = queue.pop_front() {
                stopped(stop)?;
                if plan.nodes.len() >= MAX_NODES {
                    return Err(RemoteTreeError::Capacity);
                }
                let path = join(&plan.source, &relative);
                let mut node = TransferNode {
                    relative: relative.clone(),
                    kind: NodeKind::Unsupported,
                    size: 0,
                    acknowledged: 0,
                    started: false,
                    state: NodeState::Pending,
                    decision: ConflictDecision::Ask,
                    destination_name: None,
                    error: None,
                    default_policy_pending: true,
                };
                let inspection = async {
                    guard_parent(source_sftp, &path).await?;
                    Ok::<_, RemoteTreeError>(source_sftp.symlink_metadata(&path).await?)
                }
                .await;
                match inspection {
                    Ok(attrs)
                        if attrs.is_regular() && !attrs.is_symlink() && attrs.size.is_some() =>
                    {
                        node.kind = NodeKind::File;
                        node.size = attrs.size.expect("checked size");
                    }
                    Ok(attrs) if attrs.is_dir() && !attrs.is_symlink() => {
                        node.kind = NodeKind::Directory;
                        let children = directory_children(
                            source_sftp,
                            &path,
                            &relative,
                            MAX_NODES - plan.nodes.len() - queue.len() - 1,
                            MAX_PATH_BYTES - bytes,
                            stop,
                        )
                        .await;
                        match children {
                            Ok(children) => {
                                for child in children {
                                    bytes += child.len();
                                    queue.push_back(child);
                                }
                            }
                            Err(
                                error @ (RemoteTreeError::Cancelled | RemoteTreeError::Capacity),
                            ) => return Err(error),
                            Err(error) => {
                                node.state = NodeState::Failed;
                                node.error = Some(error.to_string());
                            }
                        }
                    }
                    Ok(_) => {
                        node.state = NodeState::Failed;
                        node.error = Some("不跟随符号链接，不复制特殊文件".into());
                    }
                    Err(error) => {
                        node.state = NodeState::Failed;
                        node.error = Some(error.to_string());
                    }
                }
                plan.nodes.push(node);
                plan.stages.push(StagingPhase::Absent);
                discovered(plan.nodes.len());
            }
            plan.validate()?;
            Ok(plan)
        })
        .await
    }

    /// Read-only recovery candidate. Old indices identify private snapshots,
    /// so merging must append discoveries instead of rebuilding the manifest.
    /// The owner durably publishes the whole candidate before target writes.
    pub async fn rescan_failed(
        &self,
        indices: &[usize],
        source: &SftpSession,
        stop: &CancellationToken,
        mut discovered: impl FnMut(usize),
    ) -> Result<Self> {
        self.validate()?;
        stopped(stop)?;
        if indices.is_empty() {
            return Err(RemoteTreeError::InvalidPlan);
        }
        let mut roots = HashSet::new();
        for &index in indices {
            let node = self.nodes.get(index).ok_or(RemoteTreeError::InvalidPlan)?;
            if node.kind == NodeKind::File || node.state != NodeState::Failed {
                return Err(RemoteTreeError::InvalidPlan);
            }
            roots.insert(node.relative.clone());
        }
        let mut pending: VecDeque<_> = self
            .nodes
            .iter()
            .filter(|n| {
                roots.contains(&n.relative)
                    && (n.relative.is_empty() || !blocked_parent(&n.relative, &roots))
            })
            .map(|n| n.relative.clone())
            .collect();
        let mut scheduled: HashSet<_> = pending.iter().cloned().collect();
        let mut positions: HashMap<_, _> = self
            .nodes
            .iter()
            .enumerate()
            .map(|(i, n)| (n.relative.clone(), i))
            .collect();
        // validate() has already bounded this sum, including every old node.
        let mut bytes: usize = self.nodes.iter().map(|n| n.relative.len()).sum();
        let mut merged = self.clone();
        cancellable(stop, async {
            while let Some(relative) = pending.pop_front() {
                stopped(stop)?;
                let index = positions[&relative];
                let previous = &merged.nodes[index];
                if matches!(
                    previous.state,
                    NodeState::Complete | NodeState::Skipped | NodeState::Conflict
                ) {
                    continue;
                }
                let old_kind = previous.kind;
                let path = join(&self.source, &relative);
                let inspection = async {
                    guard_parent(source, &path).await?;
                    let attrs = source.symlink_metadata(&path).await?;
                    let (kind, size) = if attrs.is_dir() && !attrs.is_symlink() {
                        (NodeKind::Directory, 0)
                    } else if attrs.is_regular() && !attrs.is_symlink() && attrs.size.is_some() {
                        (NodeKind::File, attrs.size.expect("checked size"))
                    } else {
                        return Err(RemoteTreeError::SourceKind);
                    };
                    if old_kind != NodeKind::Unsupported && old_kind != kind {
                        return Err(RemoteTreeError::SourceKind);
                    }
                    if kind == NodeKind::Directory {
                        // Enumeration may include old names. Bound temporary
                        // metadata separately, then enforce the merged budget.
                        let children = directory_children(
                            source,
                            &path,
                            &relative,
                            MAX_NODES,
                            MAX_PATH_BYTES,
                            stop,
                        )
                        .await?;
                        for child in children {
                            if !positions.contains_key(&child) {
                                bytes = bytes
                                    .checked_add(child.len())
                                    .ok_or(RemoteTreeError::Capacity)?;
                                if positions.len() >= MAX_NODES || bytes > MAX_PATH_BYTES {
                                    return Err(RemoteTreeError::Capacity);
                                }
                                let position = merged.nodes.len();
                                merged.nodes.push(TransferNode {
                                    relative: child.clone(),
                                    kind: NodeKind::Unsupported,
                                    size: 0,
                                    acknowledged: 0,
                                    started: false,
                                    state: NodeState::Failed,
                                    decision: ConflictDecision::Ask,
                                    destination_name: None,
                                    error: None,
                                    default_policy_pending: true,
                                });
                                merged.stages.push(StagingPhase::Absent);
                                positions.insert(child.clone(), position);
                            }
                            if scheduled.insert(child.clone()) {
                                pending.push_back(child);
                            }
                        }
                    }
                    Ok((kind, size))
                }
                .await;
                let node = &mut merged.nodes[index];
                match inspection {
                    Ok((kind, size)) => {
                        node.kind = kind;
                        // Never reinterpret an uncertain OPEN or an existing
                        // private prefix/full snapshot as a fresh source body.
                        if kind == NodeKind::File && merged.stages[index] == StagingPhase::Absent {
                            node.size = size;
                        }
                        node.state = NodeState::Pending;
                        node.error = None;
                    }
                    Err(
                        RemoteTreeError::Capacity
                        | RemoteTreeError::Directory(DirectoryError::Capacity),
                    ) => return Err(RemoteTreeError::Capacity),
                    Err(RemoteTreeError::Cancelled) => return Err(RemoteTreeError::Cancelled),
                    Err(error) => {
                        node.state = NodeState::Failed;
                        node.error = Some(error.to_string());
                    }
                }
                discovered(merged.nodes.len());
            }
            stopped(stop)?;
            merged.validate()?;
            Ok(merged)
        })
        .await
    }

    fn validate_roots(&self) -> Result<()> {
        if self.version != 1
            || !named_path(&self.source)
            || !named_path(&self.destination)
            || self.staging_id.len() != 32
            || !self
                .staging_id
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        {
            return Err(RemoteTreeError::InvalidPlan);
        }
        Ok(())
    }
    pub fn validate(&self) -> Result<()> {
        self.validate_roots()?;
        if self.nodes.is_empty()
            || self.nodes.len() > MAX_NODES
            || self.stages.len() != self.nodes.len()
        {
            return Err(RemoteTreeError::InvalidPlan);
        }
        let mut seen = HashMap::new();
        let mut targets = HashSet::new();
        let mut path_bytes = 0usize;
        let mut total = 0u64;
        for (index, (node, stage)) in self.nodes.iter().zip(&self.stages).enumerate() {
            if !relative_path(&node.relative)
                || node.acknowledged > node.size
                || (!node.started && node.acknowledged != 0)
                || (node.kind != NodeKind::File
                    && (node.size != 0 || node.started || *stage != StagingPhase::Absent))
                || (node.kind == NodeKind::Unsupported && node.state != NodeState::Failed)
                || (node.kind == NodeKind::File
                    && node.started
                        != !matches!(
                            stage,
                            StagingPhase::Absent
                                | StagingPhase::Intent
                                | StagingPhase::Direct { .. }
                        ))
                || matches!(stage, StagingPhase::Direct { attempt: 0, .. })
                || (node.kind == NodeKind::File
                    && matches!(
                        stage,
                        StagingPhase::Ready | StagingPhase::Publishing | StagingPhase::Published
                    )
                    && node.acknowledged != node.size)
                || (node.kind == NodeKind::File
                    && node.state == NodeState::Complete
                    && *stage != StagingPhase::Published)
                || (index == 0 && !node.relative.is_empty())
            {
                return Err(RemoteTreeError::InvalidPlan);
            }
            if let Some(name) = &node.destination_name
                && (node.kind != NodeKind::File
                    || name.is_empty()
                    || !relative_path(name)
                    || name.contains('/'))
            {
                return Err(RemoteTreeError::InvalidPlan);
            }
            if !node.relative.is_empty() {
                let parent = node.relative.rsplit_once('/').map_or("", |(p, _)| p);
                if seen.get(parent) != Some(&NodeKind::Directory) {
                    return Err(RemoteTreeError::InvalidPlan);
                }
            }
            if seen.insert(node.relative.as_str(), node.kind).is_some()
                || !targets.insert(self.destination_path(index)?)
            {
                return Err(RemoteTreeError::InvalidPlan);
            }
            if !named_path(&self.destination_path(index)?)
                || join(&self.source, &node.relative).len() > MAX_PATH
                || self.staging_path(index)?.len() > MAX_PATH
            {
                return Err(RemoteTreeError::Capacity);
            }
            path_bytes = path_bytes
                .checked_add(node.relative.len())
                .ok_or(RemoteTreeError::Capacity)?;
            total = total
                .checked_add(node.size)
                .ok_or(RemoteTreeError::Capacity)?;
        }
        if path_bytes > MAX_PATH_BYTES {
            return Err(RemoteTreeError::Capacity);
        }
        Ok(())
    }
    pub fn destination_path(&self, index: usize) -> Result<String> {
        let node = self.nodes.get(index).ok_or(RemoteTreeError::InvalidPlan)?;
        let path = join(&self.destination, &node.relative);
        if let Some(name) = &node.destination_name {
            let parent = path.rsplit_once('/').ok_or(RemoteTreeError::InvalidPlan)?.0;
            Ok(format!("{parent}/{name}"))
        } else {
            Ok(path)
        }
    }
    pub fn staging_path(&self, index: usize) -> Result<String> {
        let node = self.nodes.get(index).ok_or(RemoteTreeError::InvalidPlan)?;
        // A conflict rename changes only the final basename. It must not lose
        // the already persisted identity of an owned partial/complete snapshot.
        let destination = join(&self.destination, &node.relative);
        let parent = destination
            .rsplit_once('/')
            .ok_or(RemoteTreeError::InvalidPlan)?
            .0;
        Ok(format!(
            "{parent}/.hspterm-copy-{}-{index}.part",
            self.staging_id
        ))
    }
    pub fn stats(&self) -> TreeStats {
        Accumulator::new(&self.nodes).snapshot()
    }

    /// Recheck restored/renamed roots against the actual endpoint identities.
    /// Equal host keys are treated conservatively as a possibly shared tree.
    pub fn validate_endpoints(&self, may_share_filesystem: bool) -> Result<()> {
        let destination = self.destination_path(0)?;
        if may_share_filesystem
            && (self.source == destination
                || (self.nodes[0].kind == NodeKind::Directory && below(&destination, &self.source)))
        {
            return Err(RemoteTreeError::InvalidPlan);
        }
        Ok(())
    }

    /// A manual failed-file retry keeps its owned complete/partial snapshot.
    /// Choosing Overwrite never truncates the original before that snapshot.
    pub fn retry(&mut self, index: usize, decision: ConflictDecision) -> Result<()> {
        let node = self
            .nodes
            .get_mut(index)
            .ok_or(RemoteTreeError::InvalidPlan)?;
        if node.kind != NodeKind::File
            || !matches!(node.state, NodeState::Failed | NodeState::Conflict)
        {
            return Err(RemoteTreeError::InvalidPlan);
        }
        node.state = NodeState::Pending;
        node.error = None;
        node.default_policy_pending = false;
        node.decision = decision;
        Ok(())
    }

    pub fn rename_destination(&mut self, index: usize, name: &str) -> Result<()> {
        self.validate()?;
        let node = self.nodes.get(index).ok_or(RemoteTreeError::InvalidPlan)?;
        if node.kind != NodeKind::File
            || !matches!(node.state, NodeState::Failed | NodeState::Conflict)
            || self.stages[index] == StagingPhase::Published
            || name.is_empty()
            || !relative_path(name)
            || name.contains('/')
        {
            return Err(RemoteTreeError::InvalidPlan);
        }
        let original = self.destination_path(index)?;
        let parent = original
            .rsplit_once('/')
            .ok_or(RemoteTreeError::InvalidPlan)?
            .0;
        let target = format!("{parent}/{name}");
        if !named_path(&target) {
            return Err(RemoteTreeError::InvalidPlan);
        }
        for other in 0..self.nodes.len() {
            if other != index && self.destination_path(other)? == target {
                return Err(RemoteTreeError::InvalidPlan);
            }
        }
        let node = &mut self.nodes[index];
        if index == 0 {
            self.destination = target;
            node.destination_name = None;
        } else {
            node.destination_name = Some(name.into());
        }
        node.state = NodeState::Pending;
        node.decision = ConflictDecision::Ask;
        node.default_policy_pending = false;
        node.error = None;
        Ok(())
    }

    /// Resolve an explicit/default batch of conflicts using metadata only.
    /// Return an independent candidate, to be durably saved before any write.
    pub async fn rename_conflicts(
        &self,
        indices: &[usize],
        target: &SftpSession,
        stop: &CancellationToken,
    ) -> Result<Self> {
        self.validate()?;
        let mut candidate = self.clone();
        let mut visited = HashSet::new();
        let mut used: HashSet<_> = (0..self.nodes.len())
            .map(|i| self.destination_path(i))
            .collect::<Result<_>>()?;
        for &index in indices {
            stopped(stop)?;
            let node = self.nodes.get(index).ok_or(RemoteTreeError::InvalidPlan)?;
            if !visited.insert(index)
                || node.kind != NodeKind::File
                || node.state != NodeState::Conflict
                || self.stages[index] == StagingPhase::Published
            {
                return Err(RemoteTreeError::InvalidPlan);
            }
            let path = self.destination_path(index)?;
            cancellable(stop, guard_parent(target, &path)).await?;
            let (parent, name) = path.rsplit_once('/').ok_or(RemoteTreeError::InvalidPlan)?;
            used.remove(&path);
            let mut found = None;
            for number in 1..=10000 {
                let name = crate::tree_transfer::numbered_name(name, number);
                let path = format!("{parent}/{name}");
                if path.len() > MAX_PATH {
                    return Err(RemoteTreeError::Capacity);
                }
                if !used.contains(&path) && !cancellable(stop, exists(target, &path)).await? {
                    used.insert(path);
                    found = Some(name);
                    break;
                }
            }
            let name = found.ok_or(RemoteTreeError::Capacity)?;
            let node = &mut candidate.nodes[index];
            if index == 0 {
                candidate.destination = format!("{parent}/{name}");
                node.destination_name = None;
            } else {
                node.destination_name = Some(name);
            }
            node.state = NodeState::Pending;
            node.decision = ConflictDecision::Ask;
            node.default_policy_pending = false;
            node.error = None;
        }
        stopped(stop)?;
        candidate.validate()?;
        Ok(candidate)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn run(
        &mut self,
        source: &SftpSession,
        target: &SftpSession,
        stop: &CancellationToken,
        upload: &BandwidthLimiter,
        download: &BandwidthLimiter,
        mut checkpoint: impl FnMut(&Self, TreeProgress) -> Result<()>,
    ) -> Result<TreeOutcome> {
        self.validate()?;
        // Mandatory full-plan barrier, even before mkdir or the first OPEN.
        checkpoint(
            self,
            TreeProgress {
                index: 0,
                current: None,
                stats: self.stats(),
            },
        )
        .map_err(|_| RemoteTreeError::Checkpoint)?;
        let mut stats = Accumulator::new(&self.nodes);
        let mut blocked: HashSet<String> = self
            .nodes
            .iter()
            .filter(|n| n.kind == NodeKind::Directory && n.state == NodeState::Failed)
            .map(|n| n.relative.clone())
            .collect();
        for index in 0..self.nodes.len() {
            if stop.is_cancelled() {
                return Ok(TreeOutcome::Paused);
            }
            let node = &self.nodes[index];
            if node.state != NodeState::Pending
                && !(node.kind == NodeKind::Directory && node.state == NodeState::Complete)
            {
                continue;
            }
            let mut previous = Contribution::from(node);
            let mut notify = |plan: &Self, current| {
                let after = Contribution::from(&plan.nodes[index]);
                stats.replace(previous, after);
                previous = after;
                checkpoint(
                    plan,
                    TreeProgress {
                        index,
                        current,
                        stats: stats.snapshot(),
                    },
                )
                .map_err(|_| RemoteTreeError::Checkpoint)
            };
            let relative = self.nodes[index].relative.clone();
            if blocked_parent(&relative, &blocked) {
                self.nodes[index].state = NodeState::Failed;
                self.nodes[index].error = Some("父目录未成功读取或创建，未跟随链接".into());
                notify(self, None)?;
                continue;
            }
            let result = if self.nodes[index].kind == NodeKind::Directory {
                let path = self.destination_path(index)?;
                let result = cancellable(stop, async {
                    guard_parent(target, &path).await?;
                    ensure_directory(target, &path).await
                })
                .await;
                if result.is_err() && !matches!(result, Err(RemoteTreeError::Cancelled)) {
                    blocked.insert(relative);
                }
                result
            } else {
                self.copy_node(index, source, target, stop, upload, download, &mut notify)
                    .await
            };
            let recoverable = result.as_ref().err().is_some_and(|error| {
                recovery::retryable(error, self.nodes[index].kind, self.stages[index])
            });
            match result {
                Ok(()) if self.nodes[index].state != NodeState::Skipped => {
                    self.nodes[index].state = NodeState::Complete;
                    self.nodes[index].error = None;
                }
                Ok(()) => {}
                Err(RemoteTreeError::Checkpoint) => return Err(RemoteTreeError::Checkpoint),
                Err(RemoteTreeError::Cancelled) => {
                    notify(self, None)?;
                    return Ok(TreeOutcome::Paused);
                }
                Err(RemoteTreeError::Copy(RemoteCopyError::Transfer(TransferError::Conflict))) => {
                    self.nodes[index].state = NodeState::Conflict;
                    self.nodes[index].error = Some("目标已存在，等待覆盖、跳过或更名".into());
                }
                Err(error) => {
                    self.nodes[index].state = NodeState::Failed;
                    self.nodes[index].error = Some(error.to_string());
                }
            }
            notify(self, None)?;
            if recoverable {
                return Err(RemoteTreeError::TransientChannel {
                    indices: vec![index],
                });
            }
        }
        let s = stats.snapshot();
        Ok(if s.failed != 0 || s.conflicts != 0 {
            TreeOutcome::Partial
        } else if s.skipped != 0 {
            TreeOutcome::CompleteWithSkips
        } else {
            TreeOutcome::Complete
        })
    }

    #[allow(clippy::too_many_arguments)]
    async fn copy_node(
        &mut self,
        index: usize,
        source: &SftpSession,
        target: &SftpSession,
        stop: &CancellationToken,
        upload: &BandwidthLimiter,
        download: &BandwidthLimiter,
        notify: &mut impl FnMut(&Self, Option<usize>) -> Result<()>,
    ) -> Result<()> {
        let mut work = file::FileWork::new(self, index)?;
        let result = work
            .run(source, target, stop, upload, download, &mut |work| {
                work.apply(self, index);
                notify(self, Some(index))
            })
            .await;
        work.apply(self, index);
        result
    }
}

async fn directory_children(
    sftp: &SftpSession,
    path: &str,
    relative: &str,
    remaining: usize,
    max_bytes: usize,
    stop: &CancellationToken,
) -> Result<Vec<String>> {
    let mut reader = DirectoryReader::open(sftp, path.into()).await?;
    if reader.path() != path {
        reader.close().await?;
        return Err(RemoteTreeError::UnsafeParent);
    }
    let result = async {
        let mut children = Vec::new();
        let mut bytes = 0usize;
        loop {
            stopped(stop)?;
            let page = reader.next_page(256).await?;
            for entry in page.entries {
                let next = if relative.is_empty() {
                    entry.name
                } else {
                    format!("{relative}/{}", entry.name)
                };
                bytes = bytes
                    .checked_add(next.len())
                    .ok_or(RemoteTreeError::Capacity)?;
                if children.len() >= remaining || bytes > max_bytes {
                    return Err(RemoteTreeError::Capacity);
                }
                children.push(next);
            }
            if page.done {
                break;
            }
        }
        Ok(children)
    }
    .await;
    // EOF is not completion without directory CLOSE. On an error/cancellation
    // the owner also closes the dedicated channel to release unknown handles.
    let close = reader.close().await;
    match (result, close) {
        (Err(error), _) => Err(error),
        (Ok(_), Err(error)) => Err(error.into()),
        (Ok(children), Ok(())) => Ok(children),
    }
}

async fn ensure_directory(sftp: &SftpSession, path: &str) -> Result<()> {
    match sftp.symlink_metadata(path).await {
        Ok(attrs) if attrs.is_dir() && !attrs.is_symlink() => Ok(()),
        Ok(_) => Err(RemoteTreeError::UnsafeParent),
        Err(SftpError::Status(s)) if s.status_code == StatusCode::NoSuchFile => {
            sftp.create_dir(path).await?;
            let attrs = sftp.symlink_metadata(path).await?;
            if attrs.is_dir() && !attrs.is_symlink() {
                Ok(())
            } else {
                Err(RemoteTreeError::UnsafeParent)
            }
        }
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn node(relative: &str, kind: NodeKind) -> TransferNode {
        TransferNode {
            relative: relative.into(),
            kind,
            size: if kind == NodeKind::File { 19 } else { 0 },
            acknowledged: 0,
            started: false,
            state: NodeState::Pending,
            decision: ConflictDecision::Ask,
            destination_name: None,
            error: None,
            default_policy_pending: true,
        }
    }
    fn fixture() -> RemoteTree {
        RemoteTree {
            version: 1,
            source: "/source".into(),
            destination: "/destination".into(),
            staging_id: "0123456789abcdef0123456789abcdef".into(),
            nodes: vec![
                node("", NodeKind::Directory),
                node("first", NodeKind::File),
                node("second", NodeKind::File),
            ],
            stages: vec![StagingPhase::Absent; 3],
        }
    }
    #[test]
    fn restore_rejects_unsafe_paths_duplicate_targets_and_impossible_snapshot_phases() {
        fixture().validate().unwrap();
        let reject = |edit: fn(&mut RemoteTree)| {
            let mut p = fixture();
            edit(&mut p);
            assert!(p.validate().is_err());
        };
        reject(|p| p.version = 2);
        reject(|p| p.staging_id = "../other-task".into());
        reject(|p| p.source = "/".into());
        reject(|p| p.destination = "/bad/../escape".into());
        reject(|p| p.nodes[1].relative = "../escape".into());
        reject(|p| p.nodes[1].relative = "missing/child".into());
        reject(|p| p.nodes[2].destination_name = Some("first".into()));
        reject(|p| p.nodes[1].destination_name = Some("../escape".into()));
        reject(|p| p.nodes[1].acknowledged = 1);
        reject(|p| p.stages[1] = StagingPhase::Writing);
        reject(|p| {
            p.nodes[1].started = true;
            p.stages[1] = StagingPhase::Ready;
        });
        reject(|p| {
            p.nodes[0].started = true;
            p.stages[0] = StagingPhase::Published;
        });
        reject(|p| p.nodes[1].state = NodeState::Complete);
        reject(|p| {
            p.stages.pop();
        });
        let mut p = fixture();
        p.nodes[1].started = true;
        p.nodes[1].acknowledged = p.nodes[1].size;
        for phase in [
            StagingPhase::Writing,
            StagingPhase::Ready,
            StagingPhase::Publishing,
            StagingPhase::Published,
        ] {
            p.stages[1] = phase;
            p.validate().unwrap();
        }
        p.nodes[1].state = NodeState::Complete;
        p.validate().unwrap();
    }
    #[test]
    fn direct_claim_is_durable_but_is_never_an_acknowledged_prefix_or_debug_secret() {
        let mut plan = fixture();
        plan.stages[1] = StagingPhase::Direct {
            nonce: [27; 32],
            attempt: 3,
        };
        plan.validate().unwrap();
        let bytes = serde_json::to_vec(&plan).unwrap();
        let restored: RemoteTree = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(restored.stages[1], plan.stages[1]);
        assert_eq!(format!("{:?}", plan.stages[1]), "Direct");
        plan.nodes[1].started = true;
        assert!(plan.validate().is_err());
        plan.nodes[1].started = false;
        plan.stages[1] = StagingPhase::Direct {
            nonce: [27; 32],
            attempt: 0,
        };
        assert!(plan.validate().is_err());
    }
    #[test]
    fn blocked_parent_lookup_obeys_components_and_does_not_confuse_adjacent_names() {
        let blocked = HashSet::from(["folder/bad".into()]);
        assert!(blocked_parent("folder/bad/deep/file", &blocked));
        assert!(!blocked_parent("folder/badly/file", &blocked));
        assert!(!blocked_parent("folder/good/file", &blocked));
        assert!(blocked_parent("any/file", &HashSet::from([String::new()])));
    }
}
