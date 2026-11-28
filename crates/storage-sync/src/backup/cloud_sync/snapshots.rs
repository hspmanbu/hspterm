//! Three previous valid configurations inside the authenticated cloud envelope.
//! No nested history, no plaintext sidecars; v1 readers reject v2 safely.
use super::*;
use sha2::{Digest, Sha256};
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct HistoricalSnapshot {
    id: String,
    unix_ms: u64,
    #[serde(deserialize_with = "bounded_items")]
    items: Vec<Item>,
}
#[derive(Clone, Serialize)]
pub struct SnapshotInfo {
    pub id: String,
    pub unix_ms: u64,
    pub hosts: usize,
    pub bookmarks: usize,
}
pub(super) fn bounded_history<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<Vec<HistoricalSnapshot>, D::Error> {
    struct Bounded;
    impl<'de> serde::de::Visitor<'de> for Bounded {
        type Value = Vec<HistoricalSnapshot>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("at most three non-nested snapshots")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut seq: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut result = Vec::new();
            while let Some(item) = seq.next_element::<HistoricalSnapshot>()? {
                if result.len() == 3 {
                    return Err(serde::de::Error::custom("too many cloud snapshots"));
                }
                result.push(item);
            }
            Ok(result)
        }
    }
    d.deserialize_seq(Bounded)
}
fn identity(items: &[Item]) -> Result<String> {
    let bytes = Zeroizing::new(serde_json::to_vec(items).map_err(|_| SyncError::Invalid)?);
    Ok(Sha256::digest(bytes.as_slice())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}
impl Document {
    pub(super) fn validate_snapshots(&self, now: u64) -> Result<()> {
        if self.snapshots.len() > 3 {
            return Err(SyncError::Capacity);
        }
        let mut ids = std::collections::BTreeSet::new();
        for snapshot in &self.snapshots {
            if snapshot.unix_ms == 0
                || snapshot.unix_ms > now.saturating_add(MAX_SKEW_MS)
                || snapshot.id != identity(&snapshot.items)?
                || !ids.insert(&snapshot.id)
            {
                return Err(SyncError::Invalid);
            }
            Document {
                version: 1,
                collection: self.collection.clone(),
                items: snapshot.items.clone(),
                snapshots: vec![],
            }
            .validate(now)?;
        }
        Ok(())
    }
    pub fn snapshots(&self) -> Vec<SnapshotInfo> {
        self.snapshots
            .iter()
            .map(|s| SnapshotInfo {
                id: s.id.clone(),
                unix_ms: s.unix_ms,
                hosts: s
                    .items
                    .iter()
                    .filter(|i| crate::repository::valid_id(&i.id, "host") && i.value.is_some())
                    .count(),
                bookmarks: s
                    .items
                    .iter()
                    .find(|i| i.id == "sftp-bookmarks-v1")
                    .and_then(|i| i.value.as_ref())
                    .and_then(|b| b.records.get("sftp-bookmarks-v1"))
                    .and_then(|r| serde_json::from_slice::<serde_json::Value>(r).ok())
                    .and_then(|v| v.get("items").and_then(|i| i.as_array()).map(Vec::len))
                    .unwrap_or(0),
            })
            .collect()
    }
    pub(super) fn retain_previous(&mut self, remote: &Document, now: u64) -> Result<()> {
        self.snapshots = remote.snapshots.clone();
        let previous = remote.by_id();
        let same_values = self.items.iter().filter(|i| i.value.is_some()).count()
            == remote.items.iter().filter(|i| i.value.is_some()).count()
            && self.items.iter().filter(|i| i.value.is_some()).all(|i| {
                previous
                    .get(i.id.as_str())
                    .is_some_and(|old| old.value == i.value)
            });
        if same_values || remote.items.is_empty() {
            self.trim_revisions_to_budget();
            return Ok(());
        }
        let id = identity(&remote.items)?;
        self.snapshots.retain(|s| s.id != id);
        self.snapshots.insert(
            0,
            HistoricalSnapshot {
                id,
                unix_ms: now,
                items: remote.items.clone(),
            },
        );
        self.snapshots.truncate(3);
        self.version = 2;
        self.trim_revisions_to_budget();
        Ok(())
    }
    /// Revision snapshots are optional recovery metadata; the live catalog is
    /// not. While the serialized document would not fit the authenticated
    /// plain budget (including room for the ledger wrapper), drop the OLDEST
    /// revisions first and publish the trimmed document instead of failing:
    /// a shallower rollback depth is always preferable to a dead exchange,
    /// and the newly retained revision is kept longest. Live items are never
    /// dropped, so a catalog that is over budget on its own still reports
    /// Capacity from encode().
    pub(super) fn trim_revisions_to_budget(&mut self) {
        self.trim_revisions_within(MAX_PLAIN - LEDGER_MARGIN);
    }
    /// Budget-parameterized form for tests; production budgets are the
    /// envelope bound minus the ledger wrapper margin.
    pub(super) fn trim_revisions_within(&mut self, budget: usize) {
        while !self.snapshots.is_empty()
            && serde_json::to_vec(&self.serializable()).is_ok_and(|raw| raw.len() > budget)
        {
            // Index 0 is the newest revision; the tail is the oldest.
            self.snapshots.pop();
        }
    }
}
impl Exchange {
    pub fn snapshots(&self) -> Vec<SnapshotInfo> {
        self.remote
            .as_ref()
            .map(Document::snapshots)
            .unwrap_or_default()
    }
    /// Explicit rollback publishes a new revision. Preserve durable command
    /// history deletion knowledge and snapshot the current remote before writing.
    pub fn restore_snapshot(
        &mut self,
        id: &str,
        password: &[u8],
        now: u64,
    ) -> Result<ExchangeStep> {
        let remote = self.remote.as_ref().ok_or(SyncError::Changed)?.clone();
        let old = remote
            .snapshots
            .iter()
            .find(|s| s.id == id)
            .ok_or(SyncError::Changed)?;
        let stamp = Stamp::next(
            self.local
                .items
                .iter()
                .chain(remote.items.iter())
                .map(|i| &i.stamp)
                .max(),
            &self.actor,
            now,
        )?;
        let mut selected = Document {
            version: 1,
            collection: remote.collection.clone(),
            items: old.items.clone(),
            snapshots: vec![],
        };
        let mut ancestor = Document::empty(&remote.collection)?;
        let mut current = remote.clone();
        let (_, choice) = selected.align_hosts(&mut ancestor, &mut current)?;
        // Reconcile identities without replacing the historical payload with
        // today's cloud settings; old duplicate IDs must not return on rollback.
        let selected = choice.unwrap_or(selected);
        let mut items: BTreeMap<_, _> = selected
            .items
            .into_iter()
            .map(|i| (i.id.clone(), i))
            .collect();
        for item in &remote.items {
            items.entry(item.id.clone()).or_insert_with(|| Item {
                id: item.id.clone(),
                stamp: stamp.clone(),
                value: None,
            });
        }
        if let Some(current) = remote.items.iter().find(|i| i.id == super::super::HISTORY)
            && let Some(historical) = items.get_mut(super::super::HISTORY)
        {
            if historical.value.is_some() {
                let merged = crate::command_history::merge_sync_payload(
                    projection::history(historical)?,
                    projection::history(current)?,
                )
                .map_err(|_| SyncError::Invalid)?;
                historical.value = Some(Bundle {
                    records: BTreeMap::from([(super::super::HISTORY.into(), merged.to_vec())]),
                });
            } else {
                historical.value = current.value.clone();
            }
        }
        for item in items.values_mut() {
            item.stamp = stamp.clone();
        }
        let mut restored = Document {
            version: 2,
            collection: remote.collection.clone(),
            items: items.into_values().collect(),
            snapshots: vec![],
        };
        restored.retain_previous(self.remote_prior.as_ref().unwrap_or(&remote), now)?;
        restored.validate(now)?;
        let summary = references::summary(&self.original, &restored, 0);
        let etag = self.etag.clone().ok_or(SyncError::Changed)?;
        // Freeze the selected snapshot. A changed cloud ETag requires a fresh
        // user decision; rollback is never silently replayed over another writer.
        self.resolution = Divergence::Unresolved;
        self.local = restored.clone();
        let ciphertext = restored.encrypt(password, now)?;
        Ok(ExchangeStep::Upload(PendingUpload::resolved(
            self.operation,
            restored,
            ciphertext,
            etag,
            summary,
        )))
    }
}
