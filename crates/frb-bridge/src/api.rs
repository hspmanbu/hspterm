use crate::diagnostics::{self, DiagnosticCode};
use crate::frb_generated::StreamSink;
use alacritty_terminal::event::Event;
use anyhow::{Context, Result, bail, ensure};
use hspterm_ssh_core::{
    Authentication, ConnectConfig, HostKeyRequest, InputOutcome, ManagedSession, SessionEvent,
    SessionPhase, TerminalInput,
};
use hspterm_storage_sync::Vault;
use hspterm_term_core::{
    FrameFingerprint, Key, KeyEvent, KeyKind, Modifiers, MouseAction, MouseButton, MouseEvent, Size,
};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Notify, mpsc};
use zeroize::Zeroizing;

/// Initialize the fixed, non-printing panic boundary before application APIs.
/// No default packet logger or tracing subscriber is installed here.
#[flutter_rust_bridge::frb(init)]
pub fn initialize_runtime() {
    crate::public_errors::prepare();
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub address: String,
    pub port: u16,
    pub username: String,
    pub private_key: bool,
}
#[derive(Serialize, Deserialize)]
struct SavedProfile {
    profile: Profile,
    secret: String,
    passphrase: Option<String>,
}
impl Drop for SavedProfile {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.secret.zeroize();
        self.passphrase.zeroize();
    }
}
#[derive(Clone)]
pub struct BridgeEvent {
    pub kind: String,
    pub generation: u64,
    pub request_id: u32,
    pub text: Option<String>,
    pub detail: Option<String>,
    pub rtt_micros: Option<u64>,
}
#[derive(Clone)]
pub struct RenderCell {
    pub text: String,
    pub foreground: u32,
    pub background: u32,
    pub flags: u16,
}
/// Half-open physical columns. Missing URI suppresses activation of that span.
#[derive(Clone)]
pub struct RenderHyperlink {
    pub start: u16,
    pub end: u16,
    pub uri: Option<String>,
}
#[derive(Clone)]
pub struct RenderRow {
    pub index: u16,
    pub cells: Vec<RenderCell>,
    pub hyperlinks: Option<Vec<RenderHyperlink>>,
}
#[derive(Clone)]
pub struct RenderFrame {
    pub revision: u64,
    pub content_revision: u64,
    pub output_lines: u64,
    pub size_locked: bool,
    pub same_word_enabled: Option<bool>,
    pub same_word_case_sensitive: Option<bool>,
    pub decorations_limited: Option<bool>,
    pub search_revision: Option<u64>,
    pub search_spans: Vec<SearchSpan>,
    pub columns: u16,
    pub rows: u16,
    pub full: bool,
    pub changed_rows: Vec<RenderRow>,
    pub cursor_column: u16,
    pub cursor_row: i64,
    pub cursor_visible: bool,
    pub cursor_shape: u8,
    pub cursor_blink: bool,
    pub osc52_enabled: Option<bool>,
    pub right_click_paste: Option<bool>,
    pub copy_on_selection: Option<bool>,
    pub image_paste_shortcut: Option<String>,
    pub cursor_color: u32,
    pub background: u32,
    pub alternate_screen: bool,
    pub mouse_reporting: bool,
    pub history_lines: u32,
    pub display_offset: u32,
}
pub struct KeyboardInput {
    pub key: String,
    pub text: Option<String>,
    pub modifiers: u8,
    pub kind: u8,
    pub shifted: Option<String>,
    pub base: Option<String>,
}
pub struct PasteResult {
    pub needs_confirmation: bool,
    pub lines: u32,
    pub bytes: u32,
    pub bracketed: bool,
}

type ClipboardFormatter = Arc<dyn Fn(&str) -> String + Send + Sync>;
/// Retained until actual native cleanup has acknowledged every local owner.
/// A retry only completes retirement; it can never reopen the SSH Root.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Default)]
struct TerminalCloseState {
    generation: Option<u64>,
    forwardings: bool,
    editors: bool,
    previews: bool,
    images: bool,
    directories: bool,
    searches: bool,
    transfers: bool,
    agents: bool,
    root_error_reported: bool,
}
struct Entry {
    session: Arc<ManagedSession>,
    transfer_target: Mutex<Option<(u64, crate::transfers::Target)>>,
    transfer_reconnect_notice: Mutex<Option<(u64, String)>>,
    transfer_closing: Arc<AtomicBool>,
    temporary_connection: AtomicBool,
    tmux: Arc<crate::tmux::TmuxRegistry>,
    forwardings: Arc<crate::forwardings::runtime::ForwardingRegistry>,
    agents: Arc<crate::agents::AgentRegistry>,
    inspection: crate::inspection::Registry,
    sftp: tokio::sync::Mutex<Option<(u64, Arc<hspterm_ssh_core::SftpSession>)>>,
    directories: crate::directories::DirectoryListings,
    file_searches: crate::directories::DirectoryListings,
    visible: AtomicBool,
    in_flight: AtomicBool,
    last_revision: AtomicU64,
    previous: Mutex<Option<FrameFingerprint>>,
    display: Mutex<Option<crate::display::DisplayRuntime>>,
    preferences_scope: Mutex<Option<String>>,
    kick: Notify,
    events: tokio::sync::Mutex<Option<mpsc::Receiver<SessionEvent>>>,
    host_requests: tokio::sync::Mutex<Option<mpsc::Receiver<HostKeyRequest>>>,
    host_sender: mpsc::Sender<HostKeyRequest>,
    pending_keys: Mutex<HashMap<u32, HostKeyRequest>>,
    verification: Arc<crate::connections::Verification>,
    pending_clipboard: Mutex<HashMap<u32, (u64, ClipboardFormatter)>>,
    cell_size: Mutex<(u16, u16)>,
    search: Mutex<Option<Arc<hspterm_term_core::SearchIndex>>>,
    search_epoch: Arc<AtomicU64>,
    search_gate: Arc<tokio::sync::Mutex<()>>,
    history_gate: Arc<tokio::sync::Mutex<()>>,
    history_capture_epoch: AtomicU64,
    integration_scope: Mutex<Option<(u64, String, String)>>,
    suggestions: Mutex<SuggestionsCache>,
    dir_size_jobs: Mutex<HashMap<String, DirSizeJob>>,
    closed: AtomicBool,
    close_state: tokio::sync::Mutex<TerminalCloseState>,
    clipboard_enabled: AtomicBool,
    image_uploads: crate::clipboard_images::Uploads,
    frame_pulls: AtomicU64,
    cells_sent: AtomicU64,
    rows_sent: AtomicU64,
}
static SESSIONS: OnceLock<Mutex<HashMap<u32, Arc<Entry>>>> = OnceLock::new();
static VAULT: OnceLock<Mutex<Option<Vault>>> = OnceLock::new();
static NEXT: AtomicU32 = AtomicU32::new(1);
fn sessions() -> &'static Mutex<HashMap<u32, Arc<Entry>>> {
    SESSIONS.get_or_init(Default::default)
}
fn vault() -> &'static Mutex<Option<Vault>> {
    VAULT.get_or_init(Default::default)
}
fn entry(id: u32) -> Result<Arc<Entry>> {
    sessions()
        .lock()
        .get(&id)
        .filter(|entry| !entry.closed.load(Ordering::Acquire))
        .cloned()
        .context("终端已关闭")
}
fn next_id() -> u32 {
    NEXT.fetch_add(1, Ordering::Relaxed)
}
fn event(kind: &str, generation: u64, text: Option<String>) -> BridgeEvent {
    BridgeEvent {
        kind: kind.into(),
        generation,
        request_id: 0,
        text,
        detail: None,
        rtt_micros: None,
    }
}
pub(crate) fn trust_id(address: &str, port: u16) -> String {
    let hash = Sha256::digest(format!("{}:{port}", address.to_ascii_lowercase()).as_bytes());
    format!(
        "trust-{}",
        hash.iter().map(|v| format!("{v:02x}")).collect::<String>()
    )
}
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn with_vault<T>(f: impl FnOnce(&mut Vault) -> Result<T>) -> Result<T> {
    let mut guard = vault().lock();
    f(guard.as_mut().context("请先解锁加密配置库")?)
}
pub(crate) fn remember_host_key(
    store: &mut Vault,
    identity: &str,
    fingerprint: &str,
) -> Result<()> {
    if let Some(existing) = store.get(identity)?
        && existing.as_slice() != fingerprint.as_bytes()
    {
        bail!("另一连接已确认不同主机密钥，本次连接已阻止；请核对服务器身份");
    }
    store.put(identity, fingerprint.as_bytes())?;
    Ok(())
}

