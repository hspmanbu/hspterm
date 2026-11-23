//! Application-owned sync monitor and one original-source operation. No HTTP at
//! registration, stream subscription or timer tick; Dart coalesces edit events.
use anyhow::{Context, Result, ensure};
use hspterm_storage_sync::{
    backup,
    cloud_sync::{
        self as cloud, Acknowledged, Baseline, Exchange, ExchangeStep, LocalProposal, drive_files,
        drive_oauth, settings, webdav,
    },
};
use parking_lot::Mutex;
use serde::Serialize;
use std::{
    sync::{
        Arc, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, watch};
use tokio_util::sync::CancellationToken;
#[cfg(test)]
#[path = "configuration_sync_tests.rs"]
mod tests;

#[derive(Clone, Serialize)]
pub(crate) struct Review {
    token: String,
    endpoint: String,
    collection: String,
    summary: cloud::MergeSummary,
    uploads: bool,
    references: bool,
}
#[derive(Clone, Serialize)]
pub(crate) struct Status {
    owner: String,
    vault_scope: String,
    sequence: u64,
    eligible: bool,
    operation: Option<String>,
    phase: &'static str,
    error: Option<&'static str>,
    review: Option<Review>,
    snapshots: Vec<cloud::SnapshotInfo>,
    commits: u64,
    configuration_updates: u64,
    remote_published: bool,
    write_unknown: bool,
    authorization_unknown: bool,
}
struct Owner {
    status: Mutex<Status>,
    operation: Mutex<Option<Arc<Operation>>>,
    stop: CancellationToken,
    changes: watch::Sender<u64>,
    initial_versions: std::collections::BTreeMap<String, u64>,
}
struct Operation {
    id: String,
    cancel: CancellationToken,
    gate: Arc<Semaphore>,
    pending: Mutex<Option<Workflow>>,
    started: AtomicBool,
    attempting_put: AtomicBool,
    remote_published: AtomicBool,
    authorization_unknown: AtomicBool,
    _permit: OwnedSemaphorePermit,
}
struct Workflow {
    baseline: Baseline,
    proposal: LocalProposal,
    target: settings::ActiveTarget,
    transport: Transport,
    exchange: Exchange,
    step: Option<ExchangeStep>,
    review: Option<String>,
    restore: bool,
}
enum Transport {
    WebDav(webdav::WebDav),
    Drive {
        files: drive_files::DriveFiles,
        id: String,
        collection: String,
    },
}
impl Transport {
    async fn read(
        &self,
        cancel: &CancellationToken,
    ) -> std::result::Result<cloud::RemoteRead, webdav::TransportError> {
        match self {
            Self::WebDav(client) => client.read(cancel).await,
            Self::Drive {
                files,
                id,
                collection,
            } => files.read(id, collection, cancel).await,
        }
    }
    async fn publish(
        &self,
        upload: cloud::PendingUpload,
        cancel: &CancellationToken,
    ) -> std::result::Result<webdav::PutResponse, webdav::TransportError> {
        match self {
            Self::WebDav(client) => client.publish(upload, cancel).await,
            Self::Drive { files, id, .. } => files.publish(id, upload, cancel).await,
        }
    }
}
fn registry() -> &'static Mutex<Option<Arc<Owner>>> {
    static OWNER: OnceLock<Mutex<Option<Arc<Owner>>>> = OnceLock::new();
    OWNER.get_or_init(Default::default)
}
fn gate() -> Arc<Semaphore> {
    static GATE: OnceLock<Arc<Semaphore>> = OnceLock::new();
    GATE.get_or_init(|| Arc::new(Semaphore::new(1))).clone()
}
fn retiring() -> &'static Mutex<std::collections::BTreeMap<String, Arc<Owner>>> {
    static RETIRING: OnceLock<Mutex<std::collections::BTreeMap<String, Arc<Owner>>>> =
        OnceLock::new();
    RETIRING.get_or_init(Default::default)
}
fn owner(id: &str) -> Result<Arc<Owner>> {
    let current = registry()
        .lock()
        .as_ref()
        .filter(|o| o.status.lock().owner == id)
        .cloned();
    current
        .or_else(|| retiring().lock().get(id).cloned())
        .context("同步监视器已关闭或属于原配置库")
}
impl Owner {
    fn emit(&self, edit: impl FnOnce(&mut Status)) {
        let mut state = self.status.lock();
        edit(&mut state);
        state.sequence = state.sequence.wrapping_add(1);
        self.changes.send_replace(state.sequence);
    }
    fn operation(&self, id: &str) -> Result<Arc<Operation>> {
        self.operation
            .lock()
            .as_ref()
            .filter(|o| o.id == id)
            .cloned()
            .context("原同步操作已结束")
    }
    fn check(&self, op: &Operation) -> Result<()> {
        let state = self.status.lock();
        ensure!(
            !self.stop.is_cancelled()
                && !op.cancel.is_cancelled()
                && self
                    .operation
                    .lock()
                    .as_ref()
                    .is_some_and(|o| o.id == op.id),
            "原同步操作已取消"
        );
        ensure!(
            state.operation.as_deref() == Some(op.id.as_str()),
            "同步操作身份已改变"
        );
        Ok(())
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}
struct AbortGuard {
    op: Arc<Operation>,
    completed: bool,
}
impl Drop for AbortGuard {
    fn drop(&mut self) {
        if !self.completed {
            self.op.cancel.cancel();
        }
    }
}
async fn blocking<T: Send + 'static>(
    lease: &Arc<OwnedSemaphorePermit>,
    f: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    let lease = lease.clone();
    tokio::task::spawn_blocking(move || {
        let _lease = lease;
        f()
    })
    .await
    .map_err(|_| anyhow::anyhow!("同步后台工作未正常结束"))?
}
fn failure(error: &anyhow::Error, op: &Operation) -> &'static str {
    if op.cancel.is_cancelled() {
        return "cancelled";
    }
    if error.is::<FirstReadMismatch>() {
        return "first_read_decrypt";
    }
    if error.is::<LegacyCollectionDataset>() {
        return "first_read_legacy_collection";
    }
    if let Some(e) = error.downcast_ref::<cloud::SyncError>() {
        return match e {
            cloud::SyncError::Changed => "source_changed",
            cloud::SyncError::References => "references",
            cloud::SyncError::Clock => "clock",
            cloud::SyncError::Capacity => "capacity",
            cloud::SyncError::Authorization => "authorization",
            _ => "data",
        };
    }
    if let Some(e) = error.downcast_ref::<drive_oauth::AuthorizationError>() {
        return match e {
            drive_oauth::AuthorizationError::Denied => "authorization",
            drive_oauth::AuthorizationError::Cancelled => "cancelled",
            drive_oauth::AuthorizationError::Configuration => "data",
            drive_oauth::AuthorizationError::Busy => "authorization_busy",
            _ => "network",
        };
    }
    if let Some(e) = error.downcast_ref::<webdav::TransportError>() {
        return match e {
            webdav::TransportError::WriteUnknown => "write_unknown",
            webdav::TransportError::Denied => "denied",
            webdav::TransportError::Directory => "directory",
            webdav::TransportError::Cancelled => "cancelled",
            webdav::TransportError::Capacity => "capacity",
            _ => "network",
        };
    }
    "failed"
}
fn finish(owner: &Owner, op: &Operation, code: &'static str) {
    let mut state = owner.status.lock();
    let mut current = owner.operation.lock();
    if !current.as_ref().is_some_and(|o| o.id == op.id) {
        return;
    }
    current.take();
    state.phase = if code == "cancelled" {
        "cancelled"
    } else {
        "failed"
    };
    state.error = Some(code);
    state.review = None;
    state.remote_published = op.remote_published.load(Ordering::Acquire);
    state.write_unknown = op.attempting_put.load(Ordering::Acquire) || code == "write_unknown";
    state.authorization_unknown = op.authorization_unknown.load(Ordering::Acquire);
    state.sequence = state.sequence.wrapping_add(1);
    owner.changes.send_replace(state.sequence);
    op.cancel.cancel();
}
pub(crate) fn open() -> Result<String> {
    crate::api::with_vault(|v| {
        let eligible = settings::eligible(v)?;
        let mut global = registry().lock();
        ensure!(
            global.as_ref().is_none_or(|o| o.stop.is_cancelled()),
            "已有活动同步监视器"
        );
        let id = format!("sync-owner-{:032x}", rand::random::<u128>());
        let (changes, _) = watch::channel(0);
        let initial_versions = cloud::journal::versions().borrow().clone();
        let root = Arc::new(Owner {
            status: Mutex::new(Status {
                owner: id.clone(),
                vault_scope: v.instance_id().into(),
                sequence: 0,
                eligible,
                operation: None,
                phase: "idle",
                error: None,
                review: None,
                snapshots: vec![],
                commits: 0,
                configuration_updates: 0,
                remote_published: false,
                write_unknown: false,
                authorization_unknown: false,
            }),
            operation: Mutex::new(None),
            stop: CancellationToken::new(),
            changes,
            initial_versions,
        });
        *global = Some(root);
        Ok(id)
    })
}
pub(crate) fn status(id: &str) -> Result<String> {
    Ok(serde_json::to_string(&*owner(id)?.status.lock())?)
}
pub(crate) async fn watch_status(
    id: String,
    sink: crate::frb_generated::StreamSink<String>,
) -> Result<()> {
    let root = owner(&id)?;
    let mut changes = root.changes.subscribe();
    let mut edits = cloud::journal::versions();
    // Snapshot only. Persisted dirty state at startup is not a new edit.
    let mut seen = root.initial_versions.clone();
    if sink
        .add(serde_json::to_string(
            &serde_json::json!({ "kind":"state", "value": &*root.status.lock() }),
        )?)
        .is_err()
    {
        return Ok(());
    }
    let current = edits.borrow_and_update().clone();
    let scope = root.status.lock().vault_scope.clone();
    if current.contains_key(&scope)
        && current.get(&scope) != seen.get(&scope)
        && sink
            .add(serde_json::to_string(
                &serde_json::json!({"kind":"configurationEdited","owner":id,"vault_scope":scope}),
            )?)
            .is_err()
    {
        return Ok(());
    }
    seen = current;
    loop {
        tokio::select! { biased;
            _ = root.stop.cancelled() => break,
            changed = changes.changed() => {
                if changed.is_err() { break; }
                let state = root.status.lock().clone();
                if sink.add(serde_json::to_string(&serde_json::json!({"kind":"state","value":state}))?).is_err() { break; }
            }
            edited = edits.changed() => {
                if edited.is_err() { break; }
                let versions = edits.borrow_and_update().clone();
                let state = root.status.lock().clone();
                let current = versions.get(&state.vault_scope).copied();
                let is_new = current.is_some() && current != seen.get(&state.vault_scope).copied();
                seen = versions;
                if is_new && sink.add(serde_json::to_string(&serde_json::json!({"kind":"configurationEdited","owner":id,"vault_scope":state.vault_scope}))?).is_err() { break; }
            }
        }
    }
    Ok(())
}
pub(crate) fn settings_saved(scope: &str, eligible: bool) {
    let root = registry().lock().clone();
    let Some(root) = root else {
        return;
    };
    if root.status.lock().vault_scope != scope || root.stop.is_cancelled() {
        return;
    }
    // Cancel an original-target request before another round can be issued.
    if let Some(op) = root.operation.lock().clone() {
        op.cancel.cancel();
    }
    root.emit(|s| {
        s.eligible = eligible;
        s.snapshots.clear();
    });
}
pub(crate) fn authorization_changed(
    target: &settings::View,
    account: &hspterm_storage_sync::google_drive_account::View,
) {
    let Some(target_value) = &target.target else {
        return;
    };
    let Some(binding) = &target_value.drive else {
        return;
    };
    if target.vault_scope != account.vault_scope {
        return;
    }
    let eligible = target_value.enabled
        && account.client_id.as_deref() == Some(binding.client_id.as_str())
        && account.authorization_id.as_deref() == Some(binding.authorization_id.as_str());
    // A Drive login/logout must not cancel an unrelated WebDAV operation.
    settings_saved(&target.vault_scope, eligible);
}
pub(crate) fn vault_replaced() {
    if let Some(root) = registry().lock().take() {
        root.stop.cancel();
        let operation = root.operation.lock().clone();
        if let Some(op) = operation {
            op.cancel.cancel();
            // Keep the original owner discoverable until the actual worker
            // gate drains. The application can still await close/cancel after
            // a backup restore or a successful Vault switch. One global
            // operation permit bounds owners with live resources to one.
            let id = root.status.lock().owner.clone();
            retiring().lock().insert(id.clone(), root.clone());
            tokio::spawn(async move {
                let _lease = op.gate.clone().acquire_owned().await;
                op.pending.lock().take();
                finish(&root, &op, "cancelled");
                retiring().lock().remove(&id);
            });
        }
    }
}
pub(crate) fn reserve(id: &str) -> Result<String> {
    let root = owner(id)?;
    let mut state = root.status.lock();
    let mut current = root.operation.lock();
    ensure!(
        !root.stop.is_cancelled() && current.is_none(),
        "另一项同步尚未结束"
    );
    let permit = gate()
        .try_acquire_owned()
        .context("上一次同步仍在释放资源，请稍后重试")?;
    let operation = format!("sync-operation-{:032x}", rand::random::<u128>());
    let op = Arc::new(Operation {
        id: operation.clone(),
        cancel: root.stop.child_token(),
        gate: Arc::new(Semaphore::new(1)),
        pending: Mutex::new(None),
        started: AtomicBool::new(false),
        attempting_put: AtomicBool::new(false),
        remote_published: AtomicBool::new(false),
        authorization_unknown: AtomicBool::new(false),
        _permit: permit,
    });
    *current = Some(op.clone());
    state.operation = Some(operation.clone());
    state.phase = "reserved";
    state.error = None;
    state.review = None;
    state.remote_published = false;
    state.write_unknown = false;
    state.authorization_unknown = false;
    state.sequence = state.sequence.wrapping_add(1);
    root.changes.send_replace(state.sequence);
    drop(current);
    drop(state);
    let weak = Arc::downgrade(&root);
    let weak_op = Arc::downgrade(&op);
    tokio::spawn(async move {
        tokio::select! { _ = op_stop(&weak_op) => {}, _ = tokio::time::sleep(Duration::from_secs(300)) => {} }
        if let (Some(root), Some(op)) = (weak.upgrade(), weak_op.upgrade())
            && root.operation(&op.id).is_ok()
        {
            op.cancel.cancel();
            let _lease = op.gate.clone().acquire_owned().await;
            op.pending.lock().take();
            finish(&root, &op, "cancelled");
        }
    });
    Ok(operation)
}
async fn op_stop(op: &std::sync::Weak<Operation>) {
    let token = op.upgrade().map(|o| o.cancel.clone());
    if let Some(token) = token {
        token.cancelled().await;
    }
}
fn acquire(root: &Arc<Owner>, op: &Arc<Operation>) -> Result<Arc<OwnedSemaphorePermit>> {
    root.check(op)?;
    Ok(Arc::new(
        op.gate
            .clone()
            .try_acquire_owned()
            .context("同步操作仍在处理中")?,
    ))
}
fn ensure_source(root: &Owner, op: &Operation, flow: &Workflow) -> Result<()> {
    crate::api::with_vault(|v| {
        root.check(op)?;
        flow.target.ensure_proposal(&flow.proposal)?;
        flow.target.ensure_current(v)?;
        flow.baseline
            .ensure_current(v, &flow.proposal, cloud::journal::now_millis()?)?;
        Ok(())
    })
}
/// The first verified read of an existing remote object cannot be decrypted
/// by this device: the sync password participates in collection derivation,
/// so it must match the device that originally created the dataset. Distinct
/// from a generic Invalid so the status panel can state the real cause.
#[derive(Debug)]
struct FirstReadMismatch;
impl std::fmt::Display for FirstReadMismatch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("无法读取云端配置：同步密码不匹配、版本不支持或数据损坏，未修改本机配置")
    }
}
impl std::error::Error for FirstReadMismatch {}

