//! Private, persistent source snapshots for delayed Windows virtual-file reads.
//! Dropping a lease closes its lock but NEVER deletes partial download data.
//! Only explicit retirement of a task with no native readers removes its tree.
use fs2::FileExt;
use std::{
    fs::{self, File, OpenOptions},
    io,
    path::{Path, PathBuf},
};

const MARKER: &[u8] = b"HSPTerm Explorer source cache v1\n";
const OWNED_MARKER: &str = "HSPTerm Explorer source cache v2\n";

pub struct ExportSlot {
    directory: PathBuf,
    owner: Option<File>,
}
impl ExportSlot {
    pub fn path(&self) -> PathBuf {
        self.directory.join("payload")
    }

    /// Only paths previously issued by this module are accepted on recovery.
    /// The encrypted task header, not an external drag/drop URI, supplies this.
    pub fn lease(path: &Path) -> io::Result<Self> {
        let directory = path.parent().ok_or_else(invalid)?;
        let root = directory.parent().ok_or_else(invalid)?;
        if path.file_name().and_then(|s| s.to_str()) != Some("payload")
            || !root.is_absolute()
            || !root
                .file_name()
                .and_then(|s| s.to_str())
                .is_some_and(|name| name == root_name())
            || !directory
                .file_name()
                .and_then(|s| s.to_str())
                .is_some_and(|name| {
                    name.strip_prefix("export-").is_some_and(|suffix| {
                        suffix.len() >= 6
                            && suffix.len() <= 64
                            && suffix.bytes().all(|c| c.is_ascii_alphanumeric())
                    })
                })
        {
            return Err(invalid());
        }
        private_directory(root)?;
        let registry = lock_file(&root.join("registry.lock"), false)?;
        registry.lock_exclusive()?;
        private_directory(directory)?;
        let owner = lock_file(&directory.join("owner.lock"), false)?;
        owner.try_lock_exclusive()?;
        let marker = fs::symlink_metadata(directory.join("marker"))?;
        if !marker.is_file()
            || reparse(&marker)
            || marker.len() > 128
            || !valid_marker(&fs::read(directory.join("marker"))?)
        {
            return Err(invalid());
        }
        match fs::symlink_metadata(path) {
            Ok(metadata) if reparse(&metadata) || !(metadata.is_file() || metadata.is_dir()) => {
                return Err(invalid());
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        Ok(Self {
            directory: directory.to_owned(),
            owner: Some(owner),
        })
    }

    /// Cache-only cleanup. It never takes an Explorer destination pathname and
    /// refuses unexpected sibling files instead of recursively erasing them.
    pub fn remove(&mut self) -> io::Result<()> {
        if self.owner.is_none() {
            return Err(invalid());
        }
        let root = self.directory.parent().ok_or_else(invalid)?;
        private_directory(root)?;
        let registry = lock_file(&root.join("registry.lock"), false)?;
        registry.lock_exclusive()?;
        private_directory(&self.directory)?;
        for entry in fs::read_dir(&self.directory)? {
            let entry = entry?;
            if !["owner.lock", "marker", "payload"]
                .iter()
                .any(|name| entry.file_name() == *name)
            {
                return Err(io::Error::other("导出缓存含未知文件，未清理"));
            }
        }
        match fs::symlink_metadata(self.path()) {
            Ok(metadata) if reparse(&metadata) => return Err(invalid()),
            Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(self.path())?,
            Ok(metadata) if metadata.is_file() => fs::remove_file(self.path())?,
            Ok(_) => return Err(invalid()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        // Keep the cache-wide lock across Windows handle close/delete. Another
        // cooperating process cannot acquire this source between those steps.
        self.owner.take();
        let result = (|| {
            for name in ["marker", "owner.lock"] {
                match fs::remove_file(self.directory.join(name)) {
                    Ok(()) => {}
                    Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                    Err(e) => return Err(e),
                }
            }
            fs::remove_dir(&self.directory)
        })();
        if result.is_err() {
            // Preserve any surviving lock ownership for explicit retry. An
            // absent directory is a known cleanup result, not another target.
            if self.directory.exists() {
                let owner = lock_file(&self.directory.join("owner.lock"), true)?;
                owner.try_lock_exclusive()?;
                self.owner = Some(owner);
            }
        }
        result
    }
}

fn invalid() -> io::Error {
    io::Error::other("导出源缓存路径、权限或类型不符合预期")
}
fn root_name() -> String {
    #[cfg(unix)]
    {
        format!(
            "hspterm-explorer-cache-v1-{}",
            rustix::process::geteuid().as_raw()
        )
    }
    #[cfg(not(unix))]
    {
        "hspterm-explorer-cache-v1".into()
    }
}
fn reparse(metadata: &fs::Metadata) -> bool {
    if metadata.file_type().is_symlink() {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        metadata.file_attributes() & 0x400 != 0 // FILE_ATTRIBUTE_REPARSE_POINT
    }
    #[cfg(not(windows))]
    {
        false
    }
}
fn private_directory(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || reparse(&metadata) {
        return Err(invalid());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != rustix::process::geteuid().as_raw() || metadata.mode() & 0o077 != 0 {
            return Err(invalid());
        }
    }
    Ok(())
}
fn lock_file(path: &Path, create: bool) -> io::Result<File> {
    if let Ok(metadata) = fs::symlink_metadata(path)
        && (!metadata.is_file() || reparse(&metadata))
    {
        return Err(invalid());
    }
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
    if !file.metadata()?.is_file() || reparse(&file.metadata()?) {
        return Err(invalid());
    }
    Ok(file)
}
pub fn allocate(base: &Path) -> io::Result<ExportSlot> {
    allocate_marker(base, MARKER)
}

/// The random owner is stored only in this device's encrypted Vault. It must
/// never be copied into configuration backups/cloud payloads.
pub fn allocate_for_owner(base: &Path, owner: &str) -> io::Result<ExportSlot> {
    let marker = owned_marker(owner)?;
    allocate_marker(base, &marker)
}
fn allocate_marker(base: &Path, contents: &[u8]) -> io::Result<ExportSlot> {
    if !base.is_absolute() {
        return Err(invalid());
    }
    let base = fs::canonicalize(base)?;
    let root = base.join(root_name());
    let builder = fs::DirBuilder::new();
    #[cfg(unix)]
    let mut builder = builder;
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    match builder.create(&root) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    private_directory(&root)?;
    let registry = lock_file(&root.join("registry.lock"), true)?;
    registry.lock_exclusive()?;
    let mut slots = tempfile::Builder::new();
    slots.prefix("export-");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // tempfile defaults to 0777 for directories. Set private creation mode
        // before creating plaintext snapshots; lease() enforces the same mode.
        slots.permissions(fs::Permissions::from_mode(0o700));
    }
    let directory = slots.tempdir_in(root)?;
    let owner = lock_file(&directory.path().join("owner.lock"), true)?;
    owner.try_lock_exclusive()?;
    let mut marker = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(directory.path().join("marker"))?;
    use io::Write;
    marker.write_all(contents)?;
    marker.sync_all()?;
    Ok(ExportSlot {
        directory: directory.keep(),
        owner: Some(owner),
    })
}

/// Distinct device-local owners for different Vault file locations, including
/// copies of a database. No absolute filename leaves the encrypted repository.
/// Moving a database deliberately leaves the old namespace unreclaimed.
pub fn vault_owner(
    vault: &mut crate::Vault,
    create: bool,
) -> Result<Option<String>, crate::StorageError> {
    use sha2::{Digest, Sha256};
    let file: String = vault.db.query_row(
        "SELECT file FROM pragma_database_list WHERE name='main'",
        [],
        |r| r.get(0),
    )?;
    let file = fs::canonicalize(file)?;
    let mut hash = Sha256::new();
    hash.update(b"HSPTerm/device/export-owner/location/v1\0");
    // Encode OsStr losslessly on each target; never merge distinct paths by
    // Unicode replacement. These records are deliberately not portable.
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::MetadataExt;
        hash.update(file.as_os_str().as_bytes());
        let metadata = fs::metadata(&file)?;
        hash.update(metadata.dev().to_le_bytes());
        hash.update(metadata.ino().to_le_bytes());
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        for unit in file.as_os_str().encode_wide() {
            hash.update(unit.to_le_bytes());
        }
    }
    #[cfg(not(any(unix, windows)))]
    hash.update(file.to_string_lossy().as_bytes());
    let digest: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect();
    let key = format!("local-explorer-owner-v1-{digest}");
    if let Some(raw) = vault.get_bounded(&key, 32)? {
        let owner = String::from_utf8(raw.to_vec()).map_err(|_| crate::StorageError::Format)?;
        owned_marker(&owner).map_err(|_| crate::StorageError::Format)?;
        return Ok(Some(owner));
    }
    if !create {
        return Ok(None);
    }
    let owner = format!("{:032x}", rand::random::<u128>());
    vault.put(&key, owner.as_bytes())?;
    Ok(Some(owner))
}

fn owned_marker(owner: &str) -> io::Result<Vec<u8>> {
    if owner.len() != 32
        || !owner
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(invalid());
    }
    Ok(format!("{OWNED_MARKER}{owner}\n").into_bytes())
}
fn valid_marker(bytes: &[u8]) -> bool {
    if bytes == MARKER {
        return true;
    }
    let Ok(text) = std::str::from_utf8(bytes) else {
        return false;
    };
    text.strip_prefix(OWNED_MARKER)
        .and_then(|s| s.strip_suffix('\n'))
        .is_some_and(|owner| owned_marker(owner).is_ok())
}
fn owner_matches(path: &Path, owner: &str) -> io::Result<bool> {
    let expected = owned_marker(owner)?;
    let marker = path.parent().ok_or_else(invalid)?.join("marker");
    let metadata = fs::symlink_metadata(&marker)?;
    if !metadata.is_file() || reparse(&metadata) || metadata.len() != expected.len() as u64 {
        return Ok(false);
    }
    Ok(fs::read(marker)? == expected)
}

/// A bounded local review batch. Live locks, another Vault's markers, old v1
/// unowned slots, and every journal-referenced payload are always retained.
/// This is explicit UI cleanup, never startup/periodic reclamation.
pub fn orphan_candidates(
    base: &Path,
    owner: &str,
    retained: &std::collections::HashSet<PathBuf>,
) -> io::Result<Vec<PathBuf>> {
    owned_marker(owner)?;
    let root = fs::canonicalize(base)?.join(root_name());
    match fs::symlink_metadata(&root) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
        Ok(_) => private_directory(&root)?,
    }
    let mut result = Vec::new();
    // The owner lock is the cross-process liveness proof. Registry acquisition
    // is performed by lease; never recursively lock the same registry handle.
    for entry in fs::read_dir(root)?.take(10_000) {
        let entry = entry?;
        let name = entry.file_name();
        if !name.to_str().is_some_and(|s| s.starts_with("export-")) {
            continue;
        }
        let directory = entry.path();
        if private_directory(&directory).is_err() {
            continue;
        }
        let path = directory.join("payload");
        if retained.contains(&path) || !owner_matches(&path, owner)? {
            continue;
        }
        match ExportSlot::lease(&path) {
            Ok(_lease) => result.push(path),
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => continue,
            Err(e) => return Err(e),
        }
        if result.len() == 128 {
            break;
        }
    }
    result.sort();
    Ok(result)
}

