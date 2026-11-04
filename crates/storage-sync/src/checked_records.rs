//! Atomic encrypted-record preconditions for publishing staged editor bodies.
use super::*;
use rusqlite::TransactionBehavior;

impl Vault {
    /// Compare decrypted records and apply the complete change set under one
    /// SQLite write transaction. False leaves every record unchanged. Missing
    /// and corrupt records differ: authentication failure never permits overwrite.
    pub fn apply_checked(
        &mut self,
        expected: &[(&str, Option<&[u8]>)],
        changes: &[RecordChange<'_>],
    ) -> Result<bool, StorageError> {
        self.apply_checked_inner(expected, changes, None)
    }
    /// Backup restore also rejects phantom configuration rows inserted by
    /// another SQLite connection after snapshot capture. Check under the same
    /// IMMEDIATE write transaction as the row comparisons and mutations.
    pub(crate) fn apply_checked_data_version(
        &mut self,
        expected: &[(&str, Option<&[u8]>)],
        changes: &[RecordChange<'_>],
        version: i64,
    ) -> Result<bool, StorageError> {
        self.apply_checked_inner(expected, changes, Some(version))
    }
    fn apply_checked_inner(
        &mut self,
        expected: &[(&str, Option<&[u8]>)],
        changes: &[RecordChange<'_>],
        version: Option<i64>,
    ) -> Result<bool, StorageError> {
        let tx = self
            .db
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(version) = version {
            let actual: i64 = tx.query_row("PRAGMA data_version", [], |row| row.get(0))?;
            if actual != version {
                return Ok(false);
            }
        }
        for (id, expected) in expected {
            validate_id(id)?;
            let row: Option<(Vec<u8>, Vec<u8>)> = tx
                .query_row(
                    "SELECT nonce, ciphertext FROM records WHERE id=?1",
                    [id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            let actual = row
                .map(|row| decrypt_record(&self.key, id, row))
                .transpose()?;
            if actual.as_deref().map(Vec::as_slice) != *expected {
                return Ok(false);
            }
        }
        let notify = cloud_sync::journal::record_transaction(&tx, &self.key, changes)?;
        for change in changes {
            match change {
                RecordChange::Put(id, bytes) => {
                    validate_id(id)?;
                    let (nonce, ciphertext) = encrypt(&self.key, id, bytes)?;
                    tx.execute("INSERT INTO records VALUES (?1, ?2, ?3) ON CONFLICT(id) DO UPDATE SET nonce=excluded.nonce, ciphertext=excluded.ciphertext",
                        params![id, nonce.as_slice(), ciphertext])?;
                }
                RecordChange::Delete(id) => {
                    validate_id(id)?;
                    tx.execute("DELETE FROM records WHERE id=?1", [id])?;
                }
            }
        }
        tx.commit()?;
        if notify {
            cloud_sync::journal::committed(&self.instance_id);
        }
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn data_version_guard_rejects_an_unlisted_external_phantom_under_write_transaction() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("phantom.vault");
        let mut first = Vault::create(&path, b"synthetic-phantom-password").unwrap();
        first.put("watched", b"original").unwrap();
        let version: i64 = first
            .db
            .query_row("PRAGMA data_version", [], |r| r.get(0))
            .unwrap();
        let mut second = Vault::open(&path, b"synthetic-phantom-password").unwrap();
        second
            .put("new-unlisted-row", b"synthetic-new-configuration")
            .unwrap();
        assert!(
            !first
                .apply_checked_data_version(
                    &[("watched", Some(b"original"))],
                    &[RecordChange::Put("watched", b"modified")],
                    version
                )
                .unwrap()
        );
        assert_eq!(
            first.get("watched").unwrap().unwrap().as_slice(),
            b"original"
        );
        let current: i64 = first
            .db
            .query_row("PRAGMA data_version", [], |r| r.get(0))
            .unwrap();
        assert!(
            first
                .apply_checked_data_version(
                    &[("watched", Some(b"original"))],
                    &[RecordChange::Put("watched", b"modified")],
                    current
                )
                .unwrap()
        );
    }
    #[test]
    fn bounded_reads_preserve_exact_limits_and_reject_oversize_before_returning_bytes() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("bounded.vault");
        let mut vault = Vault::create(&path, b"test-only-bounded-master").unwrap();
        vault.put("small", b"known").unwrap();
        assert_eq!(
            vault.get_bounded("small", 5).unwrap().unwrap().as_slice(),
            b"known"
        );
        assert!(matches!(
            vault.get_bounded("small", 4),
            Err(StorageError::RecordTooLarge)
        ));
        assert!(vault.get_bounded("absent", 0).unwrap().is_none());
        vault.put("empty", b"").unwrap();
        assert!(vault.get_bounded("empty", 0).unwrap().unwrap().is_empty());
        let large = Zeroizing::new(vec![42; 2 * 1024 * 1024]);
        vault.put("large", &large).unwrap();
        assert!(matches!(
            vault.get_bounded("large", 64),
            Err(StorageError::RecordTooLarge)
        ));
        assert_eq!(
            vault.get("large").unwrap().unwrap().as_slice(),
            large.as_slice()
        );
        vault
            .db
            .execute("UPDATE records SET nonce=x'00' WHERE id='small'", [])
            .unwrap();
        assert!(matches!(
            vault.get_bounded("small", 5),
            Err(StorageError::Authentication)
        ));
    }
    #[test]
    fn checked_records_reject_stale_writers_and_roll_back_all_changes() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("checked.vault");
        let mut first = Vault::create(&path, b"test-only-checked-master").unwrap();
        first.put("revision", b"old").unwrap();
        let mut other = Vault::open(&path, b"test-only-checked-master").unwrap();
        other.put("revision", b"new").unwrap();
        assert!(
            !first
                .apply_checked(
                    &[("revision", Some(b"old"))],
                    &[
                        RecordChange::Put("body", b"must-not-publish"),
                        RecordChange::Delete("revision"),
                    ]
                )
                .unwrap()
        );
        assert!(first.get("body").unwrap().is_none());
        assert_eq!(first.get("revision").unwrap().unwrap().as_slice(), b"new");
        assert!(
            first
                .apply_checked(
                    &[("revision", Some(b"new")), ("body", None)],
                    &[
                        RecordChange::Put("body", b"complete-body"),
                        RecordChange::Put("revision", b"final"),
                    ]
                )
                .unwrap()
        );
        assert!(
            first
                .apply_checked(
                    &[("revision", Some(b"final"))],
                    &[
                        RecordChange::Delete("body"),
                        RecordChange::Put("__invalid", b"rejected"),
                    ]
                )
                .is_err()
        );
        assert_eq!(
            first.get("body").unwrap().unwrap().as_slice(),
            b"complete-body"
        );
        first
            .db
            .execute("UPDATE records SET nonce=x'00' WHERE id='revision'", [])
            .unwrap();
        assert!(matches!(
            first.apply_checked(&[("revision", None)], &[RecordChange::Delete("body"),]),
            Err(StorageError::Authentication)
        ));
        assert!(first.get("body").unwrap().is_some());
    }
    #[test]
    fn simultaneous_connections_cannot_both_publish_from_the_same_revision() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("concurrent.vault");
        let mut first = Vault::create(&path, b"test-only-checked-master").unwrap();
        first.put("revision", b"base").unwrap();
        let second = Vault::open(&path, b"test-only-checked-master").unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let threads = [first, second]
            .into_iter()
            .enumerate()
            .map(|(n, mut vault)| {
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    vault.apply_checked(
                        &[("revision", Some(b"base"))],
                        &[RecordChange::Put(
                            "revision",
                            if n == 0 { b"first" } else { b"second" },
                        )],
                    )
                })
            })
            .collect::<Vec<_>>();
        let winners = threads
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .filter(|result| matches!(result, Ok(true)))
            .count();
        assert_eq!(winners, 1);
        let final_vault = Vault::open(&path, b"test-only-checked-master").unwrap();
        assert_ne!(
            final_vault.get("revision").unwrap().unwrap().as_slice(),
            b"base"
        );
    }
}
