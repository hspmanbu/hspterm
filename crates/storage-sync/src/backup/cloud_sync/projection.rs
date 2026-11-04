use super::*;
use crate::repository::{Catalog, HostGroup, HostRecord, valid_id};
use std::collections::{BTreeMap, BTreeSet};

pub(super) struct Projection {
    pub units: BTreeMap<String, Bundle>,
}
pub(super) fn allowed_id(id: &str) -> bool {
    valid_id(id, "host")
        || valid_id(id, "group")
        || id == "group-default"
        || id == "catalog-order"
        || super::super::GLOBALS.contains(&id)
}
pub(super) fn sensitive(id: &str) -> bool {
    valid_id(id, "host") || id == super::super::HISTORY
}
fn record(bytes: &[u8]) -> Bytes {
    Arc::new(Zeroizing::new(bytes.to_vec()))
}
pub(super) fn history(item: &Item) -> Result<&[u8]> {
    item.value
        .as_ref()
        .and_then(|v| v.records.get(super::super::HISTORY))
        .map(Vec::as_slice)
        .ok_or(SyncError::Invalid)
}
pub(super) fn validate_unit(id: &str, bundle: &Bundle) -> Result<()> {
    use super::super::{GLOBALS, HISTORY, host_keys, proxy_key};
    if !allowed_id(id) || bundle.records.len() > 5 {
        return Err(SyncError::Invalid);
    }
    let keys: BTreeSet<_> = bundle.records.keys().map(String::as_str).collect();
    if id == "catalog-order" {
        if keys != BTreeSet::from(["__order"]) {
            return Err(SyncError::Invalid);
        }
        let (hosts, groups): (Vec<String>, Vec<String>) =
            serde_json::from_slice(&bundle.records["__order"]).map_err(|_| SyncError::Invalid)?;
        if hosts.len() > 10000
            || groups.len() > 1000
            || hosts.iter().any(|h| !valid_id(h, "host"))
            || groups
                .iter()
                .any(|g| !valid_id(g, "group") && g != "group-default")
            || hosts.iter().collect::<BTreeSet<_>>().len() != hosts.len()
            || groups.iter().collect::<BTreeSet<_>>().len() != groups.len()
        {
            return Err(SyncError::Invalid);
        }
    } else if id.starts_with("group-") {
        if keys != BTreeSet::from(["__group"]) {
            return Err(SyncError::Invalid);
        }
        let group: HostGroup =
            serde_json::from_slice(&bundle.records["__group"]).map_err(|_| SyncError::Invalid)?;
        if group.id != id
            || group.name.trim().is_empty()
            || group.name.len() > 1024
            || group.name.chars().any(char::is_control)
        {
            return Err(SyncError::Invalid);
        }
    } else if valid_id(id, "host") {
        let host: HostRecord =
            serde_json::from_slice(bundle.records.get(id).ok_or(SyncError::Invalid)?)
                .map_err(|_| SyncError::Invalid)?;
        host.validate().map_err(|_| SyncError::Invalid)?;
        if host.id != id
            || host
                .credential_id
                .as_ref()
                .is_some_and(|c| c != &canonical_credential(id))
        {
            return Err(SyncError::Invalid);
        }
        let allowed = host_keys(&host).into_iter().collect::<BTreeSet<_>>();
        if !bundle.records.contains_key(id)
            || !bundle.records.keys().all(|k| allowed.contains(k))
            || host
                .credential_id
                .as_ref()
                .is_some_and(|c| !bundle.records.contains_key(c))
            || host.proxy.as_ref().is_some_and(|p| p.authenticate)
                != bundle.records.contains_key(&proxy_key(id))
        {
            return Err(SyncError::Invalid);
        }
    } else if GLOBALS.contains(&id) {
        if keys != BTreeSet::from([id]) {
            return Err(SyncError::Invalid);
        }
    } else {
        return Err(SyncError::Invalid);
    }
    for (key, bytes) in &bundle.records {
        if bytes.len()
            > if key == HISTORY {
                8 * 1024 * 1024
            } else {
                2 * 1024 * 1024
            }
        {
            return Err(SyncError::Capacity);
        }
    }
    Ok(())
}
fn canonical_credential(host: &str) -> String {
    format!("credential-{}", &host[5..])
}
impl Projection {
    pub fn capture(vault: &Vault) -> Result<Self> {
        // Do NOT capture a complete backup then remove fonts afterward: that
        // would already have read device paths/font bodies into sync memory.
        let snapshot = Snapshot::capture_kind(vault, false).map_err(backup_error)?;
        Self::from_snapshot(&snapshot)
    }
    pub fn from_snapshot(snapshot: &Snapshot) -> Result<Self> {
        let mut units = BTreeMap::new();
        for (id, unit) in restore::units(snapshot).map_err(backup_error)? {
            if !allowed_id(&id) {
                continue;
            }
            let mut bundle = Bundle {
                records: unit
                    .records
                    .iter()
                    .map(|(k, v)| (k.clone(), slice(v).to_vec()))
                    .collect(),
            };
            if valid_id(&id, "host") {
                let mut host: HostRecord =
                    serde_json::from_slice(bundle.records.get(&id).ok_or(SyncError::Invalid)?)
                        .map_err(|_| SyncError::Invalid)?;
                if let Some(old) = &host.credential_id {
                    // Local restore deliberately allocates independent secret
                    // records. Normalize their opaque IDs on the wire so this
                    // safe remapping cannot cause endless false modifications.
                    let secret = bundle.records.remove(old).ok_or(SyncError::Invalid)?;
                    let canonical = canonical_credential(&id);
                    bundle.records.insert(canonical.clone(), secret);
                    host.credential_id = Some(canonical);
                    let prior = bundle.records.insert(
                        id.clone(),
                        serde_json::to_vec(&host).map_err(|_| SyncError::Invalid)?,
                    );
                    if let Some(mut bytes) = prior {
                        bytes.zeroize();
                    }
                }
            }
            validate_unit(&id, &bundle)?;
            units.insert(id, bundle);
        }
        Ok(Self { units })
    }
    pub fn snapshot(&self) -> Result<Snapshot> {
        use super::super::{CATALOG, GLOBALS, HISTORY};
        let mut groups = BTreeMap::<String, HostGroup>::new();
        let mut hosts = BTreeSet::new();
        let mut records = super::super::Records::new();
        let (mut preferred_hosts, mut preferred_groups) = (Vec::new(), Vec::new());
        for (id, unit) in &self.units {
            validate_unit(id, unit)?;
            if id == "catalog-order" {
                (preferred_hosts, preferred_groups) =
                    serde_json::from_slice(&unit.records["__order"])
                        .map_err(|_| SyncError::Invalid)?;
            } else if id.starts_with("group-") {
                let group: HostGroup = serde_json::from_slice(&unit.records["__group"])
                    .map_err(|_| SyncError::Invalid)?;
                groups.insert(id.clone(), group);
            } else {
                if valid_id(id, "host") {
                    hosts.insert(id.clone());
                }
                for (key, bytes) in &unit.records {
                    if records.insert(key.clone(), record(bytes)).is_some() {
                        return Err(SyncError::Invalid);
                    }
                }
            }
        }
        if !self.units.contains_key("catalog-order") || !groups.contains_key("group-default") {
            return Err(SyncError::References);
        }
        fn order(preferred: Vec<String>, all: &BTreeSet<String>) -> Vec<String> {
            let mut seen = BTreeSet::new();
            preferred
                .into_iter()
                .chain(all.iter().cloned())
                .filter(|id| all.contains(id) && seen.insert(id.clone()))
                .collect()
        }
        let catalog = Catalog {
            version: 1,
            hosts: order(preferred_hosts, &hosts),
            groups: order(preferred_groups, &groups.keys().cloned().collect())
                .into_iter()
                .filter_map(|id| groups.remove(&id))
                .collect(),
            drafts: vec![],
        };
        // A history unit is a structured CRDT including durable clear epochs,
        // never a generic missing-record deletion.
        if let Some(raw) = records.get(HISTORY) {
            crate::command_history::merge_sync_payload(slice(raw), slice(raw))
                .map_err(|_| SyncError::Invalid)?;
        }
        if records
            .keys()
            .any(|k| k.starts_with("config-") && !GLOBALS.contains(&k.as_str()))
        {
            return Err(SyncError::Invalid);
        }
        records.insert(CATALOG.into(), json(&catalog).map_err(backup_error)?);
        let snapshot = Snapshot {
            records,
            data_version: None,
        };
        snapshot.validate().map_err(backup_error)?;
        Ok(snapshot)
    }
}
