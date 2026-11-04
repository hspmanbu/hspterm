//! Per-terminal runtime ownership, separate from encrypted saved rules.
use anyhow::{Context, Result, bail};
use hspterm_ssh_core::{
    ManagedSession, RemoteConnector, RemoteForward, SessionPhase, TcpConnector,
    forwarding::{ForwardStatus, LocalForward},
    remote_forward::{RemotePhase, RemoteStatus},
};
use hspterm_storage_sync::forwarding_rules::{ForwardKind, Rule};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Mutex, watch};

#[derive(Clone)]
pub struct RunStatus {
    pub token: String,
    pub generation: u64,
    pub rule_id: String,
    pub name: String,
    pub kind: String,
    pub phase: String,
    pub bind_address: Option<String>,
    pub bind_port: Option<u32>,
    pub accepted: u64,
    pub active: u32,
    pub failed: u64,
    pub last_error: Option<String>,
}
enum Resource {
    Local {
        owner: Mutex<LocalForward>,
        state: watch::Receiver<ForwardStatus>,
    },
    Remote(RemoteForward),
}
enum ForwardingWatch {
    Local(watch::Receiver<ForwardStatus>),
    Remote(watch::Receiver<RemoteStatus>),
}
impl ForwardingWatch {
    async fn changed(&mut self) -> bool {
        match self {
            Self::Local(rx) => rx.changed().await.is_ok(),
            Self::Remote(rx) => rx.changed().await.is_ok(),
        }
    }
    fn finished(&self) -> bool {
        match self {
            Self::Local(rx) => rx.borrow().stopped,
            Self::Remote(rx) => matches!(
                rx.borrow().phase,
                RemotePhase::Stopped | RemotePhase::Failed | RemotePhase::Disconnected
            ),
        }
    }
}
impl Resource {
    fn updates(&self) -> ForwardingWatch {
        match self {
            Self::Local { state, .. } => ForwardingWatch::Local(state.clone()),
            Self::Remote(owner) => ForwardingWatch::Remote(owner.subscribe()),
        }
    }
}
struct RuntimeInstance {
    token: String,
    generation: u64,
    rule: Rule,
    resource: Resource,
}
impl RuntimeInstance {
    fn status(&self) -> RunStatus {
        let (phase, bind, accepted, active, failed, error) = match &self.resource {
            Resource::Local { state, .. } => {
                let producer_closed = state.has_changed().is_err();
                let state = state.borrow();
                (
                    if state.stopped {
                        "stopped"
                    } else if producer_closed {
                        "failed"
                    } else {
                        "listening"
                    },
                    Some(self.rule.bind),
                    state.accepted,
                    state.active,
                    state.failed,
                    state.last_error.clone().or_else(|| {
                        (producer_closed && !state.stopped)
                            .then(|| "转发任务异常退出，监听已关闭".into())
                    }),
                )
            }
            Resource::Remote(owner) => {
                let state = owner.status();
                let phase = match state.phase {
                    RemotePhase::Starting => "starting",
                    RemotePhase::Listening => "listening",
                    RemotePhase::Stopping => "stopping",
                    RemotePhase::CleanupPending => "cleanupPending",
                    RemotePhase::CleanupDenied => "cleanupDenied",
                    RemotePhase::Stopped => "stopped",
                    RemotePhase::Failed => "failed",
                    RemotePhase::Disconnected => "disconnected",
                };
                (
                    phase,
                    state.address,
                    state.accepted,
                    state.active,
                    state.failed,
                    state.last_error.or_else(|| {
                        state.started.and_then(Result::err).map(|failure| {
                            match failure {
                                hspterm_ssh_core::remote_forward::RemoteFailure::Cancelled => {
                                    "转发启动已取消"
                                }
                                hspterm_ssh_core::remote_forward::RemoteFailure::Timeout => {
                                    "转发启动超时；迟到监听仍在清理"
                                }
                                hspterm_ssh_core::remote_forward::RemoteFailure::Denied => {
                                    "远端拒绝转发监听请求"
                                }
                                hspterm_ssh_core::remote_forward::RemoteFailure::Disconnected => {
                                    "原SSH连接已断开"
                                }
                                hspterm_ssh_core::remote_forward::RemoteFailure::Worker => {
                                    "远端返回的转发分配无效"
                                }
                            }
                            .into()
                        })
                    }),
                )
            }
        };
        RunStatus {
            token: self.token.clone(),
            generation: self.generation,
            rule_id: self.rule.id.clone(),
            name: self.rule.name.clone(),
            kind: match self.rule.kind {
                ForwardKind::Local => "local",
                ForwardKind::Remote => "remote",
                ForwardKind::Dynamic => "dynamic",
            }
            .into(),
            phase: phase.into(),
            bind_address: bind.map(|a| a.ip().to_string()),
            bind_port: bind.map(|a| u32::from(a.port())),
            accepted,
            active,
            failed,
            last_error: error,
        }
    }
    fn ended(&self) -> bool {
        matches!(
            self.status().phase.as_str(),
            "stopped" | "failed" | "disconnected"
        )
    }
    async fn stop(&self) -> Result<()> {
        match &self.resource {
            Resource::Local { owner, .. } => owner.lock().await.stop().await?,
            Resource::Remote(owner) => owner.stop().await?,
        }
        Ok(())
    }
}
struct RuntimeCatalog {
    serial: u64,
    jobs: Vec<Arc<RuntimeInstance>>,
    restoration_failures: Vec<RunStatus>,
}
pub(crate) struct ForwardingRegistry {
    state: Mutex<RuntimeCatalog>,
    closed: AtomicBool,
    closing: AtomicUsize,
    revision: watch::Sender<u64>,
}
/// Held through the enclosing SSH disconnect/exit, including its failure path.
/// Drop restores admission only after all overlapping non-permanent closers end.
pub(crate) struct ForwardingCloseGuard(Arc<ForwardingRegistry>);
impl Drop for ForwardingCloseGuard {
    fn drop(&mut self) {
        self.0.closing.fetch_sub(1, Ordering::AcqRel);
    }
}
#[derive(Default)]
pub(crate) struct ShutdownReport {
    pub errors: Vec<String>,
    pub remote_unconfirmed: usize,
}

