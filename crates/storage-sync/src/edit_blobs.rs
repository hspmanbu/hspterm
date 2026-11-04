//! Device-local, encrypted, bounded chunks for large editor working copies.
//! A completed body and its owning draft reference can be published atomically.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

pub const CHUNK_BYTES: usize = 1024 * 1024;
const MAX_CHUNKS: u32 = 1024 * 1024;
pub const MAX_BODY_BYTES: u64 = MAX_CHUNKS as u64 * CHUNK_BYTES as u64;
const MAX_BLOBS: usize = 512;
const INDEX: &str = "local-edit-blob-index-v1";
const PREFIX: &str = "local-edit-blob-";

#[derive(thiserror::Error, Debug)]
pub enum BlobError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("分块编辑正文格式未知或损坏；原数据保留")]
    Format,
    #[error("分块正文版本已改变，未覆盖较新数据")]
    Changed,
    #[error("分块正文超过容量或块大小限制，未截断")]
    Capacity,
    #[error("分块正文尚未完整，不能发布或读取")]
    Incomplete,
    #[error("清理已发布正文必须同时验证并更新所属草稿引用")]
    Referenced,
}
type Result<T> = std::result::Result<T, BlobError>;

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum State {
    Staging,
    Complete,
    Deleting,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    version: u32,
    id: String,
    owner: String,
    base_revision: u64,
    previous: Option<String>,
    state: State,
    expected_bytes: Option<u64>,
    bytes: u64,
    chunks: u32,
    removed: u32,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Inventory {
    version: u32,
    ids: Vec<String>,
}

/// Contains no body bytes. The counter is updated only after the chunk commits.
#[derive(Clone)]
pub struct BlobTicket {
    header: Header,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlobInfo {
    pub id: String,
    pub owner: String,
    pub base_revision: u64,
    pub bytes: u64,
    pub chunks: u32,
    /// Local chunks are finalized; this is NOT a remote save acknowledgement.
    pub complete: bool,
    pub deleting: bool,
}

impl BlobTicket {
    pub fn owner(&self) -> &str {
        &self.header.owner
    }
    pub fn base_revision(&self) -> u64 {
        self.header.base_revision
    }
    pub fn id(&self) -> &str {
        &self.header.id
    }
    pub fn bytes(&self) -> u64 {
        self.header.bytes
    }
}
impl Header {
    fn info(&self) -> BlobInfo {
        BlobInfo {
            id: self.id.clone(),
            owner: self.owner.clone(),
            base_revision: self.base_revision,
            bytes: self.bytes,
            chunks: self.chunks,
            complete: self.state == State::Complete,
            deleting: self.state == State::Deleting,
        }
    }
    fn validate(&self, id: &str) -> Result<()> {
        if self.version != 1
            || self.id != id
            || !valid(id, "blob-")
            || !valid(&self.owner, "edit-")
            || self.base_revision == 0
            || self
                .previous
                .as_ref()
                .is_some_and(|v| !valid(v, "blob-") || v == id)
            || self.chunks > MAX_CHUNKS
            || self.removed > self.chunks
            || (self.removed != 0 && self.state != State::Deleting)
            || self.bytes > u64::from(self.chunks) * CHUNK_BYTES as u64
            || (self.chunks != 0 && self.bytes <= u64::from(self.chunks - 1) * CHUNK_BYTES as u64)
            || self
                .expected_bytes
                .is_some_and(|n| n > max_bytes() || self.bytes > n)
            || (self.state == State::Complete && self.expected_bytes != Some(self.bytes))
        {
            return Err(BlobError::Format);
        }
        Ok(())
    }
}
fn max_bytes() -> u64 {
    MAX_BODY_BYTES
}
fn valid(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix)
        .is_some_and(|s| s.len() == 32 && s.bytes().all(|b| b.is_ascii_hexdigit()))
}
fn meta(id: &str) -> Result<String> {
    if !valid(id, "blob-") {
        return Err(BlobError::Format);
    }
    Ok(format!("{PREFIX}meta-{id}"))
}
fn chunk(id: &str, index: u32) -> String {
    format!("{PREFIX}chunk-{id}-{index:08x}")
}
fn json<T: Serialize>(value: &T) -> Result<Zeroizing<Vec<u8>>> {
    Ok(Zeroizing::new(
        serde_json::to_vec(value).map_err(|_| BlobError::Format)?,
    ))
}
fn condition(raw: &Option<Zeroizing<Vec<u8>>>) -> Option<&[u8]> {
    raw.as_deref().map(Vec::as_slice)
}

pub struct EditBlobs<'a> {
    vault: &'a mut Vault,
}
impl<'a> EditBlobs<'a> {
    pub fn new(vault: &'a mut Vault) -> Self {
        Self { vault }
    }
    fn reference_key(owner: &str) -> String {
        format!("{PREFIX}owner-{owner}")
    }
    fn reference(&self, owner: &str) -> Result<Option<String>> {
        if !valid(owner, "edit-") {
            return Err(BlobError::Format);
        }
        self.vault
            .get_bounded(&Self::reference_key(owner), 64)?
            .map(|raw| {
                let id = std::str::from_utf8(&raw).map_err(|_| BlobError::Format)?;
                if !valid(id, "blob-") {
                    return Err(BlobError::Format);
                }
                Ok(id.to_owned())
            })
            .transpose()
    }
    /// This module owns the sole authoritative body pointer. Draft metadata
    /// stores the owner ID, not a competing independently mutable blob pointer.
    pub fn open_owner(&self, owner: &str) -> Result<BlobInfo> {
        let id = self.reference(owner)?.ok_or(BlobError::Incomplete)?;
        let info = self.open(&id)?;
        if info.owner != owner {
            return Err(BlobError::Format);
        }
        Ok(info)
    }
    fn inventory(&self) -> Result<(Inventory, Option<Zeroizing<Vec<u8>>>)> {
        let raw = self.vault.get_bounded(INDEX, 64 * 1024)?;
        let index: Inventory = match raw.as_deref() {
            None => Inventory {
                version: 1,
                ids: Vec::new(),
            },
            Some(bytes) if bytes.len() <= 64 * 1024 => {
                serde_json::from_slice(bytes).map_err(|_| BlobError::Format)?
            }
            Some(_) => return Err(BlobError::Capacity),
        };
        let mut seen = std::collections::HashSet::new();
        if index.version != 1
            || index.ids.len() > MAX_BLOBS
            || index
                .ids
                .iter()
                .any(|id| !valid(id, "blob-") || !seen.insert(id))
        {
            return Err(BlobError::Format);
        }
        Ok((index, raw))
    }
    fn header(&self, id: &str) -> Result<(Header, Zeroizing<Vec<u8>>)> {
        let raw = self
            .vault
            .get_bounded(&meta(id)?, 4096)?
            .ok_or(BlobError::Format)?;
        if raw.len() > 4096 {
            return Err(BlobError::Capacity);
        }
        let header: Header = serde_json::from_slice(&raw).map_err(|_| BlobError::Format)?;
        header.validate(id)?;
        Ok((header, raw))
    }
    /// Metadata only; does not decrypt all bodies or perform network requests.
    pub fn list(&self, owner: &str) -> Result<Vec<BlobInfo>> {
        if !valid(owner, "edit-") {
            return Err(BlobError::Format);
        }
        let (index, _) = self.inventory()?;
        let mut rows = Vec::new();
        for id in index.ids {
            let (header, _) = self.header(&id)?;
            if header.owner == owner {
                rows.push(header.info());
            }
        }
        Ok(rows)
    }
    /// Discover interrupted reclamations even after the owning draft was
    /// removed. This only reads bounded metadata; it never retires live bodies.
    pub fn pending_reclamation(&self) -> Result<Vec<BlobInfo>> {
        let (index, _) = self.inventory()?;
        let mut rows = Vec::new();
        for id in index.ids {
            let (header, _) = self.header(&id)?;
            if header.state == State::Deleting {
                rows.push(header.info());
            }
        }
        Ok(rows)
    }
    pub fn begin(
        &mut self,
        owner: &str,
        base_revision: u64,
        expected_bytes: Option<u64>,
    ) -> Result<BlobTicket> {
        if !valid(owner, "edit-") || base_revision == 0 {
            return Err(BlobError::Format);
        }
        if expected_bytes.is_some_and(|n| n > max_bytes()) {
            return Err(BlobError::Capacity);
        }
        let (mut index, old_index) = self.inventory()?;
        if index.ids.len() >= MAX_BLOBS {
            return Err(BlobError::Capacity);
        }
        let id = format!("blob-{:032x}", rand::random::<u128>());
        let previous = self.reference(owner)?;
        if let Some(previous) = &previous
            && self.open(previous)?.owner != owner
        {
            return Err(BlobError::Format);
        }
        let reference_key = Self::reference_key(owner);
        let header = Header {
            version: 1,
            id: id.clone(),
            owner: owner.into(),
            base_revision,
            previous,
            state: State::Staging,
            expected_bytes,
            bytes: 0,
            chunks: 0,
            removed: 0,
        };
        index.ids.push(id.clone());
        let index_bytes = json(&index)?;
        let header_bytes = json(&header)?;
        let key = meta(&id)?;
        if !self.vault.apply_checked(
            &[
                (INDEX, condition(&old_index)),
                (&key, None),
                (
                    &reference_key,
                    header.previous.as_deref().map(str::as_bytes),
                ),
            ],
            &[
                RecordChange::Put(INDEX, &index_bytes),
                RecordChange::Put(&key, &header_bytes),
            ],
        )? {
            return Err(BlobError::Changed);
        }
        Ok(BlobTicket { header })
    }
    /// Recover only committed local counters. The caller must verify its source
    /// context before continuing; this never resumes an SSH connection.
    pub fn resume(&self, id: &str) -> Result<BlobTicket> {
        let (header, _) = self.header(id)?;
        if header.state != State::Staging {
            return Err(BlobError::Changed);
        }
        Ok(BlobTicket { header })
    }
    fn current(&self, ticket: &BlobTicket) -> Result<(Header, Zeroizing<Vec<u8>>)> {
        let (header, raw) = self.header(ticket.id())?;
        if header != ticket.header || header.state != State::Staging {
            return Err(BlobError::Changed);
        }
        Ok((header, raw))
    }
    /// Fill all chunks except the final one. At most one MiB is encrypted here.
    pub fn append(&mut self, ticket: &mut BlobTicket, bytes: &[u8]) -> Result<()> {
        if bytes.is_empty() || bytes.len() > CHUNK_BYTES {
            return Err(BlobError::Capacity);
        }
        let (mut header, old) = self.current(ticket)?;
        if header.chunks == MAX_CHUNKS || !header.bytes.is_multiple_of(CHUNK_BYTES as u64) {
            return Err(BlobError::Capacity);
        }
        header.bytes = header
            .bytes
            .checked_add(bytes.len() as u64)
            .ok_or(BlobError::Capacity)?;
        if header.expected_bytes.is_some_and(|n| header.bytes > n) {
            return Err(BlobError::Capacity);
        }
        let chunk_key = chunk(&header.id, header.chunks);
        header.chunks += 1;
        let key = meta(&header.id)?;
        let next = json(&header)?;
        if !self.vault.apply_checked(
            &[(&key, Some(&old)), (&chunk_key, None)],
            &[
                RecordChange::Put(&chunk_key, bytes),
                RecordChange::Put(&key, &next),
            ],
        )? {
            return Err(BlobError::Changed);
        }
        ticket.header = header;
        Ok(())
    }
    fn extras(expected: &[(&str, Option<&[u8]>)], changes: &[RecordChange<'_>]) -> Result<()> {
        if expected.iter().any(|(id, _)| id.starts_with(PREFIX))
            || changes.iter().any(|c| match c {
                RecordChange::Put(id, _) | RecordChange::Delete(id) => id.starts_with(PREFIX),
            })
        {
            return Err(BlobError::Format);
        }
        Ok(())
    }
    fn commit_header(
        &mut self,
        header: &Header,
        old: &[u8],
        expected: &[(&str, Option<&[u8]>)],
        changes: &[RecordChange<'_>],
    ) -> Result<()> {
        Self::extras(expected, changes)?;
        let key = meta(&header.id)?;
        let raw = json(header)?;
        let mut checks = vec![(key.as_str(), Some(old))];
        checks.extend_from_slice(expected);
        let mut writes = vec![RecordChange::Put(key.as_str(), raw.as_slice())];
        let reference_key = Self::reference_key(&header.owner);
        let current_reference;
        let next_reference;
        let previous_reference = if header.state == State::Complete {
            next_reference = Some(header.id.as_str());
            header.previous.as_deref()
        } else {
            current_reference = self.reference(&header.owner)?;
            if current_reference.as_deref() == Some(header.id.as_str()) {
                let owner = format!("local-edit-meta-{}", header.owner);
                if !expected
                    .iter()
                    .any(|(id, value)| *id == owner && value.is_some())
                    || !changes
                        .iter()
                        .any(|c| matches!(c, RecordChange::Delete(id) if *id == owner))
                {
                    return Err(BlobError::Referenced);
                }
                next_reference = None;
            } else {
                next_reference = current_reference.as_deref();
            }
            current_reference.as_deref()
        };
        checks.push((&reference_key, previous_reference.map(str::as_bytes)));
        match next_reference {
            Some(id) => writes.push(RecordChange::Put(&reference_key, id.as_bytes())),
            None => writes.push(RecordChange::Delete(&reference_key)),
        }
        writes.extend(changes.iter().map(|c| match c {
            RecordChange::Put(id, bytes) => RecordChange::Put(id, bytes),
            RecordChange::Delete(id) => RecordChange::Delete(id),
        }));
        if !self.vault.apply_checked(&checks, &writes)? {
            return Err(BlobError::Changed);
        }
        Ok(())
    }
    /// Call only after complete source bytes/EOF and close acknowledgement.
    /// Owning draft pointer changes belong in this transaction, not a later put.
    pub fn finish_with(
        &mut self,
        ticket: &BlobTicket,
        expected: &[(&str, Option<&[u8]>)],
        changes: &[RecordChange<'_>],
    ) -> Result<BlobInfo> {
        let (mut header, old) = self.current(ticket)?;
        let owner = format!("local-edit-meta-{}", header.owner);
        if !expected.iter().any(|(id, _)| *id == owner)
            || !changes
                .iter()
                .any(|c| matches!(c, RecordChange::Put(id, _) if *id == owner))
        {
            return Err(BlobError::Referenced);
        }
        if header.expected_bytes.is_some_and(|n| n != header.bytes) {
            return Err(BlobError::Incomplete);
        }
        header.expected_bytes = Some(header.bytes);
        header.state = State::Complete;
        self.commit_header(&header, &old, expected, changes)?;
        Ok(header.info())
    }
    pub fn open(&self, id: &str) -> Result<BlobInfo> {
        let (header, _) = self.header(id)?;
        if header.state != State::Complete {
            return Err(BlobError::Incomplete);
        }
        Ok(header.info())
    }
    pub fn read_chunk(&self, info: &BlobInfo, index: u32) -> Result<Zeroizing<Vec<u8>>> {
        let actual = self.open(&info.id)?;
        if actual != *info || index >= info.chunks {
            return Err(BlobError::Changed);
        }
        let raw = self
            .vault
            .get_bounded(&chunk(&info.id, index), CHUNK_BYTES)?
            .ok_or(BlobError::Format)?;
        let expected = if index + 1 == info.chunks {
            info.bytes - u64::from(index) * CHUNK_BYTES as u64
        } else {
            CHUNK_BYTES as u64
        };
        if raw.len() as u64 != expected {
            return Err(BlobError::Format);
        }
        Ok(raw)
    }
    /// Read a committed staging block solely to verify a second local capture.
    /// This does not publish the incomplete body or expose it as a ready draft.
    pub fn read_staging_chunk(
        &self,
        ticket: &BlobTicket,
        index: u32,
    ) -> Result<Zeroizing<Vec<u8>>> {
        let (header, _) = self.header(ticket.id())?;
        if header != ticket.header || header.state != State::Staging {
            return Err(BlobError::Changed);
        }
        if index >= header.chunks {
            return Err(BlobError::Incomplete);
        }
        let expected = if index + 1 == header.chunks {
            (header.bytes - u64::from(index) * CHUNK_BYTES as u64) as usize
        } else {
            CHUNK_BYTES
        };
        let bytes = self
            .vault
            .get_bounded(&chunk(ticket.id(), index), CHUNK_BYTES)?
            .ok_or(BlobError::Format)?;
        if bytes.len() != expected {
            return Err(BlobError::Format);
        }
        Ok(bytes)
    }
    pub fn abort(&mut self, ticket: &BlobTicket) -> Result<()> {
        let (mut header, raw) = self.current(ticket)?;
        header.state = State::Deleting;
        self.commit_header(&header, &raw, &[], &[])
    }
    /// A published body cannot be retired without checked replacement/removal
    /// of its owning metadata. An in-flight reader must be drained by its owner.
    pub fn retire_with(
        &mut self,
        info: &BlobInfo,
        expected: &[(&str, Option<&[u8]>)],
        changes: &[RecordChange<'_>],
    ) -> Result<()> {
        let (mut header, old) = self.header(&info.id)?;
        if header.info() != *info || header.state != State::Complete {
            return Err(BlobError::Changed);
        }
        header.state = State::Deleting;
        self.commit_header(&header, &old, expected, changes)
    }
    /// Delete at most 256 chunks. A crash resumes from the committed counter;
    /// the inventory entry remains until the last atomic header/index removal.
    pub fn reclaim_step(&mut self, id: &str, limit: u32) -> Result<bool> {
        if limit == 0 || limit > 256 {
            return Err(BlobError::Capacity);
        }
        let (mut header, raw) = self.header(id)?;
        if header.state != State::Deleting {
            return Err(BlobError::Referenced);
        }
        let reference_key = Self::reference_key(&header.owner);
        let reference = self.reference(&header.owner)?;
        if reference.as_deref() == Some(id) {
            return Err(BlobError::Referenced);
        }
        let key = meta(id)?;
        let mut checks = vec![
            (key.as_str(), Some(raw.as_slice())),
            (
                reference_key.as_str(),
                reference.as_deref().map(str::as_bytes),
            ),
        ];
        let end = header.removed.saturating_add(limit).min(header.chunks);
        let keys = (header.removed..end)
            .map(|i| chunk(id, i))
            .collect::<Vec<_>>();
        let mut writes = keys
            .iter()
            .map(|id| RecordChange::Delete(id))
            .collect::<Vec<_>>();
        header.removed = end;
        if end == header.chunks {
            let (mut index, old_index) = self.inventory()?;
            if !index.ids.iter().any(|v| v == id) {
                return Err(BlobError::Format);
            }
            index.ids.retain(|v| v != id);
            let next_index = json(&index)?;
            writes.push(RecordChange::Delete(&key));
            writes.push(RecordChange::Put(INDEX, &next_index));
            checks.push((INDEX, condition(&old_index)));
            if !self.vault.apply_checked(&checks, &writes)? {
                return Err(BlobError::Changed);
            }
            Ok(true)
        } else {
            let next = json(&header)?;
            writes.push(RecordChange::Put(&key, &next));
            if !self.vault.apply_checked(&checks, &writes)? {
                return Err(BlobError::Changed);
            }
            Ok(false)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const OWNER: &str = "edit-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    fn owner_key() -> String {
        format!("local-edit-meta-{OWNER}")
    }
    #[test]
    fn stale_capture_cannot_replace_a_new_body_even_with_current_metadata() {
        let root = tempfile::tempdir().unwrap();
        let mut vault =
            Vault::create(&root.path().join("pointer.vault"), b"test-only-blob-master").unwrap();
        let key = owner_key();
        vault.put(&key, b"base").unwrap();
        let mut store = EditBlobs::new(&mut vault);
        let mut first = store.begin(OWNER, 1, Some(1)).unwrap();
        let mut second = store.begin(OWNER, 1, Some(1)).unwrap();
        store.append(&mut first, b"a").unwrap();
        store.append(&mut second, b"b").unwrap();
        let info = store
            .finish_with(
                &first,
                &[(&key, Some(b"base"))],
                &[RecordChange::Put(&key, first.id().as_bytes())],
            )
            .unwrap();
        assert!(matches!(
            store.finish_with(
                &second,
                &[(&key, Some(first.id().as_bytes()))],
                &[RecordChange::Put(&key, second.id().as_bytes()),]
            ),
            Err(BlobError::Changed)
        ));
        assert_eq!(store.open_owner(OWNER).unwrap(), info);
        assert_eq!(store.read_chunk(&info, 0).unwrap().as_slice(), b"a");
        store.abort(&second).unwrap();
        assert!(store.reclaim_step(second.id(), 1).unwrap());
        assert_eq!(store.open_owner(OWNER).unwrap(), info);
    }
    #[test]
    fn cancelled_staging_and_empty_bodies_reclaim_without_touching_another_reference() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("abort.vault");
        let mut vault = Vault::create(&path, b"test-only-blob-master").unwrap();
        let key = owner_key();
        vault.put(&key, b"base").unwrap();
        let mut store = EditBlobs::new(&mut vault);
        assert!(store.begin(OWNER, 1, Some(u64::MAX)).is_err());
        let mut partial = store.begin(OWNER, 1, Some(3)).unwrap();
        store.append(&mut partial, b"ab").unwrap();
        assert!(store.append(&mut partial, b"c").is_err());
        assert!(matches!(
            store.finish_with(
                &partial,
                &[(&key, Some(b"base"))],
                &[RecordChange::Put(&key, partial.id().as_bytes()),]
            ),
            Err(BlobError::Incomplete)
        ));
        store.abort(&partial).unwrap();
        assert!(store.resume(partial.id()).is_err());
        assert!(store.reclaim_step(partial.id(), 0).is_err());
        assert!(store.reclaim_step(partial.id(), 1).unwrap());
        assert_eq!(store.vault.get(&key).unwrap().unwrap().as_slice(), b"base");
        let empty = store.begin(OWNER, 1, Some(0)).unwrap();
        let info = store
            .finish_with(
                &empty,
                &[(&key, Some(b"base"))],
                &[RecordChange::Put(&key, empty.id().as_bytes())],
            )
            .unwrap();
        assert_eq!(info.bytes, 0);
        assert_eq!(info.chunks, 0);
        assert!(store.read_chunk(&info, 0).is_err());
        store
            .retire_with(
                &info,
                &[(&key, Some(empty.id().as_bytes()))],
                &[RecordChange::Delete(&key)],
            )
            .unwrap();
        assert!(store.reclaim_step(&info.id, 1).unwrap());
        assert!(store.list(OWNER).unwrap().is_empty());
    }

    #[test]
    fn large_body_reopens_staging_and_publishes_only_with_complete_atomic_reference() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("large.vault");
        let mut vault = Vault::create(&path, b"test-only-blob-master").unwrap();
        let key = owner_key();
        vault.put(&key, b"base").unwrap();
        let mut store = EditBlobs::new(&mut vault);
        let tail = b"local-secret-tail";
        let mut ticket = store
            .begin(OWNER, 1, Some(17 * CHUNK_BYTES as u64 + tail.len() as u64))
            .unwrap();
        let id = ticket.id().to_string();
        let mut block = Zeroizing::new(vec![b'X'; CHUNK_BYTES]);
        let mut stale = ticket.clone();
        block[0] = 0;
        store.append(&mut ticket, &block).unwrap();
        assert_eq!(
            store.read_staging_chunk(&ticket, 0).unwrap().len(),
            CHUNK_BYTES
        );
        assert!(matches!(
            store.read_staging_chunk(&stale, 0),
            Err(BlobError::Changed)
        ));
        assert!(store.read_staging_chunk(&ticket, 1).is_err());
        assert!(matches!(
            store.append(&mut stale, &block),
            Err(BlobError::Changed)
        ));
        assert!(matches!(store.open(&id), Err(BlobError::Incomplete)));
        assert!(matches!(
            store.finish_with(
                &ticket,
                &[(&key, Some(b"base"))],
                &[RecordChange::Put(&key, id.as_bytes()),]
            ),
            Err(BlobError::Incomplete)
        ));
        drop(vault);
        let mut vault = Vault::open(&path, b"test-only-blob-master").unwrap();
        let mut store = EditBlobs::new(&mut vault);
        let mut ticket = store.resume(&id).unwrap();
        assert_eq!(ticket.bytes(), CHUNK_BYTES as u64);
        assert!(!store.list(OWNER).unwrap().first().unwrap().complete);
        for n in 1..17 {
            block[0] = n;
            store.append(&mut ticket, &block).unwrap();
        }
        store.append(&mut ticket, tail).unwrap();
        assert!(matches!(
            store.finish_with(&ticket, &[], &[]),
            Err(BlobError::Referenced)
        ));
        store.vault.put(&key, b"newer").unwrap();
        assert!(matches!(
            store.finish_with(
                &ticket,
                &[(&key, Some(b"base"))],
                &[RecordChange::Put(&key, id.as_bytes()),]
            ),
            Err(BlobError::Changed)
        ));
        assert!(store.open(&id).is_err());
        let info = store
            .finish_with(
                &ticket,
                &[(&key, Some(b"newer"))],
                &[RecordChange::Put(&key, id.as_bytes())],
            )
            .unwrap();
        assert!(info.complete);
        assert!(info.bytes > crate::local_edits::MAX_TEXT_BYTES as u64);
        assert_eq!(
            store.vault.get(&key).unwrap().unwrap().as_slice(),
            id.as_bytes()
        );
        for n in 0..17 {
            let read = store.read_chunk(&info, n).unwrap();
            assert_eq!(read.len(), CHUNK_BYTES);
            assert_eq!(read[0], n as u8);
            assert!(read[1..].iter().all(|b| *b == b'X'));
        }
        assert_eq!(store.read_chunk(&info, 17).unwrap().as_slice(), tail);
        assert!(store.read_chunk(&info, 18).is_err());
        assert!(store.append(&mut ticket, tail).is_err());
        assert!(store.reclaim_step(&id, 1).is_err());
        drop(vault);
        let encrypted = std::fs::read(&path).unwrap();
        assert!(!encrypted.windows(tail.len()).any(|w| w == tail));
        assert!(!encrypted.windows(64).any(|w| w.iter().all(|b| *b == b'X')));
    }
    #[test]
    fn reference_retirement_and_chunk_reclamation_resume_after_interruption() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("retire.vault");
        let mut vault = Vault::create(&path, b"test-only-blob-master").unwrap();
        let key = owner_key();
        vault.put(&key, b"base").unwrap();
        vault.put("unrelated", b"keep").unwrap();
        let mut store = EditBlobs::new(&mut vault);
        let mut ticket = store.begin(OWNER, 1, None).unwrap();
        let block = Zeroizing::new(vec![42; CHUNK_BYTES]);
        store.append(&mut ticket, &block).unwrap();
        store.append(&mut ticket, &block).unwrap();
        store.append(&mut ticket, b"tail").unwrap();
        let id = ticket.id().to_string();
        let info = store
            .finish_with(
                &ticket,
                &[(&key, Some(b"base"))],
                &[RecordChange::Put(&key, id.as_bytes())],
            )
            .unwrap();
        assert!(store.pending_reclamation().unwrap().is_empty());
        assert!(matches!(
            store.retire_with(&info, &[], &[]),
            Err(BlobError::Referenced)
        ));
        assert!(matches!(
            store.retire_with(
                &info,
                &[(&key, Some(b"stale"))],
                &[RecordChange::Delete(&key)]
            ),
            Err(BlobError::Changed)
        ));
        assert!(store.open(&id).is_ok());
        assert!(
            matches!(
                store.retire_with(
                    &info,
                    &[(&key, Some(id.as_bytes()))],
                    &[RecordChange::Put(&key, id.as_bytes()),]
                ),
                Err(BlobError::Referenced)
            ),
            "metadata-only rewrites must not retire the current body"
        );
        let mut next = store.begin(OWNER, 2, Some(1)).unwrap();
        store.append(&mut next, b"n").unwrap();
        let next_id = next.id().to_owned();
        let next_info = store
            .finish_with(
                &next,
                &[(&key, Some(id.as_bytes()))],
                &[RecordChange::Put(&key, next_id.as_bytes())],
            )
            .unwrap();
        assert_eq!(store.open_owner(OWNER).unwrap(), next_info);
        store.retire_with(&info, &[], &[]).unwrap();
        assert!(store.open(&id).is_err());
        assert!(!store.reclaim_step(&id, 1).unwrap());
        drop(vault);
        let mut vault = Vault::open(&path, b"test-only-blob-master").unwrap();
        let mut store = EditBlobs::new(&mut vault);
        assert!(
            store
                .list(OWNER)
                .unwrap()
                .iter()
                .any(|i| i.id == id && i.deleting)
        );
        assert!(!store.reclaim_step(&id, 1).unwrap());
        assert!(store.reclaim_step(&id, 1).unwrap());
        assert_eq!(store.list(OWNER).unwrap(), vec![next_info.clone()]);
        for n in 0..3 {
            assert!(store.vault.get(&chunk(&id, n)).unwrap().is_none());
        }
        assert_eq!(
            store.vault.get(&key).unwrap().unwrap().as_slice(),
            next_id.as_bytes()
        );
        assert_eq!(
            store.vault.get("unrelated").unwrap().unwrap().as_slice(),
            b"keep"
        );
        store
            .retire_with(
                &next_info,
                &[(&key, Some(next_id.as_bytes()))],
                &[RecordChange::Delete(&key)],
            )
            .unwrap();
        assert!(store.open_owner(OWNER).is_err());
        assert_eq!(store.pending_reclamation().unwrap()[0].id, next_id);
        assert!(store.reclaim_step(&next_id, 1).unwrap());
        assert!(store.pending_reclamation().unwrap().is_empty());
        assert!(store.list(OWNER).unwrap().is_empty());
    }
    #[test]
    fn invalid_chunks_future_formats_and_failed_publication_preserve_original_data() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("format.vault");
        let mut vault = Vault::create(&path, b"test-only-blob-master").unwrap();
        let key = owner_key();
        vault.put(&key, b"base").unwrap();
        let mut store = EditBlobs::new(&mut vault);
        let mut ticket = store.begin(OWNER, 1, Some(1)).unwrap();
        assert!(store.append(&mut ticket, &[]).is_err());
        assert!(
            store
                .append(&mut ticket, &vec![0; CHUNK_BYTES + 1])
                .is_err()
        );
        assert_eq!(ticket.bytes(), 0);
        store.append(&mut ticket, b"a").unwrap();
        let id = ticket.id().to_string();
        assert!(
            store
                .finish_with(
                    &ticket,
                    &[(&key, Some(b"base"))],
                    &[
                        RecordChange::Put(&key, id.as_bytes()),
                        RecordChange::Put("__invalid", b"fail"),
                    ]
                )
                .is_err()
        );
        assert!(store.open(&id).is_err());
        assert_eq!(store.vault.get(&key).unwrap().unwrap().as_slice(), b"base");
        let info = store
            .finish_with(
                &ticket,
                &[(&key, Some(b"base"))],
                &[RecordChange::Put(&key, id.as_bytes())],
            )
            .unwrap();
        store.vault.put(&chunk(&id, 0), b"invalid-size").unwrap();
        assert!(matches!(store.read_chunk(&info, 0), Err(BlobError::Format)));
        let (mut header, _) = store.header(&id).unwrap();
        header.version = 2;
        let future = json(&header).unwrap();
        store.vault.put(&meta(&id).unwrap(), &future).unwrap();
        assert!(store.open(&id).is_err());
        assert!(store.reclaim_step(&id, 1).is_err());
        assert!(store.vault.get(&chunk(&id, 0)).unwrap().is_some());
        store
            .vault
            .put(INDEX, br#"{"version":2,"ids":[]}"#)
            .unwrap();
        assert!(store.begin(OWNER, 1, None).is_err());
        assert_eq!(
            store.vault.get(INDEX).unwrap().unwrap().as_slice(),
            br#"{"version":2,"ids":[]}"#
        );
    }
}
