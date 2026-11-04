//! Public, non-secret Vault identity for an OS-protected unlock cache. Neither
//! this token nor the file path unlocks a Vault or derives an encryption key.
use crate::{StorageError, Vault};
use rusqlite::{Connection, OpenFlags};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::path::Path;

#[derive(Clone, Serialize)]
pub struct Source {
    pub vault_scope: String,
    pub token: String,
}
fn connection_token(db: &Connection) -> Result<String, StorageError> {
    let mut query = db.prepare("SELECT version, CASE WHEN typeof(salt)='blob' AND length(salt)=16 THEN salt ELSE NULL END FROM metadata LIMIT 2")?;
    let mut rows = query.query([])?;
    let row = rows.next()?.ok_or(StorageError::Format)?;
    let version: i64 = row.get(0)?;
    let salt: Vec<u8> = row.get(1)?;
    if version != crate::FORMAT_VERSION || salt.len() != 16 || rows.next()?.is_some() {
        return Err(StorageError::Format);
    }
    let mut digest = Sha256::new();
    digest.update(b"HSPTerm OS unlock identity v1\0");
    digest.update(version.to_be_bytes());
    digest.update(salt);
    Ok(digest
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}
pub fn hint(path: &Path) -> Result<String, StorageError> {
    let metadata = std::fs::metadata(path)?;
    if !metadata.is_file() {
        return Err(StorageError::Format);
    }
    let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    connection_token(&db)
}
pub fn source(vault: &Vault) -> Result<Source, StorageError> {
    Ok(Source {
        vault_scope: vault.instance_id().into(),
        token: connection_token(&vault.db)?,
    })
}
pub fn verify(
    vault: &Vault,
    scope: &str,
    token: &str,
    password: &[u8],
) -> Result<(), StorageError> {
    if scope != vault.instance_id()
        || source(vault)?.token != token
        || password.is_empty()
        || password.len() > 4096
    {
        return Err(StorageError::Format);
    }
    vault.verify_password(password)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn readonly_hint_is_stable_across_open_but_foreign_and_old_scopes_cannot_enable() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("unlock.vault");
        let v = Vault::create(&path, b"synthetic-unlock-master").unwrap();
        let old = source(&v).unwrap();
        assert_eq!(hint(&path).unwrap(), old.token);
        verify(&v, &old.vault_scope, &old.token, b"synthetic-unlock-master").unwrap();
        assert!(verify(&v, &old.vault_scope, &old.token, b"synthetic-wrong-master").is_err());
        drop(v);
        let reopened = Vault::open(&path, b"synthetic-unlock-master").unwrap();
        let current = source(&reopened).unwrap();
        assert_eq!(current.token, old.token);
        assert_ne!(current.vault_scope, old.vault_scope);
        assert!(
            verify(
                &reopened,
                &old.vault_scope,
                &old.token,
                b"synthetic-unlock-master"
            )
            .is_err()
        );
        let other =
            Vault::create(&dir.path().join("other.vault"), b"synthetic-unlock-master").unwrap();
        assert_ne!(source(&other).unwrap().token, old.token);
        assert!(
            verify(
                &other,
                other.instance_id(),
                &old.token,
                b"synthetic-unlock-master"
            )
            .is_err()
        );
    }
    #[test]
    fn hint_does_not_create_files_or_accept_future_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("missing.vault");
        assert!(hint(&missing).is_err());
        assert!(!missing.exists());
        let path = dir.path().join("future.vault");
        let v = Vault::create(&path, b"synthetic-master").unwrap();
        v.db.execute("UPDATE metadata SET version=99", []).unwrap();
        assert!(hint(&path).is_err());
    }
}
