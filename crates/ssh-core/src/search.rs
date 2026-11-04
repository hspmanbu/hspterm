//! Explicit, pull-based recursive filename search. Reads metadata only, on the
//! caller's existing SSH transport. Never follows child directory symlinks.
use crate::{
    SftpSession,
    directory::{DirectoryEntry, DirectoryError, DirectoryReader, MAX_PAGE, MAX_PAGE_BYTES},
};
use std::collections::{HashSet, VecDeque};
use tokio_util::sync::CancellationToken;

const MAX_SCANNED: u64 = 1_000_000;
const MAX_PATH_BYTES: usize = 32 * 1024 * 1024;
const SCAN_PER_PAGE: usize = 1024;
const DIRECTORIES_PER_PAGE: usize = 32;
#[derive(thiserror::Error, Debug)]
pub enum SearchError {
    #[error("文件名搜索文字不能为空或超过容量")]
    InvalidQuery,
    #[error("搜索分页大小必须为1–256")]
    InvalidPage,
    #[error("目录搜索已取消；已找到结果不代表完整搜索")]
    Cancelled,
    #[error("目录搜索已关闭或中断，请重新开始")]
    Interrupted,
    #[error("目录搜索超过安全容量；已找到结果不代表完整搜索")]
    Capacity,
    #[error("子目录已改变或跳出搜索根目录，搜索未完成")]
    EscapedRoot,
    #[error(transparent)]
    Directory(#[from] DirectoryError),
    #[error("搜索目录属性读取失败")]
    Remote(#[from] russh_sftp::client::error::Error),
}
type Result<T> = std::result::Result<T, SearchError>;
pub struct SearchPage {
    pub matches: Vec<DirectoryEntry>,
    pub scanned: u64,
    pub directories: u64,
    pub done: bool,
}
pub struct RecursiveSearch {
    root: String,
    query: String,
    case_sensitive: bool,
    current: Option<DirectoryReader>,
    entries: VecDeque<DirectoryEntry>,
    pending: VecDeque<String>,
    visited: HashSet<String>,
    path_bytes: usize,
    canonical_bytes: usize,
    scanned: u64,
    directories: u64,
    failed: bool,
    closed: bool,
}
fn within_root(root: &str, candidate: &str) -> bool {
    if candidate.len() > 131072
        || !candidate.starts_with('/')
        || candidate.contains('\0')
        || candidate.split('/').any(|p| p == "." || p == "..")
    {
        return false;
    }
    root == "/"
        || candidate == root
        || candidate
            .strip_prefix(root)
            .is_some_and(|tail| tail.starts_with('/'))
}
impl RecursiveSearch {
    /// The explicitly chosen root may be a symlink, like entering it in SFTP.
    /// Descendant symlinks are results, not traversal targets.
    pub async fn open(
        sftp: &SftpSession,
        root: &str,
        query: &str,
        case_sensitive: bool,
        stop: &CancellationToken,
    ) -> Result<Self> {
        if query.is_empty() || query.len() > 4096 || query.contains('\0') {
            return Err(SearchError::InvalidQuery);
        }
        let query = if case_sensitive {
            query.to_owned()
        } else {
            query.to_lowercase()
        };
        let open = async {
            let mut reader = DirectoryReader::open(sftp, root.to_owned()).await?;
            if !within_root("/", reader.path()) {
                reader.close().await?;
                return Err(SearchError::EscapedRoot);
            }
            let root = reader.path().trim_end_matches('/');
            let root = if root.is_empty() {
                "/".to_owned()
            } else {
                root.to_owned()
            };
            let mut visited = HashSet::new();
            visited.insert(root.clone());
            Ok(Self {
                path_bytes: root.len(),
                canonical_bytes: root.len(),
                root,
                query,
                case_sensitive,
                current: Some(reader),
                entries: VecDeque::new(),
                pending: VecDeque::new(),
                visited,
                scanned: 0,
                directories: 1,
                failed: false,
                closed: false,
            })
        };
        tokio::select! { biased; _ = stop.cancelled() => Err(SearchError::Cancelled), result = open => result }
    }
    pub fn root(&self) -> &str {
        &self.root
    }
    /// At most 1024 entries are inspected per pull, including when none match.
    /// Cancellation/dropped futures latch failure. The owner closes the dedicated
    /// SFTP channel on cancellation, including a lost OPENDIR/READDIR reply.
    pub async fn next_page(
        &mut self,
        sftp: &SftpSession,
        limit: usize,
        stop: &CancellationToken,
    ) -> Result<SearchPage> {
        if !(1..=MAX_PAGE).contains(&limit) {
            return Err(SearchError::InvalidPage);
        }
        if self.failed || self.closed {
            return Err(SearchError::Interrupted);
        }
        self.failed = true;
        let result = tokio::select! { biased; _ = stop.cancelled() => Err(SearchError::Cancelled), result = self.read_page(sftp, limit) => result };
        if result.is_ok() {
            self.failed = false;
        }
        result
    }
    async fn read_page(&mut self, sftp: &SftpSession, limit: usize) -> Result<SearchPage> {
        let mut matches = Vec::new();
        let mut bytes = 0;
        let mut inspected = 0;
        let mut opened = 0;
        while matches.len() < limit && inspected < SCAN_PER_PAGE && opened < DIRECTORIES_PER_PAGE {
            if let Some(mut entry) = self.entries.pop_front() {
                let cost = entry.path.len() + entry.name.len() + 128;
                if cost > MAX_PAGE_BYTES {
                    return Err(SearchError::Capacity);
                }
                let found = if self.case_sensitive {
                    entry.name.contains(&self.query)
                } else {
                    entry.name.to_lowercase().contains(&self.query)
                };
                if found && bytes + cost > MAX_PAGE_BYTES {
                    self.entries.push_front(entry);
                    break;
                }
                // Some SFTP implementations omit attributes in READDIR. Fetch
                // only missing type information; never read a file's contents.
                if entry.permissions.is_none() {
                    let attrs = sftp.symlink_metadata(&entry.path).await?;
                    entry.directory = attrs.is_dir();
                    entry.symlink = attrs.is_symlink();
                    entry.permissions = attrs.permissions;
                }
                inspected += 1;
                self.scanned += 1;
                if self.scanned > MAX_SCANNED {
                    return Err(SearchError::Capacity);
                }
                if entry.directory && !entry.symlink {
                    self.path_bytes = self
                        .path_bytes
                        .checked_add(entry.path.len())
                        .ok_or(SearchError::Capacity)?;
                    if self.path_bytes > MAX_PATH_BYTES {
                        return Err(SearchError::Capacity);
                    }
                    self.pending.push_back(entry.path.clone());
                }
                if found {
                    bytes += cost;
                    matches.push(entry);
                }
                continue;
            }
            if let Some(reader) = &mut self.current {
                let page = reader.next_page(MAX_PAGE).await?;
                self.entries.extend(page.entries);
                if page.done {
                    reader.close().await?;
                    self.current = None;
                }
                continue;
            }
            let Some(path) = self.pending.pop_front() else {
                break;
            };
            // A directory can be replaced after it was listed. Refuse links and
            // verify canonical containment before requesting child metadata.
            let attrs = sftp.symlink_metadata(&path).await?;
            if attrs.is_symlink() {
                continue;
            }
            if !attrs.is_dir() {
                return Err(SearchError::EscapedRoot);
            }
            let canonical = sftp.canonicalize(path).await?;
            if !within_root(&self.root, &canonical) {
                return Err(SearchError::EscapedRoot);
            }
            if self.visited.contains(&canonical) {
                continue;
            }
            self.canonical_bytes = self
                .canonical_bytes
                .checked_add(canonical.len())
                .ok_or(SearchError::Capacity)?;
            if self.canonical_bytes > MAX_PATH_BYTES {
                return Err(SearchError::Capacity);
            }
            self.visited.insert(canonical.clone());
            let mut reader = DirectoryReader::open(sftp, canonical).await?;
            if !within_root(&self.root, reader.path()) {
                reader.close().await?;
                return Err(SearchError::EscapedRoot);
            }
            self.directories += 1;
            opened += 1;
            self.current = Some(reader);
        }
        Ok(SearchPage {
            matches,
            scanned: self.scanned,
            directories: self.directories,
            done: self.current.is_none() && self.entries.is_empty() && self.pending.is_empty(),
        })
    }
    pub async fn close(&mut self) -> Result<()> {
        self.closed = true;
        self.entries.clear();
        self.pending.clear();
        self.visited.clear();
        if let Some(mut current) = self.current.take() {
            current.close().await?;
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn canonical_containment_requires_a_component_boundary() {
        assert!(within_root("/", "/anywhere"));
        assert!(within_root("/home/中文", "/home/中文/sub"));
        assert!(within_root("/home/中文", "/home/中文"));
        assert!(!within_root("/home/a", "/home/another"));
        assert!(!within_root("/home/a", "/home"));
        assert!(!within_root("/", "relative"));
        assert!(!within_root("/home/a", "/home/a/../escape"));
    }
}
