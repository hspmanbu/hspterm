//! One local encrypted OAuth identity. Never part of exported/synchronized
//! application configuration. No provider email/profile scope is requested.
use crate::{
    RecordChange, StorageError, Vault,
    cloud_sync::drive_oauth::{self, DesktopClient, Grant},
};
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, Zeroizing};

pub const RECORD: &str = "local-google-drive-account-v1";
const LIMIT: usize = 48 * 1024;
type Result<T> = std::result::Result<T, StorageError>;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    authorization_id: String,
    client_id: String,
    client_secret: String,
    refresh_token: String,
}
impl Drop for Stored {
    fn drop(&mut self) {
        self.client_secret.zeroize();
        self.refresh_token.zeroize();
    }
}
impl Stored {
    fn validate(&self) -> Result<()> {
        if self.version != 1
            || self.authorization_id.len() != 32
            || !self
                .authorization_id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || !drive_oauth::valid_client_id(&self.client_id)
            || self.client_secret.len() > 4096
            || self.client_secret.chars().any(char::is_control)
            || self.refresh_token.is_empty()
            || self.refresh_token.len() > 16 * 1024
            || !self
                .refresh_token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-._~+/=".contains(&b))
        {
            return Err(StorageError::Format);
        }
        Ok(())
    }
}
#[derive(Clone, Serialize)]
pub struct View {
    pub vault_scope: String,
    pub revision: String,
    pub client_id: Option<String>,
    /// Local random authorization identity, not an OAuth code/token/account ID.
    pub authorization_id: Option<String>,
}
fn revision(vault: &Vault, raw: Option<&[u8]>) -> String {
    let mut tag = vault.revision(b"local Google Drive account v1");
    tag.part(raw);
    tag.finish()
}