/// The remote object decrypts under this device's password but carries a
/// different collection identifier: a dataset created by an OLD (manual or
/// random collection) version. This device never synchronized that
/// identifier, so it must not silently adopt it — the original device
/// re-saves its sync target to migrate the dataset to the derived
/// identifier first. Distinct from a password mismatch.
#[derive(Debug)]
struct LegacyCollectionDataset;
impl std::fmt::Display for LegacyCollectionDataset {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(
            "云端数据集由旧版本标识创建：需在原设备重新保存同步目标迁移后再接入，未应用任何配置",
        )
    }
}
impl std::error::Error for LegacyCollectionDataset {}

/// Stable, typed run-log category for the configuration sync failure causes
/// that users can act on. Never formats foreign error payloads.
pub(crate) fn typed_kind(error: &anyhow::Error) -> Option<&'static str> {
    if error.is::<FirstReadMismatch>() {
        return Some("sync.first_read_decrypt");
    }
    if error.is::<LegacyCollectionDataset>() {
        return Some("sync.first_read_legacy_collection");
    }
    if let Some(e) = error.downcast_ref::<cloud::SyncError>() {
        return Some(match e {
            cloud::SyncError::Invalid => "sync.invalid",
            cloud::SyncError::Capacity => "sync.capacity",
            cloud::SyncError::Changed => "sync.changed",
            cloud::SyncError::Clock => "sync.clock",
            cloud::SyncError::References => "sync.references",
            cloud::SyncError::TargetChange => "sync.target_change",
            cloud::SyncError::KeyChange => "sync.key_change",
            cloud::SyncError::LegacyCollection => "sync.first_read_legacy_collection",
            cloud::SyncError::CredentialTarget => "sync.credential_target",
            cloud::SyncError::Authorization => "sync.authorization",
            cloud::SyncError::Storage(_) => "sync.storage",
        });
    }
    if let Some(e) = error.downcast_ref::<webdav::TransportError>() {
        return Some(match e {
            webdav::TransportError::Configuration => "webdav.configuration",
            webdav::TransportError::Cancelled => "webdav.cancelled",
            webdav::TransportError::Network => "webdav.network",
            webdav::TransportError::Denied => "webdav.denied",
            webdav::TransportError::Response => "webdav.response",
            webdav::TransportError::Directory => "webdav.directory",
            webdav::TransportError::Capacity => "webdav.capacity",
            webdav::TransportError::WriteUnknown => "webdav.write_unknown",
        });
    }
    None
}

