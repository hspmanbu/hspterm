//! Configuration synchronization protocol, separate from network scheduling.
//! Only allowlisted, canonical configuration units enter an E2E document.
//! No startup/background polling or credential-bearing Debug representations.
pub mod archives;
pub mod drive_files;
pub mod drive_oauth;
pub mod drive_setup;
mod envelope;
mod exchange;
pub mod journal;
mod projection;
pub(super) mod reconciliation;
mod snapshots;
pub use snapshots::SnapshotInfo;
mod references;
pub use references::{ReferenceChoice, ReferenceSelection, ReferenceSide};
pub mod settings;
#[cfg(test)]
mod tests;
pub mod webdav;

use super::{BackupError, Bytes, PreparedRestore, Snapshot, json, restore, slice};
use crate::Vault;
pub use exchange::{Acknowledged, Exchange, ExchangeStep, PendingUpload, RemoteRead};
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, sync::Arc};
use zeroize::{Zeroize, Zeroizing};

pub(super) const LEDGER: &str = "local-cloud-sync-ledger-v1";
const MAX_ITEMS: usize = 24_000;
const MAX_BODY: usize = 16 * 1024 * 1024;
const MAX_PLAIN: usize = 64 * 1024 * 1024;
/// The device-local ledger wraps the serialized document with actor and ETag
/// fields. Revision-history trimming must leave room for that wrapper so an
/// acknowledged document always fits both the envelope and its ledger copy.
const LEDGER_MARGIN: usize = 2048;
pub const MAX_ENCRYPTED_BYTES: usize = MAX_PLAIN + 92;
const MAX_SKEW_MS: u64 = 24 * 60 * 60 * 1000;
type Result<T> = std::result::Result<T, SyncError>;

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("同步格式、版本、集合标识或认证无效；没有应用云端配置")]
    Invalid,
    #[error("同步数据或永久删除标记超过安全容量；两端数据保留")]
    Capacity,
    #[error("原配置库、同步基线或配置已改变；需要重新合并")]
    Changed,
    #[error("同步数据的时间超出可接受范围；请校准设备时钟后重试")]
    Clock,
    #[error("两端修改导致主机分组、跳板或配置引用冲突；需显式解决，未应用或上传")]
    References,
    #[error("更换同步地址或集合需要明确确认；原目标及本机基线未修改")]
    TargetChange,
    #[error("该集合已完成同步，不能只修改本机同步密码；请保留原密码或明确改用新的集合")]
    KeyChange,
    #[error("云端数据集由旧版本标识创建；需在原设备重新保存同步目标迁移后再接入")]
    LegacyCollection,
    #[error("更换服务器或代理时不能把旧认证自动发往新地址，请明确填写新认证或关闭认证")]
    CredentialTarget,
    #[error("Google Drive本机授权缺失或已改变；请重新授权并明确绑定目标")]
    Authorization,
    #[error(transparent)]
    Storage(#[from] crate::StorageError),
}
fn opaque(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn backup_error(error: BackupError) -> SyncError {
    match error {
        BackupError::Storage(e) => SyncError::Storage(e),
        BackupError::Capacity => SyncError::Capacity,
        BackupError::Changed => SyncError::Changed,
        _ => SyncError::References,
    }
}

/// Physical time first; a logical tie-breaker survives a clock moving backward.
/// These are mutation times, not synchronization completion times. The caller
/// must capture allowed configuration changes when they occur.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stamp {
    unix_ms: u64,
    logical: u64,
    actor: String,
}
impl Stamp {
    fn next(previous: Option<&Self>, actor: &str, now: u64) -> Result<Self> {
        if !opaque(actor) || now == 0 || now > u64::MAX - MAX_SKEW_MS {
            return Err(SyncError::Clock);
        }
        let (unix_ms, logical) = match previous {
            Some(old) if old.unix_ms >= now => (
                old.unix_ms,
                old.logical.checked_add(1).ok_or(SyncError::Capacity)?,
            ),
            _ => (now, 0),
        };
        Ok(Self {
            unix_ms,
            logical,
            actor: actor.into(),
        })
    }
    fn validate(&self, now: u64) -> Result<()> {
        if !opaque(&self.actor) || self.unix_ms == 0 || self.logical == u64::MAX {
            return Err(SyncError::Invalid);
        }
        if self.unix_ms > now.saturating_add(MAX_SKEW_MS) {
            return Err(SyncError::Clock);
        }
        Ok(())
    }
}

