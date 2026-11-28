//! Match independently created hosts by endpoint, never by display name alone.
//! Rebind all sync-visible references before the three-way merge. No Vault writes.
use super::*;
use crate::HostRecord;
use crate::bookmarks::Bookmark;
use std::collections::{BTreeMap, BTreeSet};

fn host(item: &Item) -> Option<HostRecord> {
    if !crate::repository::valid_id(&item.id, "host") {
        return None;
    }
    serde_json::from_slice(item.value.as_ref()?.records.get(&item.id)?).ok()
}
fn normalized_ip(address: &str) -> Option<String> {
    address
        .trim_start_matches('[')
        .trim_end_matches(']')
        .parse::<std::net::IpAddr>()
        .ok()
        .map(|ip| ip.to_string())
}
fn endpoint(h: &HostRecord) -> (String, u16, String) {
    let address = h.address.trim();
    let address = normalized_ip(address).unwrap_or_else(|| {
        address
            .trim_start_matches('[')
            .trim_end_matches(']')
            .trim_end_matches('.')
            .to_ascii_lowercase()
    });
    (address, h.port, h.username.clone())
}
fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    serde_json::to_vec(value).map_err(|_| SyncError::Invalid)
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Bookmarks {
    version: u32,
    items: Vec<Bookmark>,
}
fn bookmarks(bundle: Option<&Bundle>) -> Result<Bookmarks> {
    match bundle {
        None => Ok(Bookmarks {
            version: 1,
            items: vec![],
        }),
        Some(b) => {
            let d: Bookmarks = serde_json::from_slice(
                b.records
                    .get("sftp-bookmarks-v1")
                    .ok_or(SyncError::Invalid)?,
            )
            .map_err(|_| SyncError::Invalid)?;
            let mut ids = BTreeSet::new();
            if d.version != 1 || d.items.len() > 10000 || d.items.iter().any(|b| !ids.insert(&b.id))
            {
                return Err(SyncError::Invalid);
            }
            Ok(d)
        }
    }
}
fn bookmark_bundle(items: Vec<Bookmark>) -> Result<Bundle> {
    if items.len() > 10000 {
        return Err(SyncError::Capacity);
    }
    Ok(Bundle {
        records: BTreeMap::from([(
            "sftp-bookmarks-v1".into(),
            encode(&Bookmarks { version: 1, items })?,
        )]),
    })
}

pub(super) fn merge_bookmarks(
    a: Option<&Bundle>,
    b: Option<&Bundle>,
    base: Option<&Bundle>,
    direction: Divergence,
) -> Result<(Option<Bundle>, bool)> {
    let map = |d: Bookmarks| {
        d.items
            .into_iter()
            .map(|i| (i.id.clone(), i))
            .collect::<BTreeMap<_, _>>()
    };
    let (a, b, c) = (
        map(bookmarks(a)?),
        map(bookmarks(b)?),
        map(bookmarks(base)?),
    );
    let ids: BTreeSet<_> = a.keys().chain(b.keys()).chain(c.keys()).collect();
    let mut result = Vec::new();
    let mut conflict = false;
    for id in ids {
        let (left, right, old) = (a.get(id), b.get(id), c.get(id));
        let equal = |x: Option<&Bookmark>, y: Option<&Bookmark>| -> Result<bool> {
            Ok(encode(&x)? == encode(&y)?)
        };
        let chosen = if equal(left, right)? {
            left
        } else if equal(left, old)? {
            right
        } else if equal(right, old)? {
            left
        } else {
            conflict = true;
            if direction == Divergence::PreferRemote {
                right
            } else {
                left
            }
        };
        if let Some(chosen) = chosen {
            result.push(chosen.clone());
        }
    }
    // Different devices can independently bookmark the same host/path.
    // Keep a single usable entry, including after a host-ID reconciliation.
    let mut paths = BTreeSet::new();
    result.retain(|b| paths.insert((b.host_id.clone(), b.path.clone())));
    Ok((Some(bookmark_bundle(result)?), conflict))
}

