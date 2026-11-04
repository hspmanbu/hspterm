//! Single-use saved-host overrides. No storage writes or automatic file lookup.
//! Bound to the original saved host and Vault throughout preparation and reconnect.
use anyhow::{Context, Result, ensure};
use hspterm_ssh_core::Authentication;
use hspterm_storage_sync::HostRecord;
use std::{io::Read, path::PathBuf};
use zeroize::Zeroizing;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Method {
    Saved,
    Password,
    PrivateKey,
}
#[derive(Clone)]
pub(crate) struct OverrideTarget {
    pub address: String,
    pub port: u16,
    pub username: String,
    pub method: Method,
}
impl OverrideTarget {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.address.is_empty()
                && self.address.len() <= 1024
                && !self.address.chars().any(char::is_control)
                && self.address.trim() == self.address
                && self.port != 0,
            "请填写有效的本次SSH地址和端口"
        );
        ensure!(
            !self.username.is_empty()
                && self.username.len() <= 512
                && !self.username.chars().any(char::is_control),
            "请填写有效的本次SSH用户名"
        );
        // This is a structural precheck only. The ordinary SSH core validates
        // the complete inherited route at connection time; no DNS/probe here.
        Ok(())
    }
    /// Only mutate the caller's in-memory snapshot, never Repository records.
    pub fn apply(&self, host: &mut HostRecord) -> Result<()> {
        self.validate()?;
        host.address.clone_from(&self.address);
        host.port = self.port;
        host.username.clone_from(&self.username);
        Ok(())
    }
}

/// Non-secret dialog source. Its tag covers target and jump metadata, not
/// private credentials; final preparation must recheck it under the Vault gate.
#[derive(Clone)]
pub struct TemporarySource {
    pub vault_scope: String,
    pub host_id: String,
    pub metadata_tag: String,
    pub name: String,
    pub address: String,
    pub port: u16,
    pub username: String,
    pub private_key: bool,
    pub credential_present: bool,
}
fn metadata_tag(host: &HostRecord, jump: Option<&HostRecord>) -> Result<String> {
    use sha2::{Digest, Sha256};
    let encoded = serde_json::to_vec(&(host, jump))?;
    let mut hash = Sha256::new();
    hash.update(b"HSPTerm single-use saved host metadata v1\0");
    hash.update(encoded);
    Ok(hash.finalize().iter().map(|b| format!("{b:02x}")).collect())
}
impl TemporarySource {
    pub fn capture(v: &mut hspterm_storage_sync::Vault, host_id: &str) -> Result<Self> {
        let scope = v.instance_id().to_owned();
        let repo = hspterm_storage_sync::Repository::new(v);
        let host = repo
            .host(host_id)?
            .context("请先使用主机管理器正式保存主机")?;
        let jump = repo.jump_host(&host)?;
        Ok(Self {
            vault_scope: scope,
            metadata_tag: metadata_tag(&host, jump.as_ref())?,
            host_id: host.id.clone(),
            name: host.name.clone(),
            address: host.address.clone(),
            port: host.port,
            username: host.username.clone(),
            private_key: host.auth == hspterm_storage_sync::AuthMethod::PrivateKey,
            credential_present: host.credential_id.is_some(),
        })
    }
    pub fn check(&self, v: &mut hspterm_storage_sync::Vault) -> Result<HostRecord> {
        ensure!(
            v.instance_id() == self.vault_scope,
            "原临时连接配置库已改变；请重新打开确认"
        );
        let repo = hspterm_storage_sync::Repository::new(v);
        let host = repo
            .host(&self.host_id)?
            .context("原保存主机已删除；未建立连接")?;
        let jump = repo.jump_host(&host)?;
        ensure!(
            metadata_tag(&host, jump.as_ref())? == self.metadata_tag,
            "原主机或跳板配置已改变；请重新打开本次覆盖确认"
        );
        Ok(host)
    }
}

pub(crate) struct PreparedOverride {
    pub target: OverrideTarget,
    /// None means the one explicitly selected saved authentication method.
    pub authentication: Option<Authentication>,
}