type EncryptedRecord = Option<Zeroizing<Vec<u8>>>;
/// Identity of a stored account row: `(client_id, authorization_id)`. An OAuth
/// refresh-token rotation rewrites the row without changing this pair; only a
/// replacement authorization does. Cloud-sync source comparisons use this so
/// sync-managed token rotation is not misread as a local configuration change
/// (the rotation write deliberately has no journal feedback). The apply-phase
/// row CAS still compares the captured bytes.
pub(crate) fn identity(raw: &[u8]) -> Option<(String, String)> {
    serde_json::from_slice::<Stored>(raw)
        .ok()
        // Stored implements Drop (secret zeroization), so the non-secret
        // identity fields are cloned out instead of moved.
        .map(|stored| (stored.client_id.clone(), stored.authorization_id.clone()))
}
fn read(vault: &Vault) -> Result<(EncryptedRecord, Option<Stored>)> {
    let raw = vault.get_bounded(RECORD, LIMIT)?;
    let value = raw
        .as_ref()
        .map(|raw| {
            let v: Stored = serde_json::from_slice(raw).map_err(|_| StorageError::Format)?;
            v.validate()?;
            Ok::<Stored, StorageError>(v)
        })
        .transpose()?;
    Ok((raw, value))
}
pub fn load(vault: &Vault) -> Result<View> {
    let (raw, value) = read(vault)?;
    Ok(View {
        vault_scope: vault.instance_id().into(),
        revision: revision(vault, raw.as_deref().map(Vec::as_slice)),
        client_id: value.as_ref().map(|v| v.client_id.clone()),
        authorization_id: value.as_ref().map(|v| v.authorization_id.clone()),
    })
}
pub(crate) fn checkpoint(vault: &Vault) -> Result<Option<Zeroizing<Vec<u8>>>> {
    Ok(read(vault)?.0)
}
pub(crate) fn capture_checkpoint(vault: &Vault) -> Result<(Option<Account>, EncryptedRecord)> {
    let (raw, stored) = read(vault)?;
    let account = stored.map(|stored| Account {
        stored,
        source: Source {
            scope: vault.instance_id().into(),
            raw: raw.as_ref().map(|b| Zeroizing::new(b.to_vec())),
        },
    });
    Ok((account, raw))
}
/// Original source capability kept in Rust while the external browser is open.
/// The entire old record is checked, not only a displayed client ID.
pub struct Source {
    scope: String,
    raw: Option<Zeroizing<Vec<u8>>>,
}
pub fn source(vault: &Vault, scope: &str, expected: &str) -> Result<Source> {
    let (raw, _) = read(vault)?;
    if vault.instance_id() != scope
        || revision(vault, raw.as_deref().map(Vec::as_slice)) != expected
    {
        return Err(StorageError::Format);
    }
    Ok(Source {
        scope: scope.into(),
        raw,
    })
}
impl Source {
    pub fn ensure_current(&self, vault: &Vault) -> Result<()> {
        let (raw, _) = read(vault)?;
        if vault.instance_id() != self.scope || raw != self.raw {
            return Err(StorageError::Format);
        }
        Ok(())
    }
    pub fn save(
        self,
        vault: &mut Vault,
        grant: Grant,
        preconditions: &[(&str, Option<&[u8]>)],
    ) -> Result<View> {
        self.ensure_current(vault)?;
        let stored = Stored {
            version: 1,
            authorization_id: format!("{:032x}", rand::random::<u128>()),
            client_id: grant.client.client_id.clone(),
            client_secret: grant.client.client_secret.to_string(),
            refresh_token: grant.refresh_token.to_string(),
        };
        stored.validate()?;
        let raw = Zeroizing::new(serde_json::to_vec(&stored).map_err(|_| StorageError::Format)?);
        if raw.len() > LIMIT {
            return Err(StorageError::Format);
        }
        // Construct the ACK before SQL; a post-commit read failure must not
        // invite replaying the external browser flow or reusing an old grant.
        let result = View {
            vault_scope: self.scope.clone(),
            revision: revision(vault, Some(&raw)),
            client_id: Some(stored.client_id.clone()),
            authorization_id: Some(stored.authorization_id.clone()),
        };
        let mut expected = vec![(RECORD, self.raw.as_deref().map(Vec::as_slice))];
        expected.extend_from_slice(preconditions);
        if !vault.apply_checked(&expected, &[RecordChange::Put(RECORD, &raw)])? {
            return Err(StorageError::Format);
        }
        Ok(result)
    }
    pub fn remove(self, vault: &mut Vault) -> Result<View> {
        self.remove_checked(vault, &[])
    }
    pub fn remove_checked(
        self,
        vault: &mut Vault,
        preconditions: &[(&str, Option<&[u8]>)],
    ) -> Result<View> {
        self.ensure_current(vault)?;
        let result = View {
            vault_scope: self.scope.clone(),
            revision: revision(vault, None),
            client_id: None,
            authorization_id: None,
        };
        let mut expected = vec![(RECORD, self.raw.as_deref().map(Vec::as_slice))];
        expected.extend_from_slice(preconditions);
        if !vault.apply_checked(&expected, &[RecordChange::Delete(RECORD)])? {
            return Err(StorageError::Format);
        }
        Ok(result)
    }
}
pub struct Account {
    source: Source,
    stored: Stored,
}
impl Account {
    pub(crate) fn same_source(&self, other: &Self) -> bool {
        self.source.scope == other.source.scope && self.source.raw == other.source.raw
    }
    /// Persist only an actual refresh capability from this exact original
    /// client/credential. A refreshed access token is released to the caller
    /// only after local account AND route preconditions have been confirmed.
    pub fn accept_refresh(
        mut self,
        vault: &mut Vault,
        refreshed: drive_oauth::Refreshed,
        preconditions: &[(&str, Option<&[u8]>)],
    ) -> Result<(Self, drive_oauth::AccessToken)> {
        self.source.ensure_current(vault)?;
        if !refreshed.matches(&self.client(), &self.stored.refresh_token) {
            return Err(StorageError::Format);
        }
        let changed = refreshed
            .rotated_refresh_token
            .as_ref()
            .is_some_and(|t| t.as_str() != self.stored.refresh_token);
        if let Some(token) = refreshed.rotated_refresh_token {
            self.stored.refresh_token.zeroize();
            self.stored.refresh_token = token.to_string();
        }
        self.stored.validate()?;
        let raw = if changed {
            Some(Zeroizing::new(
                serde_json::to_vec(&self.stored).map_err(|_| StorageError::Format)?,
            ))
        } else {
            None
        };
        if raw.as_ref().is_some_and(|b| b.len() > LIMIT) {
            return Err(StorageError::Format);
        }
        let mut expected = vec![(RECORD, self.source.raw.as_deref().map(Vec::as_slice))];
        expected.extend_from_slice(preconditions);
        let changes = raw
            .as_ref()
            .map(|b| vec![RecordChange::Put(RECORD, b)])
            .unwrap_or_default();
        if !vault.apply_checked(&expected, &changes)? {
            return Err(StorageError::Format);
        }
        drop(changes);
        drop(expected);
        if let Some(raw) = raw {
            self.source.raw = Some(raw);
        }
        // authorization_id stays stable for token rotation, distinct from a
        // new browser authorization/account replacement. No journal feedback.
        Ok((self, refreshed.access))
    }
    pub fn client(&self) -> DesktopClient {
        DesktopClient {
            client_id: self.stored.client_id.clone(),
            client_secret: Zeroizing::new(self.stored.client_secret.clone()),
        }
    }
    pub fn client_id(&self) -> &str {
        &self.stored.client_id
    }
    pub fn refresh_token(&self) -> &str {
        &self.stored.refresh_token
    }
    pub fn authorization_id(&self) -> &str {
        &self.stored.authorization_id
    }
    pub fn ensure_current(&self, vault: &Vault) -> Result<()> {
        self.source.ensure_current(vault)
    }
    pub fn remove(self, vault: &mut Vault) -> Result<View> {
        self.source.remove(vault)
    }
    pub fn remove_checked(
        self,
        vault: &mut Vault,
        preconditions: &[(&str, Option<&[u8]>)],
    ) -> Result<View> {
        self.source.remove_checked(vault, preconditions)
    }
}
pub fn capture(vault: &Vault, scope: &str, expected: &str) -> Result<Account> {
    let source = source(vault, scope, expected)?;
    let raw = source.raw.as_ref().ok_or(StorageError::Format)?;
    let stored: Stored = serde_json::from_slice(raw).map_err(|_| StorageError::Format)?;
    stored.validate()?;
    Ok(Account { source, stored })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn account() -> Stored {
        Stored {
            version: 1,
            authorization_id: "0123456789abcdef0123456789abcdef".into(),
            client_id: "synthetic-client.apps.googleusercontent.com".into(),
            client_secret: "synthetic-client-secret".into(),
            refresh_token: "synthetic-refresh-token".into(),
        }
    }
    #[test]
    fn metadata_never_exposes_secret_and_stale_sources_cannot_delete_replacement() {
        let dir = tempfile::tempdir().unwrap();
        let mut v =
            Vault::create(&dir.path().join("oauth.vault"), b"synthetic-vault-password").unwrap();
        let empty = load(&v).unwrap();
        let old = source(&v, &empty.vault_scope, &empty.revision).unwrap();
        let raw = Zeroizing::new(serde_json::to_vec(&account()).unwrap());
        v.put(RECORD, &raw).unwrap();
        assert!(old.remove(&mut v).is_err());
        let metadata = load(&v).unwrap();
        let json = serde_json::to_string(&metadata).unwrap();
        assert!(!json.contains("synthetic-client-secret"));
        assert!(!json.contains("synthetic-refresh-token"));
        let captured = capture(&v, &metadata.vault_scope, &metadata.revision).unwrap();
        assert_eq!(captured.refresh_token(), "synthetic-refresh-token");
        let cleared = captured.remove(&mut v).unwrap();
        assert!(cleared.authorization_id.is_none());
        assert!(v.get(RECORD).unwrap().is_none());
    }
    #[test]
    fn future_formats_and_foreign_vault_fail_closed() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = Vault::create(&dir.path().join("a.vault"), b"synthetic-master").unwrap();
        let b = Vault::create(&dir.path().join("b.vault"), b"synthetic-master").unwrap();
        let view = load(&a).unwrap();
        assert!(source(&b, &view.vault_scope, &view.revision).is_err());
        let mut value = account();
        value.version = 99;
        a.put(RECORD, &serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(load(&a).is_err());
        assert!(source(&a, &view.vault_scope, &view.revision).is_err());
    }
    #[test]
    fn route_preconditions_are_compared_with_account_deletion_in_same_transaction() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("route.vault"), b"synthetic-master").unwrap();
        v.put(RECORD, &serde_json::to_vec(&account()).unwrap())
            .unwrap();
        let view = load(&v).unwrap();
        let original = capture(&v, &view.vault_scope, &view.revision).unwrap();
        let route = crate::cloud_sync::settings::authorization_route(&v).unwrap();
        // Simulate an external writer after the earlier source check. A final
        // account-only CAS would incorrectly accept this changed route.
        original.ensure_current(&v).unwrap();
        v.put("local-cloud-sync-target-v1", b"synthetic-new-route")
            .unwrap();
        assert!(
            original
                .remove_checked(&mut v, &route.preconditions())
                .is_err()
        );
        assert!(load(&v).unwrap().authorization_id.is_some());
    }
    #[test]
    fn refreshed_capability_rotates_only_original_account_and_keeps_authorization_identity() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("rotate.vault"), b"synthetic-master").unwrap();
        v.put(RECORD, &serde_json::to_vec(&account()).unwrap())
            .unwrap();
        let before = load(&v).unwrap();
        let original = capture(&v, &before.vault_scope, &before.revision).unwrap();
        let route = crate::cloud_sync::settings::authorization_route(&v).unwrap();
        let refreshed = drive_oauth::fixture_refresh(
            &original.client(),
            original.refresh_token(),
            Some("synthetic-rotated-refresh-token"),
        );
        let (current, access) = original
            .accept_refresh(&mut v, refreshed, &route.preconditions())
            .unwrap();
        assert_eq!(current.refresh_token(), "synthetic-rotated-refresh-token");
        assert!(!access.expires_within(std::time::Duration::from_secs(5)));
        current.ensure_current(&v).unwrap();
        let after = load(&v).unwrap();
        assert_eq!(before.authorization_id, after.authorization_id);
        assert_ne!(before.revision, after.revision);
        assert!(source(&v, &before.vault_scope, &before.revision).is_err());
        let unchanged =
            drive_oauth::fixture_refresh(&current.client(), current.refresh_token(), None);
        let (current, _) = current
            .accept_refresh(&mut v, unchanged, &route.preconditions())
            .unwrap();
        assert_eq!(load(&v).unwrap().revision, after.revision);
        current.ensure_current(&v).unwrap();
    }
    #[test]
    fn wrong_refresh_source_changed_route_or_failed_sql_never_replaces_local_authorization() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("reject.vault"), b"synthetic-master").unwrap();
        v.put(RECORD, &serde_json::to_vec(&account()).unwrap())
            .unwrap();
        let before = load(&v).unwrap();
        let original = capture(&v, &before.vault_scope, &before.revision).unwrap();
        let foreign = DesktopClient {
            client_id: "synthetic-other.apps.googleusercontent.com".into(),
            client_secret: Zeroizing::new(String::new()),
        };
        let wrong = drive_oauth::fixture_refresh(
            &foreign,
            original.refresh_token(),
            Some("synthetic-other-rotation"),
        );
        assert!(original.accept_refresh(&mut v, wrong, &[]).is_err());
        assert_eq!(load(&v).unwrap().revision, before.revision);
        let original = capture(&v, &before.vault_scope, &before.revision).unwrap();
        let route = crate::cloud_sync::settings::authorization_route(&v).unwrap();
        let stale = drive_oauth::fixture_refresh(
            &original.client(),
            original.refresh_token(),
            Some("synthetic-rotation"),
        );
        v.put("local-cloud-sync-target-v1", b"synthetic-changed-route")
            .unwrap();
        assert!(
            original
                .accept_refresh(&mut v, stale, &route.preconditions())
                .is_err()
        );
        assert_eq!(load(&v).unwrap().revision, before.revision);
        v.delete("local-cloud-sync-target-v1").unwrap();
        let original = capture(&v, &before.vault_scope, &before.revision).unwrap();
        let value = drive_oauth::fixture_refresh(
            &original.client(),
            original.refresh_token(),
            Some("synthetic-rotation"),
        );
        v.db.execute_batch("CREATE TRIGGER fail_rotation BEFORE INSERT ON records WHEN NEW.id='local-google-drive-account-v1' BEGIN SELECT RAISE(ABORT,'synthetic rotation failure'); END;").unwrap();
        assert!(original.accept_refresh(&mut v, value, &[]).is_err());
        assert_eq!(load(&v).unwrap().revision, before.revision);
    }
    #[test]
    fn refresh_cannot_overwrite_a_later_browser_authorization() {
        let dir = tempfile::tempdir().unwrap();
        let mut v =
            Vault::create(&dir.path().join("reauthorize.vault"), b"synthetic-master").unwrap();
        v.put(RECORD, &serde_json::to_vec(&account()).unwrap())
            .unwrap();
        let before = load(&v).unwrap();
        let original = capture(&v, &before.vault_scope, &before.revision).unwrap();
        let response = drive_oauth::fixture_refresh(
            &original.client(),
            original.refresh_token(),
            Some("synthetic-stale-rotation"),
        );
        let mut replacement = account();
        replacement.authorization_id = "b".repeat(32);
        replacement.refresh_token = "synthetic-new-browser-credential".into();
        v.put(RECORD, &serde_json::to_vec(&replacement).unwrap())
            .unwrap();
        assert!(original.accept_refresh(&mut v, response, &[]).is_err());
        let current = load(&v).unwrap();
        assert_eq!(
            current.authorization_id.as_deref(),
            Some("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        );
        assert_eq!(
            capture(&v, &current.vault_scope, &current.revision)
                .unwrap()
                .refresh_token(),
            "synthetic-new-browser-credential"
        );
    }
}
