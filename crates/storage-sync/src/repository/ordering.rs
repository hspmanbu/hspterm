//! Explicit non-secret catalog ordering, group placement and favorites.
//! No credentials/drafts are read, no SSH/network work is performed.
use super::*;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};

// Bound before+after plaintext held for the existing all-or-nothing transaction.
// Large notes cannot turn a bulk metadata action into unbounded resident data.
const MAX_MUTATION_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum OrderingError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error(transparent)]
    Repository(RepositoryError),
    #[error("主机顺序或分组配置已改变，请重新载入；没有覆盖其他配置")]
    Changed,
    #[error("主机排序数据无效或包含不支持的字段；原数据保留")]
    Format,
    #[error("主机/分组必须各出现一次，且只能修改现有主机的分组与收藏")]
    Invalid,
    #[error("所选主机配置过大，请分批修改分组或收藏；没有保存更改")]
    Capacity,
}
// Strict repository decoding may reject a future field before checked_json.
// Keep the ordering API's format error stable regardless of which guard finds it.
impl From<RepositoryError> for OrderingError {
    fn from(error: RepositoryError) -> Self {
        match error {
            RepositoryError::Format => Self::Format,
            other => Self::Repository(other),
        }
    }
}
type OrderResult<T> = std::result::Result<T, OrderingError>;

