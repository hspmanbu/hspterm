//! Original-transport Agent authorization and bounded incoming service.
//! Keys are exposed only by explicit, original-connection, time-limited grants.
use crate::{
    SshError, agent_protocol,
    agent_signer::{AgentAuthority, AgentSigner},
};
use parking_lot::Mutex;
use russh::{Channel, ChannelOpenFailure, client, keys::PrivateKey};
use std::{
    sync::Arc,
    time::{Duration, UNIX_EPOCH},
};
use tokio::{
    sync::{Semaphore, watch},
    task::JoinSet,
};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentStatus {
    pub epoch: u64,
    pub phase: AgentPhase,
    pub key_count: u16,
    pub expires_unix_millis: Option<u64>,
    pub failed_streams: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgentPhase {
    NotRequested,
    Ready,
    Denied,
    Active,
    Expired,
    Revoked,
    Closed,
    Failed,
}
struct State {
    endpoint_accepted: bool,
    status: AgentStatus,
    signer: Option<AgentSigner>,
}
struct Owner {
    epoch: u64,
    authority: AgentAuthority,
}
struct Tasks {
    jobs: JoinSet<()>,
    failed: bool,
    closed: bool,
}
pub(crate) struct AgentRouter {
    root: CancellationToken,
    state: Mutex<State>,
    owner: tokio::sync::Mutex<Option<Owner>>,
    streams: Arc<Semaphore>,
    tasks: Mutex<Tasks>,
    changed: watch::Sender<AgentStatus>,
}
#[derive(Clone)]
pub struct AgentConnector {
    router: Arc<AgentRouter>,
}
impl AgentRouter {
    pub(crate) fn new(root: CancellationToken) -> Arc<Self> {
        let status = AgentStatus {
            epoch: 0,
            phase: AgentPhase::NotRequested,
            key_count: 0,
            expires_unix_millis: None,
            failed_streams: 0,
        };
        let (changed, _) = watch::channel(status.clone());
        Arc::new(Self {
            root: root.child_token(),
            state: Mutex::new(State {
                endpoint_accepted: false,
                status,
                signer: None,
            }),
            owner: tokio::sync::Mutex::new(None),
            streams: Arc::new(Semaphore::new(4)),
            tasks: Mutex::new(Tasks {
                jobs: JoinSet::new(),
                failed: false,
                closed: false,
            }),
            changed,
        })
    }
    fn publish(&self, state: &State) {
        self.changed.send_if_modified(|old| {
            if *old == state.status {
                false
            } else {
                *old = state.status.clone();
                true
            }
        });
    }
    pub(crate) fn endpoint_result(&self, accepted: bool) {
        let mut state = self.state.lock();
        if self.root.is_cancelled() {
            return;
        }
        state.endpoint_accepted = accepted;
        state.status.phase = if accepted {
            AgentPhase::Ready
        } else {
            AgentPhase::Denied
        };
        self.publish(&state);
    }
    fn spawn(&self, work: impl std::future::Future<Output = ()> + Send + 'static) {
        let mut tasks = self.tasks.lock();
        if tasks.closed {
            return;
        }
        while let Some(result) = tasks.jobs.try_join_next() {
            tasks.failed |= result.is_err();
        }
        tasks.jobs.spawn(work);
    }
    pub(crate) async fn incoming(
        self: &Arc<Self>,
        channel: Channel<client::Msg>,
        reply: client::ChannelOpenHandle,
    ) {
        // No network waits or asynchronous ownership lock while routing. A slow
        // crypto operation/consumer must not block the shared SSH dispatcher.
        let (epoch, signer) = {
            let state = self.state.lock();
            (
                state.status.epoch,
                state.signer.as_ref().filter(|s| s.active()).cloned(),
            )
        };
        let slot = self.streams.clone().try_acquire_owned();
        let (Some(signer), Ok(slot)) = (signer, slot) else {
            reply
                .reject(ChannelOpenFailure::AdministrativelyProhibited)
                .await;
            return;
        };
        if self.root.is_cancelled() {
            reply
                .reject(ChannelOpenFailure::AdministrativelyProhibited)
                .await;
            return;
        }
        let permission = signer.stop_token();
        let router = Arc::downgrade(self);
        self.spawn(async move {
            let _slot = slot;
            if !signer.active() {
                reply
                    .reject(ChannelOpenFailure::AdministrativelyProhibited)
                    .await;
                return;
            }
            reply.accept().await;
            // Bad/truncated frames close only this Agent stream. The codec is
            // bounded and fails requests it cannot safely perform.
            if agent_protocol::serve(channel.into_stream(), &signer, permission)
                .await
                .is_err()
                && let Some(router) = router.upgrade()
            {
                let mut state = router.state.lock();
                if state.status.epoch == epoch {
                    state.status.failed_streams = state.status.failed_streams.saturating_add(1);
                    router.publish(&state);
                }
            }
        });
    }
    fn invalidated(&self, state: &mut State, phase: AgentPhase) -> Result<u64, SshError> {
        let Some(epoch) = state.status.epoch.checked_add(1) else {
            if let Some(signer) = state.signer.take() {
                signer.revoke();
            }
            state.status.phase = AgentPhase::Failed;
            state.status.key_count = 0;
            state.status.expires_unix_millis = None;
            self.publish(state);
            return Err(SshError::AgentUnavailable);
        };
        if let Some(signer) = state.signer.take() {
            signer.revoke();
        }
        state.status = AgentStatus {
            epoch,
            phase,
            key_count: 0,
            expires_unix_millis: None,
            failed_streams: state.status.failed_streams,
        };
        self.publish(state);
        Ok(epoch)
    }
    fn complete_expiry(&self, epoch: u64) {
        let mut state = self.state.lock();
        if state.status.epoch != epoch || state.signer.as_ref().is_some_and(AgentSigner::active) {
            return;
        }
        let failed = state.signer.as_ref().is_some_and(AgentSigner::failed);
        state.signer = None;
        if state.status.phase == AgentPhase::Active {
            state.status.phase = if self.root.is_cancelled() {
                AgentPhase::Closed
            } else if failed {
                AgentPhase::Failed
            } else {
                AgentPhase::Expired
            };
            state.status.key_count = 0;
            state.status.expires_unix_millis = None;
            self.publish(&state);
        }
    }
    pub(crate) fn stop(&self) {
        self.root.cancel();
    }
    pub(crate) async fn shutdown(&self) -> Result<(), SshError> {
        // root is this client's child token; closing it never cancels another
        // client/jump or an outer caller's parent token.
        self.root.cancel();
        let stop_epoch = {
            let mut state = self.state.lock();
            // Cancellation has already revoked all operations. Even an epoch
            // overflow must continue draining workers and incoming streams.
            let epoch = self.invalidated(&mut state, AgentPhase::Closed);
            if epoch.is_err() {
                state.status.phase = AgentPhase::Closed;
                self.publish(&state);
            }
            epoch
        };
        let mut owner = self.owner.lock().await;
        let stopped = if let Some(o) = owner.as_mut() {
            o.authority
                .shutdown()
                .await
                .map_err(|_| SshError::AgentWorker)
        } else {
            Ok(())
        };
        owner.take();
        drop(owner);
        // Move the set out once no future grant/incoming can be accepted. New
        // denied callbacks create no job, and existing jobs all observe cancel.
        let mut tasks = {
            let mut guard = self.tasks.lock();
            std::mem::replace(
                &mut *guard,
                Tasks {
                    jobs: JoinSet::new(),
                    failed: false,
                    closed: true,
                },
            )
        };
        while let Some(result) = tasks.jobs.join_next().await {
            tasks.failed |= result.is_err();
        }
        stopped?;
        stop_epoch?;
        if tasks.failed {
            return Err(SshError::AgentWorker);
        }
        Ok(())
    }
}
/// Prepare a selected in-app key on a blocking worker, returning only the
/// parsed Rust key and its public fingerprint. No files or system Agent reads.
pub fn prepare_key(
    source: &str,
    password: Option<&str>,
) -> Result<(russh::keys::PrivateKey, String), SshError> {
    if source.len() > 256 * 1024 {
        return Err(SshError::PrivateKey);
    }
    let key = russh::keys::decode_secret_key(source, password).map_err(|_| SshError::PrivateKey)?;
    match key.key_data() {
        russh::keys::ssh_key::private::KeypairData::Ed25519(_)
        | russh::keys::ssh_key::private::KeypairData::Ecdsa(_) => {}
        russh::keys::ssh_key::private::KeypairData::Rsa(rsa) => {
            russh::keys::RingRsaSigner::new(rsa).map_err(|_| SshError::RsaUnsupported)?;
        }
        _ => return Err(SshError::PrivateKey),
    }
    let fingerprint = key
        .public_key()
        .fingerprint(russh::keys::HashAlg::Sha256)
        .to_string();
    Ok((key, fingerprint))
}

impl AgentConnector {
    pub(crate) fn new(router: Arc<AgentRouter>) -> Self {
        Self { router }
    }
    pub fn status(&self) -> AgentStatus {
        let state = self.router.state.lock();
        let mut status = state.status.clone();
        if self.router.root.is_cancelled() {
            status.phase = AgentPhase::Closed;
            status.key_count = 0;
            status.expires_unix_millis = None;
        } else if status.phase == AgentPhase::Active
            && state.signer.as_ref().is_none_or(|s| !s.active())
        {
            status.phase = if state.signer.as_ref().is_some_and(AgentSigner::failed) {
                AgentPhase::Failed
            } else {
                AgentPhase::Expired
            };
            status.key_count = 0;
            status.expires_unix_millis = None;
        }
        status
    }
    pub fn watch(&self) -> watch::Receiver<AgentStatus> {
        self.router.changed.subscribe()
    }
    /// An explicit confirmation must name this original router's preparation
    /// epoch. A later revoke/authorisation invalidates a stale confirmation.
    pub async fn authorise(
        &self,
        expected_epoch: u64,
        keys: Vec<PrivateKey>,
        ttl: Duration,
    ) -> Result<AgentStatus, SshError> {
        let mut owner = self.router.owner.try_lock().map_err(|_| SshError::Busy)?;
        let epoch = {
            let mut state = self.router.state.lock();
            if self.router.root.is_cancelled()
                || !state.endpoint_accepted
                || state.status.epoch != expected_epoch
                || !matches!(
                    state.status.phase,
                    AgentPhase::Ready
                        | AgentPhase::Revoked
                        | AgentPhase::Expired
                        | AgentPhase::Active
                )
            {
                return Err(SshError::AgentUnavailable);
            }
            self.router.invalidated(&mut state, AgentPhase::Ready)?
        };
        let stopped = match owner.as_mut() {
            Some(old) => old
                .authority
                .shutdown()
                .await
                .map_err(|_| SshError::AgentWorker),
            None => Ok(()),
        };
        owner.take();
        stopped?;
        let count = keys.len() as u16;
        let mut authority = AgentAuthority::authorised(keys, ttl, &self.router.root)
            .map_err(|_| SshError::AgentUnavailable)?;
        let signer = authority.signer();
        let stop = signer.stop_token();
        let expiry = signer
            .expires_at()
            .duration_since(UNIX_EPOCH)
            .ok()
            .and_then(|n| u64::try_from(n.as_millis()).ok());
        let installed = {
            let mut state = self.router.state.lock();
            if !self.router.root.is_cancelled() && state.status.epoch == epoch {
                state.signer = Some(signer);
                state.status = AgentStatus {
                    epoch,
                    phase: AgentPhase::Active,
                    key_count: count,
                    expires_unix_millis: expiry,
                    failed_streams: state.status.failed_streams,
                };
                self.router.publish(&state);
                true
            } else {
                false
            }
        };
        if !installed {
            authority
                .shutdown()
                .await
                .map_err(|_| SshError::AgentWorker)?;
            return Err(SshError::Cancelled);
        }
        *owner = Some(Owner { epoch, authority });
        drop(owner);
        let router = Arc::downgrade(&self.router);
        self.router.spawn(async move {
            stop.cancelled().await;
            if let Some(router) = router.upgrade() {
                router.complete_expiry(epoch);
            }
        });
        let status = self.status();
        if status.epoch != epoch || status.phase != AgentPhase::Active {
            return Err(SshError::Cancelled);
        }
        Ok(status)
    }
    /// Synchronously withdraw permission and invalidate prepared confirmations.
    /// Used under the application's Vault switch gate; no network/crypto waits.
    /// Call revoke/connection close to join the already-cancelled worker.
    pub fn invalidate_grant(&self) -> Result<AgentStatus, SshError> {
        let mut state = self.router.state.lock();
        let phase = if state.endpoint_accepted {
            AgentPhase::Revoked
        } else {
            state.status.phase
        };
        self.router.invalidated(&mut state, phase)?;
        Ok(state.status.clone())
    }
    pub async fn revoke(&self) -> Result<AgentStatus, SshError> {
        let cutoff = self.invalidate_grant()?.epoch;
        let mut owner = self.router.owner.lock().await;
        if let Some(old) = owner.as_mut().filter(|o| o.epoch < cutoff) {
            let stopped = old
                .authority
                .shutdown()
                .await
                .map_err(|_| SshError::AgentWorker);
            owner.take();
            stopped?;
        }
        Ok(self.status())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn key() -> PrivateKey {
        PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519).unwrap()
    }
    #[tokio::test]
    async fn grants_are_explicit_epoch_bound_and_shutdown_never_cancels_parent() {
        let root = CancellationToken::new();
        let router = AgentRouter::new(root.clone());
        let connector = AgentConnector::new(router.clone());
        assert!(
            connector
                .authorise(0, vec![key()], Duration::from_secs(60))
                .await
                .is_err()
        );
        connector.revoke().await.unwrap();
        assert_eq!(connector.status().phase, AgentPhase::NotRequested);
        assert!(
            connector
                .authorise(
                    connector.status().epoch,
                    vec![key()],
                    Duration::from_secs(60)
                )
                .await
                .is_err()
        );
        router.endpoint_result(true);
        assert!(
            connector
                .authorise(connector.status().epoch, vec![], Duration::from_secs(60))
                .await
                .is_err()
        );
        let epoch = connector.status().epoch;
        connector
            .authorise(epoch, vec![key()], Duration::from_secs(60))
            .await
            .unwrap();
        assert_eq!(connector.status().phase, AgentPhase::Active);
        assert!(
            connector
                .authorise(epoch, vec![key()], Duration::from_secs(60))
                .await
                .is_err()
        );
        let active = connector.status().epoch;
        connector.revoke().await.unwrap();
        assert!(
            connector
                .authorise(active, vec![key()], Duration::from_secs(60))
                .await
                .is_err()
        );
        connector
            .authorise(
                connector.status().epoch,
                vec![key()],
                Duration::from_secs(60),
            )
            .await
            .unwrap();
        router.shutdown().await.unwrap();
        assert_eq!(connector.status().phase, AgentPhase::Closed);
        assert!(!root.is_cancelled());
        assert!(
            connector
                .authorise(
                    connector.status().epoch,
                    vec![key()],
                    Duration::from_secs(60)
                )
                .await
                .is_err()
        );
        assert!(router.tasks.lock().closed);
    }
    #[tokio::test]
    async fn duplicate_keys_limits_and_root_loss_fail_closed() {
        let root = CancellationToken::new();
        let router = AgentRouter::new(root.clone());
        router.endpoint_result(true);
        let connector = AgentConnector::new(router.clone());
        let duplicate = key();
        assert!(
            connector
                .authorise(
                    0,
                    vec![duplicate.clone(), duplicate],
                    Duration::from_secs(60)
                )
                .await
                .is_err()
        );
        let epoch = connector.status().epoch;
        assert!(
            connector
                .authorise(epoch, vec![key()], Duration::ZERO)
                .await
                .is_err()
        );
        connector
            .authorise(
                connector.status().epoch,
                vec![key()],
                Duration::from_secs(60),
            )
            .await
            .unwrap();
        root.cancel();
        router.shutdown().await.unwrap();
        assert_eq!(connector.status().phase, AgentPhase::Closed);
    }
}
