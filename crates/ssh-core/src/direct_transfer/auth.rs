//! Task-scoped authentication over the original forwarded application socket.
//! Passwords never enter exec argv/env/files; private keys never leave Rust.
use crate::{
    Authentication, SshError, agent_protocol,
    agent_signer::{AgentAuthority, AgentSigner},
};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio_util::sync::CancellationToken;
use zeroize::{Zeroize, Zeroizing};

const SELECTOR: &[u8] = b"hspterm-direct-auth-v1";
static NEXT: AtomicU64 = AtomicU64::new(1);
pub(crate) enum Credential {
    Password(parking_lot::Mutex<Zeroizing<String>>),
    Key(AgentSigner),
}
pub(crate) struct Capability {
    token: Zeroizing<[u8; 32]>,
    pub epoch: u64,
    stop: CancellationToken,
    credential: Credential,
}
/// Only the route and its real exec workers own leases. Agent streams may
/// hold a Capability but cannot extend the lifetime of the requested copy.
pub(crate) struct Lease(pub Arc<Capability>);
impl std::ops::Deref for Lease {
    type Target = Capability;
    fn deref(&self) -> &Capability {
        &self.0
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        self.0.cancel();
    }
}
impl Drop for Capability {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}
impl Capability {
    pub(crate) async fn prepare(
        auth: Authentication,
        root: &CancellationToken,
    ) -> Result<(Arc<Self>, Option<AgentAuthority>), SshError> {
        let stop = root.child_token();
        let (credential, authority) = match auth {
            Authentication::Password(password) => {
                if password.len() > 65536 || password.contains(['\0', '\r', '\n']) {
                    return Err(SshError::InvalidConfig);
                }
                (
                    Credential::Password(parking_lot::Mutex::new(password)),
                    None,
                )
            }
            Authentication::PrivateKey {
                openssh,
                passphrase,
            } => {
                let key = tokio::task::spawn_blocking(move || {
                    crate::agent_forward::prepare_key(
                        &openssh,
                        passphrase.as_deref().map(String::as_str),
                    )
                })
                .await
                .map_err(|_| SshError::PrivateKey)??
                .0;
                let authority = AgentAuthority::for_transfer(vec![key], &stop)
                    .map_err(|_| SshError::AgentUnavailable)?;
                (Credential::Key(authority.signer()), Some(authority))
            }
        };
        let epoch = NEXT
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |v| v.checked_add(1))
            .map_err(|_| SshError::AgentUnavailable)?;
        Ok((
            Arc::new(Self {
                token: Zeroizing::new(rand::random()),
                epoch,
                stop,
                credential,
            }),
            authority,
        ))
    }
    pub(crate) fn active(&self) -> bool {
        let active = !self.stop.is_cancelled()
            && match &self.credential {
                Credential::Password(_) => true,
                Credential::Key(signer) => signer.active(),
            };
        if !active {
            self.cancel();
        }
        active
    }
    pub(crate) fn cancel(&self) {
        self.stop.cancel();
        if let Credential::Password(p) = &self.credential {
            p.lock().zeroize();
        }
    }
    pub(crate) fn stopped(&self) -> CancellationToken {
        self.stop.clone()
    }
    pub(crate) fn status(&self) -> crate::AgentStatus {
        crate::AgentStatus {
            epoch: self.epoch,
            phase: if self.active() {
                crate::AgentPhase::Active
            } else {
                crate::AgentPhase::Revoked
            },
            key_count: 1,
            // Internal admission status only. Actual validity is bounded by
            // the task lease and original root, not a manual grant deadline.
            expires_unix_millis: Some(u64::MAX),
            failed_streams: 0,
        }
    }
    pub(crate) fn input(&self) -> Zeroizing<Vec<u8>> {
        let mut input = Zeroizing::new(b"HSPAUTH\x01".to_vec());
        input.push(if matches!(self.credential, Credential::Password(_)) {
            1
        } else {
            2
        });
        input.extend_from_slice(self.token.as_ref());
        input
    }
    pub(crate) fn matches(&self, frame: &[u8]) -> bool {
        let mut prefix = vec![27];
        prefix.extend_from_slice(&(SELECTOR.len() as u32).to_be_bytes());
        prefix.extend_from_slice(SELECTOR);
        prefix.extend_from_slice(&32u32.to_be_bytes());
        if !frame.starts_with(&prefix) || frame.len() != prefix.len() + 32 || !self.active() {
            return false;
        }
        frame[prefix.len()..]
            .iter()
            .zip(self.token.iter())
            .fold(0u8, |a, (x, y)| a | std::hint::black_box(x ^ y))
            == 0
    }
    pub(crate) async fn serve<T>(&self, mut stream: T) -> std::io::Result<()>
    where
        T: AsyncRead + AsyncWrite + Unpin,
    {
        if !self.active() {
            return Ok(());
        }
        match &self.credential {
            Credential::Password(password) => {
                let password = password.lock().clone();
                let mut response = Zeroizing::new(vec![6]);
                response.extend_from_slice(&(password.len() as u32).to_be_bytes());
                response.extend_from_slice(password.as_bytes());
                tokio::select! { biased;
                    _ = self.stop.cancelled() => Ok(()),
                    r = async { stream.write_all(&(response.len() as u32).to_be_bytes()).await?;
                        stream.write_all(&response).await?; stream.flush().await } => r,
                }
            }
            Credential::Key(signer) => {
                tokio::select! { biased;
                    _ = self.stop.cancelled() => return Ok(()),
                    result = async {
                        stream.write_all(&1u32.to_be_bytes()).await?;
                        stream.write_all(&[6]).await?;
                        stream.flush().await
                    } => { result?; },
                }
                agent_protocol::serve(stream, signer, self.stop.clone()).await
            }
        }
    }
}
/// Read only the first bounded frame to choose the task capability. No secret
/// returned by a password request is ever parsed as a terminal/diagnostic event.
pub(crate) async fn first<T: AsyncRead + Unpin>(
    stream: &mut T,
) -> std::io::Result<Zeroizing<Vec<u8>>> {
    let n = stream.read_u32().await? as usize;
    if n == 0 || n > 256 * 1024 {
        return Err(std::io::ErrorKind::InvalidData.into());
    }
    let mut body = Zeroizing::new(vec![0; n]);
    stream.read_exact(&mut body).await?;
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn selector(cap: &Capability) -> Vec<u8> {
        let mut body = vec![27];
        body.extend_from_slice(&(SELECTOR.len() as u32).to_be_bytes());
        body.extend_from_slice(SELECTOR);
        body.extend_from_slice(&32u32.to_be_bytes());
        body.extend_from_slice(cap.token.as_ref());
        body
    }
    #[tokio::test]
    async fn password_is_selected_by_exact_task_token_and_retires_with_lease() {
        let root = CancellationToken::new();
        let (cap, authority) = Capability::prepare(
            Authentication::Password(Zeroizing::new("synthetic-only-password".into())),
            &root,
        )
        .await
        .unwrap();
        assert!(authority.is_none());
        let lease = Arc::new(Lease(cap.clone()));
        let frame = selector(&cap);
        assert!(cap.matches(&frame));
        let mut wrong = frame.clone();
        *wrong.last_mut().unwrap() ^= 1;
        assert!(!cap.matches(&wrong));
        assert!(!cap.matches(&frame[..frame.len() - 1]));
        assert!(!cap.matches(&[11])); // Generic identity requests reveal nothing.
        let packet = cap.input();
        assert_eq!(packet.len(), 41);
        assert!(!packet.windows(9).any(|s| s == b"synthetic"));
        let (server, mut client) = tokio::io::duplex(256);
        let served = cap.clone();
        let worker = tokio::spawn(async move { served.serve(server).await.unwrap() });
        let response = first(&mut client).await.unwrap();
        assert_eq!(response[0], 6);
        assert_eq!(
            u32::from_be_bytes(response[1..5].try_into().unwrap()) as usize,
            response.len() - 5
        );
        assert_eq!(&response[5..], b"synthetic-only-password");
        worker.await.unwrap();
        let second_owner = lease.clone();
        drop(lease);
        assert!(cap.active());
        drop(second_owner);
        // A still-open Agent stream/capability cannot keep credentials alive.
        assert!(!cap.active());
        assert!(!cap.matches(&frame));
        if let Credential::Password(password) = &cap.credential {
            assert!(password.lock().is_empty());
        }
        assert!(!root.is_cancelled());
    }
    #[tokio::test]
    async fn root_cancel_and_invalid_askpass_password_fail_closed() {
        let root = CancellationToken::new();
        for password in ["has\nnewline", "has\0nul", "has\rcarriage"] {
            assert!(
                Capability::prepare(
                    Authentication::Password(Zeroizing::new(password.into())),
                    &root
                )
                .await
                .is_err()
            );
        }
        let (cap, _) = Capability::prepare(
            Authentication::Password(Zeroizing::new("synthetic".into())),
            &root,
        )
        .await
        .unwrap();
        root.cancel();
        assert!(!cap.matches(&selector(&cap)));
        assert!(!cap.active());
    }
}
