//! Atomic device-local chunk updates. Only opaque task/part IDs are exposed to
//! SQLite; root metadata and chunk payloads use the same ID-bound encryption.
use super::*;
use rand::{RngCore, rngs::OsRng};
use zeroize::Zeroize;

const MAGIC: &[u8] = b"HSPTerm-local-parts\0";
const MAX_PARTS: usize = 4096;
const MAX_MANIFEST: usize = 2 * 1024 * 1024;
const REVISION_BYTES: usize = 16;

pub enum TaskCheckpoint {
    Legacy(Zeroizing<Vec<u8>>),
    Partitioned {
        metadata: Zeroizing<Vec<u8>>,
        parts: Vec<Zeroizing<Vec<u8>>>,
    },
}
/// Read-only root metadata for protecting local cache references. This does
/// not validate or authorize resuming any node body; use load_parts for that.
pub enum CheckpointMetadata {
    Legacy(Zeroizing<Vec<u8>>),
    Partitioned(Zeroizing<Vec<u8>>),
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Part {
    bytes: usize,
    revision: [u8; REVISION_BYTES],
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: u32,
    metadata: Vec<u8>,
    parts: Vec<Part>,
}
impl Drop for Manifest {
    fn drop(&mut self) {
        self.metadata.zeroize();
    }
}
impl Manifest {
    fn validate(&self, encoded_bytes: usize) -> Result<()> {
        if self.version != 1 || self.metadata.is_empty() {
            return Err(JournalError::Format);
        }
        if self.parts.len() > MAX_PARTS || encoded_bytes > MAX_MANIFEST {
            return Err(JournalError::Capacity);
        }
        let mut total = encoded_bytes;
        for part in &self.parts {
            if part.bytes == 0 {
                return Err(JournalError::Format);
            }
            total = total
                .checked_add(part.bytes)
                .and_then(|n| n.checked_add(REVISION_BYTES))
                .ok_or(JournalError::Capacity)?;
            if total > MAX_CHECKPOINT {
                return Err(JournalError::Capacity);
            }
        }
        Ok(())
    }
    fn decode(raw: &[u8]) -> Result<Option<Self>> {
        if !raw.starts_with(MAGIC) {
            return Ok(None);
        }
        if raw.len() > MAX_MANIFEST {
            return Err(JournalError::Capacity);
        }
        let manifest: Self =
            serde_json::from_slice(&raw[MAGIC.len()..]).map_err(|_| JournalError::Format)?;
        manifest.validate(raw.len())?;
        Ok(Some(manifest))
    }
    fn encode(&self) -> Result<Zeroizing<Vec<u8>>> {
        let mut raw = Zeroizing::new(MAGIC.to_vec());
        serde_json::to_writer(&mut *raw, self).map_err(|_| JournalError::Format)?;
        self.validate(raw.len())?;
        Ok(raw)
    }
}
fn descriptor(bytes: usize) -> Result<Part> {
    if bytes == 0 || bytes > MAX_CHECKPOINT {
        return Err(JournalError::Capacity);
    }
    let mut revision = [0; REVISION_BYTES];
    OsRng.fill_bytes(&mut revision);
    Ok(Part { bytes, revision })
}
fn payload(part: &Part, bytes: &[u8]) -> Zeroizing<Vec<u8>> {
    let mut raw = Zeroizing::new(part.revision.to_vec());
    raw.extend_from_slice(bytes);
    raw
}
impl LocalTaskJournal<'_> {
    fn part_key(&self, id: &str, index: usize) -> Result<String> {
        Ok(format!("{}-part-{index}", self.record(id)?))
    }
    /// Read both old single-record checkpoints and the partitioned format.
    /// Missing, truncated, swapped or stale-revision parts fail the whole load.
    pub fn load_parts(&self, id: &str) -> Result<Option<TaskCheckpoint>> {
        let Some(raw) = self.load(id)? else {
            return Ok(None);
        };
        let Some(mut manifest) = Manifest::decode(&raw)? else {
            return Ok(Some(TaskCheckpoint::Legacy(raw)));
        };
        let mut parts = Vec::with_capacity(manifest.parts.len());
        for (index, expected) in manifest.parts.iter().enumerate() {
            let mut bytes = self
                .vault
                .get(&self.part_key(id, index)?)?
                .ok_or(JournalError::Format)?;
            if bytes.len() != expected.bytes + REVISION_BYTES
                || bytes[..REVISION_BYTES] != expected.revision
            {
                return Err(JournalError::Format);
            }
            bytes.drain(..REVISION_BYTES);
            parts.push(bytes);
        }
        Ok(Some(TaskCheckpoint::Partitioned {
            metadata: Zeroizing::new(std::mem::take(&mut manifest.metadata)),
            parts,
        }))
    }

    /// Do not decrypt every node chunk merely to retain its local destination.
    /// Corrupt roots still fail closed. Missing bodies cannot erase the valid
    /// root's protected path, and never grant transfer-resume authority.
    pub fn load_metadata(&self, id: &str) -> Result<Option<CheckpointMetadata>> {
        let Some(raw) = self.load(id)? else {
            return Ok(None);
        };
        match Manifest::decode(&raw)? {
            None => Ok(Some(CheckpointMetadata::Legacy(raw))),
            Some(mut manifest) => Ok(Some(CheckpointMetadata::Partitioned(Zeroizing::new(
                std::mem::take(&mut manifest.metadata),
            )))),
        }
    }

    pub(super) fn part_keys(&self, id: &str) -> Result<Vec<String>> {
        let count = self
            .load(id)?
            .map(|raw| Manifest::decode(&raw))
            .transpose()?
            .flatten()
            .map_or(0, |m| m.parts.len());
        (0..count).map(|i| self.part_key(id, i)).collect()
    }

