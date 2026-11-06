//! Local authenticated encryption and domain repositories.
pub mod appearance;
pub mod backup;
pub mod sftp_view_settings;
pub use backup::cloud_sync;
pub mod bookmarks;
mod checked_records;
pub mod command_history;
pub mod display_settings;
pub mod edit_blobs;
pub mod export_cache;
pub mod external_edits;
pub mod file_open_settings;
pub mod forwarding_drafts;
pub mod forwarding_rules;
pub mod google_drive_account;
pub mod local_edits;
pub mod local_tasks;
pub mod network_defaults;
pub mod openssh_import;
pub mod preview_cache;
pub mod raw_edits;
pub mod recent_hosts;
mod repository;
mod revision;
pub mod secure_unlock;
pub mod sftp_host_prefs;
pub mod sftp_last_dirs;
pub mod ssh_proxy;
pub mod terminal_preferences;
pub mod transfer_settings;
pub mod typography;
pub use repository::bulk as host_bulk;
pub use repository::ordering as host_ordering;
pub use repository::{
    AuthMethod, CatalogMetadata, Credential, DraftMetadata, HostDraft, HostGroup, HostRecord,
    Repository, RepositoryError,
};
#[cfg(unix)]
use std::fs::File;
use std::path::Path;

use aes_gcm::{
    AesGcm, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use argon2::{Algorithm, Argon2, Params, Version};
use rand::{RngCore, rngs::OsRng};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use thiserror::Error;
use zeroize::Zeroizing;

// Explicit AES type enables schedule zeroization, in addition to GCM and Argon2 work buffers.
type VaultCipher = AesGcm<aes::Aes256, aes_gcm::aead::consts::U12>;

const FORMAT_VERSION: i64 = 1;
const CHECK_ID: &str = "__vault_unlock_check_v1";
const CHECK_VALUE: &[u8] = b"HSPTerm vault version 1";

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("存储文件无法访问")]
    Io(#[from] std::io::Error),
    #[error("数据库操作失败")]
    Database(#[from] rusqlite::Error),
    #[error("主密码错误或数据已损坏")]
    Authentication,
    #[error("不支持或无效的存储格式")]
    Format,
    #[error("记录标识无效（必须使用非敏感的不透明 ID）")]
    InvalidId,
    #[error("加密记录超过允许读取容量；原数据未修改")]
    RecordTooLarge,
    #[error("密钥派生失败")]
    Derivation,
}

/// Encrypted records, with a unique random nonce for every write and ID-bound AAD.
/// The caller must use opaque, non-sensitive IDs; payloads are never logged.
/// Keep this synchronous API on a dedicated worker, away from UI/network runtimes.
pub struct Vault {
    instance_id: String,
    db: Connection,
    key: Zeroizing<[u8; 32]>,
}

/// A set of encrypted writes and removals committed as one SQLite transaction.
pub enum RecordChange<'a> {
    Put(&'a str, &'a [u8]),
    Delete(&'a str),
}

impl Vault {
    /// Ephemeral scope for explicit previews; changes on every open, never synced.
    pub fn instance_id(&self) -> &str {
        &self.instance_id
    }

    /// Create a new file, refusing to replace any existing file.
    pub fn create(path: &Path, password: &[u8]) -> Result<Self, StorageError> {
        match std::fs::symlink_metadata(path) {
            Ok(_) => return Err(std::io::Error::from(std::io::ErrorKind::AlreadyExists).into()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        // The final path is not visible during expensive derivation or partial
        // schema initialization. Staging is private and on the same filesystem.
        let temporary = tempfile::Builder::new()
            .prefix(".hspterm-vault-stage-")
            .tempfile_in(parent)?;
        let Self { db, key, .. } = Self::initialize(temporary.path(), password)?;
        // SQLite's Windows VFS does not allow renaming an open database.
        db.close()
            .map_err(|(_, error)| StorageError::Database(error))?;
        temporary.as_file().sync_all()?;
        let published = temporary
            .persist_noclobber(path)
            .map_err(|error| StorageError::Io(error.error))?;
        published.sync_all()?;
        #[cfg(unix)]
        File::open(parent)?.sync_all()?;
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        db.execute_batch("PRAGMA secure_delete=ON;")?;
        Ok(Self {
            db,
            key,
            instance_id: format!("vault-{:032x}", rand::random::<u128>()),
        })
    }

    fn initialize(path: &Path, password: &[u8]) -> Result<Self, StorageError> {
        let mut db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        db.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON;")?;
        let mut salt = [0u8; 16];
        OsRng.fill_bytes(&mut salt);
        let key = derive(password, &salt)?;
        let (nonce, ciphertext) = encrypt(&key, CHECK_ID, CHECK_VALUE)?;
        let tx = db.transaction()?;
        tx.execute_batch("CREATE TABLE metadata(version INTEGER NOT NULL, salt BLOB NOT NULL);
            CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, nonce BLOB NOT NULL, ciphertext BLOB NOT NULL);")?;
        tx.execute(
            "INSERT INTO metadata VALUES (?1, ?2)",
            params![FORMAT_VERSION, salt.as_slice()],
        )?;
        tx.execute(
            "INSERT INTO records VALUES (?1, ?2, ?3)",
            params![CHECK_ID, nonce.as_slice(), ciphertext],
        )?;
        tx.commit()?;
        Ok(Self {
            db,
            key,
            instance_id: format!("vault-{:032x}", rand::random::<u128>()),
        })
    }

    /// Open existing storage only; this never creates or overwrites a vault.
    pub fn open(path: &Path, password: &[u8]) -> Result<Self, StorageError> {
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        let (version, salt): (i64, Vec<u8>) =
            db.query_row("SELECT version, salt FROM metadata", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })?;
        if version != FORMAT_VERSION || salt.len() != 16 {
            return Err(StorageError::Format);
        }
        let key = derive(password, &salt)?;
        let vault = Self {
            db,
            key,
            instance_id: format!("vault-{:032x}", rand::random::<u128>()),
        };
        if vault.read_record(CHECK_ID)?.as_ref().map(|v| v.as_slice()) != Some(CHECK_VALUE) {
            return Err(StorageError::Authentication);
        }
        vault.db.execute_batch("PRAGMA secure_delete=ON;")?;
        Ok(vault)
    }

    pub fn put(&mut self, id: &str, plaintext: &[u8]) -> Result<(), StorageError> {
        self.put_many(&[(id, plaintext)])
    }

    /// Commit related encrypted records atomically; errors roll back the whole set.
    pub fn put_many(&mut self, records: &[(&str, &[u8])]) -> Result<(), StorageError> {
        self.apply(
            &records
                .iter()
                .map(|(id, data)| RecordChange::Put(id, data))
                .collect::<Vec<_>>(),
        )
    }

    pub fn apply(&mut self, changes: &[RecordChange<'_>]) -> Result<(), StorageError> {
        let transaction = self.db.transaction()?;
        let notify = cloud_sync::journal::record_transaction(&transaction, &self.key, changes)?;
        for change in changes {
            match change {
                RecordChange::Put(id, plaintext) => {
                    validate_id(id)?;
                    let (nonce, ciphertext) = encrypt(&self.key, id, plaintext)?;
                    transaction.execute(
                        "INSERT INTO records VALUES (?1, ?2, ?3)
                ON CONFLICT(id) DO UPDATE SET nonce=excluded.nonce, ciphertext=excluded.ciphertext",
                        params![id, nonce.as_slice(), ciphertext],
                    )?;
                }
                RecordChange::Delete(id) => {
                    validate_id(id)?;
                    transaction.execute("DELETE FROM records WHERE id=?1", [id])?;
                }
            }
        }
        transaction.commit()?;
        if notify {
            cloud_sync::journal::committed(&self.instance_id);
        }
        Ok(())
    }

    pub fn get(&self, id: &str) -> Result<Option<Zeroizing<Vec<u8>>>, StorageError> {
        validate_id(id)?;
        self.read_record(id)
    }
    /// SQL omits oversized ciphertext before Rust allocates/decrypts it. Size
    /// and bytes come from the same statement, avoiding a check/read race.
    pub fn get_bounded(
        &self,
        id: &str,
        max_bytes: usize,
    ) -> Result<Option<Zeroizing<Vec<u8>>>, StorageError> {
        validate_id(id)?;
        let limit = max_bytes
            .checked_add(16)
            .and_then(|v| i64::try_from(v).ok())
            .ok_or(StorageError::RecordTooLarge)?;
        let row: Option<(Vec<u8>, Option<Vec<u8>>)> = self.db.query_row(
            "SELECT nonce, CASE WHEN length(ciphertext)<=?2 THEN ciphertext ELSE NULL END FROM records WHERE id=?1",
            params![id, limit], |r| Ok((r.get(0)?, r.get(1)?)),
        ).optional()?;
        row.map(|(nonce, ciphertext)| {
            decrypt_record(
                &self.key,
                id,
                (nonce, ciphertext.ok_or(StorageError::RecordTooLarge)?),
            )
        })
        .transpose()
    }

    pub fn delete(&mut self, id: &str) -> Result<bool, StorageError> {
        validate_id(id)?;
        let tx = self.db.transaction()?;
        let notify =
            cloud_sync::journal::record_transaction(&tx, &self.key, &[RecordChange::Delete(id)])?;
        let removed = tx.execute("DELETE FROM records WHERE id=?1", [id])? != 0;
        tx.commit()?;
        if notify {
            cloud_sync::journal::committed(&self.instance_id);
        }
        Ok(removed)
    }

    fn read_record(&self, id: &str) -> Result<Option<Zeroizing<Vec<u8>>>, StorageError> {
        self.read_with_key(id, &self.key)
    }

    /// Re-authenticate sensitive export operations; an unlocked vault is not sufficient.
    pub fn verify_password(&self, password: &[u8]) -> Result<(), StorageError> {
        let salt: Vec<u8> = self
            .db
            .query_row("SELECT salt FROM metadata", [], |r| r.get(0))?;
        if salt.len() != 16 {
            return Err(StorageError::Format);
        }
        let candidate = derive(password, &salt)?;
        if self
            .read_with_key(CHECK_ID, &candidate)?
            .as_deref()
            .map(Vec::as_slice)
            != Some(CHECK_VALUE)
        {
            return Err(StorageError::Authentication);
        }
        Ok(())
    }

    fn read_with_key(
        &self,
        id: &str,
        key: &[u8; 32],
    ) -> Result<Option<Zeroizing<Vec<u8>>>, StorageError> {
        let row: Option<(Vec<u8>, Vec<u8>)> = self
            .db
            .query_row(
                "SELECT nonce, ciphertext FROM records WHERE id=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        row.map(|row| decrypt_record(key, id, row)).transpose()
    }
}

fn decrypt_record(
    key: &[u8; 32],
    id: &str,
    (nonce, ciphertext): (Vec<u8>, Vec<u8>),
) -> Result<Zeroizing<Vec<u8>>, StorageError> {
    if nonce.len() != 12 {
        return Err(StorageError::Authentication);
    }
    let cipher = VaultCipher::new_from_slice(key).map_err(|_| StorageError::Derivation)?;
    cipher
        .decrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &ciphertext,
                aad: id.as_bytes(),
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| StorageError::Authentication)
}

fn validate_id(id: &str) -> Result<(), StorageError> {
    if id.is_empty() || id.len() > 256 || id.starts_with("__") || id.chars().any(char::is_control) {
        Err(StorageError::InvalidId)
    } else {
        Ok(())
    }
}

fn derive(password: &[u8], salt: &[u8]) -> Result<Zeroizing<[u8; 32]>, StorageError> {
    let params = Params::new(64 * 1024, 3, 1, Some(32)).map_err(|_| StorageError::Derivation)?;
    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = Zeroizing::new([0; 32]);
    argon
        .hash_password_into(password, salt, key.as_mut())
        .map_err(|_| StorageError::Derivation)?;
    Ok(key)
}

fn encrypt(
    key: &[u8; 32],
    id: &str,
    plaintext: &[u8],
) -> Result<([u8; 12], Vec<u8>), StorageError> {
    let cipher = VaultCipher::new_from_slice(key).map_err(|_| StorageError::Derivation)?;
    let mut nonce = [0; 12];
    OsRng.fill_bytes(&mut nonce);
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: id.as_bytes(),
            },
        )
        .map_err(|_| StorageError::Authentication)?;
    Ok((nonce, ciphertext))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_vault_is_never_published_with_an_incomplete_schema() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("vault.sqlite");
        let target = path.clone();
        let start = std::sync::Arc::new(std::sync::Barrier::new(2));
        let worker_start = start.clone();
        let worker = std::thread::spawn(move || {
            worker_start.wait();
            Vault::create(&target, b"test-only-master").unwrap();
        });
        start.wait();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while !path.exists() {
            assert!(
                std::time::Instant::now() < deadline,
                "vault was not published"
            );
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        // Readers must never observe the previous empty-file/Argon2 window.
        let reopened = Vault::open(&path, b"test-only-master").unwrap();
        worker.join().unwrap();
        drop(reopened);
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn concurrent_creators_never_replace_the_winner_or_leave_staging_files() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("vault.sqlite");
        let start = std::sync::Arc::new(std::sync::Barrier::new(3));
        let workers: Vec<_> = (0..2)
            .map(|_| {
                let path = path.clone();
                let start = start.clone();
                std::thread::spawn(move || {
                    start.wait();
                    Vault::create(&path, b"test-only-master").is_ok()
                })
            })
            .collect();
        start.wait();
        assert_eq!(
            workers
                .into_iter()
                .map(|w| usize::from(w.join().unwrap()))
                .sum::<usize>(),
            1
        );
        Vault::open(&path, b"test-only-master").unwrap();
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[test]
    fn related_records_roll_back_together() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(&dir.path().join("vault"), b"test-only-master").unwrap();
        vault.put("profile", b"old").unwrap();
        assert!(
            vault
                .put_many(&[("profile", b"new"), (CHECK_ID, b"invalid")])
                .is_err()
        );
        assert_eq!(vault.get("profile").unwrap().unwrap().as_slice(), b"old");
        vault
            .put_many(&[("profile", b"new"), ("index", b"profile")])
            .unwrap();
        assert_eq!(vault.get("profile").unwrap().unwrap().as_slice(), b"new");
        assert_eq!(vault.get("index").unwrap().unwrap().as_slice(), b"profile");
    }

    #[test]
    fn persists_only_ciphertext_and_refuses_wrong_password_or_overwrite() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.sqlite");
        let secret = b"test-only-secret-never-stored-in-plaintext";
        let mut vault = Vault::create(&path, b"test-only-master").unwrap();
        vault.put("record-1", secret).unwrap();
        assert_eq!(vault.get("record-1").unwrap().unwrap().as_slice(), secret);
        assert!(matches!(
            vault.put(CHECK_ID, b"bad"),
            Err(StorageError::InvalidId)
        ));
        drop(vault);
        assert!(
            !std::fs::read(&path)
                .unwrap()
                .windows(secret.len())
                .any(|w| w == secret)
        );
        assert!(matches!(
            Vault::create(&path, b"other"),
            Err(StorageError::Io(_))
        ));
        assert!(matches!(
            Vault::open(&path, b"wrong"),
            Err(StorageError::Authentication)
        ));
        let mut vault = Vault::open(&path, b"test-only-master").unwrap();
        assert_eq!(vault.get("record-1").unwrap().unwrap().as_slice(), secret);
        assert!(vault.delete("record-1").unwrap());
        assert!(!vault.delete("record-1").unwrap());
        assert!(vault.get("record-1").unwrap().is_none());
    }

    #[test]
    fn tampering_or_moving_ciphertext_between_ids_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.sqlite");
        let mut vault = Vault::create(&path, b"test-only-master").unwrap();
        vault.put("record-1", b"a").unwrap();
        vault.put("record-2", b"a").unwrap();
        let nonces: Vec<Vec<u8>> = vault
            .db
            .prepare("SELECT nonce FROM records")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_ne!(nonces[0], nonces[1]);
        vault
            .db
            .execute("UPDATE records SET id='record-3' WHERE id='record-1'", [])
            .unwrap();
        assert!(matches!(
            vault.get("record-3"),
            Err(StorageError::Authentication)
        ));
        vault
            .db
            .execute(
                "UPDATE records SET ciphertext=zeroblob(32) WHERE id='record-2'",
                [],
            )
            .unwrap();
        assert!(matches!(
            vault.get("record-2"),
            Err(StorageError::Authentication)
        ));
    }
}

pub mod shortcut_settings;