/// Owned plaintext is never logged or exposed through FRB. Shared copies of
/// already-zeroizing backup records are converted only at the envelope boundary.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Bundle {
    #[serde(deserialize_with = "unique_records")]
    records: BTreeMap<String, Vec<u8>>,
}
fn unique_records<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<BTreeMap<String, Vec<u8>>, D::Error> {
    struct Unique;
    impl<'de> serde::de::Visitor<'de> for Unique {
        type Value = BTreeMap<String, Vec<u8>>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("bounded unique configuration records")
        }
        fn visit_map<A: serde::de::MapAccess<'de>>(
            self,
            mut map: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            // RAII clears all successfully read secrets even on a later decode
            // error. Duplicate keys cannot be silently replaced by serde maps.
            let mut bundle = Bundle {
                records: BTreeMap::new(),
            };
            while let Some(key) = map.next_key::<String>()? {
                if key.len() > 256 || bundle.records.len() >= 5 || bundle.records.contains_key(&key)
                {
                    return Err(serde::de::Error::custom("invalid configuration record key"));
                }
                let bytes = map.next_value::<Vec<u8>>()?;
                bundle.records.insert(key, bytes);
            }
            Ok(std::mem::take(&mut bundle.records))
        }
    }
    deserializer.deserialize_map(Unique)
}
impl Drop for Bundle {
    fn drop(&mut self) {
        for bytes in self.records.values_mut() {
            bytes.zeroize();
        }
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Item {
    id: String,
    stamp: Stamp,
    value: Option<Bundle>,
}
/// No public plaintext serializer. The only wire representation is encrypt().
/// Deleted units keep their timestamps indefinitely; capacity is an error,
/// never an excuse to forget a deletion and revive an offline device's data.
#[derive(Clone)]
pub struct Document {
    version: u32,
    collection: String,
    items: Vec<Item>,
    snapshots: Vec<snapshots::HistoricalSnapshot>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireDocument {
    version: u32,
    collection: String,
    #[serde(deserialize_with = "bounded_items")]
    items: Vec<Item>,
    #[serde(default, deserialize_with = "snapshots::bounded_history")]
    snapshots: Vec<snapshots::HistoricalSnapshot>,
}
fn bounded_items<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<Vec<Item>, D::Error> {
    struct Bounded;
    impl<'de> serde::de::Visitor<'de> for Bounded {
        type Value = Vec<Item>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("a bounded, ordered configuration unit list")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut seq: A,
        ) -> std::result::Result<Vec<Item>, A::Error> {
            let mut items = Vec::<Item>::new();
            while let Some(item) = seq.next_element::<Item>()? {
                if items.len() >= MAX_ITEMS || items.last().is_some_and(|p| p.id >= item.id) {
                    return Err(serde::de::Error::custom(
                        "duplicate, unordered or excessive configuration units",
                    ));
                }
                items.push(item);
            }
            Ok(items)
        }
    }
    d.deserialize_seq(Bounded)
}
impl WireDocument {
    fn into_document(self) -> Document {
        Document {
            version: self.version,
            collection: self.collection,
            items: self.items,
            snapshots: self.snapshots,
        }
    }
}
#[derive(Serialize)]
struct DocumentRef<'a> {
    version: u32,
    collection: &'a str,
    items: &'a [Item],
    #[serde(skip_serializing_if = "<[snapshots::HistoricalSnapshot]>::is_empty")]
    snapshots: &'a [snapshots::HistoricalSnapshot],
}
#[derive(Clone, Default, Serialize)]
pub struct MergeSummary {
    pub conflicts: u32,
    pub incoming_winners: u32,
    pub deleted: u32,
    pub sensitive_changes: u32,
    pub incoming_deletions: u32,
    pub credential_changes: u32,
    /// Units modified on BOTH sides since the shared baseline without an
    /// explicit whole-direction choice yet. Non-empty means publication is
    /// blocked until the user picks one direction for all of them.
    pub diverged: Vec<String>,
}
/// Whole-direction resolution for units changed on both sides since the shared
/// baseline. Unresolved keeps the local side tentatively and reports the unit
/// list; the application must obtain an explicit direction before publishing.
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub enum Divergence {
    #[default]
    Unresolved,
    PreferLocal,
    PreferRemote,
}
impl Document {
    fn serializable(&self) -> DocumentRef<'_> {
        DocumentRef {
            version: if self.snapshots.is_empty() { 1 } else { 2 },
            collection: &self.collection,
            items: &self.items,
            snapshots: &self.snapshots,
        }
    }
    pub fn empty(collection: &str) -> Result<Self> {
        if !opaque(collection) {
            return Err(SyncError::Invalid);
        }
        Ok(Self {
            version: 1,
            collection: collection.into(),
            items: vec![],
            snapshots: vec![],
        })
    }
    pub fn collection(&self) -> &str {
        &self.collection
    }
    fn by_id(&self) -> BTreeMap<&str, &Item> {
        self.items.iter().map(|i| (i.id.as_str(), i)).collect()
    }
    fn validate(&self, now: u64) -> Result<()> {
        if !matches!(self.version, 1 | 2) || !opaque(&self.collection) {
            return Err(SyncError::Invalid);
        }
        self.validate_snapshots(now)?;
        if self.items.len() > MAX_ITEMS {
            return Err(SyncError::Capacity);
        }
        let mut total = 0usize;
        let mut prior: Option<&str> = None;
        for item in &self.items {
            if prior.is_some_and(|id| id >= item.id.as_str()) || !projection::allowed_id(&item.id) {
                return Err(SyncError::Invalid);
            }
            prior = Some(&item.id);
            item.stamp.validate(now)?;
            if let Some(bundle) = &item.value {
                projection::validate_unit(&item.id, bundle)?;
                for (key, bytes) in &bundle.records {
                    total = total
                        .checked_add(key.len())
                        .and_then(|n| n.checked_add(bytes.len()))
                        .ok_or(SyncError::Capacity)?;
                    if total > MAX_BODY {
                        return Err(SyncError::Capacity);
                    }
                }
            } else if matches!(
                item.id.as_str(),
                super::HISTORY | "group-default" | "catalog-order"
            ) {
                return Err(SyncError::Invalid);
            }
        }
        // An empty document is only an unpublished baseline. Any nonempty
        // cloud document must describe a complete, valid formal catalog.
        if !self.items.is_empty() {
            self.projection().snapshot()?;
        }
        Ok(())
    }
    fn projection(&self) -> projection::Projection {
        projection::Projection {
            units: self
                .items
                .iter()
                .filter_map(|i| i.value.as_ref().map(|v| (i.id.clone(), v.clone())))
                .collect(),
        }
    }
    fn encode(&self, now: u64) -> Result<Zeroizing<Vec<u8>>> {
        self.validate(now)?;
        let bytes = Zeroizing::new(
            serde_json::to_vec(&self.serializable()).map_err(|_| SyncError::Invalid)?,
        );
        if bytes.len() > MAX_PLAIN {
            return Err(SyncError::Capacity);
        }
        Ok(bytes)
    }
    fn decode(bytes: &[u8], collection: &str, now: u64) -> Result<Self> {
        if bytes.len() > MAX_PLAIN {
            return Err(SyncError::Capacity);
        }
        let document = serde_json::from_slice::<WireDocument>(bytes)
            .map_err(|_| SyncError::Invalid)?
            .into_document();
        if document.collection != collection {
            return Err(SyncError::Invalid);
        }
        document.validate(now)?;
        Ok(document)
    }
    /// Capture a local mutation against the LAST LOCALLY APPLIED baseline,
    /// never against a just-downloaded, unapplied document. Otherwise an offline
    /// device could mistake unseen remote additions for local deletions.
    pub fn capture(&self, vault: &Vault, actor: &str, now: u64) -> Result<Self> {
        self.validate(now)?;
        let (_, journal) = journal::load(vault, now)?;
        if journal.as_ref().is_some_and(|j| j.actor != actor) {
            return Err(SyncError::Changed);
        }
        let local = projection::Projection::capture(vault)?;
        let before = self.by_id();
        // A merged order preference may omit independently added hosts or
        // retain deleted IDs. Its effective order is completed deterministically
        // by the catalog builder. That normalization is not a fresh user edit.
        let effective = if self.items.is_empty() {
            None
        } else {
            Some(projection::Projection::from_snapshot(
                &self.projection().snapshot()?,
            )?)
        };
        let ids: std::collections::BTreeSet<_> = before
            .keys()
            .copied()
            .chain(local.units.keys().map(String::as_str))
            .collect();
        let latest = self.items.iter().map(|i| &i.stamp).max();
        let mut tick = None;
        let mut items = Vec::with_capacity(ids.len());
        for id in ids {
            let value = local.units.get(id);
            if let Some(old) = before.get(id)
                && (old.value.as_ref() == value
                    || id == "catalog-order"
                        && effective.as_ref().and_then(|p| p.units.get(id)) == value)
            {
                items.push((**old).clone());
                continue;
            }
            if id == super::HISTORY && value.is_none() {
                return Err(SyncError::Changed);
            }
            let stamp = if let Some(journal) = &journal {
                journal.stamp(id)?
            } else {
                if tick.is_none() {
                    tick = Some(Stamp::next(latest, actor, now)?);
                }
                tick.clone().expect("mutation allocated stamp")
            };
            items.push(Item {
                id: id.into(),
                stamp,
                value: value.cloned(),
            });
        }
        let mut next = Self {
            version: 1,
            collection: self.collection.clone(),
            items,
            snapshots: self.snapshots.clone(),
        };
        // Local units may have grown since the baseline stored its revision
        // history, and a first publication (remote object absent) never runs
        // retain_previous: trim here so it still fits the envelope.
        next.trim_revisions_to_budget();
        next.validate(now)?;
        Ok(next)
    }
    /// Three-way merge: `self` is the current local document (L), `base` is
    /// the last locally applied baseline, `remote` is the freshest cloud copy
    /// (R). Units changed on one side only still merge automatically (pull the
    /// cloud change or push the local change); units changed on BOTH sides
    /// are never auto-resolved by timestamp — they are reported through
    /// `summary.diverged` and keep the local side tentatively until the caller
    /// re-merges with an explicit `Divergence` direction. Command history
    /// keeps its clear-epoch CRDT union regardless of timestamps.
    pub fn merge(&self, base: &Self, remote: &Self, now: u64) -> Result<(Self, MergeSummary)> {
        let (merged, summary) = self.merge_candidate(base, remote, now, Divergence::Unresolved)?;
        merged.validate(now)?;
        Ok((merged, summary))
    }
    // Only the bounded original-source reference resolver may inspect this
    // intermediate state. It is never encrypted, published or applied before
    // full validation succeeds.
    fn merge_candidate(
        &self,
        base: &Self,
        remote: &Self,
        now: u64,
        divergence: Divergence,
    ) -> Result<(Self, MergeSummary)> {
        self.validate(now)?;
        remote.validate(now)?;
        base.validate(now)?;
        if self.collection != remote.collection || base.collection != self.collection {
            return Err(SyncError::Invalid);
        }
        let a = self.by_id();
        let b = remote.by_id();
        let c = base.by_id();
        let ids: std::collections::BTreeSet<_> = a.keys().chain(b.keys()).copied().collect();
        let mut summary = MergeSummary::default();
        let mut items = Vec::with_capacity(ids.len());
        for id in ids {
            let left = a.get(id).copied();
            let right = b.get(id).copied();
            let common = c.get(id).copied();
            let chosen = if let (Some(a), Some(b)) = (left, right)
                && id == super::HISTORY
            {
                let x = projection::history(a)?;
                let y = projection::history(b)?;
                let merged = crate::command_history::merge_sync_payload(x, y)
                    .map_err(|_| SyncError::Invalid)?;
                let mut item = if a.stamp >= b.stamp {
                    a.clone()
                } else {
                    b.clone()
                };
                item.value = Some(Bundle {
                    records: BTreeMap::from([(super::HISTORY.into(), merged.to_vec())]),
                });
                item
            } else if id == "sftp-bookmarks-v1" {
                let (value, conflict) = reconciliation::merge_bookmarks(
                    left.and_then(|i| i.value.as_ref()),
                    right.and_then(|i| i.value.as_ref()),
                    common.and_then(|i| i.value.as_ref()),
                    divergence,
                )?;
                if conflict {
                    summary.conflicts += 1;
                    if divergence == Divergence::Unresolved {
                        summary.diverged.push(id.into());
                    }
                }
                let stamp = left
                    .into_iter()
                    .chain(right)
                    .map(|i| &i.stamp)
                    .max()
                    .ok_or(SyncError::Invalid)?
                    .clone();
                Item {
                    id: id.into(),
                    stamp,
                    value,
                }
            } else {
                match (left, right) {
                    (Some(a), Some(b)) => {
                        if a.stamp == b.stamp && a.value != b.value {
                            return Err(SyncError::Invalid);
                        }
                        if a.value == b.value {
                            // Converged identical content keeps the later
                            // mutation stamp for future comparisons.
                            if b.stamp > a.stamp {
                                b.clone()
                            } else {
                                a.clone()
                            }
                        } else {
                            let base_value = common.and_then(|i| i.value.as_ref());
                            if a.value.as_ref() == base_value {
                                // L unchanged since the baseline: pull R.
                                b.clone()
                            } else if b.value.as_ref() == base_value {
                                // R unchanged since the baseline: push L.
                                a.clone()
                            } else {
                                // Both sides changed the same unit: no
                                // automatic timestamp winner. Report it and
                                // keep the chosen whole direction.
                                summary.conflicts += 1;
                                if divergence == Divergence::Unresolved {
                                    summary.diverged.push((*id).into());
                                }
                                match divergence {
                                    Divergence::PreferRemote => b.clone(),
                                    _ => a.clone(),
                                }
                            }
                        }
                    }
                    (Some(a), None) => a.clone(),
                    (None, Some(b)) => b.clone(),
                    (None, None) => unreachable!("union contains only present keys"),
                }
            };
            let left_value = left.and_then(|i| i.value.as_ref());
            if chosen.value.as_ref() != left_value {
                summary.incoming_winners += 1;
                if projection::sensitive(id) {
                    summary.sensitive_changes += 1;
                }
            }
            if chosen.value.is_none() {
                summary.deleted += 1;
                if left.is_some_and(|i| i.value.is_some()) {
                    summary.incoming_deletions += 1;
                }
            }
            if projection::sensitive(id)
                && id != super::HISTORY
                && chosen.value.as_ref() != left_value
                && (chosen.value.is_some() || left_value.is_some())
            {
                summary.credential_changes += 1;
            }
            items.push(chosen);
        }
        let merged = Self {
            version: 1,
            collection: self.collection.clone(),
            items,
            snapshots: remote.snapshots.clone(),
        };
        Ok((merged, summary))
    }
    pub fn encrypt(&self, password: &[u8], now: u64) -> Result<Vec<u8>> {
        envelope::seal(&self.encode(now)?, password, &self.collection)
    }
    pub fn decrypt(bytes: &[u8], password: &[u8], collection: &str, now: u64) -> Result<Self> {
        Self::decode(
            &envelope::open(bytes, password, collection)?,
            collection,
            now,
        )
    }
    /// Opaque dataset identifier in the stored object's plaintext header; no
    /// key derivation runs. `None` for absent/garbage headers.
    pub fn header_collection(bytes: &[u8]) -> Option<String> {
        envelope::header_collection(bytes)
    }
    /// Decrypt a first-contact object whose header carries a DIFFERENT
    /// collection than this device expects, using the header's own identifier.
    /// Success proves the password matches the dataset's creator while the
    /// identifier predates derivation (manual/random collection era); the
    /// document comes back still addressed under that legacy identifier.
    pub fn decrypt_legacy(bytes: &[u8], password: &[u8], now: u64) -> Result<Self> {
        let (plain, collection) = envelope::open_legacy(bytes, password)?;
        Self::decode(&plain, &collection, now)
    }
    /// Same items, addressed under this device's expected collection. Only a
    /// caller that just proved the password (decrypt_legacy) may adopt: the
    /// next conditional publication rewrites the object under the derived
    /// identifier, migrating the dataset without deleting any archive.
    fn rekey(&self, collection: &str) -> Result<Self> {
        if !opaque(collection) || !opaque(&self.collection) {
            return Err(SyncError::Invalid);
        }
        Ok(Self {
            version: 1,
            collection: collection.into(),
            items: self.items.clone(),
            snapshots: self.snapshots.clone(),
        })
    }
}

