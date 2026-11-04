//! One cancelable, original-Vault desktop OAuth operation. Only the browser URL
//! and non-secret repository metadata cross FRB. No startup work or token logs.
use anyhow::{Context, Result, ensure};
use hspterm_storage_sync::{
    cloud_sync::{
        drive_files::{ConfigurationObject, DriveFiles},
        drive_oauth::{self, Authorization, DesktopClient},
        drive_setup::{self, Creation},
        settings::{self, AuthorizationRoute},
    },
    google_drive_account::{self as accounts, Account, Source},
};
use parking_lot::Mutex;
use serde::Deserialize;
use std::sync::{
    Arc, OnceLock,
    atomic::{AtomicBool, Ordering},
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio_util::sync::CancellationToken;
use zeroize::{Zeroize, Zeroizing};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    vault_scope: String,
    revision: String,
    client_id: String,
    client_secret: String,
    confirm_replace: bool,
}
impl Drop for Input {
    fn drop(&mut self) {
        self.client_secret.zeroize();
    }
}
enum Flow {
    Authorize {
        source: Source,
        route: AuthorizationRoute,
        client: Option<DesktopClient>,
        listener: Option<Authorization>,
    },
    Remove {
        account: Account,
        route: AuthorizationRoute,
        remote: bool,
    },
    Discover {
        account: Account,
        route: AuthorizationRoute,
        settings: settings::View,
    },
    Objects {
        account: Account,
        route: AuthorizationRoute,
        settings: settings::View,
        objects: Vec<ConfigurationObject>,
    },
    Creation {
        account: Account,
        route: AuthorizationRoute,
        creation: Creation,
    },
}
struct Operation {
    id: String,
    stop: CancellationToken,
    gate: Arc<Semaphore>,
    flow: Mutex<Option<Flow>>,
    revoking: AtomicBool,
    revoked: AtomicBool,
    committed: AtomicBool,
    refreshing: AtomicBool,
    creating: AtomicBool,
    created: AtomicBool,
    staged: AtomicBool,
    permit: Mutex<Option<OwnedSemaphorePermit>>,
}
fn registry() -> &'static Mutex<Option<Arc<Operation>>> {
    static ROOT: OnceLock<Mutex<Option<Arc<Operation>>>> = OnceLock::new();
    ROOT.get_or_init(Default::default)
}
fn global_gate() -> Arc<Semaphore> {
    static GATE: OnceLock<Arc<Semaphore>> = OnceLock::new();
    GATE.get_or_init(|| Arc::new(Semaphore::new(1))).clone()
}
pub(crate) fn credential_lease() -> Result<Arc<OwnedSemaphorePermit>> {
    global_gate()
        .try_acquire_owned()
        .map(Arc::new)
        .map_err(|_| drive_oauth::AuthorizationError::Busy.into())
}
fn outcomes() -> &'static Mutex<std::collections::VecDeque<(String, &'static str)>> {
    static OUTCOMES: OnceLock<Mutex<std::collections::VecDeque<(String, &'static str)>>> =
        OnceLock::new();
    OUTCOMES.get_or_init(Default::default)
}
fn outcome(op: &Operation) -> &'static str {
    if op.revoked.load(Ordering::Acquire) {
        "revoked"
    } else if op.revoking.load(Ordering::Acquire) {
        "revoke_unknown"
    } else if op.committed.load(Ordering::Acquire) {
        "committed"
    } else if op.created.load(Ordering::Acquire) {
        "created"
    } else if op.creating.load(Ordering::Acquire) {
        "create_unknown"
    } else if op.refreshing.load(Ordering::Acquire) {
        "authorization_unknown"
    } else if op.staged.load(Ordering::Acquire) {
        "staged"
    } else {
        "cancelled"
    }
}
fn operation(id: &str) -> Result<Arc<Operation>> {
    registry()
        .lock()
        .as_ref()
        .filter(|o| o.id == id && !o.stop.is_cancelled())
        .cloned()
        .context("原 Google Drive 授权操作已结束或取消")
}
fn install(flow: Flow) -> Result<String> {
    let permit = global_gate()
        .try_acquire_owned()
        .context("另一个 Google Drive 授权操作尚未结束")?;
    let op = Arc::new(Operation {
        id: format!("drive-authorization-{:032x}", rand::random::<u128>()),
        stop: CancellationToken::new(),
        gate: Arc::new(Semaphore::new(1)),
        flow: Mutex::new(Some(flow)),
        revoking: AtomicBool::new(false),
        revoked: AtomicBool::new(false),
        committed: AtomicBool::new(false),
        refreshing: AtomicBool::new(false),
        creating: AtomicBool::new(false),
        created: AtomicBool::new(false),
        staged: AtomicBool::new(false),
        permit: Mutex::new(Some(permit)),
    });
    let mut root = registry().lock();
    ensure!(root.is_none(), "已有 Google Drive 授权操作");
    *root = Some(op.clone());
    let id = op.id.clone();
    tokio::spawn(async move {
        tokio::select! {
            _ = tokio::time::sleep(std::time::Duration::from_secs(300)) => {},
            _ = op.stop.cancelled() => {},
        }
        retire(&op).await;
    });
    Ok(id)
}
async fn retire(op: &Arc<Operation>) {
    {
        // Same lock as final SQL ACK. A cancellation cannot be observed only
        // after a grant was already committed and relabel that ACK as failure.
        let root = registry().lock();
        if root.as_ref().is_some_and(|o| o.id == op.id) {
            op.stop.cancel();
        }
    }
    let _lease = op.gate.clone().acquire_owned().await;
    op.flow.lock().take();
    let mut completed = outcomes().lock();
    completed.retain(|(id, _)| id != &op.id);
    if completed.len() >= 16 {
        completed.pop_front();
    }
    completed.push_back((op.id.clone(), outcome(op)));
    drop(completed);
    let mut root = registry().lock();
    if root.as_ref().is_some_and(|o| o.id == op.id) {
        root.take();
    }
    // The expiry task can still own an Arc after cancellation. Only real work
    // guarded by op.gate, not that inert reference, keeps credentials reserved.
    op.permit.lock().take();
}
pub(crate) fn vault_replaced() {
    if let Some(op) = registry().lock().as_ref() {
        op.stop.cancel();
    }
}
struct Abort {
    op: Arc<Operation>,
    complete: bool,
}
impl Drop for Abort {
    fn drop(&mut self) {
        if !self.complete {
            self.op.stop.cancel();
        }
    }
}
async fn rpc<T>(
    id: &str,
    f: impl AsyncFnOnce(Arc<Operation>, Arc<OwnedSemaphorePermit>) -> Result<T>,
) -> Result<T> {
    let op = operation(id)?;
    let lease = Arc::new(
        op.gate
            .clone()
            .try_acquire_owned()
            .context("Google Drive 原操作仍在执行")?,
    );
    let mut abort = Abort {
        op: op.clone(),
        complete: false,
    };
    let result = f(op.clone(), lease).await;
    abort.complete = result.is_ok();
    if result.is_err() {
        op.stop.cancel();
    }
    result
}
pub(crate) async fn reserve(input: String) -> Result<String> {
    let input = Zeroizing::new(input);
    ensure!(
        input.len() <= 16 * 1024,
        "Google Drive 客户端提交超过安全容量"
    );
    // Source reads and installation are in one original Vault critical section.
    tokio::task::spawn_blocking(move || {
        let mut input: Input = serde_json::from_str(&input)
            .map_err(|_| anyhow::anyhow!("Google Drive 授权配置格式无效"))?;
        let client = DesktopClient {
            client_id: input.client_id.clone(),
            client_secret: Zeroizing::new(std::mem::take(&mut input.client_secret)),
        };
        client.validate()?;
        crate::api::with_vault(|v| {
            let view = accounts::load(v)?;
            ensure!(
                view.authorization_id.is_none() || input.confirm_replace,
                "重新授权将替换本机旧授权，需要明确确认"
            );
            let source = accounts::source(v, &input.vault_scope, &input.revision)?;
            let route = settings::authorization_route(v)?;
            install(Flow::Authorize {
                source,
                route,
                client: Some(client),
                listener: None,
            })
        })
    })
    .await?
}
pub(crate) async fn prepare(id: String) -> Result<String> {
    rpc(&id, async |op, _lease| {
        let flow = op.flow.lock().take().context("原授权票据已使用")?;
        let Flow::Authorize {
            source,
            route,
            mut client,
            listener,
        } = flow
        else {
            anyhow::bail!("操作类型不符");
        };
        ensure!(listener.is_none(), "系统浏览器授权入口已经创建");
        let client = client.take().context("原客户端已使用")?;
        let authorization = tokio::select! { biased;
            _ = op.stop.cancelled() => anyhow::bail!("原 Google Drive 授权已取消"),
            result = Authorization::bind(client, route.proxy(), route.timeout_seconds()) => result?,
        };
        ensure!(!op.stop.is_cancelled(), "原 Google Drive 授权已取消");
        let url = authorization.authorization_url();
        *op.flow.lock() = Some(Flow::Authorize {
            source,
            route,
            client: None,
            listener: Some(authorization),
        });
        Ok(url)
    })
    .await
}
pub(crate) async fn finish(id: String) -> Result<String> {
    rpc(&id, async |op, lease| {
        let flow = op.flow.lock().take().context("原授权票据已使用")?;
        let Flow::Authorize {
            source,
            route,
            listener,
            ..
        } = flow
        else {
            anyhow::bail!("操作类型不符");
        };
        let grant = listener
            .context("先在原操作准备系统浏览器授权")?
            .finish(&op.stop)
            .await?;
        tokio::task::spawn_blocking(move || {
            let _lease = lease;
            crate::api::with_vault(|v| {
                let root = registry().lock();
                ensure!(
                    root.as_ref().is_some_and(|o| o.id == op.id) && !op.stop.is_cancelled(),
                    "原授权已取消，没有保存账号"
                );
                route.ensure_current(v)?;
                let target = settings::load(v)?;
                let saved = source.save(v, grant, &route.preconditions()).map_err(|_| {
                    anyhow::anyhow!(
                        "本机授权未能保存；原来源可能已改变或存储失败，请读取当前状态后重新授权"
                    )
                })?;
                crate::configuration_sync::authorization_changed(&target, &saved);
                op.committed.store(true, Ordering::Release);
                op.stop.cancel();
                Ok(serde_json::to_string(&saved)?)
            })
        })
        .await?
    })
    .await
}
pub(crate) async fn reserve_removal(
    scope: String,
    revision: String,
    remote: bool,
) -> Result<String> {
    tokio::task::spawn_blocking(move || {
        crate::api::with_vault(|v| {
            let account = accounts::capture(v, &scope, &revision)?;
            let route = settings::authorization_route(v)?;
            install(Flow::Remove {
                account,
                route,
                remote,
            })
        })
    })
    .await?
}
pub(crate) async fn remove(id: String) -> Result<String> {
    rpc(&id, async |op, lease| {
        let flow = op.flow.lock().take().context("原账号移除票据已使用")?;
        let Flow::Remove { account, route, remote } = flow else { anyhow::bail!("操作类型不符"); };
        if remote {
            op.revoking.store(true, Ordering::Release);
            drive_oauth::revoke(account.refresh_token(), route.proxy(), route.timeout_seconds(), &op.stop).await?;
            op.revoked.store(true, Ordering::Release);
        }
        tokio::task::spawn_blocking(move || {
            let _lease = lease;
            crate::api::with_vault(|v| {
                let root = registry().lock();
                ensure!(root.as_ref().is_some_and(|o| o.id == op.id) && !op.stop.is_cancelled(), "原移除操作已取消；请重新读取本机账号状态");
                route.ensure_current(v)?;
                let target = settings::load(v)?;
                let saved = account.remove_checked(v, &route.preconditions()).map_err(|_| anyhow::anyhow!("本机授权未能删除；原来源可能已改变或存储失败；若刚请求撤销，Google 端可能已经生效"))?;
                crate::configuration_sync::authorization_changed(&target, &saved);
                op.committed.store(true, Ordering::Release);
                op.stop.cancel();
                Ok(serde_json::to_string(&saved)?)
            })
        }).await?
    }).await
}

