//! Configuration bridge only. Runtime listeners and their identities are
//! deliberately separate from saving encrypted metadata.
use anyhow::{Context, Result, bail};
pub(crate) mod runtime;
use hspterm_storage_sync::forwarding_rules::{ForwardKind, ForwardingConfig, Rule, Target};
use std::net::{IpAddr, SocketAddr};

/// A temporary remote loopback target is explicit, never inferred via DNS.
pub(crate) fn temporary_rule(address: String, port: u32) -> Result<Rule> {
    let port = u16::try_from(port).context("目标端口必须介于1和65535")?;
    if port == 0 {
        bail!("目标端口必须介于1和65535");
    }
    let address = if address.eq_ignore_ascii_case("localhost") {
        "localhost".to_owned()
    } else {
        let ip: IpAddr = address
            .parse()
            .context("临时链接转发仅允许明确的回环地址")?;
        if !ip.is_loopback() {
            bail!("临时链接转发仅允许明确的回环地址");
        }
        ip.to_string()
    };
    Ok(Rule::new(
        format!("临时 {address}:{port}"),
        ForwardKind::Local,
        Some(Target { address, port }),
    ))
}

#[derive(Clone)]
pub struct DraftFields {
    pub original: Option<RuleConfig>,
    pub name: String,
    pub kind: String,
    pub bind_address: String,
    pub bind_port: String,
    pub target_address: String,
    pub target_port: String,
    pub enabled: bool,
    pub restore_on_reconnect: bool,
}
pub struct RuleDraft {
    pub revision: u64,
    pub fields: Option<DraftFields>,
}
impl From<hspterm_storage_sync::forwarding_drafts::Draft> for RuleDraft {
    fn from(draft: hspterm_storage_sync::forwarding_drafts::Draft) -> Self {
        Self {
            revision: draft.revision,
            fields: draft.fields.map(|fields| DraftFields {
                original: fields.original.map(Into::into),
                name: fields.name,
                kind: fields.kind,
                bind_address: fields.bind_address,
                bind_port: fields.bind_port,
                target_address: fields.target_address,
                target_port: fields.target_port,
                enabled: fields.enabled,
                restore_on_reconnect: fields.restore_on_reconnect,
            }),
        }
    }
}
impl DraftFields {
    fn record(self) -> Result<hspterm_storage_sync::forwarding_drafts::Fields> {
        if self.original.as_ref().is_some_and(|r| r.id.is_empty()) {
            bail!("原始规则标识不能为空");
        }
        Ok(hspterm_storage_sync::forwarding_drafts::Fields {
            original: self.original.map(RuleConfig::record).transpose()?,
            name: self.name,
            kind: self.kind,
            bind_address: self.bind_address,
            bind_port: self.bind_port,
            target_address: self.target_address,
            target_port: self.target_port,
            enabled: self.enabled,
            restore_on_reconnect: self.restore_on_reconnect,
        })
    }
}
pub(crate) async fn draft(host: String) -> Result<RuleDraft> {
    tokio::task::spawn_blocking(move || {
        crate::api::with_vault(|v| {
            Ok(hspterm_storage_sync::forwarding_drafts::Draft::load(v, &host)?.into())
        })
    })
    .await?
}
pub(crate) async fn save_draft(
    host: String,
    expected: u64,
    fields: Option<DraftFields>,
) -> Result<RuleDraft> {
    let fields = fields.map(DraftFields::record).transpose()?;
    tokio::task::spawn_blocking(move || {
        crate::api::with_vault(|v| {
            Ok(
                hspterm_storage_sync::forwarding_drafts::Draft::save(v, &host, expected, fields)?
                    .into(),
            )
        })
    })
    .await?
}
pub(crate) async fn commit_draft(host: String, expected: u64) -> Result<Vec<RuleConfig>> {
    tokio::task::spawn_blocking(move || {
        crate::api::with_vault(|v| {
            Ok(
                hspterm_storage_sync::forwarding_drafts::Draft::commit(v, &host, expected)?
                    .rules
                    .into_iter()
                    .map(Into::into)
                    .collect(),
            )
        })
    })
    .await?
}

