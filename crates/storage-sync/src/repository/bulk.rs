//! Explicit non-sensitive host edits with a preview revision and atomic CAS.
//! Credentials/drafts and runtime SSH identities are never read or modified.
use super::*;
use sha2::{Digest, Sha256};
use std::collections::HashSet;

const MAX_BYTES: usize = 8 * 1024 * 1024;
#[derive(Debug, thiserror::Error)]
pub enum BulkError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error(transparent)]
    Repository(#[from] RepositoryError),
    #[error("原主机、分组或配置库已改变，请重新预览；未保存批量修改")]
    Changed,
    #[error("请选择现有主机及允许的非敏感字段，并检查参数范围")]
    Invalid,
    #[error("所选主机记录过大，请分批编辑；未保存批量修改")]
    Capacity,
}
type BulkResult<T> = std::result::Result<T, BulkError>;
#[derive(Clone)]
pub struct NetworkPatch {
    pub use_defaults: bool,
    pub timeout_seconds: u32,
    pub keepalive_seconds: u32,
    pub keepalive_response_seconds: Option<u32>,
    pub keepalive_failures: u32,
}
#[derive(Clone, Default)]
pub struct Patch {
    pub group_id: Option<String>,
    pub favorite: Option<bool>,
    pub open_sftp: Option<bool>,
    pub follow_osc7: Option<bool>,
    pub network: Option<NetworkPatch>,
}
#[derive(Clone)]
pub struct Host {
    pub id: String,
    pub name: String,
    pub group_id: String,
    pub favorite: bool,
    pub open_sftp: bool,
    pub follow_osc7: bool,
    pub network: NetworkPatch,
}
#[derive(Clone)]
pub struct Snapshot {
    pub vault_scope: String,
    pub revision: String,
    pub groups: Vec<HostGroup>,
    pub hosts: Vec<Host>,
}
struct Captured {
    snapshot: Snapshot,
    catalog: Option<Zeroizing<Vec<u8>>>,
    hosts: Vec<(HostRecord, Zeroizing<Vec<u8>>)>,
}
fn project(host: &HostRecord) -> Host {
    Host {
        id: host.id.clone(),
        name: host.name.clone(),
        group_id: host.group_id.clone(),
        favorite: host.favorite,
        open_sftp: host.open_sftp,
        follow_osc7: host.follow_osc7,
        network: NetworkPatch {
            use_defaults: host.use_network_defaults,
            timeout_seconds: host.timeout_seconds,
            keepalive_seconds: host.keepalive_seconds,
            keepalive_response_seconds: host.keepalive_response_seconds,
            keepalive_failures: host.keepalive_failures,
        },
    }
}
fn capture(vault: &Vault, ids: &[String]) -> BulkResult<Captured> {
    if ids.is_empty() || ids.len() > 10000 {
        return Err(BulkError::Invalid);
    }
    let wanted: HashSet<_> = ids.iter().collect();
    if wanted.len() != ids.len() || ids.iter().any(|id| !valid_id(id, "host")) {
        return Err(BulkError::Invalid);
    }
    let raw = vault.get_bounded(CATALOG, MAX_RECORD)?;
    let catalog: Catalog = raw
        .as_deref()
        .map(|r| decoded(r))
        .transpose()?
        .unwrap_or_default();
    let groups: HashSet<_> = catalog.groups.iter().map(|g| g.id.as_str()).collect();
    let known: HashSet<_> = catalog.hosts.iter().map(String::as_str).collect();
    if !catalog.within_limits()
        || groups.len() != catalog.groups.len()
        || catalog.groups.iter().any(|g| {
            (g.id != DEFAULT_GROUP && !valid_id(&g.id, "group"))
                || g.name.trim().is_empty()
                || g.name.len() > 1024
        })
        || catalog
            .groups
            .iter()
            .map(|g| g.name.as_str())
            .collect::<HashSet<_>>()
            .len()
            != catalog.groups.len()
        || catalog.hosts.iter().any(|id| !valid_id(id, "host"))
        || known.len() != catalog.hosts.len()
        || ids.iter().any(|id| !known.contains(id.as_str()))
    {
        return Err(BulkError::Changed);
    }
    let mut hash = Sha256::new();
    hash.update(b"HSPTerm explicit host bulk v1\0");
    hash.update(vault.instance_id().as_bytes());
    hash.update(Sha256::digest(
        raw.as_deref().map(Vec::as_slice).unwrap_or_default(),
    ));
    let mut ordered = ids.to_vec();
    ordered.sort();
    let mut bytes = 0usize;
    let mut hosts = Vec::with_capacity(ids.len());
    let mut projections = Vec::with_capacity(ids.len());
    for id in ordered {
        let before = vault
            .get_bounded(&id, MAX_RECORD)?
            .ok_or(BulkError::Changed)?;
        bytes = bytes.checked_add(before.len()).ok_or(BulkError::Capacity)?;
        if bytes > MAX_BYTES / 2 {
            return Err(BulkError::Capacity);
        }
        let host: HostRecord = decoded(&before)?;
        host.validate()?;
        if host.id != id || !groups.contains(host.group_id.as_str()) {
            return Err(BulkError::Changed);
        }
        hash.update((id.len() as u64).to_le_bytes());
        hash.update(id.as_bytes());
        hash.update(Sha256::digest(&before));
        projections.push(project(&host));
        hosts.push((host, before));
    }
    Ok(Captured {
        snapshot: Snapshot {
            vault_scope: vault.instance_id().into(),
            revision: hash.finalize().iter().map(|b| format!("{b:02x}")).collect(),
            groups: catalog.groups,
            hosts: projections,
        },
        catalog: raw,
        hosts,
    })
}
pub fn load(vault: &Vault, ids: &[String]) -> BulkResult<Snapshot> {
    Ok(capture(vault, ids)?.snapshot)
}
pub fn apply(
    vault: &mut Vault,
    scope: &str,
    revision: &str,
    ids: &[String],
    patch: Patch,
) -> BulkResult<Snapshot> {
    if scope != vault.instance_id()
        || revision.len() != 64
        || !revision.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(BulkError::Changed);
    }
    if patch.group_id.is_none()
        && patch.favorite.is_none()
        && patch.open_sftp.is_none()
        && patch.follow_osc7.is_none()
        && patch.network.is_none()
    {
        return Err(BulkError::Invalid);
    }
    let mut old = capture(vault, ids)?;
    if old.snapshot.revision != revision {
        return Err(BulkError::Changed);
    }
    if patch
        .group_id
        .as_ref()
        .is_some_and(|id| !old.snapshot.groups.iter().any(|g| &g.id == id))
    {
        return Err(BulkError::Invalid);
    }
    if let Some(n) = &patch.network
        && (!(1..=3600).contains(&n.timeout_seconds)
            || n.keepalive_seconds > 86400
            || !(1..=100).contains(&n.keepalive_failures)
            || n.keepalive_response_seconds
                .is_some_and(|s| !(1..=3600).contains(&s)))
    {
        return Err(BulkError::Invalid);
    }
    let mut writes = Vec::with_capacity(ids.len());
    let mut bytes = 0usize;
    for (host, before) in &mut old.hosts {
        if let Some(id) = &patch.group_id {
            host.group_id = id.clone();
        }
        if let Some(value) = patch.favorite {
            host.favorite = value;
        }
        if let Some(value) = patch.open_sftp {
            host.open_sftp = value;
        }
        if let Some(value) = patch.follow_osc7 {
            host.follow_osc7 = value;
        }
        if let Some(n) = &patch.network {
            host.use_network_defaults = n.use_defaults;
            // Inheritance only changes the switch; dormant host overrides stay
            // available if the user later explicitly switches back.
            if !n.use_defaults {
                host.timeout_seconds = n.timeout_seconds;
                host.keepalive_seconds = n.keepalive_seconds;
                host.keepalive_response_seconds = n.keepalive_response_seconds;
                host.keepalive_failures = n.keepalive_failures;
            }
        }
        host.validate()?;
        let after = encoded(host)?;
        bytes = bytes
            .checked_add(before.len())
            .and_then(|b| b.checked_add(after.len()))
            .ok_or(BulkError::Capacity)?;
        if bytes > MAX_BYTES {
            return Err(BulkError::Capacity);
        }
        writes.push(after);
    }
    let mut checks = vec![(CATALOG, old.catalog.as_deref().map(Vec::as_slice))];
    checks.extend(
        old.hosts
            .iter()
            .map(|(h, b)| (h.id.as_str(), Some(b.as_slice()))),
    );
    let operations: Vec<_> = old
        .hosts
        .iter()
        .zip(&writes)
        .filter(|((_, b), a)| b.as_slice() != a.as_slice())
        .map(|((h, _), a)| RecordChange::Put(h.id.as_str(), a))
        .collect();
    // Prepare the acknowledgement before commit. Never perform a fallible
    // reread after SQL succeeds and misreport an acknowledged mutation as failed.
    let mut hash = Sha256::new();
    hash.update(b"HSPTerm explicit host bulk v1\0");
    hash.update(scope.as_bytes());
    hash.update(Sha256::digest(
        old.catalog
            .as_deref()
            .map(Vec::as_slice)
            .unwrap_or_default(),
    ));
    for ((host, _), after) in old.hosts.iter().zip(&writes) {
        hash.update((host.id.len() as u64).to_le_bytes());
        hash.update(host.id.as_bytes());
        hash.update(Sha256::digest(after));
    }
    let result = Snapshot {
        vault_scope: scope.into(),
        revision: hash.finalize().iter().map(|b| format!("{b:02x}")).collect(),
        groups: old.snapshot.groups.clone(),
        hosts: old.hosts.iter().map(|(h, _)| project(h)).collect(),
    };
    // Compare even a no-op: a stale preview must not be acknowledged as saved.
    if !vault.apply_checked(&checks, &operations)? {
        return Err(BulkError::Changed);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn seed(v: &mut Vault) -> Vec<HostRecord> {
        (0..3)
            .map(|n| {
                let mut h = HostRecord::new(
                    format!("server-{n}"),
                    "127.0.0.1".into(),
                    "fixture".into(),
                    AuthMethod::Password,
                );
                h.note = "retained private note".into();
                Repository::new(v)
                    .save(
                        h,
                        Some(Credential {
                            secret: format!("synthetic-password-{n}"),
                            passphrase: None,
                        }),
                    )
                    .unwrap()
            })
            .collect()
    }
    #[test]
    fn explicit_fields_only_independent_credentials_and_unselected_host_unchanged() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bulk.vault");
        let mut v = Vault::create(&path, b"synthetic-master").unwrap();
        let hosts = seed(&mut v);
        let ids: Vec<_> = hosts[..2].iter().map(|h| h.id.clone()).collect();
        let s = load(&v, &ids).unwrap();
        let third = v.get(&hosts[2].id).unwrap().unwrap();
        let credentials: Vec<_> = hosts
            .iter()
            .map(|h| v.get(h.credential_id.as_ref().unwrap()).unwrap().unwrap())
            .collect();
        apply(
            &mut v,
            &s.vault_scope,
            &s.revision,
            &ids,
            Patch {
                open_sftp: Some(false),
                network: Some(NetworkPatch {
                    use_defaults: false,
                    timeout_seconds: 11,
                    keepalive_seconds: 0,
                    keepalive_response_seconds: Some(6),
                    keepalive_failures: 4,
                }),
                ..Patch::default()
            },
        )
        .unwrap();
        for h in &hosts[..2] {
            let current = Repository::new(&mut v).host(&h.id).unwrap().unwrap();
            assert!(!current.open_sftp);
            assert_eq!(current.timeout_seconds, 11);
            assert_eq!(current.keepalive_seconds, 0);
            assert_eq!(current.note, h.note);
            assert_eq!(current.address, h.address);
            assert_eq!(current.username, h.username);
            assert_eq!(current.credential_id, h.credential_id);
            assert_eq!(current.agent_forwarding, h.agent_forwarding);
        }
        assert_eq!(
            v.get(&hosts[2].id).unwrap().unwrap().as_slice(),
            third.as_slice()
        );
        for (h, c) in hosts.iter().zip(credentials) {
            assert_eq!(
                v.get(h.credential_id.as_ref().unwrap())
                    .unwrap()
                    .unwrap()
                    .as_slice(),
                c.as_slice()
            );
        }
    }
    #[test]
    fn old_scope_revision_missing_duplicate_invalid_and_sql_failure_reject_atomically() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("bulk.vault"), b"synthetic-master").unwrap();
        let hosts = seed(&mut v);
        let ids: Vec<_> = hosts.iter().map(|h| h.id.clone()).collect();
        assert!(load(&v, &[ids[0].clone(), ids[0].clone()]).is_err());
        let s = load(&v, &ids).unwrap();
        let patch = Patch {
            favorite: Some(true),
            ..Patch::default()
        };
        assert!(apply(&mut v, "foreign", &s.revision, &ids, patch.clone()).is_err());
        let invalid = Patch {
            network: Some(NetworkPatch {
                use_defaults: false,
                timeout_seconds: 0,
                keepalive_seconds: 30,
                keepalive_response_seconds: None,
                keepalive_failures: 3,
            }),
            ..Patch::default()
        };
        assert!(apply(&mut v, &s.vault_scope, &s.revision, &ids, invalid).is_err());
        v.db.execute_batch(&format!("CREATE TRIGGER fail_bulk BEFORE UPDATE ON records WHEN NEW.id='{}' BEGIN SELECT RAISE(ABORT,'synthetic bulk failure'); END;", ids.iter().max().unwrap())).unwrap();
        assert!(apply(&mut v, &s.vault_scope, &s.revision, &ids, patch.clone()).is_err());
        v.db.execute_batch("DROP TRIGGER fail_bulk;").unwrap();
        assert!(
            Repository::new(&mut v)
                .list()
                .unwrap()
                .iter()
                .all(|h| !h.favorite)
        );
        Repository::new(&mut v)
            .batch_metadata(&[ids[0].clone()], None, Some(true))
            .unwrap();
        assert!(matches!(
            apply(&mut v, &s.vault_scope, &s.revision, &ids, patch),
            Err(BulkError::Changed)
        ));
    }
    #[test]
    fn group_and_inheritance_preserve_dormant_overrides_and_unknown_fields_reject() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("bulk.vault"), b"synthetic-master").unwrap();
        let hosts = seed(&mut v);
        let ids = vec![hosts[0].id.clone()];
        let group = Repository::new(&mut v)
            .create_group("bulk group".into())
            .unwrap();
        let s = load(&v, &ids).unwrap();
        apply(
            &mut v,
            &s.vault_scope,
            &s.revision,
            &ids,
            Patch {
                group_id: Some(group.id.clone()),
                network: Some(NetworkPatch {
                    use_defaults: true,
                    timeout_seconds: 1,
                    keepalive_seconds: 0,
                    keepalive_response_seconds: None,
                    keepalive_failures: 1,
                }),
                ..Patch::default()
            },
        )
        .unwrap();
        let h = Repository::new(&mut v).host(&ids[0]).unwrap().unwrap();
        assert!(h.use_network_defaults);
        assert_eq!(h.group_id, group.id);
        assert_eq!(h.timeout_seconds, hosts[0].timeout_seconds);
        let mut raw: serde_json::Value =
            serde_json::from_slice(&v.get(&ids[0]).unwrap().unwrap()).unwrap();
        raw["future_field"] = true.into();
        v.put(&ids[0], &serde_json::to_vec(&raw).unwrap()).unwrap();
        assert!(load(&v, &ids).is_err());
    }
}