/// One call's secret-bearing request, created before any async work. No Debug
/// or persistent representation. The caller must check Source before file IO
/// and again when capturing the final route under the original Vault gate.
pub(crate) struct Request {
    pub source: TemporarySource,
    pub target: OverrideTarget,
    password: Option<Zeroizing<String>>,
    key_file: Option<String>,
    passphrase: Option<Zeroizing<String>>,
}
impl Request {
    pub fn new(
        source: TemporarySource,
        target: OverrideTarget,
        password: Option<String>,
        key_file: Option<String>,
        passphrase: Option<String>,
    ) -> Self {
        Self {
            source,
            target,
            password: password.map(Zeroizing::new),
            key_file,
            passphrase: passphrase.map(Zeroizing::new),
        }
    }
    pub async fn prepare(self) -> Result<(TemporarySource, PreparedOverride)> {
        let prepared =
            prepare_guarded(self.target, self.password, self.key_file, self.passphrase).await?;
        Ok((self.source, prepared))
    }
}

async fn prepare_guarded(
    target: OverrideTarget,
    password: Option<Zeroizing<String>>,
    key_file: Option<String>,
    passphrase: Option<Zeroizing<String>>,
) -> Result<PreparedOverride> {
    target.validate()?;
    let authentication = match target.method {
        Method::Saved => {
            ensure!(
                password.is_none() && key_file.is_none() && passphrase.is_none(),
                "沿用保存认证时不能同时提供本次秘密"
            );
            None
        }
        Method::Password => {
            ensure!(
                key_file.is_none() && passphrase.is_none(),
                "密码认证不能混入私钥参数"
            );
            let password = password.context("请明确提供本次密码（允许空密码）")?;
            ensure!(password.len() <= 64 * 1024, "本次密码超过大小上限");
            Some(Authentication::Password(password))
        }
        Method::PrivateKey => {
            ensure!(password.is_none(), "私钥认证不能自动回退到密码");
            ensure!(
                passphrase.as_ref().is_none_or(|p| p.len() <= 64 * 1024),
                "本次私钥口令超过大小上限"
            );
            let path = PathBuf::from(key_file.context("请明确选择本次私钥文件")?);
            ensure!(path.is_absolute(), "请选择本次私钥的完整文件位置");
            static READS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(4);
            let permit = READS.acquire().await.context("本次私钥读取已停止")?;
            let openssh = tokio::task::spawn_blocking(move || -> Result<Zeroizing<String>> {
                let _permit = permit;
                ensure!(
                    std::fs::metadata(&path)
                        .context("无法读取本次私钥文件")?
                        .is_file(),
                    "本次私钥必须是普通文件"
                );
                let file = std::fs::File::open(&path).context("无法打开本次私钥文件")?;
                ensure!(file.metadata()?.is_file(), "本次私钥必须是普通文件");
                let mut raw = Zeroizing::new(Vec::new());
                file.take(256 * 1024 + 1)
                    .read_to_end(&mut raw)
                    .context("无法完整读取本次私钥")?;
                ensure!(raw.len() <= 256 * 1024, "本次私钥超过大小上限");
                Ok(Zeroizing::new(
                    std::str::from_utf8(&raw)
                        .context("本次私钥文件不是UTF-8文本")?
                        .to_owned(),
                ))
            })
            .await
            .map_err(|_| anyhow::anyhow!("本次私钥读取任务失败"))??;
            // The existing core authenticates/validates the selected key exactly
            // once, with bounded KDF work and without trying another method.
            Some(Authentication::PrivateKey {
                openssh,
                passphrase,
            })
        }
    };
    Ok(PreparedOverride {
        target,
        authentication,
    })
}

