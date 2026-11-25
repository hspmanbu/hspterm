//! Ephemeral file previews, separate from encrypted configuration and editors.
//! The owner lock prevents another process from collecting active files.
use fs2::FileExt;
use std::{
    fs::{self, File, OpenOptions},
    io,
    path::{Path, PathBuf},
    sync::Arc,
};
use tempfile::TempDir;

pub struct PreviewCache {
    run: Arc<Run>,
    pub deferred_cleanup: usize,
}
struct Run {
    // File handles must close before directory cleanup on Windows.
    owner: File,
    directory: TempDir,
}
/// A fresh slot is never reused by path/name. Publish it only after the full
/// transfer and server CLOSE succeed. Until then Drop removes partial bytes.
pub struct PreviewSlot {
    _directory: TempDir,
    path: PathBuf,
    _run: Arc<Run>,
}
impl PreviewSlot {
    pub fn path(&self) -> &Path {
        &self.path
    }
}
fn open_lock(path: &Path, create: bool) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options
        .read(true)
        .write(true)
        .create(create)
        .truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::other("预览缓存锁不是普通文件"));
    }
    Ok(file)
}
fn ensure_root(root: &Path) -> io::Result<()> {
    let builder = fs::DirBuilder::new();
    #[cfg(unix)]
    let mut builder = builder;
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    if let Err(error) = builder.create(root)
        && error.kind() != io::ErrorKind::AlreadyExists
    {
        return Err(error);
    }
    let metadata = fs::symlink_metadata(root)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(io::Error::other("预览缓存路径不是安全目录"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != rustix::process::geteuid().as_raw() || metadata.mode() & 0o077 != 0 {
            return Err(io::Error::other("预览缓存目录权限不安全"));
        }
    }
    Ok(())
}
fn collect(root: &Path) -> io::Result<usize> {
    let mut deferred = 0;
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        if !entry.file_name().to_string_lossy().starts_with("run-") || !entry.file_type()?.is_dir()
        {
            continue;
        }
        let owner = match open_lock(&entry.path().join("owner.lock"), false) {
            Ok(file) => Some(file),
            Err(e) if e.kind() == io::ErrorKind::NotFound => None,
            Err(e) => return Err(e),
        };
        if let Some(owner) = owner {
            match owner.try_lock_exclusive() {
                Ok(()) => drop(owner),
                // On Windows fs2 reports ERROR_LOCK_VIOLATION for a live run.
                Err(e)
                    if e.kind() == io::ErrorKind::WouldBlock
                        || e.raw_os_error() == fs2::lock_contended_error().raw_os_error() =>
                {
                    continue;
                }
                Err(e) => return Err(e),
            }
        }
        if let Err(e) = fs::remove_dir_all(entry.path()) {
            if e.kind() == io::ErrorKind::NotFound {
                continue;
            }
            // An external preview viewer can still hold files on Windows.
            // Report this explicitly; it must not prevent new previews.
            deferred += 1;
        }
    }
    Ok(deferred)
}
impl PreviewCache {
    /// Call on a storage worker with an app-private platform cache directory.
    /// Android must supply its cache path, not assume std::env::temp_dir works.
    pub fn new_in(base: &Path) -> io::Result<Self> {
        if !base.is_absolute() {
            return Err(io::Error::other("需要绝对缓存目录"));
        }
        #[cfg(unix)]
        let name = format!(
            "hspterm-previews-v1-{}",
            rustix::process::geteuid().as_raw()
        );
        #[cfg(not(unix))]
        let name = "hspterm-previews-v1";
        let root = base.join(name);
        ensure_root(&root)?;
        let registry = open_lock(&root.join("registry.lock"), true)?;
        registry.lock_exclusive()?;
        let deferred_cleanup = collect(&root)?;
        let directory = tempfile::Builder::new().prefix("run-").tempdir_in(&root)?;
        let owner = open_lock(&directory.path().join("owner.lock"), true)?;
        owner.lock_exclusive()?;
        Ok(Self {
            run: Arc::new(Run { owner, directory }),
            deferred_cleanup,
        })
    }
    pub fn allocate(&self, original_name: &str) -> io::Result<PreviewSlot> {
        let directory = tempfile::Builder::new()
            .prefix("file-")
            .tempdir_in(self.run.directory.path())?;
        // Cache names are independent of remote path components. Preserve a
        // safe extension for system associations, never platform-invalid names.
        let extension = original_name
            .rsplit_once('.')
            .map(|(_, extension)| extension)
            .filter(|ext| {
                !ext.is_empty() && ext.len() <= 32 && ext.bytes().all(|c| c.is_ascii_alphanumeric())
            });
        let name = extension.map_or_else(|| "preview".to_owned(), |ext| format!("preview.{ext}"));
        let path = directory.path().join(name);
        Ok(PreviewSlot {
            _directory: directory,
            path,
            _run: self.run.clone(),
        })
    }
    /// Refuse cleanup while a download/view still leases this run. The caller
    /// must first cancel/wait for work and release preview slots.
    pub fn close(self) -> io::Result<()> {
        let run = Arc::try_unwrap(self.run).map_err(|_| io::Error::other("预览缓存仍在使用"))?;
        let root = run
            .directory
            .path()
            .parent()
            .ok_or_else(|| io::Error::other("预览缓存根无效"))?;
        let registry = open_lock(&root.join("registry.lock"), false)?;
        registry.lock_exclusive()?;
        drop(run.owner);
        match run.directory.close() {
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            result => result,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fresh_slots_preserve_only_safe_extensions_and_release_partial_files() {
        let base = tempfile::tempdir().unwrap();
        let cache = PreviewCache::new_in(base.path()).unwrap();
        let a = cache.allocate("中文 ../../file.txt").unwrap();
        let b = cache.allocate("中文 ../../file.txt").unwrap();
        assert_ne!(a.path(), b.path());
        assert_eq!(a.path().file_name().unwrap(), "preview.txt");
        let path = a.path().to_owned();
        fs::write(&path, b"partial fixture").unwrap();
        drop(a);
        assert!(!path.exists());
        for name in [
            "../NUL",
            "bad.txt:stream",
            "name.exe\0",
            "name.a/b",
            "name. ",
            "name.",
        ] {
            let slot = cache.allocate(name).unwrap();
            assert_eq!(slot.path().file_name().unwrap(), "preview");
        }
        drop(b);
        let run = cache.run.directory.path().to_owned();
        cache.close().unwrap();
        assert!(!run.exists());
    }
    #[test]
    fn stale_collection_keeps_active_run_leases_and_unrelated_directories() {
        let base = tempfile::tempdir().unwrap();
        let first = PreviewCache::new_in(base.path()).unwrap();
        let root = first.run.directory.path().parent().unwrap().to_owned();
        let active = first.allocate("active.txt").unwrap();
        fs::write(active.path(), b"keep active").unwrap();
        let stale = root.join("run-abandoned");
        fs::create_dir(&stale).unwrap();
        fs::write(stale.join("fixture"), b"discard abandoned fixture").unwrap();
        let unrelated = root.join("unrelated");
        fs::create_dir(&unrelated).unwrap();
        let second = PreviewCache::new_in(base.path()).unwrap();
        assert!(!stale.exists());
        assert!(unrelated.exists());
        assert_eq!(fs::read(active.path()).unwrap(), b"keep active");
        second.close().unwrap();
        drop(active);
        first.close().unwrap();
    }
    #[test]
    fn closing_a_leased_cache_does_not_delete_live_slots() {
        let base = tempfile::tempdir().unwrap();
        let cache = PreviewCache::new_in(base.path()).unwrap();
        let slot = cache.allocate("live.txt").unwrap();
        let path = slot.path().to_owned();
        fs::write(&path, b"still leased").unwrap();
        assert!(cache.close().is_err());
        let other = PreviewCache::new_in(base.path()).unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"still leased");
        other.close().unwrap();
        drop(slot);
        assert!(!path.exists());
    }
    #[cfg(unix)]
    #[test]
    fn insecure_roots_and_registry_links_are_rejected() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let base = tempfile::tempdir().unwrap();
        let cache = PreviewCache::new_in(base.path()).unwrap();
        let root = cache.run.directory.path().parent().unwrap().to_owned();
        cache.close().unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o777)).unwrap();
        assert!(PreviewCache::new_in(base.path()).is_err());
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::remove_file(root.join("registry.lock")).unwrap();
        let outside = base.path().join("outside");
        fs::write(&outside, b"keep outside").unwrap();
        symlink(&outside, root.join("registry.lock")).unwrap();
        assert!(PreviewCache::new_in(base.path()).is_err());
        assert_eq!(fs::read(outside).unwrap(), b"keep outside");
    }
}