async fn read_step(
    root: &Arc<Owner>,
    op: &Arc<Operation>,
    lease: &Arc<OwnedSemaphorePermit>,
    flow: Workflow,
) -> Result<Workflow> {
    let (r, o) = (root.clone(), op.clone());
    let flow = blocking(lease, move || {
        ensure_source(&r, &o, &flow)?;
        Ok(flow)
    })
    .await?;
    let response = flow.transport.read(&op.cancel).await?;
    // First contact with an existing remote object whose decryption under the
    // expected collection fails: the plaintext header separates a genuinely
    // different password from a dataset still addressed by a LEGACY
    // (pre-derivation, manual/random) collection identifier. Only a device
    // that previously synchronized that identifier (archived or active local
    // baseline) may ADOPT the object, migrating it in place under the derived
    // identifier via the next conditional publication; every other device is
    // told to re-save the target on the ORIGINAL device instead of a
    // misleading "password does not match".
    let legacy_collection = match &response {
        cloud::RemoteRead::Present { ciphertext, .. } => {
            cloud::Document::header_collection(ciphertext)
                .filter(|c| *c != flow.target.target().collection)
        }
        _ => None,
    };
    let first_contact =
        flow.baseline.etag().is_none() && matches!(response, cloud::RemoteRead::Present { .. });
    let (r, o) = (root.clone(), op.clone());
    let flow = blocking(lease, move || {
        let mut flow = flow;
        r.check(&o)?;
        let adopt_legacy = match legacy_collection {
            Some(collection) => {
                crate::api::with_vault(|v| Ok(cloud::archives::known_collection(v, &collection)))?
            }
            None => false,
        };
        let step = match flow.exchange.accept_read(
            response,
            flow.target.password(),
            cloud::journal::now_millis()?,
            adopt_legacy,
        ) {
            Ok(step) => step,
            Err(cloud::SyncError::LegacyCollection) => {
                return Err(anyhow::Error::new(LegacyCollectionDataset));
            }
            Err(cloud::SyncError::Invalid) if first_contact => {
                return Err(anyhow::Error::new(FirstReadMismatch));
            }
            Err(error) => return Err(anyhow::Error::new(error)),
        };
        flow.step = Some(step);
        ensure_source(&r, &o, &flow)?;
        Ok(flow)
    })
    .await?;
    root.emit(|s| s.snapshots = flow.exchange.snapshots());
    Ok(flow)
}
fn publish_review(root: &Owner, op: &Operation, mut flow: Workflow) -> Result<()> {
    root.check(op)?;
    let step = flow.step.as_ref().context("同步合并结果缺失")?;
    let token = format!("sync-review-{:032x}", rand::random::<u128>());
    let review = Review {
        token: token.clone(),
        endpoint: flow.target.target().endpoint.clone(),
        collection: flow.target.target().collection.clone(),
        summary: step.summary(),
        uploads: step.uploads(),
        references: matches!(step, ExchangeStep::References(_)),
    };
    let references = review.references;
    flow.review = Some(token);
    *op.pending.lock() = Some(flow);
    root.emit(|state| {
        state.phase = if references { "references" } else { "review" };
        state.error = None;
        state.review = Some(review);
    });
    Ok(())
}
async fn prepare_target(
    root: &Arc<Owner>,
    op: &Arc<Operation>,
    lease: &Arc<OwnedSemaphorePermit>,
) -> Result<(settings::ActiveTarget, Transport)> {
    let (r, o) = (root.clone(), op.clone());
    let target = blocking(lease, move || {
        crate::api::with_vault(|v| {
            r.check(&o)?;
            ensure!(
                v.instance_id() == r.status.lock().vault_scope,
                "原配置库已改变"
            );
            let source = settings::load(v)?;
            Ok(settings::capture(v, &source.vault_scope, &source.revision)?)
        })
    })
    .await?;
    if target.target().drive.is_none() {
        return blocking(lease, move || {
            let transport = Transport::WebDav(target.webdav()?);
            Ok((target, transport))
        })
        .await;
    }
    // The same one-account gate covers browser authorization, object discovery
    // and sync refresh. Never race two rotations of the same stored token.
    let credential = crate::drive_authorization::credential_lease()?;
    let (r, o) = (root.clone(), op.clone());
    let kept = credential.clone();
    let mut target = blocking(lease, move || {
        let _credential = kept;
        crate::api::with_vault(|v| {
            r.check(&o)?;
            target.ensure_current(v)?;
            Ok(target)
        })
    })
    .await?;
    // Only an actual operation reaches refresh. No Vault, registry or UI lock
    // spans this HTTPS request, and SSH/proxy credentials are never substituted.
    let account = target.take_drive_account()?;
    let client = account.client();
    op.authorization_unknown.store(true, Ordering::Release);
    let refreshed = drive_oauth::refresh(
        &client,
        account.refresh_token(),
        target.proxy(),
        target.target().timeout_seconds,
        &op.cancel,
    )
    .await?;
    drop(client);
    let (r, o) = (root.clone(), op.clone());
    let kept = credential.clone();
    let (target, access) = blocking(lease, move || {
        let _credential = kept;
        crate::api::with_vault(|v| {
            r.check(&o)?;
            target.ensure_current(v)?;
            let source = settings::load(v)?;
            // Cancellation and the local rotation ACK have an explicit ordering.
            // Rotation never acknowledges an uploaded configuration document.
            let state = r.status.lock();
            let current = r.operation.lock();
            ensure!(
                !r.stop.is_cancelled()
                    && !o.cancel.is_cancelled()
                    && state.operation.as_deref() == Some(o.id.as_str())
                    && current.as_ref().is_some_and(|p| p.id == o.id),
                "原同步操作已取消"
            );
            let (account, access) =
                account.accept_refresh(v, refreshed, &target.target_preconditions())?;
            o.authorization_unknown.store(false, Ordering::Release);
            let updated = settings::capture(v, &source.vault_scope, &source.revision)?;
            updated.ensure_account(&account)?;
            account.ensure_current(v)?;
            Ok((updated, access))
        })
    })
    .await?;
    blocking(lease, move || {
        let binding = target
            .target()
            .drive
            .as_ref()
            .context("原Drive对象绑定已改变")?;
        let transport = Transport::Drive {
            files: drive_files::DriveFiles::new(
                access,
                target.proxy(),
                target.target().timeout_seconds,
            )?,
            id: binding.file_id.clone(),
            collection: target.target().collection.clone(),
        };
        Ok((target, transport))
    })
    .await
}
pub(crate) async fn prepare(id: String, operation: String) -> Result<String> {
    prepare_impl(id, operation, None).await
}
pub(crate) async fn prepare_snapshot(
    id: String,
    operation: String,
    snapshot: String,
) -> Result<String> {
    prepare_impl(id, operation, Some(snapshot)).await
}
async fn prepare_impl(id: String, operation: String, snapshot: Option<String>) -> Result<String> {
    let root = owner(&id)?;
    let op = root.operation(&operation)?;
    let lease = acquire(&root, &op)?;
    ensure!(
        !op.started.swap(true, Ordering::AcqRel),
        "同步准备已执行，不重复请求"
    );
    let mut abort = AbortGuard {
        op: op.clone(),
        completed: false,
    };
    root.emit(|s| s.phase = "reading");
    let result = async {
        if let Some(id) = &snapshot {
            ensure!(
                id.len() == 64 && id.bytes().all(|b| b.is_ascii_hexdigit()),
                "历史快照标识无效"
            );
            if !root.status.lock().snapshots.iter().any(|s| s.id == *id) {
                return Err(cloud::SyncError::Changed.into());
            }
        }

        let (target, transport) = prepare_target(&root, &op, &lease).await?;
        let (r, o) = (root.clone(), op.clone());
        let flow = blocking(&lease, move || {
            let (baseline, proposal) = crate::api::with_vault(|v| {
                r.check(&o)?;
                target.ensure_current(v)?;
                let baseline = Baseline::load(
                    v,
                    &target.target().collection,
                    cloud::journal::now_millis()?,
                )?;
                let proposal = baseline.capture_local(v, cloud::journal::now_millis()?)?;
                target.ensure_proposal(&proposal)?;
                Ok((baseline, proposal))
            })?;
            let exchange = Exchange::new(&proposal, baseline.document());
            Ok(Workflow {
                target,
                baseline,
                proposal,
                transport,
                exchange,
                step: None,
                review: None,
                restore: false,
            })
        })
        .await?;
        // The ONLY directory write in the protocol: one explicit MKCOL of the
        // object's parent collection before this device's FIRST verified
        // exchange with a WebDAV target (no stored baseline ETag yet). A
        // stored ETag means a previous round already confirmed the collection.
        if let (Transport::WebDav(client), None) = (&flow.transport, flow.baseline.etag()) {
            client.ensure_collection(&op.cancel).await?;
        }
        let mut flow = read_step(&root, &op, &lease, flow).await?;
        if let Some(snapshot) = snapshot {
            let (r, o) = (root.clone(), op.clone());
            flow = blocking(&lease, move || {
                ensure_source(&r, &o, &flow)?;
                flow.step = Some(flow.exchange.restore_snapshot(
                    &snapshot,
                    flow.target.password(),
                    cloud::journal::now_millis()?,
                )?);
                flow.restore = true;
                Ok(flow)
            })
            .await?;
        }
        publish_review(&root, &op, flow)?;
        status(&id)
    }
    .await;
    abort.completed = true;
    if let Err(error) = &result {
        let code = failure(error, &op);
        finish(&root, &op, code);
        // The run log keeps the typed cause; the status panel and the public
        // summary below carry the actionable per-cause text.
        if let Some(kind) = typed_kind(error) {
            crate::run_log::sync_failure(code, kind);
        }
    }
    // Keep the typed cause in the returned public summary as well; the old
    // blanket message hid password/collection mismatches, MKCOL failures and
    // authentication errors that the status panel already knew about.
    result.map_err(|error| {
        if error.is::<FirstReadMismatch>() {
            return anyhow::anyhow!(
                "无法读取云端配置：同步密码不匹配、版本不支持或数据损坏，未修改本机配置"
            );
        }
        if error.is::<LegacyCollectionDataset>() {
            return anyhow::anyhow!(
                "云端数据集由旧版本标识创建：请先在原设备重新保存同步目标（迁移为新派生标识），未应用任何配置"
            );
        }
        match error.downcast_ref::<cloud::SyncError>() {
            Some(cloud::SyncError::Invalid) => anyhow::anyhow!(
                "无法读取云端配置：同步密码不匹配、版本不支持或数据损坏，未修改本机配置"
            ),
            _ => match error.downcast_ref::<webdav::TransportError>() {
                Some(webdav::TransportError::Directory) => {
                    anyhow::anyhow!("同步目录未就绪：请在服务器确认 <根>/hspterm 目录与根地址")
                }
                Some(webdav::TransportError::Denied) => {
                    anyhow::anyhow!("WebDAV 认证被拒绝")
                }
                _ => anyhow::anyhow!("同步准备未完成；请查看同步状态后明确重试"),
            },
        }
    })
}