impl Default for ForwardingRegistry {
    fn default() -> Self {
        Self {
            state: Mutex::new(RuntimeCatalog {
                serial: 0,
                jobs: vec![],
                restoration_failures: vec![],
            }),
            closed: AtomicBool::new(false),
            closing: AtomicUsize::new(0),
            revision: watch::channel(0).0,
        }
    }
}
enum Capability {
    Local(TcpConnector),
    Remote(RemoteConnector),
}
impl ForwardingRegistry {
    pub async fn start(
        self: &Arc<Self>,
        terminal: u32,
        generation: u64,
        session: Arc<ManagedSession>,
        mut rule: Rule,
    ) -> Result<RunStatus> {
        if self.blocked() {
            bail!("终端正在关闭端口转发");
        }
        // Acquire transport capabilities outside our gate. No remote response
        // may delay the PTY actor or prevent disconnect from closing its root.
        let cap = match rule.kind {
            ForwardKind::Remote => Capability::Remote(session.remote_connector().await?),
            _ => Capability::Local(session.tcp_connector().await?),
        };
        let mut state = self.state.lock().await;
        if self.blocked() {
            bail!("终端正在关闭端口转发");
        }
        let status = session.status();
        if status.phase != SessionPhase::Connected || status.generation != generation {
            bail!("原SSH会话已失效；未启动转发");
        }
        state.jobs.retain(|job| !job.ended());
        if state.jobs.len() >= 32
            || state
                .jobs
                .iter()
                .any(|j| j.generation == generation && j.rule.id == rule.id)
        {
            bail!("转发已启动、正在清理或达到本会话容量");
        }
        let serial = state.serial.checked_add(1).context("转发标识容量已满")?;
        let target = || rule.target.as_ref().context("固定转发必须明确指定目标");
        let timeout = Duration::from_secs(10);
        let resource = match cap {
            Capability::Remote(cap) => {
                let t = target()?;
                Resource::Remote(cap.listen(rule.bind, t.address.clone(), t.port, timeout)?)
            }
            Capability::Local(cap) => {
                // Only an explicit literal SocketAddr bind is awaited while
                // holding the gate; no DNS/SSH/channel/target IO is done here.
                let owner = if rule.kind == ForwardKind::Dynamic {
                    LocalForward::socks5(cap, rule.bind, timeout).await?
                } else {
                    let t = target()?;
                    LocalForward::start(cap, rule.bind, t.address.clone(), t.port, timeout).await?
                };
                rule.bind = owner.local_addr(); // Actual local port, runtime only.
                Resource::Local {
                    state: owner.subscribe(),
                    owner: Mutex::new(owner),
                }
            }
        };
        state.serial = serial;
        state
            .restoration_failures
            .retain(|failure| failure.generation != generation || failure.rule_id != rule.id);
        let updates = resource.updates();
        let job = Arc::new(RuntimeInstance {
            token: format!("forward-{terminal}-{generation}-{serial}"),
            generation,
            rule,
            resource,
        });
        let snapshot = job.status();
        state.jobs.push(job);
        drop(state);
        self.invalidate();
        tokio::spawn(observe(Arc::downgrade(self), updates));
        Ok(snapshot)
    }
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.revision.subscribe()
    }
    fn invalidate(&self) {
        self.revision
            .send_modify(|value| *value = value.wrapping_add(1));
    }
    pub async fn list(&self) -> Vec<RunStatus> {
        let state = self.state.lock().await;
        state
            .jobs
            .iter()
            .map(|j| j.status())
            .chain(state.restoration_failures.iter().cloned())
            .collect()
    }
    /// Called only by an explicit successful SSH reconnect, with rules captured
    /// from that connection attempt's original vault. Failure is metadata, not
    /// an SSH failure; each eligible rule gets one attempt on this generation.
    pub async fn restore(
        self: &Arc<Self>,
        terminal: u32,
        generation: u64,
        session: Arc<ManagedSession>,
        rules: Result<Vec<Rule>, String>,
    ) {
        self.state.lock().await.restoration_failures.clear();
        let rules = match rules {
            Ok(rules) => rules,
            Err(message) => {
                self.restoration_failed(terminal, generation, &session, None, message)
                    .await;
                return;
            }
        };
        for rule in rules
            .into_iter()
            .filter(|r| r.enabled && r.restore_on_reconnect)
        {
            if let Err(error) = self
                .start(terminal, generation, session.clone(), rule.clone())
                .await
            {
                // A user can explicitly start the same rule as Connected is
                // published. Reuse that original instance, never duplicate it
                // or label an already running rule as a restoration failure.
                if self.state.lock().await.jobs.iter().any(|job| {
                    job.generation == generation && job.rule.id == rule.id && !job.ended()
                }) {
                    continue;
                }
                self.restoration_failed(
                    terminal,
                    generation,
                    &session,
                    Some(&rule),
                    error.to_string(),
                )
                .await;
            }
        }
    }
    async fn restoration_failed(
        &self,
        terminal: u32,
        generation: u64,
        session: &ManagedSession,
        rule: Option<&Rule>,
        message: String,
    ) {
        let mut state = self.state.lock().await;
        let current = session.status();
        if self.blocked()
            || current.phase != SessionPhase::Connected
            || current.generation != generation
        {
            return;
        }
        // These are failed restoration attempts, never fabricated listeners.
        // There are at most 32 configured attempts (or one configuration error).
        state.restoration_failures.push(RunStatus {
            token: format!(
                "restore-error-{terminal}-{generation}-{}",
                rule.map_or("config", |r| &r.id)
            ),
            generation,
            rule_id: rule.map_or_else(String::new, |r| r.id.clone()),
            name: rule.map_or_else(
                || "转发配置恢复".into(),
                |r| format!("{} · 恢复失败", r.name),
            ),
            kind: rule
                .map_or("configuration", |r| match r.kind {
                    ForwardKind::Local => "local",
                    ForwardKind::Remote => "remote",
                    ForwardKind::Dynamic => "dynamic",
                })
                .into(),
            phase: "failed".into(),
            bind_address: None,
            bind_port: None,
            accepted: 0,
            active: 0,
            failed: 1,
            last_error: Some(message),
        });
        drop(state);
        self.invalidate();
    }
    pub async fn stop(&self, token: &str, generation: u64) -> Result<()> {
        let job = self
            .state
            .lock()
            .await
            .jobs
            .iter()
            .find(|j| j.token == token && j.generation == generation)
            .cloned()
            .context("转发不属于原终端代次")?;
        job.stop().await
    }
    fn blocked(&self) -> bool {
        self.closed.load(Ordering::Acquire) || self.closing.load(Ordering::Acquire) != 0
    }
    pub fn closing(self: &Arc<Self>, permanent: bool) -> ForwardingCloseGuard {
        if permanent {
            self.closed.store(true, Ordering::Release);
        }
        self.closing.fetch_add(1, Ordering::AcqRel);
        ForwardingCloseGuard(self.clone())
    }
    /// The enclosing caller must keep ForwardingCloseGuard alive, close the original SSH
    /// root, then retire that generation. A remote cancel timeout/denial remains
    /// unknown here; it is not relabelled as an acknowledged stopped listener.
    pub async fn stop_all(&self) -> ShutdownReport {
        let jobs = self.state.lock().await.jobs.clone();
        let mut stops = tokio::task::JoinSet::new();
        for job in jobs {
            stops.spawn(async move {
                let remote = matches!(&job.resource, Resource::Remote(_));
                let result = match &job.resource {
                    Resource::Local { owner, .. } => owner.lock().await.stop().await,
                    Resource::Remote(owner) => owner.stop().await,
                };
                (remote, result)
            });
        }
        let mut report = ShutdownReport::default();
        while let Some(result) = stops.join_next().await {
            match result {
                Ok((_, Ok(()))) => {}
                Ok((
                    true,
                    Err(
                        hspterm_ssh_core::SshError::Timeout(_)
                        | hspterm_ssh_core::SshError::RequestDenied(_)
                        | hspterm_ssh_core::SshError::Disconnected
                        | hspterm_ssh_core::SshError::Cancelled,
                    ),
                )) => report.remote_unconfirmed += 1,
                Ok((_, Err(error))) => report.errors.push(error.to_string()),
                Err(_) => report.errors.push("转发清理任务异常".into()),
            }
        }
        report
    }
    /// Only after this generation's root has closed. A newer generation must
    /// never have its owners retired by a late older disconnect completion.
    pub async fn retired(&self, generation: u64, session: &ManagedSession) -> Result<()> {
        let status = session.status();
        if status.phase == SessionPhase::Connected && status.generation == generation {
            bail!("原SSH仍在线，不能丢弃转发所有者");
        }
        let mut state = self.state.lock().await;
        state.jobs.retain(|j| j.generation != generation);
        state
            .restoration_failures
            .retain(|j| j.generation != generation);
        Ok(())
    }
}

