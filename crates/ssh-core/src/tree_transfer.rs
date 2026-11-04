//! One file or directory tree is one task. This module never opens an SSH
//! transport and never deletes successfully transferred or partially written data.
use crate::{
    SftpSession,
    transfer::{self, FileDisposition, TransferError},
};
use russh_sftp::client::error::Error as RemoteError;
use russh_sftp::protocol::StatusCode;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    path::{Path, PathBuf},
};
use tokio::fs;
use tokio_util::sync::CancellationToken;

mod parallel;
pub(crate) mod stats;

pub const MAX_ENTRIES: usize = 1_000_000;
// Stay below the encrypted journal payload limit, even with very long paths.
const MAX_PATH_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum Direction {
    Upload,
    Download,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum NodeKind {
    File,
    Directory,
    Unsupported,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum NodeState {
    Pending,
    Complete,
    Skipped,
    Failed,
    Conflict,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum ConflictDecision {
    Ask,
    Overwrite,
    Skip,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TransferNode {
    /// Empty for the root; all other components are relative and validated.
    pub relative: String,
    pub kind: NodeKind,
    pub size: u64,
    pub acknowledged: u64,
    /// Set only after the streaming primitive has opened the destination.
    pub started: bool,
    pub state: NodeState,
    pub decision: ConflictDecision,
    /// Optional explicit rename of this file's destination, not its source.
    #[serde(default)]
    pub destination_name: Option<String>,
    pub error: Option<String>,
    /// Only a newly discovered file may use the task default on first conflict.
    /// Explicit user decisions and old checkpoints never silently opt in.
    #[serde(default)]
    pub default_policy_pending: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TreeTransfer {
    pub version: u32,
    pub direction: Direction,
    pub local: PathBuf,
    pub remote: String,
    /// Parents precede children; successful nodes remain for resume bookkeeping,
    /// but are not intended as a successful-file listing in the UI.
    pub nodes: Vec<TransferNode>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TreeOutcome {
    Complete,
    CompleteWithSkips,
    Partial,
    Paused,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TreeStats {
    pub files: usize,
    pub directories: usize,
    pub complete: usize,
    pub failed: usize,
    pub conflicts: usize,
    pub skipped: usize,
    pub acknowledged: u64,
    pub total: u64,
    pub total_known: bool,
}
/// Metadata-only notification for an observed node. `index` is a conservative
/// dirty hint (including file-start notifications), not a new file operation.
/// `current` retains the original run/run_limited current-file semantics.
#[derive(Clone, Copy, Debug)]
pub struct TreeProgress {
    pub index: usize,
    pub current: Option<usize>,
    pub stats: TreeStats,
}
#[derive(thiserror::Error, Debug)]
pub enum TreeError {
    #[error("目录扫描或传输已暂停；已写入内容保留")]
    Cancelled,
    #[error("原SFTP通道发生瞬时错误；已确认偏移保留，需在原SSH内恢复通道")]
    TransientChannel(Vec<usize>),
    #[error("传输清单或路径无效")]
    InvalidPlan,
    #[error("本地目录路径包含不支持的Windows名称或设备路径；未创建目录")]
    InvalidLocalPath,
    #[error("源项目类型已改变或不受支持；保留原清单，不跟随符号链接")]
    SourceKind,
    #[error("可用更名候选超过安全尝试上限；原清单未修改")]
    RenameCapacity,
    #[error("目录项目或路径总长度超过单任务安全容量，扫描未完成")]
    Capacity,
    #[error("本地目录操作失败")]
    Local(#[from] std::io::Error),
    #[error("远端目录操作失败")]
    Remote(#[from] RemoteError),
}
type Result<T> = std::result::Result<T, TreeError>;

fn check_stop(stop: &CancellationToken) -> Result<()> {
    if stop.is_cancelled() {
        Err(TreeError::Cancelled)
    } else {
        Ok(())
    }
}
async fn cancellable<T>(
    stop: &CancellationToken,
    work: impl std::future::Future<Output = Result<T>>,
) -> Result<T> {
    tokio::select! { biased; _ = stop.cancelled() => Err(TreeError::Cancelled), result = work => result }
}
fn valid_relative(relative: &str) -> bool {
    relative.is_empty()
        || (!relative.starts_with('/')
            && relative
                .split('/')
                .all(|s| !s.is_empty() && s != "." && s != ".." && !s.contains('\0')))
}
fn child(parent: &str, name: &str) -> Result<String> {
    // A server directory entry is one component, never an alternate path.
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || !valid_relative(name)
    {
        return Err(TreeError::InvalidPlan);
    }
    Ok(if parent.is_empty() {
        name.into()
    } else {
        format!("{parent}/{name}")
    })
}
fn remote_join(root: &str, relative: &str) -> String {
    if relative.is_empty() {
        root.into()
    } else {
        format!("{}/{relative}", root.trim_end_matches('/'))
    }
}
fn local_join(root: &Path, relative: &str) -> PathBuf {
    if relative.is_empty() {
        root.into()
    } else {
        root.join(relative)
    }
}
fn blocked_parent(relative: &str, blocked: &HashSet<String>) -> bool {
    let mut current = relative;
    while !current.is_empty() {
        current = current.rsplit_once('/').map_or("", |(p, _)| p);
        if blocked.contains(current) {
            return true;
        }
    }
    false
}
pub(crate) fn numbered_name(original: &str, number: usize) -> String {
    match original.rsplit_once('.') {
        Some((stem, extension)) if !stem.is_empty() => format!("{stem} ({number}).{extension}"),
        _ => format!("{original} ({number})"),
    }
}
fn mapped_relative(node: &TransferNode, name: Option<&str>) -> String {
    match name {
        Some(name) => node
            .relative
            .rsplit_once('/')
            .map_or_else(|| name.into(), |(parent, _)| format!("{parent}/{name}")),
        None => node.relative.clone(),
    }
}
impl TreeTransfer {
    fn new(direction: Direction, local: PathBuf, remote: String) -> Result<Self> {
        if !local.is_absolute()
            || !remote.starts_with('/')
            || remote.contains('\0')
            || remote.len() > 131072
        {
            return Err(TreeError::InvalidPlan);
        }
        if direction == Direction::Upload && !crate::local_path::supported(&local) {
            return Err(TreeError::InvalidLocalPath);
        }
        Ok(Self {
            version: 1,
            direction,
            local,
            remote,
            nodes: Vec::new(),
        })
    }

    /// No destination writes occur during scanning. Cancellation discards only
    /// the incomplete manifest; the next explicit attempt may rescan safely.
    /// `discovered` is a count, never a fabricated percentage with unknown total.
    pub async fn scan(
        direction: Direction,
        local: PathBuf,
        remote: String,
        sftp: &SftpSession,
        stop: &CancellationToken,
        discovered: impl FnMut(usize),
    ) -> Result<Self> {
        Self::scan_with_entry_limit(
            direction,
            local,
            remote,
            sftp,
            stop,
            MAX_ENTRIES,
            discovered,
        )
        .await
    }

    /// A delayed native descriptor inventory has a smaller platform budget.
    /// Enforce it while discovering entries, rather than scanning a million
    /// nodes and only then rejecting the drag. Ordinary tasks keep their limit.
    pub async fn scan_with_entry_limit(
        direction: Direction,
        local: PathBuf,
        remote: String,
        sftp: &SftpSession,
        stop: &CancellationToken,
        entry_limit: usize,
        mut discovered: impl FnMut(usize),
    ) -> Result<Self> {
        if entry_limit == 0 || entry_limit > MAX_ENTRIES {
            return Err(TreeError::Capacity);
        }
        let mut plan = Self::new(direction, local, remote)?;
        cancellable(stop, async {
            let mut pending = VecDeque::from([String::new()]);
            let mut path_bytes = 0usize;
            while let Some(relative) = pending.pop_front() {
                check_stop(stop)?;
                if plan.nodes.len() >= entry_limit {
                    return Err(TreeError::Capacity);
                }
                let inspected = plan.inspect(sftp, &relative).await;
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
                match inspected {
                    Ok((kind, size)) => {
                        node.kind = kind;
                        node.size = if kind == NodeKind::File { size } else { 0 };
                        if kind == NodeKind::Unsupported {
                            node.state = NodeState::Failed;
                            node.error = Some("不跟随符号链接，不传输特殊文件".into());
                        }
                        if kind == NodeKind::Directory {
                            let remaining =
                                entry_limit.saturating_sub(plan.nodes.len() + pending.len() + 1);
                            let names = plan
                                .names(sftp, &relative, remaining, MAX_PATH_BYTES - path_bytes)
                                .await;
                            match names {
                                Ok(names) => {
                                    for name in names {
                                        let next = child(&relative, &name)?;
                                        // Bound the scan frontier too, not only visited nodes.
                                        if plan.nodes.len() + pending.len() >= entry_limit {
                                            return Err(TreeError::Capacity);
                                        }
                                        path_bytes = path_bytes
                                            .checked_add(next.len())
                                            .ok_or(TreeError::Capacity)?;
                                        if path_bytes > MAX_PATH_BYTES {
                                            return Err(TreeError::Capacity);
                                        }
                                        pending.push_back(next);
                                    }
                                }
                                Err(error) => {
                                    node.state = NodeState::Failed;
                                    node.error = Some(error.to_string());
                                }
                            }
                        }
                    }
                    Err(error) => {
                        node.state = NodeState::Failed;
                        node.error = Some(error.to_string());
                    }
                }
                plan.nodes.push(node);
                discovered(plan.nodes.len());
            }
            plan.validate()?;
            Ok(plan)
        })
        .await
    }

    async fn inspect(&self, sftp: &SftpSession, relative: &str) -> Result<(NodeKind, u64)> {
        match self.direction {
            Direction::Upload if !crate::local_path::supported_relative(relative) => {
                Err(TreeError::InvalidLocalPath)
            }
            Direction::Upload => fs::symlink_metadata(local_join(&self.local, relative))
                .await
                .map(|m| {
                    (
                        if m.is_symlink() {
                            NodeKind::Unsupported
                        } else if m.is_dir() {
                            NodeKind::Directory
                        } else if m.is_file() {
                            NodeKind::File
                        } else {
                            NodeKind::Unsupported
                        },
                        m.len(),
                    )
                })
                .map_err(Into::into),
            Direction::Download => sftp
                .symlink_metadata(remote_join(&self.remote, relative))
                .await
                .map(|m| {
                    (
                        if m.is_symlink() {
                            NodeKind::Unsupported
                        } else if m.is_dir() {
                            NodeKind::Directory
                        } else if m.file_type().is_file() && m.size.is_some() {
                            NodeKind::File
                        } else {
                            NodeKind::Unsupported
                        },
                        m.size.unwrap_or(0),
                    )
                })
                .map_err(Into::into),
        }
    }

    /// Return a merged candidate, never mutate the acknowledged checkpoint.
    /// Indices remain stable: new discoveries append after existing nodes.
    /// Completed/skipped nodes and completed directory subtrees are not read.
    pub async fn rescan_failed(
        &self,
        indices: &[usize],
        sftp: &SftpSession,
        stop: &CancellationToken,
        mut discovered: impl FnMut(usize),
    ) -> Result<Self> {
        self.validate()?;
        check_stop(stop)?;
        if indices.is_empty() {
            return Err(TreeError::InvalidPlan);
        }
        let mut roots = HashSet::new();
        for &index in indices {
            let node = self.nodes.get(index).ok_or(TreeError::InvalidPlan)?;
            if node.kind == NodeKind::File || node.state != NodeState::Failed {
                return Err(TreeError::InvalidPlan);
            }
            roots.insert(node.relative.clone());
        }
        let mut pending: VecDeque<_> = self
            .nodes
            .iter()
            .filter(|n| roots.contains(&n.relative) && !blocked_parent(&n.relative, &roots))
            .map(|n| n.relative.clone())
            .collect();
        let mut scheduled: HashSet<_> = pending.iter().cloned().collect();
        let mut merged = self.clone();
        let mut positions: HashMap<_, _> = self
            .nodes
            .iter()
            .enumerate()
            .map(|(i, n)| (n.relative.clone(), i))
            .collect();
        let mut path_bytes = self.nodes.iter().try_fold(0usize, |sum, n| {
            sum.checked_add(n.relative.len()).ok_or(TreeError::Capacity)
        })?;
        if path_bytes > MAX_PATH_BYTES {
            return Err(TreeError::Capacity);
        }
        cancellable(stop, async {
            while let Some(relative) = pending.pop_front() {
                check_stop(stop)?;
                let index = positions[&relative];
                let old_kind = merged.nodes[index].kind;
                if matches!(
                    merged.nodes[index].state,
                    NodeState::Complete | NodeState::Skipped | NodeState::Conflict
                ) {
                    continue;
                }
                let inspected = merged.inspect(sftp, &relative).await;
                let result: Result<(NodeKind, u64)> = async {
                    let (kind, size) = inspected?;
                    if old_kind != NodeKind::Unsupported && old_kind != kind {
                        return Err(TreeError::SourceKind);
                    }
                    if kind == NodeKind::Unsupported {
                        return Err(TreeError::SourceKind);
                    }
                    if kind == NodeKind::Directory {
                        // Enumeration also includes already-known names. Bound
                        // its temporary storage; final merged capacity is checked
                        // independently before any target writes.
                        let names = merged
                            .names(sftp, &relative, MAX_ENTRIES, MAX_PATH_BYTES)
                            .await?;
                        for name in names {
                            let next = child(&relative, &name)?;
                            if !positions.contains_key(&next) {
                                // Bound the frontier before adding metadata nodes.
                                path_bytes = path_bytes
                                    .checked_add(next.len())
                                    .ok_or(TreeError::Capacity)?;
                                if positions.len() >= MAX_ENTRIES || path_bytes > MAX_PATH_BYTES {
                                    return Err(TreeError::Capacity);
                                }
                                let index = merged.nodes.len();
                                merged.nodes.push(TransferNode {
                                    relative: next.clone(),
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
                                positions.insert(next.clone(), index);
                            }
                            if scheduled.insert(next.clone()) {
                                pending.push_back(next);
                            }
                        }
                    }
                    Ok((kind, size))
                }
                .await;
                let node = &mut merged.nodes[index];
                match result {
                    Ok((kind, size)) => {
                        node.kind = kind;
                        if kind == NodeKind::File && !node.started {
                            node.size = size;
                        }
                        node.state = NodeState::Pending;
                        node.error = None;
                    }
                    // Capacity aborts the whole candidate, never publish a
                    // partially enumerated directory as safely scanned.
                    Err(TreeError::Capacity) => return Err(TreeError::Capacity),
                    Err(error) => {
                        node.state = NodeState::Failed;
                        node.error = Some(error.to_string());
                    }
                }
                discovered(merged.nodes.len());
            }
            check_stop(stop)?;
            merged.validate()?;
            Ok(merged)
        })
        .await
    }

    async fn names(
        &self,
        sftp: &SftpSession,
        relative: &str,
        remaining: usize,
        byte_budget: usize,
    ) -> Result<Vec<String>> {
        let mut names = Vec::new();
        let mut path_bytes = 0usize;
        let mut add = |name: String| -> Result<()> {
            if name == "." || name == ".." {
                return Ok(());
            }
            let cost = name
                .len()
                .checked_add(if relative.is_empty() {
                    0
                } else {
                    relative.len() + 1
                })
                .ok_or(TreeError::Capacity)?;
            path_bytes = path_bytes.checked_add(cost).ok_or(TreeError::Capacity)?;
            if names.len() >= remaining || path_bytes > byte_budget {
                return Err(TreeError::Capacity);
            }
            names.push(name);
            Ok(())
        };
        match self.direction {
            Direction::Upload => {
                let mut entries = fs::read_dir(self.local.join(relative)).await?;
                while let Some(entry) = entries.next_entry().await? {
                    add(entry
                        .file_name()
                        .into_string()
                        .map_err(|_| TreeError::InvalidPlan)?)?;
                }
            }
            Direction::Download => {
                let mut entries = sftp
                    .read_dir_stream(remote_join(&self.remote, relative))
                    .await?;
                while let Some(page) = entries.next_page().await? {
                    for entry in page {
                        if let Err(error) = add(entry.filename) {
                            entries.close().await?;
                            return Err(error);
                        }
                    }
                }
            }
        }
        names.sort();
        Ok(names)
    }

    pub fn validate(&self) -> Result<()> {
        Self::new(self.direction, self.local.clone(), self.remote.clone())?;
        if self.version != 1 || self.nodes.is_empty() || self.nodes.len() > MAX_ENTRIES {
            return Err(TreeError::InvalidPlan);
        }
        let mut seen = HashMap::new();
        let mut total = 0u64;
        for node in &self.nodes {
            if !valid_relative(&node.relative)
                || node.acknowledged > node.size
                || (!node.started && node.acknowledged != 0)
                || (node.kind != NodeKind::File && (node.size != 0 || node.started))
                || (node.kind == NodeKind::Unsupported && node.state != NodeState::Failed)
                || (node.kind == NodeKind::File
                    && node.state == NodeState::Complete
                    && (!node.started || node.acknowledged != node.size))
            {
                return Err(TreeError::InvalidPlan);
            }
            if let Some(name) = &node.destination_name
                && (node.kind != NodeKind::File || child("", name)? != *name)
            {
                return Err(TreeError::InvalidPlan);
            }
            if node.kind == NodeKind::File {
                total = total.checked_add(node.size).ok_or(TreeError::Capacity)?;
            }
            if !node.relative.is_empty() {
                let parent = node
                    .relative
                    .rsplit_once('/')
                    .map_or("", |(parent, _)| parent);
                if seen.get(parent) != Some(&NodeKind::Directory) {
                    return Err(TreeError::InvalidPlan);
                }
            }
            if seen.insert(node.relative.as_str(), node.kind).is_some() {
                return Err(TreeError::InvalidPlan);
            }
        }
        if !self.nodes[0].relative.is_empty() {
            return Err(TreeError::InvalidPlan);
        }
        Ok(())
    }

    pub fn stats(&self) -> TreeStats {
        let mut s = TreeStats {
            total_known: true,
            ..TreeStats::default()
        };
        for node in &self.nodes {
            match node.kind {
                NodeKind::File => s.files += 1,
                NodeKind::Directory => s.directories += 1,
                _ => {}
            }
            match node.state {
                NodeState::Complete => s.complete += 1,
                NodeState::Failed => s.failed += 1,
                NodeState::Skipped => s.skipped += 1,
                NodeState::Conflict => s.conflicts += 1,
                _ => {}
            }
            s.total = s.total.saturating_add(node.size);
            s.acknowledged = s.acknowledged.saturating_add(node.acknowledged);
            if node.state == NodeState::Failed && node.kind != NodeKind::File {
                s.total_known = false;
            }
        }
        s
    }

    /// Retry one failed file without retransmitting any completed sibling.
    /// Failed directory discovery needs a fresh scan, never false completion.
    pub fn retry(&mut self, index: usize, decision: ConflictDecision) -> Result<()> {
        let node = self.nodes.get_mut(index).ok_or(TreeError::InvalidPlan)?;
        if node.kind != NodeKind::File
            || !matches!(node.state, NodeState::Failed | NodeState::Conflict)
        {
            return Err(TreeError::InvalidPlan);
        }
        node.default_policy_pending = false;
        node.decision = decision;
        if decision == ConflictDecision::Overwrite {
            // Explicit replacement is a restart, unlike an ordinary retry of
            // an acknowledged prefix. A changed/truncated destination must not
            // trap the user in an endlessly invalid Resume offset.
            node.acknowledged = 0;
            node.started = false;
        }
        node.state = NodeState::Pending;
        node.error = None;
        Ok(())
    }

    pub fn rename_destination(&mut self, index: usize, name: &str) -> Result<()> {
        if self.direction == Direction::Download && !crate::local_path::supported_relative(name) {
            return Err(TreeError::InvalidLocalPath);
        }
        child("", name)?;
        let node = self.nodes.get_mut(index).ok_or(TreeError::InvalidPlan)?;
        if node.kind != NodeKind::File
            || !matches!(node.state, NodeState::Failed | NodeState::Conflict)
        {
            return Err(TreeError::InvalidPlan);
        }
        node.default_policy_pending = false;
        node.destination_name = Some(name.into());
        // A new name starts at zero; an old partial file is deliberately retained.
        node.acknowledged = 0;
        node.started = false;
        node.decision = ConflictDecision::Ask;
        node.state = NodeState::Pending;
        node.error = None;
        Ok(())
    }

    /// Select unused destinations for the task's current conflicts without
    /// writing files. Caller must persist the whole candidate before running it.
    /// Exclusive creation still guards races after these metadata probes.
    pub async fn rename_conflicts(
        &self,
        sftp: &SftpSession,
        stop: &CancellationToken,
    ) -> Result<Self> {
        let indices: Vec<_> = self
            .nodes
            .iter()
            .enumerate()
            .filter(|(_, n)| n.kind == NodeKind::File && n.state == NodeState::Conflict)
            .map(|(i, _)| i)
            .collect();
        self.rename_selected_conflicts(&indices, sftp, stop).await
    }

    pub async fn rename_selected_conflicts(
        &self,
        indices: &[usize],
        sftp: &SftpSession,
        stop: &CancellationToken,
    ) -> Result<Self> {
        self.validate()?;
        check_stop(stop)?;
        if indices.is_empty() || indices.len() > self.nodes.len() {
            return Err(TreeError::InvalidPlan);
        }
        let mut seen = HashSet::new();
        for &index in indices {
            let node = self.nodes.get(index).ok_or(TreeError::InvalidPlan)?;
            if node.kind != NodeKind::File
                || node.state != NodeState::Conflict
                || !seen.insert(index)
            {
                return Err(TreeError::InvalidPlan);
            }
        }
        let key = |relative: &str| {
            if self.direction == Direction::Download && cfg!(windows) {
                relative.to_lowercase()
            } else {
                relative.to_owned()
            }
        };
        let mut reserved: HashSet<_> = self
            .nodes
            .iter()
            .map(|n| key(&mapped_relative(n, n.destination_name.as_deref())))
            .collect();
        let mut candidate = self.clone();
        cancellable(stop, async {
            for &index in indices {
                let node = &self.nodes[index];
                let original = node.destination_name.as_deref().unwrap_or_else(|| {
                    if node.relative.is_empty() {
                        if self.direction == Direction::Upload {
                            self.remote.rsplit('/').next().unwrap_or("")
                        } else {
                            self.local
                                .file_name()
                                .and_then(|n| n.to_str())
                                .unwrap_or("")
                        }
                    } else {
                        node.relative.rsplit('/').next().unwrap_or("")
                    }
                });
                child("", original)?;
                let mut selected = None;
                for number in 1..=10_000 {
                    check_stop(stop)?;
                    let name = numbered_name(original, number);
                    let mapped = mapped_relative(node, Some(&name));
                    if reserved.contains(&key(&mapped)) {
                        continue;
                    }
                    let exists = match self.direction {
                        Direction::Upload => {
                            let remote = if node.relative.is_empty() {
                                let parent = self
                                    .remote
                                    .rsplit_once('/')
                                    .ok_or(TreeError::InvalidPlan)?
                                    .0;
                                format!("{parent}/{name}")
                            } else {
                                remote_join(&self.remote, &mapped)
                            };
                            match sftp.symlink_metadata(remote).await {
                                Ok(_) => true,
                                Err(RemoteError::Status(s))
                                    if s.status_code == StatusCode::NoSuchFile =>
                                {
                                    false
                                }
                                Err(error) => return Err(error.into()),
                            }
                        }
                        Direction::Download => {
                            if !crate::local_path::supported_relative(&name) {
                                return Err(TreeError::InvalidLocalPath);
                            }
                            let local = if node.relative.is_empty() {
                                self.local
                                    .parent()
                                    .ok_or(TreeError::InvalidPlan)?
                                    .join(&name)
                            } else {
                                if !crate::local_path::supported_relative(&mapped) {
                                    return Err(TreeError::InvalidLocalPath);
                                }
                                local_join(&self.local, &mapped)
                            };
                            if !crate::local_path::supported(&local) {
                                return Err(TreeError::InvalidLocalPath);
                            }
                            match fs::symlink_metadata(local).await {
                                Ok(_) => true,
                                Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
                                Err(error) => return Err(error.into()),
                            }
                        }
                    };
                    if !exists {
                        reserved.insert(key(&mapped));
                        selected = Some(name);
                        break;
                    }
                }
                let name = selected.ok_or(TreeError::RenameCapacity)?;
                candidate.rename_destination(index, &name)?;
                if node.relative.is_empty() {
                    match self.direction {
                        Direction::Upload => {
                            let parent = self
                                .remote
                                .rsplit_once('/')
                                .ok_or(TreeError::InvalidPlan)?
                                .0;
                            candidate.remote = format!("{parent}/{name}");
                        }
                        Direction::Download => {
                            candidate.local = self
                                .local
                                .parent()
                                .ok_or(TreeError::InvalidPlan)?
                                .join(name);
                        }
                    }
                    candidate.nodes[index].destination_name = None;
                }
            }
            check_stop(stop)?;
            candidate.validate()?;
            Ok(candidate)
        })
        .await
    }

    /// Caller owns task scheduling and durable checkpoints. Notifications are
    /// synchronous metadata only; never copy payloads or block on UI decisions.
    pub async fn run(
        &mut self,
        sftp: &SftpSession,
        stop: &CancellationToken,
        changed: impl FnMut(&Self, Option<usize>),
    ) -> Result<TreeOutcome> {
        self.run_limited(
            sftp,
            stop,
            changed,
            &crate::bandwidth::BandwidthLimiter::default(),
        )
        .await
    }

    pub async fn run_limited(
        &mut self,
        sftp: &SftpSession,
        stop: &CancellationToken,
        mut changed: impl FnMut(&Self, Option<usize>),
        limiter: &crate::bandwidth::BandwidthLimiter,
    ) -> Result<TreeOutcome> {
        self.run_observed(
            sftp,
            stop,
            |plan, progress| changed(plan, progress.current),
            limiter,
        )
        .await
    }

    /// Same writes and notifications as run_limited, plus O(1) statistics and
    /// the observed node index. Rebuild the accumulator once per run, after
    /// validating the real manifest; no persisted or caller-supplied counts.
    pub async fn run_observed(
        &mut self,
        sftp: &SftpSession,
        stop: &CancellationToken,
        mut changed: impl FnMut(&Self, TreeProgress),
        limiter: &crate::bandwidth::BandwidthLimiter,
    ) -> Result<TreeOutcome> {
        self.validate()?;
        let mut stats = stats::Accumulator::new(&self.nodes);
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
            if self.nodes[index].state != NodeState::Pending
                && !(self.nodes[index].kind == NodeKind::Directory
                    && self.nodes[index].state == NodeState::Complete)
            {
                continue;
            }
            let mut previous = stats::Contribution::from(&self.nodes[index]);
            let mut notify = |plan: &Self, current| {
                let next = stats::Contribution::from(&plan.nodes[index]);
                stats.replace(previous, next);
                previous = next;
                changed(
                    plan,
                    TreeProgress {
                        index,
                        current,
                        stats: stats.snapshot(),
                    },
                );
            };
            let relative = self.nodes[index].relative.clone();
            let mapped = if self.direction == Direction::Download && !relative.is_empty() {
                if let Some(name) = &self.nodes[index].destination_name {
                    relative
                        .rsplit_once('/')
                        .map_or_else(|| name.clone(), |(parent, _)| format!("{parent}/{name}"))
                } else {
                    relative.clone()
                }
            } else {
                relative.clone()
            };
            if !crate::local_path::supported_relative(&mapped) {
                let node = &mut self.nodes[index];
                node.state = NodeState::Failed;
                node.error = Some(TreeError::InvalidLocalPath.to_string());
                if node.kind == NodeKind::Directory {
                    blocked.insert(relative);
                }
                notify(self, None);
                continue;
            }
            let mut remote = remote_join(&self.remote, &relative);
            let mut local = local_join(&self.local, &mapped);
            if let Some(name) = &self.nodes[index].destination_name {
                match self.direction {
                    Direction::Upload => {
                        let parent = remote.rsplit_once('/').ok_or(TreeError::InvalidPlan)?.0;
                        remote = format!("{parent}/{name}");
                    }
                    Direction::Download if relative.is_empty() => {
                        local = local.parent().ok_or(TreeError::InvalidPlan)?.join(name)
                    }
                    Direction::Download => {}
                }
            }
            // A failed destination parent must not allow children to follow a
            // symlink or create contents outside this task's directory tree.
            if blocked_parent(&relative, &blocked) {
                self.nodes[index].state = NodeState::Failed;
                self.nodes[index].error = Some("父目录未成功创建或不能安全访问".into());
                notify(self, None);
                continue;
            }
            if self.nodes[index].kind == NodeKind::Directory {
                let result = cancellable(
                    stop,
                    ensure_directory(self.direction, sftp, &local, &remote),
                )
                .await;
                if matches!(result, Err(TreeError::Cancelled)) {
                    return Ok(TreeOutcome::Paused);
                }
                let node = &mut self.nodes[index];
                match result {
                    Ok(()) => node.state = NodeState::Complete,
                    Err(e) => {
                        node.state = NodeState::Failed;
                        node.error = Some(e.to_string());
                        blocked.insert(relative);
                    }
                }
                notify(self, None);
                continue;
            }
            if self.nodes[index].decision == ConflictDecision::Skip {
                self.nodes[index].state = NodeState::Skipped;
                notify(self, None);
                continue;
            }
            let node = &self.nodes[index];
            let mode = if node.started {
                FileDisposition::Resume {
                    offset: node.acknowledged,
                }
            } else if node.decision == ConflictDecision::Overwrite {
                FileDisposition::Overwrite
            } else {
                FileDisposition::CreateNew
            };
            notify(self, Some(index));
            let direction = self.direction;
            let mut progress = |p: transfer::FileProgress| {
                self.nodes[index].started = true;
                self.nodes[index].size = p.total;
                self.nodes[index].acknowledged = p.acknowledged;
                notify(self, Some(index));
            };
            let result = match direction {
                Direction::Upload => {
                    transfer::upload_file_limited(
                        sftp,
                        &local,
                        &remote,
                        mode,
                        stop,
                        &mut progress,
                        limiter,
                    )
                    .await
                }
                Direction::Download => {
                    transfer::download_file_limited(
                        sftp,
                        &remote,
                        &local,
                        mode,
                        stop,
                        &mut progress,
                        limiter,
                    )
                    .await
                }
            };
            let node = &mut self.nodes[index];
            match result {
                Ok(_) => {
                    node.state = NodeState::Complete;
                    node.error = None;
                }
                Err(TransferError::Cancelled) => {
                    notify(self, None);
                    return Ok(TreeOutcome::Paused);
                }
                Err(TransferError::Conflict) => {
                    node.state = NodeState::Conflict;
                    node.error = Some("目标已存在，等待覆盖、跳过或更名决定".into());
                }
                Err(error) => {
                    node.state = NodeState::Failed;
                    node.error = Some(error.to_string());
                }
            }
            notify(self, None);
        }
        let stats = stats.snapshot();
        Ok(if stats.failed == 0 && stats.conflicts == 0 {
            if stats.skipped == 0 {
                TreeOutcome::Complete
            } else {
                TreeOutcome::CompleteWithSkips
            }
        } else {
            TreeOutcome::Partial
        })
    }
}

async fn ensure_directory(
    direction: Direction,
    sftp: &SftpSession,
    local: &Path,
    remote: &str,
) -> Result<()> {
    if direction == Direction::Download && !crate::local_path::supported(local) {
        return Err(TreeError::InvalidLocalPath);
    }
    match direction {
        Direction::Upload => match sftp.symlink_metadata(remote).await {
            Ok(m) if m.is_dir() && !m.is_symlink() => Ok(()),
            Ok(_) => Err(TreeError::InvalidPlan),
            Err(RemoteError::Status(s)) if s.status_code == StatusCode::NoSuchFile => {
                Ok(sftp.create_dir(remote).await?)
            }
            Err(e) => Err(e.into()),
        },
        Direction::Download => match fs::symlink_metadata(local).await {
            Ok(m) if m.is_dir() && !m.is_symlink() => Ok(()),
            Ok(_) => Err(TreeError::InvalidPlan),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(fs::create_dir(local).await?),
            Err(e) => Err(e.into()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn directory(relative: &str) -> TransferNode {
        TransferNode {
            relative: relative.into(),
            kind: NodeKind::Directory,
            size: 0,
            acknowledged: 0,
            started: false,
            state: NodeState::Pending,
            decision: ConflictDecision::Ask,
            destination_name: None,
            error: None,
            default_policy_pending: true,
        }
    }
    fn plan() -> TreeTransfer {
        // Use an absolute path on the running platform; no real files required.
        let mut p =
            TreeTransfer::new(Direction::Upload, std::env::temp_dir(), "/fixture".into()).unwrap();
        p.nodes.push(directory(""));
        p
    }
    #[tokio::test]
    async fn directory_names_respect_the_remaining_frontier_budget() {
        struct NoFileOps;
        impl russh_sftp::server::Handler for NoFileOps {
            type Error = StatusCode;
            fn unimplemented(&self) -> Self::Error {
                StatusCode::OpUnsupported
            }
        }
        let (client, server) = tokio::io::duplex(4096);
        tokio::spawn(russh_sftp::server::run(server, NoFileOps));
        let sftp = SftpSession::new(client).await.unwrap();
        let temp = tempfile::tempdir().unwrap();
        for name in ["a", "b", "c"] {
            fs::write(temp.path().join(name), []).await.unwrap();
        }
        let plan =
            TreeTransfer::new(Direction::Upload, temp.path().into(), "/fixture".into()).unwrap();
        assert!(matches!(
            plan.names(&sftp, "", 2, 1024).await,
            Err(TreeError::Capacity)
        ));
        assert_eq!(
            plan.names(&sftp, "", 3, 1024).await.unwrap(),
            ["a", "b", "c"]
        );
        assert!(matches!(
            plan.names(&sftp, "", 3, 2).await,
            Err(TreeError::Capacity)
        ));
        assert_eq!(plan.names(&sftp, "", 3, 3).await.unwrap(), ["a", "b", "c"]);
        fs::create_dir(temp.path().join("empty")).await.unwrap();
        assert!(plan.names(&sftp, "empty", 0, 0).await.unwrap().is_empty());
        fs::create_dir(temp.path().join("目录")).await.unwrap();
        for name in ["中文", "é"] {
            fs::write(temp.path().join("目录").join(name), [])
                .await
                .unwrap();
        }
        assert!(matches!(
            plan.names(&sftp, "目录", 2, 22).await,
            Err(TreeError::Capacity)
        ));
        assert_eq!(
            plan.names(&sftp, "目录", 2, 23).await.unwrap(),
            ["é", "中文"]
        );
        sftp.close().await.unwrap();
    }

    #[test]
    fn rejects_traversal_duplicates_missing_parents_and_corrupt_offsets() {
        for name in ["..", ".", "a/../b", "/absolute", "a//b", "nul\0name"] {
            let mut p = plan();
            p.nodes.push(directory(name));
            assert!(p.validate().is_err());
        }
        let mut p = plan();
        p.nodes.push(directory(""));
        assert!(p.validate().is_err());
        let mut p = plan();
        p.nodes.push(directory("missing/child"));
        assert!(p.validate().is_err());
        let mut p = plan();
        p.nodes.push(TransferNode {
            kind: NodeKind::File,
            size: 10,
            acknowledged: 11,
            started: true,
            ..directory("file")
        });
        assert!(p.validate().is_err());
        p.nodes[1].acknowledged = 5;
        p.nodes[1].started = false;
        assert!(p.validate().is_err());
        p.nodes[1].started = true;
        p.nodes[1].state = NodeState::Complete;
        assert!(p.validate().is_err());
        p.nodes[1].acknowledged = 10;
        assert!(p.validate().is_ok());
        assert!(child("", "../escape").is_err());
        assert!(child("", "a/b").is_err());
    }
    #[test]
    fn old_checkpoints_and_explicit_decisions_cannot_silently_use_a_new_default() {
        let mut p = plan();
        p.nodes.push(TransferNode {
            kind: NodeKind::File,
            size: 10,
            state: NodeState::Conflict,
            ..directory("file")
        });
        assert!(p.nodes[1].default_policy_pending);
        let mut old = serde_json::to_value(&p).unwrap();
        for node in old["nodes"].as_array_mut().unwrap() {
            node.as_object_mut()
                .unwrap()
                .remove("default_policy_pending");
        }
        let old: TreeTransfer = serde_json::from_value(old).unwrap();
        old.validate().unwrap();
        assert!(!old.nodes[1].default_policy_pending);
        p.retry(1, ConflictDecision::Ask).unwrap();
        assert!(!p.nodes[1].default_policy_pending);
        p.nodes[1].state = NodeState::Conflict;
        p.nodes[1].default_policy_pending = true;
        p.rename_destination(1, "manual-choice").unwrap();
        assert!(!p.nodes[1].default_policy_pending);
    }

    #[test]
    fn blocked_ancestors_and_unknown_totals_remain_explicit() {
        let mut p = plan();
        p.nodes.push(directory("nested"));
        p.nodes[1].state = NodeState::Failed;
        assert!(!p.stats().total_known);
        let blocked = HashSet::from(["nested".into()]);
        assert!(blocked_parent("nested/a/b", &blocked));
        assert!(!blocked_parent("nested-other/a", &blocked));
        assert!(!blocked_parent("root-file", &blocked));
        assert!(blocked_parent("root-file", &HashSet::from(["".into()])));
        assert!(!blocked_parent("", &HashSet::from(["".into()])));
        assert!(p.retry(1, ConflictDecision::Overwrite).is_err());
        p.version = 2;
        assert!(p.validate().is_err());
    }
}