pub async fn unlock_vault(path: String, password: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        unlock_vault_inner(path, password, None, false).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Only fixed codes and numeric runtime identities; no terminal/error text.
pub async fn diagnostic_snapshot() -> crate::diagnostics::DiagnosticSnapshot {
    diagnostics::snapshot()
}
pub async fn clear_diagnostics() {
    diagnostics::clear();
}
/// Current process only; writing/export location remains a user UI action.
pub async fn current_run_log() -> String {
    crate::run_log::export()
}
/// Convenient unlock may only open the same existing Vault whose non-secret
/// identity was read before asking the OS to unprotect its cached password.
pub async fn unlock_existing_vault(path: String, password: String, token: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        unlock_vault_inner(path, password, Some(token), false).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn create_configuration_vault(path: String, password: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { unlock_vault_inner(path, password, None, true).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
async fn unlock_vault_inner(
    path: String,
    password: String,
    expected_token: Option<String>,
    create_only: bool,
) -> Result<()> {
    let password = Zeroizing::new(password);
    let agents = crate::agents::gate().write_owned().await;
    tokio::task::spawn_blocking(move || {
        let _agents = agents;
        crate::editors::switch_vault(|| {
            crate::transfers::switch_vault(|| {
                let path = std::path::Path::new(&path);
                let store = if create_only {
                    Vault::create(path, password.as_bytes())?
                } else if let Some(token) = &expected_token {
                    let store = Vault::open(path, password.as_bytes())?;
                    ensure!(
                        hspterm_storage_sync::secure_unlock::source(&store)?.token == *token,
                        "原配置文件已改变；请手动输入主密码"
                    );
                    store
                } else if path.exists() {
                    Vault::open(path, password.as_bytes())?
                } else {
                    Vault::create(path, password.as_bytes())?
                };
                let mut guard = vault().lock();
                // Same gate as final consent checks: no late approval can
                // install a grant from a vault which has already been replaced.
                for entry in sessions().lock().values() {
                    entry.agents.invalidate()?;
                    // Old unconfirmed keys cannot be trusted in the new DB.
                    // Already accepted/pinned SSH transports retain their identity.
                    entry.verification.vault_replaced();
                    entry.pending_keys.lock().clear();
                    entry.tmux.invalidate();
                }
                *guard = Some(store);
                retire_suggestions();
                crate::backups::vault_replaced();
                crate::configuration_sync::vault_replaced();
                crate::drive_authorization::vault_replaced();
                diagnostics::record(DiagnosticCode::VaultOpened, None, None);
                Ok::<_, anyhow::Error>(())
            })
        })
    })
    .await??;
    Ok(())
}
pub async fn list_profiles() -> Result<Vec<Profile>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                let ids: Vec<String> = match v.get("profile-index")? {
                    Some(data) => serde_json::from_slice(&data)?,
                    None => Vec::new(),
                };
                let mut profiles: Vec<Profile> = ids
                    .into_iter()
                    .map(|id| {
                        let raw = v.get(&id)?.context("主机配置缺失")?;
                        let saved: SavedProfile = serde_json::from_slice(&raw)?;
                        Ok(saved.profile.clone())
                    })
                    .collect::<Result<_>>()?;
                profiles.extend(
                    hspterm_storage_sync::Repository::new(v)
                        .list()?
                        .into_iter()
                        .map(|h| Profile {
                            id: h.id,
                            name: h.name,
                            address: h.address,
                            port: h.port,
                            username: h.username,
                            private_key: h.auth == hspterm_storage_sync::AuthMethod::PrivateKey,
                        }),
                );
                Ok(profiles)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_profile(
    mut profile: Profile,
    secret: String,
    passphrase: Option<String>,
) -> Result<Profile> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        if profile.address.trim().is_empty() || profile.username.is_empty() || profile.port == 0 {
            bail!("主机连接参数无效");
        }
        if profile.id.is_empty() {
            profile.id = format!("profile-{:032x}", rand::random::<u128>());
        }
        if profile.id.starts_with("host-") {
            return tokio::task::spawn_blocking(move || {
                with_vault(|v| {
                    let mut repo = hspterm_storage_sync::Repository::new(v);
                    let mut host = repo.host(&profile.id)?.context("主机配置已不存在")?;
                    host.name = profile.name.clone();
                    host.address = profile.address.clone();
                    host.port = profile.port;
                    host.username = profile.username.clone();
                    host.auth = if profile.private_key {
                        hspterm_storage_sync::AuthMethod::PrivateKey
                    } else {
                        hspterm_storage_sync::AuthMethod::Password
                    };
                    let credential = hspterm_storage_sync::Credential { secret, passphrase };
                    if profile.private_key {
                        hspterm_ssh_core::validate_private_key(
                            &credential.secret,
                            credential.passphrase.as_deref(),
                        )?;
                    }
                    repo.save(host, Some(credential))?;
                    Ok(profile)
                })
            })
            .await?;
        }
        if !profile.id.starts_with("profile-") || profile.id.len() > 128 {
            bail!("主机标识无效");
        }
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let mut ids: Vec<String> = match v.get("profile-index")? {
                    Some(data) => serde_json::from_slice(&data)?,
                    None => Vec::new(),
                };
                let saved = SavedProfile {
                    profile: profile.clone(),
                    secret,
                    passphrase,
                };
                let raw = Zeroizing::new(serde_json::to_vec(&saved)?);
                if !ids.contains(&profile.id) {
                    ids.push(profile.id.clone());
                }
                let index = serde_json::to_vec(&ids)?;
                v.put_many(&[(&profile.id, &raw), ("profile-index", &index)])?;
                Ok(profile)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn create_terminal(columns: u16, rows: u16, history_lines: u32) -> Result<u32> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        if history_lines > 1_000_000 {
            bail!("滚动历史配置过大");
        }
        let (session, events) =
            ManagedSession::new(Size::new(columns, rows)?, history_lines as usize)?;
        let (host_sender, host_requests) = mpsc::channel(1);
        let entry = Arc::new(Entry {
            session: Arc::new(session),
            sftp: tokio::sync::Mutex::new(None),
            directories: crate::directories::DirectoryListings::default(),
            file_searches: crate::directories::DirectoryListings::default(),
            transfer_target: Mutex::new(None),
            transfer_reconnect_notice: Mutex::new(None),
            transfer_closing: Arc::new(AtomicBool::new(false)),
            temporary_connection: AtomicBool::new(false),
            tmux: Arc::new(crate::tmux::TmuxRegistry::default()),
            forwardings: Arc::new(crate::forwardings::runtime::ForwardingRegistry::default()),
            agents: Arc::new(crate::agents::AgentRegistry::default()),
            inspection: crate::inspection::Registry::default(),
            visible: AtomicBool::new(true),
            in_flight: AtomicBool::new(false),
            last_revision: AtomicU64::new(u64::MAX),
            previous: Mutex::new(None),
            display: Mutex::new(None),
            preferences_scope: Mutex::new(None),
            kick: Notify::new(),
            events: tokio::sync::Mutex::new(Some(events)),
            host_requests: tokio::sync::Mutex::new(Some(host_requests)),
            host_sender,
            pending_keys: Mutex::new(HashMap::new()),
            verification: Arc::new(crate::connections::Verification::default()),
            pending_clipboard: Mutex::new(HashMap::new()),
            cell_size: Mutex::new((8, 16)),
            search: Mutex::new(None),
            search_epoch: Arc::new(AtomicU64::new(0)),
            search_gate: Arc::new(tokio::sync::Mutex::new(())),
            history_gate: Arc::new(tokio::sync::Mutex::new(())),
            history_capture_epoch: AtomicU64::new(0),
            integration_scope: Mutex::new(None),
            suggestions: Mutex::new(SuggestionsCache::default()),
            dir_size_jobs: Mutex::new(HashMap::new()),
            closed: AtomicBool::new(false),
            close_state: tokio::sync::Mutex::new(TerminalCloseState::default()),
            clipboard_enabled: AtomicBool::new(true),
            image_uploads: crate::clipboard_images::Uploads::default(),
            frame_pulls: AtomicU64::new(0),
            cells_sent: AtomicU64::new(0),
            rows_sent: AtomicU64::new(0),
        });
        let weak = Arc::downgrade(&entry);
        entry
            .session
            .set_history_sink(Some(Arc::new(move |generation, submissions| {
                let original = weak.upgrade();
                Box::pin(async move {
                    match original {
                        Some(entry) => record_integration_commands(entry, generation, submissions)
                            .await
                            .is_ok(),
                        None => true,
                    }
                })
            })));
        let id = next_id();
        sessions().lock().insert(id, entry);
        diagnostics::record(DiagnosticCode::TerminalCreated, Some(id), None);
        Ok(id)
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Formal terminal defaults. The legacy explicit-history constructor stays
/// available for protocol fixtures and the minimal Phase 2 API.
pub async fn create_configured_terminal(
    columns: u16,
    rows: u16,
    default_history_lines: u32,
) -> Result<u32> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        ensure!(default_history_lines <= 1_000_000, "滚动历史配置过大");
        let (scope, value) = tokio::task::spawn_blocking(move || -> Result<_> {
            let guard = vault().lock();
            match guard.as_ref() {
                Some(v) => {
                    let settings =
                        hspterm_storage_sync::terminal_preferences::load_with_history_default(
                            v,
                            default_history_lines,
                        )?
                        .value;
                    Ok((Some(v.instance_id().to_owned()), settings))
                }
                None => Ok((
                    None,
                    hspterm_term_core::preferences::Settings {
                        history_lines: default_history_lines,
                        ..Default::default()
                    },
                )),
            }
        })
        .await??;
        let valid = value.validated()?;
        let id = create_terminal(columns, rows, value.history_lines).await?;
        let target = entry(id)?;
        *target.preferences_scope.lock() = scope;
        apply_entry_preferences(&target, &valid);
        Ok(id)
    })
    .await;
    crate::public_errors::finish(outcome)
}
fn apply_entry_preferences(entry: &Entry, value: &hspterm_term_core::preferences::Validated) {
    let enabled = value.settings().osc52;
    entry.clipboard_enabled.store(enabled, Ordering::Release);
    if !enabled {
        entry.pending_clipboard.lock().clear();
    }
    entry.session.apply_terminal_preferences(value);
    entry.kick.notify_one();
}
fn publish_terminal_preferences(
    old_scope: &str,
    new_scope: &str,
    value: &hspterm_term_core::preferences::Validated,
) {
    for target in sessions().lock().values() {
        let mut scope = target.preferences_scope.lock();
        if scope.as_deref() == Some(old_scope) {
            *scope = Some(new_scope.to_owned());
            apply_entry_preferences(target, value);
        }
    }
}
pub async fn load_terminal_preferences() -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::terminal_preferences::load(v)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_terminal_preferences(proposal: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        ensure!(proposal.len() <= 16384, "终端设置超过容量");
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Proposal {
            vault_scope: String,
            revision: String,
            value: hspterm_term_core::preferences::Settings,
        }
        let value: Proposal = serde_json::from_str(&proposal).context("终端设置格式不支持")?;
        let valid = value.value.validated()?;
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let saved = hspterm_storage_sync::terminal_preferences::save(
                    v,
                    &value.vault_scope,
                    &value.revision,
                    value.value,
                )?;
                publish_terminal_preferences(&value.vault_scope, &value.vault_scope, &valid);
                diagnostics::record(DiagnosticCode::TerminalPreferencesSaved, None, None);
                Ok(serde_json::to_string(&saved)?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn destroy_terminal(id: u32) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        // Keep the unique cleanup owner in the registry on failure or RPC
        // cancellation. Normal entry() calls reject the closing handle.
        let original = sessions().lock().get(&id).cloned();
        if let Some(original) = original {
            let mut state = original.close_state.lock().await;
            close_terminal_owned(id, &original, &mut state).await?;
            let mut all = sessions().lock();
            if all
                .get(&id)
                .is_some_and(|current| Arc::ptr_eq(current, &original))
            {
                all.remove(&id);
            }
        }
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
async fn close_terminal_owned(
    id: u32,
    entry: &Entry,
    state: &mut TerminalCloseState,
) -> Result<()> {
    if !entry.closed.swap(true, Ordering::AcqRel) {
        diagnostics::record(
            DiagnosticCode::TerminalCloseRequested,
            Some(id),
            Some(entry.session.status().generation),
        );
    }
    let generation = *state
        .generation
        .get_or_insert_with(|| entry.session.status().generation);
    entry.inspection.close();
    entry.verification.close();
    entry.tmux.invalidate();
    entry.pending_keys.lock().clear();
    entry.pending_clipboard.lock().clear();
    entry.transfer_closing.store(true, Ordering::Release);
    let _forwarding_close = entry.forwardings.closing(true);
    let mut first: Option<anyhow::Error> = None;
    macro_rules! retire_once {
        ($field:ident, $action:expr) => {
            if !state.$field {
                match $action {
                    Ok(()) => state.$field = true,
                    Err(error) => {
                        if first.is_none() {
                            first = Some(error.into());
                        }
                    }
                }
            }
        };
    }
    let forwarded = if state.forwardings {
        None
    } else {
        Some(entry.forwardings.stop_all().await)
    };
    retire_once!(editors, crate::editors::stop_terminal(id).await);
    retire_once!(previews, crate::previews::stop_terminal(id).await);
    retire_once!(images, entry.image_uploads.stop().await);
    retire_once!(directories, entry.directories.close_all().await);
    retire_once!(searches, entry.file_searches.close_all().await);
    retire_once!(transfers, crate::transfers::stop_terminal(id).await);
    retire_once!(agents, entry.agents.close());
    entry.search_epoch.fetch_add(1, Ordering::AcqRel);
    entry.search.lock().take();
    // Even failed child cleanup cannot prevent cancelling the original Root.
    entry.session.shutdown();
    entry.kick.notify_waiters();
    entry.session.wait_closed().await;
    if let Err(error) = entry.agents.wait_operations().await
        && first.is_none()
    {
        first = Some(error);
    }
    if let Some(forwarded) = forwarded {
        let retired = entry.forwardings.retired(generation, &entry.session).await;
        if forwarded.errors.is_empty() && retired.is_ok() {
            state.forwardings = true;
        } else if first.is_none() {
            first = Some(match retired {
                Err(error) => error,
                Ok(()) => anyhow::anyhow!("端口转发清理失败：{}", forwarded.errors.join("；")),
            });
        }
    }
    let _history_finished = entry.history_gate.lock().await;
    let _finished = entry.search_gate.lock().await;
    if !state.root_error_reported
        && let Some(error) = &entry.session.status().error
    {
        state.root_error_reported = true;
        if first.is_none() {
            first = Some(anyhow::anyhow!("SSH 收尾失败：{error}"));
        }
    }
    if let Some(error) = first {
        return Err(error);
    }
    entry.sftp.lock().await.take();
    Ok(())
}

pub async fn temporary_connection_source(
    profile_id: String,
) -> Result<crate::connections::temporary::TemporarySource> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| crate::connections::temporary::TemporarySource::capture(v, &profile_id))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub struct TemporaryConnectionOptions {
    pub address: String,
    pub port: u16,
    pub username: String,
    pub authentication: u8,
}

pub async fn connect_terminal_once(
    id: u32,
    source: crate::connections::temporary::TemporarySource,
    options: TemporaryConnectionOptions,
    password: Option<String>,
    key_file: Option<String>,
    passphrase: Option<String>,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let TemporaryConnectionOptions {
            address,
            port,
            username,
            authentication,
        } = options;
        use crate::connections::temporary::{Method, OverrideTarget, Request};
        // Secret owners exist even if the method discriminator or source is bad.
        let method = match authentication {
            0 => Method::Saved,
            1 => Method::Password,
            2 => Method::PrivateKey,
            _ => {
                let _password = password.map(Zeroizing::new);
                let _passphrase = passphrase.map(Zeroizing::new);
                bail!("本次认证类型无效")
            }
        };
        let profile_id = source.host_id.clone();
        let request = Request::new(
            source,
            OverrideTarget {
                address,
                port,
                username,
                method,
            },
            password,
            key_file,
            passphrase,
        );
        connect_terminal_inner(id, profile_id, Some(request)).await
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn connect_terminal(id: u32, profile_id: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { connect_terminal_inner(id, profile_id, None).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}

async fn connect_terminal_inner(
    id: u32,
    profile_id: String,
    temporary: Option<crate::connections::temporary::Request>,
) -> Result<()> {
    let trace = diagnostics::ConnectionTrace::begin(id);
    let result = connect_terminal_run(id, profile_id, temporary).await;
    trace.finish(result.is_ok());
    result
}
async fn connect_terminal_run(
    id: u32,
    profile_id: String,
    temporary: Option<crate::connections::temporary::Request>,
) -> Result<()> {
    let entry = entry(id)?;
    let attempt = entry.verification.begin(entry.session.clone())?;
    if entry.closed.load(Ordering::Acquire) || entry.transfer_closing.load(Ordering::Acquire) {
        bail!("原终端正在关闭");
    }
    let is_temporary = temporary.is_some();
    let temporary = if let Some(request) = temporary {
        let source = request.source.clone();
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                source.check(v)?;
                Ok(())
            })
        })
        .await??;
        let prepared = tokio::select! {
            biased;
            _ = attempt.cancel.cancelled() => bail!("本次连接已取消"),
            result = request.prepare() => result?,
        };
        Some(prepared)
    } else {
        None
    };
    if entry.closed.load(Ordering::Acquire)
        || entry.transfer_closing.load(Ordering::Acquire)
        || attempt.cancel.is_cancelled()
    {
        bail!("原终端已关闭或本次连接已取消");
    }
    // A future qualified history collector must reject this entire original
    // connection, including the interval before its Connected event arrives.
    let was_temporary = entry
        .temporary_connection
        .swap(is_temporary, Ordering::AcqRel);
    entry.transfer_reconnect_notice.lock().take();
    // Last successfully authenticated target, not merely an earlier failed
    // generation. A different host/endpoint/key must not inherit listeners.
    let prior_target = entry
        .transfer_target
        .lock()
        .clone()
        .map(|(_, target)| target);
    // Quiesce the old task owners before a new generation can be considered
    // for restoration. A lost network event must not race its final checkpoint.
    let transfer_quiesced = if prior_target.is_some()
        && matches!(
            entry.session.status().phase,
            SessionPhase::Disconnected | SessionPhase::Failed
        ) {
        crate::transfers::stop_terminal(id).await.is_ok()
    } else {
        true
    };
    let restoring_host = prior_target.as_ref().map(|target| target.host_id.clone());
    let scope = attempt.scope();
    let requests = entry.host_sender.clone();
    let display_entry = entry.clone();
    let (profile, auth, prepared, restore_rules) = tokio::task::spawn_blocking(move || {
        with_vault(|v| {
            if profile_id.starts_with("host-") {
                let mut h = if let Some((source, _)) = &temporary {
                    anyhow::ensure!(source.host_id == profile_id, "本次连接来源主机不匹配");
                    source.check(v)?
                } else {
                    hspterm_storage_sync::Repository::new(v)
                        .host(&profile_id)?
                        .context("请先正式保存主机配置")?
                };
                let override_auth = if let Some((_, once)) = temporary {
                    once.target.apply(&mut h)?;
                    // Consent belongs to the saved endpoint, never a one-time
                    // override or its credentials/history namespace.
                    h.shell_integration = false;
                    match once.target.method {
                        crate::connections::temporary::Method::Saved => {}
                        crate::connections::temporary::Method::Password => {
                            h.auth = hspterm_storage_sync::AuthMethod::Password
                        }
                        crate::connections::temporary::Method::PrivateKey => {
                            h.auth = hspterm_storage_sync::AuthMethod::PrivateKey
                        }
                    }
                    once.authentication
                } else {
                    None
                };
                let repo = hspterm_storage_sync::Repository::new(v);
                let auth = match override_auth {
                    Some(auth) => auth,
                    None => crate::connections::authentication(
                        repo.credential(&profile_id)?.context("主机凭据缺失")?,
                        h.auth == hspterm_storage_sync::AuthMethod::PrivateKey,
                    ),
                };
                let profile = Profile {
                    id: h.id.clone(),
                    name: h.name.clone(),
                    address: h.address.clone(),
                    port: h.port,
                    username: h.username.clone(),
                    private_key: h.auth == hspterm_storage_sync::AuthMethod::PrivateKey,
                };
                let config = crate::connections::configuration(&repo, &h)?;
                let restore = (restoring_host.as_deref() == Some(&h.id)).then(|| {
                    hspterm_storage_sync::forwarding_rules::ForwardingConfig::load(v, &h.id)
                        .map(|config| config.rules)
                        .map_err(|_| {
                            "无法读取已保存转发配置；SSH已连接，请打开转发面板检查配置".to_owned()
                        })
                });
                let display = crate::display::capture(v, Some(&h.id))?;
                let prepared = config.prepare(v, &scope, requests)?;
                bind_display(&display_entry, display);
                Ok((profile, auth, prepared, restore))
            } else {
                anyhow::ensure!(temporary.is_none(), "请先使用主机管理器正式保存主机");
                let raw = v.get(&profile_id)?.context("请先保存主机配置")?;
                let mut saved: SavedProfile = serde_json::from_slice(&raw)?;
                let config = ConnectConfig::new(
                    saved.profile.address.clone(),
                    saved.profile.port,
                    saved.profile.username.clone(),
                );
                let prepared =
                    crate::connections::Route::direct(config).prepare(v, &scope, requests)?;
                let secret = Zeroizing::new(std::mem::take(&mut saved.secret));
                let auth = if saved.profile.private_key {
                    Authentication::PrivateKey {
                        openssh: secret,
                        passphrase: saved.passphrase.take().map(Zeroizing::new),
                    }
                } else {
                    Authentication::Password(secret)
                };
                bind_display(&display_entry, crate::display::capture(v, None)?);
                Ok((saved.profile.clone(), auth, prepared, None))
            }
        })
    })
    .await??;
    let crate::connections::Prepared {
        mut config,
        policy,
        vault_scope,
        tmux_enabled,
    } = prepared;
    let integration_enabled = config.integration.is_some() && !is_temporary;
    *entry.integration_scope.lock() = None;
    let size = entry.session.snapshot()?.size;
    config.columns = size.columns;
    config.rows = size.rows;
    let port = profile.port;
    let profile_id = profile.id.clone();
    let username = profile.username.clone();
    let (tmux_tx, mut tmux_rx) = mpsc::channel(1);
    let tmux_owner = entry
        .tmux
        .owner(attempt.scope())
        .for_target(profile_id.clone(), !is_temporary);
    let mut tmux_open = tmux_enabled;
    if tmux_enabled {
        config.tmux = Some(hspterm_ssh_core::tmux::Policy { requests: tmux_tx });
    }
    let connecting = entry.session.connect_verified(config, auth, policy);
    tokio::pin!(connecting);
    let receipt = loop {
        tokio::select! { biased;
            _ = attempt.cancel.cancelled() => bail!("连接已取消"),
            result = &mut connecting => break result?,
            request = async { if tmux_open { tmux_rx.recv().await } else { std::future::pending().await } } => {
                if let Some(request) = request {
                    tmux_owner.install(next_id(), entry.session.status().generation, request)?;
                } else { tmux_open = false; }
            }
        }
    };
    let connector = entry.session.agent_connector().await?;
    let status = entry.session.status();
    if status.phase == SessionPhase::Connected
        && status.generation == receipt.generation
        && !entry.closed.load(Ordering::Acquire)
        && !entry.transfer_closing.load(Ordering::Acquire)
    {
        anyhow::ensure!(
            receipt.host_key.address == profile.address
                && receipt.host_key.port == port
                && receipt.username == username,
            "实际SSH连接回执与原目标不匹配；未关联文件或Agent能力"
        );
        tmux_owner.bind(receipt.generation, receipt.tmux, receipt.tmux_session);
        let target = crate::transfers::Target {
            host_id: profile_id,
            address: receipt.host_key.address,
            port: receipt.host_key.port,
            username: receipt.username,
            fingerprint: receipt.host_key.sha256,
        };
        if integration_enabled {
            *entry.integration_scope.lock() = Some((
                receipt.generation,
                vault_scope.clone(),
                target.host_id.clone(),
            ));
        }
        let same_target = prior_target.as_ref() == Some(&target);
        *entry.transfer_target.lock() = Some((status.generation, target.clone()));
        entry
            .agents
            .bind(receipt.generation, vault_scope.clone(), target, connector)?;
        if let Some(rules) = restore_rules {
            let rules = if same_target {
                rules
            } else {
                Err("实际SSH目标身份与上次连接不同，未恢复旧转发；请检查规则后手动启动".to_owned())
            };
            entry
                .forwardings
                .restore(id, status.generation, entry.session.clone(), rules)
                .await;
        }
        if same_target && !is_temporary && !was_temporary {
            let scope = vault_scope;
            let original = transfer_connection(id);
            let expected_generation = status.generation;
            let restored = tokio::task::spawn_blocking(move || -> Result<Option<String>> {
                anyhow::ensure!(transfer_quiesced, "旧传输暂停与检查点未确认，未启动重连恢复");
                let original = original?;
                anyhow::ensure!(original.generation == expected_generation, "原SSH连接回执已失效");
                let local = crate::transfers::reconnect::restore(original.clone(), &scope)?;
                let mut started = local.started;
                let mut deferred = local.deferred;
                let mut failed = local.failed;
                for (a, b) in crate::remote_transfers::reconnect::pairs(id, &scope)? {
                    // The other endpoint must already be connected. This
                    // lookup does not create SSH or substitute another tab.
                    let endpoint = |terminal| {
                        if terminal == id { Ok(original.clone()) } else { transfer_connection(terminal) }
                    };
                    let pair = endpoint(a).and_then(|a| endpoint(b).map(|b| (a, b)));
                    let (a, b) = match pair { Ok(pair) => pair, Err(_) => { deferred += 1; continue; } };
                    match crate::remote_transfers::reconnect::restore(a, b, &scope) {
                        Ok(report) => { started += report.started; deferred += report.deferred; failed += report.failed; }
                        Err(_) => failed += 1,
                    }
                }
                Ok((started + deferred + failed > 0).then(|| format!(
                    "手动重连传输恢复：已入队{started}项、待手动处理{deferred}项、恢复失败{failed}项；未重试已知失败文件或冲突")))
            }).await;
            let notice = match restored {
                Ok(Ok(value)) => value,
                _ => Some(
                    "SSH已连接，但未完成传输恢复未获完整确认；请在队列检查原任务并手动处理".into(),
                ),
            };
            if entry.session.status().generation == status.generation {
                *entry.transfer_reconnect_notice.lock() =
                    notice.map(|message| (status.generation, message));
            }
        }
    } else {
        bail!("原SSH连接回执已失效；未关联到其他终端代次");
    }
    Ok(())
}
/// A separate bounded status; restoration failure never relabels SSH failure.
pub async fn transfer_reconnect_notice(id: u32) -> Result<Option<String>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        let generation = e.session.status().generation;
        let notice = e
            .transfer_reconnect_notice
            .lock()
            .as_ref()
            .filter(|(g, _)| *g == generation)
            .map(|(_, text)| text.clone());
        Ok(notice)
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn cancel_connection(id: u32) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        diagnostics::record(
            DiagnosticCode::ConnectionCancelRequested,
            Some(id),
            Some(e.session.status().generation),
        );
        e.verification.cancel();
        e.tmux.cancel_pending();
        e.pending_keys.lock().clear();
        e.session.cancel_connect();
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Explicit saved-host handshake only. Target credentials are not read or sent.
/// UI metadata must still identify the same saved endpoint at the network boundary.
pub async fn test_host_connection(
    id: u32,
    host_id: String,
    expected_address: String,
    expected_port: u16,
    expected_username: String,
    expected_jump_host_id: Option<String>,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        if e.closed.load(Ordering::Acquire) || e.transfer_closing.load(Ordering::Acquire) {
            bail!("连接测试已结束");
        }
        let attempt = e.verification.begin(e.session.clone())?;
        let scope = attempt.scope();
        let requests = e.host_sender.clone();
        let prepared = tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let repo = hspterm_storage_sync::Repository::new(v);
                let host = repo.host(&host_id)?.context("请先正式保存主机配置")?;
                if host.address != expected_address
                    || host.port != expected_port
                    || host.username != expected_username
                    || host.jump_host_id != expected_jump_host_id
                {
                    bail!("主机目标已变化，请重新选择并明确测试");
                }
                let route = crate::connections::configuration(&repo, &host)?;
                route.prepare(v, &scope, requests)
            })
        })
        .await??;
        tokio::select! {
            biased;
            _ = attempt.cancel.cancelled() => bail!("连接测试已取消"),
            result = e.session.test_connection(prepared.config, prepared.policy) => result?,
        }
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Resolve a literal path or same-target file URI in the original SSH namespace.
/// This does not open SFTP, probe files, run a shell command or reconnect.
pub async fn resolve_terminal_path(id: u32, generation: u64, text: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            let (address, directory) = terminal_path_context(id, generation)?;
            Ok(hspterm_term_core::resolve_remote_reference(
                &text,
                directory.as_ref(),
                &address,
            )?)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

fn terminal_path_context(
    id: u32,
    generation: u64,
) -> Result<(String, Option<hspterm_term_core::WorkingDirectory>)> {
    let (address, _, directory) = terminal_path_context_revision(id, generation)?;
    Ok((address, directory))
}
fn terminal_path_context_revision(
    id: u32,
    generation: u64,
) -> Result<(String, u64, Option<hspterm_term_core::WorkingDirectory>)> {
    let e = entry(id)?;
    let check = || -> Result<()> {
        let status = e.session.status();
        if e.closed.load(Ordering::Acquire)
            || e.transfer_closing.load(Ordering::Acquire)
            || status.phase != SessionPhase::Connected
            || status.generation != generation
        {
            bail!("原SSH会话已改变或断开；未定位到其他会话");
        }
        Ok(())
    };
    check()?;
    let target = e
        .transfer_target
        .lock()
        .clone()
        .filter(|(g, _)| *g == generation)
        .context("原SSH目标身份尚不可用")?
        .1;
    let (revision, directory) = e.session.directory_context();
    check()?;
    Ok((target.address, revision, directory))
}

pub struct RelativeTerminalPaths {
    pub directory_revision: u64,
    pub paths: Vec<String>,
}
/// Metadata only. No SFTP/exec/PTY IO and no shell-type inference.
pub async fn terminal_relative_paths(
    id: u32,
    generation: u64,
    expected_directory_revision: Option<u64>,
    paths: Vec<String>,
) -> Result<RelativeTerminalPaths> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        ensure!(
            !paths.is_empty() && paths.len() <= 1024,
            "相对路径最多1024项，请分批复制"
        );
        let bytes = paths
            .iter()
            .try_fold(0usize, |n, p| n.checked_add(p.len()))
            .context("路径数据超过容量")?;
        ensure!(bytes <= 1024 * 1024, "路径数据超过1MiB，请分批复制");
        tokio::task::spawn_blocking(move || {
            let (address, revision, directory) = terminal_path_context_revision(id, generation)?;
            ensure!(
                expected_directory_revision.is_none_or(|r| r == revision),
                "终端工作目录已改变，请重新打开菜单"
            );
            let result = paths
                .iter()
                .map(|p| hspterm_term_core::relative_remote_path(p, directory.as_ref(), &address))
                .collect::<Result<Vec<_>, _>>()?;
            let (current, latest, _) = terminal_path_context_revision(id, generation)?;
            ensure!(
                current == address && latest == revision,
                "原终端或工作目录已改变，请重新打开菜单"
            );
            Ok(RelativeTerminalPaths {
                directory_revision: revision,
                paths: result,
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Passive local read only. A mismatched/unknown authority is not a navigation target.
pub async fn terminal_working_directory(id: u32, generation: u64) -> Result<Option<String>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            let (address, directory) = terminal_path_context(id, generation)?;
            Ok(directory
                .filter(|d| d.matches_host(&address))
                .map(|d| d.path))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn answer_host_key(id: u32, request_id: u32, accept: bool) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let generation = entry.session.status().generation;
        let request = entry
            .pending_keys
            .lock()
            .remove(&request_id)
            .context("指纹请求已失效")?;
        let result = tokio::task::spawn_blocking(move || {
            with_vault(|v| entry.verification.answer(v, request, accept))
        })
        .await?;
        if result.is_ok() {
            diagnostics::record(
                if accept {
                    DiagnosticCode::HostKeyAccepted
                } else {
                    DiagnosticCode::HostKeyRejected
                },
                Some(id),
                Some(generation),
            );
        }
        result
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn set_visible(id: u32, visible: bool) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        entry.visible.store(visible, Ordering::Release);
        entry.kick.notify_one();
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn take_frame(id: u32) -> Result<Option<RenderFrame>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        entry.frame_pulls.fetch_add(1, Ordering::Relaxed);
        let result = (|| -> Result<Option<RenderFrame>> {
            if !entry.visible.load(Ordering::Acquire) {
                return Ok(None);
            }
            // Round-12: clone the 1 KiB fingerprint and DROP the previous
            // guard before touching the session terminal. The old code held
            // this guard across the whole frame build; nested with the
            // terminal mutex inside frame_if_changed it can form a lock
            // cycle with every other path that takes the terminal first.
            let previous_copy = entry.previous.lock().clone();
            let probe = entry.session.frame_if_changed(previous_copy.as_ref())?;
            let Some(snapshot) = probe.snapshot else {
                // Nothing visible changed; consume the revision so the pull
                // loop stays quiet until the next real change.
                entry
                    .last_revision
                    .store(probe.fingerprint.revision, Ordering::Release);
                return Ok(None);
            };
            let fingerprint = probe.fingerprint;
            let search = entry
                .search
                .lock()
                .clone()
                .filter(|index| index.revision() == snapshot.content_revision);
            let mut previous_copy = entry.previous.lock();
            let decorations = entry.display.lock().as_ref().map(|runtime| {
                let config = runtime.decorator.config();
                let enabled = config.enabled
                    && config.same_word
                    && (!snapshot.alternate_screen || config.allow_in_alternate_screen);
                let changed =
                    crate::frame::changed_rows(previous_copy.as_ref(), &fingerprint).collect();
                let decorated = runtime.decorator.decorate_rows(&snapshot, Some(&changed));
                (enabled, config.same_word_case_sensitive, decorated)
            });
            let mut frame = crate::frame::delta(previous_copy.as_ref(), snapshot, &fingerprint);
            if let Some((enabled, case_sensitive, decorated)) = decorations {
                frame.same_word_enabled = Some(enabled);
                frame.same_word_case_sensitive = Some(case_sensitive);
                frame.decorations_limited = Some(decorated.limited);
                for d in decorated.cells {
                    if let Ok(index) = frame.changed_rows.binary_search_by_key(&d.row, |r| r.index)
                        && let Some(cell) = frame.changed_rows[index]
                            .cells
                            .get_mut(usize::from(d.column))
                    {
                        if let Some(color) = d.style.foreground {
                            cell.foreground = color;
                        }
                        if let Some(color) = d.style.background {
                            cell.background = color;
                        }
                        if d.style.underline {
                            cell.flags |= 8;
                        }
                    }
                }
            }
            if let Some(search) = search {
                frame.search_revision = Some(search.revision());
                let first = (frame.history_lines - frame.display_offset) as usize;
                for hit in search.visible_hits(first, frame.rows as usize)? {
                    for row in hit.start.row.max(first as u32)
                        ..=hit.end.row.min((first + frame.rows as usize - 1) as u32)
                    {
                        let start = if row == hit.start.row {
                            hit.start.column
                        } else {
                            0
                        };
                        let end = if row == hit.end.row {
                            hit.end.column
                        } else {
                            frame.columns
                        };
                        if end <= start {
                            continue;
                        }
                        let row = (row as usize - first) as u16;
                        if let Some(last) = frame
                            .search_spans
                            .last_mut()
                            .filter(|last| last.row == row && last.end >= start)
                        {
                            last.end = last.end.max(end);
                        } else {
                            frame.search_spans.push(SearchSpan { row, start, end });
                        }
                    }
                }
            }
            entry.cells_sent.fetch_add(
                frame
                    .changed_rows
                    .iter()
                    .map(|row| row.cells.len() as u64)
                    .sum::<u64>(),
                Ordering::Relaxed,
            );
            entry
                .rows_sent
                .fetch_add(frame.changed_rows.len() as u64, Ordering::Relaxed);
            entry.last_revision.store(frame.revision, Ordering::Release);
            *previous_copy = Some(fingerprint);
            Ok(Some(frame))
        })();
        entry.in_flight.store(false, Ordering::Release);
        if result.is_ok() {
            entry.kick.notify_one();
        }
        result
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn resize_terminal(
    id: u32,
    columns: u16,
    rows: u16,
    cell_width: u16,
    cell_height: u16,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        *entry.cell_size.lock() = (cell_width, cell_height);
        entry.session.set_cell_pixels(cell_width, cell_height);
        entry.session.resize(Size::new(columns, rows)?).await?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn scroll_terminal(id: u32, lines: i32) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        entry(id)?.session.scroll(lines)?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
fn modifiers(bits: u8) -> Modifiers {
    Modifiers {
        shift: bits & 1 != 0,
        alt: bits & 2 != 0,
        control: bits & 4 != 0,
        super_key: bits & 8 != 0,
        hyper: bits & 16 != 0,
        meta: bits & 32 != 0,
        caps_lock: bits & 64 != 0,
        num_lock: bits & 128 != 0,
    }
}
pub async fn send_key(id: u32, input: KeyboardInput) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let key = match input.key.as_str() {
            "ShiftLeft" => Key::Functional(57441),
            "ControlLeft" => Key::Functional(57442),
            "AltLeft" => Key::Functional(57443),
            "MetaLeft" => Key::Functional(57444),
            "ShiftRight" => Key::Functional(57447),
            "ControlRight" => Key::Functional(57448),
            "AltRight" => Key::Functional(57449),
            "MetaRight" => Key::Functional(57450),
            "CapsLock" => Key::Functional(57358),
            "ScrollLock" => Key::Functional(57359),
            "NumLock" => Key::Functional(57360),
            "Enter" => Key::Enter,
            "Tab" => Key::Tab,
            "Escape" => Key::Escape,
            "Backspace" => Key::Backspace,
            "Delete" => Key::Delete,
            "Insert" => Key::Insert,
            "ArrowUp" => Key::Up,
            "ArrowDown" => Key::Down,
            "ArrowLeft" => Key::Left,
            "ArrowRight" => Key::Right,
            "Home" => Key::Home,
            "End" => Key::End,
            "PageUp" => Key::PageUp,
            "PageDown" => Key::PageDown,
            name if name.starts_with('F') && name[1..].parse::<u8>().is_ok() => {
                Key::Function(name[1..].parse()?)
            }
            name if name.chars().count() == 1 => {
                Key::Character(name.chars().next().context("空按键")?)
            }
            _ => bail!("不支持的按键"),
        };
        let kind = match input.kind {
            0 => KeyKind::Press,
            1 => KeyKind::Repeat,
            2 => KeyKind::Release,
            _ => bail!("按键事件无效"),
        };
        entry(id)?
            .session
            .input(TerminalInput::Key(KeyEvent {
                key,
                modifiers: modifiers(input.modifiers),
                kind,
                text: input.text,
                shifted_key: input.shifted.and_then(|s| s.chars().next()),
                base_key: input.base.and_then(|s| s.chars().next()),
            }))
            .await?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn send_text(id: u32, text: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        entry(id)?.session.input(TerminalInput::Text(text)).await?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn send_focus(id: u32, focused: bool) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        entry(id)?
            .session
            .input(TerminalInput::Focus(focused))
            .await?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn paste_text(id: u32, text: String, confirmed: bool) -> Result<PasteResult> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        Ok(
            match entry(id)?
                .session
                .input(TerminalInput::Paste { text, confirmed })
                .await?
            {
                InputOutcome::Sent { bracketed_paste } => PasteResult {
                    needs_confirmation: false,
                    lines: 0,
                    bytes: 0,
                    bracketed: bracketed_paste,
                },
                InputOutcome::Confirm {
                    lines,
                    bytes,
                    bracketed,
                } => PasteResult {
                    needs_confirmation: true,
                    lines: lines as u32,
                    bytes: bytes as u32,
                    bracketed,
                },
            },
        )
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn send_mouse(
    id: u32,
    column: u16,
    row: u16,
    action: u8,
    button: u8,
    mods: u8,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let b = match button {
            0 => Some(MouseButton::Left),
            1 => Some(MouseButton::Middle),
            2 => Some(MouseButton::Right),
            _ => None,
        };
        let action = match action {
            0 => MouseAction::Press(b.context("鼠标按钮无效")?),
            1 => MouseAction::Release(b.context("鼠标按钮无效")?),
            2 => MouseAction::Motion(b),
            3 => MouseAction::WheelUp,
            4 => MouseAction::WheelDown,
            _ => bail!("鼠标动作无效"),
        };
        entry(id)?
            .session
            .input(TerminalInput::Mouse(MouseEvent {
                column,
                row,
                action,
                modifiers: modifiers(mods),
            }))
            .await?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn answer_clipboard(id: u32, request_id: u32, text: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let (generation, formatter) = entry
            .pending_clipboard
            .lock()
            .remove(&request_id)
            .context("剪贴板请求已失效")?;
        if generation != entry.session.status().generation
            || entry.session.status().phase != SessionPhase::Connected
        {
            bail!("剪贴板请求所属连接已结束");
        }
        let reply = formatter(&text);
        if !reply.is_empty() {
            entry.session.write(reply.into_bytes()).await?;
        }
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
fn tmux_event(entry: &Entry) -> Option<BridgeEvent> {
    if let Some((token, generation)) = entry.tmux.token() {
        let mut message = event("tmux", generation, None);
        message.request_id = token;
        return Some(message);
    }
    entry.tmux.active().map(|(generation, mode)| {
        let text = match mode {
            None => "shell",
            Some(s) if s.readonly => "readonly",
            Some(_) => "control",
        };
        event("tmuxState", generation, Some(text.into()))
    })
}
// Command contents never appear in Debug, platform events or diagnostics.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Default)]
struct SuggestionsCache {
    scope: String,
    host: String,
    version: (u64, u64, u64),
    index: Option<hspterm_storage_sync::command_history::HistoryIndex>,
    proposal: Option<SuggestionProposal>,
}
#[flutter_rust_bridge::frb(ignore)]
struct SuggestionProposal {
    ticket: String,
    proof: hspterm_term_core::integration::Proof,
    version: (u64, u64, u64),
    choices: Vec<Zeroizing<String>>,
}
static HISTORY_IMPORT_EPOCH: AtomicU64 = AtomicU64::new(0);
/// Bumped when a qualified command is recorded so every session's suggestion
/// cache rebuilds and the just-executed command of the current session becomes
/// visible without a restart or reconnect.
static HISTORY_RECORD_EPOCH: AtomicU64 = AtomicU64::new(0);
fn history_version() -> (u64, u64, u64) {
    let versions = hspterm_storage_sync::cloud_sync::journal::versions();
    let latest = versions.borrow().values().copied().max().unwrap_or(0);
    (
        latest,
        HISTORY_IMPORT_EPOCH.load(Ordering::Acquire),
        HISTORY_RECORD_EPOCH.load(Ordering::Acquire),
    )
}
fn retire_suggestions() {
    retire_suggestions_for(None);
}
fn retire_suggestions_for(host: Option<&str>) {
    HISTORY_IMPORT_EPOCH.fetch_add(1, Ordering::AcqRel);
    for entry in sessions().lock().values() {
        if host.is_none_or(|host| {
            entry
                .integration_scope
                .lock()
                .as_ref()
                .is_some_and(|(_, _, id)| id == host)
        }) {
            // Clear Host A must not discard accepted commands waiting for SQL
            // in Host B. Candidate caches still observe the global version.
            entry.history_capture_epoch.fetch_add(1, Ordering::AcqRel);
        }
        *entry.suggestions.lock() = SuggestionsCache::default();
        entry.kick.notify_one();
    }
}
fn suggestion_context(
    entry: &Entry,
    generation: u64,
) -> Option<(String, String, crate::transfers::Target)> {
    let status = entry.session.status();
    if entry.closed.load(Ordering::Acquire)
        || entry.temporary_connection.load(Ordering::Acquire)
        || status.phase != SessionPhase::Connected
        || status.generation != generation
    {
        return None;
    }
    let (bound, scope, host) = entry.integration_scope.lock().clone()?;
    let (target_generation, target) = entry.transfer_target.lock().clone()?;
    (bound == generation && target_generation == generation && host == target.host_id)
        .then_some((scope, host, target))
}
fn allowed_integration(
    v: &mut Vault,
    scope: &str,
    host: &str,
    target: &crate::transfers::Target,
) -> Result<bool> {
    if v.instance_id() != scope {
        return Ok(false);
    }
    Ok(hspterm_storage_sync::Repository::new(v)
        .host(host)?
        .is_some_and(|record| {
            record.shell_integration
                && record.address == target.address
                && record.port == target.port
                && record.username == target.username
        }))
}
#[derive(Clone)]
pub struct TerminalSuggestions {
    pub ticket: String,
    pub prompt: u64,
    pub revision: u64,
    pub choices: Vec<String>,
}
/// Empty/unknown editing context yields None, never a guessed prefix. The
/// original-Vault memory index is rebuilt only after configuration mutations.
pub async fn terminal_suggestions(id: u32, generation: u64) -> Result<Option<TerminalSuggestions>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let gate = entry.history_gate.clone().lock_owned().await;
        tokio::task::spawn_blocking(move || {
            let _gate = gate;
            let Some((scope, host, target)) = suggestion_context(&entry, generation) else {
                return Ok(None);
            };
            let Some((proof, prefix)) = entry.session.integration_input() else {
                return Ok(None);
            };
            if prefix.is_empty() {
                entry.suggestions.lock().proposal = None;
                return Ok(None);
            }
            let result = with_vault(|v| {
                if v.instance_id() != scope {
                    return Ok(None);
                }
                let version = history_version();
                let mut cache = entry.suggestions.lock();
                if cache.scope != scope
                    || cache.host != host
                    || cache.version != version
                    || cache.index.is_none()
                {
                    *cache = SuggestionsCache::default();
                    if !allowed_integration(v, &scope, &host, &target)? {
                        return Ok(None);
                    }
                    // Suggestion pool is shared across all hosts; the cache
                    // stays host-bound so a host switch forces a re-check of
                    // the integration authorization.
                    let index = hspterm_storage_sync::command_history::HistoryRepository::new(v)
                        .index_all()?;
                    cache.scope = scope.clone();
                    cache.host = host.clone();
                    cache.version = version;
                    cache.index = Some(index);
                }
                let choices = cache
                    .index
                    .as_ref()
                    .context("历史候选索引已失效")?
                    .candidates(&scope, None, &prefix, 20)?;
                if choices.is_empty() {
                    cache.proposal = None;
                    return Ok(None);
                }
                let ticket = format!("{:032x}", rand::random::<u128>());
                let view = TerminalSuggestions {
                    ticket: ticket.clone(),
                    prompt: proof.prompt,
                    revision: proof.revision,
                    choices: choices.iter().map(|text| text.to_string()).collect(),
                };
                cache.proposal = Some(SuggestionProposal {
                    ticket,
                    proof,
                    version,
                    choices,
                });
                Ok(Some(view))
            })?;
            if suggestion_context(&entry, generation).is_none()
                || entry.session.integration_proof() != Some(proof)
            {
                use zeroize::Zeroize;
                if let Some(mut view) = result {
                    view.choices.zeroize();
                }
                entry.suggestions.lock().proposal = None;
                return Ok(None);
            }
            Ok(result)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
fn integration_guard(
    entry: &Arc<Entry>,
    generation: u64,
    version: (u64, u64, u64),
) -> Arc<dyn Fn() -> bool + Send + Sync> {
    let weak = Arc::downgrade(entry);
    Arc::new(move || {
        history_version() == version
            && weak
                .upgrade()
                .is_some_and(|entry| suggestion_context(&entry, generation).is_some())
    })
}
/// Status is Applied / Unavailable (proved not sent) / Unconfirmed (never
/// automatically retry, execute a second time, or substitute clipboard paste).
pub async fn choose_terminal_suggestion(
    id: u32,
    generation: u64,
    ticket: String,
    index: u32,
    execute: bool,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let Some((scope, host, target)) = suggestion_context(&entry, generation) else {
            return Ok("Unavailable".into());
        };
        let proposal = {
            let mut cache = entry.suggestions.lock();
            if cache.proposal.as_ref().is_none_or(|p| p.ticket != ticket) {
                return Ok("Unavailable".into());
            }
            cache.proposal.take().unwrap()
        };
        let Some(choice) = proposal.choices.get(index as usize).cloned() else {
            return Ok("Unavailable".into());
        };
        let version = proposal.version;
        if history_version() != version || entry.session.integration_proof() != Some(proposal.proof)
        {
            return Ok("Unavailable".into());
        }
        let approved = tokio::task::spawn_blocking(move || {
            with_vault(|v| allowed_integration(v, &scope, &host, &target))
        })
        .await??;
        if !approved {
            return Ok("Unavailable".into());
        }
        let kind = if execute {
            hspterm_ssh_core::IntegratedEdit::Execute
        } else {
            hspterm_ssh_core::IntegratedEdit::Replace
        };
        let guard = integration_guard(&entry, generation, version);
        Ok(integrated_result(
            entry
                .session
                .apply_integrated(generation, proposal.proof, kind, choice, false, Some(guard))
                .await,
        ))
    })
    .await;
    crate::public_errors::finish(outcome)
}
fn integrated_result(
    result: std::result::Result<hspterm_ssh_core::IntegratedOutcome, hspterm_ssh_core::SshError>,
) -> String {
    match result {
        Ok(hspterm_ssh_core::IntegratedOutcome::Applied) => "Applied",
        Err(hspterm_ssh_core::SshError::IntegrationUnavailable) => "Unavailable",
        _ => "Unconfirmed",
    }
    .into()
}
fn integration_status(entry: &Entry, generation: u64) -> &'static str {
    if entry.session.status().generation != generation {
        return "StaleConnection";
    }
    if entry.session.status().phase != SessionPhase::Connected {
        return "Disconnected";
    }
    if entry.temporary_connection.load(Ordering::Acquire) {
        return "TemporaryConnection";
    }
    if suggestion_context(entry, generation).is_none() {
        return "ConnectionNotOptedIn";
    }
    entry.session.integration_status()
}
/// Non-secret capability/reason only; does not probe, inject input or reconnect.
pub async fn terminal_integration_status(id: u32, generation: u64) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let current = entry(id)?;
        Ok(integration_status(&current, generation).to_owned())
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Literal paths from this exact session's SFTP; no lookup, expansion, upload or
/// download. Only the confirmed optional Bash helper can accept these bytes.
pub async fn insert_terminal_paths(
    id: u32,
    generation: u64,
    paths: Vec<String>,
    enter_directory: bool,
    names_only: Option<bool>,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        ensure!(
            !paths.is_empty() && paths.len() <= 1024 && (!enter_directory || paths.len() == 1),
            "路径数量无效"
        );
        ensure!(
            paths
                .iter()
                .all(|path| path.starts_with('/') && !path.contains('\0'))
                && paths.iter().map(String::len).sum::<usize>() <= 1024 * 1024,
            "远端路径无效或超过容量"
        );
        let entry = entry(id)?;
        crate::run_log::decision(
            "path.insert",
            integration_status(&entry, generation),
            id,
            generation,
        );
        let Some((scope, host, target)) = suggestion_context(&entry, generation) else {
            return Ok("Unavailable".into());
        };
        let Some(proof) = entry.session.integration_proof() else {
            return Ok("Unavailable".into());
        };
        let version = history_version();
        let approved = tokio::task::spawn_blocking(move || {
            with_vault(|v| allowed_integration(v, &scope, &host, &target))
        })
        .await??;
        if !approved {
            crate::run_log::decision("path.insert", "PermissionRevoked", id, generation);
            return Ok("Unavailable".into());
        }
        ensure!(
            !(enter_directory && names_only.unwrap_or(false)),
            "文件名插入不能作为进入目录操作"
        );
        let quoted = paths
            .iter()
            .map(|path| {
                let path = if names_only.unwrap_or(false) {
                    path.rsplit('/').next().unwrap_or("")
                } else {
                    path.as_str()
                };
                format!("'{}'", path.replace('\'', "'\\''"))
            })
            .collect::<Vec<_>>()
            .join(" ");
        let text = Zeroizing::new(if enter_directory {
            format!("cd {quoted}")
        } else {
            quoted
        });
        let kind = if enter_directory {
            hspterm_ssh_core::IntegratedEdit::Execute
        } else {
            hspterm_ssh_core::IntegratedEdit::Insert
        };
        let result = integrated_result(
            entry
                .session
                .apply_integrated(
                    generation,
                    proof,
                    kind,
                    text,
                    enter_directory,
                    Some(integration_guard(&entry, generation, version)),
                )
                .await,
        );
        crate::run_log::decision(
            "path.result",
            match result.as_str() {
                "Applied" => "Applied",
                "Unavailable" => "Unavailable",
                _ => "Unconfirmed",
            },
            id,
            generation,
        );
        Ok(result)
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Actor-owned persistence. The actual worker retains its gate even if an RPC
/// or renderer goes away; closing awaits the actor and this original worker.
async fn record_integration_commands(
    entry: Arc<Entry>,
    generation: u64,
    submissions: Vec<hspterm_term_core::integration::Submission>,
) -> Result<()> {
    // A clear/record preference/import which commits while this original
    // submission waits must not let its delayed worker revive old history.
    let capture_epoch = entry.history_capture_epoch.load(Ordering::Acquire);
    let gate = entry.history_gate.clone().lock_owned().await;
    tokio::task::spawn_blocking(move || {
        let _gate = gate;
        if entry.temporary_connection.load(Ordering::Acquire) {
            return Ok(());
        }
        let Some((bound, scope, host_id)) = entry.integration_scope.lock().clone() else {
            return Ok(());
        };
        if bound != generation || entry.session.status().generation != generation {
            return Ok(());
        }
        let Some((target_generation, target)) = entry.transfer_target.lock().clone() else {
            return Ok(());
        };
        if target_generation != generation || target.host_id != host_id {
            return Ok(());
        }
        with_vault(|v| {
            if v.instance_id() != scope
                || entry.history_capture_epoch.load(Ordering::Acquire) != capture_epoch
            {
                return Ok(());
            }
            let Some(host) = hspterm_storage_sync::Repository::new(v).host(&host_id)? else {
                return Ok(());
            };
            if !host.shell_integration
                || host.address != target.address
                || host.port != target.port
                || host.username != target.username
                || entry.session.status().generation != generation
            {
                return Ok(());
            }
            let texts: Vec<&str> = submissions
                .iter()
                .map(|submission| submission.text.as_str())
                .collect();
            let recorded = hspterm_storage_sync::command_history::HistoryRepository::new(v)
                .record_qualified_batch(&host_id, &texts)?;
            if recorded > 0 {
                // Make this session's just-executed commands visible to every
                // suggestion cache, including the recording session itself.
                HISTORY_RECORD_EPOCH.fetch_add(1, Ordering::AcqRel);
            }
            Ok(())
        })
    })
    .await?
}

/// Drop an obsolete search's frozen grid/plaintext even while its view is
/// hidden. Read the terminal outside the search lock; a replacement index is
/// protected by Arc identity so an older observation cannot erase a new one.
fn retire_stale_search(entry: &Entry) {
    let Some(observed) = entry.search.lock().clone() else {
        return;
    };
    if observed.revision() == entry.session.content_revision() {
        return;
    }
    let retired = {
        let mut current = entry.search.lock();
        if current
            .as_ref()
            .is_some_and(|index| Arc::ptr_eq(index, &observed))
        {
            current.take()
        } else {
            None
        }
    };
    // Potentially large zeroization/destructors must run outside the lock.
    drop(retired);
}

/// Only small invalidations/platform events cross FFI; no history command body.
pub async fn watch_events(id: u32, sink: StreamSink<BridgeEvent>) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
    let entry = entry(id)?;
    let mut frames = entry.session.subscribe_frames();
    let mut forwards = entry.forwardings.subscribe();
    let mut agents = entry.agents.subscribe();
    let mut integration = entry.session.subscribe_integration();
    let mut history_changes = hspterm_storage_sync::cloud_sync::journal::versions();
    let mut tmux = entry.tmux.subscribe();
    let mut states = entry.session.subscribe();
    let mut events = entry.events.lock().await.take().context("终端已被订阅")?;
    let mut keys = entry
        .host_requests
        .lock()
        .await
        .take()
        .context("终端已被订阅")?;
    let initial = states.borrow_and_update().clone();
    diagnostics::status(id, initial.generation, initial.phase);
    let mut last_status = initial.clone();
    let mut status = event(
        "status",
        initial.generation,
        Some(format!("{:?}", initial.phase)),
    );
    status.detail = initial.error;
    status.rtt_micros = initial.rtt_micros;
    if sink.add(status).is_err() {
        entry.session.shutdown();
        return Ok(());
    }
    if let Some(message) = tmux_event(&entry)
        && sink.add(message).is_err()
    {
        entry.session.shutdown();
        return Ok(());
    }
    entry.kick.notify_one();
    let mut next_frame_at = tokio::time::Instant::now();
    let mut pending_directory = None;
    let mut directory_at = None;
    let mut forwarding_at = None;
    let mut agent_at = None;
    let mut shell_at = None;
    let mut history_seen = history_version();
    let mut notification_policy = None;
    loop {
        let version = history_version();
        if history_seen != version {
            history_seen = version;
            if entry.integration_scope.lock().is_some() && shell_at.is_none() {
                shell_at = Some(tokio::time::Instant::now() + Duration::from_micros(16_667));
            }
        }
        let current_policy = (
            entry.session.status().generation,
            entry.session.notification_policy(),
        );
        if notification_policy != Some(current_policy) {
            notification_policy = Some(current_policy);
            if sink
                .add(event(
                    "notificationPolicy",
                    current_policy.0,
                    Some(current_policy.1.to_string()),
                ))
                .is_err()
            {
                break;
            }
        }
        tokio::select! {
            result=integration.changed()=>{
                if result.is_err(){break;}
                integration.borrow_and_update();
                if shell_at.is_none(){shell_at=Some(tokio::time::Instant::now()+Duration::from_micros(16_667));}
            }
            result=history_changes.changed()=>{if result.is_err(){break;} history_changes.borrow_and_update();}
            _=async { if let Some(at)=shell_at {tokio::time::sleep_until(at).await;} else {std::future::pending::<()>().await;} }=>{
                shell_at=None;
                // Detail tells the UI whether the plain-shell input proof is
                // currently ready: while it is, mouse reporting left on by an
                // exited TUI must not forward events into the echo stream.
                let ready=entry.session.integration_input().is_some();
                if sink.add(event("shellInput",entry.session.status().generation,if ready{Some("ready".into())}else{None})).is_err(){break;}
            }
            _=async {
                if let Some(at)=forwarding_at {tokio::time::sleep_until(at).await;}
                else {std::future::pending::<()>().await;}
            }=>{
                forwarding_at=None;
                if sink.add(event("forwardings",entry.session.status().generation,None)).is_err(){break;}
            }
            _=async {
                if let Some(at)=agent_at {tokio::time::sleep_until(at).await;}
                else {std::future::pending::<()>().await;}
            }=>{
                agent_at=None;
                if sink.add(event("agent",entry.session.status().generation,None)).is_err(){break;}
            }
            result=agents.changed()=>{
                if result.is_err(){break;}
                agents.borrow_and_update();
                if agent_at.is_none(){agent_at=Some(tokio::time::Instant::now()+Duration::from_millis(100));}
            }
            result=forwards.changed()=>{
                if result.is_err(){break;}
                forwards.borrow_and_update();
                // Fixed window from the first change: floods cannot starve the
                // notification and idle listeners leave no periodic timer.
                if forwarding_at.is_none(){forwarding_at=Some(tokio::time::Instant::now()+Duration::from_millis(100));}
            }

            _=async {
                if let Some(at)=directory_at { tokio::time::sleep_until(at).await; }
                else { std::future::pending::<()>().await; }
            }=>{
                if let Some((generation,directory))=pending_directory.take() {
                    let directory:Option<hspterm_term_core::WorkingDirectory>=directory;
                    let mut message=event("workingDirectory",generation,directory.as_ref().map(|d|d.path.clone()));
                    message.detail=directory.map(|d|d.authority);
                    if sink.add(message).is_err(){break;}
                }
                directory_at=None;
            }
            r=tmux.changed()=>{
                if r.is_err(){break;}
                tmux.borrow_and_update();
                if let Some(message)=tmux_event(&entry)
                    && sink.add(message).is_err(){break;}
            }
            r=states.changed()=>{
                if r.is_err(){break;}
                let state=states.borrow_and_update().clone();
                let status_changed=state.generation!=last_status.generation || state.phase!=last_status.phase || state.error!=last_status.error;
                if status_changed {
                    diagnostics::status(id,state.generation,state.phase);
                    let mut message=event("status",state.generation,Some(format!("{:?}",state.phase)));
                    message.detail=state.error.clone(); message.rtt_micros=state.rtt_micros;
                    if sink.add(message).is_err() || state.phase==SessionPhase::Closed {break;}
                } else if state.rtt_micros!=last_status.rtt_micros {
                    let mut message=event("latency",state.generation,None);message.rtt_micros=state.rtt_micros;
                    if sink.add(message).is_err(){break;}
                }
                last_status=state;
            }
            r=keys.recv()=>{if let Some(request)=r {
                let Some(jump)=entry.verification.is_jump(&request) else { continue; };
                let request_id=next_id();let mut message=event(if jump {"jumpHostKey"} else {"hostKey"},entry.session.status().generation,Some(request.key.sha256.clone()));
                message.request_id=request_id;message.detail=Some(format!("{}:{} · {}",request.key.address,request.key.port,request.key.algorithm));
                {
                    let mut pending=entry.pending_keys.lock();
                    pending.retain(|_,r| entry.verification.is_jump(r).is_some());
                    pending.insert(request_id,request);
                }
                if sink.add(message).is_err(){break;}
            }}
            r=events.recv()=>{match r {Some(SessionEvent::Reconnected{generation})=>{entry.pending_clipboard.lock().clear();if sink.add(event("reconnected",generation,None)).is_err(){break;}},
                Some(SessionEvent::ShellRestored{generation})=>{
                    pending_directory=None;
                    directory_at=None;
                    entry.pending_clipboard.lock().clear();
                    entry.tmux.shell_restored(generation);
                    if sink.add(event("tmuxState",generation,Some("shell".into()))).is_err(){break;}
                },
                Some(SessionEvent::Notification{generation,notice})=>{
                    let current = entry.session.notification_policy();
                    if notice.policy != current.to_string() { continue; }
                    if notification_policy != Some((generation,current)) {
                        notification_policy=Some((generation,current));
                        if sink.add(event("notificationPolicy",generation,Some(current.to_string()))).is_err(){break;}
                    }
                    let text=serde_json::to_string(&notice)?;
                    if sink.add(event("notification",generation,Some(text))).is_err(){break;}
                },
                Some(SessionEvent::HistoryWarning{generation})=>{
                    if sink.add(event("historyWarning",generation,Some("合格命令历史未获保存确认；终端输入继续，不会自动重试或记录未知输入".into()))).is_err() { break; }
                },
                Some(SessionEvent::WorkingDirectory{generation,directory})=>{
                    pending_directory=Some((generation,directory));
                    if directory_at.is_none(){directory_at=Some(tokio::time::Instant::now()+Duration::from_micros(16_667));}
                },
                Some(SessionEvent::Terminal{generation,event:terminal_event})=>{
                    let message=match terminal_event {
                        Event::ClipboardStore(_,text) if entry.clipboard_enabled.load(Ordering::Acquire)=>Some(event("clipboardWrite",generation,Some(text))),
                        Event::ClipboardLoad(_,formatter) if entry.clipboard_enabled.load(Ordering::Acquire)=>{let request_id=next_id();entry.pending_clipboard.lock().insert(request_id,(generation,formatter));let mut m=event("clipboardRead",generation,None);m.request_id=request_id;Some(m)},
                        Event::ClipboardStore(..)|Event::ClipboardLoad(..)=>None,
                        Event::Title(text)=>Some(event("title",generation,Some(text.chars().take(1024).collect()))),
                        // Bell has a single bounded/deduplicated notification path.
                        Event::Bell|Event::Notification{..}|Event::NotificationLine(_)=>None,
                        Event::ColorRequest(..)|Event::TextAreaSizeRequest(..)|Event::PtyWrite(_)=>None,
                        Event::ResetTitle=>Some(event("title",generation,Some("HSPTerm".into()))),
                        Event::WorkingDirectory(_)=>None,
                        Event::ShellMarker(_)|Event::ShellIntegration(_)|Event::CommandBoundary(_)|Event::CommandBoundaryInvalid=>None,
                        Event::MouseCursorDirty|Event::CursorBlinkingChange|Event::Wakeup|Event::Exit|Event::ChildExit(_)=>None,
                    };if let Some(message)=message && sink.add(message).is_err(){break;}
                },None=>break}}
            r=frames.changed()=>{if r.is_err(){break;} frames.borrow_and_update();retire_stale_search(&entry);}
            _=entry.kick.notified()=>{}
        }
        if entry.visible.load(Ordering::Acquire)
            && entry.session.revision() != entry.last_revision.load(Ordering::Acquire)
            && !entry.in_flight.load(Ordering::Acquire)
        {
            // Acknowledgement kicks and output invalidations share the same
            // limit. Neither may bypass it; idle/hidden terminals have no timer.
            tokio::time::sleep_until(next_frame_at).await;
            if entry.visible.load(Ordering::Acquire)
                && !entry.in_flight.swap(true, Ordering::AcqRel)
            {
                next_frame_at = tokio::time::Instant::now() + Duration::from_micros(16_667);
                if sink
                    .add(event("frame", entry.session.status().generation, None))
                    .is_err()
                {
                    break;
                }
            }
        }
    }
    entry.pending_keys.lock().clear();
    entry.pending_clipboard.lock().clear();
    entry.session.shutdown();
    Ok(())
}).await;
    crate::public_errors::finish(outcome)
}

pub struct SearchSummary {
    pub revision: u64,
    pub count: u32,
    pub markers: Vec<u32>,
    pub document_rows: u32,
}
#[derive(Clone)]
pub struct SearchSpan {
    pub row: u16,
    pub start: u16,
    pub end: u16,
}
pub struct SearchLocation {
    pub revision: u64,
    pub start_row: u32,
    pub start_column: u16,
    pub end_row: u32,
    pub end_column: u16,
}
pub struct TerminalMetrics {
    pub disk_bytes: u64,
    pub disk_reads: u64,
    pub disk_writes: u64,
    pub resident_history_cells: u64,
    pub history_rows: u64,
    pub frame_pulls: u64,
    pub cells_sent: u64,
    pub changed_rows_sent: u64,
}

/// Bounded, cancellable worker; the actor only clones immutable row references.
pub async fn search_terminal(
    id: u32,
    query: String,
    regular_expression: bool,
    case_sensitive: bool,
) -> Result<SearchSummary> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let epoch = entry.search_epoch.fetch_add(1, Ordering::AcqRel) + 1;
        entry.search.lock().take();
        entry.session.invalidate_view();
        let gate = entry.search_gate.clone().lock_owned().await;
        if entry.closed.load(Ordering::Acquire)
            || entry.search_epoch.load(Ordering::Acquire) != epoch
        {
            bail!("搜索已取消");
        }
        if query.is_empty() {
            return Ok(SearchSummary {
                revision: entry.session.content_revision(),
                count: 0,
                markers: vec![0; 128],
                document_rows: 0,
            });
        }
        let document = entry.session.document()?;
        let token = entry.search_epoch.clone();
        let (index, _gate) = tokio::task::spawn_blocking(move || {
            let index =
                document.search_cancellable(&query, regular_expression, case_sensitive, || {
                    token.load(Ordering::Acquire) != epoch
                });
            (index, gate)
        })
        .await?;
        let index = index?;
        if entry.search_epoch.load(Ordering::Acquire) != epoch {
            bail!("搜索已取消");
        }
        if entry.session.content_revision() != index.revision() {
            bail!("终端内容已变化，请更新搜索");
        }
        let summary = SearchSummary {
            revision: index.revision(),
            count: index.count,
            markers: index.markers.clone(),
            document_rows: index.rows() as u32,
        };
        *entry.search.lock() = Some(Arc::new(index));
        entry.session.invalidate_view();
        Ok(summary)
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn navigate_search(id: u32, ordinal: u32) -> Result<SearchLocation> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let search = entry.search.lock().clone().context("搜索结果已失效")?;
        if entry.session.content_revision() != search.revision() {
            bail!("终端内容已变化，请更新搜索");
        }
        let revision = search.revision();
        let hit = tokio::task::spawn_blocking(move || search.hit(ordinal))
            .await??
            .context("搜索位置不存在")?;
        if entry.session.content_revision() != revision {
            bail!("终端内容已变化，请更新搜索");
        }
        let rows = entry.session.snapshot()?.size.rows as u32;
        entry
            .session
            .seek(hit.start.row.saturating_sub(rows / 2) as usize)?;
        Ok(SearchLocation {
            revision,
            start_row: hit.start.row,
            start_column: hit.start.column,
            end_row: hit.end.row,
            end_column: hit.end.column,
        })
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn seek_terminal(id: u32, top_row: u32) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        entry(id)?.session.seek(top_row as usize)?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
fn ensure_command_source(entry: &Entry, generation: u64) -> Result<()> {
    let status = entry.session.status();
    ensure!(
        !entry.closed.load(Ordering::Acquire)
            && status.generation == generation
            && !matches!(
                status.phase,
                SessionPhase::Connecting | SessionPhase::Closed
            ),
        "原终端来源已改变，请重新选择"
    );
    Ok(())
}
/// Explicit metadata request only; no poll, command body, history persistence,
/// shell inference or SSH input. Coordinates belong to the supplied frame.
pub async fn terminal_command_ranges(id: u32, generation: u64, revision: u64) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let gate = entry.search_gate.clone().lock_owned().await;
        tokio::task::spawn_blocking(move || {
            let _gate = gate;
            ensure_command_source(&entry, generation)?;
            let (current, ranges) = entry.session.command_ranges();
            ensure!(current == revision, "终端画面已更新，请重新打开命令操作");
            ensure_command_source(&entry, generation)?;
            Ok(serde_json::to_string(&ranges.into_iter().map(|r| serde_json::json!({
            "id": r.id, "prompt_row": r.prompt.map(|p| p.row),
            "start_row": r.start.row, "start_column": r.start.column,
            "end_row": r.end.row, "end_column": r.end.column, "exit_status": r.exit_status,
        })).collect::<Vec<_>>())?)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// A bounded whole command output read from a frozen validated range. Failure
/// never publishes a partial clipboard value. Ordinary disconnected history
/// remains readable; a new PTY or changed/missing row proof refuses the request.
pub async fn copy_terminal_command_at(
    id: u32,
    generation: u64,
    revision: u64,
    row: u32,
    column: u16,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let gate = entry.search_gate.clone().lock_owned().await;
        tokio::task::spawn_blocking(move || {
            let _gate = gate;
            ensure_command_source(&entry, generation)?;
            let (current, ranges) = entry.session.command_ranges();
            ensure!(current == revision, "终端画面已更新，请重新选择命令输出");
            let range = ranges
                .into_iter()
                .rev()
                .find(|range| {
                    let begin = range.prompt.unwrap_or(range.start);
                    (begin.row, begin.column) <= (row, column)
                        && (row, column) < (range.end.row, range.end.column)
                })
                .context("没有可靠完整的OSC133输出范围，请手动选择后复制")?;
            let (document, range) = entry.session.command_document(range.id)?;
            ensure!(
                document.revision == revision,
                "终端画面已更新，请重新选择命令输出"
            );
            struct Text {
                bytes: Zeroizing<Vec<u8>>,
                source: Arc<Entry>,
                generation: u64,
            }
            impl std::io::Write for Text {
                fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                    if ensure_command_source(&self.source, self.generation).is_err() {
                        return Err(std::io::Error::other("原终端来源已改变"));
                    }
                    if bytes.len() > 10 * 1024 * 1024 - self.bytes.len() {
                        return Err(std::io::Error::other(
                            "命令输出超过10MiB剪贴板上限，请使用文本导出",
                        ));
                    }
                    self.bytes.extend_from_slice(bytes);
                    Ok(bytes.len())
                }
                fn flush(&mut self) -> std::io::Result<()> {
                    Ok(())
                }
            }
            let mut text = Text {
                bytes: Zeroizing::new(Vec::new()),
                source: entry.clone(),
                generation,
            };
            document.export_range(range.start, range.end, &mut text)?;
            ensure_command_source(&entry, generation)?;
            Ok(String::from_utf8(std::mem::take(&mut *text.bytes))?)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn navigate_terminal_command(
    id: u32,
    generation: u64,
    revision: u64,
    top_row: u32,
    next: bool,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let gate = entry.search_gate.clone().lock_owned().await;
        tokio::task::spawn_blocking(move || {
            let _gate = gate;
            ensure_command_source(&entry, generation)?;
            let (current, ranges) = entry.session.command_ranges();
            ensure!(current == revision, "终端画面已更新，请重新选择命令导航");
            let range = if next {
                ranges
                    .iter()
                    .filter(|r| r.prompt.is_some_and(|p| p.row > top_row))
                    .min_by_key(|r| r.prompt.unwrap().row)
            } else {
                ranges
                    .iter()
                    .filter(|r| r.prompt.is_some_and(|p| p.row < top_row))
                    .max_by_key(|r| r.prompt.unwrap().row)
            }
            .context("此方向没有仍可靠保留的OSC133命令标记，请手动滚动")?;
            ensure_command_source(&entry, generation)?;
            entry.session.command_seek(range.id)?;
            Ok(())
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn lock_terminal_size(id: u32, locked: bool) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        entry(id)?.session.lock_size(locked);
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn set_clipboard_enabled(id: u32, enabled: bool) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        entry.clipboard_enabled.store(enabled, Ordering::Release);
        entry.session.set_osc52_enabled(enabled);
        if !enabled {
            entry.pending_clipboard.lock().clear();
        }
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn terminal_metrics(id: u32) -> Result<TerminalMetrics> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let stats = entry.session.history_stats();
        Ok(TerminalMetrics {
            disk_bytes: stats.disk_bytes,
            disk_reads: stats.disk_reads,
            disk_writes: stats.disk_writes,
            resident_history_cells: stats.resident_history_cells as u64,
            history_rows: stats.retained_rows as u64,
            frame_pulls: entry.frame_pulls.load(Ordering::Relaxed),
            cells_sent: entry.cells_sent.load(Ordering::Relaxed),
            changed_rows_sent: entry.rows_sent.load(Ordering::Relaxed),
        })
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Explicit UTF-8 export. A temporary sibling is published only after a complete read;
/// existing destinations are never overwritten implicitly.
pub async fn export_terminal_history(id: u32, path: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let gate = entry.search_gate.clone().lock_owned().await;
        if entry.closed.load(Ordering::Acquire) {
            bail!("终端已关闭");
        }
        let document = entry.session.document()?;
        tokio::task::spawn_blocking(move || -> Result<()> {
            let _gate = gate;
            use std::io::Write;
            let destination = std::path::Path::new(&path);
            let parent = destination
                .parent()
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or(std::path::Path::new("."));
            let mut file = tempfile::NamedTempFile::new_in(parent)?;
            {
                let mut writer = std::io::BufWriter::new(&mut file);
                document.export(&mut writer)?;
                writer.flush()?;
            }
            file.as_file().sync_all()?;
            file.persist_noclobber(destination)?;
            Ok(())
        })
        .await??;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Non-secret host metadata. Credentials are never returned to the UI.
#[derive(Clone)]
pub struct HostConfig {
    pub id: String,
    pub name: String,
    pub address: String,
    pub port: u16,
    pub username: String,
    pub private_key: bool,
    pub group_id: String,
    pub favorite: bool,
    pub note: String,
    pub credential_set: bool,
    pub timeout_seconds: u32,
    pub keepalive_seconds: u32,
    pub keepalive_failures: u32,
    pub use_network_defaults: Option<bool>,
    pub keepalive_response_seconds: Option<u32>,
    pub open_sftp: bool,
    pub follow_osc7: Option<bool>,
    pub proxy: Option<HostProxyConfig>,
    pub jump_host_id: Option<String>,
    pub agent_forwarding: Option<bool>,
    pub tmux_enabled: Option<bool>,
    pub shell_integration: Option<bool>,
}
/// Metadata only. The authentication flag does not contain or retrieve secrets.
#[derive(Clone)]
pub struct HostProxyConfig {
    pub socks5: bool,
    pub address: String,
    pub port: u16,
    pub authenticate: bool,
    pub credential_set: Option<bool>,
}
/// Only supplied when editing authentication. Never returned in host metadata.
pub struct ProxyAuthenticationInput {
    pub username: String,
    pub password: String,
}
impl ProxyAuthenticationInput {
    fn credential(mut self) -> hspterm_storage_sync::ssh_proxy::ProxyCredential {
        hspterm_storage_sync::ssh_proxy::ProxyCredential {
            username: std::mem::take(&mut self.username),
            password: std::mem::take(&mut self.password),
        }
    }
}
#[derive(Clone)]
pub struct HostGroupConfig {
    pub id: String,
    pub name: String,
}
impl From<hspterm_storage_sync::HostRecord> for HostConfig {
    fn from(h: hspterm_storage_sync::HostRecord) -> Self {
        Self {
            id: h.id,
            name: h.name,
            address: h.address,
            port: h.port,
            username: h.username,
            private_key: h.auth == hspterm_storage_sync::AuthMethod::PrivateKey,
            group_id: h.group_id,
            favorite: h.favorite,
            note: h.note,
            credential_set: h.credential_id.is_some(),
            timeout_seconds: h.timeout_seconds,
            keepalive_seconds: h.keepalive_seconds,
            keepalive_failures: h.keepalive_failures,
            use_network_defaults: Some(h.use_network_defaults),
            keepalive_response_seconds: h.keepalive_response_seconds,
            open_sftp: h.open_sftp,
            follow_osc7: Some(h.follow_osc7),
            jump_host_id: h.jump_host_id,
            agent_forwarding: Some(h.agent_forwarding),
            tmux_enabled: Some(h.tmux_enabled),
            shell_integration: Some(h.shell_integration),
            proxy: h.proxy.map(|p| HostProxyConfig {
                socks5: p.kind == hspterm_storage_sync::ssh_proxy::ProxyKind::Socks5,
                address: p.address,
                port: p.port,
                authenticate: p.authenticate,
                credential_set: Some(p.authenticate),
            }),
        }
    }
}
impl HostConfig {
    fn record(self) -> hspterm_storage_sync::HostRecord {
        let mut h = hspterm_storage_sync::HostRecord::new(
            self.name,
            self.address,
            self.username,
            if self.private_key {
                hspterm_storage_sync::AuthMethod::PrivateKey
            } else {
                hspterm_storage_sync::AuthMethod::Password
            },
        );
        if !self.id.is_empty() {
            h.id = self.id;
        }
        h.port = self.port;
        h.group_id = self.group_id;
        h.favorite = self.favorite;
        h.note = self.note;
        h.timeout_seconds = self.timeout_seconds;
        h.keepalive_seconds = self.keepalive_seconds;
        h.keepalive_failures = self.keepalive_failures;
        h.use_network_defaults = self.use_network_defaults.unwrap_or(false);
        h.keepalive_response_seconds = self.keepalive_response_seconds;
        h.open_sftp = self.open_sftp;
        h.follow_osc7 = self.follow_osc7.unwrap_or(false);
        h.jump_host_id = self.jump_host_id;
        h.agent_forwarding = self.agent_forwarding.unwrap_or(false);
        h.tmux_enabled = self.tmux_enabled.unwrap_or(false);
        h.shell_integration = self.shell_integration.unwrap_or(false);
        h.proxy = self
            .proxy
            .map(|p| hspterm_storage_sync::ssh_proxy::ProxySettings {
                kind: if p.socks5 {
                    hspterm_storage_sync::ssh_proxy::ProxyKind::Socks5
                } else {
                    hspterm_storage_sync::ssh_proxy::ProxyKind::HttpConnect
                },
                address: p.address,
                port: p.port,
                authenticate: p.authenticate,
            });
        h
    }
}
#[flutter_rust_bridge::frb(sync)]
pub fn new_host_id() -> String {
    hspterm_storage_sync::HostRecord::new(
        String::new(),
        String::new(),
        String::new(),
        hspterm_storage_sync::AuthMethod::Password,
    )
    .id
}

/// Idempotent upgrade from the Phase2 private test catalog. Old encrypted records
/// are removed only after every new independent host/credential pair was saved.
fn migrate_legacy_profiles(v: &mut Vault) -> Result<()> {
    let ids: Vec<String> = match v.get("profile-index")? {
        Some(raw) => serde_json::from_slice(&raw)?,
        None => return Ok(()),
    };
    for id in &ids {
        let raw = v.get(id)?.context("旧主机记录缺失")?;
        let saved: SavedProfile = serde_json::from_slice(&raw)?;
        let digest = Sha256::digest(id.as_bytes());
        let suffix: String = digest[..16].iter().map(|b| format!("{b:02x}")).collect();
        let target_id = format!("host-{suffix}");
        let mut repo = hspterm_storage_sync::Repository::new(v);
        if repo.host(&target_id)?.is_some() {
            continue;
        }
        let mut h = hspterm_storage_sync::HostRecord::new(
            saved.profile.name.clone(),
            saved.profile.address.clone(),
            saved.profile.username.clone(),
            if saved.profile.private_key {
                hspterm_storage_sync::AuthMethod::PrivateKey
            } else {
                hspterm_storage_sync::AuthMethod::Password
            },
        );
        h.id = target_id;
        h.port = saved.profile.port;
        repo.save(
            h,
            Some(hspterm_storage_sync::Credential {
                secret: saved.secret.clone(),
                passphrase: saved.passphrase.clone(),
            }),
        )?;
    }
    let mut changes: Vec<_> = ids
        .iter()
        .map(|id| hspterm_storage_sync::RecordChange::Delete(id))
        .collect();
    changes.push(hspterm_storage_sync::RecordChange::Delete("profile-index"));
    v.apply(&changes)?;
    Ok(())
}
#[derive(Clone)]
pub struct SftpBookmark {
    pub id: String,
    pub name: String,
    pub path: String,
    pub host_id: Option<String>,
}
impl From<hspterm_storage_sync::bookmarks::Bookmark> for SftpBookmark {
    fn from(value: hspterm_storage_sync::bookmarks::Bookmark) -> Self {
        Self {
            id: value.id,
            name: value.name,
            path: value.path,
            host_id: value.host_id,
        }
    }
}
pub async fn list_sftp_bookmarks(host_id: String) -> Result<Vec<SftpBookmark>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                Ok(hspterm_storage_sync::bookmarks::BookmarkRepository::new(v)
                    .list(&host_id)?
                    .into_iter()
                    .map(Into::into)
                    .collect())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_sftp_bookmark(value: SftpBookmark) -> Result<SftpBookmark> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let bookmark = hspterm_storage_sync::bookmarks::Bookmark {
                    id: value.id,
                    name: value.name,
                    path: value.path,
                    host_id: value.host_id,
                };
                Ok(hspterm_storage_sync::bookmarks::BookmarkRepository::new(v)
                    .save(bookmark)?
                    .into())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn delete_sftp_bookmark(bookmark_id: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                hspterm_storage_sync::bookmarks::BookmarkRepository::new(v).remove(&bookmark_id)?;
                Ok(())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Single-Vault, single-SQLite-read snapshot. Credential bodies never cross FFI.
pub struct HostCatalogSnapshot {
    pub vault_scope: String,
    pub hosts: Vec<HostConfig>,
    pub groups: Vec<HostGroupConfig>,
    pub drafts: Vec<HostConfig>,
}
pub async fn host_catalog_snapshot() -> Result<HostCatalogSnapshot> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                migrate_legacy_profiles(v)?;
                let metadata = hspterm_storage_sync::Repository::new(v).metadata_snapshot()?;
                Ok(HostCatalogSnapshot {
                    vault_scope: v.instance_id().to_owned(),
                    hosts: metadata.hosts.into_iter().map(Into::into).collect(),
                    groups: metadata
                        .groups
                        .into_iter()
                        .map(|group| HostGroupConfig {
                            id: group.id,
                            name: group.name,
                        })
                        .collect(),
                    drafts: metadata
                        .drafts
                        .into_iter()
                        .map(|draft| {
                            let mut host: HostConfig = draft.host.into();
                            host.credential_set |= draft.credential_set;
                            if let Some(proxy) = &mut host.proxy {
                                proxy.credential_set =
                                    Some(proxy.authenticate && draft.proxy_credential_set);
                            }
                            host
                        })
                        .collect(),
                })
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Device-local convenience list of recently opened formal host IDs. Not
/// synced, not backed up, and never proof that a host still exists.
/// Device-local last SFTP directory per formal host; pairs only, no secrets.
pub async fn load_sftp_last_dirs() -> Result<Vec<SftpLastDir>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(hspterm_storage_sync::sftp_last_dirs::load(v)?
                    .into_iter()
                    .map(|(host_id, path)| SftpLastDir { host_id, path })
                    .collect())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Remembers one host's last SFTP directory for the next connection.
pub async fn record_sftp_last_dir(host_id: String, path: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                hspterm_storage_sync::sftp_last_dirs::record(v, &host_id, &path)?;
                Ok(())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub struct SftpLastDir {
    pub host_id: String,
    pub path: String,
}

/// Device-local SFTP sort preference per formal host (column, ascending).
pub async fn load_sftp_sort_prefs() -> Result<Vec<SftpSortPref>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(hspterm_storage_sync::sftp_host_prefs::load(v)?
                    .into_iter()
                    .map(|(host_id, column, ascending)| SftpSortPref {
                        host_id,
                        column,
                        ascending,
                    })
                    .collect())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Remembers one host's listing sort for the next connection.
pub async fn record_sftp_sort_pref(host_id: String, column: u32, ascending: bool) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                hspterm_storage_sync::sftp_host_prefs::record(v, &host_id, column, ascending)?;
                Ok(())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub struct SftpSortPref {
    pub host_id: String,
    pub column: u32,
    pub ascending: bool,
}

/// One host's saved SFTP listing column layout (stable column ids).
pub struct SftpColumnPref {
    pub host_id: String,
    pub order: Vec<String>,
    pub hidden: Vec<String>,
    pub widths: Vec<(String, u32)>,
}

/// Device-local SFTP column layout per formal host (order, hidden, widths).
pub async fn load_sftp_column_prefs() -> Result<Vec<SftpColumnPref>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(hspterm_storage_sync::sftp_host_prefs::load_columns(v)?
                    .into_iter()
                    .map(|entry| SftpColumnPref {
                        host_id: entry.host,
                        order: entry.order,
                        hidden: entry.hidden,
                        widths: entry
                            .widths
                            .into_iter()
                            .map(|(id, w)| (id, u32::from(w)))
                            .collect(),
                    })
                    .collect())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Replaces one host's saved column layout.
pub async fn record_sftp_column_pref(
    host_id: String,
    order: Vec<String>,
    hidden: Vec<String>,
    widths: Vec<(String, u32)>,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            let widths_bounded: Vec<(String, u16)> = widths
                .into_iter()
                .filter_map(|(id, w)| u16::try_from(w).ok().map(|w| (id, w)))
                .collect();
            let entry = hspterm_storage_sync::sftp_host_prefs::HostColumns {
                host: host_id,
                order,
                hidden,
                widths: widths_bounded,
            };
            with_vault(|v| {
                hspterm_storage_sync::sftp_host_prefs::record_columns(v, &entry)?;
                Ok(())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn load_recent_hosts() -> Result<Vec<String>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| Ok(hspterm_storage_sync::recent_hosts::load(v)?))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Records one host open. Only formal saved hosts are recorded; the returned
/// list is the durable device-local ordering.
pub async fn record_recent_host(host_id: String) -> Result<Vec<String>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                // Never invent catalog entries from the convenience list.
                if hspterm_storage_sync::Repository::new(v)
                    .host(&host_id)?
                    .is_none()
                {
                    return Ok(hspterm_storage_sync::recent_hosts::load(v)?);
                }
                Ok(hspterm_storage_sync::recent_hosts::record(v, &host_id)?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn list_hosts() -> Result<Vec<HostConfig>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                migrate_legacy_profiles(v)?;
                Ok(hspterm_storage_sync::Repository::new(v)
                    .list()?
                    .into_iter()
                    .map(Into::into)
                    .collect())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn host_groups() -> Result<Vec<HostGroupConfig>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(hspterm_storage_sync::Repository::new(v)
                    .groups()?
                    .into_iter()
                    .map(|g| HostGroupConfig {
                        id: g.id,
                        name: g.name,
                    })
                    .collect())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_host(
    host: HostConfig,
    secret: Option<String>,
    passphrase: Option<String>,
    proxy_authentication: Option<ProxyAuthenticationInput>,
) -> Result<HostConfig> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let credential =
            secret.map(|secret| hspterm_storage_sync::Credential { secret, passphrase });
        let proxy_credential = proxy_authentication.map(ProxyAuthenticationInput::credential);
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let mut repo = hspterm_storage_sync::Repository::new(v);
                let private_key = host.private_key;
                let host = host.record();
                let credential = match credential {
                    Some(c) => Some(c),
                    None => repo
                        .drafts()?
                        .into_iter()
                        .find(|d| d.host.id == host.id && d.host.auth == host.auth)
                        .and_then(|d| d.credential),
                };
                if private_key && let Some(c) = &credential {
                    hspterm_ssh_core::validate_private_key(&c.secret, c.passphrase.as_deref())?;
                }
                let changes_secret = credential.is_some()
                    || repo
                        .host(&host.id)?
                        .is_some_and(|old| old.auth != host.auth);
                let host = repo.save_with_proxy(host, credential, proxy_credential)?;
                if changes_secret {
                    for entry in sessions().lock().values() {
                        entry
                            .agents
                            .invalidate_sources(std::slice::from_ref(&host.id))?;
                    }
                }
                Ok(host.into())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn delete_hosts(ids: Vec<String>) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                hspterm_storage_sync::Repository::new(v).delete(&ids)?;
                for entry in sessions().lock().values() {
                    entry.agents.invalidate_sources(&ids)?;
                }
                Ok(())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn copy_host_to_draft(id: String) -> Result<HostConfig> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let mut dto: HostConfig = hspterm_storage_sync::Repository::new(v)
                    .copy_to_draft(&id)?
                    .into();
                dto.credential_set = true;
                Ok(dto)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_host_draft(
    host: HostConfig,
    secret: Option<String>,
    passphrase: Option<String>,
    proxy_authentication: Option<ProxyAuthenticationInput>,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let credential =
            secret.map(|secret| hspterm_storage_sync::Credential { secret, passphrase });
        let proxy_credential = proxy_authentication.map(ProxyAuthenticationInput::credential);
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let mut repo = hspterm_storage_sync::Repository::new(v);
                let host = host.record();
                let old = if credential.is_none() {
                    repo.drafts()?
                        .into_iter()
                        .find(|d| d.host.id == host.id && d.host.auth == host.auth)
                } else {
                    None
                };
                repo.save_draft(&hspterm_storage_sync::HostDraft {
                    host,
                    proxy_credential,
                    credential: credential.or_else(|| old.and_then(|d| d.credential)),
                })?;
                Ok(())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn host_drafts() -> Result<Vec<HostConfig>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                let repo = hspterm_storage_sync::Repository::new(v);
                repo.drafts()?
                    .into_iter()
                    .map(|d| {
                        let has_proxy_secret = d.proxy_credential.is_some()
                            || (repo.host(&d.host.id)?.is_some()
                                && repo.proxy_credential(&d.host.id)?.is_some());
                        let has_secret = d.credential.is_some()
                            || repo.host(&d.host.id)?.is_some_and(|h| {
                                h.auth == d.host.auth && h.credential_id.is_some()
                            });
                        let mut dto: HostConfig = d.host.into();
                        if let Some(proxy) = &mut dto.proxy {
                            proxy.credential_set = Some(proxy.authenticate && has_proxy_secret);
                        }
                        dto.credential_set |= has_secret;
                        Ok(dto)
                    })
                    .collect()
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn discard_host_draft(id: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                hspterm_storage_sync::Repository::new(v).discard_draft(&id)?;
                Ok(())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn create_host_group(name: String) -> Result<HostGroupConfig> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let g = hspterm_storage_sync::Repository::new(v).create_group(name)?;
                Ok(HostGroupConfig {
                    id: g.id,
                    name: g.name,
                })
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn rename_host_group(id: String, name: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                hspterm_storage_sync::Repository::new(v).rename_group(&id, name)?;
                Ok(())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn delete_host_group(id: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                hspterm_storage_sync::Repository::new(v).delete_group(&id)?;
                Ok(())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn disconnect_terminal(id: u32) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        diagnostics::record(
            DiagnosticCode::DisconnectRequested,
            Some(id),
            Some(e.session.status().generation),
        );
        e.transfer_closing.store(true, Ordering::Release);
        let _forwarding_close = e.forwardings.closing(false);
        let generation = e.session.status().generation;
        let agent_revoked = e.agents.invalidate();
        let agent_operations = e.agents.wait_operations().await;
        let forwarded = e.forwardings.stop_all().await;
        let disconnected: Result<()> = async {
            let images_stopped = e.image_uploads.stop().await;
            let editors_stopped = crate::editors::stop_terminal(id).await;
            let previews_closed = crate::previews::stop_terminal(id).await;
            let directory_closed = e.directories.close_all().await;
            let searches_closed = e.file_searches.close_all().await;
            let transfers_stopped = crate::transfers::stop_terminal(id).await;
            // An unknown child CLOSE must not prevent closing its original
            // Root: Root cancellation is what allows that owner to retire.
            let root_closed = e.session.disconnect().await;
            let forwardings_retired = e.forwardings.retired(generation, &e.session).await;
            root_closed?;
            forwardings_retired?;
            transfers_stopped?;
            if !forwarded.errors.is_empty() {
                bail!("端口转发清理失败：{}", forwarded.errors.join("；"));
            }
            directory_closed?;
            searches_closed?;
            previews_closed?;
            editors_stopped?;
            images_stopped?;
            Ok(())
        }
        .await;
        e.transfer_closing.store(false, Ordering::Release);
        e.sftp.lock().await.take();
        disconnected?;
        agent_revoked?;
        agent_operations?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub use crate::editors::{EditorDocument, EditorProgress, EditorSummary, ExternalEditorFile};
pub async fn open_external_editor(
    editor_id: String,
    base_directory: String,
) -> Result<ExternalEditorFile> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::editors::open_external(editor_id, base_directory).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn capture_external_editor(
    editor_id: String,
    expected_revision: u64,
) -> Result<Option<EditorDocument>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::editors::capture_external(editor_id, expected_revision).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn release_external_editor(editor_id: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::editors::release_external(editor_id).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
pub async fn cleanup_external_editor(
    editor_id: String,
    editor_closed: bool,
) -> Result<EditorDocument> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::editors::cleanup_external(editor_id, editor_closed).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub use crate::previews::{FileOpenPreferences, FilePreview};

#[flutter_rust_bridge::frb(sync)]
pub fn reserve_editor(id: u32, generation: u64, path: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard_sync(move || {
        validate_remote_path(&path)?;
        if !path.starts_with('/') {
            bail!("编辑文件需要绝对路径");
        }
        let connection = transfer_connection(id)?;
        if connection.generation != generation {
            bail!("编辑源SSH代次已改变");
        }
        crate::editors::reserve(connection, path)
    });
    crate::public_errors::finish(outcome)
}
#[flutter_rust_bridge::frb(sync)]
pub fn reserve_saved_editor(draft_id: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard_sync(move || crate::editors::reserve_saved(draft_id));
    crate::public_errors::finish(outcome)
}
/// Explicit byte-preserving external editor mode. No full body crosses FRB.
#[flutter_rust_bridge::frb(sync)]
pub fn reserve_raw_editor(id: u32, generation: u64, path: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard_sync(move || {
        validate_remote_path(&path)?;
        if !path.starts_with('/') {
            bail!("编辑文件需要绝对路径");
        }
        let connection = transfer_connection(id)?;
        if connection.generation != generation {
            bail!("编辑源SSH代次已改变");
        }
        crate::editors::reserve_raw(connection, path)
    });
    crate::public_errors::finish(outcome)
}
#[flutter_rust_bridge::frb(sync)]
pub fn begin_editor_operation(editor_id: String) -> Result<u64> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard_sync(move || crate::editors::begin_operation(editor_id));
    crate::public_errors::finish(outcome)
}
#[flutter_rust_bridge::frb(sync)]
pub fn editor_progress(editor_id: String, operation: u64) -> Result<Option<EditorProgress>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard_sync(move || crate::editors::progress(editor_id, operation));
    crate::public_errors::finish(outcome)
}
pub async fn prepare_editor(
    editor_id: String,
    operation: u64,
    input_encoding: Option<String>,
) -> Result<EditorDocument> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::editors::prepare(editor_id, operation, input_encoding).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn bind_editor(editor_id: String, id: u32, generation: u64) -> Result<EditorSummary> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let connection = transfer_connection(id)?;
        if connection.generation != generation {
            bail!("关联SSH代次已改变");
        }
        crate::editors::bind(editor_id, connection).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn update_editor(
    editor_id: String,
    expected_revision: u64,
    text: String,
    encoding: String,
    line_ending: String,
) -> Result<EditorSummary> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::editors::update(editor_id, expected_revision, text, encoding, line_ending).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_editor(
    editor_id: String,
    operation: u64,
    expected_revision: u64,
    id: u32,
    generation: u64,
) -> Result<EditorSummary> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let connection = match transfer_connection(id) {
            Ok(connection) if connection.generation == generation => connection,
            result => {
                crate::editors::cancel(editor_id, operation).await?;
                return match result {
                    Err(error) => Err(error),
                    Ok(_) => bail!("保存所属SSH代次已改变"),
                };
            }
        };
        crate::editors::save(editor_id, operation, expected_revision, connection).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn list_editor_drafts() -> Result<Vec<EditorSummary>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::editors::list().await }).await;
    crate::public_errors::finish(outcome)
}
pub async fn cancel_editor_operation(editor_id: String, operation: u64) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::editors::cancel(editor_id, operation).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
pub async fn close_editor(editor_id: String, keep_draft: bool) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::editors::close(editor_id, keep_draft).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
pub async fn discard_editor_draft(draft_id: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::editors::discard_saved(draft_id).await })
            .await;
    crate::public_errors::finish(outcome)
}
pub async fn shutdown_editors() -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::editors::shutdown().await }).await;
    crate::public_errors::finish(outcome)
}
pub use crate::transfers::explorer::{ExportDescriptor, ExportFile, ExportTicket};
pub use crate::transfers::{TransferFailure, TransferTaskView};

pub use crate::transfers::export_cleanup::{ExportCleanupResult, ExportCleanupReview};

pub async fn prepare_explorer_cache_cleanup(
    cache_directory: String,
) -> Result<ExportCleanupReview> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let scope = with_vault(|v| Ok(v.instance_id().to_owned()))?;
        tokio::task::spawn_blocking(move || {
            crate::transfers::export_cleanup::prepare(cache_directory, scope)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn apply_explorer_cache_cleanup(ticket: String) -> Result<ExportCleanupResult> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || crate::transfers::export_cleanup::apply(ticket)).await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn release_explorer_cache_cleanup(ticket: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || crate::transfers::export_cleanup::release(ticket))
            .await?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn begin_explorer_export(
    id: u32,
    generation: u64,
    cache_directory: String,
    path: String,
    name: String,
) -> Result<ExportTicket> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let connection = transfer_connection(id)?;
        if connection.generation != generation {
            bail!("导出所属SSH代次已过期");
        }
        validate_remote_path(&path)?;
        let scope = with_vault(|v| Ok(v.instance_id().to_owned()))?;
        tokio::task::spawn_blocking(move || {
            crate::transfers::explorer::enqueue(connection, cache_directory, path, name, scope)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn attach_explorer_export(task: String) -> Result<ExportTicket> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let scope = with_vault(|v| Ok(v.instance_id().to_owned()))?;
        tokio::task::spawn_blocking(move || crate::transfers::explorer::attach_ready(task, scope))
            .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn explorer_export_inventory(
    task: String,
    lease: String,
) -> Result<Vec<ExportDescriptor>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::transfers::explorer::inventory(task, lease).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn prepare_explorer_export_file(
    task: String,
    lease: String,
    node: u32,
) -> Result<ExportFile> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::transfers::explorer::prepare(task, lease, node).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn release_explorer_export_file(task: String, lease: String, read: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            crate::transfers::explorer::release_file(task, lease, read)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn cancel_explorer_export(task: String, lease: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::transfers::explorer::cancel(task, lease).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn release_explorer_export(task: String, lease: String, delivered: bool) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            crate::transfers::explorer::release(task, lease, delivered)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn initialize_file_previews(cache_directory: String) -> Result<u32> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::previews::initialize(cache_directory).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
pub async fn file_open_preferences() -> Result<FileOpenPreferences> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(crate::previews::preferences).await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_file_open_preferences(value: FileOpenPreferences) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || crate::previews::save_preferences(value)).await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Memory-only reservation, so cancellation is valid before download starts.
#[flutter_rust_bridge::frb(sync)]
pub fn reserve_file_preview(id: u32, generation: u64, path: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard_sync(move || {
        validate_remote_path(&path)?;
        let connection = transfer_connection(id)?;
        if connection.generation != generation {
            bail!("预览所属SSH代次已过期");
        }
        crate::previews::reserve(connection, path, crate::previews::Purpose::Open)
    });
    crate::public_errors::finish(outcome)
}
/// Copy-only virtual-file snapshot. Unlike explicit file opening, this never
/// canonicalizes a final symbolic link into another download source.
#[flutter_rust_bridge::frb(sync)]
pub fn reserve_explorer_file_export(id: u32, generation: u64, path: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard_sync(move || {
        validate_remote_path(&path)?;
        let connection = transfer_connection(id)?;
        if connection.generation != generation {
            bail!("导出所属SSH代次已过期");
        }
        crate::previews::reserve(connection, path, crate::previews::Purpose::ExplorerCopy)
    });
    crate::public_errors::finish(outcome)
}
pub async fn prepare_file_preview(token: String, allow_large: bool) -> Result<FilePreview> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::previews::prepare(token, allow_large).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
#[flutter_rust_bridge::frb(sync)]
pub fn file_preview_progress(token: String) -> Result<FilePreview> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard_sync(move || crate::previews::progress(token));
    crate::public_errors::finish(outcome)
}
pub async fn cancel_file_preview(token: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::previews::cancel(token).await }).await;
    crate::public_errors::finish(outcome)
}
pub async fn shutdown_file_previews() -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::previews::shutdown().await }).await;
    crate::public_errors::finish(outcome)
}
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn transfer_agent_registry(id: u32) -> Result<Arc<crate::agents::AgentRegistry>> {
    Ok(entry(id)?.agents.clone())
}
fn transfer_connection(id: u32) -> Result<crate::transfers::Connection> {
    let e = entry(id)?;
    if e.closed.load(Ordering::Acquire) || e.transfer_closing.load(Ordering::Acquire) {
        bail!("关联终端正在关闭或断开");
    }
    let status = e.session.status();
    let (generation, target) = e
        .transfer_target
        .lock()
        .clone()
        .context("SSH目标身份尚未确认，请稍后重试")?;
    if status.phase != SessionPhase::Connected || status.generation != generation {
        bail!("关联SSH未连接或已改变");
    }
    Ok(crate::transfers::Connection {
        terminal_id: id,
        session: e.session.clone(),
        generation,
        target,
        closing: e.transfer_closing.clone(),
    })
}
pub async fn list_transfer_tasks() -> Result<Vec<TransferTaskView>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(crate::transfers::list).await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn list_remote_copies() -> Result<Vec<TransferTaskView>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(crate::remote_transfers::list).await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
#[allow(
    clippy::too_many_arguments,
    reason = "Preserve the established FRB named arguments for both endpoint identities and explicit transport policy."
)]
pub async fn enqueue_remote_copy(
    source_id: u32,
    target_id: u32,
    source: String,
    destination: String,
    allow_memory_relay: bool,
    expected_source_generation: Option<u64>,
    expected_target_generation: Option<u64>,
    allow_direct: Option<bool>,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let source_connection = transfer_connection(source_id)?;
        let target_connection = transfer_connection(target_id)?;
        if expected_source_generation.is_some_and(|g| g != source_connection.generation)
            || expected_target_generation.is_some_and(|g| g != target_connection.generation)
        {
            bail!("文件操作所绑定的SSH代次已改变，请重新选择；未创建任务");
        }
        let expected_scope = with_vault(|v| Ok(v.instance_id().to_owned()))?;
        tokio::task::spawn_blocking(move || {
            crate::remote_transfers::enqueue(
                source_connection,
                target_connection,
                source,
                destination,
                allow_memory_relay,
                expected_scope,
                allow_direct.unwrap_or(false),
            )
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// The whole batch is one task: one enqueue-time probe below, one select, one
/// channel pair and one DirectRoute shared by every entry. Per-file admission
/// no longer probes at all, so a multi-file submission no longer runs a full
/// preflight per file and cannot starve on the single probe slot.
#[allow(
    clippy::too_many_arguments,
    reason = "Preserve the established FRB named arguments for both endpoint identities and explicit transport policy."
)]
pub async fn enqueue_remote_copy_batch(
    source_id: u32,
    target_id: u32,
    entries: Vec<crate::remote_transfers::RemoteCopyBatchEntry>,
    allow_memory_relay: bool,
    expected_source_generation: Option<u64>,
    expected_target_generation: Option<u64>,
    allow_direct: Option<bool>,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let source_connection = transfer_connection(source_id)?;
        let target_connection = transfer_connection(target_id)?;
        if expected_source_generation.is_some_and(|g| g != source_connection.generation)
            || expected_target_generation.is_some_and(|g| g != target_connection.generation)
        {
            bail!("文件操作所绑定的SSH代次已改变，请重新选择；未创建任务");
        }
        let expected_scope = with_vault(|v| Ok(v.instance_id().to_owned()))?;
        let runtime = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
            runtime.block_on(crate::remote_transfers::direct::preflight(
                &source_connection,
                &target_connection,
                allow_memory_relay,
                false,
                allow_direct.unwrap_or(false),
            ))?;
            crate::remote_transfers::enqueue_copy_batch(
                source_connection,
                target_connection,
                entries,
                allow_memory_relay,
                expected_scope,
                allow_direct.unwrap_or(false),
            )
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn stop_remote_copy(task_id: String, cancel: bool) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::remote_transfers::stop(task_id, cancel).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
#[allow(
    clippy::too_many_arguments,
    reason = "Preserve the established FRB named arguments for both endpoint identities and explicit transport policy."
)]
pub async fn enqueue_remote_move(
    source_id: u32,
    target_id: u32,
    source: String,
    destination: String,
    expected_source_generation: Option<u64>,
    expected_target_generation: Option<u64>,
    allow_memory_relay: Option<bool>,
    allow_direct: Option<bool>,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let source_connection = transfer_connection(source_id)?;
        let target_connection = transfer_connection(target_id)?;
        if expected_source_generation.is_some_and(|g| g != source_connection.generation)
            || expected_target_generation.is_some_and(|g| g != target_connection.generation)
        {
            bail!("移动绑定的SSH代次已改变，未创建任务");
        }
        let expected_scope = with_vault(|v| Ok(v.instance_id().to_owned()))?;
        let runtime = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
            let source = runtime.block_on(crate::remote_transfers::prepare_move_source(
                &source_connection,
                source,
            ))?;
            crate::remote_transfers::enqueue_move(
                source_connection,
                target_connection,
                source,
                destination,
                allow_memory_relay.unwrap_or(false),
                expected_scope,
                allow_direct.unwrap_or(false),
            )
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
#[allow(
    clippy::too_many_arguments,
    reason = "Both original endpoint generations and per-endpoint conflict choices are required at this FRB boundary."
)]
pub async fn resume_remote_copy(
    source_id: u32,
    target_id: u32,
    task_id: String,
    node: Option<u32>,
    decision: String,
    rename: Option<String>,
    source_generation: Option<u64>,
    target_generation: Option<u64>,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let source = transfer_connection(source_id)?;
        let target = transfer_connection(target_id)?;
        ensure!(
            source_generation.is_none_or(|generation| generation == source.generation)
                && target_generation.is_none_or(|generation| generation == target.generation),
            "所选传输连接已改变，请重新选择原任务会话"
        );
        tokio::task::spawn_blocking(move || {
            crate::remote_transfers::resume(source, target, task_id, node, decision, rename)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Device-only staging references. This never queries a remote server.
pub async fn remote_staging_tasks(offset: u32, limit: u32) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            crate::remote_transfers::staging_cleanup::tasks(offset, limit)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn remote_staging_inventory(task_id: String, offset: u32, limit: u32) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            crate::remote_transfers::staging_cleanup::inventory(task_id, offset, limit)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn prepare_remote_staging_cleanup(
    target_id: u32,
    task_id: String,
    index: u32,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let target = transfer_connection(target_id)?;
        let runtime = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
            runtime.block_on(crate::remote_transfers::staging_cleanup::prepare(
                target, task_id, index,
            ))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn apply_remote_staging_cleanup(
    target_id: u32,
    task_id: String,
    ticket: String,
    allow_uncertain: bool,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let target = transfer_connection(target_id)?;
        crate::remote_transfers::staging_cleanup::apply(target, task_id, ticket, allow_uncertain)
            .await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn prepare_remote_staging_end(task_id: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            crate::remote_transfers::staging_cleanup::prepare_end(task_id)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn end_remote_staging_wait(task_id: String, ticket: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            crate::remote_transfers::staging_cleanup::end_local(task_id, ticket)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn prepare_source_retirement_end(
    task_id: String,
) -> Result<crate::remote_transfers::RemoteMoveEndReview> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            crate::remote_transfers::source_resolution::prepare(task_id)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn end_source_retirement_wait(task_id: String, ticket: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            crate::remote_transfers::source_resolution::end(task_id, ticket)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn inspect_source_retirement(
    source_id: u32,
    target_id: u32,
    task_id: String,
) -> Result<crate::remote_transfers::RemoteMoveInspection> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let source = transfer_connection(source_id)?;
        let target = transfer_connection(target_id)?;
        let runtime = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
            runtime.block_on(crate::remote_transfers::source_resolution::inspect(
                source, target, task_id,
            ))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Metadata only; the one-use ticket is bound to both live generations.
pub async fn inspect_remote_move(
    source_id: u32,
    target_id: u32,
    task_id: String,
) -> Result<crate::remote_transfers::RemoteMoveInspection> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let source = transfer_connection(source_id)?;
        let target = transfer_connection(target_id)?;
        let runtime = tokio::runtime::Handle::current();
        tokio::task::spawn_blocking(move || {
            runtime.block_on(crate::remote_transfers::inspect_move(
                source, target, task_id,
            ))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Explicitly end local waiting, without asserting success, renaming or deleting
/// either path. It cannot revoke an already sent server request. The encrypted
/// audit is retained; stale inspection cannot apply.
pub async fn acknowledge_remote_move(
    source_id: u32,
    target_id: u32,
    task_id: String,
    ticket: String,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let source = transfer_connection(source_id)?;
        let target = transfer_connection(target_id)?;
        tokio::task::spawn_blocking(move || {
            crate::remote_transfers::acknowledge_move(source, target, task_id, ticket)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Review original local task metadata only. This never opens SSH/SFTP or reads
/// current files, and the returned capability cannot authorize a network action.
pub async fn prepare_remote_move_end(
    task_id: String,
) -> Result<crate::remote_transfers::RemoteMoveEndReview> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || crate::remote_transfers::prepare_move_end(task_id))
            .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// End only local waiting for an already stopped, unconfirmed move. An original
/// request may still execute; its encrypted audit is retained. No server or host
/// configuration is needed, created, rebound or contacted.
pub async fn end_remote_move_wait(task_id: String, ticket: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || crate::remote_transfers::end_move_wait(task_id, ticket))
            .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn remote_copy_failures(
    task_id: String,
    offset: u32,
    limit: u32,
) -> Result<Vec<TransferFailure>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            crate::remote_transfers::failures(&task_id, offset as usize, limit as usize)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn clear_ended_remote_copies() -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(crate::remote_transfers::clear_ended).await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn enqueue_transfer(
    id: u32,
    local: String,
    remote: String,
    upload: bool,
    expected_generation: Option<u64>,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let result: Result<String> = async {
            let connection = transfer_connection(id)?;
            ensure!(
                expected_generation.is_none_or(|expected| expected == connection.generation),
                "原传输SSH会话代次已变化，请重新选择文件"
            );
            tokio::task::spawn_blocking(move || {
                crate::transfers::enqueue(connection, local, remote, upload)
            })
            .await?
        }
        .await;
        diagnostics::record(
            if result.is_err() {
                DiagnosticCode::TransferRequestRejected
            } else if upload {
                DiagnosticCode::UploadQueued
            } else {
                DiagnosticCode::DownloadQueued
            },
            Some(id),
            None,
        );
        result
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn stop_transfer(task_id: String, cancel: bool) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::transfers::stop(task_id, cancel).await })
            .await;
    crate::public_errors::finish(outcome)
}
pub async fn resume_transfer(
    id: u32,
    task_id: String,
    node: Option<u32>,
    decision: String,
    rename: Option<String>,
    generation: Option<u64>,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let connection = transfer_connection(id)?;
        ensure!(
            generation.is_none_or(|generation| generation == connection.generation),
            "所选传输连接已改变，请重新选择原任务会话"
        );
        tokio::task::spawn_blocking(move || {
            crate::transfers::resume(connection, task_id, node, decision, rename)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn transfer_failures(
    task_id: String,
    offset: u32,
    limit: u32,
) -> Result<Vec<TransferFailure>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || crate::transfers::failures(task_id, offset, limit))
            .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn clear_ended_transfers() -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::transfers::clear_ended();
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
#[derive(Clone)]
pub struct RemoteFile {
    pub name: String,
    pub path: String,
    pub directory: bool,
    pub symlink: bool,
    pub size: Option<u64>,
    pub modified: Option<u32>,
    pub permissions: Option<u32>,
    /// Listing owner/group names (or numeric ids as text) when the server
    /// reports them; round-9 SFTP columns. No extra network requests.
    pub owner: Option<String>,
    pub group: Option<String>,
}
pub struct RemoteDirectory {
    pub path: String,
    pub files: Vec<RemoteFile>,
}
fn validate_remote_path(path: &str) -> Result<()> {
    if path.is_empty() || path.len() > 131072 || path.contains('\0') {
        bail!("远端路径无效");
    }
    Ok(())
}
async fn remote_sftp(
    id: u32,
    expected_generation: Option<u64>,
) -> Result<Arc<hspterm_ssh_core::SftpSession>> {
    let e = entry(id)?;
    // Capture before the first await. A request waiting behind an old metadata
    // OPEN must not silently attach to a newly reconnected transport.
    let generation = e.session.status().generation;
    ensure!(
        expected_generation.is_none_or(|expected| expected == generation),
        "原SFTP操作绑定的SSH代次已改变，未执行"
    );
    let check = || -> Result<()> {
        let status = e.session.status();
        if e.closed.load(Ordering::Acquire)
            || e.transfer_closing.load(Ordering::Acquire)
            || status.phase != SessionPhase::Connected
            || status.generation != generation
        {
            bail!("原SFTP元数据请求的SSH会话已改变或正在关闭");
        }
        Ok(())
    };
    check()?;
    let mut cache = e.sftp.lock().await;
    check()?;
    if let Some((cached_generation, sftp)) = cache.as_ref()
        && *cached_generation == generation
        && !sftp.local_io_closed()
    {
        return Ok(sftp.clone());
    }
    if let Some((_, sftp)) = cache.as_ref() {
        // Never discard the sole cached owner before its actual local IO ends.
        // Failure retains it for an explicit retry or the original Root close.
        sftp.close().await.context("旧SFTP元数据子通道收尾未确认")?;
    }
    cache.take();
    check()?;
    let sftp = Arc::new(
        e.session
            .open_sftp_with_retry(generation, &tokio_util::sync::CancellationToken::new())
            .await?,
    );
    *cache = Some((generation, sftp.clone()));
    if let Err(error) = check() {
        // Publish ownership before a fallible close, including generation change
        // during negotiation. No caller receives a channel of a different Root.
        sftp.close()
            .await
            .context("迟到的SFTP元数据子通道收尾未确认")?;
        cache.take();
        return Err(error);
    }
    Ok(sftp)
}
pub async fn sftp_list_directory(id: u32, path: String) -> Result<RemoteDirectory> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&path)?;
        let remote = remote_sftp(id, None).await?;
        let path = remote.canonicalize(path).await?;
        let entries = remote.read_dir(path.clone()).await?;
        let mut files = Vec::new();
        for f in entries {
            let name = f.file_name();
            if name.contains('/') || name.contains('\0') {
                bail!("服务器返回无效文件名");
            }
            let a = f.metadata();
            files.push(RemoteFile {
                name,
                path: f.path(),
                directory: a.is_dir(),
                symlink: a.is_symlink(),
                size: a.size,
                modified: a.mtime,
                permissions: a.permissions,
                owner: a.user.clone().or_else(|| a.uid.map(|id| id.to_string())),
                group: a.group.clone().or_else(|| a.gid.map(|id| id.to_string())),
            });
        }
        Ok(RemoteDirectory { path, files })
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub struct RemoteDirectoryPage {
    pub files: Vec<RemoteFile>,
    pub done: bool,
}
fn check_directory_session(e: &Entry, generation: u64) -> Result<()> {
    let status = e.session.status();
    if e.closed.load(Ordering::Acquire)
        || e.transfer_closing.load(Ordering::Acquire)
        || status.phase != SessionPhase::Connected
        || status.generation != generation
    {
        bail!("关联SSH会话已改变或断开");
    }
    Ok(())
}
pub async fn sftp_open_directory(
    id: u32,
    generation: u64,
    request: u64,
    path: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&path)?;
        let e = entry(id)?;
        check_directory_session(&e, generation)?;
        e.directories
            .open(
                e.session.clone(),
                e.transfer_closing.clone(),
                generation,
                request,
                path,
            )
            .await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn sftp_directory_page(
    id: u32,
    generation: u64,
    request: u64,
    limit: u32,
) -> Result<RemoteDirectoryPage> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        check_directory_session(&e, generation)?;
        let page = e
            .directories
            .page(generation, request, limit as usize)
            .await?;
        check_directory_session(&e, generation)?;
        Ok(RemoteDirectoryPage {
            done: page.done,
            files: page
                .entries
                .into_iter()
                .map(|f| RemoteFile {
                    name: f.name,
                    path: f.path,
                    directory: f.directory,
                    symlink: f.symlink,
                    size: f.size,
                    modified: f.modified,
                    permissions: f.permissions,
                    owner: f.owner,
                    group: f.group,
                })
                .collect(),
        })
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn sftp_close_directory(id: u32, generation: u64, request: u64) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = sessions().lock().get(&id).cloned();
        if let Some(e) = e {
            e.directories.close(generation, request).await?;
        }
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub struct RemoteFileSearchPage {
    pub files: Vec<RemoteFile>,
    pub scanned: u64,
    pub directories: u64,
    pub done: bool,
}
/// An independent cursor: searching cannot close the sidebar's directory read.
pub async fn sftp_open_file_search(
    id: u32,
    generation: u64,
    request: u64,
    path: String,
    query: String,
    case_sensitive: bool,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&path)?;
        let e = entry(id)?;
        check_directory_session(&e, generation)?;
        e.file_searches
            .open_search(
                e.session.clone(),
                e.transfer_closing.clone(),
                generation,
                request,
                path,
                query,
                case_sensitive,
            )
            .await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn sftp_file_search_page(
    id: u32,
    generation: u64,
    request: u64,
    limit: u32,
) -> Result<RemoteFileSearchPage> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        check_directory_session(&e, generation)?;
        let page = e
            .file_searches
            .search_page(generation, request, limit as usize)
            .await?;
        check_directory_session(&e, generation)?;
        Ok(RemoteFileSearchPage {
            files: page
                .matches
                .into_iter()
                .map(|f| RemoteFile {
                    name: f.name,
                    path: f.path,
                    directory: f.directory,
                    symlink: f.symlink,
                    size: f.size,
                    modified: f.modified,
                    permissions: f.permissions,
                    owner: f.owner,
                    group: f.group,
                })
                .collect(),
            scanned: page.scanned,
            directories: page.directories,
            done: page.done,
        })
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn sftp_close_file_search(id: u32, generation: u64, request: u64) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = sessions().lock().get(&id).cloned();
        if let Some(e) = e {
            e.file_searches.close(generation, request).await?;
        }
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Explicit user image paste: stream a local PNG through a dedicated channel
/// into a private remote temporary directory. Never sends terminal input.
pub async fn paste_clipboard_image_path(id: u32, generation: u64, path: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        ensure!(
            path.starts_with('/') && path.len() <= 4096 && !path.chars().any(char::is_control),
            "图片路径无效，未输入"
        );
        let text = format!("'{}'", path.replace('\'', "'\\''"));
        ensure!(
            matches!(
                entry(id)?
                    .session
                    .input_generation(
                        generation,
                        TerminalInput::Paste {
                            text,
                            confirmed: false
                        }
                    )
                    .await?,
                InputOutcome::Sent { .. }
            ),
            "图片路径粘贴未确认，未自动重试"
        );
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn load_resource_bar_preference(scope: String, host: String) -> Result<bool> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                Ok(hspterm_storage_sync::resource_bar_preferences::load(
                    v, &scope, &host,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_resource_bar_preference(
    scope: String,
    host: String,
    enabled: bool,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                Ok(hspterm_storage_sync::resource_bar_preferences::save(
                    v, &scope, &host, enabled,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Small generation-bound ACK snapshot; contains no clipboard pixels or text.
pub async fn clipboard_image_progress(
    id: u32,
    generation: u64,
    local_path: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        if e.session.status().generation != generation {
            bail!("原图片粘贴会话已改变");
        }
        Ok(e.image_uploads
            .progress(generation, std::path::Path::new(&local_path)))
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Requests cancellation of only the matching image operation. The upload
/// future still owns ACK draining and channel cleanup; false means not started.
pub async fn cancel_clipboard_image(id: u32, generation: u64, local_path: String) -> Result<bool> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        Ok(entry(id)?
            .image_uploads
            .cancel(generation, std::path::Path::new(&local_path)))
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn upload_clipboard_image(
    id: u32,
    generation: u64,
    local_path: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        e.image_uploads
            .upload(
                &e.session,
                generation,
                &e.transfer_closing,
                std::path::Path::new(&local_path),
            )
            .await
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn sftp_create_directory(
    id: u32,
    path: String,
    expected_generation: Option<u64>,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&path)?;
        remote_sftp(id, expected_generation)
            .await?
            .create_dir(path)
            .await?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Resolve only an explicitly opened entry. Listing never probes link targets.
pub async fn sftp_resolve_entry(id: u32, generation: u64, path: String) -> Result<RemoteFile> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&path)?;
        let e = entry(id)?;
        let check = || -> Result<()> {
            let status = e.session.status();
            if e.closed.load(Ordering::Acquire)
                || e.transfer_closing.load(Ordering::Acquire)
                || status.phase != SessionPhase::Connected
                || status.generation != generation
            {
                bail!("关联SSH会话已改变或断开");
            }
            Ok(())
        };
        check()?;
        let remote = remote_sftp(id, Some(generation)).await?;
        check()?;
        let canonical = remote
            .canonicalize(path.clone())
            .await
            .context("无法解析远端链接目标")?;
        validate_remote_path(&canonical)?;
        let attributes = remote
            .symlink_metadata(canonical.clone())
            .await
            .context("无法读取远端链接属性")?;
        check()?;
        Ok(RemoteFile {
            name: path.rsplit('/').next().unwrap_or("").to_owned(),
            path: canonical,
            directory: attributes.is_dir(),
            symlink: attributes.is_symlink(),
            size: attributes.size,
            modified: attributes.mtime,
            permissions: attributes.permissions,
            owner: attributes
                .user
                .clone()
                .or_else(|| attributes.uid.map(|id| id.to_string())),
            group: attributes
                .group
                .clone()
                .or_else(|| attributes.gid.map(|id| id.to_string())),
        })
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Explicit terminal-selection navigation. Only the parent is canonicalized:
/// selecting a file symlink must select that link, not a different target entry.
pub async fn sftp_locate_terminal_path(
    id: u32,
    generation: u64,
    text: String,
) -> Result<RemoteFile> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let path = resolve_terminal_path(id, generation, text).await?;
        let e = entry(id)?;
        let check = || -> Result<()> {
            let state = e.session.status();
            if e.closed.load(Ordering::Acquire)
                || e.transfer_closing.load(Ordering::Acquire)
                || state.phase != SessionPhase::Connected
                || state.generation != generation
            {
                bail!("原SSH会话已改变或断开；未定位到其他会话");
            }
            Ok(())
        };
        check()?;
        let remote = remote_sftp(id, Some(generation)).await?;
        check()?;
        let (parent, name) = path.rsplit_once('/').context("需要绝对远端路径")?;
        let parent = remote
            .canonicalize(if parent.is_empty() { "/" } else { parent })
            .await
            .context("无法读取所选路径的远端父目录")?;
        validate_remote_path(&parent)?;
        let candidate = format!("{}/{}", parent.trim_end_matches('/'), name);
        let attributes = remote
            .symlink_metadata(candidate.clone())
            .await
            .context("无法读取所选远端路径的属性")?;
        let path = if attributes.is_dir() {
            remote.canonicalize(candidate).await?
        } else {
            candidate
        };
        validate_remote_path(&path)?;
        check()?;
        Ok(RemoteFile {
            name: path.rsplit('/').next().unwrap_or("").to_owned(),
            path,
            directory: attributes.is_dir(),
            symlink: attributes.is_symlink(),
            size: attributes.size,
            modified: attributes.mtime,
            permissions: attributes.permissions,
            owner: attributes
                .user
                .clone()
                .or_else(|| attributes.uid.map(|id| id.to_string())),
            group: attributes
                .group
                .clone()
                .or_else(|| attributes.gid.map(|id| id.to_string())),
        })
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn sftp_rename(
    id: u32,
    source: String,
    destination: String,
    expected_generation: Option<u64>,
    overwrite: Option<bool>,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&source)?;
        validate_remote_path(&destination)?;
        let remote = remote_sftp(id, expected_generation).await?;
        if overwrite == Some(true) {
            // Edit-save semantics: replace the destination. POSIX-rename is
            // atomic when the server advertises the extension (OpenSSH
            // does); otherwise an explicitly confirmed fallback removes the
            // existing file first, so the caller must have user consent.
            if remote.supports_posix_rename() {
                match remote.posix_rename(source, destination).await {
                    Ok(true) => return Ok(()),
                    // Advertised but refused: surface instead of silently
                    // falling into the destructive remove+rename path.
                    Ok(false) => bail!("服务器未实际支持POSIX覆盖重命名"),
                    Err(error) => return Err(error.into()),
                }
            }
            if remote.try_exists(destination.clone()).await? {
                remote.remove_file(destination.clone()).await?;
            }
            remote.rename(source, destination).await?;
            return Ok(());
        }
        if remote.try_exists(destination.clone()).await? {
            bail!("目标路径已存在，请先处理同名冲突");
        }
        remote.rename(source, destination).await?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Edit-save replace, phase 1 (round-11): prefer the atomic POSIX rename.
/// Returns "Applied" when the server supports posix-rename@openssh.com and
/// the temp file replaced the original in one step, or "NeedsConfirmation"
/// when only the destructive path is possible — the caller must collect the
/// user's explicit consent before phase 2. The original's permissions are
/// captured and reapplied so the replaced entry keeps its mode.
pub async fn sftp_edit_replace(
    id: u32,
    generation: u64,
    temp: String,
    original: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&temp)?;
        validate_remote_path(&original)?;
        let remote = remote_sftp(id, Some(generation)).await?;
        if !remote.supports_posix_rename() {
            return Ok("NeedsConfirmation".to_owned());
        }
        let attrs = remote.symlink_metadata(original.clone()).await?;
        let permissions = attrs.permissions;
        match remote.posix_rename(temp, original.clone()).await {
            Ok(true) => {}
            // Advertised but refused: never fall into the destructive path
            // without consent either.
            Ok(false) => bail!("服务器未实际支持POSIX覆盖重命名"),
            Err(error) => return Err(error.into()),
        }
        if let Some(mode) = permissions {
            remote
                .set_metadata(
                    original,
                    russh_sftp::protocol::FileAttributes {
                        permissions: Some(mode),
                        ..Default::default()
                    },
                )
                .await?;
        }
        Ok("Applied".to_owned())
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Edit-save replace, phase 2 (round-11): the explicitly confirmed
/// destructive path for servers without POSIX-rename. The original is moved
/// aside to a backup first; any failure rolls it back, so the remote never
/// loses data mid-save. Permissions (and owner/group when the server
/// accepts them) carry over to the replacement.
pub async fn sftp_edit_replace_confirmed(
    id: u32,
    generation: u64,
    temp: String,
    original: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&temp)?;
        validate_remote_path(&original)?;
        let remote = remote_sftp(id, Some(generation)).await?;
        let attrs = remote.symlink_metadata(original.clone()).await?;
        let slash = original.rfind('/').unwrap_or(0);
        let parent = if slash == 0 {
            "/".to_owned()
        } else {
            original[..slash].to_owned()
        };
        let backup = format!(
            "{}/.hspterm-backup-{}",
            parent,
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_micros())
                .unwrap_or(0)
        );
        remote.rename(original.clone(), backup.clone()).await?;
        if let Err(error) = remote.rename(temp, original.clone()).await {
            // Roll the original back before surfacing the failure.
            let _ = remote.rename(backup, original).await;
            return Err(error.into());
        }
        // Restore mode; uid/gid only when the server honors them for this
        // login (permission errors here are non-fatal — the content save
        // already succeeded).
        let mut restored = russh_sftp::protocol::FileAttributes {
            permissions: attrs.permissions,
            ..Default::default()
        };
        if restored.permissions.is_none() {
            restored.permissions = Some(0o644);
        }
        if let Err(mode_error) = remote.set_metadata(original.clone(), restored).await {
            crate::public_errors::log_loss(format!("替换后恢复权限失败：{mode_error}"));
        }
        if (attrs.uid.is_some() || attrs.gid.is_some())
            && remote
                .set_metadata(
                    original.clone(),
                    russh_sftp::protocol::FileAttributes {
                        uid: attrs.uid,
                        gid: attrs.gid,
                        ..Default::default()
                    },
                )
                .await
                .is_err()
        {
            crate::public_errors::log_loss("替换后恢复所有者/组未获服务器接受".into());
        }
        if let Err(remove_error) = remote.remove_file(backup).await {
            crate::public_errors::log_loss(format!("清理备份失败：{remove_error}"));
        }
        Ok("Applied".to_owned())
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// One path the server refused to delete, with its restricted reason code and
/// fixed public phrase. Raw server payloads never cross FFI.
#[derive(Clone)]
pub struct SftpRemoveFailure {
    pub path: String,
    pub reason_code: String,
    pub reason_text: String,
}
/// One batched delete result: every entry actually removed (including tree
/// children and already-absent paths) and every refusal, so a partial
/// completion is explicit data instead of an all-or-nothing error.
#[derive(Clone)]
pub struct SftpRemoveBatchOutcome {
    pub succeeded: Vec<String>,
    pub failed: Vec<SftpRemoveFailure>,
}

pub async fn sftp_remove(
    id: u32,
    path: String,
    recursive: bool,
    expected_generation: Option<u64>,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&path)?;
        if ["/", ".", ".."].contains(&path.as_str()) {
            bail!("不能删除根目录或当前目录入口");
        }
        let remote = remote_sftp(id, expected_generation).await?;
        let root = path.trim_end_matches('/').to_owned();
        if root.is_empty() {
            bail!("不能删除根目录");
        }
        let mut outcome = crate::remove_tree::RemoveOutcome::default();
        let mut budget = crate::remove_tree::REMOVE_MAX_ENTRIES;
        if crate::remove_tree::remove_lossy(&root) {
            // A lossy U+FFFD path can never address the original bytes;
            // classify it without a doomed request.
            outcome.failed.push(crate::remove_tree::RemoveFailure::new(
                root.clone(),
                crate::remove_tree::RemoveFailureCode::NameInvalid,
            ));
        } else {
            crate::remove_tree::remove_remote_tree(
                &remote,
                root.clone(),
                recursive,
                &mut budget,
                &mut outcome,
            )
            .await?;
        }
        // The first recorded row is the root cause: children run (and fail)
        // before their parent's RMDIR, so a busy or permission-denied child
        // surfaces instead of the non-empty symptom on the parent.
        if let Some(failure) = outcome.failed.first() {
            bail!(failure.text);
        }
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// One batched multi-select delete: admission validates every path before any
/// deletion, then per-entry errors accumulate instead of aborting siblings.
pub async fn sftp_remove_batch(
    id: u32,
    paths: Vec<String>,
    expected_generation: Option<u64>,
) -> Result<SftpRemoveBatchOutcome> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        if paths.len() > crate::remove_tree::REMOVE_MAX_ROOTS {
            bail!("删除清单超过安全容量");
        }
        let mut roots = Vec::with_capacity(paths.len());
        for path in paths {
            validate_remote_path(&path)?;
            let root = path.trim_end_matches('/').to_owned();
            ensure!(
                !root.is_empty() && ![".", ".."].contains(&root.as_str()),
                "不能删除根目录或当前目录入口"
            );
            roots.push(root);
        }
        let remote = remote_sftp(id, expected_generation).await?;
        crate::remove_tree::remove_remote_paths(&remote, roots, true).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Bounded primitive used by previews and the streaming transfer engine.
pub async fn sftp_read_chunk(id: u32, path: String, offset: u64, length: u32) -> Result<Vec<u8>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
        validate_remote_path(&path)?;
        if length == 0 || length > 1024 * 1024 {
            bail!("文件块大小无效");
        }
        let remote = remote_sftp(id, None).await?;
        let mut file = remote.open(path).await?;
        file.seek(std::io::SeekFrom::Start(offset)).await?;
        let mut data = vec![0; length as usize];
        let read = file.read(&mut data).await?;
        data.truncate(read);
        file.shutdown().await?;
        Ok(data)
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn sftp_write_chunk(
    id: u32,
    path: String,
    offset: u64,
    data: Vec<u8>,
    truncate: bool,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        use tokio::io::{AsyncSeekExt, AsyncWriteExt};
        validate_remote_path(&path)?;
        if data.len() > 1024 * 1024 || (truncate && offset != 0) {
            bail!("文件块参数无效");
        }
        let remote = remote_sftp(id, None).await?;
        let mut flags =
            hspterm_ssh_core::SftpOpenFlags::WRITE | hspterm_ssh_core::SftpOpenFlags::CREATE;
        if truncate {
            flags |= hspterm_ssh_core::SftpOpenFlags::TRUNCATE;
        }
        let mut file = remote.open_with_flags(path, flags).await?;
        file.seek(std::io::SeekFrom::Start(offset)).await?;
        file.write_all(&data).await?;
        file.flush().await?;
        file.shutdown().await?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn batch_hosts_metadata(
    ids: Vec<String>,
    group_id: Option<String>,
    favorite: Option<bool>,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                hspterm_storage_sync::Repository::new(v)
                    .batch_metadata(&ids, group_id, favorite)?;
                Ok(())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Non-secret result only. Private key material never crosses the bridge on export/generation.
pub struct HostKeyInfo {
    pub public_key: String,
    pub fingerprint: String,
    pub algorithm: String,
}
impl From<hspterm_ssh_core::identity::PublicIdentity> for HostKeyInfo {
    fn from(identity: hspterm_ssh_core::identity::PublicIdentity) -> Self {
        Self {
            public_key: identity.public,
            fingerprint: identity.fingerprint,
            algorithm: identity.algorithm,
        }
    }
}
fn key_credential(v: &mut Vault, id: &str) -> Result<hspterm_storage_sync::Credential> {
    use hspterm_storage_sync::{AuthMethod, Repository};
    let repo = Repository::new(v);
    if let Some(draft) = repo.drafts()?.into_iter().find(|d| d.host.id == id) {
        if draft.host.auth != AuthMethod::PrivateKey {
            bail!("当前草稿不是私钥认证");
        }
        if let Some(credential) = draft.credential {
            return Ok(credential);
        }
    }
    let host = repo.host(id)?.context("请先生成或导入私钥")?;
    if host.auth != AuthMethod::PrivateKey {
        bail!("当前主机不是私钥认证");
    }
    repo.credential(id)?.context("请先生成或导入私钥")
}
pub async fn generate_host_key(
    host: HostConfig,
    passphrase: Option<String>,
) -> Result<HostKeyInfo> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let passphrase = passphrase.map(Zeroizing::new);
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                if !host.private_key {
                    bail!("请先选择私钥认证");
                }
                let mut key = hspterm_ssh_core::identity::generate_ed25519(
                    passphrase.as_ref().map(|s| s.as_str()),
                )?;
                let credential = hspterm_storage_sync::Credential {
                    secret: std::mem::take(&mut *key.private),
                    passphrase: passphrase.as_ref().map(|s| s.to_string()),
                };
                hspterm_storage_sync::Repository::new(v).save_draft(
                    &hspterm_storage_sync::HostDraft {
                        host: host.record(),
                        credential: Some(credential),
                        proxy_credential: None,
                    },
                )?;
                Ok(HostKeyInfo {
                    public_key: key.public,
                    fingerprint: key.fingerprint,
                    algorithm: key.algorithm,
                })
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn import_host_key(
    host: HostConfig,
    path: String,
    passphrase: Option<String>,
) -> Result<HostKeyInfo> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let passphrase = passphrase.map(Zeroizing::new);
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                use std::io::Read;
                if !host.private_key {
                    bail!("请先选择私钥认证");
                }
                if !std::fs::metadata(&path)
                    .context("无法读取所选私钥文件")?
                    .is_file()
                {
                    bail!("所选对象不是普通私钥文件");
                }
                let file = std::fs::File::open(path).context("无法打开所选私钥文件")?;
                if !file.metadata()?.is_file() {
                    bail!("所选对象不是普通私钥文件");
                }
                let mut raw = Zeroizing::new(Vec::new());
                file.take(2 * 1024 * 1024 + 1).read_to_end(&mut raw)?;
                if raw.len() > 2 * 1024 * 1024 {
                    bail!("私钥文件超过大小上限");
                }
                let mut credential = hspterm_storage_sync::Credential {
                    secret: String::new(),
                    passphrase: passphrase.as_ref().map(|s| s.to_string()),
                };
                credential.secret = std::str::from_utf8(&raw)
                    .context("私钥文件编码无效")?
                    .to_owned();
                let identity = hspterm_ssh_core::identity::public_identity(
                    &credential.secret,
                    credential.passphrase.as_deref(),
                )?;
                hspterm_storage_sync::Repository::new(v).save_draft(
                    &hspterm_storage_sync::HostDraft {
                        host: host.record(),
                        credential: Some(credential),
                        proxy_credential: None,
                    },
                )?;
                Ok(identity.into())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn host_public_key(id: String) -> Result<HostKeyInfo> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let key = key_credential(v, &id)?;
                Ok(hspterm_ssh_core::identity::public_identity(
                    &key.secret,
                    key.passphrase.as_deref(),
                )?
                .into())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn export_host_private_key(
    id: String,
    path: String,
    master_password: String,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let password = Zeroizing::new(master_password);
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                v.verify_password(password.as_bytes())?;
                let key = key_credential(v, &id)?;
                hspterm_ssh_core::identity::public_identity(
                    &key.secret,
                    key.passphrase.as_deref(),
                )?;
                persist_key_file(&path, key.secret.as_bytes())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

fn persist_key_file(path: &str, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let destination = std::path::Path::new(path);
    if !destination.is_absolute() {
        bail!("请选择明确的密钥保存位置");
    }
    let parent = destination.parent().context("保存位置无效")?;
    let mut temporary = tempfile::Builder::new()
        .prefix(".hspterm-key-export-")
        .tempfile_in(parent)?;
    temporary.write_all(bytes)?;
    temporary.as_file().sync_all()?;
    temporary
        .persist_noclobber(destination)
        .map_err(|e| e.error)
        .context("无法保存密钥；不会覆盖已有文件")?;
    #[cfg(unix)]
    std::fs::File::open(parent)?.sync_all()?;
    Ok(())
}

pub async fn export_host_public_key(id: String, path: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let key = key_credential(v, &id)?;
                let public = hspterm_ssh_core::identity::public_identity(
                    &key.secret,
                    key.passphrase.as_deref(),
                )?;
                persist_key_file(&path, format!("{}\n", public.public).as_bytes())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Encrypted user preferences; no transfer task or file content is returned.
pub async fn transfer_preferences() -> Result<crate::transfers::TransferPreferences> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(crate::transfers::preferences).await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_transfer_preferences(value: crate::transfers::TransferPreferences) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || crate::transfers::save_preferences(value)).await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Read saved forwarding configuration; never starts a listener or SSH.
pub async fn forwarding_rules(host_id: String) -> Result<Vec<crate::forwardings::RuleConfig>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::forwardings::load(host_id).await }).await;
    crate::public_errors::finish(outcome)
}
pub async fn ssh_network_defaults() -> Result<crate::network_settings::SshNetworkDefaults> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::network_settings::load().await }).await;
    crate::public_errors::finish(outcome)
}
pub async fn save_ssh_network_defaults(
    value: crate::network_settings::SshNetworkDefaults,
) -> Result<crate::network_settings::SshNetworkDefaults> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::network_settings::save(value).await })
            .await;
    crate::public_errors::finish(outcome)
}
/// Explicit encrypted configuration save; runtime changes are separate actions.
pub async fn save_forwarding_rules(
    host_id: String,
    rules: Vec<crate::forwardings::RuleConfig>,
) -> Result<Vec<crate::forwardings::RuleConfig>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::forwardings::save(host_id, rules).await })
            .await;
    crate::public_errors::finish(outcome)
}
/// Device-local incomplete editor text. Does not change formal rules or listen.
pub async fn forwarding_rule_draft(host_id: String) -> Result<crate::forwardings::RuleDraft> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::forwardings::draft(host_id).await }).await;
    crate::public_errors::finish(outcome)
}
/// fields=None explicitly retires a draft with a revisioned tombstone.
pub async fn save_forwarding_rule_draft(
    host_id: String,
    expected_revision: u64,
    fields: Option<crate::forwardings::DraftFields>,
) -> Result<crate::forwardings::RuleDraft> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::forwardings::save_draft(host_id, expected_revision, fields).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Explicit formal Save, using the exact persisted draft revision atomically.
pub async fn commit_forwarding_rule_draft(
    host_id: String,
    expected_revision: u64,
) -> Result<Vec<crate::forwardings::RuleConfig>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::forwardings::commit_draft(host_id, expected_revision).await
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Explicitly starts one saved rule on the original connected terminal.
/// Configuration edits do not change this captured runtime or rebuild SSH.
pub async fn start_forwarding(
    id: u32,
    generation: u64,
    rule_id: String,
) -> Result<crate::forwardings::runtime::RunStatus> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let connection = transfer_connection(id)?;
        if connection.generation != generation {
            bail!("原SSH代次已改变；未启动转发");
        }
        let rule = tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let target = &connection.target;
                let host = hspterm_storage_sync::Repository::new(v)
                    .host(&target.host_id)?
                    .context("关联主机已删除，不能启动新的已保存转发规则")?;
                if host.address != target.address
                    || host.port != target.port
                    || host.username != target.username
                {
                    bail!("当前会话目标与保存主机配置不同；未启动转发");
                }
                let rule = hspterm_storage_sync::forwarding_rules::ForwardingConfig::load(
                    v,
                    &target.host_id,
                )?
                .rules
                .into_iter()
                .find(|r| r.id == rule_id)
                .context("转发规则已删除，请刷新配置")?;
                if !rule.enabled {
                    bail!("该转发规则已停用，请先明确启用");
                }
                Ok(rule)
            })
        })
        .await??;
        if entry.closed.load(Ordering::Acquire) || entry.transfer_closing.load(Ordering::Acquire) {
            bail!("终端正在关闭");
        }
        entry
            .forwardings
            .start(id, generation, entry.session.clone(), rule)
            .await
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Explicitly confirmed terminal loopback link. Ephemeral loopback-only local
/// bind; never saves a rule, opens a browser, probes a target or reconnects SSH.
pub async fn start_temporary_forwarding(
    id: u32,
    generation: u64,
    target_address: String,
    target_port: u32,
) -> Result<crate::forwardings::runtime::RunStatus> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let rule = crate::forwardings::temporary_rule(target_address, target_port)?;
        let connection = transfer_connection(id)?;
        if connection.generation != generation {
            bail!("原SSH代次已改变；未启动临时转发");
        }
        let e = entry(id)?;
        e.forwardings
            .start(id, generation, connection.session, rule)
            .await
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Runtime metadata only; no forwarded bytes or saved host credentials.
pub async fn terminal_forwardings(id: u32) -> Result<Vec<crate::forwardings::runtime::RunStatus>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { Ok(entry(id)?.forwardings.list().await) }).await;
    crate::public_errors::finish(outcome)
}
/// Stops the original runtime token; does not delete its saved rule or SSH.
pub async fn stop_forwarding(id: u32, generation: u64, token: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        entry(id)?.forwardings.stop(&token, generation).await
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Parse only the supplied snapshot; no file, command, key or network access.
pub async fn preview_openssh_import(
    source: String,
    default_username: String,
) -> Result<crate::openssh_import::OpenSshImportPreview> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::openssh_import::preview(source, default_username).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Explicit metadata-only creation; credentials are configured separately.
pub async fn commit_openssh_import(
    source: String,
    default_username: String,
    aliases: Vec<String>,
    acknowledge_partial: bool,
    group_id: String,
    vault_scope: String,
) -> Result<Vec<HostConfig>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::openssh_import::commit(
            source,
            default_username,
            aliases,
            acknowledge_partial,
            group_id,
            vault_scope,
        )
        .await
    })
    .await;
    crate::public_errors::finish(outcome)
}

fn bind_display(entry: &Entry, runtime: crate::display::DisplayRuntime) {
    if entry.closed.load(Ordering::Acquire) {
        return;
    }
    let mut previous = entry.previous.lock();
    *previous = None;
    *entry.display.lock() = Some(runtime);
    entry.last_revision.store(u64::MAX, Ordering::Release);
    entry.kick.notify_one();
}
pub(crate) type BackupDisplayUpdate = (
    u32,
    Option<String>,
    Arc<hspterm_term_core::decorations::Decorator>,
);
pub(crate) fn invalidate_backup_agents() -> Result<()> {
    for entry in sessions().lock().values() {
        entry.agents.invalidate()?;
    }
    Ok(())
}
pub(crate) fn invalidate_synchronized_agents(hosts: &[String]) -> Result<()> {
    for entry in sessions().lock().values() {
        entry.agents.invalidate_sources(hosts)?;
    }
    Ok(())
}
pub(crate) fn configuration_synchronized(
    scope: &str,
    updates: Vec<BackupDisplayUpdate>,
    preferences: Option<&hspterm_term_core::preferences::Validated>,
) {
    retire_suggestions();
    if let Some(value) = preferences {
        publish_terminal_preferences(scope, scope, value);
    }
    for (id, host, decorator) in updates {
        if let Ok(entry) = entry(id) {
            bind_display(
                &entry,
                crate::display::DisplayRuntime {
                    source: crate::display::Source {
                        vault_scope: scope.into(),
                        host,
                    },
                    decorator,
                },
            );
        }
    }
}
pub(crate) fn configuration_restored(
    old_scope: &str,
    new_scope: &str,
    updates: Vec<BackupDisplayUpdate>,
    preferences: &hspterm_term_core::preferences::Validated,
) {
    retire_suggestions();
    crate::configuration_sync::vault_replaced();
    crate::drive_authorization::vault_replaced();
    publish_terminal_preferences(old_scope, new_scope, preferences);
    for entry in sessions().lock().values() {
        entry.agents.configuration_restored(old_scope, new_scope);
        entry.verification.vault_replaced();
        entry.pending_keys.lock().clear();
        entry.tmux.invalidate();
    }
    for (id, host, decorator) in updates {
        if let Ok(entry) = entry(id) {
            bind_display(
                &entry,
                crate::display::DisplayRuntime {
                    source: crate::display::Source {
                        vault_scope: new_scope.into(),
                        host,
                    },
                    decorator,
                },
            );
        }
    }
    diagnostics::record(DiagnosticCode::ConfigurationRestored, None, None);
}
pub(crate) fn display_sources() -> Vec<(u32, crate::display::Source)> {
    sessions()
        .lock()
        .iter()
        .filter_map(|(id, entry)| {
            entry
                .display
                .lock()
                .as_ref()
                .map(|r| (*id, r.source.clone()))
        })
        .collect()
}
pub(crate) fn replace_display(
    id: u32,
    source: &crate::display::Source,
    decorator: Arc<hspterm_term_core::decorations::Decorator>,
) {
    let Ok(entry) = entry(id) else {
        return;
    };
    if entry.closed.load(Ordering::Acquire) {
        return;
    }
    let mut previous = entry.previous.lock();
    let mut display = entry.display.lock();
    let Some(current) = display.as_mut().filter(|r| r.source == *source) else {
        return;
    };
    current.decorator = decorator;
    *previous = None;
    entry.last_revision.store(u64::MAX, Ordering::Release);
    entry.kick.notify_one();
}
pub async fn terminal_display_settings(
    host_id: Option<String>,
) -> Result<crate::display::DisplaySettingsView> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::display::load(host_id).await }).await;
    crate::public_errors::finish(outcome)
}
pub async fn save_terminal_display_settings(
    host_id: Option<String>,
    vault_scope: String,
    expected_revision: u64,
    config: Option<crate::display::DisplayConfig>,
) -> Result<crate::display::DisplaySettingsView> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::display::save(host_id, vault_scope, expected_revision, config).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn test_display_rules(
    config: crate::display::DisplayConfig,
    sample: String,
) -> Result<Vec<crate::display::DisplayRuleMatch>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::display::test(config, sample).await })
            .await;
    crate::public_errors::finish(outcome)
}
pub async fn import_display_rules(source: String) -> Result<Vec<crate::display::DisplayRule>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::display::import_rules(source).await })
            .await;
    crate::public_errors::finish(outcome)
}

