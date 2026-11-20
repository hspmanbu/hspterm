//! Device-local old-object baselines. Explicit cleanup never sends HTTP,
//! deletes an active baseline, or returns any configuration/credential body.
use super::*;
use crate::RecordChange;
use sha2::{Digest, Sha256};

#[derive(Clone, Serialize)]
pub struct Item {
    pub id: String,
    pub collection: String,
    pub units: usize,
    pub tombstones: usize,
    pub active: bool,
}
#[derive(Serialize)]
pub struct View {
    pub vault_scope: String,
    pub revision: String,
    pub items: Vec<Item>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Removal {
    pub vault_scope: String,
    pub revision: String,
    pub ids: Vec<String>,
    pub confirm_local_baseline_loss: bool,
}
struct Snapshot {
    scope: String,
    settings: String,
    items: Vec<(Item, String)>,
}
impl Snapshot {
    fn view(&self) -> View {
        let mut hash = Sha256::new();
        hash.update(b"HSPTerm local cloud archive metadata v1\0");
        hash.update(self.scope.as_bytes());
        hash.update(self.settings.as_bytes());
        for (item, digest) in &self.items {
            hash.update(item.id.as_bytes());
            hash.update(digest.as_bytes());
        }
        View {
            vault_scope: self.scope.clone(),
            revision: hash.finalize().iter().map(|b| format!("{b:02x}")).collect(),
            items: self.items.iter().map(|(i, _)| i.clone()).collect(),
        }
    }
}
fn read(vault: &Vault) -> Result<Snapshot> {
    let now = journal::now_millis()?;
    let tx = vault
        .db
        .unchecked_transaction()
        .map_err(crate::StorageError::from)?;
    let settings = settings::load_in_snapshot(vault)?;
    let ids = {
        let mut query = vault.db.prepare("SELECT id FROM records WHERE id GLOB 'local-cloud-sync-ledger-archive-*' ORDER BY id LIMIT 9")
            .map_err(crate::StorageError::from)?;
        query
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(crate::StorageError::from)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(crate::StorageError::from)?
    };
    if ids.len() > 8 {
        return Err(SyncError::Capacity);
    }
    let active = settings.target.as_ref().map(settings::archive);
    let mut items = Vec::new();
    for id in ids {
        let suffix = id
            .strip_prefix(settings::ARCHIVE_PREFIX)
            .ok_or(SyncError::Invalid)?;
        if suffix.len() != 64
            || !suffix
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(SyncError::Invalid);
        }
        let raw = vault
            .get_bounded(&id, MAX_PLAIN)?
            .ok_or(SyncError::Changed)?;
        let ledger: Ledger = serde_json::from_slice(&raw).map_err(|_| SyncError::Invalid)?;
        if ledger.version != 1
            || !opaque(&ledger.actor)
            || ledger
                .etag
                .as_deref()
                .is_some_and(|e| EntityTag::parse(e).is_err())
        {
            return Err(SyncError::Invalid);
        }
        let document = ledger.document.into_document();
        document.validate(now)?;
        let item = Item {
            active: active.as_ref() == Some(&id),
            id,
            collection: document.collection.clone(),
            units: document.items.len(),
            tombstones: document.items.iter().filter(|i| i.value.is_none()).count(),
        };
        let mut tag = vault.revision(b"local cloud archive record v1");
        tag.part(Some(item.id.as_bytes()));
        tag.part(Some(raw.as_slice()));
        items.push((item, tag.finish()));
        // Drop each decrypted archive before reading the next; do not retain
        // eight full credential-bearing documents just to display eight rows.
    }
    tx.commit().map_err(crate::StorageError::from)?;
    Ok(Snapshot {
        scope: vault.instance_id().into(),
        settings: settings.revision,
        items,
    })
}
pub fn load(vault: &Vault) -> Result<View> {
    Ok(read(vault)?.view())
}
/// Whether this device holds a baseline (active ledger or an archived target
/// baseline) whose document was created under the given collection — proof it
/// previously synchronized that dataset identifier. Used to gate first-contact
/// adoption of a legacy-identifier cloud object; any read/parse problem means
/// `false` (no adoption, the caller reports the legacy state instead).
pub fn known_collection(vault: &Vault, collection: &str) -> bool {
    if !opaque(collection) {
        return false;
    }
    let matches = |raw: Option<Zeroizing<Vec<u8>>>| {
        raw.as_deref().is_some_and(|bytes| {
            serde_json::from_slice::<Ledger>(bytes)
                .is_ok_and(|ledger| ledger.document.collection == collection)
        })
    };
    if vault
        .get_bounded(LEDGER, MAX_PLAIN)
        .map(matches)
        .unwrap_or(false)
    {
        return true;
    }
    let Ok(ids) = (|| {
        let mut query = vault
            .db
            .prepare(
                "SELECT id FROM records WHERE id GLOB 'local-cloud-sync-ledger-archive-*' ORDER BY id LIMIT 8",
            )
            .map_err(crate::StorageError::from)?;
        query
            .query_map([], |r| r.get::<_, String>(0))
            .map(|rows| rows.collect::<std::result::Result<Vec<_>, _>>())
            .map_err(crate::StorageError::from)?
            .map_err(crate::StorageError::from)
    })() else {
        return false;
    };
    ids.iter().any(|id| {
        vault
            .get_bounded(id, MAX_PLAIN)
            .map(matches)
            .unwrap_or(false)
    })
}
pub fn remove(vault: &mut Vault, removal: Removal) -> Result<View> {
    if !removal.confirm_local_baseline_loss
        || removal.ids.is_empty()
        || removal.ids.len() > 8
        || vault.instance_id() != removal.vault_scope
    {
        return Err(SyncError::Changed);
    }
    // Exclusive &mut Vault plus data_version checked under IMMEDIATE covers
    // both local and external writers without retaining all plaintext records.
    let version = vault
        .db
        .query_row("PRAGMA data_version", [], |r| r.get(0))
        .map_err(crate::StorageError::from)?;
    let mut snapshot = read(vault)?;
    if snapshot.view().revision != removal.revision {
        return Err(SyncError::Changed);
    }
    let ids: std::collections::BTreeSet<_> = removal.ids.iter().collect();
    if ids.len() != removal.ids.len()
        || ids.iter().any(|id| {
            !snapshot
                .items
                .iter()
                .any(|(i, _)| &i.id == *id && !i.active)
        })
    {
        return Err(SyncError::Changed);
    }
    snapshot.items.retain(|(i, _)| !ids.contains(&i.id));
    let result = snapshot.view();
    let changes = removal
        .ids
        .iter()
        .map(|id| RecordChange::Delete(id))
        .collect::<Vec<_>>();
    if !vault.apply_checked_data_version(&[], &changes, version)? {
        return Err(SyncError::Changed);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(v: &mut Vault, suffix: char) -> String {
        let id = format!(
            "{}{}",
            settings::ARCHIVE_PREFIX,
            suffix.to_string().repeat(64)
        );
        let doc = Document::empty("0123456789abcdef0123456789abcdef").unwrap();
        let raw = json(&LedgerRef {
            version: 1,
            actor: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            etag: Some("\"synthetic-etag\""),
            document: doc.serializable(),
        })
        .unwrap();
        v.put(&id, &raw).unwrap();
        id
    }
    fn removal(view: &View, ids: Vec<String>) -> Removal {
        Removal {
            vault_scope: view.vault_scope.clone(),
            revision: view.revision.clone(),
            ids,
            confirm_local_baseline_loss: true,
        }
    }
    #[test]
    fn deletion_requires_original_revision_and_confirmation_and_returns_exact_ack() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("archive.vault"), b"synthetic-master").unwrap();
        let first = fixture(&mut v, 'a');
        let second = fixture(&mut v, 'b');
        let old = load(&v).unwrap();
        assert_eq!(old.items.len(), 2);
        let mut unconfirmed = removal(&old, vec![first.clone()]);
        unconfirmed.confirm_local_baseline_loss = false;
        assert!(remove(&mut v, unconfirmed).is_err());
        assert!(remove(&mut v, removal(&old, vec![first.clone(), first.clone()])).is_err());
        let saved = remove(&mut v, removal(&old, vec![first.clone()])).unwrap();
        assert_eq!(saved.items.len(), 1);
        assert_eq!(saved.items[0].id, second);
        assert_eq!(saved.revision, load(&v).unwrap().revision);
        assert!(v.get(&first).unwrap().is_none());
        assert!(remove(&mut v, removal(&old, vec![second.clone()])).is_err());
        assert!(v.get(&second).unwrap().is_some());
        let text = serde_json::to_string(&saved).unwrap();
        assert!(!text.contains("synthetic-etag"));
        assert!(!text.contains("document"));
    }
    #[test]
    fn corrupt_future_or_excess_archives_are_not_silently_removed_or_hidden() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("corrupt.vault"), b"synthetic-master").unwrap();
        let id = fixture(&mut v, 'a');
        let old = load(&v).unwrap();
        v.put(&id, br#"{"version":99}"#).unwrap();
        assert!(load(&v).is_err());
        assert!(remove(&mut v, removal(&old, vec![id.clone()])).is_err());
        assert!(v.get(&id).unwrap().is_some());
        fixture(&mut v, 'a');
        for suffix in 'b'..='i' {
            fixture(&mut v, suffix);
        }
        // g/h/i aren't hex and fail the format too; count is rejected first.
        assert!(matches!(load(&v), Err(SyncError::Capacity)));
    }
    #[test]
    fn active_target_archive_is_readable_but_cannot_be_deleted() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("active.vault"), b"synthetic-master").unwrap();
        let source = settings::load(&v).unwrap();
        let proposal = serde_json::from_value::<settings::Proposal>(serde_json::json!({
            "vault_scope": source.vault_scope, "revision": source.revision,
            "target": { "enabled": true, "endpoint": "https://synthetic.invalid/config", "collection": "0123456789abcdef0123456789abcdef", "authenticate": false, "timeout_seconds": 60, "proxy": null },
            "secrets": { "sync_password": "synthetic-sync-password", "webdav": { "action": "remove" }, "proxy": { "action": "remove" } }, "confirm_target_change": false,
        })).unwrap();
        let target = settings::save(&mut v, proposal).unwrap().target.unwrap();
        let original = fixture(&mut v, 'a');
        let key = settings::archive(&target);
        let raw = v.get(&original).unwrap().unwrap();
        v.put(&key, &raw).unwrap();
        let view = load(&v).unwrap();
        assert!(view.items.iter().find(|i| i.id == key).unwrap().active);
        assert!(remove(&mut v, removal(&view, vec![key.clone()])).is_err());
        assert!(v.get(&key).unwrap().is_some());
    }
}