async fn commit(
    root: Arc<Owner>,
    op: Arc<Operation>,
    lease: &Arc<OwnedSemaphorePermit>,
    flow: Workflow,
    acknowledged: Acknowledged,
) -> Result<()> {
    let agents = crate::agents::gate().write_owned().await;
    blocking(lease, move || {
        let _agents = agents;
        crate::transfers::restore_configuration(|| {
            crate::api::with_vault(|v| {
                root.check(&op)?;
                let source_scope = root.status.lock().vault_scope.clone();
                let snapshots = acknowledged.snapshots();
                let plan = flow.baseline.prepare_acknowledged(
                    v,
                    &flow.proposal,
                    &acknowledged,
                    cloud::journal::now_millis()?,
                )?;
                let next_scope = plan.next_scope().to_owned();
                let display_sources = crate::api::display_sources();
                let changed = plan.changed_units().to_vec();
                let changed_hosts = plan.changed_hosts().to_vec();
                let (settings, updates, preferences) = plan.inspect_candidate(|candidate| {
                    let settings =
                        hspterm_storage_sync::transfer_settings::TransferSettings::load(candidate)?;
                    let updates = display_sources
                        .into_iter()
                        .filter(|(_, s)| {
                            s.vault_scope == source_scope
                                && (changed
                                    .iter()
                                    .any(|id| id == "config-terminal-decorations-v1")
                                    || s.host.as_ref().is_some_and(|h| changed.contains(h)))
                        })
                        .map(|(id, old)| {
                            let decorator = crate::display::capture(candidate, old.host.as_deref())
                                .map_err(|_| backup::BackupError::Invalid)?
                                .decorator;
                            Ok((id, old.host, decorator))
                        })
                        .collect::<backup::Result<Vec<_>>>()?;
                    let preferences = if changed
                        .iter()
                        .any(|id| id == hspterm_storage_sync::terminal_preferences::RECORD)
                    {
                        Some(
                            hspterm_storage_sync::terminal_preferences::load(candidate)
                                .map_err(|_| backup::BackupError::Invalid)?
                                .value
                                .validated()
                                .map_err(|_| backup::BackupError::Invalid)?,
                        )
                    } else {
                        None
                    };
                    Ok((settings, updates, preferences))
                })?;
                // Vault -> owner is the only nested order. Cancel takes this owner
                // lock and linearizes before the commit, or sees its committed ACK.
                let mut state = root.status.lock();
                let mut current = root.operation.lock();
                ensure!(
                    !op.cancel.is_cancelled()
                        && !root.stop.is_cancelled()
                        && current.as_ref().is_some_and(|p| p.id == op.id),
                    "同步已取消，未应用本机配置"
                );
                crate::api::invalidate_synchronized_agents(&changed_hosts)?;
                plan.commit(v)?;
                crate::api::configuration_synchronized(
                    &source_scope,
                    updates,
                    preferences.as_ref(),
                );
                state.vault_scope = next_scope;
                state.phase = "committed";
                state.snapshots = snapshots;
                state.error = None;
                state.review = None;
                state.commits = state.commits.saturating_add(1);
                state.remote_published = op.remote_published.load(Ordering::Acquire);
                state.write_unknown = false;
                state.authorization_unknown = false;
                if !changed.is_empty() {
                    state.configuration_updates = state.configuration_updates.saturating_add(1);
                }
                current.take();
                state.sequence = state.sequence.wrapping_add(1);
                root.changes.send_replace(state.sequence);
                op.cancel.cancel();
                Ok(((), settings))
            })
        })
    })
    .await
}
pub(crate) async fn confirm(id: String, operation: String, review: String) -> Result<String> {
    let root = owner(&id)?;
    let op = root.operation(&operation)?;
    let lease = acquire(&root, &op)?;
    let mut flow = {
        let state = root.status.lock();
        ensure!(
            state.phase == "review" && state.review.as_ref().is_some_and(|r| r.token == review),
            "原同步审阅已失效"
        );
        op.pending
            .lock()
            .take()
            .filter(|f| f.review.as_deref() == Some(review.as_str()))
            .context("原同步候选已释放")?
    };
    let mut abort = AbortGuard {
        op: op.clone(),
        completed: false,
    };
    root.emit(|s| {
        s.phase = "publishing";
        s.review = None;
    });
    let result = async {
        let (r, o) = (root.clone(), op.clone());
        flow = blocking(&lease, move || {
            ensure_source(&r, &o, &flow)?;
            Ok(flow)
        })
        .await?;
        let step = flow.step.take().context("同步候选缺失")?;
        let acknowledged = match step {
            ExchangeStep::References(_) => {
                anyhow::bail!("先明确解决原引用冲突，不能直接发布无效配置")
            }
            ExchangeStep::AlreadyCurrent(ack) => {
                if !ack.summary().diverged.is_empty() {
                    anyhow::bail!("两端同时修改的单位未选择整体方向，不能应用")
                }
                ack
            }
            ExchangeStep::Upload(upload) => {
                if !upload.summary().diverged.is_empty() {
                    anyhow::bail!("两端同时修改的单位未选择整体方向，不能发布")
                }
                op.attempting_put.store(true, Ordering::Release);
                match flow.transport.publish(upload, &op.cancel).await? {
                    webdav::PutResponse::PreconditionFailed => {
                        op.attempting_put.store(false, Ordering::Release);
                        if flow.restore {
                            return Err(cloud::SyncError::Changed.into());
                        }
                        let flow = read_step(&root, &op, &lease, flow).await?;
                        publish_review(&root, &op, flow)?;
                        return status(&id);
                    }
                    webdav::PutResponse::Confirmed(ack) => {
                        op.attempting_put.store(false, Ordering::Release);
                        op.remote_published.store(true, Ordering::Release);
                        ack
                    }
                }
            }
        };
        root.emit(|s| s.phase = "applying");
        commit(root.clone(), op.clone(), &lease, flow, acknowledged).await?;
        status(&id)
    }
    .await;
    abort.completed = true;
    if let Err(error) = &result {
        finish(&root, &op, failure(error, &op));
    }
    result.map_err(|_| anyhow::anyhow!("同步未完成；保留本机修改，请查看同步状态"))
}
/// Non-secret unit/dependency metadata only; no credentials, history body or
/// decrypted document is returned. A separate RPC avoids cloning a large
/// choice list into every ordinary monitor notification.
pub(crate) async fn reference_choices(
    id: String,
    operation: String,
    review: String,
) -> Result<String> {
    let root = owner(&id)?;
    let op = root.operation(&operation)?;
    let lease = acquire(&root, &op)?;
    blocking(&lease, move || {
        {
            let state = root.status.lock();
            ensure!(
                state.phase == "references"
                    && state.review.as_ref().is_some_and(|r| r.token == review),
                "原引用审阅已失效"
            );
        }
        let pending = op.pending.lock();
        let flow = pending
            .as_ref()
            .filter(|f| f.review.as_deref() == Some(review.as_str()))
            .context("原引用候选已释放")?;
        ensure_source(&root, &op, flow)?;
        let choices = flow
            .exchange
            .reference_choices(flow.step.as_ref().context("原引用候选缺失")?)?;
        Ok(serde_json::to_string(&choices)?)
    })
    .await
}
pub(crate) async fn resolve_references(
    id: String,
    operation: String,
    review: String,
    choices: String,
) -> Result<String> {
    ensure!(choices.len() <= 4 * 1024 * 1024, "引用选择超过安全容量");
    let root = owner(&id)?;
    let op = root.operation(&operation)?;
    let lease = acquire(&root, &op)?;
    let mut abort = AbortGuard {
        op: op.clone(),
        completed: false,
    };
    let flow = {
        let state = root.status.lock();
        ensure!(
            state.phase == "references" && state.review.as_ref().is_some_and(|r| r.token == review),
            "原引用审阅已失效"
        );
        op.pending
            .lock()
            .take()
            .filter(|f| f.review.as_deref() == Some(review.as_str()))
            .context("原引用候选已释放")?
    };
    let (r, o) = (root.clone(), op.clone());
    let result = blocking(&lease, move || {
        let mut flow = flow;
        ensure_source(&r, &o, &flow)?;
        let choices: Vec<cloud::ReferenceSelection> =
            serde_json::from_str(&choices).map_err(|_| cloud::SyncError::Invalid)?;
        let Some(ExchangeStep::References(pending)) = flow.step.as_ref() else {
            anyhow::bail!("原引用候选类型已改变");
        };
        let resolved = match flow.exchange.resolve_references(
            pending,
            &choices,
            flow.target.password(),
            cloud::journal::now_millis()?,
        ) {
            Ok(step) => {
                flow.step = Some(step);
                true
            }
            Err(cloud::SyncError::References) => false,
            Err(error) => return Err(error.into()),
        };
        ensure_source(&r, &o, &flow)?;
        Ok((flow, resolved))
    })
    .await;
    abort.completed = true;
    match result {
        Ok((flow, true)) => publish_review(&root, &op, flow)?,
        Ok((flow, false)) => {
            *op.pending.lock() = Some(flow);
            root.emit(|s| s.error = Some("references"));
        }
        Err(error) => {
            finish(&root, &op, failure(&error, &op));
        }
    }
    status(&id)
}
/// Whole-direction choice for units modified on both sides since the
/// baseline. The direction applies to ALL diverged units together; a fresh
/// review token is issued and the old one can no longer be confirmed.
pub(crate) async fn resolve_direction(
    id: String,
    operation: String,
    review: String,
    direction: String,
) -> Result<String> {
    let root = owner(&id)?;
    let op = root.operation(&operation)?;
    let lease = acquire(&root, &op)?;
    let mut abort = AbortGuard {
        op: op.clone(),
        completed: false,
    };
    let flow = {
        let state = root.status.lock();
        ensure!(
            matches!(state.phase, "review" | "references")
                && state.review.as_ref().is_some_and(|r| r.token == review),
            "原同步审阅已失效"
        );
        op.pending
            .lock()
            .take()
            .filter(|f| f.review.as_deref() == Some(review.as_str()))
            .context("原同步候选已释放")?
    };
    let (r, o) = (root.clone(), op.clone());
    let result = blocking(&lease, move || {
        let mut flow = flow;
        ensure_source(&r, &o, &flow)?;
        let direction = match direction.as_str() {
            "local" => cloud::Divergence::PreferLocal,
            "remote" => cloud::Divergence::PreferRemote,
            _ => return Err(anyhow::anyhow!("整体方向选择无效；未改变候选")),
        };
        let step = flow.exchange.resolve_divergence(
            direction,
            flow.target.password(),
            cloud::journal::now_millis()?,
        )?;
        flow.step = Some(step);
        ensure_source(&r, &o, &flow)?;
        Ok(flow)
    })
    .await;
    abort.completed = true;
    match result {
        Ok(flow) => publish_review(&root, &op, flow)?,
        Err(error) => {
            finish(&root, &op, failure(&error, &op));
        }
    }
    status(&id)
}
pub(crate) async fn cancel(id: String, operation: String) -> Result<()> {
    let root = match owner(&id) {
        Ok(root) => root,
        Err(_) => return Ok(()),
    };
    let op = {
        let _state = root.status.lock();
        let op = root.operation(&operation).ok();
        if let Some(op) = &op {
            op.cancel.cancel();
        }
        op
    };
    let Some(op) = op else {
        return Ok(());
    };
    let _lease = op.gate.clone().acquire_owned().await?;
    op.pending.lock().take();
    finish(&root, &op, "cancelled");
    Ok(())
}
pub(crate) async fn close(id: String) -> Result<()> {
    let root = match owner(&id) {
        Ok(root) => root,
        Err(_) => return Ok(()),
    };
    let operation = {
        let _state = root.status.lock();
        root.stop.cancel();
        root.operation.lock().clone()
    };
    if let Some(op) = operation {
        op.cancel.cancel();
        let _lease = op.gate.clone().acquire_owned().await?;
        op.pending.lock().take();
        finish(&root, &op, "cancelled");
    }
    let mut global = registry().lock();
    if global.as_ref().is_some_and(|o| Arc::ptr_eq(o, &root)) {
        global.take();
    }
    drop(global);
    retiring().lock().remove(&id);
    Ok(())
}