fn agent_connected(entry: &Entry, generation: u64) -> Result<()> {
    let status = entry.session.status();
    anyhow::ensure!(
        !entry.closed.load(Ordering::Acquire)
            && status.generation == generation
            && !entry.transfer_closing.load(Ordering::Acquire)
            && status.phase == SessionPhase::Connected,
        "原 SSH 会话已失效"
    );
    Ok(())
}
fn agent_scope(v: &Vault, entry: &Entry, pending: &crate::agents::Pending) -> Result<()> {
    agent_connected(entry, pending.binding.generation)?;
    anyhow::ensure!(
        v.instance_id() == pending.binding.vault_scope,
        "加密库已切换；本终端需明确重连后重新授权"
    );
    anyhow::ensure!(
        entry
            .transfer_target
            .lock()
            .as_ref()
            .is_some_and(
                |(generation, target)| *generation == pending.binding.generation
                    && *target == pending.binding.target
            ),
        "实际 SSH 目标已变化"
    );
    Ok(())
}
pub async fn terminal_agent_state(id: u32, generation: u64) -> Result<crate::agents::AgentView> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        anyhow::ensure!(
            entry.session.status().generation == generation,
            "原 SSH 会话已失效"
        );
        Ok(entry.agents.binding(generation)?.connector.status().into())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn agent_key_options() -> Result<Vec<crate::agents::AgentKeyOption>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(hspterm_storage_sync::Repository::new(v)
                    .list()?
                    .into_iter()
                    .filter(|h| {
                        h.auth == hspterm_storage_sync::AuthMethod::PrivateKey
                            && h.credential_id.is_some()
                    })
                    .map(|h| crate::agents::AgentKeyOption {
                        host_id: h.id,
                        name: h.name,
                        fingerprint: None,
                    })
                    .collect())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn prepare_agent_authorisation(
    id: u32,
    generation: u64,
    host_ids: Vec<String>,
    seconds: u32,
) -> Result<crate::agents::AgentPreview> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        static NEXT_CONSENT: AtomicU64 = AtomicU64::new(1);
        let entry = entry(id)?;
        let operation = entry.agents.operation()?;
        let agents = crate::agents::gate().read_owned().await;
        let ticket = NEXT_CONSENT
            .try_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_add(1))
            .map_err(|_| anyhow::anyhow!("授权票据已耗尽"))?;
        tokio::task::spawn_blocking(move || {
            let _agents = agents;
            let _operation = operation;
            let (pending, keys) = with_vault(|v| {
                agent_connected(&entry, generation)?;
                let binding = entry.agents.binding(generation)?;
                anyhow::ensure!(
                    v.instance_id() == binding.vault_scope,
                    "加密库已切换；本终端需明确重连后重新授权"
                );
                let pending = entry.agents.reserve(
                    binding,
                    format!("agent-consent-{ticket:016x}"),
                    seconds,
                )?;
                let keys = crate::agents::selected(v, &host_ids)?;
                Ok((pending, keys))
            })?;
            // Parsing and private-key validation never run under the Vault gate.
            let mut fingerprints = std::collections::BTreeSet::new();
            let selected = keys
                .into_iter()
                .map(|(mut proof, credential)| {
                    let (_, fingerprint) = hspterm_ssh_core::agent_forward::prepare_key(
                        &credential.secret,
                        credential.passphrase.as_deref(),
                    )?;
                    anyhow::ensure!(
                        fingerprints.insert(fingerprint.clone()),
                        "所选主机引用相同密钥，请仅选择其中一个"
                    );
                    proof.fingerprint = fingerprint;
                    Ok(proof)
                })
                .collect::<Result<Vec<_>>>()?;
            with_vault(|v| {
                agent_scope(v, &entry, &pending)?;
                crate::agents::unchanged(v, &selected)?;
                entry.agents.publish(pending, selected)
            })
        })
        .await
        .map_err(|_| anyhow::anyhow!("Agent 密钥准备任务异常退出；没有建立授权"))?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn approve_agent_authorisation(
    id: u32,
    generation: u64,
    ticket: String,
) -> Result<crate::agents::AgentView> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let operation = entry.agents.operation()?;
        let agents = crate::agents::gate().read_owned().await;
        let registry = entry.agents.clone();
        let (pending, keys, _agents, _operation) = tokio::task::spawn_blocking(move || {
            let (pending, current) = with_vault(|v| {
                let pending = entry.agents.pending(&ticket)?;
                anyhow::ensure!(
                    pending.binding.generation == generation,
                    "原 SSH 会话已失效"
                );
                agent_scope(v, &entry, &pending)?;
                crate::agents::unchanged(v, &pending.keys)?;
                let ids = pending
                    .keys
                    .iter()
                    .map(|k| k.host_id.clone())
                    .collect::<Vec<_>>();
                let current = crate::agents::selected(v, &ids)?;
                Ok((pending, current))
            })?;
            let keys = current
                .into_iter()
                .zip(&pending.keys)
                .map(|((_, credential), selected)| {
                    let (key, fingerprint) = hspterm_ssh_core::agent_forward::prepare_key(
                        &credential.secret,
                        credential.passphrase.as_deref(),
                    )?;
                    anyhow::ensure!(
                        fingerprint == selected.fingerprint,
                        "密钥身份已变化，请重新预览"
                    );
                    Ok(key)
                })
                .collect::<Result<Vec<_>>>()?;
            with_vault(|v| {
                agent_scope(v, &entry, &pending)?;
                crate::agents::unchanged(v, &pending.keys)?;
                entry.agents.consume(&pending)
            })?;
            Ok::<_, anyhow::Error>((pending, keys, agents, operation))
        })
        .await
        .map_err(|_| anyhow::anyhow!("Agent 密钥准备任务异常退出；没有建立授权"))??;
        // Vault switch/revoke synchronously changes this registered connector's
        // epoch, covering the gap before or during core installation. Never hold a
        // Vault guard across this await. Reconnection has a different connector.
        let status = pending
            .binding
            .connector
            .authorise(
                pending.epoch,
                keys,
                Duration::from_secs(pending.seconds as u64),
            )
            .await?;
        registry.granted(&pending, status.epoch);
        Ok(status.into())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn cancel_agent_authorisation(id: u32, ticket: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        entry(id)?.agents.cancel(&ticket);
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn revoke_terminal_agent(id: u32, generation: u64) -> Result<crate::agents::AgentView> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        anyhow::ensure!(
            entry.session.status().generation == generation,
            "原 SSH 会话已失效"
        );
        entry.agents.invalidate()?;
        Ok(entry
            .agents
            .binding(generation)?
            .connector
            .revoke()
            .await?
            .into())
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Only the original connection-attempt metadata, no SSH input or authentication.
pub async fn terminal_tmux_prompt(id: u32, request_id: u32) -> Result<crate::tmux::TmuxPrompt> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            let e = entry(id)?;
            let state = e.session.status();
            anyhow::ensure!(
                !e.closed.load(Ordering::Acquire) && state.phase == SessionPhase::Connecting,
                "原tmux连接已结束"
            );
            let prompt = e.tmux.prompt(request_id)?;
            anyhow::ensure!(prompt.generation == state.generation, "原tmux代次已改变");
            Ok(prompt)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn terminal_tmux_restore_enabled(id: u32, generation: u64) -> Result<bool> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        ensure!(
            !e.closed.load(Ordering::Acquire) && e.session.status().generation == generation,
            "原终端或tmux代次已改变"
        );
        e.tmux.restore_enabled(generation)
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn forget_terminal_tmux_restore(id: u32, generation: u64) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        ensure!(
            !e.closed.load(Ordering::Acquire) && e.session.status().generation == generation,
            "原终端或tmux代次已改变"
        );
        e.tmux.forget_restore(generation)
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn answer_terminal_tmux(
    id: u32,
    generation: u64,
    request_id: u32,
    selection: crate::tmux::TmuxSelection,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            let e = entry(id)?;
            anyhow::ensure!(
                !e.closed.load(Ordering::Acquire)
                    && e.session.status().generation == generation
                    && e.session.status().phase == SessionPhase::Connecting,
                "原tmux连接已结束"
            );
            e.tmux.answer(request_id, generation, selection)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn load_host_bulk(ids: Vec<String>) -> Result<crate::host_bulk::HostBulkView> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| Ok(hspterm_storage_sync::host_bulk::load(v, &ids)?.into()))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn apply_host_bulk(
    vault_scope: String,
    revision: String,
    ids: Vec<String>,
    patch: crate::host_bulk::HostBulkPatch,
) -> Result<crate::host_bulk::HostBulkView> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                Ok(hspterm_storage_sync::host_bulk::apply(
                    v,
                    &vault_scope,
                    &revision,
                    &ids,
                    patch.into(),
                )?
                .into())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn load_host_ordering() -> Result<crate::host_ordering::OrderingView> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| Ok(hspterm_storage_sync::host_ordering::load(v)?.into()))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn apply_host_ordering(
    vault_scope: String,
    revision: String,
    groups: Vec<String>,
    hosts: Vec<String>,
    placements: Vec<crate::host_ordering::OrderingPlacement>,
) -> Result<crate::host_ordering::OrderingView> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let change = hspterm_storage_sync::host_ordering::Change {
                    groups,
                    hosts,
                    placements: placements.into_iter().map(Into::into).collect(),
                };
                Ok(
                    hspterm_storage_sync::host_ordering::apply(v, &vault_scope, &revision, change)?
                        .into(),
                )
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Metadata only. No command strings or input collection endpoint.
pub async fn command_history_controls() -> Result<crate::history_controls::HistoryControls> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| Ok(hspterm_storage_sync::command_history::controls::load(v)?.into()))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn set_command_history_enabled(
    vault_scope: String,
    revision: String,
    enabled: bool,
) -> Result<crate::history_controls::HistoryControls> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let before = hspterm_storage_sync::command_history::controls::load(v)?;
                let result = hspterm_storage_sync::command_history::controls::apply(
                    v,
                    &vault_scope,
                    &revision,
                    hspterm_storage_sync::command_history::controls::Action::Enabled(enabled),
                )?;
                if before.revision != result.revision {
                    retire_suggestions();
                }
                Ok(result.into())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn clear_command_history(
    vault_scope: String,
    revision: String,
    host_id: Option<String>,
) -> Result<crate::history_controls::HistoryControls> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                use hspterm_storage_sync::command_history::controls::{Action, apply};
                let action = host_id.clone().map_or(Action::ClearAll, Action::ClearHost);
                let result = apply(v, &vault_scope, &revision, action)?;
                retire_suggestions_for(host_id.as_deref());
                Ok(result.into())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// One decrypted search row for the settings history manager. The command
