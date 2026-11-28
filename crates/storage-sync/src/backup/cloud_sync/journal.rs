//! Device-local mutation times, encrypted in the SAME SQLite transaction as
//! the actual allowed configuration changes. Never stores names or payloads.
use super::*;
use crate::{
    RecordChange, StorageError,
    repository::{Catalog, HostRecord, valid_id},
};
use rusqlite::{OptionalExtension, Transaction, params};
use std::{
    collections::BTreeSet,
    sync::OnceLock,
    time::{SystemTime, UNIX_EPOCH},
};

pub(crate) const RECORD: &str = "local-cloud-sync-mutations-v1";
pub(crate) const LIMIT: usize = 8 * 1024 * 1024;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Journal {
    version: u32,
    pub actor: String,
    clock: Option<Stamp>,
    #[serde(deserialize_with = "unique_pending")]
    pending: BTreeMap<String, Stamp>,
}
fn unique_pending<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<BTreeMap<String, Stamp>, D::Error> {
    struct Unique;
    impl<'de> serde::de::Visitor<'de> for Unique {
        type Value = BTreeMap<String, Stamp>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("bounded unique pending unit timestamps")
        }
        fn visit_map<A: serde::de::MapAccess<'de>>(
            self,
            mut map: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut result = BTreeMap::new();
            while let Some(id) = map.next_key::<String>()? {
                if result.len() >= MAX_ITEMS
                    || !projection::allowed_id(&id)
                    || result.contains_key(&id)
                {
                    return Err(serde::de::Error::custom("invalid pending unit"));
                }
                result.insert(id, map.next_value::<Stamp>()?);
            }
            Ok(result)
        }
    }
    d.deserialize_map(Unique)
}
pub fn now_millis() -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| SyncError::Clock)?
        .as_millis()
        .try_into()
        .map_err(|_| SyncError::Clock)
}
impl Journal {
    fn decode(bytes: &[u8], now: u64) -> Result<Self> {
        if bytes.len() > LIMIT {
            return Err(SyncError::Capacity);
        }
        let value: Self = serde_json::from_slice(bytes).map_err(|_| SyncError::Invalid)?;
        if value.version != 1 || !opaque(&value.actor) || value.pending.len() > MAX_ITEMS {
            return Err(SyncError::Invalid);
        }
        if let Some(clock) = &value.clock {
            clock.validate(now)?;
        }
        for (id, stamp) in &value.pending {
            stamp.validate(now)?;
            if !projection::allowed_id(id)
                || stamp.actor != value.actor
                || value.clock.as_ref().is_none_or(|clock| stamp > clock)
            {
                return Err(SyncError::Invalid);
            }
        }
        Ok(value)
    }
    fn encode(&self) -> Result<Zeroizing<Vec<u8>>> {
        let raw = Zeroizing::new(serde_json::to_vec(self).map_err(|_| SyncError::Invalid)?);
        if raw.len() > LIMIT || self.pending.len() > MAX_ITEMS {
            return Err(SyncError::Capacity);
        }
        Ok(raw)
    }
    pub(super) fn stamp(&self, id: &str) -> Result<Stamp> {
        self.pending.get(id).cloned().ok_or(SyncError::Changed)
    }
    pub(super) fn acknowledged(mut self, document: &Document) -> Result<Zeroizing<Vec<u8>>> {
        if let Some(latest) = document.items.iter().map(|i| &i.stamp).max()
            && self.clock.as_ref().is_none_or(|old| old < latest)
        {
            self.clock = Some(latest.clone());
        }
        self.pending.clear();
        self.encode()
    }
}
pub(super) fn load(vault: &Vault, now: u64) -> Result<(Option<Bytes>, Option<Journal>)> {
    let raw = vault.get_bounded(RECORD, LIMIT)?.map(Arc::new);
    let journal = raw
        .as_ref()
        .map(|v| Journal::decode(slice(v), now))
        .transpose()?;
    Ok((raw, journal))
}

/// Source-comparison form of the mutation journal: the ACTOR that owns the
/// pending stamps must match. The journal row is sync-managed bookkeeping —
/// every configuration write restamps it inside the same SQLite transaction —
/// so comparing raw bytes reads that ordinary churn as a fresh local change
/// and aborts the exchange. A restamp never happens alone: when it reflects a
/// real edit the underlying record changed too, and the proposal's frozen
/// source revision still fails; a journal rebase or enable always accompanies
/// target/ledger row changes that remain byte-compared. A row that appeared,
/// vanished, or no longer decodes is still reported as a source change.
pub(super) fn same_source(vault: &Vault, expected: Option<&[u8]>, now: u64) -> Result<bool> {
    let (_, current) = load(vault, now)?;
    let expected = match expected {
        None => None,
        Some(raw) => match Journal::decode(raw, now) {
            Ok(journal) => Some(journal.actor),
            Err(_) => return Ok(false),
        },
    };
    Ok(expected == current.map(|journal| journal.actor))
}