// The observer owns only a watch receiver and a Weak registry, never a
// forwarding owner, SSH capability or terminal. No self-retaining task cycle.
async fn observe(registry: std::sync::Weak<ForwardingRegistry>, mut updates: ForwardingWatch) {
    loop {
        let changed = updates.changed().await;
        let Some(registry) = registry.upgrade() else {
            break;
        };
        registry.invalidate();
        if !changed || updates.finished() {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn overlapping_close_guards_resume_only_after_last_drop_and_permanent_close_never_reopens() {
        let registry = Arc::new(ForwardingRegistry::default());
        assert!(!registry.blocked());
        let first = registry.closing(false);
        let second = registry.closing(false);
        assert!(registry.blocked());
        drop(first);
        assert!(registry.blocked());
        drop(second);
        assert!(!registry.blocked());
        let permanent = registry.closing(true);
        drop(permanent);
        assert!(registry.blocked());
    }
    #[tokio::test]
    async fn metadata_observation_has_no_idle_tick_and_finishes_when_the_rule_ends() {
        let registry = Arc::new(ForwardingRegistry::default());
        let mut changed = registry.subscribe();
        let (sender, receiver) = watch::channel(ForwardStatus::default());
        let observer = tokio::spawn(observe(
            Arc::downgrade(&registry),
            ForwardingWatch::Local(receiver),
        ));
        assert!(
            tokio::time::timeout(Duration::from_millis(20), changed.changed())
                .await
                .is_err()
        );
        sender.send_modify(|s| s.active = 1);
        tokio::time::timeout(Duration::from_secs(1), changed.changed())
            .await
            .unwrap()
            .unwrap();
        assert!(*changed.borrow_and_update() > 0);
        sender.send_modify(|s| s.stopped = true);
        tokio::time::timeout(Duration::from_secs(1), observer)
            .await
            .unwrap()
            .unwrap();
        changed.borrow_and_update();
        assert!(
            tokio::time::timeout(Duration::from_millis(20), changed.changed())
                .await
                .is_err()
        );
    }
    #[tokio::test]
    async fn observers_do_not_retain_the_registry_or_wait_forever_after_producer_drop() {
        let registry = Arc::new(ForwardingRegistry::default());
        let weak = Arc::downgrade(&registry);
        let (sender, receiver) = watch::channel(ForwardStatus::default());
        let observer = tokio::spawn(observe(weak.clone(), ForwardingWatch::Local(receiver)));
        tokio::task::yield_now().await;
        drop(registry);
        assert!(weak.upgrade().is_none());
        drop(sender);
        tokio::time::timeout(Duration::from_secs(1), observer)
            .await
            .unwrap()
            .unwrap();
    }
    #[tokio::test]
    async fn closing_rejects_late_start_before_requesting_an_actor_capability() {
        let registry = Arc::new(ForwardingRegistry::default());
        let (session, _events) =
            ManagedSession::new(hspterm_term_core::Size::new(80, 24).unwrap(), 100).unwrap();
        let session = Arc::new(session);
        let guard = registry.closing(true);
        let rule = Rule::new("late".into(), ForwardKind::Dynamic, None);
        assert!(registry.start(1, 0, session.clone(), rule).await.is_err());
        assert!(registry.list().await.is_empty());
        drop(guard);
        session.shutdown();
        session.wait_closed().await;
    }
}
