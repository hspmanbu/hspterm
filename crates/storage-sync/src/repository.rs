//! Encrypted host catalog, independent credentials and recoverable local drafts.
//! No remote/network actions and no plaintext payload diagnostics.
use crate::ssh_proxy::{ProxyCredential, ProxySettings};
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use zeroize::{Zeroize, Zeroizing};

pub mod bulk;
mod import;
#[cfg(test)]
mod integration_tests;
mod metadata;
pub use metadata::{CatalogMetadata, DraftMetadata};
pub mod ordering;

const CATALOG: &str = "host-catalog-v1";
const DEFAULT_GROUP: &str = "group-default";
const MAX_RECORD: usize = 2 * 1024 * 1024;

#[derive(Error, Debug)]
pub enum RepositoryError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("主机或分组配置无效")]
    Invalid,
    #[error("主机或分组已不存在")]
    Missing,
    #[error("请明确提供所选认证方式的凭据")]
    CredentialRequired,
    #[error("导入名称已存在或配置已改变，请重新预览；没有覆盖任何主机")]
    ImportConflict,
    #[error("加密主机记录格式无效或版本不受支持")]
    Format,
    #[error("跳板主机已删除或尚未正式保存，请重新选择；未改为直连")]
    JumpMissing,
    #[error("仅支持一级跳板，不能选择自身或含跳板的主机")]
    JumpInvalid,
    #[error("整条连接只允许一个代理，请明确移除目标或跳板中的一个代理配置")]
    JumpProxyConflict,
}
type Result<T> = std::result::Result<T, RepositoryError>;

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AuthMethod {
    Password,
    PrivateKey,
}