#[derive(Clone)]
pub struct Host {
    pub id: String,
    pub name: String,
    pub detail: String,
    pub group_id: String,
    pub favorite: bool,
}
#[derive(Clone)]
pub struct Snapshot {
    pub vault_scope: String,
    pub revision: String,
    pub groups: Vec<HostGroup>,
    pub hosts: Vec<Host>,
}
#[derive(Clone)]
pub struct Placement {
    pub id: String,
    pub group_id: String,
    pub favorite: bool,
}
pub struct Change {
    pub groups: Vec<String>,
    pub hosts: Vec<String>,
    pub placements: Vec<Placement>,
}
struct Captured {
    snapshot: Snapshot,
    catalog: Catalog,
    raw: Option<Zeroizing<Vec<u8>>>,
    value: Value,
    digests: BTreeMap<String, [u8; 32]>,
}
fn digest(raw: &[u8]) -> [u8; 32] {
    Sha256::digest(raw).into()
}
fn revision(
    scope: &str,
    catalog: Option<&[u8]>,
    hosts: &[String],
    digests: &BTreeMap<String, [u8; 32]>,
) -> String {
    let mut hash = Sha256::new();
    hash.update(b"HSPTerm host ordering v1\0");
    hash.update((scope.len() as u64).to_le_bytes());
    hash.update(scope.as_bytes());
    if let Some(raw) = catalog {
        hash.update([1]);
        hash.update(digest(raw));
    } else {
        hash.update([0]);
    }
    for id in hosts {
        hash.update((id.len() as u64).to_le_bytes());
        hash.update(id.as_bytes());
        hash.update(digests[id]);
    }
    hash.finalize().iter().map(|b| format!("{b:02x}")).collect()
}
// Reject unsupported fields before reconstructing JSON. Missing legacy default
// fields are allowed; no future/unknown data is silently dropped by an edit.
fn understood(value: &Value, known: &Value) -> bool {
    match (value, known) {
        (Value::Object(a), Value::Object(b)) => a
            .iter()
            .all(|(k, v)| b.get(k).is_some_and(|b| understood(v, b))),
        (Value::Array(a), Value::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(a, b)| understood(a, b))
        }
        _ => value == known,
    }
}
fn checked_json<T: Serialize>(raw: &[u8], known: &T) -> OrderResult<Value> {
    let value = serde_json::from_slice(raw).map_err(|_| OrderingError::Format)?;
    let canonical = serde_json::to_value(known).map_err(|_| OrderingError::Format)?;
    if !understood(&value, &canonical) {
        return Err(OrderingError::Format);
    }
    Ok(value)
}
fn capture(vault: &Vault) -> OrderResult<Captured> {
    let raw = vault.get_bounded(CATALOG, MAX_RECORD)?;
    let catalog: Catalog = raw
        .as_deref()
        .map(|r| decoded(r))
        .transpose()?
        .unwrap_or_default();
    if !catalog.within_limits() {
        return Err(OrderingError::Format);
    }
    let value = match &raw {
        Some(raw) => checked_json(raw, &catalog)?,
        None => serde_json::to_value(&catalog).map_err(|_| OrderingError::Format)?,
    };
    let groups: HashSet<_> = catalog.groups.iter().map(|g| g.id.as_str()).collect();
    let names: HashSet<_> = catalog.groups.iter().map(|g| g.name.as_str()).collect();
    if groups.len() != catalog.groups.len()
        || names.len() != catalog.groups.len()
        || catalog.groups.iter().any(|g| {
            (g.id != DEFAULT_GROUP && !valid_id(&g.id, "group"))
                || g.name.trim().is_empty()
                || g.name.len() > 1024
        })
    {
        return Err(OrderingError::Format);
    }
    let mut hosts = Vec::with_capacity(catalog.hosts.len());
    let mut digests = BTreeMap::new();
    for id in &catalog.hosts {
        if !valid_id(id, "host") || digests.contains_key(id) {
            return Err(OrderingError::Format);
        }
        let bytes = vault
            .get_bounded(id, MAX_RECORD)?
            .ok_or(OrderingError::Changed)?;
        let host: HostRecord = decoded(&bytes)?;
        host.validate()?;
        if host.id != *id || !groups.contains(host.group_id.as_str()) {
            return Err(OrderingError::Format);
        }
        checked_json(&bytes, &host)?;
        digests.insert(id.clone(), digest(&bytes));
        hosts.push(Host {
            id: host.id,
            name: host.name,
            detail: format!("{}@{}:{}", host.username, host.address, host.port),
            group_id: host.group_id,
            favorite: host.favorite,
        });
    }
    let snapshot = Snapshot {
        vault_scope: vault.instance_id().to_owned(),
        revision: revision(
            vault.instance_id(),
            raw.as_deref().map(Vec::as_slice),
            &catalog.hosts,
            &digests,
        ),
        groups: catalog.groups.clone(),
        hosts,
    };
    Ok(Captured {
        snapshot,
        catalog,
        raw,
        value,
        digests,
    })
}
pub fn load(vault: &Vault) -> OrderResult<Snapshot> {
    Ok(capture(vault)?.snapshot)
}
fn permutation(a: &[String], b: &[String]) -> bool {
    a.len() == b.len()
        && a.iter().collect::<HashSet<_>>() == b.iter().collect::<HashSet<_>>()
        && a.iter().collect::<HashSet<_>>().len() == a.len()
}
struct Write {
    id: String,
    before: Zeroizing<Vec<u8>>,
    after: Zeroizing<Vec<u8>>,
}
pub fn apply(
    vault: &mut Vault,
    scope: &str,
    expected: &str,
    change: Change,
) -> OrderResult<Snapshot> {
    if scope != vault.instance_id() {
        return Err(OrderingError::Changed);
    }
    if expected.len() != 64 || !expected.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(OrderingError::Changed);
    }
    if change.groups.len() > 1000 || change.hosts.len() > 10000 || change.placements.len() > 10000 {
        return Err(OrderingError::Invalid);
    }
    if change
        .groups
        .iter()
        .any(|id| id != DEFAULT_GROUP && !valid_id(id, "group"))
        || change.hosts.iter().any(|id| !valid_id(id, "host"))
        || change.placements.iter().any(|p| {
            !valid_id(&p.id, "host")
                || (p.group_id != DEFAULT_GROUP && !valid_id(&p.group_id, "group"))
        })
    {
        return Err(OrderingError::Invalid);
    }
    let mut old = capture(vault)?;
    if old.snapshot.revision != expected {
        return Err(OrderingError::Changed);
    }
    let group_ids: Vec<_> = old.catalog.groups.iter().map(|g| g.id.clone()).collect();
    let host_set: HashSet<_> = old.catalog.hosts.iter().map(String::as_str).collect();
    let group_set: HashSet<_> = group_ids.iter().map(String::as_str).collect();
    if !permutation(&change.groups, &group_ids)
        || !permutation(&change.hosts, &old.catalog.hosts)
        || change.placements.len() != host_set.len()
        || change
            .placements
            .iter()
            .map(|p| p.id.as_str())
            .collect::<HashSet<_>>()
            != host_set
        || change
            .placements
            .iter()
            .any(|p| !group_set.contains(p.group_id.as_str()))
    {
        return Err(OrderingError::Invalid);
    }
    let placements: BTreeMap<_, _> = change
        .placements
        .into_iter()
        .map(|p| (p.id.clone(), p))
        .collect();
    let mut writes = Vec::new();
    let mut bytes = 0usize;
    for host in &mut old.snapshot.hosts {
        let p = &placements[&host.id];
        if p.group_id == host.group_id && p.favorite == host.favorite {
            continue;
        }
        let before = vault
            .get_bounded(&host.id, MAX_RECORD)?
            .ok_or(OrderingError::Changed)?;
        if digest(&before) != old.digests[&host.id] {
            return Err(OrderingError::Changed);
        }
        let mut value: Value =
            serde_json::from_slice(&before).map_err(|_| OrderingError::Format)?;
        let object = value.as_object_mut().ok_or(OrderingError::Format)?;
        object.insert("group_id".into(), Value::String(p.group_id.clone()));
        object.insert("favorite".into(), Value::Bool(p.favorite));
        let after = Zeroizing::new(serde_json::to_vec(&value).map_err(|_| OrderingError::Format)?);
        bytes = bytes
            .checked_add(before.len())
            .and_then(|n| n.checked_add(after.len()))
            .ok_or(OrderingError::Capacity)?;
        if bytes > MAX_MUTATION_BYTES || after.len() > MAX_RECORD {
            return Err(OrderingError::Capacity);
        }
        host.group_id = p.group_id.clone();
        host.favorite = p.favorite;
        old.digests.insert(host.id.clone(), digest(&after));
        writes.push(Write {
            id: host.id.clone(),
            before,
            after,
        });
    }
    let catalog_changed = change.groups != group_ids || change.hosts != old.catalog.hosts;
    let candidate = if catalog_changed {
        let mut groups: BTreeMap<_, _> = old.value["groups"]
            .as_array()
            .ok_or(OrderingError::Format)?
            .iter()
            .map(|g| {
                Ok((
                    g["id"].as_str().ok_or(OrderingError::Format)?.to_owned(),
                    g.clone(),
                ))
            })
            .collect::<OrderResult<_>>()?;
        old.value["groups"] = Value::Array(
            change
                .groups
                .iter()
                .map(|id| groups.remove(id).ok_or(OrderingError::Format))
                .collect::<OrderResult<_>>()?,
        );
        old.value["hosts"] =
            serde_json::to_value(&change.hosts).map_err(|_| OrderingError::Format)?;
        let candidate =
            Zeroizing::new(serde_json::to_vec(&old.value).map_err(|_| OrderingError::Format)?);
        if candidate.len() > MAX_RECORD {
            return Err(OrderingError::Capacity);
        }
        Some(candidate)
    } else {
        None
    };
    let mut checks = vec![(CATALOG, old.raw.as_deref().map(Vec::as_slice))];
    checks.extend(
        writes
            .iter()
            .map(|w| (w.id.as_str(), Some(w.before.as_slice()))),
    );
    let mut operations = Vec::new();
    if let Some(raw) = &candidate {
        operations.push(RecordChange::Put(CATALOG, raw));
    }
    operations.extend(writes.iter().map(|w| RecordChange::Put(&w.id, &w.after)));
    if !operations.is_empty() && !vault.apply_checked(&checks, &operations)? {
        return Err(OrderingError::Changed);
    }
    let mut groups: BTreeMap<_, _> = old
        .snapshot
        .groups
        .into_iter()
        .map(|g| (g.id.clone(), g))
        .collect();
    let mut hosts: BTreeMap<_, _> = old
        .snapshot
        .hosts
        .into_iter()
        .map(|h| (h.id.clone(), h))
        .collect();
    Ok(Snapshot {
        vault_scope: scope.to_owned(),
        revision: revision(
            scope,
            candidate
                .as_ref()
                .or(old.raw.as_ref())
                .map(|r| r.as_slice()),
            &change.hosts,
            &old.digests,
        ),
        groups: change
            .groups
            .iter()
            .map(|id| groups.remove(id).ok_or(OrderingError::Format))
            .collect::<OrderResult<_>>()?,
        hosts: change
            .hosts
            .iter()
            .map(|id| hosts.remove(id).ok_or(OrderingError::Format))
            .collect::<OrderResult<_>>()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn seed(v: &mut Vault, count: usize, note: &str) -> Vec<HostRecord> {
        let mut repo = Repository::new(v);
        let group = repo.create_group("Development".into()).unwrap();
        repo.create_group("Production".into()).unwrap();
        (0..count)
            .map(|i| {
                let mut h = HostRecord::new(
                    format!("Fixture {i}"),
                    "fixture.invalid".into(),
                    "fixture".into(),
                    AuthMethod::Password,
                );
                h.note = note.into();
                if i % 2 == 0 {
                    h.group_id = group.id.clone();
                }
                h.favorite = i == 0;
                repo.save(
                    h,
                    Some(Credential {
                        secret: format!("synthetic-order-{i}"),
                        passphrase: None,
                    }),
                )
                .unwrap()
            })
            .collect()
    }
    fn unchanged(s: &Snapshot) -> Change {
        Change {
            groups: s.groups.iter().map(|g| g.id.clone()).collect(),
            hosts: s.hosts.iter().map(|h| h.id.clone()).collect(),
            placements: s
                .hosts
                .iter()
                .map(|h| Placement {
                    id: h.id.clone(),
                    group_id: h.group_id.clone(),
                    favorite: h.favorite,
                })
                .collect(),
        }
    }
    #[test]
    fn atomic_order_groups_favorites_and_reopen_preserve_credentials_drafts_and_other_fields() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("order.vault");
        let mut v = Vault::create(&path, b"synthetic-order-master").unwrap();
        let hosts = seed(&mut v, 3, "preserved synthetic metadata");
        let draft = Repository::new(&mut v).copy_to_draft(&hosts[0].id).unwrap();
        let draft_key = format!("draft-{}", draft.id);
        let draft_before = v.get(&draft_key).unwrap().unwrap();
        let credentials: Vec<_> = hosts
            .iter()
            .map(|h| v.get(h.credential_id.as_ref().unwrap()).unwrap().unwrap())
            .collect();
        let before: Vec<_> = hosts
            .iter()
            .map(|h| v.get(&h.id).unwrap().unwrap())
            .collect();
        let s = load(&v).unwrap();
        let mut c = unchanged(&s);
        c.groups.reverse();
        c.hosts.reverse();
        c.placements[0].group_id = s.groups[2].id.clone();
        c.placements[0].favorite = false;
        c.placements[1].favorite = true;
        let result = apply(&mut v, &s.vault_scope, &s.revision, c).unwrap();
        assert_eq!(result.revision, load(&v).unwrap().revision);
        assert_eq!(
            result
                .hosts
                .iter()
                .map(|h| h.id.as_str())
                .collect::<Vec<_>>(),
            hosts
                .iter()
                .rev()
                .map(|h| h.id.as_str())
                .collect::<Vec<_>>()
        );
        assert_eq!(result.groups[0].id, s.groups[2].id);
        for (i, h) in hosts.iter().enumerate() {
            let mut old: Value = serde_json::from_slice(&before[i]).unwrap();
            let mut after: Value = serde_json::from_slice(&v.get(&h.id).unwrap().unwrap()).unwrap();
            for key in ["group_id", "favorite"] {
                old.as_object_mut().unwrap().remove(key);
                after.as_object_mut().unwrap().remove(key);
            }
            assert_eq!(old, after);
            assert_eq!(
                v.get(h.credential_id.as_ref().unwrap())
                    .unwrap()
                    .unwrap()
                    .as_slice(),
                credentials[i].as_slice()
            );
        }
        assert_eq!(
            v.get(&hosts[2].id).unwrap().unwrap().as_slice(),
            before[2].as_slice()
        );
        assert_eq!(
            v.get(&draft_key).unwrap().unwrap().as_slice(),
            draft_before.as_slice()
        );
        drop(v);
        let mut v = Vault::open(&path, b"synthetic-order-master").unwrap();
        let fresh = load(&v).unwrap();
        assert_eq!(fresh.hosts[0].id, hosts[2].id);
        assert_ne!(fresh.vault_scope, s.vault_scope);
        assert!(matches!(
            apply(&mut v, &s.vault_scope, &s.revision, unchanged(&s)),
            Err(OrderingError::Changed)
        ));
        assert!(matches!(
            apply(&mut v, &fresh.vault_scope, &s.revision, unchanged(&fresh)),
            Err(OrderingError::Changed)
        ));
    }
    #[test]
    fn stale_snapshots_duplicates_unknown_groups_and_unsupported_fields_never_overwrite_data() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("stale.vault");
        let mut v = Vault::create(&path, b"synthetic-order-stale").unwrap();
        let hosts = seed(&mut v, 3, "");
        let s = load(&v).unwrap();
        let mut other = Vault::open(&path, b"synthetic-order-stale").unwrap();
        let mut h = Repository::new(&mut other)
            .host(&hosts[0].id)
            .unwrap()
            .unwrap();
        h.note = "another writer's current metadata".into();
        Repository::new(&mut other).save(h, None).unwrap();
        let mut c = unchanged(&s);
        c.hosts.reverse();
        assert!(matches!(
            apply(&mut v, &s.vault_scope, &s.revision, c),
            Err(OrderingError::Changed)
        ));
        assert_eq!(
            Repository::new(&mut v)
                .host(&hosts[0].id)
                .unwrap()
                .unwrap()
                .note,
            "another writer's current metadata"
        );
        let s = load(&v).unwrap();
        let before = v.get(CATALOG).unwrap().unwrap();
        let mut c = unchanged(&s);
        c.hosts[0] = c.hosts[1].clone();
        assert!(matches!(
            apply(&mut v, &s.vault_scope, &s.revision, c),
            Err(OrderingError::Invalid)
        ));
        let mut c = unchanged(&s);
        c.groups.remove(0);
        assert!(apply(&mut v, &s.vault_scope, &s.revision, c).is_err());
        let mut c = unchanged(&s);
        c.placements[0].group_id = "group-11111111111111111111111111111111".into();
        assert!(apply(&mut v, &s.vault_scope, &s.revision, c).is_err());
        let mut c = unchanged(&s);
        c.placements[0].id = c.placements[1].id.clone();
        assert!(apply(&mut v, &s.vault_scope, &s.revision, c).is_err());
        assert_eq!(
            v.get(CATALOG).unwrap().unwrap().as_slice(),
            before.as_slice()
        );
        let key = &hosts[0].id;
        let mut future: Value = serde_json::from_slice(&v.get(key).unwrap().unwrap()).unwrap();
        future["future_feature"] = serde_json::json!({"preserved":"future synthetic metadata"});
        let future = serde_json::to_vec(&future).unwrap();
        v.put(key, &future).unwrap();
        assert!(matches!(load(&v), Err(OrderingError::Format)));
        assert!(apply(&mut v, &s.vault_scope, &s.revision, unchanged(&s)).is_err());
        assert_eq!(v.get(key).unwrap().unwrap().as_slice(), future.as_slice());
    }
    #[test]
    fn transaction_failure_rolls_back_catalog_and_earlier_hosts_then_allows_explicit_retry() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(
            &dir.path().join("rollback.vault"),
            b"synthetic-order-rollback",
        )
        .unwrap();
        let hosts = seed(&mut v, 3, "");
        let s = load(&v).unwrap();
        let before = v.get(CATALOG).unwrap().unwrap();
        let raw: Vec<_> = hosts
            .iter()
            .map(|h| v.get(&h.id).unwrap().unwrap())
            .collect();
        v.db.execute_batch(&format!("CREATE TRIGGER reject_order BEFORE UPDATE ON records WHEN NEW.id='{}' BEGIN SELECT RAISE(ABORT,'synthetic ordering failure'); END;",hosts[1].id)).unwrap();
        let change = || {
            let mut c = unchanged(&s);
            c.hosts.reverse();
            for p in &mut c.placements {
                p.favorite = !p.favorite;
            }
            c
        };
        assert!(matches!(
            apply(&mut v, &s.vault_scope, &s.revision, change()),
            Err(OrderingError::Storage(_))
        ));
        assert_eq!(
            v.get(CATALOG).unwrap().unwrap().as_slice(),
            before.as_slice()
        );
        for (i, h) in hosts.iter().enumerate() {
            assert_eq!(v.get(&h.id).unwrap().unwrap().as_slice(), raw[i].as_slice());
        }
        assert_eq!(
            apply(&mut v, &s.vault_scope, &s.revision, unchanged(&s))
                .unwrap()
                .revision,
            s.revision
        );
        v.db.execute_batch("DROP TRIGGER reject_order;").unwrap();
        let result = apply(&mut v, &s.vault_scope, &s.revision, change()).unwrap();
        assert_eq!(result.revision, load(&v).unwrap().revision);
    }
    #[test]
    fn large_bulk_edit_fails_before_any_publication_but_sorting_still_works() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(
            &dir.path().join("capacity.vault"),
            b"synthetic-order-capacity",
        )
        .unwrap();
        let hosts = seed(&mut v, 70, &"n".repeat(65_000));
        let s = load(&v).unwrap();
        let before = v.get(CATALOG).unwrap().unwrap();
        let mut c = unchanged(&s);
        for p in &mut c.placements {
            p.favorite = !p.favorite;
        }
        assert!(matches!(
            apply(&mut v, &s.vault_scope, &s.revision, c),
            Err(OrderingError::Capacity)
        ));
        assert_eq!(
            v.get(CATALOG).unwrap().unwrap().as_slice(),
            before.as_slice()
        );
        assert!(
            Repository::new(&mut v)
                .host(&hosts[0].id)
                .unwrap()
                .unwrap()
                .favorite
        );
        assert!(
            !Repository::new(&mut v)
                .host(&hosts[69].id)
                .unwrap()
                .unwrap()
                .favorite
        );
        let mut c = unchanged(&s);
        c.hosts.reverse();
        let result = apply(&mut v, &s.vault_scope, &s.revision, c).unwrap();
        assert_eq!(result.hosts[0].id, hosts[69].id);
    }
}
