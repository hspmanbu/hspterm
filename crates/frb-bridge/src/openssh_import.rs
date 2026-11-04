//! No implicit local config access. Callers provide an explicit UTF-8 snapshot.
use crate::api::{HostConfig, with_vault};
use anyhow::{Context, Result, ensure};
use hspterm_storage_sync::{Repository, openssh_import};
use zeroize::Zeroizing;

#[derive(Clone)]
pub struct OpenSshImportHost {
    pub alias: String,
    pub address: String,
    pub port: u16,
    pub username: String,
    pub private_key: bool,
    pub timeout_seconds: u32,
    pub keepalive_seconds: u32,
    pub keepalive_failures: u32,
    pub jump_alias: Option<String>,
    pub warnings: Vec<String>,
    pub blocked: bool,
    pub name_exists: bool,
}
#[derive(Clone)]
pub struct OpenSshImportPreview {
    pub vault_scope: String,
    pub hosts: Vec<OpenSshImportHost>,
    pub warnings: Vec<String>,
}
pub(crate) async fn preview(
    source: String,
    default_username: String,
) -> Result<OpenSshImportPreview> {
    let source = Zeroizing::new(source);
    tokio::task::spawn_blocking(move || {
        let parsed = openssh_import::preview(&source, &default_username)?;
        with_vault(|v| {
            let vault_scope = v.instance_id().to_owned();
            let names: std::collections::BTreeSet<_> = Repository::new(v)
                .list()?
                .into_iter()
                .map(|h| h.name.to_lowercase())
                .collect();
            let hosts = parsed
                .hosts
                .into_iter()
                .map(|h| OpenSshImportHost {
                    name_exists: names.contains(&h.alias.to_lowercase()),
                    alias: h.alias,
                    address: h.address,
                    port: h.port,
                    username: h.username,
                    private_key: h.private_key,
                    timeout_seconds: h.timeout_seconds,
                    keepalive_seconds: h.keepalive_seconds,
                    keepalive_failures: h.keepalive_failures,
                    jump_alias: h.jump_alias,
                    warnings: h.warnings,
                    blocked: h.blocked,
                })
                .collect();
            Ok(OpenSshImportPreview {
                vault_scope,
                hosts,
                warnings: parsed.warnings,
            })
        })
    })
    .await
    .context("SSH导入预览工作任务失败")?
}
pub(crate) async fn commit(
    source: String,
    default_username: String,
    aliases: Vec<String>,
    acknowledge_partial: bool,
    group_id: String,
    vault_scope: String,
) -> Result<Vec<HostConfig>> {
    let source = Zeroizing::new(source);
    tokio::task::spawn_blocking(move || {
        with_vault(|v| {
            ensure!(
                v.instance_id() == vault_scope,
                "配置库已重新打开，请重新预览后导入"
            );
            Ok(Repository::new(v)
                .import_openssh(
                    &source,
                    &default_username,
                    &aliases,
                    acknowledge_partial,
                    &group_id,
                )?
                .into_iter()
                .map(Into::into)
                .collect())
        })
    })
    .await
    .context("SSH导入保存工作任务失败")?
}
