//! Explicit first publication. A generated ID and the exact encrypted body are
//! durable before POST; interruption never allocates a replacement object.
//! This local intent is excluded from cloud configuration and all backups.
use super::*;
use crate::{RecordChange, google_drive_account::Account};
use drive_files::ReservedObject;
use sha2::{Digest, Sha256};

pub(super) const META: &str = "local-google-drive-creation-v1";
pub(super) const BODY: &str = "local-google-drive-creation-body-v1";
const META_LIMIT: usize = 1024 * 1024;
#[cfg(test)]
#[path = "drive_setup_tests.rs"]
mod tests;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    id: String,
    collection: String,
    client_id: String,
    authorization_id: String,
    password: String,
    enabled: bool,
    confirmed_switch: bool,
    attempted: bool,
    bytes: usize,
    units: usize,
    digest: [u8; 32],
    config: Option<Vec<u8>>,
    secret: Option<Vec<u8>>,
}
impl Drop for Stored {
    fn drop(&mut self) {
        self.password.zeroize();
        self.config.zeroize();
        self.secret.zeroize();
    }
}
#[derive(Serialize)]
pub struct View {
    pub vault_scope: String,
    pub revision: String,
    pub id: String,
    pub collection: String,
    pub client_id: String,
    pub authorization_id: String,
    pub bytes: usize,
    pub units: usize,
    pub enabled: bool,
    pub attempted: bool,
}
pub struct Creation {
    scope: String,
    raw: Zeroizing<Vec<u8>>,
    body: Zeroizing<Vec<u8>>,
    stored: Stored,
}
fn version(v: &Vault) -> Result<i64> {
    v.db.query_row("PRAGMA data_version", [], |r| r.get(0))
        .map_err(crate::StorageError::from)
        .map_err(Into::into)
}
fn encode(stored: &Stored) -> Result<Zeroizing<Vec<u8>>> {
    let raw = Zeroizing::new(serde_json::to_vec(stored).map_err(|_| SyncError::Invalid)?);
    if raw.len() > META_LIMIT {
        return Err(SyncError::Capacity);
    }
    Ok(raw)
}
fn read(v: &Vault) -> Result<Option<Creation>> {
    let tx =
        v.db.unchecked_transaction()
            .map_err(crate::StorageError::from)?;
    let raw = v.get_bounded(META, META_LIMIT)?;
    let body = v.get_bounded(BODY, MAX_ENCRYPTED_BYTES)?;
    tx.commit().map_err(crate::StorageError::from)?;
    match (raw, body) {
        (None, None) => Ok(None),
        (Some(raw), Some(body)) => {
            let stored: Stored = serde_json::from_slice(&raw).map_err(|_| SyncError::Invalid)?;
            if stored.version != 1
                || !opaque(&stored.collection)
                || !drive_oauth::valid_client_id(&stored.client_id)
                || !opaque(&stored.authorization_id)
                || stored.password.is_empty()
                || stored.password.len() > 4096
                || stored.bytes != body.len()
                || stored.units > MAX_ITEMS
                || stored.digest != <[u8; 32]>::from(Sha256::digest(body.as_slice()))
                || stored.config.is_none() && stored.secret.is_some()
            {
                return Err(SyncError::Invalid);
            }
            ReservedObject::restore(&stored.id).map_err(|_| SyncError::Invalid)?;
            Ok(Some(Creation {
                scope: v.instance_id().into(),
                raw,
                body,
                stored,
            }))
        }
        _ => Err(SyncError::Invalid),
    }
}
pub fn load(v: &Vault) -> Result<Option<View>> {
    read(v)?.map(|c| c.view(v)).transpose()
}
pub fn capture(v: &Vault, scope: &str, revision: &str) -> Result<Creation> {
    let creation = read(v)?.ok_or(SyncError::Changed)?;
    let view = creation.view(v)?;
    if view.vault_scope != scope || view.revision != revision {
        return Err(SyncError::Changed);
    }
    Ok(creation)
}
pub fn stage(
    v: &mut Vault,
    account: &Account,
    route: &settings::AuthorizationRoute,
    reserved: ReservedObject,
    password: Zeroizing<String>,
    enabled: bool,
    confirm_switch: bool,
) -> Result<Creation> {
    let version = version(v)?;
    // Same entry normalization as the settings form: surrounding whitespace is
    // never part of the E2E password, and the first-publication body this
    // function encrypts must use exactly the bytes the target will store.
    let password = Zeroizing::new({
        let trimmed = password.trim().to_owned();
        drop(password); // zeroizes the untrimmed original
        trimmed
    });
    if read(v)?.is_some() || password.is_empty() || password.len() > 4096 {
        return Err(SyncError::Invalid);
    }
    account.ensure_current(v)?;
    route.ensure_current(v)?;
    let source = settings::load(v)?;
    if source.target.is_some() && !confirm_switch {
        return Err(SyncError::TargetChange);
    }
    let now = journal::now_millis()?;
    let collection = format!("{:032x}", rand::random::<u128>());
    let actor = format!("{:032x}", rand::random::<u128>());
    // Explicit new-collection initial snapshot. It does not re-stamp edits in
    // an existing collection or consume/acknowledge its mutation journal.
    let stamp = Stamp::next(None, &actor, now)?;
    let document = Document {
        version: 1,
        collection: collection.clone(),
        items: projection::Projection::capture(v)?
            .units
            .into_iter()
            .map(|(id, value)| Item {
                id,
                stamp: stamp.clone(),
                value: Some(value),
            })
            .collect(),
    };
    document.validate(now)?;
    let body = Zeroizing::new(document.encrypt(password.as_bytes(), now)?);
    let rows = route.preconditions();
    let stored = Stored {
        version: 1,
        id: reserved.id().into(),
        collection,
        client_id: account.client_id().into(),
        authorization_id: account.authorization_id().into(),
        password: password.to_string(),
        enabled,
        confirmed_switch: confirm_switch,
        attempted: false,
        bytes: body.len(),
        units: document.items.len(),
        digest: Sha256::digest(body.as_slice()).into(),
        config: rows[0].1.map(<[u8]>::to_vec),
        secret: rows[1].1.map(<[u8]>::to_vec),
    };
    let raw = encode(&stored)?;
    let account_raw = crate::google_drive_account::checkpoint(v)?;
    account.ensure_current(v)?;
    let mut expected = vec![
        (META, None),
        (BODY, None),
        (
            crate::google_drive_account::RECORD,
            account_raw.as_deref().map(Vec::as_slice),
        ),
    ];
    expected.extend_from_slice(&rows);
    if !v.apply_checked_data_version(
        &expected,
        &[
            RecordChange::Put(META, &raw),
            RecordChange::Put(BODY, &body),
        ],
        version,
    )? {
        return Err(SyncError::Changed);
    }
    Ok(Creation {
        scope: v.instance_id().into(),
        raw,
        body,
        stored,
    })
}
impl Creation {
    pub fn view(&self, v: &Vault) -> Result<View> {
        if self.scope != v.instance_id() {
            return Err(SyncError::Changed);
        }
        let mut tag = v.revision(b"local Drive first-publication intent v1");
        tag.part(Some(&self.raw));
        Ok(View {
            vault_scope: self.scope.clone(),
            revision: tag.finish(),
            id: self.stored.id.clone(),
            collection: self.stored.collection.clone(),
            client_id: self.stored.client_id.clone(),
            authorization_id: self.stored.authorization_id.clone(),
            bytes: self.stored.bytes,
            units: self.stored.units,
            enabled: self.stored.enabled,
            attempted: self.stored.attempted,
        })
    }
    pub fn reserved(&self) -> Result<ReservedObject> {
        ReservedObject::restore(&self.stored.id).map_err(|_| SyncError::Invalid)
    }
    pub fn collection(&self) -> &str {
        &self.stored.collection
    }
    pub fn same_ciphertext(&self, body: &[u8]) -> bool {
        self.body.as_slice() == body
    }
    fn document(&self, now: u64) -> Result<Document> {
        Document::decrypt(
            &self.body,
            self.stored.password.as_bytes(),
            &self.stored.collection,
            now,
        )
    }
    pub fn ensure_source(&self, v: &Vault, account: &Account) -> Result<()> {
        if self.scope != v.instance_id()
            || account.client_id() != self.stored.client_id
            || account.authorization_id() != self.stored.authorization_id
        {
            return Err(SyncError::Changed);
        }
        account.ensure_current(v)?;
        if v.get_bounded(META, META_LIMIT)?
            .as_deref()
            .map(Vec::as_slice)
            != Some(self.raw.as_slice())
            || v.get_bounded(BODY, MAX_ENCRYPTED_BYTES)?
                .as_deref()
                .map(Vec::as_slice)
                != Some(self.body.as_slice())
            || v.get_bounded(settings::CONFIG, META_LIMIT)?
                .as_deref()
                .map(Vec::as_slice)
                != self.stored.config.as_deref()
            || v.get_bounded(settings::SECRET, META_LIMIT)?
                .as_deref()
                .map(Vec::as_slice)
                != self.stored.secret.as_deref()
        {
            return Err(SyncError::Changed);
        }
        let document = self.document(journal::now_millis()?)?;
        if document.projection().units != projection::Projection::capture(v)?.units {
            return Err(SyncError::Changed);
        }
        Ok(())
    }
    pub fn mark_attempt(mut self, v: &mut Vault, account: &Account) -> Result<Self> {
        let version = version(v)?;
        self.ensure_source(v, account)?;
        self.stored.attempted = true;
        let raw = encode(&self.stored)?;
        if !v.apply_checked_data_version(
            &[(META, Some(&self.raw)), (BODY, Some(&self.body))],
            &[RecordChange::Put(META, &raw)],
            version,
        )? {
            return Err(SyncError::Changed);
        }
        self.raw = raw;
        Ok(self)
    }
    pub fn upload(&self, now: u64) -> Result<PendingUpload> {
        Ok(PendingUpload::initial(
            self.document(now)?,
            self.body.to_vec(),
        ))
    }
    /// Caller supplies a real exact-ID/whole-body read or create ACK. Selecting
    /// the target and retiring this intent are one SQLite transaction.
    pub fn finish(
        self,
        v: &mut Vault,
        account: &Account,
        acknowledged: &Acknowledged,
    ) -> Result<settings::View> {
        let version = version(v)?;
        self.ensure_source(v, account)?;
        if acknowledged
            .document
            .encode(journal::now_millis()?)?
            .as_slice()
            != self
                .document(journal::now_millis()?)?
                .encode(journal::now_millis()?)?
                .as_slice()
        {
            return Err(SyncError::Changed);
        }
        let source = settings::load(v)?;
        let target = settings::Target {
            enabled: self.stored.enabled,
            endpoint: drive_files::DriveFiles::object_endpoint(&self.stored.id)
                .map_err(|_| SyncError::Invalid)?,
            collection: self.stored.collection.clone(),
            authenticate: false,
            timeout_seconds: source.target.as_ref().map_or(60, |t| t.timeout_seconds),
            proxy: source.target.as_ref().and_then(|t| t.proxy.clone()),
            drive: Some(settings::DriveTarget {
                file_id: self.stored.id.clone(),
                client_id: self.stored.client_id.clone(),
                authorization_id: self.stored.authorization_id.clone(),
            }),
        };
        let proposal = settings::Proposal {
            vault_scope: source.vault_scope,
            revision: source.revision,
            target,
            derive_collection: None,
            secrets: settings::SecretChanges {
                sync_password: Some(self.stored.password.clone()),
                webdav: settings::CredentialChange::Remove,
                proxy: if source.proxy_credential_set {
                    settings::CredentialChange::Keep
                } else {
                    settings::CredentialChange::Remove
                },
            },
            confirm_target_change: self.stored.confirmed_switch,
        };
        settings::save_created(v, proposal, &self.raw, &self.body, version)
    }
}
/// Explicit local cleanup does not delete the possibly-created remote object.
/// Unknown publication is never relabeled as a successful cloud deletion.
pub fn discard(v: &mut Vault, scope: &str, revision: &str, confirm: bool) -> Result<()> {
    if !confirm {
        return Err(SyncError::Changed);
    }
    let creation = capture(v, scope, revision)?;
    if !v.apply_checked(
        &[(META, Some(&creation.raw)), (BODY, Some(&creation.body))],
        &[RecordChange::Delete(META), RecordChange::Delete(BODY)],
    )? {
        return Err(SyncError::Changed);
    }
    Ok(())
}