impl Document {
    pub(super) fn align_hosts(
        &mut self,
        base: &mut Document,
        remote: &mut Document,
    ) -> Result<(Option<Document>, Option<Document>)> {
        let remote_hosts: BTreeMap<_, _> = remote
            .items
            .iter()
            .filter_map(host)
            .map(|h| (h.id.clone(), h))
            .collect();
        let local_hosts: BTreeMap<_, _> = self
            .items
            .iter()
            .filter_map(host)
            .map(|h| (h.id.clone(), h))
            .collect();
        let mut canonical = BTreeMap::new();
        let mut aliases = BTreeMap::new();
        // The cloud ID remains stable when a new device already has the same endpoint.
        for h in remote_hosts.values() {
            let key = endpoint(h);
            // A jump with the same endpoint can collapse into this group.
            // Use its cloud ID to avoid turning the route into a self-jump.
            let id = h
                .jump_host_id
                .as_ref()
                .and_then(|id| remote_hosts.get(id))
                .filter(|jump| endpoint(jump) == key)
                .map_or(&h.id, |jump| &jump.id);
            canonical.entry(key).or_insert_with(|| id.clone());
        }
        for h in remote_hosts.values() {
            if let Some(id) = canonical.get(&endpoint(h))
                && *id != h.id
            {
                aliases.insert(h.id.clone(), id.clone());
            }
        }
        let mut adopted = BTreeSet::new();
        for h in local_hosts.values() {
            if !remote_hosts.contains_key(&h.id)
                && let Some(id) = canonical.get(&endpoint(h))
                && *id != h.id
            {
                aliases.insert(h.id.clone(), id.clone());
                adopted.insert(id.clone());
            }
        }
        if aliases.is_empty() {
            return Ok((None, None));
        }
        let prior = remote.clone();
        remote.rebind_hosts(&aliases)?;
        self.rebind_hosts(&aliases)?;
        base.rebind_hosts(&aliases)?;
        let local_choice = (!adopted.is_empty()).then(|| self.clone());
        // A separately-created local duplicate is replaced by the cloud host,
        // as requested; existing shared IDs still follow the normal baseline.
        for item in &mut self.items {
            if adopted.contains(&item.id)
                && let Some(incoming) = remote.items.iter().find(|r| r.id == item.id)
            {
                *item = incoming.clone();
            }
        }
        Ok(((prior.items != remote.items).then_some(prior), local_choice))
    }
    fn rebind_hosts(&mut self, aliases: &BTreeMap<String, String>) -> Result<()> {
        let mut rewritten = BTreeMap::<String, Item>::new();
        // Canonical IDs first, so aliases cannot replace the canonical cloud payload.
        let mut originals = std::mem::take(&mut self.items);
        originals.sort_by_key(|i| aliases.contains_key(&i.id));
        for mut item in originals {
            let old_id = item.id.clone();
            let parsed_host = host(&item);
            if let Some(bundle) = &mut item.value {
                if let Some(mut h) = parsed_host {
                    h.id = aliases.get(&h.id).cloned().unwrap_or(h.id);
                    if let Some(jump) = &mut h.jump_host_id
                        && let Some(id) = aliases.get(jump)
                    {
                        *jump = id.clone();
                    }
                    let old_credential = h.credential_id.clone();
                    h.credential_id = old_credential
                        .as_ref()
                        .map(|_| format!("credential-{}", &h.id[5..]));
                    let mut records = Bundle {
                        records: BTreeMap::new(),
                    };
                    for (key, raw) in &bundle.records {
                        let mut value = Zeroizing::new(raw.clone());
                        let new_key = if key == &old_id {
                            h.id.clone()
                        } else if Some(key) == old_credential.as_ref() {
                            h.credential_id.clone().ok_or(SyncError::Invalid)?
                        } else {
                            key.replace(&old_id, &h.id)
                        };
                        if key == &old_id {
                            value.zeroize();
                            value = Zeroizing::new(encode(&h)?);
                        } else if *key == crate::forwarding_rules::record_key(&old_id) {
                            let mut config: crate::forwarding_rules::ForwardingConfig =
                                serde_json::from_slice(&value).map_err(|_| SyncError::Invalid)?;
                            config.host_id = h.id.clone();
                            value.zeroize();
                            value = Zeroizing::new(encode(&config)?);
                        }
                        records.records.insert(new_key, std::mem::take(&mut *value));
                    }
                    *bundle = records;
                    item.id = h.id;
                } else if item.id == "sftp-bookmarks-v1" {
                    let mut doc = bookmarks(Some(bundle))?;
                    for b in &mut doc.items {
                        if let Some(id) = b.host_id.as_ref().and_then(|h| aliases.get(h)) {
                            b.host_id = Some(id.clone());
                        }
                    }
                    *bundle = bookmark_bundle(doc.items)?;
                } else if item.id == super::super::HISTORY {
                    let raw = bundle
                        .records
                        .get_mut(super::super::HISTORY)
                        .ok_or(SyncError::Invalid)?;
                    let next = crate::command_history::remap_sync_hosts(raw, aliases)
                        .map_err(|_| SyncError::Invalid)?;
                    raw.zeroize();
                    *raw = next.to_vec();
                } else if item.id == "catalog-order" {
                    let raw = bundle
                        .records
                        .get_mut("__order")
                        .ok_or(SyncError::Invalid)?;
                    let (ids, groups): (Vec<String>, Vec<String>) =
                        serde_json::from_slice(raw).map_err(|_| SyncError::Invalid)?;
                    let mut seen = BTreeSet::new();
                    let ids: Vec<_> = ids
                        .into_iter()
                        .map(|id| aliases.get(&id).cloned().unwrap_or(id))
                        .filter(|id| seen.insert(id.clone()))
                        .collect();
                    *raw = encode(&(ids, groups))?;
                }
            } else if let Some(id) = aliases.get(&item.id) {
                item.id = id.clone();
            }
            rewritten.entry(item.id.clone()).or_insert(item);
        }
        self.items = rewritten.into_values().collect();
        Ok(())
    }
}