/// Secret-bearing values have no Debug implementation and zeroize on drop.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Credential {
    pub secret: String,
    pub passphrase: Option<String>,
}
impl Drop for Credential {
    fn drop(&mut self) {
        self.secret.zeroize();
        self.passphrase.zeroize();
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostRecord {
    pub id: String,
    pub name: String,
    pub address: String,
    pub port: u16,
    pub username: String,
    pub auth: AuthMethod,
    pub group_id: String,
    pub favorite: bool,
    pub note: String,
    pub credential_id: Option<String>,
    pub timeout_seconds: u32,
    pub keepalive_seconds: u32,
    pub keepalive_failures: u32,
    #[serde(default)]
    pub use_network_defaults: bool,
    #[serde(default)]
    pub keepalive_response_seconds: Option<u32>,
    pub open_sftp: bool,
    #[serde(default)]
    pub follow_osc7: bool,
    #[serde(default)]
    pub proxy: Option<ProxySettings>,
    #[serde(default)]
    pub jump_host_id: Option<String>,
    #[serde(default)]
    pub agent_forwarding: bool,
    #[serde(default)]
    pub tmux_enabled: bool,
    /// Explicit per-host consent; a copied host must opt in again.
    #[serde(default)]
    pub shell_integration: bool,
}
impl HostRecord {
    pub fn new(name: String, address: String, username: String, auth: AuthMethod) -> Self {
        Self {
            id: opaque("host"),
            name,
            address,
            port: 22,
            username,
            auth,
            group_id: DEFAULT_GROUP.into(),
            favorite: false,
            note: String::new(),
            credential_id: None,
            timeout_seconds: 30,
            keepalive_seconds: 30,
            keepalive_failures: 3,
            use_network_defaults: false,
            keepalive_response_seconds: None,
            open_sftp: true,
            follow_osc7: false,
            proxy: None,
            jump_host_id: None,
            agent_forwarding: false,
            tmux_enabled: false,
            shell_integration: false,
        }
    }
    pub(crate) fn validate(&self) -> Result<()> {
        if !valid_id(&self.id, "host")
            || self.name.trim().is_empty()
            || self.name.len() > 1024
            || self.address.is_empty()
            || self.address.len() > 1024
            || self.address.chars().any(char::is_whitespace)
            || self.address.chars().any(char::is_control)
            || self.username.is_empty()
            || self.username.len() > 1024
            || self.username.chars().any(char::is_control)
            || self.port == 0
            || self.note.len() > 65536
            || !(1..=3600).contains(&self.timeout_seconds)
            || self.keepalive_seconds > 86400
            || !(1..=100).contains(&self.keepalive_failures)
            || self
                .keepalive_response_seconds
                .is_some_and(|seconds| !(1..=3600).contains(&seconds))
            || self.proxy.as_ref().is_some_and(|p| !p.valid(&self.address))
        {
            return Err(RepositoryError::Invalid);
        }
        Ok(())
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostGroup {
    pub id: String,
    pub name: String,
}
#[derive(Serialize, Deserialize)]
pub struct HostDraft {
    pub host: HostRecord,
    pub credential: Option<Credential>,
    #[serde(default)]
    pub proxy_credential: Option<ProxyCredential>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Catalog {
    pub(crate) version: u32,
    pub(crate) hosts: Vec<String>,
    pub(crate) groups: Vec<HostGroup>,
    pub(crate) drafts: Vec<String>,
}
impl Default for Catalog {
    fn default() -> Self {
        Self {
            version: 1,
            hosts: vec![],
            groups: vec![HostGroup {
                id: DEFAULT_GROUP.into(),
                name: "未分组".into(),
            }],
            drafts: vec![],
        }
    }
}
impl Catalog {
    pub(crate) fn within_limits(&self) -> bool {
        self.version == 1
            && self.hosts.len() <= 10000
            && self.drafts.len() <= 10000
            && self.groups.len() <= 1000
            && self.groups.iter().any(|g| g.id == DEFAULT_GROUP)
    }
    fn encoded(&self) -> Result<Zeroizing<Vec<u8>>> {
        if !self.within_limits() {
            return Err(RepositoryError::Invalid);
        }
        encoded(self)
    }
}
fn forwarding_error(error: crate::forwarding_rules::ForwardingError) -> RepositoryError {
    match error {
        crate::forwarding_rules::ForwardingError::Storage(error) => RepositoryError::Storage(error),
        _ => RepositoryError::Format,
    }
}
fn display_error(error: crate::display_settings::DisplayError) -> RepositoryError {
    match error {
        crate::display_settings::DisplayError::Storage(error) => RepositoryError::Storage(error),
        _ => RepositoryError::Format,
    }
}
fn opaque(prefix: &str) -> String {
    format!("{prefix}-{:032x}", rand::random::<u128>())
}
pub(crate) fn valid_id(id: &str, prefix: &str) -> bool {
    id.strip_prefix(&format!("{prefix}-"))
        .is_some_and(|v| v.len() == 32 && v.bytes().all(|b| b.is_ascii_hexdigit()))
}
fn encoded<T: Serialize>(value: &T) -> Result<Zeroizing<Vec<u8>>> {
    let raw = Zeroizing::new(serde_json::to_vec(value).map_err(|_| RepositoryError::Format)?);
    if raw.len() > MAX_RECORD {
        return Err(RepositoryError::Invalid);
    }
    Ok(raw)
}
fn decoded<T: for<'de> Deserialize<'de>>(data: &[u8]) -> Result<T> {
    if data.len() > MAX_RECORD {
        return Err(RepositoryError::Format);
    }
    serde_json::from_slice(data).map_err(|_| RepositoryError::Format)
}

pub struct Repository<'a> {
    vault: &'a mut Vault,
}
impl<'a> Repository<'a> {
    pub fn network_defaults(
        &self,
    ) -> std::result::Result<
        crate::network_defaults::NetworkDefaults,
        crate::network_defaults::NetworkDefaultsError,
    > {
        crate::network_defaults::NetworkDefaults::load(self.vault)
    }
    pub fn new(vault: &'a mut Vault) -> Self {
        Self { vault }
    }
    fn catalog(&self) -> Result<Catalog> {
        let c: Catalog = match self.vault.get(CATALOG)? {
            Some(raw) => decoded(&raw)?,
            None => Catalog::default(),
        };
        if !c.within_limits() {
            return Err(RepositoryError::Format);
        }
        Ok(c)
    }
    pub fn list(&self) -> Result<Vec<HostRecord>> {
        self.catalog()?
            .hosts
            .iter()
            .map(|id| self.host(id)?.ok_or(RepositoryError::Format))
            .collect()
    }
    pub fn groups(&self) -> Result<Vec<HostGroup>> {
        Ok(self.catalog()?.groups)
    }
    pub fn host(&self, id: &str) -> Result<Option<HostRecord>> {
        if !valid_id(id, "host") {
            return Err(RepositoryError::Invalid);
        }
        self.vault.get(id)?.map(|raw| decoded(&raw)).transpose()
    }
    pub fn credential(&self, id: &str) -> Result<Option<Credential>> {
        let h = self.host(id)?.ok_or(RepositoryError::Missing)?;
        h.credential_id
            .map(|id| self.vault.get(&id)?.map(|raw| decoded(&raw)).transpose())
            .transpose()
            .map(Option::flatten)
    }
    /// Resolve a captured target's explicit saved-host reference. A missing or
    /// changed route is an error, never permission to connect directly. This
    /// returns metadata only; authentication is read by the explicit caller.
    pub fn jump_host(&self, host: &HostRecord) -> Result<Option<HostRecord>> {
        self.jump_host_in(host, &self.catalog()?)
    }
    fn jump_host_in(&self, host: &HostRecord, catalog: &Catalog) -> Result<Option<HostRecord>> {
        let Some(id) = &host.jump_host_id else {
            return Ok(None);
        };
        if id == &host.id || !valid_id(id, "host") {
            return Err(RepositoryError::JumpInvalid);
        }
        if !catalog.hosts.contains(id) {
            return Err(RepositoryError::JumpMissing);
        }
        let jump = self.host(id)?.ok_or(RepositoryError::JumpMissing)?;
        if jump.jump_host_id.is_some() {
            return Err(RepositoryError::JumpInvalid);
        }
        if host.proxy.is_some() && jump.proxy.is_some() {
            return Err(RepositoryError::JumpProxyConflict);
        }
        Ok(Some(jump))
    }
    fn validate_route(&self, host: &HostRecord, catalog: &Catalog) -> Result<()> {
        self.jump_host_in(host, catalog)?;
        // Validate reverse references as well: editing a saved jump must not
        // silently create a second SSH hop or a second proxy for its targets.
        // Read one bounded encrypted record at a time, not the whole catalog's
        // notes/metadata into a second list.
        if host.jump_host_id.is_some() || host.proxy.is_some() {
            for id in &catalog.hosts {
                if id == &host.id {
                    continue;
                }
                let dependent = self.host(id)?.ok_or(RepositoryError::Format)?;
                if dependent.jump_host_id.as_ref() == Some(&host.id) {
                    if host.jump_host_id.is_some() {
                        return Err(RepositoryError::JumpInvalid);
                    }
                    if dependent.proxy.is_some() && host.proxy.is_some() {
                        return Err(RepositoryError::JumpProxyConflict);
                    }
                }
            }
        }
        Ok(())
    }
    pub fn save(&mut self, host: HostRecord, credential: Option<Credential>) -> Result<HostRecord> {
        self.save_with_proxy(host, credential, None)
    }
    /// The caller never supplies a credential reference. Each proxy secret is
    /// owned by its host ID and is committed together with that host metadata.
    pub fn proxy_credential(&self, id: &str) -> Result<Option<ProxyCredential>> {
        let host = self.host(id)?.ok_or(RepositoryError::Missing)?;
        if !host.proxy.as_ref().is_some_and(|p| p.authenticate) {
            return Ok(None);
        }
        self.vault
            .get(&format!("host-proxy-credential-{id}"))?
            .map(|raw| decoded(&raw))
            .transpose()
    }
    pub fn save_with_proxy(
        &mut self,
        mut host: HostRecord,
        mut credential: Option<Credential>,
        mut proxy_credential: Option<ProxyCredential>,
    ) -> Result<HostRecord> {
        host.validate()?;
        let mut catalog = self.catalog()?;
        self.validate_route(&host, &catalog)?;
        if !catalog.groups.iter().any(|g| g.id == host.group_id) {
            return Err(RepositoryError::Invalid);
        }
        let existing = self.host(&host.id)?;
        if let Some(raw) = self.vault.get(&format!("draft-{}", host.id))? {
            let draft: HostDraft = decoded(&raw)?;
            if credential.is_none() && draft.host.auth == host.auth {
                credential = draft.credential;
            }
            if proxy_credential.is_none() && draft.host.proxy == host.proxy {
                proxy_credential = draft.proxy_credential;
            }
        }
        let proxy_key = format!("host-proxy-credential-{}", host.id);
        let proxy_raw = if let Some(proxy) = host.proxy.as_ref().filter(|p| p.authenticate) {
            if proxy_credential.is_none()
                && existing
                    .as_ref()
                    .and_then(|h| h.proxy.as_ref())
                    .is_some_and(|p| p.authenticate)
            {
                proxy_credential = self.proxy_credential(&host.id)?;
            }
            let value = proxy_credential
                .as_ref()
                .ok_or(RepositoryError::CredentialRequired)?;
            if !proxy.credential_valid(value) {
                return Err(RepositoryError::Invalid);
            }
            Some(encoded(value)?)
        } else {
            None
        };
        if credential.is_none()
            && existing
                .as_ref()
                .is_none_or(|v| v.auth != host.auth || v.credential_id.is_none())
        {
            return Err(RepositoryError::CredentialRequired);
        }
        // Never trust a caller-supplied credential reference belonging to another host.
        host.credential_id = existing
            .and_then(|v| v.credential_id)
            .or_else(|| Some(opaque("credential")));
        if !catalog.hosts.contains(&host.id) {
            catalog.hosts.push(host.id.clone());
        }
        catalog.drafts.retain(|id| id != &host.id);
        let host_raw = encoded(&host)?;
        let cat_raw = catalog.encoded()?;
        let credential_raw = credential.as_ref().map(encoded).transpose()?;
        let draft_id = format!("draft-{}", host.id);
        let mut changes = vec![
            RecordChange::Put(&host.id, &host_raw),
            RecordChange::Put(CATALOG, &cat_raw),
            RecordChange::Delete(&draft_id),
        ];
        if let Some(raw) = &credential_raw {
            changes.push(RecordChange::Put(host.credential_id.as_ref().unwrap(), raw));
        }
        match &proxy_raw {
            Some(raw) => changes.push(RecordChange::Put(&proxy_key, raw)),
            None => changes.push(RecordChange::Delete(&proxy_key)),
        }
        self.vault.apply(&changes)?;
        Ok(host)
    }
    pub fn copy(&mut self, id: &str) -> Result<HostRecord> {
        let host = self.copy_to_draft(id)?;
        self.save(host, None)
    }
    /// Explicit save is still required; a copied draft is not a connectable host.
    pub fn copy_to_draft(&mut self, id: &str) -> Result<HostRecord> {
        let mut host = self.host(id)?.ok_or(RepositoryError::Missing)?;
        let forwarding = crate::forwarding_rules::ForwardingConfig::load(self.vault, id)
            .map_err(forwarding_error)?;
        let display = crate::display_settings::DisplaySettings::copy_raw(self.vault, id)
            .map_err(display_error)?;
        let proxy_credential = self.proxy_credential(id)?;
        if host.proxy.as_ref().is_some_and(|p| p.authenticate) && proxy_credential.is_none() {
            return Err(RepositoryError::CredentialRequired);
        }
        let credential = self.credential(id)?;
        if host.credential_id.is_some() && credential.is_none() {
            return Err(RepositoryError::CredentialRequired);
        }
        host.id = opaque("host");
        host.shell_integration = false;
        host.credential_id = None;
        host.name.push_str(" 副本");
        let forwarding = forwarding.copied(host.id.clone());
        let forwarding_raw = forwarding.encoded().map_err(forwarding_error)?;
        let forwarding_key = crate::forwarding_rules::record_key(&host.id);
        let display_key = crate::display_settings::host_key(&host.id);
        let mut extra: Vec<(&str, &[u8])> = vec![(&forwarding_key, &forwarding_raw)];
        if let Some(raw) = &display {
            extra.push((&display_key, raw));
        }
        self.save_draft_records(
            &HostDraft {
                host: host.clone(),
                credential,
                proxy_credential,
            },
            &extra,
        )?;
        Ok(host)
    }
    pub fn delete(&mut self, ids: &[String]) -> Result<()> {
        let mut c = self.catalog()?;
        let mut remove = Vec::new();
        for id in ids {
            let h = self.host(id)?.ok_or(RepositoryError::Missing)?;
            remove.push(id.clone());
            remove.push(format!("draft-{id}"));
            remove.push(format!("host-proxy-credential-{id}"));
            remove.push(crate::forwarding_rules::record_key(id));
            remove.push(crate::forwarding_drafts::record_key(id));
            remove.push(crate::display_settings::host_key(id));
            if let Some(secret) = h.credential_id {
                remove.push(secret);
            }
        }
        c.hosts.retain(|id| !ids.contains(id));
        c.drafts.retain(|id| !ids.contains(id));
        let raw = c.encoded()?;
        let mut changes = vec![RecordChange::Put(CATALOG, &raw)];
        changes.extend(remove.iter().map(|id| RecordChange::Delete(id)));
        self.vault.apply(&changes)?;
        Ok(())
    }
    pub fn save_draft(&mut self, draft: &HostDraft) -> Result<()> {
        self.save_draft_records(draft, &[])
    }
    fn save_draft_records(
        &mut self,
        draft: &HostDraft,
        additional: &[(&str, &[u8])],
    ) -> Result<()> {
        if !valid_id(&draft.host.id, "host") {
            return Err(RepositoryError::Invalid);
        }
        let mut c = self.catalog()?;
        if !c.drafts.contains(&draft.host.id) {
            c.drafts.push(draft.host.id.clone());
        }
        let old: Option<HostDraft> = self
            .vault
            .get(&format!("draft-{}", draft.host.id))?
            .map(|raw| decoded(&raw))
            .transpose()?;
        #[derive(Serialize)]
        struct DraftRef<'a> {
            host: &'a HostRecord,
            credential: Option<&'a Credential>,
            proxy_credential: Option<&'a ProxyCredential>,
        }
        let auth = draft.host.proxy.as_ref().is_some_and(|p| p.authenticate);
        let retained = old
            .as_ref()
            .filter(|d| d.host.proxy.as_ref().is_some_and(|p| p.authenticate))
            .and_then(|d| d.proxy_credential.as_ref());
        let raw = encoded(&DraftRef {
            host: &draft.host,
            credential: draft.credential.as_ref(),
            proxy_credential: if auth {
                draft.proxy_credential.as_ref().or(retained)
            } else {
                None
            },
        })?;
        let cat_raw = c.encoded()?;
        let draft_key = format!("draft-{}", draft.host.id);
        let mut records: Vec<(&str, &[u8])> = vec![(&draft_key, &raw), (CATALOG, &cat_raw)];
        records.extend_from_slice(additional);
        self.vault.put_many(&records)?;
        Ok(())
    }
    pub fn drafts(&self) -> Result<Vec<HostDraft>> {
        self.catalog()?
            .drafts
            .iter()
            .map(|id| {
                self.vault
                    .get(&format!("draft-{id}"))?
                    .ok_or(RepositoryError::Format)
                    .and_then(|raw| decoded(&raw))
            })
            .collect()
    }
    pub fn discard_draft(&mut self, id: &str) -> Result<()> {
        if !valid_id(id, "host") {
            return Err(RepositoryError::Invalid);
        }
        let mut c = self.catalog()?;
        c.drafts.retain(|v| v != id);
        let raw = c.encoded()?;
        let draft_key = format!("draft-{id}");
        let forwarding_key = crate::forwarding_rules::record_key(id);
        let mut changes = vec![
            RecordChange::Put(CATALOG, &raw),
            RecordChange::Delete(&draft_key),
        ];
        let display_key = crate::display_settings::host_key(id);
        if !c.hosts.iter().any(|host| host == id) {
            changes.push(RecordChange::Delete(&forwarding_key));
            changes.push(RecordChange::Delete(&display_key));
        }
        self.vault.apply(&changes)?;
        Ok(())
    }
    pub fn create_group(&mut self, name: String) -> Result<HostGroup> {
        let mut c = self.catalog()?;
        if name.trim().is_empty() || name.len() > 1024 || c.groups.iter().any(|g| g.name == name) {
            return Err(RepositoryError::Invalid);
        }
        let g = HostGroup {
            id: opaque("group"),
            name,
        };
        c.groups.push(g.clone());
        self.vault.put(CATALOG, &c.encoded()?)?;
        Ok(g)
    }
    pub fn rename_group(&mut self, id: &str, name: String) -> Result<()> {
        let mut c = self.catalog()?;
        if name.trim().is_empty()
            || name.len() > 1024
            || c.groups.iter().any(|g| g.id != id && g.name == name)
        {
            return Err(RepositoryError::Invalid);
        }
        c.groups
            .iter_mut()
            .find(|g| g.id == id)
            .ok_or(RepositoryError::Missing)?
            .name = name;
        self.vault.put(CATALOG, &c.encoded()?)?;
        Ok(())
    }
    pub fn delete_group(&mut self, id: &str) -> Result<()> {
        if id == DEFAULT_GROUP {
            return Err(RepositoryError::Invalid);
        }
        let mut c = self.catalog()?;
        if !c.groups.iter().any(|g| g.id == id) {
            return Err(RepositoryError::Missing);
        }
        let mut replacements = Vec::new();
        for mut host in self.list()?.into_iter().filter(|h| h.group_id == id) {
            host.group_id = DEFAULT_GROUP.into();
            replacements.push((host.id.clone(), encoded(&host)?));
        }
        c.groups.retain(|g| g.id != id);
        let raw = c.encoded()?;
        let mut changes = vec![RecordChange::Put(CATALOG, &raw)];
        changes.extend(
            replacements
                .iter()
                .map(|(id, raw)| RecordChange::Put(id, raw)),
        );
        self.vault.apply(&changes)?;
        Ok(())
    }
    pub fn reorder_hosts(&mut self, ids: Vec<String>) -> Result<()> {
        let mut c = self.catalog()?;
        let mut a = ids.clone();
        let mut b = c.hosts.clone();
        a.sort();
        b.sort();
        if a != b {
            return Err(RepositoryError::Invalid);
        }
        c.hosts = ids;
        self.vault.put(CATALOG, &c.encoded()?)?;
        Ok(())
    }
    /// Only these explicitly selected non-sensitive fields may be edited in bulk.
    pub fn batch_metadata(
        &mut self,
        ids: &[String],
        group: Option<String>,
        favorite: Option<bool>,
    ) -> Result<()> {
        let catalog = self.catalog()?;
        if group
            .as_ref()
            .is_some_and(|id| !catalog.groups.iter().any(|g| &g.id == id))
        {
            return Err(RepositoryError::Invalid);
        }
        let mut writes = Vec::new();
        for id in ids {
            let mut h = self.host(id)?.ok_or(RepositoryError::Missing)?;
            if let Some(group) = &group {
                h.group_id = group.clone();
            }
            if let Some(favorite) = favorite {
                h.favorite = favorite;
            }
            writes.push((id.clone(), encoded(&h)?));
        }
        self.vault.apply(
            &writes
                .iter()
                .map(|(id, raw)| RecordChange::Put(id, raw))
                .collect::<Vec<_>>(),
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn osc7_follow_is_opt_in_and_preserved_by_encrypted_drafts_and_host_copies() {
        let mut legacy = serde_json::to_value(host()).unwrap();
        legacy.as_object_mut().unwrap().remove("follow_osc7");
        let old: HostRecord = serde_json::from_value(legacy).unwrap();
        assert!(!old.follow_osc7);
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault");
        let mut vault = Vault::create(&path, b"synthetic-follow-master").unwrap();
        let id;
        {
            let mut repo = Repository::new(&mut vault);
            let mut h = old;
            h.follow_osc7 = true;
            h.open_sftp = false;
            let saved = repo.save(h, Some(credential())).unwrap();
            id = saved.id.clone();
            let copy = repo.copy_to_draft(&id).unwrap();
            assert!(copy.follow_osc7);
            assert!(!copy.open_sftp);
            assert!(repo.drafts().unwrap()[0].host.follow_osc7);
            assert!(repo.host(&copy.id).unwrap().is_none());
        }
        drop(vault);
        let mut vault = Vault::open(&path, b"synthetic-follow-master").unwrap();
        let mut repo = Repository::new(&mut vault);
        let mut saved = repo.host(&id).unwrap().unwrap();
        assert!(saved.follow_osc7);
        saved.follow_osc7 = false;
        repo.save(saved, None).unwrap();
        assert!(!repo.host(&id).unwrap().unwrap().follow_osc7);
        assert!(repo.drafts().unwrap()[0].host.follow_osc7);
    }
    #[test]
    fn capacity_rejection_keeps_the_existing_catalog_readable() {
        let directory = tempfile::tempdir().unwrap();
        let mut vault =
            Vault::create(&directory.path().join("vault"), b"test-only-master").unwrap();
        let mut catalog = Catalog::default();
        catalog.groups.extend((1..1000).map(|n| HostGroup {
            id: format!("group-{n:032x}"),
            name: format!("Group {n}"),
        }));
        vault.put(CATALOG, &catalog.encoded().unwrap()).unwrap();
        let mut repo = Repository::new(&mut vault);
        assert!(matches!(
            repo.create_group("one too many".into()),
            Err(RepositoryError::Invalid)
        ));
        assert_eq!(repo.groups().unwrap().len(), 1000);
        // Existing data remains editable; no Format error poisons subsequent operations.
        repo.rename_group(&format!("group-{:032x}", 1), "renamed".into())
            .unwrap();
        assert_eq!(repo.groups().unwrap()[1].name, "renamed");
    }
    fn host() -> HostRecord {
        HostRecord::new(
            "Test server".into(),
            "private.example.test".into(),
            "tester".into(),
            AuthMethod::Password,
        )
    }
    fn credential() -> Credential {
        Credential {
            secret: "synthetic-secret-not-on-disk".into(),
            passphrase: None,
        }
    }
    #[test]
    fn hosts_credentials_copy_delete_and_group_changes_are_independent_and_encrypted() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault");
        let mut vault = Vault::create(&path, b"synthetic-master").unwrap();
        let mut repo = Repository::new(&mut vault);
        let group = repo.create_group("Servers".into()).unwrap();
        let mut h = host();
        h.group_id = group.id.clone();
        let a = repo.save(h, Some(credential())).unwrap();
        let b = repo.copy(&a.id).unwrap();
        assert_ne!(a.credential_id, b.credential_id);
        let mut edited = a.clone();
        edited.credential_id = b.credential_id.clone();
        edited.favorite = true;
        let edited = repo.save(edited, None).unwrap();
        assert_eq!(edited.credential_id, a.credential_id);
        repo.rename_group(&group.id, "Renamed".into()).unwrap();
        repo.delete_group(&group.id).unwrap();
        assert!(
            repo.list()
                .unwrap()
                .iter()
                .all(|h| h.group_id == DEFAULT_GROUP)
        );
        repo.reorder_hosts(vec![b.id.clone(), a.id.clone()])
            .unwrap();
        assert_eq!(repo.list().unwrap()[0].id, b.id);
        assert!(
            repo.reorder_hosts(vec![a.id.clone(), a.id.clone()])
                .is_err()
        );
        let before = repo.host(&b.id).unwrap().unwrap().favorite;
        let missing = format!("host-{:032x}", 1);
        assert!(
            repo.batch_metadata(&[b.id.clone(), missing], None, Some(!before))
                .is_err()
        );
        assert_eq!(repo.host(&b.id).unwrap().unwrap().favorite, before);
        repo.batch_metadata(&[a.id.clone(), b.id.clone()], None, Some(true))
            .unwrap();
        assert!(repo.list().unwrap().iter().all(|h| h.favorite));
        repo.delete(std::slice::from_ref(&a.id)).unwrap();
        assert!(repo.host(&a.id).unwrap().is_none());
        assert_eq!(
            repo.credential(&b.id).unwrap().unwrap().secret,
            "synthetic-secret-not-on-disk"
        );
        drop(vault);
        let bytes = std::fs::read(&path).unwrap();
        for secret in [
            "synthetic-secret-not-on-disk",
            "private.example.test",
            "Test server",
            "tester",
        ] {
            assert!(!bytes.windows(secret.len()).any(|v| v == secret.as_bytes()));
        }
        let mut reopened = Vault::open(&path, b"synthetic-master").unwrap();
        assert_eq!(Repository::new(&mut reopened).list().unwrap().len(), 1);
    }
    #[test]
    fn incomplete_drafts_recover_without_becoming_connectable_and_save_clears_them() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault");
        let mut vault = Vault::create(&path, b"synthetic-master").unwrap();
        let mut h = host();
        h.address.clear();
        let draft = HostDraft {
            host: h,
            credential: Some(credential()),
            proxy_credential: None,
        };
        Repository::new(&mut vault).save_draft(&draft).unwrap();
        drop(vault);
        let mut vault = Vault::open(&path, b"synthetic-master").unwrap();
        let mut repo = Repository::new(&mut vault);
        assert!(repo.list().unwrap().is_empty());
        let mut drafts = repo.drafts().unwrap();
        let mut draft = drafts.remove(0);
        assert_eq!(draft.host.address, "");
        draft.host.address = "saved.example.test".into();
        repo.save(draft.host, draft.credential).unwrap();
        assert!(repo.drafts().unwrap().is_empty());
        let mut h = repo.list().unwrap().remove(0);
        h.auth = AuthMethod::PrivateKey;
        assert!(matches!(
            repo.save(h, None),
            Err(RepositoryError::CredentialRequired)
        ));
    }
    #[test]
    fn combined_deletes_and_writes_roll_back_without_losing_credentials() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(&dir.path().join("vault"), b"synthetic-master").unwrap();
        vault.put("credential-test", b"original").unwrap();
        assert!(
            vault
                .apply(&[
                    RecordChange::Delete("credential-test"),
                    RecordChange::Put("__invalid", b"no")
                ])
                .is_err()
        );
        assert_eq!(
            vault.get("credential-test").unwrap().unwrap().as_slice(),
            b"original"
        );
    }
}

#[cfg(test)]
mod jump_tests;
#[cfg(test)]
mod proxy_tests;

#[cfg(test)]
mod agent_setting_tests {
    use super::*;
    #[test]
    fn legacy_hosts_default_to_no_agent_socket_and_wrong_types_are_rejected() {
        let mut host = HostRecord::new(
            "fixture".into(),
            "127.0.0.1".into(),
            "fixture".into(),
            AuthMethod::PrivateKey,
        );
        assert!(!host.agent_forwarding);
        host.agent_forwarding = true;
        let mut encoded = serde_json::to_value(&host).unwrap();
        assert!(
            serde_json::from_value::<HostRecord>(encoded.clone())
                .unwrap()
                .agent_forwarding
        );
        encoded.as_object_mut().unwrap().remove("agent_forwarding");
        assert!(
            !serde_json::from_value::<HostRecord>(encoded.clone())
                .unwrap()
                .agent_forwarding
        );
        encoded["agent_forwarding"] = serde_json::Value::String("true".into());
        assert!(serde_json::from_value::<HostRecord>(encoded).is_err());
    }
}

#[cfg(test)]
mod tmux_setting_tests {
    use super::*;
    #[test]
    fn legacy_tmux_default_and_encrypted_save_copy_preserve_independent_credentials() {
        let host = HostRecord::new(
            "Tmux fixture".into(),
            "127.0.0.1".into(),
            "fixture".into(),
            AuthMethod::Password,
        );
        let mut value = serde_json::to_value(&host).unwrap();
        value.as_object_mut().unwrap().remove("tmux_enabled");
        assert!(
            !serde_json::from_value::<HostRecord>(value.clone())
                .unwrap()
                .tmux_enabled
        );
        value["tmux_enabled"] = serde_json::json!("enabled");
        assert!(serde_json::from_value::<HostRecord>(value).is_err());
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("tmux.vault");
        let mut v = Vault::create(&path, b"synthetic-tmux-setting-master").unwrap();
        let mut h = host;
        h.tmux_enabled = true;
        let id = h.id.clone();
        Repository::new(&mut v)
            .save(
                h,
                Some(Credential {
                    secret: "synthetic-secret".into(),
                    passphrase: None,
                }),
            )
            .unwrap();
        drop(v);
        let mut v = Vault::open(&path, b"synthetic-tmux-setting-master").unwrap();
        let repo = Repository::new(&mut v);
        assert!(repo.host(&id).unwrap().unwrap().tmux_enabled);
        assert_eq!(
            repo.credential(&id).unwrap().unwrap().secret,
            "synthetic-secret"
        );
    }
}