#[cfg(test)]
fn prepare(
    target: OverrideTarget,
    password: Option<String>,
    key_file: Option<String>,
    passphrase: Option<String>,
) -> impl std::future::Future<Output = Result<PreparedOverride>> {
    prepare_guarded(
        target,
        password.map(Zeroizing::new),
        key_file,
        passphrase.map(Zeroizing::new),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    fn target(method: Method) -> OverrideTarget {
        OverrideTarget {
            address: "127.0.0.1".into(),
            port: 22,
            username: "fixture".into(),
            method,
        }
    }
    #[tokio::test]
    async fn explicit_modes_do_not_guess_credentials_or_read_unselected_paths() {
        assert!(
            prepare(target(Method::Saved), Some("synthetic".into()), None, None)
                .await
                .is_err()
        );
        assert!(
            prepare(
                target(Method::Saved),
                None,
                Some("/does/not/exist".into()),
                None
            )
            .await
            .is_err()
        );
        assert!(
            prepare(target(Method::Saved), None, None, None)
                .await
                .unwrap()
                .authentication
                .is_none()
        );
        assert!(
            prepare(target(Method::Password), None, None, None)
                .await
                .is_err()
        );
        assert!(
            matches!(prepare(target(Method::Password), Some(String::new()), None, None).await.unwrap().authentication,
            Some(Authentication::Password(p)) if p.is_empty())
        );
        assert!(
            prepare(
                target(Method::PrivateKey),
                Some("synthetic".into()),
                Some("/does/not/exist".into()),
                None
            )
            .await
            .is_err()
        );
        assert!(
            prepare(
                target(Method::PrivateKey),
                None,
                Some("relative-key".into()),
                None
            )
            .await
            .is_err()
        );
    }
    #[test]
    fn invalid_metadata_is_rejected_without_network_or_storage() {
        for address in ["", " leading", "line\nfeed", "name\0suffix"] {
            let mut t = target(Method::Saved);
            t.address = address.into();
            assert!(t.validate().is_err());
        }
        let mut t = target(Method::Saved);
        t.port = 0;
        assert!(t.validate().is_err());
        let mut t = target(Method::Saved);
        t.username = "bad\rname".into();
        assert!(t.validate().is_err());
    }
    #[tokio::test]
    async fn source_guards_vault_target_jump_and_deletion_without_changing_saved_metadata() {
        use hspterm_storage_sync::{AuthMethod, Credential, HostRecord, Repository, Vault};
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("once");
        let mut vault = Vault::create(&path, b"synthetic-once-master").unwrap();
        let jump = Repository::new(&mut vault)
            .save(
                HostRecord::new(
                    "jump".into(),
                    "jump.invalid".into(),
                    "fixture".into(),
                    AuthMethod::Password,
                ),
                Some(Credential {
                    secret: "synthetic-jump-password".into(),
                    passphrase: None,
                }),
            )
            .unwrap();
        let mut h = HostRecord::new(
            "source".into(),
            "saved.invalid".into(),
            "fixture".into(),
            AuthMethod::Password,
        );
        h.jump_host_id = Some(jump.id.clone());
        let h = Repository::new(&mut vault)
            .save(
                h,
                Some(Credential {
                    secret: "synthetic-source-password".into(),
                    passphrase: None,
                }),
            )
            .unwrap();
        let source = TemporarySource::capture(&mut vault, &h.id).unwrap();
        let mut snapshot = source.check(&mut vault).unwrap();
        let selected = OverrideTarget {
            address: "override.invalid".into(),
            port: 2222,
            username: "other-user".into(),
            method: Method::Password,
        };
        selected.apply(&mut snapshot).unwrap();
        assert_eq!(snapshot.address, "override.invalid");
        assert_eq!(
            Repository::new(&mut vault)
                .host(&h.id)
                .unwrap()
                .unwrap()
                .address,
            "saved.invalid"
        );
        let mut reopened = Vault::open(&path, b"synthetic-once-master").unwrap();
        assert!(source.check(&mut reopened).is_err());
        let mut changed_jump = jump;
        changed_jump.port = 2223;
        Repository::new(&mut vault)
            .save(changed_jump, None)
            .unwrap();
        assert!(source.check(&mut vault).is_err());
        let current_source = TemporarySource::capture(&mut vault, &h.id).unwrap();
        Repository::new(&mut vault)
            .delete(std::slice::from_ref(&h.id))
            .unwrap();
        assert!(current_source.check(&mut vault).is_err());
    }

    #[tokio::test]
    async fn one_off_private_reads_are_explicit_bounded_and_do_not_run_a_decoder_or_write_storage()
    {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("selected-key");
        std::fs::write(&path, b"synthetic-private-input-not-a-real-key").unwrap();
        let prepared = prepare(
            target(Method::PrivateKey),
            None,
            Some(path.to_str().unwrap().into()),
            Some("synthetic-passphrase".into()),
        )
        .await
        .unwrap();
        assert!(
            matches!(prepared.authentication, Some(Authentication::PrivateKey { openssh, passphrase })
            if openssh.as_str() == "synthetic-private-input-not-a-real-key" && passphrase.as_deref().map(|p| p.as_str()) == Some("synthetic-passphrase"))
        );
        std::fs::write(&path, vec![0; 256 * 1024 + 1]).unwrap();
        assert!(
            prepare(
                target(Method::PrivateKey),
                None,
                Some(path.to_str().unwrap().into()),
                None
            )
            .await
            .is_err()
        );
        assert!(
            prepare(
                target(Method::PrivateKey),
                None,
                Some(dir.path().to_str().unwrap().into()),
                None
            )
            .await
            .is_err()
        );
    }
}
