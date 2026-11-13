//! One authoritative saved-host routing snapshot for login and handshake tests.
use anyhow::{Context, Result};
use hspterm_ssh_core::{
    Authentication, ConnectConfig, HostKeyPolicy, HostKeyRequest, JumpHost, ProxyConfig,
    ProxyCredentials, ProxyKind,
};
use hspterm_storage_sync::{HostRecord, Repository, ssh_proxy};
use sha2::{Digest, Sha256};
use std::time::Duration;
use zeroize::Zeroizing;
pub(crate) mod temporary;
mod verification;
pub(crate) use verification::{Scope, Verification};

pub(crate) struct Route {
    config: ConnectConfig,
    jump: Option<(HostRecord, Authentication)>,
    tmux_enabled: bool,
}
pub(crate) struct Prepared {
    pub config: ConnectConfig,
    pub policy: HostKeyPolicy,
    pub vault_scope: String,
    pub tmux_enabled: bool,
}

fn target_identity(config: &ConnectConfig, jump: Option<&HostRecord>) -> String {
    let Some(jump) = jump else {
        return crate::api::trust_id(&config.address, config.port);
    };
    // Unambiguous versioned tuple, never concatenate endpoints with ambiguous
    // separators. Distinct private networks must not share the direct pin.
    let mut hash = Sha256::new();
    for value in [
        b"hspterm-jump-target-v1".as_slice(),
        jump.address.to_ascii_lowercase().as_bytes(),
        &jump.port.to_be_bytes(),
        jump.username.as_bytes(),
        config.address.to_ascii_lowercase().as_bytes(),
        &config.port.to_be_bytes(),
    ] {
        hash.update((value.len() as u64).to_be_bytes());
        hash.update(value);
    }
    format!(
        "trust-jump-{}",
        hash.finalize()
            .iter()
            .map(|v| format!("{v:02x}"))
            .collect::<String>()
    )
}

impl Route {
    pub fn direct(config: ConnectConfig) -> Self {
        Self {
            config,
            jump: None,
            tmux_enabled: false,
        }
    }
    pub fn prepare(
        mut self,
        v: &mut hspterm_storage_sync::Vault,
        scope: &verification::Scope,
        requests: tokio::sync::mpsc::Sender<HostKeyRequest>,
    ) -> Result<Prepared> {
        let target_trust = target_identity(&self.config, self.jump.as_ref().map(|j| &j.0));
        let policy = scope.policy(
            v,
            &self.config.address,
            self.config.port,
            target_trust.clone(),
            false,
            requests.clone(),
        )?;
        if let Some((jump, authentication)) = self.jump {
            let host_key = scope.policy(
                v,
                &jump.address,
                jump.port,
                crate::api::trust_id(&jump.address, jump.port),
                true,
                requests,
            )?;
            self.config.jump = Some(JumpHost {
                address: jump.address,
                port: jump.port,
                username: jump.username,
                authentication,
                host_key,
            });
        }
        Ok(Prepared {
            tmux_enabled: self.tmux_enabled,
            config: self.config,
            policy,
            vault_scope: v.instance_id().to_owned(),
        })
    }
}

pub(crate) fn authentication(
    mut c: hspterm_storage_sync::Credential,
    private: bool,
) -> Authentication {
    if private {
        Authentication::PrivateKey {
            openssh: Zeroizing::new(std::mem::take(&mut c.secret)),
            passphrase: c.passphrase.take().map(Zeroizing::new),
        }
    } else {
        Authentication::Password(Zeroizing::new(std::mem::take(&mut c.secret)))
    }
}