// Keep a device's saved host IDs stable (including live sessions) while the
// wire adopts cloud IDs. Alias metadata is encrypted, device-local and CASed
// atomically with the configuration/ledger; it is never part of cloud history.
pub(in crate::backup) const IDENTITIES: &str = "local-cloud-sync-host-identities-v1";
pub(super) fn identity_map(raw: Option<&[u8]>) -> Result<BTreeMap<String, String>> {
    let map: BTreeMap<String, String> = match raw {
        None => BTreeMap::new(),
        Some(raw) => serde_json::from_slice(raw).map_err(|_| SyncError::Invalid)?,
    };
    if map.len() > 10000
        || map.iter().any(|(a, b)| {
            !crate::repository::valid_id(a, "host") || !crate::repository::valid_id(b, "host")
        })
    {
        return Err(SyncError::Capacity);
    }
    Ok(map)
}
impl projection::Projection {
    fn rebind(&mut self, aliases: &BTreeMap<String, String>) -> Result<()> {
        if aliases.is_empty() {
            return Ok(());
        }
        let mut doc = Document {
            version: 1,
            collection: "00000000000000000000000000000000".into(),
            items: std::mem::take(&mut self.units)
                .into_iter()
                .map(|(id, value)| Item {
                    id,
                    stamp: Stamp {
                        unix_ms: 1,
                        logical: 0,
                        actor: "00000000000000000000000000000000".into(),
                    },
                    value: Some(value),
                })
                .collect(),
            snapshots: vec![],
        };
        doc.rebind_hosts(aliases)?;
        self.units = doc
            .items
            .into_iter()
            .filter_map(|i| i.value.map(|v| (i.id, v)))
            .collect();
        Ok(())
    }
    pub(super) fn canonicalize(&mut self, vault: &Vault) -> Result<()> {
        let raw = vault.get_bounded(IDENTITIES, 2 * 1024 * 1024)?;
        self.rebind(&identity_map(raw.as_deref().map(Vec::as_slice))?)
    }
    pub(super) fn localize(
        &mut self,
        vault: &Vault,
        local: &projection::Projection,
    ) -> Result<(Option<Bytes>, Bytes)> {
        let raw = vault.get_bounded(IDENTITIES, 2 * 1024 * 1024)?;
        let mut aliases = identity_map(raw.as_deref().map(Vec::as_slice))?;
        let hosts = |p: &projection::Projection| {
            p.units
                .iter()
                .filter(|(id, _)| crate::repository::valid_id(id, "host"))
                .filter_map(|(id, value)| {
                    value
                        .records
                        .get(id)
                        .and_then(|raw| serde_json::from_slice::<HostRecord>(raw).ok())
                })
                .map(|h| (h.id.clone(), h))
                .collect::<BTreeMap<_, _>>()
        };
        let locals = hosts(local);
        let mut reverse = BTreeMap::new();
        let mut used = BTreeSet::new();
        let remotes = hosts(self);
        for remote in remotes.values() {
            let candidate = locals
                .values()
                .find(|l| {
                    !used.contains(&l.id)
                        && (l.id == remote.id
                            || (!remotes.contains_key(&l.id)
                                && aliases.get(&l.id) == Some(&remote.id)))
                })
                .or_else(|| {
                    let target = endpoint(remote);
                    locals.values().find(|l| {
                        endpoint(l) == target
                            && !used.contains(&l.id)
                            && (!remotes.contains_key(&l.id) || l.id == remote.id)
                    })
                });
            if let Some(l) = candidate {
                used.insert(l.id.clone());
                if remote.id != l.id {
                    reverse.insert(remote.id.clone(), l.id.clone());
                    aliases.insert(l.id.clone(), remote.id.clone());
                } else {
                    aliases.remove(&l.id);
                }
            }
        }
        // Stale entries can never be consulted again: host IDs are never
        // recycled, only live hosts generate journal mutations, and a host
        // whose command-history section is gone no longer needs its cloud
        // remap. Retain the rest so the reconciliation map tracks live pairs
        // instead of growing without bound.
        let history = local
            .units
            .get(super::super::HISTORY)
            .and_then(|bundle| bundle.records.get(super::super::HISTORY))
            .map(Vec::as_slice);
        let retained =
            crate::command_history::retained_host_ids(history).map_err(|_| SyncError::Invalid)?;
        aliases.retain(|id, _| locals.contains_key(id) || retained.contains(id));
        if aliases.len() > 10000 {
            return Err(SyncError::Capacity);
        }
        self.rebind(&reverse)?;
        Ok((
            raw.map(Arc::new),
            Arc::new(Zeroizing::new(encode(&aliases)?)),
        ))
    }
}
