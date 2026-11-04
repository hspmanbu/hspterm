//! Per-original-Transport consent preparation. No secrets are returned to Dart.
//! Integration is staged as a batch; API registration and native tests follow.
use anyhow::{Context, Result, ensure};
use hspterm_ssh_core::{AgentConnector, AgentStatus};
use parking_lot::Mutex;
use sha2::{Digest, Sha256};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

#[derive(Clone)]
pub struct AgentView {
    pub phase: String,
    pub epoch: String,
    pub key_count: u16,
    pub expires_unix_millis: Option<u64>,
    pub failed_streams: u64,
}
impl From<AgentStatus> for AgentView {
    fn from(s: AgentStatus) -> Self {
        Self {
            phase: format!("{:?}", s.phase),
            epoch: s.epoch.to_string(),
            key_count: s.key_count,
            expires_unix_millis: s.expires_unix_millis,
            failed_streams: s.failed_streams,
        }
    }
}
#[derive(Clone)]
pub struct AgentKeyOption {
    pub host_id: String,
    pub name: String,
    pub fingerprint: Option<String>,
}
#[derive(Clone)]
pub struct AgentPreview {
    pub ticket: String,
    pub target: String,
    pub host_key: String,
    pub seconds: u32,
    pub keys: Vec<AgentKeyOption>,
}

