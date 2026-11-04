//! One bounded native backup operation/restore preview. Secrets never cross
//! back to Dart; all paths come from explicit system picker/save actions.
use anyhow::{Context, Result, ensure};
use hspterm_storage_sync::backup::{self, Snapshot};
use parking_lot::Mutex;
use std::{
    sync::{Arc, OnceLock},
    time::{Duration, Instant},
};
use zeroize::Zeroizing;

#[derive(Clone)]
struct Pending {
    ticket: String,
    scope: String,
    revision: String,
    incoming: Snapshot,
    expires: Instant,
}
#[derive(Default)]
struct Slot {
    request: String,
    pending: Option<Pending>,
}
static SLOT: OnceLock<Mutex<Slot>> = OnceLock::new();
fn slot() -> &'static Mutex<Slot> {
    SLOT.get_or_init(Default::default)
}
fn operation() -> Result<tokio::sync::OwnedSemaphorePermit> {
    static GATE: OnceLock<Arc<tokio::sync::Semaphore>> = OnceLock::new();
    GATE.get_or_init(|| Arc::new(tokio::sync::Semaphore::new(1)))
        .clone()
        .try_acquire_owned()
        .context("另一项备份/恢复操作尚未结束，请稍后重试")
}
fn pending(ticket: &str) -> Result<Pending> {
    let mut slot = slot().lock();
    if slot
        .pending
        .as_ref()
        .is_some_and(|p| Instant::now() >= p.expires)
    {
        slot.pending = None;
    }
    slot.pending
        .as_ref()
        .filter(|p| p.ticket == ticket && slot.request == ticket)
        .cloned()
        .context("恢复预览已过期或已关闭，请重新选择备份")
}
fn dto(ticket: &str, preview: &backup::Preview) -> Result<String> {
    Ok(serde_json::to_string(
        &serde_json::json!({ "ticket": ticket, "preview": preview }),
    )?)
}
pub(crate) async fn summary() -> Result<String> {
    let permit = operation()?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        crate::api::with_vault(|v| {
            let snapshot = Snapshot::capture(v)?;
            let preview = backup::preview(v, &snapshot, "merge")?;
            Ok(serde_json::to_string(&preview)?)
        })
    })
    .await?
}
pub(crate) async fn export(
    scope: String,
    revision: String,
    password: String,
    backup_password: String,
    path: String,
) -> Result<()> {
    let password = Zeroizing::new(password);
    let backup_password = Zeroizing::new(backup_password);
    ensure!(
        !backup_password.is_empty() && backup_password.len() <= 4096,
        "备份密码不能为空或超过4096字节"
    );
    let permit = operation()?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let snapshot = crate::api::with_vault(|v| {
            ensure!(v.instance_id() == scope, "原配置库已改变，请重新载入");
            v.verify_password(password.as_bytes())?;
            let snapshot = Snapshot::capture(v)?;
            ensure!(
                snapshot.revision(v) == revision,
                "配置已改变，请重新载入后导出"
            );
            Ok(snapshot)
        })?;
        snapshot.write_encrypted(std::path::Path::new(&path), backup_password.as_bytes())?;
        Ok(())
    })
    .await?
}
pub(crate) async fn begin(path: String, password: String, mode: String) -> Result<String> {
    ensure!(
        ["merge", "replace"].contains(&mode.as_str()),
        "恢复方式无效"
    );
    let password = Zeroizing::new(password);
    let permit = operation()?;
    let scope = crate::api::with_vault(|v| Ok(v.instance_id().to_owned()))?;
    let ticket = format!("backup-preview-{:032x}", rand::random::<u128>());
    {
        let mut slot = slot().lock();
        slot.request = ticket.clone();
        slot.pending = None;
    }
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let incoming = Snapshot::read_encrypted(std::path::Path::new(&path), password.as_bytes())?;
        crate::api::with_vault(|v| {
            ensure!(v.instance_id() == scope, "配置库已改变；未保留旧备份预览");
            let preview = backup::preview(v, &incoming, &mode)?;
            let mut slot = slot().lock();
            ensure!(slot.request == ticket, "恢复读取请求已失效");
            slot.pending = Some(Pending {
                ticket: ticket.clone(),
                scope,
                revision: preview.revision.clone(),
                incoming,
                expires: Instant::now() + Duration::from_secs(300),
            });
            let expired = ticket.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(300)).await;
                let _ = tokio::task::spawn_blocking(move || cancel(&expired)).await;
            });
            dto(&ticket, &preview)
        })
    })
    .await?
}
pub(crate) async fn repreview(ticket: String, mode: String) -> Result<String> {
    let permit = operation()?;
    let source = pending(&ticket)?;
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        crate::api::with_vault(|v| {
            ensure!(
                v.instance_id() == source.scope
                    && Snapshot::capture(v)?.revision(v) == source.revision,
                "原配置已改变；请重新选择备份"
            );
            let preview = backup::preview(v, &source.incoming, &mode)?;
            pending(&ticket)?;
            dto(&ticket, &preview)
        })
    })
    .await?
}
pub(crate) async fn apply(
    ticket: String,
    use_incoming: Vec<String>,
    password: String,
) -> Result<String> {
    ensure!(use_incoming.len() <= 30_000, "恢复选择超过容量");
    let permit = operation()?;
    let source = pending(&ticket)?;
    let password = Zeroizing::new(password);
    let agents = crate::agents::gate().write_owned().await;
    tokio::task::spawn_blocking(move || {
        let _permit = permit; let _agents = agents;
        crate::transfers::restore_configuration(|| crate::api::with_vault(|v| {
            let mut slot = slot().lock();
            ensure!(slot.request == ticket && slot.pending.as_ref().is_some_and(|p| p.ticket == ticket && Instant::now() < p.expires), "恢复预览已过期或被关闭");
            ensure!(v.instance_id() == source.scope, "原配置库已改变；没有恢复");
            v.verify_password(password.as_bytes())?;
            let plan = backup::prepare_restore(v, &source.incoming, &source.scope, &source.revision, &use_incoming)?;
            let next_scope = plan.next_scope().to_owned();
            let changed_hosts = plan.changed_hosts.len();
            let display_sources = crate::api::display_sources();
            let (settings, updates, preferences) = plan.inspect_candidate(|candidate| {
                let settings = hspterm_storage_sync::transfer_settings::TransferSettings::load(candidate)?;
                let updates = display_sources.into_iter().filter(|(_, s)| s.vault_scope == source.scope).map(|(id, old)| {
                    let decorator = crate::display::capture(candidate, old.host.as_deref()).map_err(|_| backup::BackupError::Invalid)?.decorator;
                    Ok((id, old.host, decorator))
                }).collect::<backup::Result<Vec<_>>>()?;
                let preferences = hspterm_storage_sync::terminal_preferences::load(candidate).map_err(|_| backup::BackupError::Invalid)?.value.validated().map_err(|_| backup::BackupError::Invalid)?;
                Ok((settings, updates, preferences))
            })?;
            // Revoke before commit under the same consent gate. If SQLite then
            // fails, configuration is unchanged; grants stay conservatively
            // revoked and are never silently reinstalled.
            crate::api::invalidate_backup_agents()?;
            plan.commit(v)?;
            crate::api::configuration_restored(&source.scope, &next_scope, updates, &preferences);
            slot.pending = None; slot.request.clear();
            Ok((serde_json::to_string(&serde_json::json!({ "committed": true, "vault_scope": next_scope, "changed_hosts": changed_hosts }))?, settings))
        }))
    }).await?
}
pub(crate) fn cancel(ticket: &str) {
    let mut slot = slot().lock();
    if slot.request == ticket {
        slot.pending = None;
        slot.request.clear();
    }
}
pub(crate) fn vault_replaced() {
    let mut slot = slot().lock();
    slot.pending = None;
    slot.request.clear();
}