/// text crosses the bridge only inside this response and is never logged.
#[derive(Clone)]
pub struct CommandSearchRow {
    pub host_id: String,
    pub text: String,
    pub used_counter: u64,
}

pub async fn search_command_history(
    query: String,
    host_id: Option<String>,
    limit: u32,
    expected_vault_scope: Option<String>,
) -> Result<Vec<CommandSearchRow>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                ensure!(
                    expected_vault_scope
                        .as_deref()
                        .is_none_or(|scope| scope == v.instance_id()),
                    "原历史管理配置库已改变，请重新打开页面"
                );
                use hspterm_storage_sync::command_history::HistoryRepository;
                Ok(HistoryRepository::new(v)
                    .search_commands(&query, host_id.as_deref(), limit as usize)?
                    .into_iter()
                    .map(|mut hit| CommandSearchRow {
                        host_id: std::mem::take(&mut hit.host_id),
                        text: std::mem::take(&mut hit.text),
                        used_counter: hit.used_counter,
                    })
                    .collect())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Tombstoned single/batch delete. `host_id = None` deletes the texts on
/// every host that stores them. The revision of the history document is
/// consumed inside the atomic commit; stale callers get a public summary.
pub async fn delete_command_history(
    texts: Vec<String>,
    host_id: Option<String>,
    expected_vault_scope: Option<String>,
) -> Result<u32> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                ensure!(
                    expected_vault_scope
                        .as_deref()
                        .is_none_or(|scope| scope == v.instance_id()),
                    "原历史管理配置库已改变，请重新打开页面"
                );
                use hspterm_storage_sync::command_history::HistoryRepository;
                let borrowed: Vec<&str> = texts.iter().map(String::as_str).collect();
                let deleted =
                    HistoryRepository::new(v).delete_commands(host_id.as_deref(), &borrowed)?;
                if deleted > 0 {
                    retire_suggestions_for(host_id.as_deref());
                }
                Ok(deleted as u32)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Round-12 candidate delete: resolves the exact text from the live ticket