#[derive(Clone)]
pub(crate) struct Binding {
    pub generation: u64,
    pub vault_scope: String,
    pub target: crate::transfers::Target,
    pub connector: AgentConnector,
    serial: u64,
}
#[derive(Clone)]
pub(crate) struct Selected {
    pub host_id: String,
    pub name: String,
    credential_id: String,
    tag: [u8; 32],
    pub fingerprint: String,
}
#[derive(Clone)]
pub(crate) struct Pending {
    pub ticket: String,
    pub binding: Binding,
    pub epoch: u64,
    pub seconds: u32,
    pub keys: Vec<Selected>,
    deadline: Instant,
    ready: bool,
}
struct State {
    serial: u64,
    binding: Option<Binding>,
    pending: Option<Pending>,
    authorized_sources: std::collections::BTreeSet<String>,
    monitor: CancellationToken,
    closed: bool,
}
pub(crate) struct AgentRegistry {
    operations: Arc<tokio::sync::Semaphore>,
    state: Mutex<State>,
    changed: watch::Sender<u64>,
}
impl Default for AgentRegistry {
    fn default() -> Self {
        let (changed, _) = watch::channel(0);
        Self {
            operations: Arc::new(tokio::sync::Semaphore::new(1)),
            state: Mutex::new(State {
                serial: 0,
                binding: None,
                pending: None,
                authorized_sources: Default::default(),
                monitor: CancellationToken::new(),
                closed: false,
            }),
            changed,
        }
    }
}
/// Agent preparation/approval has read access; switching the Vault has write
/// access. Owned guards follow blocking workers even if a caller disappears.
pub(crate) fn gate() -> Arc<tokio::sync::RwLock<()>> {
    static GATE: std::sync::OnceLock<Arc<tokio::sync::RwLock<()>>> = std::sync::OnceLock::new();
    GATE.get_or_init(|| Arc::new(tokio::sync::RwLock::new(())))
        .clone()
}
impl AgentRegistry {
    pub fn operation(self: &Arc<Self>) -> Result<tokio::sync::OwnedSemaphorePermit> {
        let state = self.state.lock();
        ensure!(!state.closed, "终端已关闭");
        self.operations
            .clone()
            .try_acquire_owned()
            .context("本终端正在准备或处理另一项 Agent 授权")
    }
    pub async fn wait_operations(&self) -> Result<()> {
        let _finished = self
            .operations
            .acquire()
            .await
            .context("Agent 操作门控已关闭")?;
        Ok(())
    }
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changed.subscribe()
    }
    fn notify(&self) {
        self.changed.send_modify(|n| *n = n.wrapping_add(1));
    }
    pub fn bind(
        self: &Arc<Self>,
        generation: u64,
        vault_scope: String,
        target: crate::transfers::Target,
        connector: AgentConnector,
    ) -> Result<()> {
        let (mut updates, stop, serial) = {
            let mut state = self.state.lock();
            ensure!(!state.closed, "终端已关闭");
            state.monitor.cancel();
            if let Some(previous) = &state.binding {
                previous.connector.invalidate_grant()?;
            }
            state.serial = state.serial.checked_add(1).context("Agent 作用域已耗尽")?;
            state.pending = None;
            state.authorized_sources.clear();
            state.monitor = CancellationToken::new();
            let updates = connector.watch();
            let serial = state.serial;
            state.binding = Some(Binding {
                generation,
                vault_scope,
                target,
                connector,
                serial,
            });
            (updates, state.monitor.clone(), serial)
        };
        self.notify();
        let registry = Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                tokio::select! { biased;
                    _ = stop.cancelled() => break,
                    result = updates.changed() => {
                        if result.is_err() { break; }
                        updates.borrow_and_update();
                        let Some(registry) = registry.upgrade() else { break; };
                        if registry.state.lock().binding.as_ref().is_none_or(|b| b.serial != serial) { break; }
                        registry.notify();
                    },
                }
            }
        });
        Ok(())
    }
    pub fn binding(&self, generation: u64) -> Result<Binding> {
        let state = self.state.lock();
        ensure!(!state.closed, "终端已关闭");
        state
            .binding
            .as_ref()
            .filter(|b| b.generation == generation)
            .cloned()
            .context("原 Agent 会话已失效")
    }
    /// Called under the same Vault gate as opening a replacement vault. A core
    /// epoch change closes the gap between final approval checks and async grant
    /// installation, without taking a Vault lock across a network/crypto await.
    pub fn invalidate(&self) -> Result<()> {
        let mut state = self.state.lock();
        state.pending = None;
        state.authorized_sources.clear();
        if let Some(binding) = &state.binding {
            binding.connector.invalidate_grant()?;
        }
        Ok(())
    }
    /// Same database/Transport after an explicit configuration restore. The
    /// caller revoked grants under the write gate before committing; rebinding
    /// proposal scope does not authorize any key or reconnect the SSH session.
    pub fn configuration_restored(&self, old_scope: &str, new_scope: &str) {
        let mut state = self.state.lock();
        if let Some(binding) = state
            .binding
            .as_mut()
            .filter(|b| b.vault_scope == old_scope)
        {
            binding.vault_scope = new_scope.into();
            state.pending = None;
            state.authorized_sources.clear();
        }
    }
    pub fn close(&self) -> Result<()> {
        let mut state = self.state.lock();
        state.closed = true;
        state.monitor.cancel();
        state.pending = None;
        if let Some(binding) = &state.binding {
            binding.connector.invalidate_grant()?;
        }
        Ok(())
    }
    pub fn reserve(&self, binding: Binding, ticket: String, seconds: u32) -> Result<Pending> {
        ensure!((1..=3600).contains(&seconds), "授权时长必须介于1和3600秒");
        let mut state = self.state.lock();
        ensure!(
            !state.closed
                && state
                    .binding
                    .as_ref()
                    .is_some_and(|b| b.serial == binding.serial),
            "原 Agent 会话已失效"
        );
        let status = binding.connector.status();
        ensure!(
            matches!(
                status.phase,
                hspterm_ssh_core::AgentPhase::Ready
                    | hspterm_ssh_core::AgentPhase::Active
                    | hspterm_ssh_core::AgentPhase::Expired
                    | hspterm_ssh_core::AgentPhase::Revoked
            ),
            "本连接未启用或服务器拒绝了 Agent 转发；需修改配置并明确重连"
        );
        let pending = Pending {
            ticket,
            binding,
            epoch: status.epoch,
            seconds,
            keys: Vec::new(),
            deadline: Instant::now() + Duration::from_secs(120),
            ready: false,
        };
        state.pending = Some(pending.clone());
        Ok(pending)
    }
    pub fn publish(&self, mut pending: Pending, keys: Vec<Selected>) -> Result<AgentPreview> {
        let mut state = self.state.lock();
        check_pending(&state, &pending, false)?;
        pending.keys = keys;
        pending.ready = true;
        let address = if pending.binding.target.address.contains(':')
            && !pending.binding.target.address.starts_with('[')
        {
            format!("[{}]", pending.binding.target.address)
        } else {
            pending.binding.target.address.clone()
        };
        let view = AgentPreview {
            ticket: pending.ticket.clone(),
            target: format!(
                "{}@{}:{}",
                pending.binding.target.username, address, pending.binding.target.port
            ),
            host_key: pending.binding.target.fingerprint.clone(),
            seconds: pending.seconds,
            keys: pending
                .keys
                .iter()
                .map(|k| AgentKeyOption {
                    host_id: k.host_id.clone(),
                    name: k.name.clone(),
                    fingerprint: Some(k.fingerprint.clone()),
                })
                .collect(),
        };
        state.pending = Some(pending);
        Ok(view)
    }
    pub fn pending(&self, ticket: &str) -> Result<Pending> {
        let state = self.state.lock();
        let pending = state
            .pending
            .as_ref()
            .filter(|p| p.ticket == ticket)
            .context("授权预览已失效，请重新选择密钥")?;
        check_pending(&state, pending, true)?;
        Ok(pending.clone())
    }
    pub fn consume(&self, pending: &Pending) -> Result<()> {
        let mut state = self.state.lock();
        check_pending(&state, pending, true)?;
        state
            .authorized_sources
            .extend(pending.keys.iter().map(|k| k.host_id.clone()));
        state.pending = None;
        Ok(())
    }
    pub fn granted(&self, pending: &Pending, epoch: u64) {
        let mut state = self.state.lock();
        if !state.closed
            && state.binding.as_ref().is_some_and(|b| {
                b.serial == pending.binding.serial && b.connector.status().epoch == epoch
            })
        {
            state.authorized_sources = pending.keys.iter().map(|k| k.host_id.clone()).collect();
        }
    }
    pub fn invalidate_sources(&self, ids: &[String]) -> Result<()> {
        let mut state = self.state.lock();
        if ids.iter().any(|id| {
            state.authorized_sources.contains(id)
                || state
                    .pending
                    .as_ref()
                    .is_some_and(|p| p.keys.iter().any(|k| &k.host_id == id))
        }) {
            state.pending = None;
            state.authorized_sources.clear();
            if let Some(binding) = &state.binding {
                binding.connector.invalidate_grant()?;
            }
        }
        Ok(())
    }
    pub fn cancel(&self, ticket: &str) {
        let mut state = self.state.lock();
        if state.pending.as_ref().is_some_and(|p| p.ticket == ticket) {
            state.pending = None;
        }
    }
}
impl Drop for AgentRegistry {
    fn drop(&mut self) {
        self.state.get_mut().monitor.cancel();
    }
}
fn check_pending(state: &State, pending: &Pending, ready: bool) -> Result<()> {
    ensure!(
        !state.closed
            && state
                .binding
                .as_ref()
                .is_some_and(|b| b.serial == pending.binding.serial)
            && state
                .pending
                .as_ref()
                .is_some_and(|p| p.ticket == pending.ticket && (!ready || p.ready))
            && Instant::now() < pending.deadline
            && pending.binding.connector.status().epoch == pending.epoch,
        "授权预览已失效，请重新确认"
    );
    Ok(())
}

