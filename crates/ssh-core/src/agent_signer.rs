//! Explicitly authorized app-owned keys; bounded requests and one blocking
//! signing job. Cancellation drains the job before releasing its private keys.
use crate::agent_protocol::{Identity, Signer as AgentSigning};
use russh::keys::{
    HashAlg, PrivateKey, RingRsaSigner,
    signature::Signer as CryptoSigner,
    ssh_key::{Signature, private::KeypairData},
};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime},
};
use tokio::{
    sync::{mpsc, oneshot},
    task::JoinHandle,
    time::Instant,
};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

#[derive(Debug, thiserror::Error)]
pub(crate) enum AgentError {
    #[error("Agent授权参数无效；未建立授权")]
    Invalid,
    #[error("Agent授权工作任务失败，已撤销授权")]
    Worker,
}
struct Key {
    public: Vec<u8>,
    private: Arc<PrivateKey>,
    rsa: Arc<std::sync::OnceLock<Result<RingRsaSigner, ()>>>,
}
#[derive(Clone)]
struct Permission {
    stop: CancellationToken,
    deadline: Option<Instant>,
    wall_deadline: Option<SystemTime>,
    failed: Arc<AtomicBool>,
}
impl Permission {
    async fn expired(&self) {
        match self.deadline {
            Some(deadline) => tokio::time::sleep_until(deadline).await,
            None => std::future::pending::<()>().await,
        }
    }
    fn active(&self) -> bool {
        let active = !self.failed.load(Ordering::Acquire)
            && !self.stop.is_cancelled()
            && self.deadline.is_none_or(|limit| Instant::now() < limit)
            && self
                .wall_deadline
                .is_none_or(|limit| SystemTime::now() < limit);
        if !active {
            self.stop.cancel();
        }
        active
    }
}
enum Command {
    Identities(oneshot::Sender<Result<Vec<Identity>, ()>>),
    Sign {
        key: Vec<u8>,
        data: Zeroizing<Vec<u8>>,
        flags: u32,
        reply: oneshot::Sender<Result<Vec<u8>, ()>>,
    },
}
/// Clones contain only a bounded request capability, public expiry and cancel.
/// Private keys remain in the owned worker and its one in-progress crypto job.
#[derive(Clone)]
pub(crate) struct AgentSigner {
    permission: Permission,
    requests: mpsc::Sender<Command>,
}
pub(crate) struct AgentAuthority {
    signer: AgentSigner,
    worker: Option<JoinHandle<()>>,
}
impl AgentAuthority {
    /// Caller must obtain explicit, per-connection, time-limited consent first.
    /// This never reads Vault/files/system agents, or modifies the original root.
    pub(crate) fn authorised(
        keys: Vec<PrivateKey>,
        ttl: Duration,
        original_root: &CancellationToken,
    ) -> Result<Self, AgentError> {
        if ttl.is_zero() || ttl > Duration::from_secs(3600) {
            return Err(AgentError::Invalid);
        }
        Self::create(keys, Some(ttl), original_root)
    }
    /// An explicit copy owns this single-destination signer. Its lease, root
    /// disconnect or credential revocation cancels it; long transfers do not
    /// acquire a new one-hour failure boundary. Never used for general grants.
    pub(crate) fn for_transfer(
        keys: Vec<PrivateKey>,
        original_root: &CancellationToken,
    ) -> Result<Self, AgentError> {
        Self::create(keys, None, original_root)
    }
    fn create(
        keys: Vec<PrivateKey>,
        ttl: Option<Duration>,
        original_root: &CancellationToken,
    ) -> Result<Self, AgentError> {
        if keys.is_empty() || keys.len() > 16 || original_root.is_cancelled() {
            return Err(AgentError::Invalid);
        }
        let mut seen = std::collections::BTreeSet::new();
        let mut selected = Vec::new();
        let mut total = 5usize;
        for key in keys {
            if key.is_encrypted() {
                return Err(AgentError::Invalid);
            }
            match key.key_data() {
                KeypairData::Ed25519(_) | KeypairData::Ecdsa(_) => {}
                KeypairData::Rsa(rsa) if (2048..=4096).contains(&rsa.key_size()) => {}
                _ => return Err(AgentError::Invalid),
            }
            let public = key
                .public_key()
                .to_bytes()
                .map_err(|_| AgentError::Invalid)?;
            if public.is_empty() || public.len() > 16384 || !seen.insert(public.clone()) {
                return Err(AgentError::Invalid);
            }
            total = total
                .checked_add(8 + public.len())
                .ok_or(AgentError::Invalid)?;
            if total > 256 * 1024 {
                return Err(AgentError::Invalid);
            }
            selected.push(Key {
                public,
                private: Arc::new(key),
                rsa: Arc::new(std::sync::OnceLock::new()),
            });
        }
        let permission = Permission {
            stop: original_root.child_token(),
            failed: Arc::new(AtomicBool::new(false)),
            deadline: ttl.map(|ttl| Instant::now() + ttl),
            wall_deadline: ttl
                .map(|ttl| {
                    SystemTime::now()
                        .checked_add(ttl)
                        .ok_or(AgentError::Invalid)
                })
                .transpose()?,
        };
        let (requests, receiver) = mpsc::channel(4);
        let signer = AgentSigner {
            permission: permission.clone(),
            requests,
        };
        let worker = tokio::spawn(run(selected, permission, receiver));
        Ok(Self {
            signer,
            worker: Some(worker),
        })
    }
    pub(crate) fn signer(&self) -> AgentSigner {
        self.signer.clone()
    }
    pub(crate) fn cancel(&self) {
        self.signer.permission.stop.cancel();
    }
    /// Explicit root cleanup waits for the one bounded, non-preemptible crypto
    /// operation before dropping keys. Dropping a Tokio blocking job detaches it.
    pub(crate) async fn shutdown(&mut self) -> Result<(), AgentError> {
        self.cancel();
        let result = match self.worker.as_mut() {
            Some(worker) => worker.await.map_err(|_| AgentError::Worker),
            None => Ok(()),
        };
        self.worker.take();
        if result.is_ok() && self.signer.failed() {
            return Err(AgentError::Worker);
        }
        result
    }
}
impl Drop for AgentAuthority {
    fn drop(&mut self) {
        self.cancel();
    }
}
struct RevokeOnExit(Permission);
impl Drop for RevokeOnExit {
    fn drop(&mut self) {
        if std::thread::panicking() {
            self.0.failed.store(true, Ordering::Release);
        }
        self.0.stop.cancel();
    }
}
async fn run(keys: Vec<Key>, permission: Permission, mut requests: mpsc::Receiver<Command>) {
    let _exit = RevokeOnExit(permission.clone());
    loop {
        let command = tokio::select! {
            biased;
            _=permission.stop.cancelled()=>return,
            _=permission.expired()=>return,
            command=requests.recv()=>match command {Some(c)=>c,None=>return},
        };
        if !permission.active() {
            return;
        }
        match command {
            Command::Identities(reply) => {
                let _ = reply.send(Ok(keys
                    .iter()
                    .map(|k| Identity {
                        blob: k.public.clone(),
                    })
                    .collect()));
            }
            Command::Sign {
                key,
                data,
                flags,
                reply,
            } => {
                let Some(key) = keys.iter().find(|k| k.public == key) else {
                    let _ = reply.send(Err(()));
                    continue;
                };
                if flags & !6 != 0 {
                    let _ = reply.send(Err(()));
                    continue;
                }
                let private = Arc::clone(&key.private);
                let rsa = key.rsa.clone();
                let allowed = permission.clone();
                let job = tokio::task::spawn_blocking(move || {
                    if !allowed.active() {
                        return Err(());
                    }
                    let signature: Signature = match private.key_data() {
                        // Flags are a bitfield; SHA-512 wins if both are set.
                        // Ring refuses legacy RSA SHA-1 rather than downgrading.
                        KeypairData::Rsa(key) => rsa
                            .get_or_init(|| RingRsaSigner::new(key).map_err(|_| ()))
                            .as_ref()
                            .map_err(|_| ())?
                            .sign(
                                if flags & 4 != 0 {
                                    Some(HashAlg::Sha512)
                                } else if flags & 2 != 0 {
                                    Some(HashAlg::Sha256)
                                } else {
                                    None
                                },
                                &data,
                            )
                            .map_err(|_| ())?,
                        _ if flags == 0 => private.try_sign(&data).map_err(|_| ())?,
                        _ => return Err(()),
                    };
                    if !allowed.active() {
                        return Err(());
                    }
                    Vec::<u8>::try_from(signature).map_err(|_| ())
                });
                let Some(result) = finish_job(&permission, job).await else {
                    return;
                };
                let _ = reply.send(if permission.active() { result } else { Err(()) });
            }
        }
    }
}
async fn finish_job(
    permission: &Permission,
    mut job: JoinHandle<Result<Vec<u8>, ()>>,
) -> Option<Result<Vec<u8>, ()>> {
    let joined = tokio::select! {
        biased;
        _ = permission.stop.cancelled() => { let joined = job.await; (false, joined) },
        _ = permission.expired() => { permission.stop.cancel(); let joined = job.await; (false, joined) },
        result = &mut job => (true, result),
    };
    match joined {
        (_, Err(_)) => {
            permission.failed.store(true, Ordering::Release);
            permission.stop.cancel();
            None
        }
        (true, Ok(result)) => Some(result),
        (false, Ok(_)) => None,
    }
}
impl AgentSigner {
    pub(crate) fn failed(&self) -> bool {
        self.permission.failed.load(Ordering::Acquire)
    }
    pub(crate) fn active(&self) -> bool {
        self.permission.active()
    }
    pub(crate) fn stop_token(&self) -> CancellationToken {
        self.permission.stop.clone()
    }
    pub(crate) fn expires_at(&self) -> Option<SystemTime> {
        self.permission.wall_deadline
    }
    pub(crate) fn revoke(&self) {
        self.permission.stop.cancel();
    }
    async fn request<T>(
        &self,
        command: Command,
        reply: oneshot::Receiver<Result<T, ()>>,
    ) -> Result<T, ()> {
        if !self.permission.active() {
            return Err(());
        }
        tokio::select! {
            biased;
            _=self.permission.stop.cancelled()=>Err(()),
            _=self.permission.expired()=>Err(()),
            result=async {
                self.requests.send(command).await.map_err(|_|())?;
                let result=reply.await.map_err(|_|())??;
                if self.permission.active(){Ok(result)}else{Err(())}
            }=>result,
        }
    }
}
impl AgentSigning for AgentSigner {
    async fn identities(&self) -> Result<Vec<Identity>, ()> {
        let (tx, rx) = oneshot::channel();
        self.request(Command::Identities(tx), rx).await
    }
    async fn sign(&self, key: &[u8], data: &[u8], flags: u32) -> Result<Vec<u8>, ()> {
        if key.is_empty() || key.len() > 16384 || data.len() > 128 * 1024 || flags & !6 != 0 {
            return Err(());
        }
        let (tx, rx) = oneshot::channel();
        self.request(
            Command::Sign {
                key: key.to_vec(),
                data: Zeroizing::new(data.to_vec()),
                flags,
                reply: tx,
            },
            rx,
        )
        .await
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use russh::keys::{Algorithm, signature::Verifier};
    #[tokio::test]
    async fn task_signer_is_owned_by_root_not_manual_grant_timeout() {
        let root = CancellationToken::new();
        let key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
        let mut owner = AgentAuthority::for_transfer(vec![key], &root).unwrap();
        let signer = owner.signer();
        assert!(signer.expires_at().is_none());
        assert_eq!(signer.identities().await.unwrap().len(), 1);
        root.cancel();
        assert!(signer.identities().await.is_err());
        owner.shutdown().await.unwrap();
    }
    #[tokio::test]
    async fn real_ed25519_signatures_are_verified_and_rejected_after_revoke_expiry_or_original_root_loss()
     {
        for reason in 0..3 {
            let root = CancellationToken::new();
            let key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
            let public = key.public_key().clone();
            let blob = public.to_bytes().unwrap();
            let mut owner =
                AgentAuthority::authorised(vec![key], Duration::from_secs(5), &root).unwrap();
            let signer = owner.signer();
            assert_eq!(signer.identities().await.unwrap().len(), 1);
            let signature = signer
                .sign(&blob, b"synthetic-agent-challenge", 0)
                .await
                .unwrap();
            Verifier::verify(
                &public,
                b"synthetic-agent-challenge",
                &Signature::try_from(signature.as_slice()).unwrap(),
            )
            .unwrap();
            assert!(signer.sign(&blob, b"data", 2).await.is_err());
            assert!(signer.sign(b"unknown", b"data", 0).await.is_err());
            match reason {
                0 => owner.cancel(),
                1 => {
                    tokio::time::pause();
                    tokio::time::advance(Duration::from_secs(6)).await;
                    tokio::time::resume();
                }
                _ => root.cancel(),
            };
            assert!(signer.identities().await.is_err());
            assert!(signer.sign(&blob, b"data", 0).await.is_err());
            owner.shutdown().await.unwrap();
            if reason != 2 {
                assert!(!root.is_cancelled());
            }
        }
    }
}

#[cfg(test)]
mod worker_failure_tests {
    use super::*;
    #[tokio::test]
    async fn blocking_crypto_panic_is_a_failure_not_a_success_or_expiration() {
        let permission = Permission {
            stop: CancellationToken::new(),
            deadline: Some(Instant::now() + Duration::from_secs(60)),
            wall_deadline: Some(SystemTime::now() + Duration::from_secs(60)),
            failed: Arc::new(AtomicBool::new(false)),
        };
        let result = finish_job(
            &permission,
            tokio::task::spawn_blocking(|| -> Result<Vec<u8>, ()> {
                panic!("synthetic crypto worker failure")
            }),
        )
        .await;
        assert!(result.is_none());
        assert!(permission.failed.load(Ordering::Acquire));
        assert!(permission.stop.is_cancelled());
        assert!(!permission.active());
    }
}
