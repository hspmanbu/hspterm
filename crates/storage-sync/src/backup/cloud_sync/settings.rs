//! Device-local encrypted target and SEPARATE authentication. No network work
//! during load/save, no passwords/tokens in metadata views, sync or backups.
use super::*;
use crate::RecordChange;
use sha2::{Digest, Sha256};

pub(in crate::backup) const CONFIG: &str = "local-cloud-sync-target-v1";
pub(in crate::backup) const SECRET: &str = "local-cloud-sync-secrets-v1";
const CONFIG_LIMIT: usize = 16 * 1024;
const SECRET_LIMIT: usize = 64 * 1024;
pub(super) const ARCHIVE_PREFIX: &str = "local-cloud-sync-ledger-archive-";
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProxyTarget {
    pub address: String,
    pub authenticate: bool,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Target {
    pub enabled: bool,
    /// Exact WebDAV HTTP(S) or Drive HTTPS object, validated against the chosen provider. Drive has
    /// explicit metadata and cannot silently be sent through the WebDAV client.
    pub endpoint: String,
    pub collection: String,
    pub authenticate: bool,
    pub timeout_seconds: u32,
    pub proxy: Option<ProxyTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drive: Option<DriveTarget>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DriveTarget {
    pub file_id: String,
    pub client_id: String,
    pub authorization_id: String,
}
impl Target {
    fn checked(mut self) -> Result<Self> {
        self.endpoint = webdav::checked_endpoint(&self.endpoint).map_err(|_| SyncError::Invalid)?;
        if let Some(drive) = &self.drive
            && (!drive_oauth::valid_client_id(&drive.client_id)
                || !opaque(&drive.authorization_id)
                || self.authenticate
                || drive_files::DriveFiles::object_endpoint(&drive.file_id)
                    .map_err(|_| SyncError::Invalid)?
                    != self.endpoint)
        {
            return Err(SyncError::Invalid);
        }
        if !opaque(&self.collection) || !(1..=300).contains(&self.timeout_seconds) {
            return Err(SyncError::Invalid);
        }
        if let Some(proxy) = &mut self.proxy {
            webdav::checked_proxy(&proxy.address).map_err(|_| SyncError::Invalid)?;
            proxy.address = reqwest::Url::parse(&proxy.address)
                .map_err(|_| SyncError::Invalid)?
                .to_string();
            if proxy.address.len() > 4096 {
                return Err(SyncError::Invalid);
            }
        }
        Ok(self)
    }
    pub fn same_object(&self, other: &Self) -> bool {
        self.endpoint == other.endpoint
            && self.collection == other.collection
            && self.drive.as_ref().map(|d| (&d.client_id, &d.file_id))
                == other.drive.as_ref().map(|d| (&d.client_id, &d.file_id))
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    target: Target,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Credential {
    username: String,
    password: String,
}
impl Drop for Credential {
    fn drop(&mut self) {
        self.username.zeroize();
        self.password.zeroize();
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Secrets {
    version: u32,
    sync_password: String,
    webdav: Option<Credential>,
    proxy: Option<Credential>,
}
impl Default for Secrets {
    fn default() -> Self {
        Self {
            version: 1,
            sync_password: String::new(),
            webdav: None,
            proxy: None,
        }
    }
}
impl Drop for Secrets {
    fn drop(&mut self) {
        self.sync_password.zeroize();
    }
}
#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum CredentialChange {
    Keep,
    Remove,
    Replace { username: String, password: String },
}
impl Drop for CredentialChange {
    fn drop(&mut self) {
        if let Self::Replace { username, password } = self {
            username.zeroize();
            password.zeroize();
        }
    }
}
impl CredentialChange {
    fn apply(&mut self, current: &mut Option<Credential>) {
        match self {
            Self::Keep => {}
            Self::Remove => *current = None,
            Self::Replace { username, password } => {
                *current = Some(Credential {
                    username: std::mem::take(username),
                    password: std::mem::take(password),
                })
            }
        }
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SecretChanges {
    pub sync_password: Option<String>,
    pub webdav: CredentialChange,
    pub proxy: CredentialChange,
}
impl Drop for SecretChanges {
    fn drop(&mut self) {
        self.sync_password.zeroize();
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Proposal {
    pub vault_scope: String,
    pub revision: String,
    pub target: Target,
    /// Some(root): derive target.collection from the normalized root and the
    /// effective sync password (new or already stored) instead of using the
    /// explicit target.collection value. None keeps stored collections.
    #[serde(default)]
    pub derive_collection: Option<String>,
    pub secrets: SecretChanges,
    pub confirm_target_change: bool,
}
#[derive(Serialize)]
pub struct View {
    pub vault_scope: String,
    pub revision: String,
    pub target: Option<Target>,
    pub sync_password_set: bool,
    pub webdav_credential_set: bool,
    pub proxy_credential_set: bool,
    pub suggested_collection: String,
    /// The stored WebDAV target's collection equals the derivation (v2:
    /// path-only) from its own endpoint root and the stored password.
    /// `false` marks a dataset from the manual/random collection era or one
    /// derived by the older full-root (v1) spec: re-saving derives the new
    /// collection, which routes through the explicit target-switch
    /// confirmation (the e32c259 legacy adoption path).
    pub collection_derived: bool,
}
fn revision(vault: &Vault, config: Option<&[u8]>, secret: Option<&[u8]>) -> String {
    let mut tag = vault.revision(b"local sync target v1");
    tag.part(config);
    tag.part(secret);
    tag.finish()
}

type Raw = Option<Zeroizing<Vec<u8>>>;
struct Read {
    config: Raw,
    secret: Raw,
    target: Option<Target>,
    secrets: Secrets,
}
fn checked_secrets(target: &Target, secret: &Secrets) -> Result<()> {
    if secret.version != 1
        || secret.sync_password.is_empty()
        || secret.sync_password.len() > 4096
        || target.authenticate != secret.webdav.is_some()
        || target.proxy.as_ref().is_some_and(|p| p.authenticate) != secret.proxy.is_some()
    {
        return Err(SyncError::Invalid);
    }
    for credential in [&secret.webdav, &secret.proxy].into_iter().flatten() {
        if !webdav::valid_auth(&credential.username, &credential.password) {
            return Err(SyncError::Invalid);
        }
    }
    if let Some(proxy) = &target.proxy
        && webdav::checked_proxy(&proxy.address).map_err(|_| SyncError::Invalid)?
        && secret.proxy.as_ref().is_some_and(|c| {
            c.username.len() > 255 || c.password.is_empty() || c.password.len() > 255
        })
    {
        return Err(SyncError::Invalid);
    }
    Ok(())
}
fn read(vault: &Vault) -> Result<Read> {
    let tx = vault
        .db
        .unchecked_transaction()
        .map_err(crate::StorageError::from)?;
    let value = read_records(vault)?;
    tx.commit().map_err(crate::StorageError::from)?;
    Ok(value)
}
fn read_records(vault: &Vault) -> Result<Read> {
    let config = vault.get_bounded(CONFIG, CONFIG_LIMIT)?;
    let secret = vault.get_bounded(SECRET, SECRET_LIMIT)?;
    let target = match &config {
        Some(raw) => {
            let stored: Stored = serde_json::from_slice(raw).map_err(|_| SyncError::Invalid)?;
            if stored.version != 1 {
                return Err(SyncError::Invalid);
            }
            Some(stored.target.checked()?)
        }
        None => None,
    };
    let secrets = secret
        .as_deref()
        .map(|b| serde_json::from_slice::<Secrets>(b))
        .transpose()
        .map_err(|_| SyncError::Invalid)?
        .unwrap_or_default();
    if target.is_none() && secret.is_some() {
        return Err(SyncError::Invalid);
    }
    if let Some(target) = &target {
        checked_secrets(target, &secrets)?;
    }
    Ok(Read {
        config,
        secret,
        target,
        secrets,
    })
}
pub(super) fn load_in_snapshot(vault: &Vault) -> Result<View> {
    Ok(view(vault, &read_records(vault)?))
}

fn view(vault: &Vault, value: &Read) -> View {
    View {
        vault_scope: vault.instance_id().into(),
        revision: revision(
            vault,
            value.config.as_deref().map(Vec::as_slice),
            value.secret.as_deref().map(Vec::as_slice),
        ),
        target: value.target.clone(),
        sync_password_set: !value.secrets.sync_password.is_empty(),
        webdav_credential_set: value.secrets.webdav.is_some(),
        proxy_credential_set: value.secrets.proxy.is_some(),
        suggested_collection: value
            .target
            .as_ref()
            .map(|t| t.collection.clone())
            .unwrap_or_else(|| format!("{:032x}", rand::random::<u128>())),
        collection_derived: value
            .target
            .as_ref()
            .is_none_or(|t| collection_is_derived(t, value.secrets.sync_password.as_bytes())),
    }
}
/// Whether the stored target's collection is the one the frozen derivation
/// (v2: path-only) produces from the target's own endpoint root and the
/// stored password.
fn collection_is_derived(target: &Target, password: &[u8]) -> bool {
    if target.drive.is_some() {
        return false;
    }
    target
        .endpoint
        .strip_suffix(webdav::DERIVED_OBJECT_PATH)
        .is_some_and(|root| {
            derived_collection(root, password).is_ok_and(|c| c == target.collection)
        })
}
pub fn load(vault: &Vault) -> Result<View> {
    Ok(view(vault, &read(vault)?))
}
/// OAuth uses the explicitly saved independent sync proxy. Unsaved form
/// values and the SSH route never silently change an authorization's route.
pub struct AuthorizationRoute {
    scope: String,
    revision: String,
    checkpoint: Checkpoint,
    proxy: Option<ProxyTarget>,
    credential: Option<Credential>,
    timeout: u32,
}
impl AuthorizationRoute {
    /// These exact route/secret rows join the account's original record in
    /// the final SQLite write transaction, closing an external-writer race.
    pub fn preconditions(&self) -> [(&str, Option<&[u8]>); 2] {
        [
            (
                CONFIG,
                self.checkpoint.config.as_deref().map(|b| b.as_slice()),
            ),
            (
                SECRET,
                self.checkpoint.secret.as_deref().map(|b| b.as_slice()),
            ),
        ]
    }
    pub fn ensure_current(&self, vault: &Vault) -> Result<()> {
        let current = load(vault)?;
        if current.vault_scope != self.scope || current.revision != self.revision {
            return Err(SyncError::Changed);
        }
        Ok(())
    }
    pub fn proxy(&self) -> Option<webdav::IndependentProxy> {
        self.proxy.as_ref().map(|p| webdav::IndependentProxy {
            address: p.address.clone(),
            username: self.credential.as_ref().map(|c| c.username.clone()),
            password: Zeroizing::new(
                self.credential
                    .as_ref()
                    .map(|c| c.password.clone())
                    .unwrap_or_default(),
            ),
        })
    }
    pub fn timeout_seconds(&self) -> u32 {
        self.timeout
    }
}
pub fn authorization_route(vault: &Vault) -> Result<AuthorizationRoute> {
    let mut value = read(vault)?;
    let metadata = view(vault, &value);
    Ok(AuthorizationRoute {
        scope: metadata.vault_scope,
        revision: metadata.revision,
        checkpoint: Checkpoint {
            config: value.config.map(Arc::new),
            secret: value.secret.map(Arc::new),
            drive_account: None,
        },
        proxy: value.target.as_ref().and_then(|t| t.proxy.clone()),
        credential: value.secrets.proxy.take(),
        timeout: value.target.as_ref().map_or(60, |t| t.timeout_seconds),
    })
}
#[derive(PartialEq, Eq)]
pub(super) struct Checkpoint {
    pub config: Option<Bytes>,
    pub secret: Option<Bytes>,
    /// Outer None: WebDAV (do not read/change any stored Drive account).
    /// Some(None): Drive whose local account is absent; never a fake login.
    pub drive_account: Option<Option<Bytes>>,
}
impl Checkpoint {
    pub(super) fn rows(&self) -> Vec<(String, Option<Bytes>)> {
        let mut rows = vec![
            (CONFIG.into(), self.config.clone()),
            (SECRET.into(), self.secret.clone()),
        ];
        if let Some(account) = &self.drive_account {
            rows.push((crate::google_drive_account::RECORD.into(), account.clone()));
        }
        rows
    }
}
pub(super) fn checkpoint(vault: &Vault) -> Result<Checkpoint> {
    let value = read(vault)?;
    let drive_account = if value.target.as_ref().is_some_and(|t| t.drive.is_some()) {
        Some(crate::google_drive_account::checkpoint(vault)?.map(Arc::new))
    } else {
        None
    };
    Ok(Checkpoint {
        config: value.config.map(Arc::new),
        secret: value.secret.map(Arc::new),
        drive_account,
    })
}
pub(super) fn archive(target: &Target) -> String {
    let mut hash = Sha256::new();
    hash.update(b"HSPTerm local cloud ledger archive v1\0");
    if let Some(drive) = &target.drive {
        hash.update(b"drive\0");
        hash.update(drive.client_id.as_bytes());
        hash.update([0]);
    }
    hash.update(target.endpoint.as_bytes());
    hash.update([0]);
    hash.update(target.collection.as_bytes());
    format!(
        "{ARCHIVE_PREFIX}{}",
        hash.finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    )
}
/// Frozen derivation spec (never change once released): the collection is the
/// first 16 bytes of SHA-256("HSPTerm collection v2\0" + path of the
/// normalized root + "\0" + sync_password) as 32 lowercase hex characters.
/// Only the normalized root's PATH participates (trailing slash appended;
/// empty path and root "/" are the same), never the scheme, host or port:
/// the same WebDAV layout (same path) with the same password is one dataset,
/// so devices that reach it through different intranet/public addresses (or
/// http vs https) sync with each other. Changing the path or the password
/// routes through the existing explicit target-switch/archive confirmation.
/// Collections derived by the frozen v1 spec (full normalized root URL) no
/// longer match this derivation: the settings view reports them as
/// non-derived and the next target save re-derives them through that same
/// explicit switch path (the e32c259 legacy-collection adoption mechanism),
/// after which the next sync adopts and rewrites the cloud object in place.
pub(in crate::backup) const COLLECTION_DERIVATION_LABEL: &[u8] = b"HSPTerm collection v2\0";
pub(in crate::backup) fn derived_collection(root: &str, password: &[u8]) -> Result<String> {
    let path = webdav::checked_root_path(root).map_err(|_| SyncError::Invalid)?;
    let mut hash = Sha256::new();
    hash.update(COLLECTION_DERIVATION_LABEL);
    hash.update(path.as_bytes());
    hash.update([0]);
    hash.update(password);
    let derived: String = hash
        .finalize()
        .iter()
        .take(16)
        .map(|b| format!("{b:02x}"))
        .collect();
    Ok(derived)
}
pub fn save(vault: &mut Vault, proposal: Proposal) -> Result<View> {
    save_inner(vault, proposal, None)
}
pub(super) fn save_created(
    vault: &mut Vault,
    proposal: Proposal,
    metadata: &[u8],
    body: &[u8],
    source_version: i64,
) -> Result<View> {
    save_inner(vault, proposal, Some((metadata, body, source_version)))
}
fn save_inner(
    vault: &mut Vault,
    mut proposal: Proposal,
    creation: Option<(&[u8], &[u8], i64)>,
) -> Result<View> {
    if vault.instance_id() != proposal.vault_scope {
        return Err(SyncError::Changed);
    }
    let observed_version = vault
        .db
        .query_row("PRAGMA data_version", [], |r| r.get(0))
        .map_err(crate::StorageError::from)?;
    let version = creation
        .as_ref()
        .map_or(observed_version, |(_, _, version)| *version);
    let mut before = read(vault)?;
    if view(vault, &before).revision != proposal.revision {
        return Err(SyncError::Changed);
    }
    // Entry normalization (single choke point for every settings entry):
    // surrounding whitespace is never part of the E2E sync password, so every
    // device derives the collection and decrypts with the same bytes. The
    // untrimmed original is zeroized immediately.
    let proposed_password = proposal.secrets.sync_password.take().map(|mut raw| {
        let trimmed = raw.trim().to_owned();
        raw.zeroize();
        Zeroizing::new(trimmed)
    });
    let mut target = proposal.target.checked()?;
    if let Some(root) = proposal.derive_collection.as_deref() {
        // Derivation is WebDAV-only and must agree with the endpoint the form
        // derived; the effective password is the new one when replaced, else
        // the already-stored one the device can still decrypt with.
        if target.drive.is_some() {
            return Err(SyncError::Invalid);
        }
        if webdav::derive_object(root).map_err(|_| SyncError::Invalid)? != target.endpoint {
            return Err(SyncError::Invalid);
        }
        let effective = proposed_password
            .as_ref()
            .map(|p| p.as_str())
            .unwrap_or(before.secrets.sync_password.as_str());
        target.collection = derived_collection(root, effective.as_bytes())?;
    }
    let drive_account = if let Some(drive) = &target.drive {
        let (account, raw) = crate::google_drive_account::capture_checkpoint(vault)?;
        let binding_matches = account.as_ref().is_some_and(|a| {
            a.client_id() == drive.client_id && a.authorization_id() == drive.authorization_id
        });
        let disabling_known =
            !target.enabled && before.target.as_ref().and_then(|t| t.drive.as_ref()) == Some(drive);
        if !binding_matches && !disabling_known {
            return Err(SyncError::Authorization);
        }
        Some(raw)
    } else {
        None
    };
    let switching = before
        .target
        .as_ref()
        .is_some_and(|t| !t.same_object(&target));
    if switching && !proposal.confirm_target_change {
        return Err(SyncError::TargetChange);
    }
    if let Some(old) = &before.target {
        let old_origin = reqwest::Url::parse(&old.endpoint)
            .map_err(|_| SyncError::Invalid)?
            .origin();
        let new_origin = reqwest::Url::parse(&target.endpoint)
            .map_err(|_| SyncError::Invalid)?
            .origin();
        if target.authenticate
            && before.secrets.webdav.is_some()
            && old_origin != new_origin
            && matches!(&proposal.secrets.webdav, CredentialChange::Keep)
        {
            return Err(SyncError::CredentialTarget);
        }
        if target.proxy.as_ref().is_some_and(|p| p.authenticate)
            && before.secrets.proxy.is_some()
            && old.proxy.as_ref().map(|p| &p.address) != target.proxy.as_ref().map(|p| &p.address)
            && matches!(&proposal.secrets.proxy, CredentialChange::Keep)
        {
            return Err(SyncError::CredentialTarget);
        }
    }
    let ledger = vault.get_bounded(LEDGER, MAX_PLAIN)?;
    if !switching
        && ledger.is_some()
        && proposed_password
            .as_ref()
            .is_some_and(|p| p.as_str() != before.secrets.sync_password)
    {
        return Err(SyncError::KeyChange);
    }
    if let Some(password) = proposed_password {
        before.secrets.sync_password.zeroize();
        before.secrets.sync_password = password.as_str().to_owned();
    }
    proposal.secrets.webdav.apply(&mut before.secrets.webdav);
    proposal.secrets.proxy.apply(&mut before.secrets.proxy);
    if !target.authenticate {
        before.secrets.webdav = None;
    }
    if target.proxy.as_ref().is_none_or(|p| !p.authenticate) {
        before.secrets.proxy = None;
    }
    checked_secrets(&target, &before.secrets)?;
    let config = Zeroizing::new(
        serde_json::to_vec(&Stored {
            version: 1,
            target: target.clone(),
        })
        .map_err(|_| SyncError::Invalid)?,
    );
    let secret =
        Zeroizing::new(serde_json::to_vec(&before.secrets).map_err(|_| SyncError::Invalid)?);
    if config.len() > CONFIG_LIMIT || secret.len() > SECRET_LIMIT {
        return Err(SyncError::Capacity);
    }
    let now = journal::now_millis()?;
    if before.target.is_none() && ledger.is_some() {
        return Err(SyncError::Changed);
    }
    let journal_before = vault.get_bounded(journal::RECORD, journal::LIMIT)?;
    let mut extra = BTreeMap::<String, Raw>::new();
    let mut expected_extra = BTreeMap::<String, Raw>::new();
    let journal_after;
    if switching {
        let old_key = archive(before.target.as_ref().expect("switch has original target"));
        let old_archive = vault.get_bounded(&old_key, MAX_PLAIN)?;
        let new_key = archive(&target);
        let new_archive = vault.get_bounded(&new_key, MAX_PLAIN)?;
        if let Some(raw) = &old_archive
            && ledger.is_some()
        {
            let archived: Ledger = serde_json::from_slice(raw).map_err(|_| SyncError::Invalid)?;
            if archived.version != 1
                || archived.document.collection
                    != before
                        .target
                        .as_ref()
                        .expect("switch has original target")
                        .collection
            {
                return Err(SyncError::Invalid);
            }
            archived.document.into_document().validate(now)?;
        }
        if old_archive.is_none() && ledger.is_some() {
            let count: i64 = vault.db.query_row("SELECT count(*) FROM (SELECT id FROM records WHERE id GLOB 'local-cloud-sync-ledger-archive-*' LIMIT 9)", [], |r| r.get(0)).map_err(crate::StorageError::from)?;
            if count >= 8 {
                return Err(SyncError::Capacity);
            }
        }
        if let Some(raw) = &new_archive {
            let archived: Ledger = serde_json::from_slice(raw).map_err(|_| SyncError::Invalid)?;
            if archived.version != 1 || archived.document.collection != target.collection {
                return Err(SyncError::Invalid);
            }
        }
        journal_after = Some(journal::rebase_record(
            vault,
            new_archive.as_deref().map(Vec::as_slice),
            now,
        )?);
        if ledger.is_some() {
            expected_extra.insert(old_key.clone(), old_archive);
            extra.insert(old_key, ledger.as_ref().map(|b| Zeroizing::new(b.to_vec())));
        }
        expected_extra.insert(
            new_key,
            new_archive.as_ref().map(|b| Zeroizing::new(b.to_vec())),
        );
        extra.insert(LEDGER.into(), new_archive);
    } else {
        journal_after = journal::initial_record(vault, now)?;
    }
    let result = View {
        vault_scope: vault.instance_id().into(),
        revision: revision(vault, Some(&config), Some(&secret)),
        target: Some(target.clone()),
        sync_password_set: true,
        webdav_credential_set: before.secrets.webdav.is_some(),
        proxy_credential_set: before.secrets.proxy.is_some(),
        suggested_collection: target.collection.clone(),
        collection_derived: collection_is_derived(&target, before.secrets.sync_password.as_bytes()),
    };
    let mut expected = vec![
        (CONFIG, before.config.as_deref().map(Vec::as_slice)),
        (SECRET, before.secret.as_deref().map(Vec::as_slice)),
        (LEDGER, ledger.as_deref().map(Vec::as_slice)),
        (
            journal::RECORD,
            journal_before.as_deref().map(Vec::as_slice),
        ),
    ];
    if let Some(account) = &drive_account {
        expected.push((
            crate::google_drive_account::RECORD,
            account.as_deref().map(Vec::as_slice),
        ));
    }
    expected.extend(
        expected_extra
            .iter()
            .map(|(id, raw)| (id.as_str(), raw.as_deref().map(Vec::as_slice))),
    );
    let mut changes = vec![
        RecordChange::Put(CONFIG, &config),
        RecordChange::Put(SECRET, &secret),
    ];
    if let Some(raw) = &journal_after {
        changes.push(RecordChange::Put(journal::RECORD, raw));
    }
    changes.extend(extra.iter().map(|(id, raw)| match raw {
        Some(raw) => RecordChange::Put(id, raw),
        None => RecordChange::Delete(id),
    }));
    if let Some((metadata, body, _)) = creation {
        expected.push((drive_setup::META, Some(metadata)));
        expected.push((drive_setup::BODY, Some(body)));
        changes.push(RecordChange::Delete(drive_setup::META));
        changes.push(RecordChange::Delete(drive_setup::BODY));
    }
    if !vault.apply_checked_data_version(&expected, &changes, version)? {
        return Err(SyncError::Changed);
    }
    journal::committed(vault.instance_id());
    Ok(result)
}

/// Native-only owned secrets. Construct the HTTP client AFTER releasing Vault
/// locks; this capability never crosses FRB or enters diagnostics.
pub struct ActiveTarget {
    target: Target,
    secrets: Secrets,
    scope: String,
    checkpoint: Checkpoint,
    drive_account: Option<crate::google_drive_account::Account>,
}
impl ActiveTarget {
    /// Freezing the HTTP capability and the local merge proposal are separate
    /// reads. An external writer between them cannot pair old endpoint/auth
    /// with a newly captured target checkpoint, even for the same collection.
    pub fn ensure_proposal(&self, proposal: &LocalProposal) -> Result<()> {
        if self.scope != proposal.scope || self.checkpoint != proposal.settings {
            return Err(SyncError::Changed);
        }
        Ok(())
    }
    pub fn ensure_current(&self, vault: &Vault) -> Result<()> {
        if self.scope != vault.instance_id() || checkpoint(vault)? != self.checkpoint {
            return Err(SyncError::Changed);
        }
        Ok(())
    }
    pub fn target(&self) -> &Target {
        &self.target
    }
    pub fn password(&self) -> &[u8] {
        self.secrets.sync_password.as_bytes()
    }
    pub fn webdav(&self) -> Result<webdav::WebDav> {
        if self.target.drive.is_some() {
            return Err(SyncError::Invalid);
        }
        webdav::WebDav::new(
            &self.target.endpoint,
            self.secrets
                .webdav
                .as_ref()
                .map(|c| webdav::Authentication {
                    username: c.username.clone(),
                    password: Zeroizing::new(c.password.clone()),
                }),
            self.target
                .proxy
                .as_ref()
                .map(|p| webdav::IndependentProxy {
                    address: p.address.clone(),
                    username: self.secrets.proxy.as_ref().map(|c| c.username.clone()),
                    password: Zeroizing::new(
                        self.secrets
                            .proxy
                            .as_ref()
                            .map(|c| c.password.clone())
                            .unwrap_or_default(),
                    ),
                }),
            self.target.timeout_seconds,
        )
        .map_err(|_| SyncError::Invalid)
    }
    pub fn proxy(&self) -> Option<webdav::IndependentProxy> {
        self.target
            .proxy
            .as_ref()
            .map(|p| webdav::IndependentProxy {
                address: p.address.clone(),
                username: self.secrets.proxy.as_ref().map(|c| c.username.clone()),
                password: Zeroizing::new(
                    self.secrets
                        .proxy
                        .as_ref()
                        .map(|c| c.password.clone())
                        .unwrap_or_default(),
                ),
            })
    }
    pub fn take_drive_account(&mut self) -> Result<crate::google_drive_account::Account> {
        self.drive_account.take().ok_or(SyncError::Authorization)
    }
    pub fn ensure_account(&self, account: &crate::google_drive_account::Account) -> Result<()> {
        if !self
            .drive_account
            .as_ref()
            .is_some_and(|captured| captured.same_source(account))
        {
            return Err(SyncError::Changed);
        }
        Ok(())
    }
    /// The account and target rows join a rotation's original-source CAS.
    pub fn target_preconditions(&self) -> [(&str, Option<&[u8]>); 2] {
        [
            (
                CONFIG,
                self.checkpoint.config.as_deref().map(|b| b.as_slice()),
            ),
            (
                SECRET,
                self.checkpoint.secret.as_deref().map(|b| b.as_slice()),
            ),
        ]
    }
}
pub fn eligible(vault: &Vault) -> Result<bool> {
    let value = load(vault)?;
    let Some(target) = value.target.filter(|t| t.enabled) else {
        return Ok(false);
    };
    let Some(drive) = target.drive else {
        return Ok(true);
    };
    let account = crate::google_drive_account::load(vault)?;
    Ok(
        account.client_id.as_deref() == Some(drive.client_id.as_str())
            && account.authorization_id.as_deref() == Some(drive.authorization_id.as_str()),
    )
}
pub fn capture(vault: &Vault, scope: &str, expected: &str) -> Result<ActiveTarget> {
    if vault.instance_id() != scope {
        return Err(SyncError::Changed);
    }
    let value = read(vault)?;
    if view(vault, &value).revision != expected {
        return Err(SyncError::Changed);
    }
    let target = value
        .target
        .filter(|t| t.enabled)
        .ok_or(SyncError::Invalid)?;
    let (drive_account, account_checkpoint) = if let Some(drive) = &target.drive {
        let (account, raw) = crate::google_drive_account::capture_checkpoint(vault)?;
        let account = account.ok_or(SyncError::Authorization)?;
        if account.client_id() != drive.client_id
            || account.authorization_id() != drive.authorization_id
        {
            return Err(SyncError::Authorization);
        }
        (Some(account), Some(raw.map(Arc::new)))
    } else {
        (None, None)
    };
    Ok(ActiveTarget {
        target,
        secrets: value.secrets,
        scope: scope.into(),
        drive_account,
        checkpoint: Checkpoint {
            config: value.config.map(Arc::new),
            secret: value.secret.map(Arc::new),
            drive_account: account_checkpoint,
        },
    })
}

#[cfg(test)]
mod tests;
