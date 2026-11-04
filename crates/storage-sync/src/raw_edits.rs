//! Device-only raw editor snapshots. Metadata contains an owner, never a second
//! mutable body pointer. Publication and remote acknowledgement are distinct.
use crate::{
    RecordChange, Vault,
    edit_blobs::{BlobError, BlobInfo, BlobTicket, EditBlobs},
    local_edits::{EditMetadata, EditTarget, Encoding, LineEnding},
};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

const INDEX: &str = "local-edit-raw-index-v1";
const MAX_DOCUMENTS: usize = 256;
type Result<T> = std::result::Result<T, RawEditError>;
#[derive(thiserror::Error, Debug)]
pub enum RawEditError {
    #[error(transparent)]
    Storage(#[from] crate::StorageError),
    #[error(transparent)]
    Blob(#[from] BlobError),
    #[error("大正文草稿格式未知或损坏；原数据保留")]
    Format,
    #[error("大正文草稿不存在")]
    Missing,
    #[error("大正文草稿版本已改变；未覆盖较新内容")]
    Changed,
    #[error("草稿仍关联外部工作文件，请先确认结束并清理")]
    ExternalCopy,
    #[error("草稿数量或修订号超过容量；未截断")]
    Capacity,
}

#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "edit-cccccccccccccccccccccccccccccccc";
    fn pending() -> RawEditMetadata {
        RawEditMetadata {
            version: 2,
            id: ID.into(),
            target: EditTarget {
                host_id: "synthetic-host".into(),
                address: "127.0.0.1".into(),
                port: 22,
                username: "fixture".into(),
                fingerprint: "SHA256:synthetic-only".into(),
            },
            path: "/alias".into(),
            revision: 1,
            saved_revision: 0,
            bytes: 0,
            ready: false,
            external_directory: None,
        }
    }
    #[test]
    fn raw_drafts_publish_atomic_snapshots_keep_pins_and_reopen_without_network() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("raw.vault");
        let mut vault = Vault::create(&path, b"test-only-raw-master").unwrap();
        RawEditJournal::new(&mut vault).create(&pending()).unwrap();
        let mut capture = RawEditJournal::new(&mut vault)
            .begin_capture(ID, 1, Some(3))
            .unwrap();
        EditBlobs::new(&mut vault)
            .append(&mut capture, b"old")
            .unwrap();
        let meta = RawEditJournal::new(&mut vault)
            .publish(&capture, Some("/canonical ' 中文.txt"))
            .unwrap();
        assert!(meta.ready && !meta.dirty());
        assert_eq!(meta.revision, 2);
        assert_eq!(meta.path, "/canonical ' 中文.txt");
        assert!(
            RawEditJournal::new(&mut vault)
                .publish(&capture, None)
                .is_err()
        );
        let mut modified = RawEditJournal::new(&mut vault)
            .begin_capture(ID, 2, Some(3))
            .unwrap();
        EditBlobs::new(&mut vault)
            .append(&mut modified, b"new")
            .unwrap();
        let directory = crate::external_edits::ExternalCopy::location(root.path(), ID)
            .unwrap()
            .to_str()
            .unwrap()
            .to_owned();
        RawEditJournal::new(&mut vault)
            .set_external_directory(ID, 2, Some(directory.clone()))
            .unwrap();
        let meta = RawEditJournal::new(&mut vault)
            .publish(&modified, None)
            .unwrap();
        assert!(meta.dirty());
        assert_eq!(meta.external_directory.as_deref(), Some(directory.as_str()));
        assert!(matches!(
            RawEditJournal::new(&mut vault).mark_saved(ID, 2),
            Err(RawEditError::Changed)
        ));
        assert!(matches!(
            RawEditJournal::new(&mut vault).discard(ID, 3),
            Err(RawEditError::ExternalCopy)
        ));
        drop(vault);
        let mut vault = Vault::open(&path, b"test-only-raw-master").unwrap();
        let meta = RawEditJournal::new(&mut vault).load(ID).unwrap();
        assert!(meta.dirty());
        let info = RawEditJournal::new(&mut vault).body(ID, 3).unwrap();
        assert_eq!(
            EditBlobs::new(&mut vault)
                .read_chunk(&info, 0)
                .unwrap()
                .as_slice(),
            b"new"
        );
        assert!(
            crate::local_edits::EditJournal::new(&mut vault)
                .list()
                .unwrap()
                .is_empty()
        );
        let meta = RawEditJournal::new(&mut vault).mark_saved(ID, 3).unwrap();
        assert!(!meta.dirty());
        RawEditJournal::new(&mut vault)
            .set_external_directory(ID, 3, None)
            .unwrap();
        RawEditJournal::new(&mut vault).discard(ID, 3).unwrap();
        assert!(RawEditJournal::new(&mut vault).list().unwrap().is_empty());
        drop(vault);
        let mut vault = Vault::open(&path, b"test-only-raw-master").unwrap();
        let mut blobs = EditBlobs::new(&mut vault);
        let pending = blobs.pending_reclamation().unwrap();
        assert_eq!(pending.len(), 2);
        for info in pending {
            assert!(blobs.reclaim_step(&info.id, 1).unwrap());
        }
        assert!(blobs.list(ID).unwrap().is_empty());
    }
    #[test]
    fn pending_raw_reads_and_future_metadata_never_become_savable_or_overwrite_inline_drafts() {
        let root = tempfile::tempdir().unwrap();
        let mut vault =
            Vault::create(&root.path().join("pending.vault"), b"test-only-raw-master").unwrap();
        let meta = pending();
        let mut oversized = meta.clone();
        oversized.ready = true;
        oversized.revision = 2;
        oversized.saved_revision = 2;
        oversized.bytes = crate::edit_blobs::MAX_BODY_BYTES + 1;
        assert!(matches!(oversized.validate(), Err(RawEditError::Format)));
        let mut journal = RawEditJournal::new(&mut vault);
        let mut escaped = meta.clone();
        escaped.path = format!("/{}", "\n".repeat(131071));
        assert!(matches!(
            journal.create(&escaped),
            Err(RawEditError::Capacity)
        ));
        assert!(journal.list().unwrap().is_empty());
        journal.create(&meta).unwrap();
        assert!(!journal.load(ID).unwrap().ready);
        assert!(journal.mark_saved(ID, 1).is_err());
        assert!(journal.body(ID, 1).is_err());
        let mut capture = journal.begin_capture(ID, 1, Some(5)).unwrap();
        EditBlobs::new(&mut vault)
            .append(&mut capture, b"part")
            .unwrap();
        assert!(
            RawEditJournal::new(&mut vault)
                .publish(&capture, Some("/canonical"))
                .is_err()
        );
        assert!(!RawEditJournal::new(&mut vault).load(ID).unwrap().ready);
        let mut future = meta.clone();
        future.version = 99;
        let future = json(&future).unwrap();
        vault.put(&key(ID).unwrap(), &future).unwrap();
        assert!(RawEditJournal::new(&mut vault).list().is_err());
        assert!(RawEditJournal::new(&mut vault).discard(ID, 1).is_err());
        assert_eq!(
            vault.get(&key(ID).unwrap()).unwrap().unwrap().as_slice(),
            future.as_slice()
        );
        vault.put(&key(ID).unwrap(), &json(&meta).unwrap()).unwrap();
        RawEditJournal::new(&mut vault).discard(ID, 1).unwrap();
        assert_eq!(
            EditBlobs::new(&mut vault)
                .pending_reclamation()
                .unwrap()
                .len(),
            1
        );
        assert!(
            EditBlobs::new(&mut vault)
                .reclaim_step(capture.id(), 1)
                .unwrap()
        );
        vault
            .put(&key(ID).unwrap(), b"inline fixture data")
            .unwrap();
        assert!(matches!(
            RawEditJournal::new(&mut vault).create(&meta),
            Err(RawEditError::Changed)
        ));
        assert_eq!(
            vault.get(&key(ID).unwrap()).unwrap().unwrap().as_slice(),
            b"inline fixture data"
        );
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RawEditMetadata {
    pub version: u32,
    pub id: String,
    pub target: EditTarget,
    pub path: String,
    pub revision: u64,
    pub saved_revision: u64,
    pub bytes: u64,
    /// False until all source bytes and the enclosing SFTP CLOSE are confirmed.
    pub ready: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_directory: Option<String>,
}
impl RawEditMetadata {
    pub fn dirty(&self) -> bool {
        !self.ready || self.revision != self.saved_revision
    }
    fn validate(&self) -> Result<()> {
        if self.version != 2
            || self.bytes > crate::edit_blobs::MAX_BODY_BYTES
            || (!self.ready && (self.revision != 1 || self.saved_revision != 0 || self.bytes != 0))
        {
            return Err(RawEditError::Format);
        }
        // Share target/path/pin validation with the established inline journal.
        let common = EditMetadata {
            version: 1,
            id: self.id.clone(),
            target: self.target.clone(),
            path: self.path.clone(),
            encoding: Encoding::Utf8,
            line_ending: LineEnding::Preserve,
            revision: self.revision,
            saved_revision: self.saved_revision,
            external_directory: self.external_directory.clone(),
        };
        common.validate().map_err(|_| RawEditError::Format)
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Inventory {
    version: u32,
    ids: Vec<String>,
}
fn valid(id: &str) -> bool {
    id.strip_prefix("edit-")
        .is_some_and(|s| s.len() == 32 && s.bytes().all(|b| b.is_ascii_hexdigit()))
}
fn key(id: &str) -> Result<String> {
    if !valid(id) {
        return Err(RawEditError::Format);
    }
    Ok(format!("local-edit-meta-{id}"))
}
fn json<T: Serialize>(value: &T) -> Result<Zeroizing<Vec<u8>>> {
    let bytes = Zeroizing::new(serde_json::to_vec(value).map_err(|_| RawEditError::Format)?);
    if bytes.len() > 256 * 1024 {
        return Err(RawEditError::Capacity);
    }
    Ok(bytes)
}
fn condition(value: &Option<Zeroizing<Vec<u8>>>) -> Option<&[u8]> {
    value.as_deref().map(Vec::as_slice)
}

pub struct RawEditJournal<'a> {
    vault: &'a mut Vault,
}
impl<'a> RawEditJournal<'a> {
    pub fn new(vault: &'a mut Vault) -> Self {
        Self { vault }
    }
    pub fn contains(&self, id: &str) -> Result<bool> {
        key(id)?;
        Ok(self.inventory()?.0.ids.iter().any(|v| v == id))
    }
    fn inventory(&self) -> Result<(Inventory, Option<Zeroizing<Vec<u8>>>)> {
        let raw = self.vault.get_bounded(INDEX, 64 * 1024)?;
        let value: Inventory = match raw.as_deref() {
            Some(bytes) => serde_json::from_slice(bytes).map_err(|_| RawEditError::Format)?,
            None => Inventory {
                version: 1,
                ids: Vec::new(),
            },
        };
        let mut seen = std::collections::HashSet::new();
        if value.version != 1
            || value.ids.len() > MAX_DOCUMENTS
            || value.ids.iter().any(|v| !valid(v) || !seen.insert(v))
        {
            return Err(RawEditError::Format);
        }
        Ok((value, raw))
    }
    fn metadata(&self, id: &str) -> Result<(RawEditMetadata, Zeroizing<Vec<u8>>)> {
        let raw = self
            .vault
            .get_bounded(&key(id)?, 256 * 1024)?
            .ok_or(RawEditError::Missing)?;
        let meta: RawEditMetadata =
            serde_json::from_slice(&raw).map_err(|_| RawEditError::Format)?;
        meta.validate()?;
        if meta.id != id {
            return Err(RawEditError::Format);
        }
        Ok((meta, raw))
    }
    pub fn load(&self, id: &str) -> Result<RawEditMetadata> {
        let (inventory, _) = self.inventory()?;
        if !inventory.ids.iter().any(|v| v == id) {
            return Err(RawEditError::Missing);
        }
        Ok(self.metadata(id)?.0)
    }
    /// Metadata only, including interrupted initial reads. Does not decrypt bodies.
    pub fn list(&self) -> Result<Vec<RawEditMetadata>> {
        self.inventory()?
            .0
            .ids
            .iter()
            .map(|id| self.metadata(id).map(|v| v.0))
            .collect()
    }
    /// Persist the intent before creating any plaintext working copy.
    pub fn create(&mut self, meta: &RawEditMetadata) -> Result<()> {
        meta.validate()?;
        if meta.ready || meta.revision != 1 || meta.saved_revision != 0 {
            return Err(RawEditError::Format);
        }
        let (mut inventory, old) = self.inventory()?;
        if inventory.ids.len() >= MAX_DOCUMENTS {
            return Err(RawEditError::Capacity);
        }
        if inventory.ids.iter().any(|v| v == &meta.id) {
            return Err(RawEditError::Changed);
        }
        inventory.ids.push(meta.id.clone());
        let next = json(&inventory)?;
        let raw = json(meta)?;
        let key = key(&meta.id)?;
        if !self.vault.apply_checked(
            &[(INDEX, condition(&old)), (&key, None)],
            &[
                RecordChange::Put(INDEX, &next),
                RecordChange::Put(&key, &raw),
            ],
        )? {
            return Err(RawEditError::Changed);
        }
        Ok(())
    }
    pub fn begin_capture(
        &mut self,
        id: &str,
        revision: u64,
        size: Option<u64>,
    ) -> Result<BlobTicket> {
        if self.load(id)?.revision != revision {
            return Err(RawEditError::Changed);
        }
        Ok(EditBlobs::new(self.vault).begin(id, revision, size)?)
    }
    /// First publication requires the canonical path returned by the confirmed
    /// read; subsequent local captures cannot retarget the original remote file.
    pub fn publish(
        &mut self,
        ticket: &BlobTicket,
        canonical: Option<&str>,
    ) -> Result<RawEditMetadata> {
        if !self
            .inventory()?
            .0
            .ids
            .iter()
            .any(|id| id == ticket.owner())
        {
            return Err(RawEditError::Missing);
        }
        let (mut meta, old) = self.metadata(ticket.owner())?;
        if meta.revision != ticket.base_revision() || meta.ready == canonical.is_some() {
            return Err(RawEditError::Changed);
        }
        let initial = !meta.ready;
        if let Some(canonical) = canonical {
            meta.path = canonical.into();
        }
        meta.revision = meta.revision.checked_add(1).ok_or(RawEditError::Capacity)?;
        meta.ready = true;
        meta.bytes = ticket.bytes();
        if initial {
            meta.saved_revision = meta.revision;
        }
        meta.validate()?;
        let raw = json(&meta)?;
        let key = key(&meta.id)?;
        EditBlobs::new(self.vault).finish_with(
            ticket,
            &[(&key, Some(&old))],
            &[RecordChange::Put(&key, &raw)],
        )?;
        Ok(meta)
    }
    fn change_metadata(
        &mut self,
        id: &str,
        revision: u64,
        change: impl FnOnce(&mut RawEditMetadata) -> Result<()>,
    ) -> Result<RawEditMetadata> {
        // Presence in the raw index prevents an inline draft from being reinterpreted.
        self.load(id)?;
        let (mut meta, old) = self.metadata(id)?;
        if meta.revision != revision {
            return Err(RawEditError::Changed);
        }
        change(&mut meta)?;
        meta.validate()?;
        let raw = json(&meta)?;
        let key = key(id)?;
        if !self
            .vault
            .apply_checked(&[(&key, Some(&old))], &[RecordChange::Put(&key, &raw)])?
        {
            return Err(RawEditError::Changed);
        }
        Ok(meta)
    }
    /// Only call after every byte, FSTAT and remote file/channel CLOSE succeeds.
    pub fn mark_saved(&mut self, id: &str, revision: u64) -> Result<RawEditMetadata> {
        self.change_metadata(id, revision, |meta| {
            if !meta.ready {
                return Err(RawEditError::Changed);
            }
            meta.saved_revision = revision;
            Ok(())
        })
    }
    pub fn set_external_directory(
        &mut self,
        id: &str,
        revision: u64,
        directory: Option<String>,
    ) -> Result<RawEditMetadata> {
        self.change_metadata(id, revision, |meta| {
            if meta.external_directory.is_some()
                && directory.is_some()
                && meta.external_directory != directory
            {
                return Err(RawEditError::ExternalCopy);
            }
            meta.external_directory = directory;
            Ok(())
        })
    }
    pub fn body(&mut self, id: &str, revision: u64) -> Result<BlobInfo> {
        let meta = self.load(id)?;
        if !meta.ready || meta.revision != revision {
            return Err(RawEditError::Changed);
        }
        let info = EditBlobs::new(self.vault).open_owner(id)?;
        if info.base_revision.checked_add(1) != Some(revision) || info.bytes != meta.bytes {
            return Err(RawEditError::Format);
        }
        Ok(info)
    }
    /// Caller must drain all readers/captures first and confirm external cleanup.
    /// Retired chunks remain discoverable if interrupted after metadata deletion.
    pub fn discard(&mut self, id: &str, revision: u64) -> Result<()> {
        let (mut inventory, old_index) = self.inventory()?;
        if !inventory.ids.iter().any(|v| v == id) {
            return Err(RawEditError::Missing);
        }
        let (meta, old) = self.metadata(id)?;
        if meta.revision != revision {
            return Err(RawEditError::Changed);
        }
        if meta.external_directory.is_some() {
            return Err(RawEditError::ExternalCopy);
        }
        let current = if meta.ready {
            Some(self.body(id, revision)?)
        } else {
            None
        };
        let mut store = EditBlobs::new(self.vault);
        for info in store.list(id)? {
            if info.deleting || current.as_ref().is_some_and(|v| v.id == info.id) {
                continue;
            }
            if info.complete {
                store.retire_with(&info, &[], &[])?;
            } else {
                store.abort(&store.resume(&info.id)?)?;
            }
        }
        inventory.ids.retain(|v| v != id);
        let next_index = json(&inventory)?;
        let key = key(id)?;
        let checks = [
            (&*key, Some(old.as_slice())),
            (INDEX, condition(&old_index)),
        ];
        let changes = [
            RecordChange::Delete(&key),
            RecordChange::Put(INDEX, &next_index),
        ];
        if let Some(info) = current {
            store.retire_with(&info, &checks, &changes)?;
        } else if !self.vault.apply_checked(&checks, &changes)? {
            return Err(RawEditError::Changed);
        }
        Ok(())
    }
}