/// Strong ETag only: a weak validator cannot be used for If-Match publication.
/// Provider HTTP implementations must disable redirects and never log this
/// opaque server value, credentials, URLs or response bodies.
#[derive(Clone, PartialEq, Eq)]
pub struct EntityTag(String);
impl EntityTag {
    pub fn parse(value: &str) -> Result<Self> {
        let bytes = value.as_bytes();
        if bytes.len() < 2
            || bytes.len() > 1024
            || bytes[0] != b'"'
            || bytes[bytes.len() - 1] != b'"'
            || !bytes[1..bytes.len() - 1]
                .iter()
                .all(|b| *b == 0x21 || (0x23..=0x7e).contains(b) || *b >= 0x80)
        {
            return Err(SyncError::Invalid);
        }
        Ok(Self(value.into()))
    }
    pub fn header_value(&self) -> &str {
        &self.0
    }
}

/// Absence is only an authenticated successful 404, not a timeout, denied
/// request, missing ETag or decoding failure. Never perform an unconditional PUT.
#[derive(Clone)]
pub enum PublicationCondition {
    CreateOnly,
    Match(EntityTag),
}

/// Device-local encrypted baseline. It must be published atomically with the
/// matching configuration; it is excluded from complete backups and cloud data.
pub struct Baseline {
    prior: Option<Bytes>,
    scope: String,
    document: Document,
    actor: String,
    etag: Option<EntityTag>,
}
pub struct LocalProposal {
    operation: u128,
    scope: String,
    source_revision: String,
    document: Document,
    journal: Option<Bytes>,
    settings: settings::Checkpoint,
    actor: String,
}
impl LocalProposal {
    pub fn document(&self) -> &Document {
        &self.document
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Ledger {
    version: u32,
    actor: String,
    etag: Option<String>,
    document: WireDocument,
}
#[derive(Serialize)]
struct LedgerRef<'a> {
    version: u32,
    actor: &'a str,
    etag: Option<&'a str>,
    document: DocumentRef<'a>,
}
impl Baseline {
    pub fn ensure_current(&self, vault: &Vault, proposal: &LocalProposal, now: u64) -> Result<()> {
        if vault.instance_id() != self.scope
            || proposal.scope != self.scope
            || vault
                .get_bounded(LEDGER, MAX_PLAIN)?
                .as_deref()
                .map(Vec::as_slice)
                != self.prior.as_ref().map(slice)
            || journal::load(vault, now)?.0 != proposal.journal
            || settings::checkpoint(vault)? != proposal.settings
            || Snapshot::capture_kind(vault, false)
                .map_err(backup_error)?
                .revision(vault)
                != proposal.source_revision
        {
            return Err(SyncError::Changed);
        }
        Ok(())
    }
    pub fn prepare_acknowledged(
        &self,
        vault: &Vault,
        proposal: &LocalProposal,
        acknowledged: &Acknowledged,
        now: u64,
    ) -> Result<ApplyPlan> {
        if acknowledged.operation != proposal.operation {
            return Err(SyncError::Changed);
        }
        self.prepare_apply(
            vault,
            proposal,
            &acknowledged.document,
            Some(acknowledged.etag.clone()),
            now,
        )
    }
    pub fn document(&self) -> &Document {
        &self.document
    }
    pub fn etag(&self) -> Option<&EntityTag> {
        self.etag.as_ref()
    }
    pub fn capture_local(&self, vault: &Vault, now: u64) -> Result<LocalProposal> {
        if vault.instance_id() != self.scope
            || vault
                .get_bounded(LEDGER, MAX_PLAIN)?
                .as_deref()
                .map(Vec::as_slice)
                != self.prior.as_ref().map(slice)
        {
            return Err(SyncError::Changed);
        }
        let settings = settings::checkpoint(vault)?;
        let (journal, _) = journal::load(vault, now)?;
        let before = Snapshot::capture_kind(vault, false).map_err(backup_error)?;
        let document = self.document.capture(vault, &self.actor, now)?;
        let after = Snapshot::capture_kind(vault, false).map_err(backup_error)?;
        let revision = before.revision(vault);
        if after.revision(vault) != revision
            || journal::load(vault, now)?.0 != journal
            || settings::checkpoint(vault)? != settings
        {
            return Err(SyncError::Changed);
        }
        Ok(LocalProposal {
            actor: self.actor.clone(),
            operation: rand::random(),
            scope: self.scope.clone(),
            source_revision: revision,
            document,
            journal,
            settings,
        })
    }
    /// Reading the baseline never triggers a network operation. A new device
    /// starts with an EMPTY baseline, so local absence cannot delete cloud data.
    pub fn load(vault: &Vault, collection: &str, now: u64) -> Result<Self> {
        let prior = vault.get_bounded(LEDGER, MAX_PLAIN)?.map(Arc::new);
        let (_, journal) = journal::load(vault, now)?;
        let (actor, etag, document) = match &prior {
            Some(bytes) => {
                let ledger: Ledger =
                    serde_json::from_slice(slice(bytes)).map_err(|_| SyncError::Invalid)?;
                if ledger.version != 1
                    || !opaque(&ledger.actor)
                    || ledger.document.collection != collection
                {
                    return Err(SyncError::Invalid);
                }
                let document = ledger.document.into_document();
                document.validate(now)?;
                (ledger.actor, ledger.etag, document)
            }
            None => (
                journal
                    .as_ref()
                    .map(|j| j.actor.clone())
                    .unwrap_or_else(|| format!("{:032x}", rand::random::<u128>())),
                None,
                Document::empty(collection)?,
            ),
        };
        if journal.as_ref().is_some_and(|j| j.actor != actor) {
            return Err(SyncError::Changed);
        }
        Ok(Self {
            scope: vault.instance_id().into(),
            prior,
            actor,
            etag: etag.as_deref().map(EntityTag::parse).transpose()?,
            document,
        })
    }
    /// The caller only prepares this after the provider has acknowledged a
    /// conditional publication, or after deciding that downloaded content needs
    /// no publication. Never acknowledge a rejected/unknown PUT as committed.
    fn prepare_apply(
        &self,
        vault: &Vault,
        proposal: &LocalProposal,
        merged: &Document,
        etag: Option<EntityTag>,
        now: u64,
    ) -> Result<ApplyPlan> {
        if vault.instance_id() != self.scope
            || proposal.scope != self.scope
            || merged.collection != self.document.collection
        {
            return Err(SyncError::Changed);
        }
        let actual = vault.get_bounded(LEDGER, MAX_PLAIN)?;
        if actual.as_deref().map(Vec::as_slice) != self.prior.as_ref().map(slice) {
            return Err(SyncError::Changed);
        }
        let (journal_raw, journal) = journal::load(vault, now)?;
        if journal_raw != proposal.journal || settings::checkpoint(vault)? != proposal.settings {
            return Err(SyncError::Changed);
        }
        if Snapshot::capture_kind(vault, false)
            .map_err(backup_error)?
            .revision(vault)
            != proposal.source_revision
        {
            return Err(SyncError::Changed);
        }
        merged.validate(now)?;
        let current = Snapshot::capture(vault).map_err(backup_error)?;
        // The full restore capture and this projection check bracket external
        // SQLite writers. prepare_restore compares that full revision again;
        // its IMMEDIATE transaction later rejects rows/phantoms after staging.
        if Snapshot::capture_kind(vault, false)
            .map_err(backup_error)?
            .revision(vault)
            != proposal.source_revision
        {
            return Err(SyncError::Changed);
        }
        let local = projection::Projection::from_snapshot(&current)?;
        let mut remote = merged.projection();
        let identities = remote.localize(vault, &local)?;
        let incoming = remote.snapshot()?;
        // Only changed units get the restore path's independent credential IDs;
        // unchanged hosts retain their exact local records and active identity.
        let ids: std::collections::BTreeSet<_> = local
            .units
            .keys()
            .chain(remote.units.keys())
            .cloned()
            .collect();
        let selected: Vec<_> = ids
            .into_iter()
            .filter(|id| local.units.get(id) != remote.units.get(id))
            .collect();
        let prepared = restore::prepare_restore(
            vault,
            &incoming,
            &self.scope,
            &current.revision(vault),
            &selected,
        )
        .map_err(backup_error)?;
        let next = json(&LedgerRef {
            version: 1,
            actor: &self.actor,
            etag: etag.as_ref().map(EntityTag::header_value),
            document: merged.serializable(),
        })
        .map_err(backup_error)?;
        if next.len() > MAX_PLAIN {
            return Err(SyncError::Capacity);
        }
        Ok(ApplyPlan {
            changed_units: selected,
            prepared: prepared.with_cloud_checkpoint(
                self.prior.clone(),
                next,
                journal
                    .map(|j| {
                        j.acknowledged(merged)
                            .map(|raw| (journal_raw, Arc::new(raw)))
                    })
                    .transpose()?,
                proposal.settings.rows(),
                identities,
            ),
        })
    }
}
pub struct ApplyPlan {
    prepared: PreparedRestore,
    changed_units: Vec<String>,
}
impl ApplyPlan {
    pub fn changed_units(&self) -> &[String] {
        &self.changed_units
    }
    pub fn changed_hosts(&self) -> &[String] {
        &self.prepared.changed_hosts
    }
    pub fn next_scope(&self) -> &str {
        self.prepared.next_scope()
    }
    pub fn inspect_candidate<T>(
        &self,
        f: impl FnOnce(&mut Vault) -> super::Result<T>,
    ) -> super::Result<T> {
        self.prepared.inspect_candidate(f)
    }
    /// Same Agent write gate/transfer-before-Vault lock ordering and precompiled
    /// runtime publication contract as backup restore. Does not reconnect SSH.
    pub fn commit(self, vault: &mut Vault) -> Result<()> {
        self.prepared.commit(vault).map_err(backup_error)
    }
}