/// (never trusts Dart-side strings), tombstone-deletes it on every host so
/// a synced stale copy cannot resurrect it, and retires every session's
/// candidate cache. Returns 1 when a command was deleted, 0 for an expired
/// ticket/index or nothing to delete.
pub async fn delete_terminal_suggestion(id: u32, ticket: String, index: u32) -> Result<u32> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let entry = entry(id)?;
        let text = {
            let cache = entry.suggestions.lock();
            cache
                .proposal
                .as_ref()
                .filter(|p| p.ticket == ticket)
                .and_then(|p| p.choices.get(usize::try_from(index).unwrap_or(usize::MAX)))
                .map(|t| t.to_string())
        };
        let Some(text) = text else {
            return Ok(0);
        };
        let deleted = tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                use hspterm_storage_sync::command_history::HistoryRepository;
                HistoryRepository::new(v)
                    .delete_commands(None, &[&text])
                    .map_err(anyhow::Error::from)
            })
        })
        .await??;
        if deleted > 0 {
            retire_suggestions_for(None);
        }
        Ok(deleted as u32)
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn command_palette_shortcut() -> Result<crate::shortcut_settings::PaletteShortcutView> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| Ok(hspterm_storage_sync::shortcut_settings::load(v)?.into()))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_command_palette_shortcut(
    value: crate::shortcut_settings::PaletteShortcutView,
) -> Result<crate::shortcut_settings::PaletteShortcutView> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let scope = value.vault_scope.clone();
                let revision = value.revision.clone();
                Ok(hspterm_storage_sync::shortcut_settings::save(
                    v,
                    &scope,
                    &revision,
                    value.config(),
                )?
                .into())
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Small, versioned device-local font/typography metadata; never terminal text.
pub async fn configuration_backup_summary() -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::backups::summary().await }).await;
    crate::public_errors::finish(outcome)
}
/// Device-local sync metadata only. Reading never starts HTTP or reveals secrets.
pub async fn load_configuration_sync_settings() -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::cloud_sync::settings::load(v)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Device-local metadata only; never reads browser cookies or existing logins.
pub async fn load_google_drive_account() -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::google_drive_account::load(v)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Reserves a cancelable original-source operation before binding a listener
/// or opening a browser. JSON contains write-only optional desktop client secret.
pub async fn reserve_google_drive_authorization(input: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::drive_authorization::reserve(input).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
pub async fn prepare_google_drive_authorization(operation: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::drive_authorization::prepare(operation).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
pub async fn finish_google_drive_authorization(operation: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::drive_authorization::finish(operation).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
/// Local removal and provider-side revocation are distinct explicit actions.
pub async fn reserve_google_drive_account_removal(
    vault_scope: String,
    revision: String,
    revoke: bool,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::drive_authorization::reserve_removal(vault_scope, revision, revoke).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn remove_google_drive_account(operation: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::drive_authorization::remove(operation).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
pub async fn cancel_google_drive_authorization(operation: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::drive_authorization::cancel(operation).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
pub async fn reserve_google_drive_object_discovery(
    vault_scope: String,
    revision: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::drive_authorization::reserve_discovery(vault_scope, revision).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn discover_google_drive_objects(operation: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::drive_authorization::discover(operation).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn select_google_drive_object(operation: String, input: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::drive_authorization::select_object(operation, input).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn pending_google_drive_creation() -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::drive_authorization::pending_creation().await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
pub async fn reserve_google_drive_creation(
    vault_scope: String,
    account_revision: String,
    creation_revision: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::drive_authorization::reserve_creation(
            vault_scope,
            account_revision,
            creation_revision,
        )
        .await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn prepare_google_drive_creation(operation: String, input: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::drive_authorization::prepare_creation(operation, input).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn finish_google_drive_creation(operation: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::drive_authorization::finish_creation(operation).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn discard_google_drive_creation(
    vault_scope: String,
    revision: String,
    confirm_local_only: bool,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::drive_authorization::discard_creation(vault_scope, revision, confirm_local_only)
            .await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn load_configuration_sync_archives() -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::cloud_sync::archives::load(v)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn load_appearance() -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::appearance::load(v)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn load_sftp_view_settings() -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::sftp_view_settings::load(v)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_sftp_view_settings(proposal: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        ensure!(proposal.len() <= 4096, "SFTP浏览设置超过安全容量");
        let value =
            serde_json::from_str::<hspterm_storage_sync::sftp_view_settings::Proposal>(&proposal)
                .map_err(|_| anyhow::anyhow!("SFTP浏览设置提交格式无效"))?;
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::sftp_view_settings::save(v, value)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_appearance(
    vault_scope: String,
    revision: String,
    theme: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let theme = match theme.as_str() {
            "dark" => hspterm_storage_sync::appearance::Theme::Dark,
            "light" => hspterm_storage_sync::appearance::Theme::Light,
            _ => anyhow::bail!("界面主题无效，原设置保留"),
        };
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::appearance::save(v, &vault_scope, &revision, theme)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn remove_configuration_sync_archives(proposal: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        ensure!(proposal.len() <= 8192, "同步基线清理提交超过安全容量");
        tokio::task::spawn_blocking(move || {
            let removal =
                serde_json::from_str::<hspterm_storage_sync::cloud_sync::archives::Removal>(
                    &proposal,
                )
                .map_err(|_| anyhow::anyhow!("同步基线清理提交格式无效"))?;
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::cloud_sync::archives::remove(v, removal)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn open_configuration_sync() -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(crate::configuration_sync::open).await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn watch_configuration_sync(owner: String, sink: StreamSink<String>) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::configuration_sync::watch_status(owner, sink).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn configuration_sync_status(owner: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::configuration_sync::status(&owner) }).await;
    crate::public_errors::finish(outcome)
}
pub async fn reserve_configuration_sync(owner: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::configuration_sync::reserve(&owner) })
            .await;
    crate::public_errors::finish(outcome)
}
pub async fn prepare_configuration_sync(owner: String, operation: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::configuration_sync::prepare(owner, operation).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Restore one authenticated cloud snapshot as a new revision, after explicit
/// UI confirmation. The original operation/target and final ETag remain bound.
pub async fn prepare_configuration_sync_snapshot(
    owner: String,
    operation: String,
    snapshot: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::configuration_sync::prepare_snapshot(owner, operation, snapshot).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn confirm_configuration_sync(
    owner: String,
    operation: String,
    review: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::configuration_sync::confirm(owner, operation, review).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn cancel_configuration_sync(owner: String, operation: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::configuration_sync::cancel(owner, operation).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn close_configuration_sync(owner: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::configuration_sync::close(owner).await })
            .await;
    crate::public_errors::finish(outcome)
}
pub async fn configuration_sync_reference_choices(
    owner: String,
    operation: String,
    review: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::configuration_sync::reference_choices(owner, operation, review).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn resolve_configuration_sync_references(
    owner: String,
    operation: String,
    review: String,
    choices: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::configuration_sync::resolve_references(owner, operation, review, choices).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Explicit complete-configuration overwrite direction. Shared host IDs and
/// reference integrity are preserved; command-history deletion knowledge is
/// merged. No candidate plaintext crosses the bridge.
pub async fn resolve_configuration_sync_direction(
    owner: String,
    operation: String,
    review: String,
    direction: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::configuration_sync::resolve_direction(owner, operation, review, direction).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Device-local periodic check interval in minutes (0 disables, default 10,
/// maximum 1440). Reading never starts HTTP; the record is never synced.
pub async fn load_configuration_sync_interval() -> Result<u32> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| Ok(hspterm_storage_sync::sync_interval::load(v)?))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Saves the interval through the same record CAS as the other device
/// preferences. The application restarts its periodic timer from the ACK.
pub async fn save_configuration_sync_interval(minutes: u32) -> Result<u32> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        ensure!(
            minutes <= 1440,
            "同步检查间隔必须在 0–1440 分钟内；0 表示关闭"
        );
        tokio::task::spawn_blocking(move || {
            with_vault(|v| Ok(hspterm_storage_sync::sync_interval::save(v, minutes)?))
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// The proposal's write-only secrets are immediately wrapped in a zeroizing
/// buffer; neither this proposal nor passwords are returned or diagnosed.
pub async fn save_configuration_sync_settings(proposal: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let proposal = Zeroizing::new(proposal);
        ensure!(proposal.len() <= 128 * 1024, "同步配置提交超过安全容量");
        tokio::task::spawn_blocking(move || {
            let proposal = serde_json::from_str::<
                hspterm_storage_sync::cloud_sync::settings::Proposal,
            >(&proposal)
            .map_err(|_| anyhow::anyhow!("同步配置提交格式无效；没有保存"))?;
            with_vault(|v| {
                let saved = hspterm_storage_sync::cloud_sync::settings::save(v, proposal)?;
                crate::configuration_sync::settings_saved(
                    v.instance_id(),
                    saved.target.as_ref().is_some_and(|t| t.enabled),
                );
                Ok(serde_json::to_string(&saved)?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn vault_unlock_hint(path: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            Ok(hspterm_storage_sync::secure_unlock::hint(
                std::path::Path::new(&path),
            )?)
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn secure_unlock_source() -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::secure_unlock::source(v)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn verify_secure_unlock(
    vault_scope: String,
    token: String,
    password: String,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let password = Zeroizing::new(password);
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                Ok(hspterm_storage_sync::secure_unlock::verify(
                    v,
                    &vault_scope,
                    &token,
                    password.as_bytes(),
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn export_configuration_backup(
    vault_scope: String,
    revision: String,
    password: String,
    backup_password: String,
    path: String,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::backups::export(vault_scope, revision, password, backup_password, path).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn prepare_configuration_restore(
    path: String,
    password: String,
    mode: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(
            async move { crate::backups::begin(path, password, mode).await },
        )
        .await;
    crate::public_errors::finish(outcome)
}
pub async fn preview_configuration_restore(ticket: String, mode: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> =
        crate::public_errors::guard(async move { crate::backups::repreview(ticket, mode).await })
            .await;
    crate::public_errors::finish(outcome)
}
pub async fn apply_configuration_restore(
    ticket: String,
    use_incoming: Vec<String>,
    password: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        crate::backups::apply(ticket, use_incoming, password).await
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn cancel_configuration_restore(ticket: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || crate::backups::cancel(&ticket)).await?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn load_terminal_typography() -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(|| {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::typography::load(v)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn save_terminal_typography(proposal: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        if proposal.len() > 16 * 1024 {
            anyhow::bail!("排版设置超过容量");
        }
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let proposal = serde_json::from_str(&proposal)?;
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::typography::save(v, proposal)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Device-local host override; None restores global inheritance. No SSH IO.
pub async fn save_host_terminal_typography(proposal: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        if proposal.len() > 16 * 1024 {
            anyhow::bail!("排版设置超过容量");
        }
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                let proposal = serde_json::from_str(&proposal)?;
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::typography::save_host(v, proposal)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn import_terminal_font(
    vault_scope: String,
    revision: String,
    label: String,
    bytes: Vec<u8>,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        if bytes.len() > hspterm_storage_sync::typography::FONT_LIMIT {
            anyhow::bail!("字体超过32MiB");
        }
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::typography::import(
                        v,
                        &vault_scope,
                        &revision,
                        label,
                        &bytes,
                    )?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn terminal_font_bytes(
    vault_scope: String,
    revision: String,
    id: String,
) -> Result<Vec<u8>> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                Ok(hspterm_storage_sync::typography::font_bytes(
                    v,
                    &vault_scope,
                    &revision,
                    &id,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn remove_terminal_font(
    vault_scope: String,
    revision: String,
    id: String,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        tokio::task::spawn_blocking(move || {
            with_vault(|v| {
                Ok(serde_json::to_string(
                    &hspterm_storage_sync::typography::remove(v, &vault_scope, &revision, &id)?,
                )?)
            })
        })
        .await?
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Explicit per-original-session volatile consent. Does not execute a command.
pub async fn configure_remote_inspection(
    id: u32,
    generation: u64,
    metrics: bool,
    processes: bool,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let target = entry(id)?;
        let status = target.session.status();
        ensure!(
            !target.closed.load(Ordering::Acquire)
                && status.generation == generation
                && status.phase == SessionPhase::Connected,
            "原终端已断开、关闭或重连；未改变远端检查授权"
        );
        target.inspection.configure(generation, metrics, processes)
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// No text/commands: bounded geometry for an explicit caret click.
pub struct TerminalCursorMove {
    pub column: u16,
    pub row: u16,
    pub cursor_column: u16,
    pub cursor_row: u16,
    pub steps: u16,
}

/// Fresh inner-pane mouse detection and tmux-queue guarded caret movement.
/// "handled" is not an execution receipt; never automatically replay it.
pub async fn terminal_tmux_click_cursor(
    id: u32,
    generation: u64,
    pane: String,
    movement: TerminalCursorMove,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let target = entry(id)?;
        let inspector = target.session.inspector_for(generation).await?;
        let value = match inspector
            .tmux_click_cursor(
                pane,
                hspterm_ssh_core::inspection::CursorMove {
                    column: movement.column,
                    row: movement.row,
                    cursor_column: movement.cursor_column,
                    cursor_row: movement.cursor_row,
                    steps: movement.steps,
                },
                tokio_util::sync::CancellationToken::new(),
            )
            .await
        {
            Ok(value) => value,
            Err(hspterm_ssh_core::SshError::Inspection(
                hspterm_ssh_core::inspection::InspectionError::Busy,
            )) => {
                // No probe or input reached tmux. Drop this best-effort click
                // without a popup or an unsafe replay into the active pane.
                return Ok("ignored".to_owned());
            }
            Err(error) => return Err(error.into()),
        };
        ensure!(
            target.session.status().generation == generation
                && target.session.status().phase == SessionPhase::Connected,
            "原终端会话已改变"
        );
        let route = value
            .get("pointer")
            .and_then(serde_json::Value::as_str)
            .filter(|v| matches!(*v, "mouse" | "handled" | "ignored"))
            .context("tmux点击响应无效")?;
        Ok(route.to_owned())
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Read/seek the attached tmux pane's real bounded history. No PTY injection.
pub async fn terminal_tmux_history(
    id: u32,
    generation: u64,
    pane: Option<String>,
    offset: Option<u32>,
) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let target = entry(id)?;
        let inspector = target.session.inspector_for(generation).await?;
        let value = inspector
            .tmux_history(pane, offset, tokio_util::sync::CancellationToken::new())
            .await?;
        ensure!(
            target.session.status().generation == generation
                && target.session.status().phase == SessionPhase::Connected,
            "原终端会话已改变"
        );
        Ok(serde_json::to_string(&value)?)
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn sample_remote_resources(id: u32, generation: u64) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let target = entry(id)?;
        let lease = target.inspection.lease(generation, false)?;
        let inspector = target.session.inspector().await?;
        ensure!(
            target.session.status().generation == generation,
            "原终端会话已改变"
        );
        target.inspection.current(&lease)?;
        let value = inspector.sample(lease.cancel.clone()).await?;
        let status = target.session.status();
        ensure!(
            status.generation == generation && status.phase == SessionPhase::Connected,
            "原终端会话已改变"
        );
        target.inspection.current(&lease)?;
        Ok(serde_json::to_string(&value)?)
    })
    .await;
    crate::public_errors::finish(outcome)
}

pub async fn list_remote_processes(id: u32, generation: u64) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let target = entry(id)?;
        let lease = target.inspection.lease(generation, true)?;
        let inspector = target.session.inspector().await?;
        ensure!(
            target.session.status().generation == generation,
            "原终端会话已改变"
        );
        target.inspection.current(&lease)?;
        let value = inspector.processes(lease.cancel.clone()).await?;
        let status = target.session.status();
        ensure!(
            status.generation == generation && status.phase == SessionPhase::Connected,
            "原终端会话已改变"
        );
        target.inspection.publish(&lease, value)
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Only SIGTERM to a process from the unexpired original list, once. Success
/// means the kernel accepted a signal, not that the target actually exited.
pub async fn terminate_remote_process(
    id: u32,
    generation: u64,
    revision: String,
    pid: u32,
    confirmed: bool,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        ensure!(
            confirmed && revision.len() <= 64,
            "结束远端进程需要对原对象明确确认"
        );
        let target = entry(id)?;
        let lease = target.inspection.lease(generation, true)?;
        let inspector = target.session.inspector().await?;
        let status = target.session.status();
        ensure!(
            status.generation == generation && status.phase == SessionPhase::Connected,
            "原终端会话已改变"
        );
        let (process, boot) = target.inspection.consume(&lease, &revision, pid)?;
        inspector
            .terminate(&process, &boot, lease.cancel)
            .await
            .map_err(|error| anyhow::anyhow!(error))
    })
    .await;
    crate::public_errors::finish(outcome)
}

#[cfg(test)]
mod trust_tests {
    use super::*;
    #[tokio::test]
    async fn stale_search_snapshot_is_retired_for_hidden_views_but_cursor_only_changes_keep_it() {
        let id = create_terminal(40, 5, 100).await.unwrap();
        let source = entry(id).unwrap();
        search_terminal(id, "synthetic".into(), false, false)
            .await
            .unwrap();
        let weak = Arc::downgrade(source.search.lock().as_ref().unwrap());
        source.visible.store(false, Ordering::Release);
        source.session.invalidate_view();
        retire_stale_search(&source);
        assert!(
            weak.upgrade().is_some(),
            "view/cursor invalidations keep the current search"
        );
        resize_terminal(id, 41, 6, 9, 20).await.unwrap();
        retire_stale_search(&source);
        assert!(source.search.lock().is_none());
        assert!(
            weak.upgrade().is_none(),
            "the frozen corpus/grid must actually be released"
        );
        destroy_terminal(id).await.unwrap();
    }
    #[tokio::test]
    async fn clearing_one_host_retires_only_its_waiting_capture_owners() {
        let first = create_terminal(40, 5, 100).await.unwrap();
        let second = create_terminal(40, 5, 100).await.unwrap();
        let a = entry(first).unwrap();
        let b = entry(second).unwrap();
        *a.integration_scope.lock() = Some((0, "synthetic-scope".into(), "host-a".into()));
        *b.integration_scope.lock() = Some((0, "synthetic-scope".into(), "host-b".into()));
        let before_a = a.history_capture_epoch.load(Ordering::Acquire);
        let before_b = b.history_capture_epoch.load(Ordering::Acquire);
        retire_suggestions_for(Some("host-a"));
        assert_ne!(a.history_capture_epoch.load(Ordering::Acquire), before_a);
        assert_eq!(b.history_capture_epoch.load(Ordering::Acquire), before_b);
        destroy_terminal(first).await.unwrap();
        destroy_terminal(second).await.unwrap();
    }
    #[tokio::test]
    async fn cancelled_terminal_destroy_retains_exclusive_cleanup_owner_for_retry() {
        let id = create_terminal(40, 5, 100).await.unwrap();
        let source = entry(id).unwrap();
        let gate = source.search_gate.clone().lock_owned().await;
        let closing = tokio::spawn(destroy_terminal(id));
        tokio::time::timeout(Duration::from_secs(5), async {
            while !source.closed.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
            source.session.wait_closed().await;
        })
        .await
        .unwrap();
        assert!(entry(id).is_err());
        assert!(
            sessions()
                .lock()
                .get(&id)
                .is_some_and(|saved| Arc::ptr_eq(saved, &source))
        );
        closing.abort();
        assert!(closing.await.unwrap_err().is_cancelled());
        let retry = tokio::spawn(destroy_terminal(id));
        tokio::task::yield_now().await;
        assert!(!retry.is_finished());
        drop(gate);
        tokio::time::timeout(Duration::from_secs(5), retry)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(!sessions().lock().contains_key(&id));
        destroy_terminal(id).await.unwrap();
    }
    #[tokio::test]
    async fn destroying_terminal_waits_for_real_history_worker_after_rpc_handle_is_abandoned() {
        let id = create_terminal(40, 5, 100).await.unwrap();
        let source = entry(id).unwrap();
        let gate = source.search_gate.clone().lock_owned().await;
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release, waiting) = std::sync::mpsc::channel();
        let worker = tokio::task::spawn_blocking(move || {
            let _gate = gate;
            started_tx.send(()).unwrap();
            waiting.recv_timeout(Duration::from_secs(5)).unwrap();
        });
        started_rx.await.unwrap();
        // Abandoning a blocking RPC cannot terminate its actual OS thread.
        worker.abort();
        let closing = tokio::spawn(destroy_terminal(id));
        tokio::task::yield_now().await;
        assert!(source.search_gate.try_lock().is_err());
        assert!(!closing.is_finished());
        release.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(5), closing)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(source.search_gate.try_lock().is_ok());
    }
    #[test]
    fn an_older_prompt_cannot_replace_another_connections_new_trust() {
        let temp = tempfile::tempdir().unwrap();
        let mut store =
            Vault::create(&temp.path().join("trust.vault"), b"test-only-trust-master").unwrap();
        let id = trust_id("fixture.example.test", 22);
        remember_host_key(&mut store, &id, "SHA256:fixture-first").unwrap();
        remember_host_key(&mut store, &id, "SHA256:fixture-first").unwrap();
        assert!(remember_host_key(&mut store, &id, "SHA256:fixture-different").is_err());
        assert_eq!(
            store.get(&id).unwrap().unwrap().as_slice(),
            b"SHA256:fixture-first"
        );
    }
}

/// Explicit properties query. Directory size is the sum of remote entry sizes,
/// never the directory inode's size. No file contents are downloaded.
pub struct RemoteProperties {
    pub path: String,
    pub size: u64,
    pub files: u64,
    pub directories: u64,
    pub permissions: Option<u32>,
    pub uid: Option<u32>,
    pub gid: Option<u32>,
    pub link_target: Option<String>,
    pub size_complete: bool,
    /// Remote modification time in seconds; the write-back editor uses it
    /// with size for conflict detection.
    pub mtime: Option<u64>,
}
fn check_file_generation(id: u32, generation: u64) -> Result<()> {
    let e = entry(id)?;
    let state = e.session.status();
    ensure!(
        !e.transfer_closing.load(Ordering::Acquire)
            && state.phase == SessionPhase::Connected
            && state.generation == generation,
        "原SFTP操作绑定的SSH代次已改变，未执行"
    );
    Ok(())
}
pub async fn sftp_properties(
    id: u32,
    generation: u64,
    path: String,
    include_directory_size: Option<bool>,
) -> Result<RemoteProperties> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&path)?;
        let remote = remote_sftp(id, Some(generation)).await?;
        let operation = async {
            let root = remote.symlink_metadata(path.clone()).await?;
            let mut result = RemoteProperties {
                path: path.clone(),
                size: 0,
                files: 0,
                directories: 0,
                size_complete: false,
                permissions: root.permissions,
                uid: root.uid,
                gid: root.gid,
                mtime: root.mtime.map(u64::from),
                link_target: if root.is_symlink() {
                    Some(remote.read_link(path.clone()).await?)
                } else {
                    None
                },
            };
            if !root.is_dir() || root.is_symlink() {
                result.files = 1;
                result.size_complete = true;
                result.size = root.size.context("远端未提供文件大小")?;
                return Ok(result);
            }
            if !include_directory_size.unwrap_or(true) {
                result.directories = 1;
                return Ok(result);
            }
            let mut queued_bytes = path.len();
            let mut pending = vec![(path, 0u32)];
            while let Some((path, depth)) = pending.pop() {
                queued_bytes -= path.len();
                check_file_generation(id, generation)?;
                ensure!(
                    depth <= 128 && result.files + result.directories < 1_000_000,
                    "目录属性查询超过安全容量"
                );
                let current = remote.symlink_metadata(path.clone()).await?;
                ensure!(
                    current.is_dir() && !current.is_symlink(),
                    "目录在属性查询期间改变，请刷新后重试"
                );
                result.directories += 1;
                let mut stream = remote.read_dir_stream(path.clone()).await?;
                let read: Result<()> = async {
                    while let Some(page) = stream.next_page().await? {
                        check_file_generation(id, generation)?;
                        for entry in page {
                            let name = entry.filename;
                            if name == "." || name == ".." {
                                continue;
                            }
                            ensure!(!name.contains(['/', '\0']), "服务器返回无效文件名");
                            ensure!(
                                result.files + result.directories + (pending.len() as u64)
                                    < 1_000_000,
                                "目录属性查询超过安全容量"
                            );
                            if entry.attrs.is_dir() && !entry.attrs.is_symlink() {
                                let child = format!("{}/{name}", path.trim_end_matches('/'));
                                queued_bytes += child.len();
                                ensure!(
                                    queued_bytes <= 32 * 1024 * 1024 && pending.len() < 100_000,
                                    "目录属性查询超过安全容量"
                                );
                                pending.push((child, depth + 1));
                            } else {
                                result.files += 1;
                                result.size = result
                                    .size
                                    .checked_add(entry.attrs.size.context("远端未提供文件大小")?)
                                    .context("目录大小超过安全容量")?;
                            }
                        }
                    }
                    Ok(())
                }
                .await;
                let closed = stream.close().await;
                read?;
                closed?;
            }
            check_file_generation(id, generation)?;
            result.size_complete = true;
            Ok(result)
        };
        tokio::time::timeout(std::time::Duration::from_secs(30), operation)
            .await
            .context("目录属性查询超时，请缩小范围后重试")?
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// One bounded chunk of a progressively reported directory-size walk. Totals
/// are cumulative from the first page; `complete` retires the ticket.
pub struct DirectorySizePage {
    pub size: u64,
    pub files: u64,
    pub directories: u64,
    pub complete: bool,
}
#[flutter_rust_bridge::frb(ignore)]
struct DirSizeJob {
    generation: u64,
    root: String,
    inspector_failed: bool,
    pending: Vec<(String, u32)>,
    queued_bytes: usize,
    size: u64,
    files: u64,
    directories: u64,
    last_used: std::time::Instant,
}
const DIR_SIZE_IDLE: std::time::Duration = std::time::Duration::from_secs(600);
const DIR_SIZE_MAX_JOBS: usize = 4;
/// Starts a step-wise directory-size walk bound to one SSH generation. Each
/// step performs a bounded amount of remote work, so a slow or huge tree no
/// longer trips one long request timeout; the UI shows the growing totals.
pub async fn sftp_directory_size_begin(id: u32, generation: u64, path: String) -> Result<String> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&path)?;
        let e = entry(id)?;
        check_file_generation(id, generation)?;
        let remote = remote_sftp(id, Some(generation)).await?;
        let root = remote.symlink_metadata(path.clone()).await?;
        ensure!(
            root.is_dir() && !root.is_symlink(),
            "仅目录支持内容大小统计"
        );
        let mut jobs = e.dir_size_jobs.lock();
        jobs.retain(|_, job| job.last_used.elapsed() < DIR_SIZE_IDLE);
        ensure!(
            jobs.len() < DIR_SIZE_MAX_JOBS,
            "目录大小统计任务过多，请先完成或停止现有统计"
        );
        let ticket = format!("{:032x}", rand::random::<u128>());
        jobs.insert(
            ticket.clone(),
            DirSizeJob {
                generation,
                root: path.clone(),
                inspector_failed: false,
                queued_bytes: path.len(),
                pending: vec![(path, 0)],
                size: 0,
                files: 0,
                directories: 0,
                last_used: std::time::Instant::now(),
            },
        );
        Ok(ticket)
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Walks up to `budget_directories` (default 16, max 256) directories and
/// returns cumulative totals. Any error or timeout retires the ticket: a
/// partially listed directory is never re-read into the same totals. Totals
/// already displayed stay valid as of the last completed page.
pub async fn sftp_directory_size_step(
    id: u32,
    generation: u64,
    ticket: String,
    budget_directories: Option<u32>,
) -> Result<DirectorySizePage> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        check_file_generation(id, generation)?;
        let mut job = {
            let mut jobs = e.dir_size_jobs.lock();
            jobs.retain(|_, job| job.last_used.elapsed() < DIR_SIZE_IDLE);
            let job = jobs.remove(&ticket).context("目录大小统计已结束或不存在")?;
            // A ticket is bound to the generation that started the walk; a
            // reconnected terminal must not resume a stale path stack.
            ensure!(
                job.generation == generation,
                "目录大小统计所属SSH代次已改变，已停止"
            );
            job
        };
        // Fast path first: the fixed server-side walk (one round trip, local
        // stat calls — the speed the server's own file manager shows). Falls
        // back to the paged SFTP walk when the inspector is unavailable.
        let started = std::time::Instant::now();
        if !job.inspector_failed {
            match e
                .session
                .inspector_for(generation)
                .await?
                .directory_size(&job.root, tokio_util::sync::CancellationToken::new())
                .await
            {
                Ok(totals) => {
                    diagnostics::record(
                        diagnostics::DiagnosticCode::DirectorySizeRemote,
                        Some(id),
                        Some(generation),
                    );
                    return Ok(DirectorySizePage {
                        size: totals.size,
                        files: totals.files,
                        directories: totals.directories,
                        complete: true,
                    });
                }
                Err(hspterm_ssh_core::SshError::Inspection(
                    hspterm_ssh_core::inspection::InspectionError::Busy,
                )) => {
                    // Another long task (DirSize/ServerCopy) owns the long lane;
                    // short probes run on their own lane. Preserve the
                    // fast-path opportunity, not a permanent slow-walk
                    // downgrade. No totals were added.
                    let page = DirectorySizePage {
                        size: job.size,
                        files: job.files,
                        directories: job.directories,
                        complete: false,
                    };
                    check_file_generation(id, generation)?;
                    job.last_used = std::time::Instant::now();
                    e.dir_size_jobs.lock().insert(ticket, job);
                    return Ok(page);
                }
                Err(_) => {
                    diagnostics::record(
                        diagnostics::DiagnosticCode::DirectorySizeFallback,
                        Some(id),
                        Some(generation),
                    );
                    job.inspector_failed = true;
                }
            }
        }
        let _ = started;
        let remote = remote_sftp(id, Some(generation)).await?;
        let budget = budget_directories.unwrap_or(16).clamp(1, 256);
        let operation = async {
            for _ in 0..budget {
                let Some((path, depth)) = job.pending.pop() else {
                    break;
                };
                job.queued_bytes -= path.len();
                check_file_generation(id, generation)?;
                ensure!(
                    depth <= 128 && job.files + job.directories < 1_000_000,
                    "目录大小统计超过安全容量"
                );
                let current = remote.symlink_metadata(path.clone()).await?;
                ensure!(
                    current.is_dir() && !current.is_symlink(),
                    "目录在统计期间改变，请刷新后重试"
                );
                job.directories += 1;
                let mut stream = remote.read_dir_stream(path.clone()).await?;
                let read: Result<()> = async {
                    while let Some(page) = stream.next_page().await? {
                        check_file_generation(id, generation)?;
                        for item in page {
                            let name = item.filename;
                            if name == "." || name == ".." {
                                continue;
                            }
                            ensure!(!name.contains(['/', '\0']), "服务器返回无效文件名");
                            ensure!(
                                job.files + job.directories + (job.pending.len() as u64)
                                    < 1_000_000,
                                "目录大小统计超过安全容量"
                            );
                            if item.attrs.is_dir() && !item.attrs.is_symlink() {
                                let child = format!("{}/{name}", path.trim_end_matches('/'));
                                job.queued_bytes += child.len();
                                ensure!(
                                    job.queued_bytes <= 32 * 1024 * 1024
                                        && job.pending.len() < 100_000,
                                    "目录大小统计超过安全容量"
                                );
                                job.pending.push((child, depth + 1));
                            } else {
                                job.files += 1;
                                job.size = job
                                    .size
                                    .checked_add(item.attrs.size.context("远端未提供文件大小")?)
                                    .context("目录大小超过安全容量")?;
                            }
                        }
                    }
                    Ok(())
                }
                .await;
                let closed = stream.close().await;
                read?;
                closed?;
            }
            Ok(())
        };
        let result = tokio::time::timeout(std::time::Duration::from_secs(20), operation).await;
        let complete = job.pending.is_empty();
        let page = DirectorySizePage {
            size: job.size,
            files: job.files,
            directories: job.directories,
            complete,
        };
        result.context("目录大小统计超时或中断，已停止；已显示数值截至最近完整分页")??;
        if !complete {
            job.last_used = std::time::Instant::now();
            e.dir_size_jobs.lock().insert(ticket, job);
        }
        Ok(page)
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Explicit stop for a progressive walk; idempotent. Callers must invoke it on
/// dialog disposal so the bounded registry does not wait for idle expiry.
pub async fn sftp_directory_size_stop(id: u32, ticket: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        let e = entry(id)?;
        e.dir_size_jobs.lock().remove(&ticket);
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}
/// Remote account names for the properties-dialog owner dropdowns, read from
/// the world-readable account databases over the same SFTP session. No exec,
/// no new privileges; unreadable or missing files yield empty lists and the
/// dialog falls back to numeric entry.
pub struct RemoteIdName {
    pub id: u32,
    pub name: String,
}
pub struct RemoteAccountOptions {
    pub users: Vec<RemoteIdName>,
    pub groups: Vec<RemoteIdName>,
}
fn parse_account_lines(bytes: &[u8]) -> Vec<RemoteIdName> {
    let mut out: Vec<RemoteIdName> = Vec::new();
    for line in String::from_utf8_lossy(bytes).lines() {
        if out.len() >= 4096 {
            break;
        }
        let fields: Vec<&str> = line.split(':').collect();
        if fields.len() < 3 {
            continue;
        }
        let Ok(id) = fields[2].parse::<u32>() else {
            continue;
        };
        let name = fields[0];
        if name.is_empty()
            || name.len() > 64
            || !name.bytes().all(|byte| byte.is_ascii_graphic())
            || out.iter().any(|existing| existing.id == id)
        {
            continue;
        }
        out.push(RemoteIdName {
            id,
            name: name.to_owned(),
        });
    }
    out
}
pub async fn sftp_account_options(id: u32, generation: u64) -> Result<RemoteAccountOptions> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        check_file_generation(id, generation)?;
        let remote = remote_sftp(id, Some(generation)).await?;
        async fn read_optional(
            remote: &hspterm_ssh_core::SftpSession,
            path: &str,
        ) -> Option<Vec<u8>> {
            let mut file = remote.open(path).await.ok()?;
            let mut bytes = Vec::new();
            // Bound the world-readable account file read; larger tails are
            // dropped exactly like an oversized file.
            let mut limited = (&mut file).take(256 * 1024);
            limited.read_to_end(&mut bytes).await.ok()?;
            drop(limited);
            file.shutdown().await.ok()?;
            Some(bytes)
        }
        let users = read_optional(&remote, "/etc/passwd")
            .await
            .map(|bytes| parse_account_lines(&bytes))
            .unwrap_or_default();
        let groups = read_optional(&remote, "/etc/group")
            .await
            .map(|bytes| parse_account_lines(&bytes))
            .unwrap_or_default();
        Ok(RemoteAccountOptions { users, groups })
    })
    .await;
    crate::public_errors::finish(outcome)
}
async fn property_children(
    remote: &hspterm_ssh_core::SftpSession,
    path: &str,
) -> Result<Vec<russh_sftp::protocol::File>> {
    let mut stream = remote.read_dir_stream(path).await?;
    let read: Result<_> = async {
        let mut entries = Vec::new();
        let mut bytes = 0usize;
        while let Some(page) = stream.next_page().await? {
            for entry in page {
                if entry.filename == "." || entry.filename == ".." {
                    continue;
                }
                ensure!(
                    !entry.filename.contains(['/', '\0']),
                    "服务器返回无效文件名"
                );
                bytes += entry.filename.len() + 128;
                ensure!(
                    entries.len() < 100_000 && bytes <= 32 * 1024 * 1024,
                    "递归属性修改超过安全容量"
                );
                entries.push(entry);
            }
        }
        Ok(entries)
    }
    .await;
    let closed = stream.close().await;
    let entries = read?;
    closed?;
    Ok(entries)
}
pub async fn sftp_set_properties(
    id: u32,
    generation: u64,
    path: String,
    permissions: Option<u32>,
    uid: Option<u32>,
    gid: Option<u32>,
    recursive: bool,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&path)?;
        ensure!(
            permissions.is_none_or(|p| p <= 0o7777),
            "权限必须为有效八进制权限"
        );
        let remote = remote_sftp(id, Some(generation)).await?;
        let canonical = remote.canonicalize(path.clone()).await?;
        let operation = async {
            let mut pending = vec![(path, false, 0u32)];
            let mut count = 0u32;
            while let Some((path, expanded, depth)) = pending.pop() {
                check_file_generation(id, generation)?;
                count += 1;
                ensure!(
                    count <= 2_000_000 && depth <= 128,
                    "递归属性修改超过安全容量；部分项目可能已修改"
                );
                let old = remote.symlink_metadata(path.clone()).await?;
                // Never chmod/chown a link target as a side effect of recursion.
                if old.is_symlink() {
                    ensure!(
                        recursive && depth > 0,
                        "符号链接权限不能安全修改；未跟随链接"
                    );
                    continue;
                }
                let resolved = remote.canonicalize(path.clone()).await?;
                ensure!(
                    resolved == canonical
                        || resolved.starts_with(&format!("{}/", canonical.trim_end_matches('/'))),
                    "远端目录已改变，未继续修改其他路径"
                );
                if recursive && old.is_dir() && !expanded {
                    pending.push((path.clone(), true, depth));
                    for entry in property_children(&remote, &path).await? {
                        let name = entry.filename;
                        if name == "." || name == ".." {
                            continue;
                        }
                        ensure!(
                            !name.contains(['/', '\0']) && pending.len() < 100_000,
                            "递归属性修改超过安全容量"
                        );
                        pending.push((
                            format!("{}/{name}", path.trim_end_matches('/')),
                            false,
                            depth + 1,
                        ));
                    }
                    continue;
                }
                let mut attrs = russh_sftp::protocol::FileAttributes {
                    permissions,
                    ..Default::default()
                };
                if uid.is_some() || gid.is_some() {
                    attrs.uid = Some(uid.or(old.uid).context("远端未提供原所有者UID")?);
                    attrs.gid = Some(gid.or(old.gid).context("远端未提供原所有组GID")?);
                }
                remote
                    .set_metadata(path, attrs)
                    .await
                    .context("属性修改未全部完成，请刷新核对已修改的项目")?;
            }
            Ok(())
        };
        tokio::time::timeout(std::time::Duration::from_secs(120), operation)
            .await
            .context("递归属性修改超时；部分项目可能已修改，请刷新核对")?
    })
    .await;
    crate::public_errors::finish(outcome)
}
pub async fn sftp_create_file(id: u32, generation: u64, path: String) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        validate_remote_path(&path)?;
        let remote = remote_sftp(id, Some(generation)).await?;
        let flags = russh_sftp::protocol::OpenFlags::WRITE
            | russh_sftp::protocol::OpenFlags::CREATE
            | russh_sftp::protocol::OpenFlags::EXCLUDE;
        let file = remote.open_with_flags(path, flags).await?;
        file.close().await?;
        Ok(())
    })
    .await;
    crate::public_errors::finish(outcome)
}

/// Clipboard copy on one SSH session: no local download/relay, no overwrite.
pub async fn sftp_copy_on_server(
    id: u32,
    generation: u64,
    source: String,
    destination: String,
) -> Result<()> {
    /* HSPTERM_PUBLIC_ERROR_BOUNDARY */
    let outcome: Result<_> = crate::public_errors::guard(async move {
        use tokio::io::AsyncWriteExt;
        validate_remote_path(&source)?; validate_remote_path(&destination)?;
        ensure!(source.starts_with('/') && destination.starts_with('/') && source.len() <= 16384 && destination.len() <= 16384, "远端复制需要有效绝对路径");
        let remote = remote_sftp(id, Some(generation)).await?;
        let (parent, name) = source.rsplit_once('/').context("无效来源路径")?;
        ensure!(!name.is_empty(), "不能复制远端根目录");
        let parent = remote.canonicalize(if parent.is_empty() {"/"} else {parent}).await?;
        let source = format!("{}/{name}", parent.trim_end_matches('/'));
        let (parent, name) = destination.rsplit_once('/').context("无效目标路径")?;
        ensure!(!name.is_empty(), "无效目标文件名称");
        let parent = remote.canonicalize(if parent.is_empty() {"/"} else {parent}).await?;
        let destination = format!("{}/{name}", parent.trim_end_matches('/'));
        ensure!(source != destination && !destination.starts_with(&format!("{}/", source.trim_end_matches('/'))), "不能复制到来源自身或子目录");
        ensure!(!remote.try_exists(destination.clone()).await?, "目标路径已存在，请先处理同名冲突");
        let metadata = remote.symlink_metadata(source.clone()).await?;
        let token: [u8; 32] = rand::random();
        let nonce: String = token.iter().map(|b| format!("{b:02x}")).collect();
        let marker = format!("{}/.hspterm-copy-{}", parent.trim_end_matches('/'), &nonce[..32]);
        let flags = russh_sftp::protocol::OpenFlags::WRITE | russh_sftp::protocol::OpenFlags::CREATE | russh_sftp::protocol::OpenFlags::EXCLUDE;
        let mut receipt = remote.open_with_flags(marker.clone(), flags).await?;
        // Bind the copy to this session generation's Transport Root: a close
        // or reconnect retires the token and aborts the bounded copy instead
        // of letting it run its full 120s deadline on a dead Root.
        let inspector = entry(id)?.session.inspector_for(generation).await?;
        let result: Result<()> = async {
            let written: Result<()> = async {
                receipt.set_metadata(russh_sftp::protocol::FileAttributes {permissions: Some(0o600), ..Default::default()}).await?;
                receipt.write_all(&token).await?; Ok(())
            }.await;
            let closed = receipt.close().await;
            written?; closed?;
            check_file_generation(id, generation)?;
            inspector.copy_file(serde_json::json!({
                "source":source, "destination":destination, "marker":marker, "nonce":nonce,
                "metadata":{"size":metadata.size,"mtime":metadata.mtime,"permissions":metadata.permissions,"uid":metadata.uid,"gid":metadata.gid}
            }), inspector.transport_cancel()).await.context("服务器内复制未确认；可能已创建部分目标，请检查后再操作；未自动下载或重试")?;
            Ok(())
        }.await;
        let cleanup = remote.remove_file(marker).await.context("远端复制校验文件清理失败，请刷新并检查目标目录");
        result?; cleanup?;
        Ok(())
    }).await;
    crate::public_errors::finish(outcome)
}
