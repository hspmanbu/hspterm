//! One non-secret tmux selection per original connection attempt.
use crate::{api::with_vault, connections::Scope};
use anyhow::{Context, Result, ensure};
use hspterm_ssh_core::tmux::{Choice, ListingIssue, Request};
use parking_lot::Mutex;
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
use tokio::sync::watch;

#[derive(Clone)]
pub struct TmuxSessionInfo {
    pub id: String,
    pub name: String,
    pub attached: u32,
}
#[derive(Clone)]
pub struct TmuxPrompt {
    pub readonly_default: Option<bool>,
    pub restore_available: Option<bool>,
    pub request_id: u32,
    pub generation: u64,
    pub columns: u16,
    pub rows: u16,
    pub version: Option<String>,
    pub issue: Option<String>,
    pub sessions: Vec<TmuxSessionInfo>,
}
pub struct TmuxSelection {
    pub restore_on_reconnect: Option<bool>,
    /// 0 cancel, 1 explicit ordinary Shell, 2 create, 3 attach.
    pub kind: u8,
    pub name: Option<String>,
    pub session_id: Option<String>,
    pub readonly: bool,
    pub takeover_confirmed: bool,
    pub lock_size: bool,
}
impl TmuxSelection {
    fn choice(self) -> Result<Choice> {
        Ok(match self.kind {
            0 => Choice::Cancel,
            1 => {
                ensure!(
                    self.name.is_none() && self.session_id.is_none(),
                    "普通Shell不能混入tmux目标"
                );
                Choice::Shell
            }
            2 => {
                ensure!(
                    self.session_id.is_none() && !self.readonly,
                    "新建tmux不能混入附着参数"
                );
                let name = self.name.context("请填写会话名称")?;
                if self.restore_on_reconnect == Some(true) {
                    Choice::CreateRemembered {
                        name,
                        lock_size: self.lock_size,
                    }
                } else {
                    Choice::Create {
                        name,
                        lock_size: self.lock_size,
                    }
                }
            }
            3 => {
                ensure!(self.name.is_none(), "附着tmux不能混入新建名称");
                Choice::Attach {
                    id: self.session_id.context("请选择原列表中的tmux会话")?,
                    readonly: self.readonly,
                    takeover_confirmed: self.takeover_confirmed,
                    lock_size: self.lock_size,
                }
            }
            _ => anyhow::bail!("tmux操作类型无效"),
        })
    }
}
struct TmuxPending {
    owner: u64,
    token: u32,
    generation: u64,
    scope: Scope,
    request: Request,
    profile_id: String,
    allow_restore: bool,
    restore_note: Option<&'static str>,
}
#[derive(Clone)]
struct Remembered {
    vault_scope: String,
    profile_id: String,
    host: hspterm_ssh_core::HostKey,
    username: String,
    session: hspterm_ssh_core::tmux::Identity,
    readonly: bool,
    lock_size: bool,
    takeover_confirmed: bool,
}
struct Selected {
    owner: u64,
    remembered: Option<Remembered>,
    created: Option<CreationMemory>,
}
struct CreationMemory {
    vault_scope: String,
    profile_id: String,
    host: hspterm_ssh_core::HostKey,
    username: String,
    lock_size: bool,
}
#[derive(Default)]
struct Memory {
    owner: u64,
    view_owner: u64,
    generation: Option<u64>,
    remembered: Option<Remembered>,
    selected: Option<Selected>,
}
pub(crate) struct TmuxRegistry {
    pending: Mutex<Option<TmuxPending>>,
    active: Mutex<Option<(u64, Option<hspterm_ssh_core::tmux::TmuxState>)>>,
    memory: Mutex<Memory>,
    changes: watch::Sender<u64>,
}
impl Default for TmuxRegistry {
    fn default() -> Self {
        let (changes, _) = watch::channel(0);
        Self {
            pending: Mutex::new(None),
            active: Mutex::new(None),
            memory: Mutex::new(Memory::default()),
            changes,
        }
    }
}
impl TmuxRegistry {
    fn changed(&self) {
        self.changes.send_modify(|v| *v = v.wrapping_add(1));
    }
    pub fn invalidate(&self) {
        self.cancel_pending();
        self.memory.lock().remembered = None;
    }
    pub fn cancel_pending(&self) {
        if self.pending.lock().take().is_some() {
            self.changed();
        }
        let mut memory = self.memory.lock();
        memory.selected = None;
        memory.owner = 0;
    }
    pub fn bind(&self, generation: u64, state: Option<hspterm_ssh_core::tmux::TmuxState>) {
        *self.active.lock() = Some((generation, state));
        self.changed();
    }
    pub fn shell_restored(&self, generation: u64) {
        // Same lock order as TmuxOwner::bind (memory -> active).
        let mut memory = self.memory.lock();
        let mut active = self.active.lock();
        if active.as_ref().is_some_and(|(g, _)| *g == generation) {
            *active = Some((generation, None));
            if memory.generation == Some(generation) {
                memory.remembered = None;
                memory.selected = None;
            }
            drop(active);
            drop(memory);
            self.changed();
        }
    }
    pub fn active(&self) -> Option<(u64, Option<hspterm_ssh_core::tmux::TmuxState>)> {
        *self.active.lock()
    }
    pub fn restore_enabled(&self, generation: u64) -> Result<bool> {
        let memory = self.memory.lock();
        ensure!(
            memory.generation.is_none_or(|actual| actual == generation),
            "原tmux记忆代次已改变"
        );
        Ok(memory.generation == Some(generation) && memory.remembered.is_some())
    }
    pub fn forget_restore(&self, generation: u64) -> Result<()> {
        let mut memory = self.memory.lock();
        ensure!(
            memory.generation == Some(generation)
                || memory.remembered.is_none() && memory.selected.is_none(),
            "原tmux记忆代次已改变"
        );
        memory.remembered = None;
        if let Some(selected) = &mut memory.selected {
            selected.remembered = None;
        }
        // No PTY input, transport change or pending choice cancellation.
        Ok(())
    }
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.subscribe()
    }
    pub fn token(&self) -> Option<(u32, u64)> {
        self.pending
            .lock()
            .as_ref()
            .map(|p| (p.token, p.generation))
    }
    pub fn owner(self: &Arc<Self>, scope: Scope) -> TmuxOwner {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        {
            let mut memory = self.memory.lock();
            memory.selected = None;
            memory.owner = id;
            memory.view_owner = id;
            memory.generation = None;
            self.active.lock().take();
        }
        TmuxOwner {
            registry: self.clone(),
            id,
            scope,
            profile_id: String::new(),
            allow_restore: false,
        }
    }
    pub fn prompt(&self, token: u32) -> Result<TmuxPrompt> {
        with_vault(|v| {
            let guard = self.pending.lock();
            let p = guard
                .as_ref()
                .filter(|p| p.token == token)
                .context("原tmux选择已结束")?;
            p.scope.check(v)?;
            ensure!(
                self.memory.lock().owner == p.owner,
                "原tmux显示所有者已退役"
            );
            Ok(TmuxPrompt {
                readonly_default: Some(if p.allow_restore {
                    hspterm_storage_sync::tmux_preferences::load(v, &p.profile_id)?
                } else {
                    true
                }),
                restore_available: Some(p.allow_restore),
                request_id: p.token,
                generation: p.generation,
                columns: p.request.columns,
                rows: p.request.rows,
                version: p.request.listing.version.clone(),
                issue: p
                    .request
                    .listing
                    .issue
                    .map(|issue| {
                        match issue {
                            ListingIssue::NotAvailable => "远端无法运行tmux；不会自动改为普通Shell",
                            ListingIssue::UnsupportedVersion => {
                                "当前tmux版本不在已支持的3.2及以上范围"
                            }
                            ListingIssue::ListUnavailable => {
                                "无法读取会话（可能尚无服务或缺少base64/tr）；可取消或明确新建"
                            }
                        }
                        .to_owned()
                    })
                    .or_else(|| p.restore_note.map(str::to_owned)),
                sessions: p
                    .request
                    .listing
                    .sessions
                    .iter()
                    .map(|s| TmuxSessionInfo {
                        id: s.id.clone(),
                        name: s.name.clone(),
                        attached: s.attached,
                    })
                    .collect(),
            })
        })
    }
    pub fn answer(&self, token: u32, generation: u64, selection: TmuxSelection) -> Result<()> {
        let readonly = (selection.kind == 3).then_some(selection.readonly);
        let restore = selection.restore_on_reconnect.unwrap_or(false);
        let choice = selection.choice()?;
        with_vault(|v| {
            let mut guard = self.pending.lock();
            let p = guard
                .as_ref()
                .filter(|p| p.token == token && p.generation == generation)
                .context("原tmux选择已结束或代次已改变")?;
            p.scope.check(v)?;
            ensure!(
                self.memory.lock().owner == p.owner,
                "原tmux显示所有者已退役"
            );
            let mut created = None;
            let remembered = if restore {
                ensure!(p.allow_restore, "一次性覆盖连接不能记忆tmux恢复目标");
                if let Choice::CreateRemembered { lock_size, .. } = &choice {
                    ensure!(p.request.listing.version.is_some(), "远端tmux版本不可用");
                    created = Some(CreationMemory {
                        vault_scope: v.instance_id().into(),
                        profile_id: p.profile_id.clone(),
                        host: p.request.verified_host.clone(),
                        username: p.request.username.clone(),
                        lock_size: *lock_size,
                    });
                    None
                } else {
                    let Choice::Attach {
                        id,
                        readonly,
                        takeover_confirmed,
                        lock_size,
                    } = &choice
                    else {
                        anyhow::bail!("该操作不能记忆tmux恢复目标");
                    };
                    ensure!(
                        p.request.listing.issue.is_none() && (*readonly || *takeover_confirmed),
                        "tmux恢复需要有效列表和明确接管同意"
                    );
                    let session = p
                        .request
                        .listing
                        .sessions
                        .iter()
                        .find(|s| &s.id == id)
                        .context("原tmux会话不在列表中")?;
                    Some(Remembered {
                        vault_scope: v.instance_id().into(),
                        profile_id: p.profile_id.clone(),
                        host: p.request.verified_host.clone(),
                        username: p.request.username.clone(),
                        session: session.identity(),
                        readonly: *readonly,
                        lock_size: *lock_size,
                        takeover_confirmed: *takeover_confirmed,
                    })
                }
            } else {
                None
            };
            if let Some(readonly) = readonly
                && p.allow_restore
            {
                hspterm_storage_sync::tmux_preferences::save(v, &p.profile_id, readonly)?;
            }
            let p = guard.take().context("原tmux选择已结束")?;
            drop(guard);
            self.changed();
            p.request
                .reply
                .send(choice)
                .map_err(|_| anyhow::anyhow!("原tmux连接已取消"))?;
            self.memory.lock().selected = Some(Selected {
                owner: p.owner,
                remembered,
                created,
            });
            Ok(())
        })
    }
}
pub(crate) struct TmuxOwner {
    registry: Arc<TmuxRegistry>,
    id: u64,
    scope: Scope,
    profile_id: String,
    allow_restore: bool,
}
impl TmuxOwner {
    pub fn for_target(mut self, profile_id: String, saved: bool) -> Self {
        self.allow_restore = saved && profile_id.starts_with("host-");
        self.profile_id = profile_id;
        self
    }
    /// Only an actually connected receipt activates a remembered choice. A
    /// failed exec, cancelled attempt or failed PTY cannot replace the cache.
    pub fn bind(
        &self,
        generation: u64,
        state: Option<hspterm_ssh_core::tmux::TmuxState>,
        identity: Option<hspterm_ssh_core::tmux::Identity>,
    ) {
        let published = with_vault(|v| {
            self.scope.check(v)?;
            let mut memory = self.registry.memory.lock();
            if memory.view_owner != self.id {
                return Ok(false);
            }
            if memory.owner == self.id {
                let selected = memory.selected.take().filter(|s| s.owner == self.id);
                memory.generation = Some(generation);
                memory.remembered = if let (Some(state), Some(identity), Some(selected)) =
                    (state, identity, selected)
                {
                    if let Some(remembered) = selected.remembered {
                        (remembered.session == identity
                            && remembered.readonly == state.readonly
                            && remembered.lock_size == state.size_locked)
                            .then_some(remembered)
                    } else {
                        selected
                            .created
                            .filter(|c| !state.readonly && c.lock_size == state.size_locked)
                            .map(|c| Remembered {
                                vault_scope: c.vault_scope,
                                profile_id: c.profile_id,
                                host: c.host,
                                username: c.username,
                                session: identity,
                                readonly: false,
                                lock_size: c.lock_size,
                                takeover_confirmed: true,
                            })
                    }
                } else {
                    None
                };
            }
            self.registry.bind(generation, state);
            Ok(true)
        });
        if published.is_err() {
            // Optional memory expires on source revocation. Existing SSH
            // remains usable; do not turn an old owner's failure into a write
            // against a later attempt's selection or active mode.
            let mut memory = self.registry.memory.lock();
            if memory.owner == self.id {
                memory.remembered = None;
                memory.selected = None;
                memory.generation = Some(generation);
            }
            if memory.view_owner == self.id {
                self.registry.bind(generation, state);
            }
        }
    }
    pub fn install(&self, token: u32, generation: u64, request: Request) -> Result<()> {
        with_vault(|v| {
            self.scope.check(v)?;
            let mut pending = self.registry.pending.lock();
            ensure!(pending.is_none(), "原连接已有一个tmux选择");
            ensure!(
                self.registry.memory.lock().owner == self.id,
                "原tmux显示所有者已退役"
            );
            self.registry.memory.lock().generation = Some(generation);
            let remembered = self.registry.memory.lock().remembered.clone();
            let mut restore_note = None;
            if self.allow_restore
                && let Some(remembered) = remembered
            {
                let source_matches = remembered.vault_scope == v.instance_id()
                    && remembered.profile_id == self.profile_id
                    && remembered.host == request.verified_host
                    && remembered.username == request.username;
                let session = request
                    .listing
                    .sessions
                    .iter()
                    .find(|s| s.matches_identity(&remembered.session));
                if source_matches
                    && request.listing.issue.is_none()
                    && let Some(session) = session
                {
                    request
                        .reply
                        .send(Choice::Attach {
                            id: session.id.clone(),
                            readonly: remembered.readonly,
                            takeover_confirmed: remembered.takeover_confirmed,
                            lock_size: remembered.lock_size,
                        })
                        .map_err(|_| anyhow::anyhow!("原tmux恢复请求已取消"))?;
                    self.registry.memory.lock().selected = Some(Selected {
                        owner: self.id,
                        remembered: Some(remembered),
                        created: None,
                    });
                    return Ok(());
                }
                restore_note =
                    Some("原记忆tmux目标与当前SSH身份或会话列表不一致；未自动附着，请重新选择。");
            }
            *pending = Some(TmuxPending {
                owner: self.id,
                token,
                generation,
                scope: self.scope.clone(),
                request,
                profile_id: self.profile_id.clone(),
                allow_restore: self.allow_restore,
                restore_note,
            });
            drop(pending);
            self.registry.changed();
            Ok(())
        })
    }
}
impl Drop for TmuxOwner {
    fn drop(&mut self) {
        let mut guard = self.registry.pending.lock();
        if guard.as_ref().is_some_and(|p| p.owner == self.id) {
            guard.take();
            drop(guard);
            self.registry.changed();
        }
        let mut memory = self.registry.memory.lock();
        if memory.selected.as_ref().is_some_and(|s| s.owner == self.id) {
            memory.selected = None;
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn shell_transition_clears_only_the_original_active_tmux_mode() {
        let registry = super::TmuxRegistry::default();
        let mode = hspterm_ssh_core::tmux::TmuxState {
            readonly: true,
            size_locked: true,
        };
        registry.bind(7, Some(mode));
        registry.shell_restored(6);
        assert!(registry.active().unwrap().1.is_some());
        registry.shell_restored(7);
        let active = registry.active().unwrap();
        assert_eq!(active.0, 7);
        assert!(active.1.is_none());
    }

    use super::*;
    use crate::connections::Verification;
    use hspterm_ssh_core::{ManagedSession, tmux::Listing};
    use hspterm_term_core::Size;
    use tokio::sync::{mpsc, oneshot};
    fn request() -> (Request, oneshot::Receiver<Choice>) {
        let (reply, rx) = oneshot::channel();
        (
            Request {
                verified_host: hspterm_ssh_core::HostKey {
                    address: "127.0.0.1".into(),
                    port: 22,
                    algorithm: "ssh-ed25519".into(),
                    sha256: "synthetic-fingerprint".into(),
                },
                username: "synthetic-user".into(),
                columns: 80,
                rows: 24,
                listing: Listing {
                    version: Some("tmux 3.4".into()),
                    issue: None,
                    sessions: vec![],
                },
                reply,
            },
            rx,
        )
    }
    fn shell() -> TmuxSelection {
        TmuxSelection {
            restore_on_reconnect: None,
            kind: 1,
            name: None,
            session_id: None,
            readonly: false,
            takeover_confirmed: false,
            lock_size: false,
        }
    }
    fn listed_request(pid: u32, created: u64) -> (Request, oneshot::Receiver<Choice>) {
        let (mut request, reply) = request();
        request.listing.sessions = hspterm_ssh_core::tmux::parse_sessions(
            format!("{pid}\t$12\t{created}\t0\tbmFtZQo=\n").as_bytes(),
        )
        .unwrap();
        (request, reply)
    }
    fn bind_policy(scope: &Scope) {
        let (keys, _) = mpsc::channel(1);
        with_vault(|v| {
            scope.policy(v, "127.0.0.1", 22, "trust-tmux-test".into(), false, keys)?;
            let mut repo = hspterm_storage_sync::Repository::new(v);
            for id in [
                "host-00000000000000000000000000000001",
                "host-00000000000000000000000000000002",
                "host-00000000000000000000000000000003",
            ] {
                if repo.host(id)?.is_none() {
                    let mut host = hspterm_storage_sync::HostRecord::new(
                        id.into(),
                        "127.0.0.1".into(),
                        "fixture".into(),
                        hspterm_storage_sync::AuthMethod::Password,
                    );
                    host.id = id.into();
                    repo.save(host, None)?;
                }
            }
            Ok(())
        })
        .unwrap();
    }
    fn remembered_selection() -> TmuxSelection {
        TmuxSelection {
            restore_on_reconnect: Some(true),
            kind: 3,
            name: None,
            session_id: Some("$12".into()),
            readonly: true,
            takeover_confirmed: false,
            lock_size: true,
        }
    }
    #[tokio::test]
    async fn new_session_is_remembered_only_after_actual_creation_identity_receipt() {
        let dir = tempfile::tempdir().unwrap();
        crate::api::unlock_vault(
            dir.path()
                .join("created.vault")
                .to_string_lossy()
                .into_owned(),
            "synthetic-master".into(),
        )
        .await
        .unwrap();
        let (session, _events) = ManagedSession::new(Size::new(80, 24).unwrap(), 10).unwrap();
        let session = Arc::new(session);
        let verification = Arc::new(Verification::default());
        let registry = Arc::new(TmuxRegistry::default());
        let attempt = verification.begin(session.clone()).unwrap();
        bind_policy(&attempt.scope());
        let owner = registry
            .owner(attempt.scope())
            .for_target("host-00000000000000000000000000000001".into(), true);
        let (req, reply) = request();
        owner.install(20, 1, req).unwrap();
        registry
            .answer(
                20,
                1,
                TmuxSelection {
                    restore_on_reconnect: Some(true),
                    kind: 2,
                    name: Some("new fixture".into()),
                    session_id: None,
                    readonly: false,
                    takeover_confirmed: false,
                    lock_size: false,
                },
            )
            .unwrap();
        assert!(matches!(
            reply.await.unwrap(),
            Choice::CreateRemembered { .. }
        ));
        assert!(!registry.restore_enabled(1).unwrap());
        owner.bind(
            1,
            Some(hspterm_ssh_core::tmux::TmuxState {
                readonly: false,
                size_locked: false,
            }),
            Some(listed_request(123, 456).0.listing.sessions[0].identity()),
        );
        assert!(registry.restore_enabled(1).unwrap());
        drop(owner);
        drop(attempt);
        let attempt = verification.begin(session.clone()).unwrap();
        bind_policy(&attempt.scope());
        let next = registry
            .owner(attempt.scope())
            .for_target("host-00000000000000000000000000000001".into(), true);
        let (req, reply) = listed_request(123, 456);
        next.install(21, 2, req).unwrap();
        assert!(matches!(
            reply.await.unwrap(),
            Choice::Attach {
                readonly: false,
                takeover_confirmed: true,
                ..
            }
        ));
        registry.forget_restore(2).unwrap();
        drop(next);
        drop(attempt);
        session.shutdown();
        session.wait_closed().await;
    }
    #[tokio::test]
    async fn remembered_attach_requires_actual_identity_and_successful_binding_and_can_be_disabled()
    {
        let dir = tempfile::tempdir().unwrap();
        crate::api::unlock_vault(
            dir.path()
                .join("restore.vault")
                .to_string_lossy()
                .into_owned(),
            "synthetic-tmux-master".into(),
        )
        .await
        .unwrap();
        let (session, _events) = ManagedSession::new(Size::new(80, 24).unwrap(), 10).unwrap();
        let session = Arc::new(session);
        let verification = Arc::new(Verification::default());
        let registry = Arc::new(TmuxRegistry::default());
        let attempt = verification.begin(session.clone()).unwrap();
        bind_policy(&attempt.scope());
        let first = registry
            .owner(attempt.scope())
            .for_target("host-00000000000000000000000000000002".into(), true);
        let (req, reply) = listed_request(123, 456);
        first.install(10, 1, req).unwrap();
        registry.answer(10, 1, remembered_selection()).unwrap();
        assert!(matches!(
            reply.await.unwrap(),
            Choice::Attach { readonly: true, .. }
        ));
        assert!(!registry.restore_enabled(1).unwrap());
        first.bind(
            1,
            Some(hspterm_ssh_core::tmux::TmuxState {
                readonly: true,
                size_locked: true,
            }),
            Some(listed_request(123, 456).0.listing.sessions[0].identity()),
        );
        assert!(registry.restore_enabled(1).unwrap());
        drop(first);
        drop(attempt);

        let attempt = verification.begin(session.clone()).unwrap();
        bind_policy(&attempt.scope());
        let second = registry
            .owner(attempt.scope())
            .for_target("host-00000000000000000000000000000002".into(), true);
        let (req, reply) = listed_request(123, 456);
        second.install(11, 2, req).unwrap();
        assert!(registry.token().is_none());
        assert!(matches!(
            reply.await.unwrap(),
            Choice::Attach {
                readonly: true,
                lock_size: true,
                ..
            }
        ));
        second.bind(
            2,
            Some(hspterm_ssh_core::tmux::TmuxState {
                readonly: true,
                size_locked: true,
            }),
            Some(listed_request(123, 456).0.listing.sessions[0].identity()),
        );
        drop(second);
        drop(attempt);

        for variant in 0..6 {
            let attempt = verification.begin(session.clone()).unwrap();
            bind_policy(&attempt.scope());
            let owner = registry.owner(attempt.scope()).for_target(
                if variant == 4 {
                    "host-00000000000000000000000000000003"
                } else {
                    "host-00000000000000000000000000000002"
                }
                .into(),
                variant != 5,
            );
            let (mut req, mut reply) = listed_request(
                if variant == 2 { 124 } else { 123 },
                if variant == 3 { 457 } else { 456 },
            );
            if variant == 0 {
                req.verified_host.sha256 = "synthetic-other-key".into();
            }
            if variant == 1 {
                req.username = "synthetic-other-account".into();
            }
            owner.install(12, 3, req).unwrap();
            assert_eq!(registry.token(), Some((12, 3)));
            assert!(reply.try_recv().is_err());
            drop(owner);
            drop(attempt);
        }
        let attempt = verification.begin(session.clone()).unwrap();
        bind_policy(&attempt.scope());
        let current = registry
            .owner(attempt.scope())
            .for_target("host-00000000000000000000000000000002".into(), true);
        let (req, reply) = listed_request(123, 456);
        current.install(13, 4, req).unwrap();
        reply.await.unwrap();
        assert!(registry.forget_restore(2).is_err());
        registry.forget_restore(4).unwrap();
        current.bind(
            4,
            Some(hspterm_ssh_core::tmux::TmuxState {
                readonly: true,
                size_locked: true,
            }),
            Some(listed_request(123, 456).0.listing.sessions[0].identity()),
        );
        assert!(!registry.restore_enabled(4).unwrap());
        drop(current);
        drop(attempt);

        let attempt = verification.begin(session.clone()).unwrap();
        bind_policy(&attempt.scope());
        let unbound = registry
            .owner(attempt.scope())
            .for_target("host-00000000000000000000000000000002".into(), true);
        let (req, reply) = listed_request(123, 456);
        unbound.install(14, 5, req).unwrap();
        registry.answer(14, 5, remembered_selection()).unwrap();
        reply.await.unwrap();
        drop(unbound);
        drop(attempt);
        assert!(!registry.restore_enabled(5).unwrap());
        session.shutdown();
        session.wait_closed().await;
    }
    #[tokio::test]
    async fn original_scope_one_use_answer_stale_owner_and_reopened_vault_never_redirect_a_choice()
    {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("tmux.vault");
        crate::api::unlock_vault(
            path.to_string_lossy().into_owned(),
            "synthetic-tmux-master".into(),
        )
        .await
        .unwrap();
        let (session, _events) = ManagedSession::new(Size::new(80, 24).unwrap(), 10).unwrap();
        let session = Arc::new(session);
        let verification = Arc::new(Verification::default());
        let attempt = verification.begin(session.clone()).unwrap();
        let scope = attempt.scope();
        let (keys, _) = mpsc::channel(1);
        with_vault(|v| {
            scope.policy(v, "127.0.0.1", 22, "trust-tmux-test".into(), false, keys)?;
            Ok(())
        })
        .unwrap();
        let registry = Arc::new(TmuxRegistry::default());
        let old = registry.owner(scope.clone());
        let (req, rx) = request();
        old.install(1, 1, req).unwrap();
        assert_eq!(registry.prompt(1).unwrap().generation, 1);
        assert!(registry.answer(2, 1, shell()).is_err());
        registry.invalidate();
        assert!(rx.await.is_err());
        let current = registry.owner(scope);
        let (req, rx) = request();
        current.install(2, 2, req).unwrap();
        drop(old);
        assert_eq!(registry.token(), Some((2, 2)));
        registry.answer(2, 2, shell()).unwrap();
        assert!(matches!(rx.await.unwrap(), Choice::Shell));
        assert!(registry.answer(2, 2, shell()).is_err());
        let (req, rx) = request();
        current.install(3, 3, req).unwrap();
        assert!(
            crate::api::unlock_vault(path.to_string_lossy().into_owned(), "wrong-password".into())
                .await
                .is_err()
        );
        assert!(registry.prompt(3).is_ok());
        crate::api::unlock_vault(
            path.to_string_lossy().into_owned(),
            "synthetic-tmux-master".into(),
        )
        .await
        .unwrap();
        assert!(registry.prompt(3).is_err());
        assert!(registry.answer(3, 3, shell()).is_err());
        registry.invalidate();
        assert!(rx.await.is_err());
        drop(current);
        drop(attempt);
        session.shutdown();
        session.wait_closed().await;
    }
}