/// Reserve before HTTP so cancellation/exit can always wait for the exact
/// original discovery. The single credential lease spans user selection too.
pub(crate) async fn reserve_discovery(scope: String, revision: String) -> Result<String> {
    tokio::task::spawn_blocking(move || {
        crate::api::with_vault(|v| {
            let account = accounts::capture(v, &scope, &revision)?;
            let route = settings::authorization_route(v)?;
            let metadata = settings::load(v)?;
            route.ensure_current(v)?;
            account.ensure_current(v)?;
            install(Flow::Discover {
                account,
                route,
                settings: metadata,
            })
        })
    })
    .await?
}

async fn refreshed_files(
    op: &Arc<Operation>,
    lease: &Arc<OwnedSemaphorePermit>,
    account: Account,
    route: AuthorizationRoute,
) -> Result<(Account, DriveFiles, AuthorizationRoute)> {
    let held = lease.clone();
    let source = op.clone();
    let (account, route) = tokio::task::spawn_blocking(move || {
        let _lease = held;
        crate::api::with_vault(|v| {
            let root = registry().lock();
            ensure!(
                root.as_ref().is_some_and(|o| o.id == source.id) && !source.stop.is_cancelled(),
                "原发现已取消"
            );
            route.ensure_current(v)?;
            account.ensure_current(v)?;
            Ok((account, route))
        })
    })
    .await??;
    let client = account.client();
    op.refreshing.store(true, Ordering::Release);
    let response = drive_oauth::refresh(
        &client,
        account.refresh_token(),
        route.proxy(),
        route.timeout_seconds(),
        &op.stop,
    )
    .await?;
    drop(client);
    let held = lease.clone();
    let source = op.clone();
    let (account, access, route) = tokio::task::spawn_blocking(move || {
        let _lease = held;
        crate::api::with_vault(|v| {
            let root = registry().lock();
            ensure!(
                root.as_ref().is_some_and(|o| o.id == source.id) && !source.stop.is_cancelled(),
                "原发现已取消；刷新结果可能未知"
            );
            route.ensure_current(v)?;
            let (account, access) = account.accept_refresh(v, response, &route.preconditions())?;
            source.refreshing.store(false, Ordering::Release);
            Ok((account, access, route))
        })
    })
    .await??;
    let held = lease.clone();
    let (files, route) = tokio::task::spawn_blocking(move || {
        let _lease = held;
        Ok::<_, anyhow::Error>((
            DriveFiles::new(access, route.proxy(), route.timeout_seconds())?,
            route,
        ))
    })
    .await??;
    Ok((account, files, route))
}

