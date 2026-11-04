//! Device-local encrypted transfer checkpoints, deliberately separate from the
//! host catalog, cloud configuration payloads and backups. No automatic resume.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use zeroize::Zeroizing;

mod partitioned;
pub use partitioned::{CheckpointMetadata, TaskCheckpoint};

const INDEX: &str = "local-transfer-index-v1";
const MAX_TASKS: usize = 10_000;
/// Aggregate encoded checkpoint budget (root and encrypted-part plaintexts).
pub const MAX_CHECKPOINT: usize = 64 * 1024 * 1024;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Index {
    version: u32,
    ids: Vec<String>,
}
#[derive(thiserror::Error, Debug)]
pub enum JournalError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("本机传输状态格式无效或版本不受支持")]
    Format,
    #[error("本机传输状态超过安全容量；原检查点未修改")]
    Capacity,
}
type Result<T> = std::result::Result<T, JournalError>;
pub struct LocalTaskJournal<'a> {
    vault: &'a mut Vault,
    index: &'static str,
    prefix: &'static str,
}
fn valid_id(id: &str) -> bool {
    id.len() == 37
        && id.starts_with("task-")
        && id.as_bytes()[5..].iter().all(u8::is_ascii_hexdigit)
}
#[cfg(test)]
fn record(id: &str) -> Result<String> {
    if !valid_id(id) {
        return Err(JournalError::Format);
    }
    Ok(format!("local-transfer-{id}"))
}
impl<'a> LocalTaskJournal<'a> {
    pub fn new(vault: &'a mut Vault) -> Self {
        Self {
            vault,
            index: INDEX,
            prefix: "local-transfer-",
        }
    }
    /// Distinct inventory and encrypted record IDs keep remote-copy manifests
    /// out of the existing upload/download restorer. Both remain device-local.
    pub fn remote_copies(vault: &'a mut Vault) -> Self {
        Self {
            vault,
            index: "local-remote-transfer-index-v1",
            prefix: "local-remote-transfer-",
        }
    }
    fn record(&self, id: &str) -> Result<String> {
        if !valid_id(id) {
            return Err(JournalError::Format);
        }
        Ok(format!("{}{id}", self.prefix))
    }
    pub fn list(&self) -> Result<Vec<String>> {
        let Some(raw) = self.vault.get(self.index)? else {
            return Ok(Vec::new());
        };
        if raw.len() > 2 * 1024 * 1024 {
            return Err(JournalError::Capacity);
        }
        let index: Index = serde_json::from_slice(&raw).map_err(|_| JournalError::Format)?;
        if index.version != 1 || index.ids.len() > MAX_TASKS {
            return Err(JournalError::Format);
        }
        let mut seen = HashSet::new();
        if index.ids.iter().any(|id| !valid_id(id) || !seen.insert(id)) {
            return Err(JournalError::Format);
        }
        Ok(index.ids)
    }
    /// The caller validates its own versioned task format and actual server
    /// binding before starting any filesystem or network operation.
    pub fn load(&self, id: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
        let key = self.record(id)?;
        if !self.list()?.iter().any(|saved| saved == id) {
            return Ok(None);
        }
        let bytes = self.vault.get(&key)?.ok_or(JournalError::Format)?;
        if bytes.len() > MAX_CHECKPOINT {
            return Err(JournalError::Capacity);
        }
        Ok(Some(bytes))
    }
    /// Replace an acknowledged checkpoint atomically. Call on a storage worker;
    /// not once per byte/chunk and never from the terminal receive actor.
    pub fn save(&mut self, id: &str, checkpoint: &[u8]) -> Result<()> {
        let key = self.record(id)?;
        if checkpoint.is_empty() || checkpoint.len() > MAX_CHECKPOINT {
            return Err(JournalError::Capacity);
        }
        let old = self.part_keys(id)?;
        let index = self.inventory_with(id)?;
        let mut changes = vec![
            RecordChange::Put(self.index, &index),
            RecordChange::Put(&key, checkpoint),
        ];
        changes.extend(old.iter().map(|key| RecordChange::Delete(key)));
        self.vault.apply(&changes)?;
        Ok(())
    }
    fn inventory_with(&self, id: &str) -> Result<Zeroizing<Vec<u8>>> {
        self.record(id)?;
        let mut ids = self.list()?;
        if !ids.iter().any(|saved| saved == id) {
            if ids.len() >= MAX_TASKS {
                return Err(JournalError::Capacity);
            }
            ids.push(id.into());
        }
        Ok(Zeroizing::new(
            serde_json::to_vec(&Index { version: 1, ids }).map_err(|_| JournalError::Format)?,
        ))
    }
    /// Successful/cancelled tasks are retained only in runtime UI state. Remove
    /// their checkpoints plus inventory in one transaction; never delete files.
    pub fn remove(&mut self, task_ids: &[String]) -> Result<()> {
        let mut keys: Vec<String> = task_ids
            .iter()
            .map(|id| self.record(id))
            .collect::<Result<_>>()?;
        for id in task_ids.iter().collect::<HashSet<_>>() {
            keys.extend(self.part_keys(id)?);
        }
        let remove: HashSet<&String> = task_ids.iter().collect();
        let mut ids = self.list()?;
        ids.retain(|id| !remove.contains(id));
        let index = Zeroizing::new(
            serde_json::to_vec(&Index { version: 1, ids }).map_err(|_| JournalError::Format)?,
        );
        let mut changes: Vec<RecordChange<'_>> =
            keys.iter().map(|key| RecordChange::Delete(key)).collect();
        changes.push(RecordChange::Put(self.index, &index));
        self.vault.apply(&changes)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const A: &str = "task-00000000000000000000000000000001";
    const B: &str = "task-00000000000000000000000000000002";
    #[test]
    fn remote_journal_rolls_back_all_parts_and_unknown_inventory_does_not_block_local_tasks() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &temp.path().join("remote-rollback.vault"),
            b"synthetic-remote-journal-rollback",
        )
        .unwrap();
        LocalTaskJournal::remote_copies(&mut vault)
            .replace_parts(A, b"old metadata", &[b"old block"])
            .unwrap();
        let key = format!("local-remote-transfer-{A}-part-0");
        vault.db.execute_batch(&format!("CREATE TRIGGER deny_remote_chunk BEFORE INSERT ON records WHEN NEW.id='{key}' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;")).unwrap();
        assert!(
            LocalTaskJournal::remote_copies(&mut vault)
                .update_parts(A, b"uncommitted metadata", &[(0, b"uncommitted block")])
                .is_err()
        );
        let TaskCheckpoint::Partitioned { metadata, parts } =
            LocalTaskJournal::remote_copies(&mut vault)
                .load_parts(A)
                .unwrap()
                .unwrap()
        else {
            panic!("partitioned checkpoint expected");
        };
        assert_eq!(metadata.as_slice(), b"old metadata");
        assert_eq!(parts[0].as_slice(), b"old block");
        vault
            .put(
                "local-remote-transfer-index-v1",
                br#"{"version":2,"ids":[]}"#,
            )
            .unwrap();
        assert!(
            LocalTaskJournal::remote_copies(&mut vault)
                .save(B, b"must not reset inventory")
                .is_err()
        );
        LocalTaskJournal::new(&mut vault)
            .save(B, b"independent local")
            .unwrap();
        assert_eq!(LocalTaskJournal::new(&mut vault).list().unwrap(), vec![B]);
        assert_eq!(
            vault
                .get("local-remote-transfer-index-v1")
                .unwrap()
                .unwrap()
                .as_slice(),
            br#"{"version":2,"ids":[]}"#
        );
    }
    #[test]
    fn remote_copy_journal_is_encrypted_partitioned_and_independent_of_local_transfer_ids() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("two-task-kinds.vault");
        let mut vault = Vault::create(&path, b"synthetic-journal-namespace-test").unwrap();
        LocalTaskJournal::new(&mut vault)
            .replace_parts(A, b"local metadata", &[b"local block"])
            .unwrap();
        let mut remote = LocalTaskJournal::remote_copies(&mut vault);
        assert!(remote.list().unwrap().is_empty());
        assert!(remote.load_parts(A).unwrap().is_none());
        remote
            .replace_parts(
                A,
                b"remote endpoint metadata",
                &[
                    b"private remote path zero".as_slice(),
                    b"private remote path one",
                ],
            )
            .unwrap();
        remote
            .update_parts(A, b"remote updated", &[(1, b"remote replacement")])
            .unwrap();
        assert_eq!(remote.list().unwrap(), vec![A]);
        drop(vault);
        let raw = std::fs::read(&path).unwrap();
        assert!(
            !raw.windows(b"private remote path".len())
                .any(|w| w == b"private remote path")
        );
        let mut vault = Vault::open(&path, b"synthetic-journal-namespace-test").unwrap();
        let TaskCheckpoint::Partitioned { metadata, parts } =
            LocalTaskJournal::remote_copies(&mut vault)
                .load_parts(A)
                .unwrap()
                .unwrap()
        else {
            panic!("partitioned checkpoint expected");
        };
        assert_eq!(metadata.as_slice(), b"remote updated");
        assert_eq!(parts[0].as_slice(), b"private remote path zero");
        assert_eq!(parts[1].as_slice(), b"remote replacement");
        LocalTaskJournal::new(&mut vault)
            .remove(&[A.into()])
            .unwrap();
        assert_eq!(
            LocalTaskJournal::remote_copies(&mut vault).list().unwrap(),
            vec![A]
        );
        LocalTaskJournal::new(&mut vault)
            .save(B, b"independent local task")
            .unwrap();
        LocalTaskJournal::remote_copies(&mut vault)
            .remove(&[A.into()])
            .unwrap();
        assert_eq!(
            LocalTaskJournal::new(&mut vault)
                .load(B)
                .unwrap()
                .unwrap()
                .as_slice(),
            b"independent local task"
        );
        assert!(
            LocalTaskJournal::remote_copies(&mut vault)
                .list()
                .unwrap()
                .is_empty()
        );
        assert!(
            vault
                .get(&format!("local-remote-transfer-{A}-part-0"))
                .unwrap()
                .is_none()
        );
    }
    #[test]
    fn partitioned_checkpoints_update_only_dirty_ciphertexts_and_remove_all_parts() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("partitioned.vault");
        let mut vault = Vault::create(&path, b"test-only-partitioned-journal").unwrap();
        vault.put("independent-host-fixture", b"keep host").unwrap();
        let mut journal = LocalTaskJournal::new(&mut vault);
        journal.save(A, b"legacy checkpoint").unwrap();
        assert!(matches!(
            journal.load_parts(A).unwrap(),
            Some(TaskCheckpoint::Legacy(_))
        ));
        journal
            .replace_parts(
                A,
                b"private-fixture-path metadata",
                &[b"part one", b"part two", b"part three"],
            )
            .unwrap();
        let key = format!("local-transfer-{A}-part-0");
        let untouched = vault.get(&key).unwrap().unwrap();
        let ciphertext: Vec<u8> = vault
            .db
            .query_row("SELECT ciphertext FROM records WHERE id=?1", [&key], |r| {
                r.get(0)
            })
            .unwrap();
        let mut journal = LocalTaskJournal::new(&mut vault);
        journal
            .update_parts(A, b"new metadata", &[(1, b"changed part")])
            .unwrap();
        let after: Vec<u8> = vault
            .db
            .query_row("SELECT ciphertext FROM records WHERE id=?1", [&key], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(
            ciphertext, after,
            "unchanged chunks must not be re-encrypted"
        );
        assert_eq!(
            vault.get(&key).unwrap().unwrap().as_slice(),
            untouched.as_slice()
        );
        drop(vault);
        let raw = std::fs::read(&path).unwrap();
        for forbidden in [b"private-fixture-path".as_slice(), b"changed part"] {
            assert!(!raw.windows(forbidden.len()).any(|w| w == forbidden));
        }
        let mut vault = Vault::open(&path, b"test-only-partitioned-journal").unwrap();
        let mut journal = LocalTaskJournal::new(&mut vault);
        let TaskCheckpoint::Partitioned { metadata, parts } =
            journal.load_parts(A).unwrap().unwrap()
        else {
            panic!("expected partitioned checkpoint");
        };
        assert_eq!(metadata.as_slice(), b"new metadata");
        assert_eq!(
            parts.iter().map(|p| p.as_slice()).collect::<Vec<_>>(),
            [b"part one".as_slice(), b"changed part", b"part three"]
        );
        journal
            .replace_parts(A, b"shorter manifest", &[b"only part"])
            .unwrap();
        assert!(
            vault
                .get(&format!("local-transfer-{A}-part-2"))
                .unwrap()
                .is_none()
        );
        let mut journal = LocalTaskJournal::new(&mut vault);
        journal.remove(&[A.into(), A.into()]).unwrap();
        assert!(journal.list().unwrap().is_empty());
        let remaining: u32 = vault
            .db
            .query_row(
                "SELECT count(*) FROM records WHERE id LIKE 'local-transfer-task-%'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(remaining, 0);
        assert_eq!(
            vault
                .get("independent-host-fixture")
                .unwrap()
                .unwrap()
                .as_slice(),
            b"keep host"
        );
    }

    #[test]
    fn partitioned_updates_roll_back_and_validate_revisions_and_indices() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &temp.path().join("partitioned-rollback.vault"),
            b"test-only-partitioned-rollback",
        )
        .unwrap();
        LocalTaskJournal::new(&mut vault)
            .replace_parts(A, b"old meta", &[b"old zero", b"old one"])
            .unwrap();
        let old_meta = vault.get(&record(A).unwrap()).unwrap().unwrap();
        let key = format!("local-transfer-{A}-part-1");
        let old_part = vault.get(&key).unwrap().unwrap();
        vault.db.execute_batch(&format!("CREATE TRIGGER deny_chunk BEFORE INSERT ON records WHEN NEW.id='{key}' BEGIN SELECT RAISE(ABORT, 'test chunk fault'); END;")).unwrap();
        let mut journal = LocalTaskJournal::new(&mut vault);
        assert!(
            journal
                .update_parts(A, b"uncommitted", &[(1, b"new one")])
                .is_err()
        );
        assert_eq!(
            vault.get(&record(A).unwrap()).unwrap().unwrap().as_slice(),
            old_meta.as_slice()
        );
        assert_eq!(
            vault.get(&key).unwrap().unwrap().as_slice(),
            old_part.as_slice()
        );
        vault.db.execute_batch("DROP TRIGGER deny_chunk").unwrap();
        vault.db.execute_batch(&format!("CREATE TRIGGER deny_tail BEFORE DELETE ON records WHEN OLD.id='{key}' BEGIN SELECT RAISE(ABORT, 'test tail cleanup fault'); END;")).unwrap();
        assert!(
            LocalTaskJournal::new(&mut vault)
                .replace_parts(A, b"uncommitted shorter", &[b"replacement zero"])
                .is_err()
        );
        assert_eq!(
            vault.get(&record(A).unwrap()).unwrap().unwrap().as_slice(),
            old_meta.as_slice()
        );
        let TaskCheckpoint::Partitioned { metadata, parts } = LocalTaskJournal::new(&mut vault)
            .load_parts(A)
            .unwrap()
            .unwrap()
        else {
            panic!("expected original checkpoint");
        };
        assert_eq!(metadata.as_slice(), b"old meta");
        assert_eq!(parts[0].as_slice(), b"old zero");
        assert_eq!(parts[1].as_slice(), b"old one");
        vault.db.execute_batch("DROP TRIGGER deny_tail").unwrap();
        let mut journal = LocalTaskJournal::new(&mut vault);
        assert!(
            journal
                .update_parts(A, b"bad index", &[(2, b"invalid")])
                .is_err()
        );
        assert!(
            journal
                .update_parts(A, b"duplicate index", &[(0, b"a"), (0, b"b")])
                .is_err()
        );
        journal
            .update_parts(A, b"new meta", &[(1, b"new one")])
            .unwrap();
        // Replaying an old, validly encrypted chunk cannot match the new root.
        vault.put(&key, &old_part).unwrap();
        assert!(LocalTaskJournal::new(&mut vault).load_parts(A).is_err());
        vault.delete(&key).unwrap();
        assert!(LocalTaskJournal::new(&mut vault).load_parts(A).is_err());
        // A full legacy replacement removes obsolete parts as well.
        let mut journal = LocalTaskJournal::new(&mut vault);
        journal.save(A, b"legacy replacement").unwrap();
        assert!(matches!(
            journal.load_parts(A).unwrap(),
            Some(TaskCheckpoint::Legacy(_))
        ));
        assert!(
            vault
                .get(&format!("local-transfer-{A}-part-0"))
                .unwrap()
                .is_none()
        );
    }
    #[test]
    fn checkpoints_reopen_encrypted_and_completed_removal_is_local_only() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("tasks.vault");
        let mut vault = Vault::create(&path, b"test-only-task-journal").unwrap();
        vault.put("independent-host-fixture", b"keep host").unwrap();
        let mut journal = LocalTaskJournal::new(&mut vault);
        assert!(journal.list().unwrap().is_empty());
        journal
            .save(A, b"/private-fixture-path offset=65536")
            .unwrap();
        journal.save(B, b"another waiting fixture").unwrap();
        journal
            .save(A, b"/private-fixture-path offset=131072")
            .unwrap();
        assert_eq!(journal.list().unwrap(), [A, B]);
        drop(vault);
        let raw = std::fs::read(&path).unwrap();
        assert!(
            !raw.windows(b"private-fixture-path".len())
                .any(|w| w == b"private-fixture-path")
        );
        let mut vault = Vault::open(&path, b"test-only-task-journal").unwrap();
        let mut journal = LocalTaskJournal::new(&mut vault);
        assert_eq!(
            journal.load(A).unwrap().unwrap().as_slice(),
            b"/private-fixture-path offset=131072"
        );
        journal.remove(&[A.into()]).unwrap();
        assert!(journal.load(A).unwrap().is_none());
        assert_eq!(journal.list().unwrap(), [B]);
        assert!(journal.load("host-not-a-task").is_err());
        assert!(journal.remove(&["host-not-a-task".into()]).is_err());
        journal.remove(&[B.into(), B.into()]).unwrap();
        assert!(journal.list().unwrap().is_empty());
        assert_eq!(
            vault
                .get("independent-host-fixture")
                .unwrap()
                .unwrap()
                .as_slice(),
            b"keep host"
        );
    }
    #[test]
    fn journal_transactions_roll_back_and_unknown_format_is_never_reset() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("rollback.vault");
        let mut vault = Vault::create(&path, b"test-only-journal-rollback").unwrap();
        LocalTaskJournal::new(&mut vault)
            .save(A, b"old checkpoint")
            .unwrap();
        // Simulate a storage failure after inventory update, before new state.
        vault.db.execute_batch("CREATE TRIGGER deny_task BEFORE INSERT ON records WHEN NEW.id='local-transfer-task-00000000000000000000000000000002' BEGIN SELECT RAISE(ABORT, 'test checkpoint fault'); END;").unwrap();
        let mut journal = LocalTaskJournal::new(&mut vault);
        assert!(journal.save(B, b"not committed").is_err());
        assert_eq!(journal.list().unwrap(), [A]);
        assert_eq!(
            journal.load(A).unwrap().unwrap().as_slice(),
            b"old checkpoint"
        );
        assert!(journal.load(B).unwrap().is_none());
        assert!(journal.save(A, &[]).is_err());
        vault.put(INDEX, br#"{"version":2,"ids":[]}"#).unwrap();
        let mut journal = LocalTaskJournal::new(&mut vault);
        assert!(journal.list().is_err());
        assert!(journal.save(B, b"must not reset newer data").is_err());
        assert_eq!(
            vault.get(&record(A).unwrap()).unwrap().unwrap().as_slice(),
            b"old checkpoint"
        );
    }
}