/// Explicit setup arms tracking once. It does not connect, read remote files or
/// upload. Preexisting local data is stamped as the user's initial sync state.
/// The returned write can join the target/credentials CAS transaction.
pub(super) fn initial_record(vault: &Vault, now: u64) -> Result<Option<Zeroizing<Vec<u8>>>> {
    if load(vault, now)?.1.is_some() {
        return Ok(None);
    }
    rebase_record(
        vault,
        vault
            .get_bounded(LEDGER, MAX_PLAIN)?
            .as_deref()
            .map(Vec::as_slice),
        now,
    )
    .map(Some)
}
/// Explicit target switching is a local operation. It adopts that target's
/// original ledger, observes both clocks, and stamps current local differences
/// at the confirmed switch time rather than at a later sync request.
pub(super) fn rebase_record(
    vault: &Vault,
    baseline: Option<&[u8]>,
    now: u64,
) -> Result<Zeroizing<Vec<u8>>> {
    let (_, current) = load(vault, now)?;
    let mut document = None;
    let actor = if let Some(bytes) = baseline {
        let ledger: Ledger = serde_json::from_slice(bytes).map_err(|_| SyncError::Invalid)?;
        if ledger.version != 1 || !opaque(&ledger.actor) {
            return Err(SyncError::Invalid);
        }
        let value = ledger.document.into_document();
        value.validate(now)?;
        document = Some(value);
        ledger.actor
    } else {
        current
            .as_ref()
            .map(|j| j.actor.clone())
            .unwrap_or_else(|| format!("{:032x}", rand::random::<u128>()))
    };
    if current.as_ref().is_some_and(|j| j.actor != actor) {
        return Err(SyncError::Changed);
    }
    let latest = document
        .as_ref()
        .and_then(|d| d.items.iter().map(|i| &i.stamp).max());
    let latest = latest
        .into_iter()
        .chain(current.as_ref().and_then(|j| j.clock.as_ref()))
        .max();
    let stamp = Stamp::next(latest, &actor, now)?;
    let mut ids = projection::Projection::capture(vault)?
        .units
        .into_keys()
        .collect::<BTreeSet<_>>();
    if let Some(document) = document {
        ids.extend(document.items.into_iter().map(|i| i.id));
    }
    Journal {
        version: 1,
        actor,
        clock: Some(stamp.clone()),
        pending: ids.into_iter().map(|id| (id, stamp.clone())).collect(),
    }
    .encode()
}
pub fn enable(vault: &mut Vault) -> Result<()> {
    enable_at(vault, now_millis()?)
}
fn enable_at(vault: &mut Vault, now: u64) -> Result<()> {
    let version = vault
        .db
        .query_row("PRAGMA data_version", [], |r| r.get(0))
        .map_err(StorageError::from)?;
    let Some(raw) = initial_record(vault, now)? else {
        return Ok(());
    };
    if !vault.apply_checked_data_version(
        &[(RECORD, None)],
        &[RecordChange::Put(RECORD, &raw)],
        version,
    )? {
        return Err(SyncError::Changed);
    }
    Ok(())
}