#[derive(Clone)]
pub struct RuleConfig {
    /// Empty on creation only; the saved result contains a stable opaque ID.
    pub id: String,
    pub name: String,
    pub kind: String,
    pub bind_address: String,
    pub bind_port: u32,
    pub target_address: Option<String>,
    pub target_port: Option<u32>,
    pub enabled: bool,
    pub restore_on_reconnect: bool,
}
impl From<Rule> for RuleConfig {
    fn from(rule: Rule) -> Self {
        Self {
            id: rule.id,
            name: rule.name,
            kind: match rule.kind {
                ForwardKind::Local => "local",
                ForwardKind::Remote => "remote",
                ForwardKind::Dynamic => "dynamic",
            }
            .into(),
            bind_address: rule.bind.ip().to_string(),
            bind_port: u32::from(rule.bind.port()),
            target_address: rule.target.as_ref().map(|t| t.address.clone()),
            target_port: rule.target.map(|t| u32::from(t.port)),
            enabled: rule.enabled,
            restore_on_reconnect: rule.restore_on_reconnect,
        }
    }
}
impl RuleConfig {
    fn record(self) -> Result<Rule> {
        let kind = match self.kind.as_str() {
            "local" => ForwardKind::Local,
            "remote" => ForwardKind::Remote,
            "dynamic" => ForwardKind::Dynamic,
            _ => bail!("端口转发类型无效"),
        };
        let target = match (self.target_address, self.target_port) {
            (None, None) => None,
            (Some(address), Some(port)) => Some(Target {
                address,
                port: u16::try_from(port).context("目标端口必须介于1和65535")?,
            }),
            _ => bail!("目标地址与端口必须同时提供"),
        };
        let ip: IpAddr = self
            .bind_address
            .parse()
            .context("监听地址必须是明确的IPv4或IPv6地址")?;
        let port = u16::try_from(self.bind_port).context("监听端口必须介于0和65535")?;
        let mut rule = Rule::new(self.name, kind, target);
        if !self.id.is_empty() {
            rule.id = self.id;
        }
        rule.bind = SocketAddr::new(ip, port);
        rule.enabled = self.enabled;
        rule.restore_on_reconnect = self.restore_on_reconnect;
        Ok(rule)
    }
}
pub(crate) async fn load(host: String) -> Result<Vec<RuleConfig>> {
    tokio::task::spawn_blocking(move || {
        crate::api::with_vault(|v| {
            Ok(ForwardingConfig::load(v, &host)?
                .rules
                .into_iter()
                .map(Into::into)
                .collect())
        })
    })
    .await?
}
pub(crate) async fn save(host: String, values: Vec<RuleConfig>) -> Result<Vec<RuleConfig>> {
    if values.len() > 32 {
        bail!("每个主机最多保存32条端口转发规则");
    }
    let rules = values
        .into_iter()
        .map(RuleConfig::record)
        .collect::<Result<Vec<_>>>()?;
    let document = ForwardingConfig {
        version: 1,
        host_id: host,
        rules,
    };
    document.validate()?;
    tokio::task::spawn_blocking(move || {
        crate::api::with_vault(|v| {
            document.save(v)?;
            Ok(document.rules.into_iter().map(Into::into).collect())
        })
    })
    .await?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn temporary_links_accept_only_explicit_loopback_and_never_persist_or_restore() {
        for address in ["localhost", "LOCALHOST", "127.0.0.1", "127.2.3.4", "::1"] {
            let rule = temporary_rule(address.into(), 8080).unwrap();
            assert!(rule.bind.ip().is_loopback());
            assert_eq!(rule.bind.port(), 0);
            assert_eq!(rule.kind, ForwardKind::Local);
            assert!(!rule.restore_on_reconnect);
        }
        for address in [
            "0.0.0.0",
            "192.0.2.1",
            "::",
            "::ffff:127.0.0.1",
            "localhost.invalid",
            "localhost.",
            "[::1]",
            "localhost/path",
            "127.0.0.1\n",
        ] {
            assert!(temporary_rule(address.into(), 8080).is_err(), "{address}");
        }
        for port in [0, 65536, u32::MAX] {
            assert!(temporary_rule("localhost".into(), port).is_err());
        }
    }
}