pub(crate) fn configuration(repo: &Repository<'_>, host: &HostRecord) -> Result<Route> {
    let jump = repo.jump_host(host)?;
    let mut config = ConnectConfig::new(host.address.clone(), host.port, host.username.clone());
    let inherited = host
        .use_network_defaults
        .then(|| repo.network_defaults())
        .transpose()?;
    let timeout = inherited.map_or(host.timeout_seconds, |s| s.timeout_seconds);
    let interval = inherited.map_or(host.keepalive_seconds, |s| s.keepalive_seconds);
    let failures = inherited.map_or(host.keepalive_failures, |s| s.keepalive_failures);
    let response = inherited
        .map(|s| s.response_timeout_seconds)
        .or(host.keepalive_response_seconds);
    config.agent_forwarding = host.agent_forwarding;
    config.integration = host
        .shell_integration
        .then(hspterm_ssh_core::integration::Launch::fresh);
    config.timeout = Duration::from_secs(timeout as u64);
    config.keepalive_interval = (interval != 0).then(|| Duration::from_secs(interval as u64));
    config.keepalive_failures = failures as usize;
    config.keepalive_response_timeout = response.map(|s| Duration::from_secs(s as u64));
    let proxy_owner = if host.proxy.is_some() {
        host
    } else {
        jump.as_ref().unwrap_or(host)
    };
    config.proxy = proxy_owner
        .proxy
        .as_ref()
        .map(|p| {
            let authentication = if p.authenticate {
                let mut c = repo
                    .proxy_credential(&proxy_owner.id)?
                    .context("代理凭据缺失")?;
                Some(ProxyCredentials::new(
                    std::mem::take(&mut c.username),
                    std::mem::take(&mut c.password),
                ))
            } else {
                None
            };
            Ok::<_, anyhow::Error>(ProxyConfig {
                kind: match p.kind {
                    ssh_proxy::ProxyKind::HttpConnect => ProxyKind::HttpConnect,
                    ssh_proxy::ProxyKind::Socks5 => ProxyKind::Socks5,
                },
                address: p.address.clone(),
                port: p.port,
                authentication,
            })
        })
        .transpose()?;
    let jump = jump
        .map(|j| {
            let c = repo.credential(&j.id)?.context("跳板机凭据缺失")?;
            let auth = authentication(c, j.auth == hspterm_storage_sync::AuthMethod::PrivateKey);
            Ok::<_, anyhow::Error>((j, auth))
        })
        .transpose()?;
    Ok(Route {
        config,
        jump,
        tmux_enabled: host.tmux_enabled,
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn inherited_defaults_are_captured_for_one_attempt_and_legacy_hosts_do_not_read_unrelated_defaults()
     {
        use super::*;
        use hspterm_storage_sync::{
            AuthMethod, Credential, Vault, network_defaults::NetworkDefaults,
        };
        let tmp = tempfile::tempdir().unwrap();
        let mut vault =
            Vault::create(&tmp.path().join("defaults.vault"), b"synthetic-master").unwrap();
        let chosen = NetworkDefaults {
            version: 1,
            timeout_seconds: 19,
            keepalive_seconds: 7,
            keepalive_failures: 2,
            response_timeout_seconds: 5,
            auto_reconnect: false,
            tmux_local_selection: true,
            tmux_shift_enter_lf: false,
        };
        chosen.save(&mut vault).unwrap();
        let mut host = HostRecord::new(
            "fixture".into(),
            "target.invalid".into(),
            "fixture".into(),
            AuthMethod::Password,
        );
        host.use_network_defaults = true;
        let host = Repository::new(&mut vault)
            .save(
                host,
                Some(Credential {
                    secret: "synthetic-only".into(),
                    passphrase: None,
                }),
            )
            .unwrap();
        let captured = configuration(&Repository::new(&mut vault), &host).unwrap();
        NetworkDefaults {
            timeout_seconds: 25,
            ..chosen
        }
        .save(&mut vault)
        .unwrap();
        assert_eq!(captured.config.timeout, Duration::from_secs(19));
        assert_eq!(
            captured.config.keepalive_response_timeout,
            Some(Duration::from_secs(5))
        );
        assert_eq!(
            configuration(&Repository::new(&mut vault), &host)
                .unwrap()
                .config
                .timeout,
            Duration::from_secs(25)
        );
        vault
            .put("config-ssh-network-defaults-v1", br#"{"version":99}"#)
            .unwrap();
        assert!(configuration(&Repository::new(&mut vault), &host).is_err());
        let mut legacy = host;
        legacy.use_network_defaults = false;
        let explicit = configuration(&Repository::new(&mut vault), &legacy).unwrap();
        assert_eq!(explicit.config.timeout, Duration::from_secs(30));
        assert_eq!(explicit.config.keepalive_response_timeout, None);
    }
    use super::*;
    #[test]
    fn target_pins_are_scoped_to_jump_route_without_changing_direct_trust() {
        let config = ConnectConfig::new("10.0.0.1".into(), 22, "target-user".into());
        let mut j = HostRecord::new(
            "jump".into(),
            "bastion.invalid".into(),
            "jump-user".into(),
            hspterm_storage_sync::AuthMethod::Password,
        );
        let direct = target_identity(&config, None);
        assert_eq!(direct, crate::api::trust_id("10.0.0.1", 22));
        let first = target_identity(&config, Some(&j));
        assert_ne!(first, direct);
        j.username.push('2');
        assert_ne!(target_identity(&config, Some(&j)), first);
        j.username.pop();
        j.port += 1;
        assert_ne!(target_identity(&config, Some(&j)), first);
        j.port -= 1;
        j.address = "other.invalid".into();
        assert_ne!(target_identity(&config, Some(&j)), first);
        j.address = "BASTION.invalid".into();
        assert_eq!(target_identity(&config, Some(&j)), first);
    }
}
