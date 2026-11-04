//! Pull-based directory metadata. No speculative READDIR or filesystem writes.
use crate::SftpSession;
use russh_sftp::client::{error::Error as RemoteError, fs::ReadDirStream};
use std::collections::{HashSet, VecDeque};

pub const MAX_PAGE: usize = 256;
pub const MAX_PAGE_BYTES: usize = 256 * 1024;
const MAX_ENTRIES: usize = 1_000_000;
const MAX_PATH_BYTES: usize = 32 * 1024 * 1024;
#[derive(Clone, Debug)]
pub struct DirectoryEntry {
    pub name: String,
    pub path: String,
    pub directory: bool,
    pub symlink: bool,
    pub size: Option<u64>,
    pub modified: Option<u32>,
    pub permissions: Option<u32>,
}
pub struct DirectoryPage {
    pub entries: Vec<DirectoryEntry>,
    pub done: bool,
}
#[derive(thiserror::Error, Debug)]
pub enum DirectoryError {
    #[error("服务器返回无效的目录路径或文件名")]
    InvalidPath,
    #[error("目录元数据超过安全容量；原目录缓存未修改")]
    Capacity,
    #[error("此目录读取已失败或被中断，请重新打开")]
    Interrupted,
    #[error("目录分页大小必须为1–256")]
    InvalidPage,
    #[error("目录读取失败；请检查连接和目录权限")]
    Remote(#[from] RemoteError),
}
/// The owner closes the dedicated SFTP channel on cancellation. This also
/// releases server handles when OPENDIR was cancelled before its reply arrived.
pub struct DirectoryReader {
    path: String,
    stream: ReadDirStream,
    pending: VecDeque<DirectoryEntry>,
    seen: HashSet<String>,
    path_bytes: usize,
    done: bool,
    failed: bool,
}
impl DirectoryReader {
    pub async fn open(sftp: &SftpSession, path: String) -> Result<Self, DirectoryError> {
        if path.is_empty() || path.len() > 131072 || path.contains('\0') {
            return Err(DirectoryError::InvalidPath);
        }
        let path = sftp.canonicalize(path).await?;
        if !path.starts_with('/') || path.len() > 131072 || path.contains('\0') {
            return Err(DirectoryError::InvalidPath);
        }
        let stream = sftp.read_dir_stream(path.clone()).await?;
        Ok(Self {
            path,
            stream,
            pending: VecDeque::new(),
            seen: HashSet::new(),
            path_bytes: 0,
            done: false,
            failed: false,
        })
    }
    pub fn path(&self) -> &str {
        &self.path
    }
    pub async fn next_page(&mut self, limit: usize) -> Result<DirectoryPage, DirectoryError> {
        if !(1..=MAX_PAGE).contains(&limit) {
            return Err(DirectoryError::InvalidPage);
        }
        if self.failed {
            return Err(DirectoryError::Interrupted);
        }
        // A dropped future must not be reused after consuming only part of a
        // page or losing a pending READDIR reply. Failure remains latched.
        self.failed = true;
        let result = self.read_page(limit).await;
        if result.is_ok() {
            self.failed = false;
        }
        result
    }
    async fn read_page(&mut self, limit: usize) -> Result<DirectoryPage, DirectoryError> {
        let mut bytes = 0usize;
        let mut replies = 0usize;
        let mut entries = Vec::with_capacity(limit);
        while entries.len() < limit {
            if let Some(entry) = self.pending.pop_front() {
                let cost = entry.path.len() + entry.name.len() + 128;
                if cost > MAX_PAGE_BYTES {
                    return Err(DirectoryError::Capacity);
                }
                if bytes + cost > MAX_PAGE_BYTES {
                    self.pending.push_front(entry);
                    break;
                }
                bytes += cost;
                entries.push(entry);
                continue;
            }
            if self.done {
                break;
            }
            replies += 1;
            if replies > 1024 {
                return Err(DirectoryError::Capacity);
            }
            match self.stream.next_page().await? {
                None => self.done = true,
                Some(page) => {
                    for file in page {
                        let name = file.filename;
                        if name == "." || name == ".." {
                            continue;
                        }
                        if name.is_empty()
                            || name.contains('/')
                            || name.contains('\0')
                            || !self.seen.insert(name.clone())
                        {
                            return Err(DirectoryError::InvalidPath);
                        }
                        let path = format!("{}/{}", self.path.trim_end_matches('/'), name);
                        self.path_bytes = self
                            .path_bytes
                            .checked_add(path.len())
                            .ok_or(DirectoryError::Capacity)?;
                        if self.seen.len() > MAX_ENTRIES || self.path_bytes > MAX_PATH_BYTES {
                            return Err(DirectoryError::Capacity);
                        }
                        let a = file.attrs;
                        self.pending.push_back(DirectoryEntry {
                            name,
                            path,
                            directory: a.is_dir(),
                            symlink: a.is_symlink(),
                            size: a.size,
                            modified: a.mtime,
                            permissions: a.permissions,
                        });
                    }
                }
            }
        }
        Ok(DirectoryPage {
            entries,
            done: self.done && self.pending.is_empty(),
        })
    }
    pub async fn close(&mut self) -> Result<(), DirectoryError> {
        self.done = true;
        self.pending.clear();
        let failed = self.failed;
        self.failed = true;
        self.stream.close().await?;
        self.failed = failed;
        Ok(())
    }
}