fn events() -> &'static tokio::sync::broadcast::Sender<String> {
    static EVENTS: OnceLock<tokio::sync::broadcast::Sender<String>> = OnceLock::new();
    EVENTS.get_or_init(|| tokio::sync::broadcast::channel(64).0)
}
/// Coalesced per-scope change versions for an operation-driven network owner.
/// Unlike a single last-event watch, a burst from another Vault cannot hide a
/// local change or cause startup dirty data to be mistaken for a new edit.
pub fn versions() -> tokio::sync::watch::Receiver<BTreeMap<String, u64>> {
    version_events().subscribe()
}
fn version_events() -> &'static tokio::sync::watch::Sender<BTreeMap<String, u64>> {
    static VERSIONS: OnceLock<tokio::sync::watch::Sender<BTreeMap<String, u64>>> = OnceLock::new();
    VERSIONS.get_or_init(|| tokio::sync::watch::channel(BTreeMap::new()).0)
}
/// Operation-driven notification, never startup polling. The owning driver
/// filters its original Vault scope and coalesces changes before any HTTP work.
pub fn subscribe() -> tokio::sync::broadcast::Receiver<String> {
    events().subscribe()
}
pub(crate) fn committed(scope: &str) {
    // No receiver is a normal offline/disabled state. Pending times are already
    // durable, so a lagging/absent UI cannot lose the configuration mutation.
    let _no_active_receiver = events().send(scope.to_owned());
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    let sequence = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    version_events().send_modify(|values| {
        if values.len() >= 16
            && !values.contains_key(scope)
            && let Some(oldest) = values
                .iter()
                .min_by_key(|(_, seq)| *seq)
                .map(|(scope, _)| scope.clone())
        {
            values.remove(&oldest);
        }
        values.insert(scope.to_owned(), sequence);
    });
}
fn storage(error: SyncError) -> StorageError {
    match error {
        SyncError::Storage(e) => e,
        SyncError::Capacity => StorageError::RecordTooLarge,
        _ => StorageError::Format,
    }
}
fn possible(id: &str) -> bool {
    id == super::super::CATALOG
        || super::super::GLOBALS.contains(&id)
        || valid_id(id, "host")
        || valid_id(id, "credential")
        || id.starts_with("host-proxy-credential-")
        || id.starts_with("host-forwarding-v1-")
        || id.starts_with("host-terminal-decorations-v1-")
}
fn row(
    tx: &Transaction<'_>,
    key: &[u8; 32],
    id: &str,
    limit: usize,
) -> std::result::Result<Option<Zeroizing<Vec<u8>>>, StorageError> {
    let value: Option<(Vec<u8>, Option<Vec<u8>>)> = tx.query_row("SELECT nonce, CASE WHEN length(ciphertext)<=?2 THEN ciphertext ELSE NULL END FROM records WHERE id=?1", params![id, (limit + 16) as i64], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
    value
        .map(|(nonce, bytes)| {
            crate::decrypt_record(key, id, (nonce, bytes.ok_or(StorageError::RecordTooLarge)?))
        })
        .transpose()
}
fn catalog(bytes: Option<&[u8]>) -> std::result::Result<Catalog, StorageError> {
    let c = bytes
        .map(serde_json::from_slice::<Catalog>)
        .transpose()
        .map_err(|_| StorageError::Format)?
        .unwrap_or_default();
    super::super::check_catalog(&c).map_err(|_| StorageError::Format)?;
    Ok(c)
}
fn changed<'a>(
    tx: &Transaction<'_>,
    key: &[u8; 32],
    values: &'a BTreeMap<&str, Option<&'a [u8]>>,
) -> std::result::Result<BTreeSet<&'a str>, StorageError> {
    let mut result = BTreeSet::new();
    for (id, value) in values {
        if !possible(id) {
            continue;
        }
        let limit = if *id == super::super::HISTORY {
            8 * 1024 * 1024
        } else {
            2 * 1024 * 1024
        };
        if row(tx, key, id, limit)?.as_deref().map(Vec::as_slice) != *value {
            result.insert(*id);
        }
    }
    Ok(result)
}

