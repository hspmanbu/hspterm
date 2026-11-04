//! Device-local, incomplete forwarding editor drafts. Never part of sync or backup.
//! A revisioned empty body is a tombstone: an older delayed writer cannot revive
//! a discarded/committed editor after an absent -> present -> absent ABA cycle.
use crate::forwarding_rules::{ForwardKind, ForwardingConfig, Rule, Target};
use crate::{RecordChange, Repository, StorageError, Vault};
use serde::{Deserialize, Serialize};
use std::net::{IpAddr, SocketAddr};
use thiserror::Error;
use zeroize::Zeroizing;

const MAX_BYTES: usize = 64 * 1024;
#[derive(Debug, Error)]
pub enum DraftError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error(transparent)]
    Repository(#[from] crate::RepositoryError),
    #[error("转发草稿格式无效或版本不支持；原数据保留")]
    Format,
    #[error("主机已删除或尚未正式保存")]
    MissingHost,
    #[error("草稿或正式规则已改变；请保留当前内容并重新载入")]
    Changed,
    #[error("转发字段不完整或无效，请检查名称、地址与端口")]
    Invalid,
    #[error("保存规则失败：{0}")]
    Rule(#[from] crate::forwarding_rules::ForwardingError),
}
type Result<T> = std::result::Result<T, DraftError>;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fields {
    /// Immutable original saved rule, used only for optimistic replacement.
    pub original: Option<Rule>,
    pub name: String,
    pub kind: String,
    pub bind_address: String,
    pub bind_port: String,
    pub target_address: String,
    pub target_port: String,
    pub enabled: bool,
    pub restore_on_reconnect: bool,
}
impl Fields {
    fn bounded(&self, host: &str) -> bool {
        [&self.name, &self.bind_address, &self.target_address]
            .iter()
            .all(|s| s.len() <= 4096)
            && self.bind_port.len() <= 64
            && self.target_port.len() <= 64
            && matches!(self.kind.as_str(), "local" | "remote" | "dynamic")
            && self.original.as_ref().is_none_or(|original| {
                ForwardingConfig {
                    version: 1,
                    host_id: host.into(),
                    rules: vec![original.clone()],
                }
                .validate()
                .is_ok()
            })
    }
    fn rule(&self) -> Result<Rule> {
        let kind = match self.kind.as_str() {
            "local" => ForwardKind::Local,
            "remote" => ForwardKind::Remote,
            "dynamic" => ForwardKind::Dynamic,
            _ => return Err(DraftError::Invalid),
        };
        let ip: IpAddr = self.bind_address.parse().map_err(|_| DraftError::Invalid)?;
        let port: u16 = self.bind_port.parse().map_err(|_| DraftError::Invalid)?;
        let target = if kind == ForwardKind::Dynamic {
            None
        } else {
            Some(Target {
                address: self.target_address.clone(),
                port: self.target_port.parse().map_err(|_| DraftError::Invalid)?,
            })
        };
        let mut rule = Rule::new(self.name.clone(), kind, target);
        if let Some(original) = &self.original {
            rule.id = original.id.clone();
        }
        rule.bind = SocketAddr::new(ip, port);
        rule.enabled = self.enabled;
        rule.restore_on_reconnect = self.restore_on_reconnect;
        Ok(rule)
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Draft {
    version: u32,
    host_id: String,
    pub revision: u64,
    pub fields: Option<Fields>,
}
pub(crate) fn record_key(host: &str) -> String {
    format!("local-forwarding-draft-v1-{host}")
}
fn host_record(vault: &mut Vault, host: &str) -> Result<Zeroizing<Vec<u8>>> {
    if !crate::repository::valid_id(host, "host") {
        return Err(DraftError::MissingHost);
    }
    let raw = vault.get(host)?.ok_or(DraftError::MissingHost)?;
    if Repository::new(vault).host(host)?.is_none() {
        return Err(DraftError::MissingHost);
    }
    Ok(raw)
}
fn read(vault: &Vault, host: &str) -> Result<(Draft, Option<Zeroizing<Vec<u8>>>)> {
    let raw = vault.get_bounded(&record_key(host), MAX_BYTES)?;
    let draft = match &raw {
        None => Draft {
            version: 1,
            host_id: host.into(),
            revision: 0,
            fields: None,
        },
        Some(raw) => {
            let value: Draft = serde_json::from_slice(raw).map_err(|_| DraftError::Format)?;
            if value.version != 1
                || value.host_id != host
                || value.revision == 0
                || value.fields.as_ref().is_some_and(|f| !f.bounded(host))
            {
                return Err(DraftError::Format);
            }
            value
        }
    };
    Ok((draft, raw))
}
fn encoded(draft: &Draft) -> Result<Zeroizing<Vec<u8>>> {
    let raw = Zeroizing::new(serde_json::to_vec(draft).map_err(|_| DraftError::Format)?);
    if raw.len() > MAX_BYTES {
        return Err(DraftError::Invalid);
    }
    Ok(raw)
}
impl Draft {
    pub fn load(vault: &mut Vault, host: &str) -> Result<Self> {
        host_record(vault, host)?;
        Ok(read(vault, host)?.0)
    }
    /// Incomplete/invalid text is allowed within bounds; no formal config writes.
    pub fn save(
        vault: &mut Vault,
        host: &str,
        expected: u64,
        fields: Option<Fields>,
    ) -> Result<Self> {
        let host_raw = host_record(vault, host)?;
        let (mut draft, previous) = read(vault, host)?;
        if draft.revision != expected {
            return Err(DraftError::Changed);
        }
        if fields.as_ref().is_some_and(|f| !f.bounded(host)) {
            return Err(DraftError::Invalid);
        }
        draft.revision = draft.revision.checked_add(1).ok_or(DraftError::Format)?;
        draft.fields = fields;
        let raw = encoded(&draft)?;
        let key = record_key(host);
        if !vault.apply_checked(
            &[
                (host, Some(&host_raw)),
                (&key, previous.as_deref().map(Vec::as_slice)),
            ],
            &[RecordChange::Put(&key, &raw)],
        )? {
            return Err(DraftError::Changed);
        }
        Ok(draft)
    }
    /// Explicit Save only: commit validated persisted editor text and retire its
    /// draft in one transaction. Preserve unrelated latest rules and reject an
    /// edited/deleted original instead of overwriting another writer's change.
    pub fn commit(vault: &mut Vault, host: &str, expected: u64) -> Result<ForwardingConfig> {
        let host_raw = host_record(vault, host)?;
        let (mut draft, previous) = read(vault, host)?;
        if draft.revision != expected {
            return Err(DraftError::Changed);
        }
        let fields = draft.fields.as_ref().ok_or(DraftError::Invalid)?;
        let config_key = crate::forwarding_rules::record_key(host);
        let config_raw = vault.get_bounded(&config_key, 128 * 1024)?;
        let mut config = ForwardingConfig::load(vault, host)?;
        let rule = fields.rule()?;
        if let Some(original) = &fields.original {
            let index = config
                .rules
                .iter()
                .position(|r| r.id == original.id)
                .ok_or(DraftError::Changed)?;
            if &config.rules[index] != original {
                return Err(DraftError::Changed);
            }
            config.rules[index] = rule;
        } else {
            config.rules.push(rule);
        }
        config.validate()?;
        draft.revision = draft.revision.checked_add(1).ok_or(DraftError::Format)?;
        draft.fields = None;
        let cleared = encoded(&draft)?;
        let saved = config.encoded()?;
        let draft_key = record_key(host);
        if !vault.apply_checked(
            &[
                (host, Some(&host_raw)),
                (&draft_key, previous.as_deref().map(Vec::as_slice)),
                (&config_key, config_raw.as_deref().map(Vec::as_slice)),
            ],
            &[
                RecordChange::Put(&config_key, &saved),
                RecordChange::Put(&draft_key, &cleared),
            ],
        )? {
            return Err(DraftError::Changed);
        }
        Ok(config)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AuthMethod, Credential, HostRecord};
    fn setup(vault: &mut Vault) -> String {
        Repository::new(vault)
            .save(
                HostRecord::new(
                    "fixture".into(),
                    "forward.invalid".into(),
                    "fixture".into(),
                    AuthMethod::Password,
                ),
                Some(Credential {
                    secret: "synthetic-only".into(),
                    passphrase: None,
                }),
            )
            .unwrap()
            .id
    }
    fn fields() -> Fields {
        Fields {
            original: None,
            name: "private-draft-label".into(),
            kind: "local".into(),
            bind_address: "127.0.0.1".into(),
            bind_port: "0".into(),
            target_address: "target.invalid".into(),
            target_port: "443".into(),
            enabled: true,
            restore_on_reconnect: true,
        }
    }
    #[test]
    fn incomplete_drafts_reopen_encrypted_and_commit_only_after_explicit_validation() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("draft.vault");
        let mut v = Vault::create(&path, b"synthetic-draft-master").unwrap();
        let host = setup(&mut v);
        let mut text = fields();
        text.bind_port = "not a port".into();
        let saved = Draft::save(&mut v, &host, 0, Some(text.clone())).unwrap();
        assert!(Draft::commit(&mut v, &host, saved.revision).is_err());
        assert!(
            ForwardingConfig::load(&mut v, &host)
                .unwrap()
                .rules
                .is_empty()
        );
        drop(v);
        assert!(
            !std::fs::read(&path)
                .unwrap()
                .windows(text.name.len())
                .any(|w| w == text.name.as_bytes())
        );
        let mut v = Vault::open(&path, b"synthetic-draft-master").unwrap();
        assert_eq!(Draft::load(&mut v, &host).unwrap().fields, Some(text));
        let saved = Draft::save(&mut v, &host, saved.revision, Some(fields())).unwrap();
        let config = Draft::commit(&mut v, &host, saved.revision).unwrap();
        assert_eq!(config.rules.len(), 1);
        assert!(config.rules[0].restore_on_reconnect);
        assert_eq!(config.rules[0].bind.port(), 0);
        assert!(Draft::load(&mut v, &host).unwrap().fields.is_none());
        assert!(matches!(
            Draft::save(&mut v, &host, saved.revision, Some(fields())),
            Err(DraftError::Changed)
        ));
        let revision = Draft::load(&mut v, &host).unwrap().revision;
        Draft::save(&mut v, &host, revision, None).unwrap();
        assert!(matches!(
            Draft::save(&mut v, &host, 0, Some(fields())),
            Err(DraftError::Changed)
        ));
    }
    #[test]
    fn formal_rule_conflicts_and_failed_atomic_commit_preserve_both_draft_and_config() {
        let tmp = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&tmp.path().join("atomic.vault"), b"synthetic-master").unwrap();
        let host = setup(&mut v);
        let first = Draft::save(&mut v, &host, 0, Some(fields())).unwrap();
        let mut config = Draft::commit(&mut v, &host, first.revision).unwrap();
        let current = Draft::load(&mut v, &host).unwrap();
        let mut changed = fields();
        changed.original = Some(config.rules[0].clone());
        changed.name = "draft edit".into();
        let draft = Draft::save(&mut v, &host, current.revision, Some(changed)).unwrap();
        config.rules[0].name = "other writer".into();
        config.save(&mut v).unwrap();
        assert!(matches!(
            Draft::commit(&mut v, &host, draft.revision),
            Err(DraftError::Changed)
        ));
        assert_eq!(
            ForwardingConfig::load(&mut v, &host).unwrap().rules[0].name,
            "other writer"
        );
        assert!(Draft::load(&mut v, &host).unwrap().fields.is_some());
        let draft = Draft::save(&mut v, &host, draft.revision, Some(fields())).unwrap();
        let key = record_key(&host);
        v.db.execute_batch(&format!("CREATE TEMP TRIGGER refuse_draft BEFORE UPDATE ON records WHEN OLD.id='{key}' BEGIN SELECT RAISE(ABORT,'fixture'); END;")).unwrap();
        assert!(Draft::commit(&mut v, &host, draft.revision).is_err());
        assert_eq!(
            ForwardingConfig::load(&mut v, &host).unwrap().rules.len(),
            1
        );
        assert_eq!(Draft::load(&mut v, &host).unwrap(), draft);
        v.db.execute_batch("DROP TRIGGER refuse_draft").unwrap();
        let copy = Repository::new(&mut v).copy(&host).unwrap();
        assert!(Draft::load(&mut v, &copy.id).unwrap().fields.is_none());
        Repository::new(&mut v)
            .delete(std::slice::from_ref(&host))
            .unwrap();
        assert!(v.get(&key).unwrap().is_none());
        assert!(Draft::save(&mut v, &host, 0, Some(fields())).is_err());
    }
    #[test]
    fn unknown_versions_capacity_and_stale_second_connection_never_overwrite_current_draft() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("concurrent.vault");
        let mut v = Vault::create(&path, b"synthetic-master").unwrap();
        let host = setup(&mut v);
        let mut second = Vault::open(&path, b"synthetic-master").unwrap();
        let before = Draft::load(&mut second, &host).unwrap();
        let saved = Draft::save(&mut v, &host, before.revision, Some(fields())).unwrap();
        assert!(matches!(
            Draft::save(&mut second, &host, before.revision, Some(fields())),
            Err(DraftError::Changed)
        ));
        let mut oversized = fields();
        oversized.name = "x".repeat(4097);
        assert!(Draft::save(&mut v, &host, saved.revision, Some(oversized)).is_err());
        assert_eq!(Draft::load(&mut v, &host).unwrap(), saved);
        let key = record_key(&host);
        let mut future = serde_json::to_value(&saved).unwrap();
        future["version"] = 99.into();
        let raw = serde_json::to_vec(&future).unwrap();
        v.put(&key, &raw).unwrap();
        assert!(Draft::load(&mut v, &host).is_err());
        assert!(Draft::save(&mut v, &host, saved.revision, None).is_err());
        assert_eq!(v.get(&key).unwrap().unwrap().as_slice(), raw);
    }
}