    /// Replace the entire plan before the first write or after a rescan/rename.
    /// Inventory, root and all parts commit together, including stale tail removal.
    pub fn replace_parts(&mut self, id: &str, metadata: &[u8], parts: &[&[u8]]) -> Result<()> {
        let root = self.record(id)?;
        if metadata.is_empty() || metadata.len() > MAX_MANIFEST || parts.len() > MAX_PARTS {
            return Err(JournalError::Capacity);
        }
        let old = self.part_keys(id)?;
        let mut manifest = Manifest {
            version: 1,
            metadata: metadata.to_vec(),
            parts: Vec::with_capacity(parts.len()),
        };
        let mut payloads = Vec::with_capacity(parts.len());
        let mut total = metadata.len();
        for (i, bytes) in parts.iter().enumerate() {
            total = total
                .checked_add(bytes.len())
                .ok_or(JournalError::Capacity)?;
            if total > MAX_CHECKPOINT {
                return Err(JournalError::Capacity);
            }
            let descriptor = descriptor(bytes.len())?;
            let raw = payload(&descriptor, bytes);
            manifest.parts.push(descriptor);
            payloads.push((self.part_key(id, i)?, raw));
        }
        let encoded = manifest.encode()?;
        let inventory = self.inventory_with(id)?;
        let mut changes = vec![
            RecordChange::Put(self.index, &inventory),
            RecordChange::Put(&root, &encoded),
        ];
        changes.extend(
            payloads
                .iter()
                .map(|(key, bytes)| RecordChange::Put(key, bytes)),
        );
        changes.extend(
            old.iter()
                .skip(parts.len())
                .map(|key| RecordChange::Delete(key)),
        );
        self.vault.apply(&changes)?;
        Ok(())
    }

    /// Update only dirty parts and metadata, preserving unmodified ciphertexts.
    /// Part count is fixed; structural changes require replace_parts instead.
    pub fn update_parts(
        &mut self,
        id: &str,
        metadata: &[u8],
        updates: &[(usize, &[u8])],
    ) -> Result<()> {
        if metadata.is_empty() || metadata.len() > MAX_MANIFEST {
            return Err(JournalError::Capacity);
        }
        let root = self.record(id)?;
        let raw = self.load(id)?.ok_or(JournalError::Format)?;
        let mut manifest = Manifest::decode(&raw)?.ok_or(JournalError::Format)?;
        manifest.metadata.zeroize();
        manifest.metadata = metadata.to_vec();
        let mut seen = HashSet::new();
        for &(index, bytes) in updates {
            if !seen.insert(index) || index >= manifest.parts.len() {
                return Err(JournalError::Format);
            }
            manifest.parts[index] = descriptor(bytes.len())?;
        }
        // Validate aggregate bytes before allocating copies of dirty payloads.
        let encoded = manifest.encode()?;
        let payloads: Vec<_> = updates
            .iter()
            .map(|(index, bytes)| {
                Ok((
                    self.part_key(id, *index)?,
                    payload(&manifest.parts[*index], bytes),
                ))
            })
            .collect::<Result<_>>()?;
        let mut changes = vec![RecordChange::Put(&root, &encoded)];
        changes.extend(
            payloads
                .iter()
                .map(|(key, bytes)| RecordChange::Put(key, bytes)),
        );
        self.vault.apply(&changes)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn aggregate_capacity_and_future_versions_cannot_reset_old_data() {
        let mut manifest = Manifest {
            version: 1,
            metadata: b"meta".to_vec(),
            parts: vec![Part {
                bytes: MAX_CHECKPOINT,
                revision: [0; REVISION_BYTES],
            }],
        };
        assert!(manifest.encode().is_err());
        manifest.parts.clear();
        manifest.version = 2;
        let mut future = MAGIC.to_vec();
        serde_json::to_writer(&mut future, &manifest).unwrap();
        let temp = tempfile::tempdir().unwrap();
        let mut vault =
            Vault::create(&temp.path().join("future.vault"), b"test-only-future-parts").unwrap();
        let id = "task-00000000000000000000000000000007";
        LocalTaskJournal::new(&mut vault).save(id, &future).unwrap();
        let mut journal = LocalTaskJournal::new(&mut vault);
        assert!(journal.load_parts(id).is_err());
        assert!(journal.save(id, b"must not reset").is_err());
        assert!(journal.replace_parts(id, b"meta", &[b"part"]).is_err());
        assert!(journal.update_parts(id, b"meta", &[]).is_err());
        assert!(journal.remove(&[id.into()]).is_err());
        assert_eq!(
            vault.get(&record(id).unwrap()).unwrap().unwrap().as_slice(),
            future
        );
    }
    #[test]
    fn metadata_reference_remains_readable_when_a_chunk_cannot_resume() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &temp.path().join("reference.vault"),
            b"synthetic-cache-reference",
        )
        .unwrap();
        let id = "task-00000000000000000000000000000007";
        LocalTaskJournal::new(&mut vault)
            .replace_parts(id, b"protected-root", &[b"node-body"])
            .unwrap();
        vault
            .delete(&format!("local-transfer-{id}-part-0"))
            .unwrap();
        let journal = LocalTaskJournal::new(&mut vault);
        match journal.load_metadata(id).unwrap().unwrap() {
            CheckpointMetadata::Partitioned(raw) => assert_eq!(raw.as_slice(), b"protected-root"),
            _ => panic!("expected partitioned metadata"),
        }
        assert!(journal.load_parts(id).is_err());
    }
}
