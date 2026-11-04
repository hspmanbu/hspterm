//! Saved-host forwarding configuration. This module never opens sockets,
//! resolves names, reads SSH credentials or persists running listener state.
use crate::{Repository, RepositoryError, StorageError, Vault};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, net::SocketAddr};
use zeroize::Zeroizing;

const MAX_BYTES: usize = 128 * 1024;
const MAX_RULES: usize = 32;
#[derive(thiserror::Error, Debug)]
pub enum ForwardingError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error(transparent)]
    Repository(#[from] RepositoryError),
    #[error("端口转发规则无效或重复；未保存")]
    Invalid,
    #[error("端口转发配置格式无效或版本不受支持；未覆盖原数据")]
    Format,
    #[error("只能为已正式保存的主机配置端口转发")]
    MissingHost,
}
type Result<T> = std::result::Result<T, ForwardingError>;
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ForwardKind {
    Local,
    Remote,
    Dynamic,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Target {
    pub address: String,
    pub port: u16,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rule {
    pub id: String,
    pub name: String,
    pub kind: ForwardKind,
    /// Local/Dynamic: client bind. Remote: server's requested bind.
    /// Default is deliberately loopback. No implicit wildcard interpretation.
    pub bind: SocketAddr,
    /// None only for Dynamic, whose target is chosen by each SOCKS request.
    pub target: Option<Target>,
    pub enabled: bool,
    /// Applies only after an explicit successful manual reconnect, never boot.
    pub restore_on_reconnect: bool,
}
impl Rule {
    pub fn new(name: String, kind: ForwardKind, target: Option<Target>) -> Self {
        Self {
            id: opaque(),
            name,
            kind,
            bind: SocketAddr::from(([127, 0, 0, 1], 0)),
            target,
            enabled: true,
            restore_on_reconnect: false,
        }
    }
    fn valid(&self) -> bool {
        valid_rule_id(&self.id)
            && !self.name.trim().is_empty()
            && self.name.len() <= 1024
            && !self.name.chars().any(char::is_control)
            && match self.bind {
                SocketAddr::V6(v6) => v6.scope_id() == 0 && v6.flowinfo() == 0,
                _ => true,
            }
            && match (&self.kind, &self.target) {
                (ForwardKind::Dynamic, None) => true,
                (ForwardKind::Local | ForwardKind::Remote, Some(target)) => {
                    target.port != 0 && crate::ssh_proxy::host(&target.address)
                }
                _ => false,
            }
    }
}
fn opaque() -> String {
    format!("forward-{:032x}", rand::random::<u128>())
}
fn valid_rule_id(id: &str) -> bool {
    crate::repository::valid_id(id, "forward")
}
fn valid_host_id(id: &str) -> bool {
    crate::repository::valid_id(id, "host")
}
pub(crate) fn record_key(host: &str) -> String {
    format!("host-forwarding-v1-{host}")
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ForwardingConfig {
    pub version: u32,
    pub host_id: String,
    pub rules: Vec<Rule>,
}
impl ForwardingConfig {
    pub fn empty(host_id: String) -> Self {
        Self {
            version: 1,
            host_id,
            rules: vec![],
        }
    }
    pub fn validate(&self) -> Result<()> {
        if self.version != 1 || !valid_host_id(&self.host_id) || self.rules.len() > MAX_RULES {
            return Err(ForwardingError::Invalid);
        }
        let mut ids = HashSet::new();
        for (index, rule) in self.rules.iter().enumerate() {
            if !rule.valid() || !ids.insert(&rule.id) {
                return Err(ForwardingError::Invalid);
            }
            // L and D share the same local listening namespace. R belongs to
            // the server. Disabled and port-zero rules reserve no fixed port.
            if rule.enabled
                && rule.bind.port() != 0
                && self.rules.iter().take(index).any(|other| {
                    other.enabled
                        && other.bind.port() == rule.bind.port()
                        && other.bind.is_ipv4() == rule.bind.is_ipv4()
                        && (other.kind == ForwardKind::Remote) == (rule.kind == ForwardKind::Remote)
                        && (other.bind.ip() == rule.bind.ip()
                            || other.bind.ip().is_unspecified()
                            || rule.bind.ip().is_unspecified())
                })
            {
                return Err(ForwardingError::Invalid);
            }
        }
        Ok(())
    }
    /// Reading metadata does not read host credentials or establish any SSH.
    pub fn load(vault: &mut Vault, host: &str) -> Result<Self> {
        if !valid_host_id(host) {
            return Err(ForwardingError::Invalid);
        }
        if Repository::new(vault).host(host)?.is_none() {
            return Err(ForwardingError::MissingHost);
        }
        let Some(raw) = vault.get_bounded(&record_key(host), MAX_BYTES)? else {
            return Ok(Self::empty(host.into()));
        };
        let document: Self = serde_json::from_slice(&raw).map_err(|_| ForwardingError::Format)?;
        if document.host_id != host || document.validate().is_err() {
            return Err(ForwardingError::Format);
        }
        Ok(document)
    }
    /// Atomic record replacement, only after validating the old version too.
    /// This saves configuration; starting or stopping a runtime is separate.
    pub fn save(&self, vault: &mut Vault) -> Result<()> {
        self.validate()?;
        Self::load(vault, &self.host_id)?;
        let raw = self.encoded()?;
        vault.put(&record_key(&self.host_id), &raw)?;
        Ok(())
    }
    pub(crate) fn copied(&self, host: String) -> Self {
        let mut copy = self.clone();
        copy.host_id = host;
        for rule in &mut copy.rules {
            rule.id = opaque();
        }
        copy
    }
    pub(crate) fn encoded(&self) -> Result<Zeroizing<Vec<u8>>> {
        self.validate()?;
        let raw = Zeroizing::new(serde_json::to_vec(self).map_err(|_| ForwardingError::Format)?);
        if raw.len() > MAX_BYTES {
            return Err(ForwardingError::Invalid);
        }
        Ok(raw)
    }
    /// Explicit configuration copy between saved hosts, with independent IDs.
    /// No runtime or remotely allocated ephemeral port is copied.
    pub fn copy_to(&self, vault: &mut Vault, host: &str) -> Result<Self> {
        self.validate()?;
        Self::load(vault, &self.host_id)?;
        let copy = self.copied(host.into());
        copy.save(vault)?;
        Ok(copy)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AuthMethod, Credential, HostRecord};
    fn host(vault: &mut Vault) -> HostRecord {
        Repository::new(vault)
            .save(
                HostRecord::new(
                    "fixture".into(),
                    "saved-host.invalid".into(),
                    "synthetic".into(),
                    AuthMethod::Password,
                ),
                Some(Credential {
                    secret: "synthetic-test-only".into(),
                    passphrase: None,
                }),
            )
            .unwrap()
    }
    fn rule() -> Rule {
        Rule::new(
            "private-forward-label".into(),
            ForwardKind::Local,
            Some(Target {
                address: "target.invalid".into(),
                port: 443,
            }),
        )
    }
    #[test]
    fn rules_reopen_encrypted_and_copy_between_hosts_with_independent_ids() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("forward.vault");
        let mut vault = Vault::create(&path, b"synthetic-only").unwrap();
        let a = host(&mut vault);
        let b = host(&mut vault);
        let mut config = ForwardingConfig::load(&mut vault, &a.id).unwrap();
        assert!(config.rules.is_empty());
        config.rules.push(rule());
        config
            .rules
            .push(Rule::new("SOCKS".into(), ForwardKind::Dynamic, None));
        config.save(&mut vault).unwrap();
        let copy = config.copy_to(&mut vault, &b.id).unwrap();
        assert_ne!(copy.rules[0].id, config.rules[0].id);
        drop(vault);
        let mut vault = Vault::open(&path, b"synthetic-only").unwrap();
        assert_eq!(
            ForwardingConfig::load(&mut vault, &a.id).unwrap().rules,
            config.rules
        );
        assert_eq!(
            ForwardingConfig::load(&mut vault, &b.id).unwrap().rules,
            copy.rules
        );
        let raw = std::fs::read(&path).unwrap();
        assert!(
            !raw.windows(b"private-forward-label".len())
                .any(|w| w == b"private-forward-label")
        );
        Repository::new(&mut vault)
            .delete(std::slice::from_ref(&a.id))
            .unwrap();
        assert!(vault.get(&record_key(&a.id)).unwrap().is_none());
        assert_eq!(
            ForwardingConfig::load(&mut vault, &b.id).unwrap().rules,
            copy.rules
        );
    }
    #[test]
    fn invalid_rules_overlaps_versions_and_failed_writes_preserve_original_configuration() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(&dir.path().join("test.vault"), b"synthetic-only").unwrap();
        let h = host(&mut vault);
        let mut config = ForwardingConfig::empty(h.id.clone());
        config.rules.push(rule());
        config.rules[0].bind.set_port(18080);
        config.save(&mut vault).unwrap();
        let original = vault.get(&record_key(&h.id)).unwrap().unwrap();
        let mut duplicate = config.clone();
        duplicate.rules.push(config.rules[0].clone());
        assert!(duplicate.save(&mut vault).is_err());
        for address in [
            "bad\r\n.invalid",
            "http://host/path",
            "host\0.invalid",
            "",
            "[not-an-ip]",
        ] {
            let mut bad = config.clone();
            bad.rules[0].target.as_mut().unwrap().address = address.into();
            assert!(bad.save(&mut vault).is_err());
        }
        let mut conflict = config.clone();
        let mut socks = Rule::new("D".into(), ForwardKind::Dynamic, None);
        socks.bind = "0.0.0.0:18080".parse().unwrap();
        conflict.rules.push(socks);
        assert!(conflict.save(&mut vault).is_err());
        conflict.rules[1].enabled = false;
        conflict.save(&mut vault).unwrap();
        config.save(&mut vault).unwrap();
        let mut remote = config.clone();
        let mut r = config.rules[0].clone();
        r.id = opaque();
        r.kind = ForwardKind::Remote;
        remote.rules.push(r);
        remote.save(&mut vault).unwrap();
        config.save(&mut vault).unwrap();
        assert_eq!(
            &*vault.get(&record_key(&h.id)).unwrap().unwrap(),
            &*original
        );
        let key = record_key(&h.id);
        vault.db.execute_batch(&format!("CREATE TRIGGER deny_forward BEFORE INSERT ON records WHEN NEW.id='{key}' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;")).unwrap();
        let mut changed = config.clone();
        changed.rules[0].name = "new-name".into();
        assert!(changed.save(&mut vault).is_err());
        assert_eq!(
            ForwardingConfig::load(&mut vault, &h.id).unwrap().rules,
            config.rules
        );
        vault
            .db
            .execute_batch("DROP TRIGGER deny_forward;")
            .unwrap();
        let future = Zeroizing::new(
            format!("{{\"version\":2,\"host_id\":\"{}\",\"rules\":[]}}", h.id).into_bytes(),
        );
        vault.put(&key, &future).unwrap();
        assert!(matches!(
            config.save(&mut vault),
            Err(ForwardingError::Format)
        ));
        assert_eq!(&*vault.get(&key).unwrap().unwrap(), &*future);
    }
    #[test]
    fn host_copy_keeps_rules_private_in_a_recoverable_draft_until_formal_save() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.vault");
        let mut vault = Vault::create(&path, b"synthetic-only").unwrap();
        let source = host(&mut vault);
        let mut config = ForwardingConfig::empty(source.id.clone());
        config.rules.push(rule());
        config.save(&mut vault).unwrap();
        let copied = Repository::new(&mut vault)
            .copy_to_draft(&source.id)
            .unwrap();
        assert!(matches!(
            ForwardingConfig::load(&mut vault, &copied.id),
            Err(ForwardingError::MissingHost)
        ));
        assert!(vault.get(&record_key(&copied.id)).unwrap().is_some());
        drop(vault);
        let mut vault = Vault::open(&path, b"synthetic-only").unwrap();
        let draft = Repository::new(&mut vault).drafts().unwrap().pop().unwrap();
        assert_eq!(draft.host.id, copied.id);
        Repository::new(&mut vault).save_draft(&draft).unwrap();
        Repository::new(&mut vault)
            .save(draft.host, draft.credential)
            .unwrap();
        let saved = ForwardingConfig::load(&mut vault, &copied.id).unwrap();
        assert_eq!(saved.rules.len(), 1);
        assert_ne!(saved.rules[0].id, config.rules[0].id);
        assert_eq!(saved.rules[0].target, config.rules[0].target);
        let discarded = Repository::new(&mut vault)
            .copy_to_draft(&source.id)
            .unwrap();
        Repository::new(&mut vault)
            .discard_draft(&discarded.id)
            .unwrap();
        assert!(vault.get(&record_key(&discarded.id)).unwrap().is_none());
        // Discarding an edit draft of an existing saved host must keep rules.
        Repository::new(&mut vault)
            .save_draft(&crate::HostDraft {
                host: source.clone(),
                credential: None,
                proxy_credential: None,
            })
            .unwrap();
        Repository::new(&mut vault)
            .discard_draft(&source.id)
            .unwrap();
        assert_eq!(
            ForwardingConfig::load(&mut vault, &source.id)
                .unwrap()
                .rules,
            config.rules
        );
    }
    #[test]
    fn host_copy_and_delete_failures_roll_back_rules_catalog_drafts_and_credentials_together() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(&dir.path().join("test.vault"), b"synthetic-only").unwrap();
        let source = host(&mut vault);
        let mut config = ForwardingConfig::empty(source.id.clone());
        config.rules.push(rule());
        config.save(&mut vault).unwrap();
        vault.db.execute_batch("CREATE TRIGGER deny_forward_copy BEFORE INSERT ON records WHEN NEW.id LIKE 'host-forwarding-v1-%' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;").unwrap();
        assert!(
            Repository::new(&mut vault)
                .copy_to_draft(&source.id)
                .is_err()
        );
        assert!(Repository::new(&mut vault).drafts().unwrap().is_empty());
        assert_eq!(Repository::new(&mut vault).list().unwrap().len(), 1);
        vault
            .db
            .execute_batch("DROP TRIGGER deny_forward_copy;")
            .unwrap();
        let key = record_key(&source.id);
        vault.db.execute_batch(&format!("CREATE TRIGGER deny_forward_delete BEFORE DELETE ON records WHEN OLD.id='{key}' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;")).unwrap();
        assert!(
            Repository::new(&mut vault)
                .delete(std::slice::from_ref(&source.id))
                .is_err()
        );
        assert!(
            Repository::new(&mut vault)
                .credential(&source.id)
                .unwrap()
                .is_some()
        );
        assert_eq!(
            ForwardingConfig::load(&mut vault, &source.id)
                .unwrap()
                .rules,
            config.rules
        );
    }
    #[test]
    fn configurations_are_bounded_and_do_not_create_or_reassign_missing_hosts() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(&dir.path().join("test.vault"), b"synthetic-only").unwrap();
        let h = host(&mut vault);
        let mut config = ForwardingConfig::empty(h.id.clone());
        for _ in 0..32 {
            config.rules.push(rule());
        }
        config.save(&mut vault).unwrap();
        config.rules.push(rule());
        assert!(config.save(&mut vault).is_err());
        config.rules.pop();
        config.host_id = format!("host-{:032x}", 0);
        assert!(matches!(
            config.save(&mut vault),
            Err(ForwardingError::MissingHost)
        ));
        config.host_id = h.id.clone();
        vault
            .put(&record_key(&h.id), &vec![0; MAX_BYTES + 1])
            .unwrap();
        assert!(matches!(
            ForwardingConfig::load(&mut vault, &h.id),
            Err(ForwardingError::Storage(StorageError::RecordTooLarge))
        ));
    }
}