pub(crate) async fn discover(id: String) -> Result<String> {
    rpc(&id, async |op, lease| {
        let flow = op.flow.lock().take().context("原发现票据已使用")?;
        let Flow::Discover {
            account,
            route,
            settings,
        } = flow
        else {
            anyhow::bail!("操作类型不符");
        };
        let (account, files, route) = refreshed_files(&op, &lease, account, route).await?;
        let objects = files.discover(&op.stop).await?;
        // Access token/client die here. The UI retains only metadata and the
        // source capability; selection performs no additional network request.
        drop(files);
        tokio::task::spawn_blocking(move || {
            let _lease = lease;
            crate::api::with_vault(|v| {
                let root = registry().lock();
                ensure!(
                    root.as_ref().is_some_and(|o| o.id == op.id) && !op.stop.is_cancelled(),
                    "原发现已取消"
                );
                route.ensure_current(v)?;
                account.ensure_current(v)?;
                let metadata = accounts::load(v)?;
                let result = serde_json::to_string(&serde_json::json!({
                    "operation": op.id, "account": metadata,
                    "settings": settings, "objects": objects,
                }))?;
                *op.flow.lock() = Some(Flow::Objects {
                    account,
                    route,
                    settings,
                    objects,
                });
                Ok(result)
            })
        })
        .await?
    })
    .await
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ObjectSelection {
    id: String,
    enabled: bool,
    sync_password: Option<String>,
    confirm_target_change: bool,
}
impl Drop for ObjectSelection {
    fn drop(&mut self) {
        self.sync_password.zeroize();
    }
}
fn object_proposal(
    account: &Account,
    source: &settings::View,
    objects: &[ConfigurationObject],
    mut choice: ObjectSelection,
) -> Result<settings::Proposal> {
    let object = objects
        .iter()
        .find(|o| o.id == choice.id)
        .context("只能选择原发现结果中的对象")?;
    let target = settings::Target {
        enabled: choice.enabled,
        endpoint: DriveFiles::object_endpoint(&object.id)?,
        collection: object.collection.clone(),
        authenticate: false,
        timeout_seconds: source.target.as_ref().map_or(60, |t| t.timeout_seconds),
        proxy: source.target.as_ref().and_then(|t| t.proxy.clone()),
        drive: Some(settings::DriveTarget {
            file_id: object.id.clone(),
            client_id: account.client_id().into(),
            authorization_id: account.authorization_id().into(),
        }),
    };
    let same = source
        .target
        .as_ref()
        .is_some_and(|t| t.same_object(&target));
    ensure!(
        same || choice.sync_password.as_ref().is_some_and(|p| !p.is_empty()),
        "选择不同对象须明确填写该集合的端到端同步密码"
    );
    Ok(settings::Proposal {
        vault_scope: source.vault_scope.clone(),
        revision: source.revision.clone(),
        secrets: settings::SecretChanges {
            sync_password: choice.sync_password.take(),
            webdav: settings::CredentialChange::Remove,
            proxy: if target.proxy.as_ref().is_some_and(|p| p.authenticate) {
                settings::CredentialChange::Keep
            } else {
                settings::CredentialChange::Remove
            },
        },
        target,
        confirm_target_change: choice.confirm_target_change,
    })
}

/// Select an existing discovered object. This saves a local encrypted target;
/// it does NOT create a file, upload configuration, or assume a missing object.
pub(crate) async fn select_object(id: String, input: String) -> Result<String> {
    let input = Zeroizing::new(input);
    ensure!(input.len() <= 16 * 1024, "对象选择提交超过安全容量");
    rpc(&id, async |op, lease| {
        let flow = op.flow.lock().take().context("原选择票据已使用")?;
        let Flow::Objects {
            account,
            route,
            settings,
            objects,
        } = flow
        else {
            anyhow::bail!("操作类型不符");
        };
        tokio::task::spawn_blocking(move || {
            let _lease = lease;
            let input: ObjectSelection =
                serde_json::from_str(&input).map_err(|_| anyhow::anyhow!("对象选择格式无效"))?;
            let proposal = object_proposal(&account, &settings, &objects, input)?;
            crate::api::with_vault(|v| {
                let root = registry().lock();
                ensure!(
                    root.as_ref().is_some_and(|o| o.id == op.id) && !op.stop.is_cancelled(),
                    "原选择已取消"
                );
                route.ensure_current(v)?;
                account.ensure_current(v)?;
                let saved = settings::save(v, proposal)?;
                crate::configuration_sync::settings_saved(
                    &saved.vault_scope,
                    saved.target.as_ref().is_some_and(|t| t.enabled),
                );
                op.committed.store(true, Ordering::Release);
                op.stop.cancel();
                Ok(serde_json::to_string(&saved)?)
            })
        })
        .await?
    })
    .await
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NewCollection {
    password: String,
    enabled: bool,
    confirm_target_change: bool,
    confirm_sensitive_upload: bool,
}
impl Drop for NewCollection {
    fn drop(&mut self) {
        self.password.zeroize();
    }
}
pub(crate) async fn pending_creation() -> Result<String> {
    tokio::task::spawn_blocking(|| {
        crate::api::with_vault(|v| Ok(serde_json::to_string(&drive_setup::load(v)?)?))
    })
    .await?
}
pub(crate) async fn reserve_creation(
    scope: String,
    account_revision: String,
    creation_revision: String,
) -> Result<String> {
    tokio::task::spawn_blocking(move || {
        crate::api::with_vault(|v| {
            let account = accounts::capture(v, &scope, &account_revision)?;
            let creation = drive_setup::capture(v, &scope, &creation_revision)?;
            creation.ensure_source(v, &account)?;
            let route = settings::authorization_route(v)?;
            install(Flow::Creation {
                account,
                route,
                creation,
            })
        })
    })
    .await?
}
/// Stage only: generate one private ID, freeze/validate the initial document,
/// and commit the encrypted local intent. No remote file is created here.
pub(crate) async fn prepare_creation(id: String, input: String) -> Result<String> {
    let input = Zeroizing::new(input);
    ensure!(input.len() <= 24 * 1024, "新集合提交超过安全容量");
    rpc(&id, async |op, lease| {
        let mut input: NewCollection = serde_json::from_str(&input).map_err(|_| anyhow::anyhow!("新集合提交格式无效"))?;
        ensure!(input.confirm_sensitive_upload && !input.password.is_empty() && input.password.len() <= 4096, "须明确同意包含凭据和合格命令历史的加密初始快照，并填写同步密码");
        let flow = op.flow.lock().take().context("原发现票据已使用")?;
        let Flow::Objects { account, route, settings, .. } = flow else { anyhow::bail!("先明确发现已有对象，再选择新建集合"); };
        ensure!(settings.target.is_none() || input.confirm_target_change, "更换唯一目标需要明确确认");
        let held = lease.clone();
        tokio::task::spawn_blocking(move || {
            let _lease = held;
            crate::api::with_vault(|v| {
                ensure!(drive_setup::load(v)?.is_none(), "本机已有待恢复创建，请先核对原ID，不要重复创建");
                Ok(())
            })
        }).await??;
        let (account, files, route) = refreshed_files(&op, &lease, account, route).await?;
        let reserved = files.reserve_object(&op.stop).await?;
        drop(files);
        let password = Zeroizing::new(std::mem::take(&mut input.password));
        tokio::task::spawn_blocking(move || {
            let _lease = lease;
            crate::api::with_vault(|v| {
                let root = registry().lock();
                ensure!(root.as_ref().is_some_and(|o| o.id == op.id) && !op.stop.is_cancelled(), "原新建准备已取消");
                let creation = drive_setup::stage(v, &account, &route, reserved, password, input.enabled, input.confirm_target_change)?;
                op.staged.store(true, Ordering::Release);
                let metadata = creation.view(v)?;
                let account_view = accounts::load(v)?;
                let result = serde_json::to_string(&serde_json::json!({"operation": op.id, "creation": metadata, "account": account_view}))?;
                *op.flow.lock() = Some(Flow::Creation { account, route, creation });
                Ok(result)
            })
        }).await?
    }).await
}
/// Explicit first publication/resume. Always GET the original generated ID;
/// only an authenticated 404 of that capability permits POST of the SAME body.
pub(crate) async fn finish_creation(id: String) -> Result<String> {
    rpc(&id, async |op, lease| {
        let flow = op.flow.lock().take().context("原创建票据已使用")?;
        let Flow::Creation {
            account,
            route,
            creation,
        } = flow
        else {
            anyhow::bail!("操作类型不符");
        };
        let held = lease.clone();
        let (account, creation) = tokio::task::spawn_blocking(move || {
            let _lease = held;
            crate::api::with_vault(|v| {
                creation.ensure_source(v, &account)?;
                Ok((account, creation))
            })
        })
        .await??;
        let (account, files, route) = refreshed_files(&op, &lease, account, route).await?;
        let held = lease.clone();
        let source = op.clone();
        let (account, creation) = tokio::task::spawn_blocking(move || {
            let _lease = held;
            crate::api::with_vault(|v| {
                ensure!(!source.stop.is_cancelled(), "原创建已取消");
                route.ensure_current(v)?;
                creation.ensure_source(v, &account)?;
                Ok((account, creation))
            })
        })
        .await??;
        let reserved = creation.reserved()?;
        let read = files
            .read_reserved(&reserved, creation.collection(), &op.stop)
            .await?;
        let held = lease.clone();
        let source = op.clone();
        let (account, creation, upload, present) = tokio::task::spawn_blocking(move || {
            let _lease = held;
            crate::api::with_vault(|v| {
                ensure!(!source.stop.is_cancelled(), "原创建已取消");
                creation.ensure_source(v, &account)?;
                let (creation, present) = match read {
                    hspterm_storage_sync::cloud_sync::RemoteRead::Missing => {
                        (creation.mark_attempt(v, &account)?, None)
                    }
                    hspterm_storage_sync::cloud_sync::RemoteRead::Present { etag, ciphertext } => {
                        ensure!(
                            creation.same_ciphertext(&ciphertext),
                            "原生成ID下已有不同内容，未覆盖，请保留本机记录并核对"
                        );
                        (creation, Some(etag))
                    }
                };
                let upload =
                    creation.upload(hspterm_storage_sync::cloud_sync::journal::now_millis()?)?;
                Ok((account, creation, upload, present))
            })
        })
        .await??;
        let acknowledged = if let Some(etag) = present {
            upload.acknowledge(etag)
        } else {
            op.creating.store(true, Ordering::Release);
            match files.create(creation.reserved()?, upload, &op.stop).await? {
                hspterm_storage_sync::cloud_sync::webdav::PutResponse::Confirmed(ack) => ack,
                hspterm_storage_sync::cloud_sync::webdav::PutResponse::PreconditionFailed => {
                    anyhow::bail!("原ID已存在或创建条件冲突；请明确重试以读取核对，不生成其他ID")
                }
            }
        };
        op.created.store(true, Ordering::Release);
        drop(files);
        tokio::task::spawn_blocking(move || {
            let _lease = lease;
            crate::api::with_vault(|v| {
                let root = registry().lock();
                ensure!(
                    root.as_ref().is_some_and(|o| o.id == op.id) && !op.stop.is_cancelled(),
                    "远端对象已确认；本机选择可能尚未提交，请保留原恢复记录"
                );
                let saved = creation.finish(v, &account, &acknowledged)?;
                crate::configuration_sync::settings_saved(
                    &saved.vault_scope,
                    saved.target.as_ref().is_some_and(|t| t.enabled),
                );
                op.committed.store(true, Ordering::Release);
                op.stop.cancel();
                Ok(serde_json::to_string(&saved)?)
            })
        })
        .await?
    })
    .await
}
pub(crate) async fn discard_creation(scope: String, revision: String, confirm: bool) -> Result<()> {
    let lease = credential_lease()?;
    tokio::task::spawn_blocking(move || {
        let _lease = lease;
        crate::api::with_vault(|v| {
            drive_setup::discard(v, &scope, &revision, confirm)?;
            Ok(())
        })
    })
    .await?
}
pub(crate) async fn cancel(id: String) -> Result<String> {
    let op = registry().lock().as_ref().filter(|o| o.id == id).cloned();
    let Some(op) = op else {
        return Ok(outcomes()
            .lock()
            .iter()
            .find(|(known, _)| known == &id)
            .map_or("ended", |(_, code)| *code)
            .into());
    };
    retire(&op).await;
    Ok(outcome(&op).into())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn stored_account(v: &mut hspterm_storage_sync::Vault) -> Account {
        v.put(accounts::RECORD, br#"{"version":1,"authorization_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","client_id":"synthetic-client.apps.googleusercontent.com","client_secret":"","refresh_token":"synthetic-refresh-token"}"#).unwrap();
        let source = accounts::load(v).unwrap();
        accounts::capture(v, &source.vault_scope, &source.revision).unwrap()
    }
    #[test]
    fn object_selection_preserves_distinct_ids_and_requires_password_and_target_consent() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = hspterm_storage_sync::Vault::create(
            &dir.path().join("objects.vault"),
            b"synthetic-master",
        )
        .unwrap();
        let account = stored_account(&mut v);
        let source = settings::load(&v).unwrap();
        let objects = vec![
            ConfigurationObject {
                id: "synthetic-object-A".into(),
                collection: "b".repeat(32),
                bytes: 128,
            },
            ConfigurationObject {
                id: "synthetic-object-B".into(),
                collection: "b".repeat(32),
                bytes: 128,
            },
        ];
        let choose = |id: &str, password: bool, confirm| ObjectSelection {
            id: id.into(),
            enabled: false,
            sync_password: password.then(|| "synthetic-e2e-password".into()),
            confirm_target_change: confirm,
        };
        assert!(
            object_proposal(
                &account,
                &source,
                &objects,
                choose("synthetic-foreign-object", true, false)
            )
            .is_err()
        );
        assert!(
            object_proposal(
                &account,
                &source,
                &objects,
                choose(&objects[0].id, false, false)
            )
            .is_err()
        );
        let proposal = object_proposal(
            &account,
            &source,
            &objects,
            choose(&objects[1].id, true, false),
        )
        .unwrap();
        assert_eq!(
            proposal.target.drive.as_ref().unwrap().file_id,
            objects[1].id
        );
        let saved = settings::save(&mut v, proposal).unwrap();
        assert!(!saved.target.as_ref().unwrap().enabled);
        let rejected = object_proposal(
            &account,
            &saved,
            &objects,
            choose(&objects[0].id, true, false),
        )
        .unwrap();
        assert!(settings::save(&mut v, rejected).is_err());
        assert_eq!(settings::load(&v).unwrap().revision, saved.revision);
        let accepted = object_proposal(
            &account,
            &saved,
            &objects,
            choose(&objects[0].id, true, true),
        )
        .unwrap();
        assert_eq!(
            settings::save(&mut v, accepted)
                .unwrap()
                .target
                .unwrap()
                .drive
                .unwrap()
                .file_id,
            objects[0].id
        );
    }
    #[tokio::test]
    async fn discovery_reservation_excludes_other_refreshes_and_reports_unknown_rotation() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = hspterm_storage_sync::Vault::create(
            &dir.path().join("discovery.vault"),
            b"synthetic-master",
        )
        .unwrap();
        let account = stored_account(&mut v);
        let id = install(Flow::Discover {
            account,
            route: settings::authorization_route(&v).unwrap(),
            settings: settings::load(&v).unwrap(),
        })
        .unwrap();
        let op = operation(&id).unwrap();
        assert!(credential_lease().is_err());
        op.refreshing.store(true, Ordering::Release);
        assert_eq!(cancel(id).await.unwrap(), "authorization_unknown");
        assert!(op.flow.lock().is_none());
        drop(op);
        assert!(credential_lease().is_ok());
    }
    #[tokio::test]
    async fn staged_unknown_created_and_committed_outcomes_remain_distinct_through_cancel() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = hspterm_storage_sync::Vault::create(
            &dir.path().join("creation-outcome.vault"),
            b"synthetic-master",
        )
        .unwrap();
        let account = stored_account(&mut v);
        let id = install(Flow::Discover {
            account,
            route: settings::authorization_route(&v).unwrap(),
            settings: settings::load(&v).unwrap(),
        })
        .unwrap();
        let op = operation(&id).unwrap();
        op.staged.store(true, Ordering::Release);
        assert_eq!(outcome(&op), "staged");
        op.creating.store(true, Ordering::Release);
        assert_eq!(outcome(&op), "create_unknown");
        op.created.store(true, Ordering::Release);
        assert_eq!(outcome(&op), "created");
        op.committed.store(true, Ordering::Release);
        assert_eq!(cancel(id).await.unwrap(), "committed");
    }
    fn flow(v: &hspterm_storage_sync::Vault) -> Flow {
        let view = accounts::load(v).unwrap();
        Flow::Authorize {
            source: accounts::source(v, &view.vault_scope, &view.revision).unwrap(),
            route: settings::authorization_route(v).unwrap(),
            client: Some(DesktopClient {
                client_id: "synthetic-client.apps.googleusercontent.com".into(),
                client_secret: Zeroizing::new(String::new()),
            }),
            listener: None,
        }
    }
    // The bridge suite owns process-global Vault/registries; run Native fixture
    // tests serially in the unified stage, as with the existing SSH tests.
    #[tokio::test]
    async fn original_ticket_binds_one_listener_and_stale_cancel_cannot_close_it() {
        let dir = tempfile::tempdir().unwrap();
        let v = hspterm_storage_sync::Vault::create(
            &dir.path().join("oauth.vault"),
            b"synthetic-master",
        )
        .unwrap();
        let id = install(flow(&v)).unwrap();
        assert!(
            credential_lease().is_err(),
            "browser/discovery ownership must also exclude sync refresh"
        );
        assert_eq!(
            cancel("synthetic-foreign-operation".into()).await.unwrap(),
            "ended"
        );
        let url = prepare(id.clone()).await.unwrap();
        let redirect = url
            .split("redirect_uri=")
            .nth(1)
            .unwrap()
            .split('&')
            .next()
            .unwrap();
        assert!(redirect.starts_with("http%3A%2F%2F127.0.0.1%3A"));
        let root = operation(&id).unwrap();
        assert!(root.flow.lock().as_ref().is_some_and(|f| matches!(
            f,
            Flow::Authorize {
                listener: Some(_),
                ..
            }
        )));
        cancel(id).await.unwrap();
        assert!(root.flow.lock().is_none());
        assert!(registry().lock().is_none());
    }
    #[tokio::test]
    async fn cancellation_waits_for_the_real_blocking_worker_lease() {
        let dir = tempfile::tempdir().unwrap();
        let v = hspterm_storage_sync::Vault::create(
            &dir.path().join("lease.vault"),
            b"synthetic-master",
        )
        .unwrap();
        let id = install(flow(&v)).unwrap();
        let root = operation(&id).unwrap();
        let lease = Arc::new(root.gate.clone().acquire_owned().await.unwrap());
        let worker_lease = lease.clone();
        let (release, hold) = std::sync::mpsc::channel();
        let worker = tokio::task::spawn_blocking(move || {
            let _lease = worker_lease;
            hold.recv_timeout(std::time::Duration::from_secs(3))
                .unwrap();
        });
        drop(lease);
        let cancelled = tokio::spawn(cancel(id));
        root.stop.cancelled().await;
        assert!(!cancelled.is_finished());
        release.send(()).unwrap();
        worker.await.unwrap();
        cancelled.await.unwrap().unwrap();
        assert!(registry().lock().is_none());
    }
    #[tokio::test]
    async fn shared_credential_lease_is_held_by_the_actual_rotation_worker() {
        let lease = credential_lease().unwrap();
        let kept = lease.clone();
        let (release, hold) = std::sync::mpsc::channel();
        let worker = tokio::task::spawn_blocking(move || {
            let _lease = kept;
            hold.recv_timeout(std::time::Duration::from_secs(3))
                .unwrap();
        });
        drop(lease);
        assert!(credential_lease().is_err());
        release.send(()).unwrap();
        worker.await.unwrap();
        assert!(credential_lease().is_ok());
    }
}
