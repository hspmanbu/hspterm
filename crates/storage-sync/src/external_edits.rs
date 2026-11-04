//! Persistent, private external-editor work files. Never preview cleanup data.
//! Drop releases only the lease. Deletion requires a separate confirmed action.
use fs2::FileExt;
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    time::SystemTime,
};
use zeroize::Zeroizing;

pub const DIRECTORY: &str = "hspterm-editing-v1";
const MARKER: &str = "format-v1";
const OWNER: &str = "owner.lock";
pub const MAX_WORK_BYTES: usize = super::local_edits::MAX_TEXT_BYTES * 2 + 2;

pub struct ExternalCopy {
    directory: PathBuf,
    path: PathBuf,
    owner: Option<File>,
}
pub struct WorkSnapshot {
    pub bytes: Zeroizing<Vec<u8>>,
    pub modified: SystemTime,
}
/// A bounded-memory read under the owning copy's lease. Finishing checks that
/// this opened file did not change; callers compare a second capture to handle
/// editors which atomically replace the pathname while the old inode is open.
pub struct WorkReader<'a> {
    file: File,
    before: fs::Metadata,
    _copy: &'a ExternalCopy,
}
impl Read for WorkReader<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.file.read(buffer)
    }
}
impl WorkReader<'_> {
    pub fn length(&self) -> u64 {
        self.before.len()
    }
    pub fn finish(self) -> io::Result<()> {
        let after = ordinary(&self.file)?;
        if self.before.len() != after.len() || self.before.modified()? != after.modified()? {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "编辑文件仍在变化，请稍后重试",
            ));
        }
        Ok(())
    }
}
impl PartialEq for WorkSnapshot {
    fn eq(&self, other: &Self) -> bool {
        self.modified == other.modified && self.bytes == other.bytes
    }
}
fn invalid(message: &str) -> io::Error {
    io::Error::other(message)
}
pub fn valid_location(path: &Path, id: &str) -> bool {
    path.is_absolute()
        && path.file_name().is_some_and(|n| n == id)
        && path
            .parent()
            .and_then(Path::file_name)
            .is_some_and(|n| n == DIRECTORY)
        && id
            .strip_prefix("edit-")
            .is_some_and(|v| v.len() == 32 && v.bytes().all(|c| c.is_ascii_hexdigit()))
}
fn private_directory(path: &Path, create: bool) -> io::Result<()> {
    if create {
        let builder = fs::DirBuilder::new();
        #[cfg(unix)]
        let mut builder = builder;
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        if let Err(e) = builder.create(path)
            && e.kind() != io::ErrorKind::AlreadyExists
        {
            return Err(e);
        }
    }
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err(invalid("编辑工作目录不是安全目录"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.uid() != rustix::process::geteuid().as_raw() || meta.mode() & 0o077 != 0 {
            return Err(invalid("编辑工作目录所有者或权限不安全"));
        }
    }
    Ok(())
}
fn options(read: bool, write: bool, create_new: bool) -> OpenOptions {
    let mut options = OpenOptions::new();
    options.read(read).write(write).create_new(create_new);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(
            (rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32,
        );
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // Open a reparse point itself; metadata validation below rejects it.
        options.custom_flags(0x0020_0000);
    }
    options
}
fn ordinary(file: &File) -> io::Result<fs::Metadata> {
    let meta = file.metadata()?;
    if !meta.is_file() || meta.file_type().is_symlink() {
        return Err(invalid("编辑工作文件不是普通文件"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        // Atomic-save editors can replace 0600 with 0644. The enclosing 0700
        // directories still protect it; reject aliases escaping that boundary.
        if meta.uid() != rustix::process::geteuid().as_raw() || meta.nlink() != 1 {
            return Err(invalid("编辑工作文件所有者或链接数不安全"));
        }
    }
    Ok(meta)
}
fn name(original: &str) -> String {
    let extension = original
        .rsplit_once('.')
        .map(|(_, e)| e)
        .filter(|e| !e.is_empty() && e.len() <= 32 && e.bytes().all(|c| c.is_ascii_alphanumeric()));
    extension.map_or_else(|| "document.txt".into(), |e| format!("document.{e}"))
}
impl ExternalCopy {
    /// Compute/pin this location in the encrypted journal BEFORE creating files.
    pub fn location(base: &Path, id: &str) -> io::Result<PathBuf> {
        if !base.is_absolute() {
            return Err(invalid("编辑工作目录需要绝对路径"));
        }
        let base = fs::canonicalize(base)?;
        let directory = base.join(DIRECTORY).join(id);
        if !valid_location(&directory, id) {
            return Err(invalid("编辑工作目录标识无效"));
        }
        Ok(directory)
    }
    /// Reopen never truncates an existing file, even if a prior launch crashed.
    /// Missing initialization files use create_new; existing bodies are retained.
    pub fn open(
        directory: &Path,
        id: &str,
        original: &str,
        initial: &[u8],
    ) -> io::Result<(Self, bool)> {
        if initial.len() > MAX_WORK_BYTES {
            return Err(invalid("外部文本工作文件超过容量，未截断"));
        }
        Self::open_initialized(
            directory,
            id,
            original,
            |file| file.write_all(initial),
            true,
        )
    }
    /// The caller has pinned this location and holds a complete encrypted body.
    /// Initialisation streams only into a new file, never an existing work copy.
    /// A failed callback leaves its partial file for explicit recovery; no marker
    /// is published and no data is truncated on reopen.
    pub fn open_stream(
        directory: &Path,
        id: &str,
        original: &str,
        initialize: impl FnOnce(&mut File) -> io::Result<()>,
    ) -> io::Result<(Self, bool)> {
        Self::open_initialized(directory, id, original, initialize, false)
    }
    fn open_initialized(
        directory: &Path,
        id: &str,
        original: &str,
        initialize: impl FnOnce(&mut File) -> io::Result<()>,
        allow_incomplete: bool,
    ) -> io::Result<(Self, bool)> {
        if !valid_location(directory, id) {
            return Err(invalid("编辑工作目录标识无效"));
        }
        let root = directory
            .parent()
            .ok_or_else(|| invalid("编辑工作根无效"))?;
        private_directory(root, true)?;
        let created = match fs::symlink_metadata(directory) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                private_directory(directory, true)?;
                true
            }
            Err(e) => return Err(e),
            Ok(_) => {
                private_directory(directory, false)?;
                false
            }
        };
        let owner_path = directory.join(OWNER);
        let owner = match options(true, true, false).open(&owner_path) {
            Ok(file) => file,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                options(true, true, true).open(&owner_path)?
            }
            Err(e) => return Err(e),
        };
        ordinary(&owner)?;
        owner.try_lock_exclusive().map_err(|e| {
            if e.kind() == io::ErrorKind::WouldBlock {
                invalid("另一编辑实例仍在使用工作文件")
            } else {
                e
            }
        })?;
        let filename = name(original);
        let path = directory.join(&filename);
        let marker = format!("hspterm-external-editor-v1\n{filename}\n");
        let copy = Self {
            directory: directory.into(),
            path,
            owner: Some(owner),
        };
        if created {
            let mut file = options(false, true, true).open(copy.path())?;
            initialize(&mut file)?;
            file.sync_all()?;
            let mut file = options(false, true, true).open(directory.join(MARKER))?;
            file.write_all(marker.as_bytes())?;
            file.sync_all()?;
        } else {
            match options(true, false, false).open(directory.join(MARKER)) {
                Ok(mut file) => {
                    ordinary(&file)?;
                    let mut raw = Vec::new();
                    Read::by_ref(&mut file).take(160).read_to_end(&mut raw)?;
                    if raw != marker.as_bytes() {
                        return Err(invalid("编辑工作目录格式未知；原文件未覆盖"));
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    // A crash before the marker was durable. Never truncate an
                    // existing body; complete only absent initialization files.
                    match options(false, true, true).open(copy.path()) {
                        Ok(mut file) => {
                            initialize(&mut file)?;
                            file.sync_all()?;
                        }
                        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                            if !allow_incomplete {
                                return Err(invalid(
                                    "上次大文件初始化未完成；部分工作文件保留，请确认结束并清理后再打开",
                                ));
                            }
                        }
                        Err(e) => return Err(e),
                    }
                    let mut file = options(false, true, true).open(directory.join(MARKER))?;
                    file.write_all(marker.as_bytes())?;
                    file.sync_all()?;
                }
                Err(e) => return Err(e),
            }
            // Do not interpret contents during metadata/open; capture is explicit.
        }
        Ok((copy, !created))
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
    pub fn is_leased(&self) -> bool {
        self.owner.is_some()
    }
    pub fn directory(&self) -> &Path {
        &self.directory
    }
    pub fn reader(&self) -> io::Result<WorkReader<'_>> {
        if self.owner.is_none() {
            return Err(invalid("编辑工作文件租约已释放"));
        }
        private_directory(
            self.directory
                .parent()
                .ok_or_else(|| invalid("编辑根无效"))?,
            false,
        )?;
        private_directory(&self.directory, false)?;
        let file = options(true, false, false).open(&self.path)?;
        let before = ordinary(&file)?;
        Ok(WorkReader {
            file,
            before,
            _copy: self,
        })
    }
    pub fn snapshot(&self) -> io::Result<WorkSnapshot> {
        if self.owner.is_none() {
            return Err(invalid("编辑工作文件租约已释放"));
        }
        private_directory(
            self.directory
                .parent()
                .ok_or_else(|| invalid("编辑根无效"))?,
            false,
        )?;
        private_directory(&self.directory, false)?;
        let mut file = options(true, false, false).open(&self.path)?;
        let before = ordinary(&file)?;
        if before.len() > MAX_WORK_BYTES as u64 {
            return Err(invalid("外部文本工作文件超过容量；原文件保留"));
        }
        let mut bytes = Zeroizing::new(Vec::with_capacity(before.len() as usize));
        Read::by_ref(&mut file)
            .take(MAX_WORK_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        let after = ordinary(&file)?;
        if bytes.len() > MAX_WORK_BYTES {
            return Err(invalid("外部文本工作文件超过容量；原文件保留"));
        }
        if before.len() != after.len()
            || bytes.len() as u64 != after.len()
            || before.modified()? != after.modified()?
        {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "编辑文件仍在变化，请稍后重试",
            ));
        }
        Ok(WorkSnapshot {
            bytes,
            modified: after.modified()?,
        })
    }
    /// Caller has persisted the latest bytes and the user confirmed the external
    /// editor is closed. Unknown sibling files (e.g. swap/backup) are never erased.
    pub fn remove_confirmed(&mut self) -> io::Result<()> {
        private_directory(
            self.directory
                .parent()
                .ok_or_else(|| invalid("编辑根无效"))?,
            false,
        )?;
        private_directory(&self.directory, false)?;
        if self.owner.is_none() {
            let path = self.directory.join(OWNER);
            let file = match options(true, true, false).open(&path) {
                Ok(file) => file,
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    options(true, true, true).open(&path)?
                }
                Err(e) => return Err(e),
            };
            ordinary(&file)?;
            file.try_lock_exclusive()?;
            self.owner = Some(file);
        }
        let filename = self
            .path
            .file_name()
            .ok_or_else(|| invalid("编辑文件名无效"))?;
        for entry in fs::read_dir(&self.directory)? {
            let entry = entry?;
            let n = entry.file_name();
            if n != filename && n != MARKER && n != OWNER {
                return Err(invalid("工作目录仍有其他文件；未清理，请先关闭外部编辑器"));
            }
            if !entry.file_type()?.is_file() {
                return Err(invalid("工作目录文件类型异常；未清理"));
            }
        }
        // Delete the document while still owning its lease. Releasing first
        // would allow another instance to start editing before we remove it.
        // Keep the valid marker until the very end: a racing opener must see a
        // missing document, not initialize a replacement that we then delete.
        if let Err(e) = fs::remove_file(&self.path)
            && e.kind() != io::ErrorKind::NotFound
        {
            return Err(e);
        }
        // Windows can require closing the lease handle before removing it.
        // No document unlink is allowed after this point. If another opener
        // initializes new files after marker removal, remove_dir fails safely.
        self.owner.take();
        for path in [&self.directory.join(OWNER), &self.directory.join(MARKER)] {
            if let Err(e) = fs::remove_file(path)
                && e.kind() != io::ErrorKind::NotFound
            {
                return Err(e);
            }
        }
        fs::remove_dir(&self.directory)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "edit-0123456789abcdef0123456789abcdef";
    #[test]
    fn large_work_files_stream_under_a_lease_and_reopen_without_running_initialization() {
        let base = tempfile::tempdir().unwrap();
        let dir = ExternalCopy::location(base.path(), ID).unwrap();
        let length = 17 * 1024 * 1024 + 13;
        let (copy, existing) = ExternalCopy::open_stream(&dir, ID, "large.txt", |file| {
            let mut source = io::repeat(29).take(length);
            assert_eq!(io::copy(&mut source, file)?, length);
            Ok(())
        })
        .unwrap();
        assert!(!existing);
        assert!(
            ExternalCopy::open_stream(&dir, ID, "large.txt", |_| panic!("lease must refuse"))
                .is_err()
        );
        let mut reader = copy.reader().unwrap();
        assert_eq!(reader.length(), length);
        let mut bytes = [0u8; 65536];
        let mut total = 0;
        loop {
            let count = reader.read(&mut bytes).unwrap();
            if count == 0 {
                break;
            }
            assert!(bytes[..count].iter().all(|b| *b == 29));
            total += count as u64;
        }
        reader.finish().unwrap();
        assert_eq!(total, length);
        let reader = copy.reader().unwrap();
        options(false, true, false)
            .open(copy.path())
            .unwrap()
            .set_len(length - 1)
            .unwrap();
        assert_eq!(
            reader.finish().unwrap_err().kind(),
            io::ErrorKind::WouldBlock
        );
        drop(copy);
        let (mut copy, existing) = ExternalCopy::open_stream(&dir, ID, "large.txt", |_| {
            panic!("must never overwrite existing work")
        })
        .unwrap();
        assert!(existing);
        assert_eq!(copy.reader().unwrap().length(), length - 1);
        copy.remove_confirmed().unwrap();
    }
    #[test]
    fn failed_stream_initialization_keeps_partial_plaintext_for_explicit_recovery() {
        let base = tempfile::tempdir().unwrap();
        let dir = ExternalCopy::location(base.path(), ID).unwrap();
        assert!(
            ExternalCopy::open_stream(&dir, ID, "large.txt", |file| {
                file.write_all(b"partial synthetic snapshot")?;
                Err(io::Error::other("synthetic source failure"))
            })
            .is_err()
        );
        assert!(!dir.join(MARKER).exists());
        assert!(
            ExternalCopy::open_stream(&dir, ID, "large.txt", |_| panic!(
                "partial work must not be overwritten"
            ))
            .is_err()
        );
        assert!(!dir.join(MARKER).exists());
        let (mut copy, existing) =
            ExternalCopy::open(&dir, ID, "large.txt", b"must not overwrite").unwrap();
        assert!(existing);
        assert_eq!(
            copy.snapshot().unwrap().bytes.as_slice(),
            b"partial synthetic snapshot"
        );
        copy.remove_confirmed().unwrap();
    }
    #[test]
    fn atomic_replacement_and_incomplete_initialization_preserve_newer_bytes() {
        let base = tempfile::tempdir().unwrap();
        let dir = ExternalCopy::location(base.path(), ID).unwrap();
        let (copy, _) = ExternalCopy::open(&dir, ID, "file.txt", b"initial").unwrap();
        let replacement = dir.join("temporary-save");
        fs::write(&replacement, "atomic 中文 é").unwrap();
        fs::rename(&replacement, copy.path()).unwrap();
        assert_eq!(&*copy.snapshot().unwrap().bytes, "atomic 中文 é".as_bytes());
        drop(copy);
        fs::remove_file(dir.join(MARKER)).unwrap();
        fs::remove_file(dir.join(OWNER)).unwrap();
        let (mut recovered, reused) =
            ExternalCopy::open(&dir, ID, "file.txt", b"older encrypted draft").unwrap();
        assert!(reused);
        assert_eq!(
            &*recovered.snapshot().unwrap().bytes,
            "atomic 中文 é".as_bytes()
        );
        recovered.remove_confirmed().unwrap();
    }
    #[test]
    fn work_copy_survives_drop_reopens_without_overwriting_and_requires_a_lease() {
        let base = tempfile::tempdir().unwrap();
        let dir = ExternalCopy::location(base.path(), ID).unwrap();
        let (copy, reused) =
            ExternalCopy::open(&dir, ID, "/remote/a 中文.txt", b"original").unwrap();
        assert!(!reused);
        assert!(ExternalCopy::open(&dir, ID, "a.txt", b"must not overwrite").is_err());
        fs::write(copy.path(), "changed 中文").unwrap();
        let path = copy.path().to_owned();
        drop(copy);
        assert!(path.exists());
        let (mut restored, reused) = ExternalCopy::open(&dir, ID, "a.txt", b"older draft").unwrap();
        assert!(reused);
        assert_eq!(
            &*restored.snapshot().unwrap().bytes,
            "changed 中文".as_bytes()
        );
        fs::write(dir.join("swap.keep"), b"keep unknown").unwrap();
        assert!(restored.remove_confirmed().is_err());
        assert_eq!(fs::read(&path).unwrap(), "changed 中文".as_bytes());
        fs::remove_file(dir.join("swap.keep")).unwrap();
        restored.remove_confirmed().unwrap();
        assert!(!dir.exists());
    }
    #[test]
    fn filenames_markers_and_capacity_do_not_allow_unrelated_files_to_be_read_or_erased() {
        let base = tempfile::tempdir().unwrap();
        assert!(ExternalCopy::location(base.path(), "../escape").is_err());
        let dir = ExternalCopy::location(base.path(), ID).unwrap();
        let (copy, _) = ExternalCopy::open(&dir, ID, "../../NUL.txt:stream", b"keep").unwrap();
        assert_eq!(copy.path().file_name().unwrap(), "document.txt");
        let file = options(false, true, false).open(copy.path()).unwrap();
        file.set_len(MAX_WORK_BYTES as u64 + 1).unwrap();
        assert!(copy.snapshot().is_err());
        assert_eq!(file.metadata().unwrap().len(), MAX_WORK_BYTES as u64 + 1);
        drop(copy);
        fs::write(dir.join(MARKER), b"future format").unwrap();
        assert!(ExternalCopy::open(&dir, ID, "a.txt", b"must not overwrite").is_err());
    }
    #[cfg(unix)]
    #[test]
    fn symlinks_hard_links_fifos_and_insecure_permissions_are_rejected() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let base = tempfile::tempdir().unwrap();
        let dir = ExternalCopy::location(base.path(), ID).unwrap();
        let (copy, _) = ExternalCopy::open(&dir, ID, "a.txt", b"original").unwrap();
        let outside = base.path().join("outside");
        fs::write(&outside, b"keep outside").unwrap();
        fs::remove_file(copy.path()).unwrap();
        symlink(&outside, copy.path()).unwrap();
        assert!(copy.snapshot().is_err());
        fs::remove_file(copy.path()).unwrap();
        fs::hard_link(&outside, copy.path()).unwrap();
        assert!(copy.snapshot().is_err());
        fs::remove_file(copy.path()).unwrap();
        rustix::fs::mknodat(
            rustix::fs::CWD,
            copy.path(),
            rustix::fs::FileType::Fifo,
            rustix::fs::Mode::RUSR | rustix::fs::Mode::WUSR,
            0,
        )
        .unwrap();
        assert!(copy.snapshot().is_err());
        assert_eq!(fs::read(outside).unwrap(), b"keep outside");
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o777)).unwrap();
        assert!(copy.snapshot().is_err());
    }
}