fn credential_tag(credential: &hspterm_storage_sync::Credential) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(b"hspterm-agent-credential-v1");
    for part in [
        credential.secret.as_bytes(),
        credential
            .passphrase
            .as_deref()
            .map_or(&b""[..], str::as_bytes),
    ] {
        digest.update((part.len() as u64).to_be_bytes());
        digest.update(part);
    }
    digest.finalize().into()
}
pub(crate) fn selected(
    v: &mut hspterm_storage_sync::Vault,
    ids: &[String],
) -> Result<Vec<(Selected, hspterm_storage_sync::Credential)>> {
    ensure!(
        !ids.is_empty() && ids.len() <= 16,
        "请选择1至16个应用内密钥"
    );
    let mut seen = std::collections::BTreeSet::new();
    let repo = hspterm_storage_sync::Repository::new(v);
    ids.iter()
        .map(|id| {
            ensure!(seen.insert(id.clone()), "密钥选择重复");
            let host = repo.host(id)?.context("密钥所属主机已删除")?;
            ensure!(
                host.auth == hspterm_storage_sync::AuthMethod::PrivateKey,
                "所选主机没有私钥认证配置"
            );
            let credential_id = host.credential_id.context("主机密钥凭据缺失")?;
            let credential = repo.credential(id)?.context("主机密钥凭据缺失")?;
            ensure!(
                credential.secret.len() <= 256 * 1024
                    && credential
                        .passphrase
                        .as_ref()
                        .is_none_or(|s| s.len() <= 16 * 1024),
                "私钥内容超出 Agent 限制"
            );
            let proof = Selected {
                host_id: host.id,
                name: host.name,
                credential_id,
                tag: credential_tag(&credential),
                fingerprint: String::new(),
            };
            Ok((proof, credential))
        })
        .collect()
}
pub(crate) fn unchanged(v: &mut hspterm_storage_sync::Vault, proof: &[Selected]) -> Result<()> {
    let ids = proof.iter().map(|p| p.host_id.clone()).collect::<Vec<_>>();
    let current = selected(v, &ids)?;
    ensure!(
        current
            .iter()
            .zip(proof)
            .all(|((now, _), old)| now.credential_id == old.credential_id && now.tag == old.tag),
        "密钥凭据已修改，请重新预览授权"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{future::Future, task::Poll};

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn closing_waits_for_owned_blocking_work_even_if_its_caller_is_aborted() {
        let registry = Arc::new(AgentRegistry::default());
        let permit = registry.operation().unwrap();
        assert!(
            registry.operation().is_err(),
            "no concurrent key-decoding batches"
        );
        let (entered, ready) = tokio::sync::oneshot::channel();
        let (release, hold) = std::sync::mpsc::channel();
        let caller = tokio::spawn(async move {
            tokio::task::spawn_blocking(move || {
                let _owned = permit;
                entered.send(()).unwrap();
                hold.recv().unwrap();
            })
            .await
            .unwrap();
        });
        ready.await.unwrap();
        caller.abort();
        assert!(caller.await.unwrap_err().is_cancelled());
        registry.close().unwrap();
        assert!(registry.operation().is_err());
        let mut closing = Box::pin(registry.wait_operations());
        std::future::poll_fn(|cx| {
            assert!(
                closing.as_mut().poll(cx).is_pending(),
                "private worker still owns its gate"
            );
            Poll::Ready(())
        })
        .await;
        release.send(()).unwrap();
        closing.await.unwrap();
    }

    #[tokio::test]
    async fn vault_switch_excludes_existing_and_later_preparations() {
        let preparation = gate().read_owned().await;
        let mut switching = Box::pin(gate().write_owned());
        std::future::poll_fn(|cx| {
            assert!(switching.as_mut().poll(cx).is_pending());
            Poll::Ready(())
        })
        .await;
        let mut late = Box::pin(gate().read_owned());
        std::future::poll_fn(|cx| {
            assert!(
                late.as_mut().poll(cx).is_pending(),
                "queued switch must precede later preparation"
            );
            Poll::Ready(())
        })
        .await;
        drop(preparation);
        let switched = switching.await;
        std::future::poll_fn(|cx| {
            assert!(late.as_mut().poll(cx).is_pending());
            Poll::Ready(())
        })
        .await;
        drop(switched);
        let _prepared_again = late.await;
    }
}
