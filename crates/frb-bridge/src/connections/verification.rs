//! At most two host-key slots, captured before networking and revoked on cancel.
//! Never derive a trust destination from mutable host metadata or the peer.
use super::*;
use hspterm_ssh_core::{HostKeyRequest, ManagedSession, SessionPhase};
use parking_lot::Mutex;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, Ordering},
};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

static NEXT: AtomicU64 = AtomicU64::new(1);
#[derive(Clone)]
struct Slot {
    tag: u64,
    address: String,
    port: u16,
    identity: String,
    jump: bool,
}
struct Active {
    id: u64,
    cancel: CancellationToken,
    slots: Vec<Slot>,
    vault_scope: Option<String>,
}
#[derive(Default)]
pub(crate) struct Verification {
    active: Mutex<Option<Active>>,
    closed: AtomicBool,
}

pub(crate) struct Attempt {
    scope: Scope,
    session: Arc<ManagedSession>,
    pub cancel: CancellationToken,
}
#[derive(Clone)]
pub(crate) struct Scope {
    state: Arc<Verification>,
    id: u64,
}
impl Verification {
    pub fn begin(self: &Arc<Self>, session: Arc<ManagedSession>) -> Result<Attempt> {
        let mut guard = self.active.lock();
        if self.closed.load(Ordering::Acquire)
            || guard.is_some()
            || matches!(
                session.status().phase,
                SessionPhase::Connecting | SessionPhase::Connected | SessionPhase::Closed
            )
        {
            anyhow::bail!("会话正在连接、已连接或已关闭");
        }
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let cancel = CancellationToken::new();
        *guard = Some(Active {
            id,
            cancel: cancel.clone(),
            slots: Vec::with_capacity(2),
            vault_scope: None,
        });
        Ok(Attempt {
            scope: Scope {
                state: self.clone(),
                id,
            },
            session,
            cancel,
        })
    }
    /// Called under the Vault gate on a successful reopen/switch. Drop old
    /// confirmation rights, without cancelling already trusted SSH transports.
    pub fn vault_replaced(&self) {
        if let Some(active) = self.active.lock().as_mut() {
            active.slots.clear();
        }
    }
    pub fn cancel(&self) {
        if let Some(active) = self.active.lock().as_mut() {
            active.cancel.cancel();
            active.slots.clear();
        }
    }
    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
        self.cancel();
    }
    fn slot<'a>(active: &'a Option<Active>, request: &HostKeyRequest) -> Option<&'a Slot> {
        active
            .as_ref()
            .filter(|a| !a.cancel.is_cancelled())?
            .slots
            .iter()
            .find(|s| {
                request.context == Some(s.tag)
                    && request.key.address == s.address
                    && request.key.port == s.port
                    && !request.decision.is_closed()
            })
    }
    pub fn is_jump(&self, request: &HostKeyRequest) -> Option<bool> {
        Self::slot(&self.active.lock(), request).map(|s| s.jump)
    }
    /// Called with the vault lock first; never hold this guard across an await.
    pub fn answer(
        &self,
        v: &mut hspterm_storage_sync::Vault,
        request: HostKeyRequest,
        accept: bool,
    ) -> Result<()> {
        let guard = self.active.lock();
        anyhow::ensure!(
            guard.as_ref().and_then(|a| a.vault_scope.as_deref()) == Some(v.instance_id()),
            "原连接配置库已改变；指纹未写入其他配置库"
        );
        let slot = Self::slot(&guard, &request).context("原连接指纹请求已取消或失效")?;
        if accept {
            crate::api::remember_host_key(v, &slot.identity, &request.key.sha256)?;
        }
        request
            .decision
            .send(accept)
            .map_err(|_| anyhow::anyhow!("连接确认已取消"))
    }
}
impl Attempt {
    pub fn scope(&self) -> Scope {
        self.scope.clone()
    }
}
impl Drop for Attempt {
    fn drop(&mut self) {
        let mut guard = self.scope.state.active.lock();
        if guard.as_ref().is_some_and(|s| s.id == self.scope.id) {
            self.cancel.cancel();
            // A later attempt cannot begin until this one has released its slot.
            // This cancels only a still-Connecting actor, never a logged-in SSH.
            self.session.cancel_connect();
            *guard = None;
        }
    }
}
impl Scope {
    pub(crate) fn check(&self, v: &hspterm_storage_sync::Vault) -> Result<()> {
        let guard = self.state.active.lock();
        let active = guard
            .as_ref()
            .filter(|s| s.id == self.id && !s.cancel.is_cancelled())
            .context("原连接选择已取消")?;
        anyhow::ensure!(
            active.vault_scope.as_deref() == Some(v.instance_id()),
            "原连接配置库已改变"
        );
        Ok(())
    }
    pub fn policy(
        &self,
        v: &mut hspterm_storage_sync::Vault,
        address: &str,
        port: u16,
        identity: String,
        jump: bool,
        requests: mpsc::Sender<HostKeyRequest>,
    ) -> Result<HostKeyPolicy> {
        let pinned = v
            .get(&identity)?
            .map(|raw| String::from_utf8(raw.to_vec()))
            .transpose()?;
        let mut guard = self.state.active.lock();
        let active = guard
            .as_mut()
            .filter(|s| s.id == self.id && !s.cancel.is_cancelled())
            .context("连接已取消")?;
        if let Some(previous) = &active.vault_scope {
            anyhow::ensure!(previous == v.instance_id(), "原连接配置库已改变");
        } else {
            active.vault_scope = Some(v.instance_id().to_owned());
        }
        if let Some(sha256) = pinned {
            return Ok(HostKeyPolicy::Pinned { sha256 });
        }
        anyhow::ensure!(active.slots.len() < 2, "主机指纹验证槽已用完");
        let tag = NEXT.fetch_add(1, Ordering::Relaxed);
        active.slots.push(Slot {
            tag,
            address: address.into(),
            port,
            identity,
            jump,
        });
        Ok(HostKeyPolicy::ConfirmTagged {
            requests,
            context: tag,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hspterm_ssh_core::HostKey;
    use hspterm_term_core::Size;
    use tokio::sync::oneshot;

    #[tokio::test]
    async fn cancelled_confirmation_cannot_store_into_a_later_route_even_with_identical_endpoints()
    {
        let dir = tempfile::tempdir().unwrap();
        let mut v = hspterm_storage_sync::Vault::create(&dir.path().join("v"), b"synthetic-master")
            .unwrap();
        let (session, _) = ManagedSession::new(Size::new(80, 24).unwrap(), 0).unwrap();
        let session = Arc::new(session);
        let state = Arc::new(Verification::default());
        let (tx, _) = mpsc::channel(1);
        let first = state.begin(session.clone()).unwrap();
        let policy = first
            .scope()
            .policy(
                &mut v,
                "10.0.0.1",
                22,
                "trust-jump-old".into(),
                false,
                tx.clone(),
            )
            .unwrap();
        let HostKeyPolicy::ConfirmTagged { context, .. } = policy else {
            panic!()
        };
        let (decision, response) = oneshot::channel();
        let request = HostKeyRequest {
            context: Some(context),
            key: HostKey {
                address: "10.0.0.1".into(),
                port: 22,
                algorithm: "ssh-ed25519".into(),
                sha256: "SHA256:synthetic-old".into(),
            },
            decision,
        };
        assert_eq!(state.is_jump(&request), Some(false));
        state.cancel();
        assert!(state.begin(session.clone()).is_err());
        assert_eq!(state.is_jump(&request), None);
        drop(first);
        let next = state.begin(session.clone()).unwrap();
        next.scope()
            .policy(&mut v, "10.0.0.1", 22, "trust-jump-new".into(), false, tx)
            .unwrap();
        assert!(state.answer(&mut v, request, true).is_err());
        assert!(response.await.is_err());
        assert!(v.get("trust-jump-old").unwrap().is_none());
        assert!(v.get("trust-jump-new").unwrap().is_none());
        drop(next);
        state.close();
        assert!(
            state.begin(session.clone()).is_err(),
            "destroyed entry cannot begin another preparation"
        );
        session.shutdown();
        session.wait_closed().await;
    }

    #[tokio::test]
    async fn same_endpoint_jump_and_target_have_distinct_slots_and_only_their_captured_trust_is_saved()
     {
        let dir = tempfile::tempdir().unwrap();
        let mut v = hspterm_storage_sync::Vault::create(&dir.path().join("v"), b"synthetic-master")
            .unwrap();
        let (session, _) = ManagedSession::new(Size::new(80, 24).unwrap(), 0).unwrap();
        let session = Arc::new(session);
        let state = Arc::new(Verification::default());
        let attempt = state.begin(session.clone()).unwrap();
        let scope = attempt.scope();
        let (tx, _) = mpsc::channel(1);
        for (jump, identity) in [
            (true, "trust-synthetic-jump"),
            (false, "trust-synthetic-target"),
        ] {
            let p = scope
                .policy(&mut v, "127.0.0.1", 22, identity.into(), jump, tx.clone())
                .unwrap();
            let HostKeyPolicy::ConfirmTagged { context, .. } = p else {
                panic!()
            };
            let (decision, response) = oneshot::channel();
            let request = HostKeyRequest {
                context: Some(context),
                key: HostKey {
                    address: "127.0.0.1".into(),
                    port: 22,
                    algorithm: "ssh-ed25519".into(),
                    sha256: "SHA256:synthetic-key".into(),
                },
                decision,
            };
            assert_eq!(state.is_jump(&request), Some(jump));
            state.answer(&mut v, request, true).unwrap();
            assert!(response.await.unwrap());
            assert_eq!(
                v.get(identity).unwrap().unwrap().as_slice(),
                b"SHA256:synthetic-key"
            );
        }
        assert!(
            scope
                .policy(&mut v, "other.invalid", 22, "trust-third".into(), false, tx)
                .is_err()
        );
        drop(attempt);
        session.shutdown();
        session.wait_closed().await;
    }
    #[tokio::test]
    async fn pending_keys_and_route_preparation_cannot_write_a_different_or_reopened_vault() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("first");
        let mut first = hspterm_storage_sync::Vault::create(&path, b"synthetic-master").unwrap();
        let mut other = hspterm_storage_sync::Vault::create(
            &directory.path().join("other"),
            b"synthetic-master",
        )
        .unwrap();
        let mut reopened = hspterm_storage_sync::Vault::open(&path, b"synthetic-master").unwrap();
        let (session, _) = ManagedSession::new(Size::new(80, 24).unwrap(), 0).unwrap();
        let session = Arc::new(session);
        let state = Arc::new(Verification::default());
        let attempt = state.begin(session.clone()).unwrap();
        let scope = attempt.scope();
        let (requests, _) = mpsc::channel(1);
        let HostKeyPolicy::ConfirmTagged { context, .. } = scope
            .policy(
                &mut first,
                "fixture.invalid",
                22,
                "trust-original".into(),
                false,
                requests.clone(),
            )
            .unwrap()
        else {
            panic!()
        };
        for vault in [&mut other, &mut reopened] {
            assert!(
                scope
                    .policy(
                        vault,
                        "fixture.invalid",
                        22,
                        "trust-other".into(),
                        true,
                        requests.clone()
                    )
                    .is_err()
            );
            let (decision, response) = oneshot::channel();
            let request = HostKeyRequest {
                context: Some(context),
                key: HostKey {
                    address: "fixture.invalid".into(),
                    port: 22,
                    algorithm: "ssh-ed25519".into(),
                    sha256: "SHA256:synthetic".into(),
                },
                decision,
            };
            assert!(state.answer(vault, request, true).is_err());
            assert!(response.await.is_err());
            assert!(vault.get("trust-original").unwrap().is_none());
        }
        assert!(first.get("trust-original").unwrap().is_none());
        state.vault_replaced();
        let (decision, response) = oneshot::channel();
        assert!(
            state
                .answer(
                    &mut first,
                    HostKeyRequest {
                        context: Some(context),
                        key: HostKey {
                            address: "fixture.invalid".into(),
                            port: 22,
                            algorithm: "ssh-ed25519".into(),
                            sha256: "SHA256:synthetic".into()
                        },
                        decision
                    },
                    true
                )
                .is_err()
        );
        assert!(response.await.is_err());
        assert!(first.get("trust-original").unwrap().is_none());
        drop(attempt);
        session.shutdown();
        session.wait_closed().await;
    }
}