/// Called BEFORE the original row mutations, inside their existing write
/// transaction. A later failure rolls back both configuration and timestamps.
pub(crate) fn record_transaction(
    tx: &Transaction<'_>,
    key: &[u8; 32],
    changes: &[RecordChange<'_>],
) -> std::result::Result<bool, StorageError> {
    if !changes.iter().any(|c| {
        possible(match c {
            RecordChange::Put(id, _) | RecordChange::Delete(id) => id,
        })
    }) {
        return Ok(false);
    }
    let Some(raw) = row(tx, key, RECORD, LIMIT)? else {
        return Ok(false);
    };
    // A cloud ACK applies imported state, not a new local edit. Only the cloud
    // plan can supply both the authenticated ledger and its retired journal.
    if changes
        .iter()
        .any(|c| matches!(c, RecordChange::Put(id,_) if *id == LEDGER))
    {
        if !changes
            .iter()
            .any(|c| matches!(c, RecordChange::Put(id,_) if *id == RECORD))
        {
            return Err(StorageError::Format);
        }
        return Ok(false);
    }
    record_at(tx, key, changes, &raw, now_millis().map_err(storage)?)
}
fn record_at(
    tx: &Transaction<'_>,
    key: &[u8; 32],
    changes: &[RecordChange<'_>],
    raw: &[u8],
    now: u64,
) -> std::result::Result<bool, StorageError> {
    let mut journal = Journal::decode(raw, now).map_err(storage)?;
    let values: BTreeMap<_, _> = changes
        .iter()
        .map(|c| match c {
            RecordChange::Put(id, bytes) => (*id, Some(*bytes)),
            RecordChange::Delete(id) => (*id, None),
        })
        .collect();
    let changed = changed(tx, key, &values)?;
    let mut units = BTreeSet::new();
    for id in &changed {
        if super::super::GLOBALS.contains(id) {
            units.insert((*id).to_owned());
        }
    }
    if changed.iter().any(|id| !super::super::GLOBALS.contains(id)) {
        let old_raw = row(tx, key, super::super::CATALOG, 2 * 1024 * 1024)?;
        let old = catalog(old_raw.as_deref().map(Vec::as_slice))?;
        let new = match values.get(super::super::CATALOG) {
            Some(raw) => catalog(*raw)?,
            None => catalog(old_raw.as_deref().map(Vec::as_slice))?,
        };
        let old_hosts: BTreeSet<_> = old.hosts.iter().map(String::as_str).collect();
        let new_hosts: BTreeSet<_> = new.hosts.iter().map(String::as_str).collect();
        let hosts: BTreeSet<_> = old_hosts.union(&new_hosts).copied().collect();
        if changed.contains(super::super::CATALOG) {
            let a = old
                .groups
                .iter()
                .map(|g| (g.id.as_str(), g.name.as_str()))
                .collect::<BTreeMap<_, _>>();
            let b = new
                .groups
                .iter()
                .map(|g| (g.id.as_str(), g.name.as_str()))
                .collect::<BTreeMap<_, _>>();
            for id in a.keys().chain(b.keys()) {
                if a.get(id) != b.get(id) {
                    units.insert((*id).to_owned());
                }
            }
            if old.hosts != new.hosts
                || old
                    .groups
                    .iter()
                    .map(|g| &g.id)
                    .ne(new.groups.iter().map(|g| &g.id))
            {
                units.insert("catalog-order".into());
            }
        }
        for id in &changed {
            let host = if valid_id(id, "host") {
                Some(*id)
            } else {
                [
                    "host-proxy-credential-",
                    "host-forwarding-v1-",
                    "host-terminal-decorations-v1-",
                ]
                .into_iter()
                .find_map(|p| id.strip_prefix(p))
            };
            if let Some(host) = host
                && hosts.contains(host)
            {
                units.insert(host.to_owned());
            }
        }
        // Secret-only updates are rare. Only then scan FORMAL host metadata to
        // associate opaque credential IDs; this association scan reads only
        // host metadata, not the referenced credential bodies.
        if changed.iter().any(|id| valid_id(id, "credential")) {
            for id in hosts {
                let before = row(tx, key, id, 2 * 1024 * 1024)?;
                let after = values
                    .get(id)
                    .copied()
                    .unwrap_or(before.as_deref().map(Vec::as_slice));
                for raw in [before.as_deref().map(Vec::as_slice), after]
                    .into_iter()
                    .flatten()
                {
                    let host: HostRecord =
                        serde_json::from_slice(raw).map_err(|_| StorageError::Format)?;
                    if host.id != id {
                        return Err(StorageError::Format);
                    }
                    if host
                        .credential_id
                        .as_deref()
                        .is_some_and(|c| changed.contains(c))
                    {
                        units.insert(id.to_owned());
                    }
                }
            }
        }
        // Creating/removing formal membership can reuse a previously written
        // row; account for the host even when that row's bytes did not change.
        for id in old_hosts.symmetric_difference(&new_hosts) {
            units.insert((*id).to_owned());
        }
    }
    if units.is_empty() {
        return Ok(false);
    }
    let stamp = Stamp::next(journal.clock.as_ref(), &journal.actor, now).map_err(storage)?;
    let aliases_raw = row(tx, key, super::reconciliation::IDENTITIES, 2 * 1024 * 1024)?;
    let aliases = super::reconciliation::identity_map(aliases_raw.as_deref().map(Vec::as_slice))
        .map_err(storage)?;
    for id in units {
        let id = aliases.get(&id).cloned().unwrap_or(id);
        if !projection::allowed_id(&id) {
            return Err(StorageError::Format);
        }
        journal.pending.insert(id, stamp.clone());
    }
    journal.clock = Some(stamp);
    let encoded = journal.encode().map_err(storage)?;
    let (nonce, ciphertext) = crate::encrypt(key, RECORD, &encoded)?;
    tx.execute("INSERT INTO records VALUES (?1,?2,?3) ON CONFLICT(id) DO UPDATE SET nonce=excluded.nonce,ciphertext=excluded.ciphertext", params![RECORD, nonce.as_slice(), ciphertext])?;
    Ok(true)
}

#[cfg(test)]
mod tests;