/// Confirmation must supply the original owner again and recheck the journal
/// before calling. A candidate is never deleted merely because it was listed.
pub fn retire_orphan(path: &Path, owner: &str) -> io::Result<bool> {
    let mut slot = match ExportSlot::lease(path) {
        Ok(slot) => slot,
        Err(e)
            if matches!(
                e.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::WouldBlock
            ) =>
        {
            return Ok(false);
        }
        Err(e) => return Err(e),
    };
    if !owner_matches(path, owner)? {
        return Ok(false);
    }
    slot.remove()?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn partial_trees_survive_drop_but_are_exclusively_leased_and_explicitly_retired() {
        let base = tempfile::tempdir().unwrap();
        let slot = allocate(base.path()).unwrap();
        let path = slot.path();
        fs::create_dir(&path).unwrap();
        fs::create_dir(path.join("空目录")).unwrap();
        fs::write(path.join("partial"), b"private fixture").unwrap();
        assert!(ExportSlot::lease(&path).is_err());
        drop(slot);
        assert_eq!(fs::read(path.join("partial")).unwrap(), b"private fixture");
        let mut leased = ExportSlot::lease(&path).unwrap();
        leased.remove().unwrap();
        assert!(!path.exists());
    }
    #[test]
    fn unknown_siblings_and_foreign_paths_are_never_deleted() {
        let base = tempfile::tempdir().unwrap();
        let mut slot = allocate(base.path()).unwrap();
        fs::write(slot.directory.join("unknown"), b"preserve").unwrap();
        assert!(slot.remove().is_err());
        assert!(slot.directory.join("unknown").exists());
        assert!(ExportSlot::lease(&base.path().join("payload")).is_err());
    }
    #[test]
    fn orphan_review_preserves_live_referenced_foreign_and_legacy_slots() {
        let base = tempfile::tempdir().unwrap();
        let owner = "0123456789abcdef0123456789abcdef";
        let other = "1123456789abcdef0123456789abcdef";
        let live = allocate_for_owner(base.path(), owner).unwrap();
        let kept = allocate_for_owner(base.path(), owner).unwrap();
        let kept_path = kept.path();
        drop(kept);
        let foreign = allocate_for_owner(base.path(), other).unwrap();
        let foreign_path = foreign.path();
        drop(foreign);
        let legacy = allocate(base.path()).unwrap();
        let legacy_path = legacy.path();
        drop(legacy);
        let orphan = allocate_for_owner(base.path(), owner).unwrap();
        let orphan_path = orphan.path();
        fs::write(&orphan_path, b"private fixture").unwrap();
        drop(orphan);
        let retained = std::collections::HashSet::from([kept_path.clone()]);
        assert_eq!(
            orphan_candidates(base.path(), owner, &retained).unwrap(),
            vec![orphan_path.clone()]
        );
        assert!(!retire_orphan(&orphan_path, other).unwrap());
        let reopened = ExportSlot::lease(&orphan_path).unwrap();
        assert!(!retire_orphan(&orphan_path, owner).unwrap());
        drop(reopened);
        assert!(retire_orphan(&orphan_path, owner).unwrap());
        assert!(!orphan_path.exists());
        assert!(live.directory.exists());
        assert!(kept_path.parent().unwrap().exists());
        assert!(foreign_path.parent().unwrap().exists());
        assert!(legacy_path.parent().unwrap().exists());
    }
    #[test]
    fn cache_ownership_is_local_persistent_and_distinct_for_a_copied_vault_file() {
        let temp = tempfile::tempdir().unwrap();
        let first_path = temp.path().join("first.vault");
        let second_path = temp.path().join("second.vault");
        let mut first =
            crate::Vault::create(&first_path, b"synthetic-export-owner-master").unwrap();
        assert!(vault_owner(&mut first, false).unwrap().is_none());
        let owner = vault_owner(&mut first, true).unwrap().unwrap();
        assert_eq!(
            vault_owner(&mut first, false).unwrap().as_deref(),
            Some(owner.as_str())
        );
        drop(first);
        fs::copy(&first_path, &second_path).unwrap();
        let mut original =
            crate::Vault::open(&first_path, b"synthetic-export-owner-master").unwrap();
        assert_eq!(
            vault_owner(&mut original, false).unwrap().as_deref(),
            Some(owner.as_str())
        );
        let mut copy = crate::Vault::open(&second_path, b"synthetic-export-owner-master").unwrap();
        assert!(vault_owner(&mut copy, false).unwrap().is_none());
        assert_ne!(vault_owner(&mut copy, true).unwrap().unwrap(), owner);
    }
}
