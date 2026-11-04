//! Controlled SSH peer tests. Separate from real OpenSSH interoperability.
use super::*;
use hspterm_ssh_core::{ManagedSession, SessionPhase, Stage};
use russh::{Channel, ChannelId, Pty, server};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};
use tokio::task::JoinHandle;

#[derive(Clone, Copy)]
enum Mode {
    HoldOpens,
    CloseFirst(usize),
    Deny,
}
struct Peer {
    first: bool,
    mode: Mode,
    pending: mpsc::Sender<(server::ChannelOpenHandle, Channel<server::Msg>)>,
    channels: HashMap<ChannelId, Channel<server::Msg>>,
    requests: Arc<AtomicUsize>,
    cancel_on_request: Option<CancellationToken>,
    children: Arc<Mutex<Vec<JoinHandle<()>>>>,
}
struct Subsystem;
impl russh_sftp::server::Handler for Subsystem {
    type Error = russh_sftp::protocol::StatusCode;
    fn unimplemented(&self) -> Self::Error {
        russh_sftp::protocol::StatusCode::OpUnsupported
    }
}
impl server::Handler for Peer {
    type Error = russh::Error;
    async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
        Ok(server::Auth::Accept)
    }
    async fn channel_open_session(
        &mut self,
        channel: Channel<server::Msg>,
        reply: server::ChannelOpenHandle,
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        if !self.first && matches!(self.mode, Mode::HoldOpens) {
            self.pending
                .send((reply, channel))
                .await
                .map_err(|_| russh::Error::Disconnect)?;
        } else {
            self.first = false;
            self.channels.insert(channel.id(), channel);
            reply.accept().await;
        }
        Ok(())
    }
    async fn pty_request(
        &mut self,
        id: ChannelId,
        _: &str,
        _: u32,
        _: u32,
        _: u32,
        _: u32,
        _: &[(Pty, u32)],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(id)
    }
    async fn shell_request(
        &mut self,
        id: ChannelId,
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(id)
    }
    async fn subsystem_request(
        &mut self,
        id: ChannelId,
        name: &str,
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        assert_eq!(name, "sftp");
        let request = self.requests.fetch_add(1, Ordering::SeqCst) + 1;
        if let Some(cancel) = &self.cancel_on_request {
            cancel.cancel();
        }
        match self.mode {
            Mode::Deny => session.channel_failure(id),
            Mode::CloseFirst(n) if request <= n => {
                session.channel_success(id)?;
                session.eof(id)?;
                session.close(id)?;
                self.channels.remove(&id);
                Ok(())
            }
            _ => {
                session.channel_success(id)?;
                let channel = self.channels.remove(&id).unwrap();
                self.children
                    .lock()
                    .unwrap()
                    .push(tokio::spawn(russh_sftp::server::run_owned(
                        channel.into_stream(),
                        Subsystem,
                    )));
                Ok(())
            }
        }
    }
}
struct Harness {
    session: Arc<ManagedSession>,
    pending: mpsc::Receiver<(server::ChannelOpenHandle, Channel<server::Msg>)>,
    requests: Arc<AtomicUsize>,
    serving: JoinHandle<Result<(), russh::Error>>,
    drain: JoinHandle<()>,
    children: Arc<Mutex<Vec<JoinHandle<()>>>>,
}
impl Harness {
    async fn new(mode: Mode) -> Self {
        Self::with_cancel(mode, None).await
    }
    async fn with_cancel(mode: Mode, cancel_on_request: Option<CancellationToken>) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("synthetic-host");
        generate_key(&path, "");
        let key = russh::keys::load_secret_key(&path, None).unwrap();
        let fingerprint = key
            .public_key()
            .fingerprint(russh::keys::HashAlg::Sha256)
            .to_string();
        let config = Arc::new(server::Config {
            keys: vec![key],
            auth_rejection_time: Duration::ZERO,
            ..Default::default()
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (sender, pending) = mpsc::channel(64);
        let requests = Arc::new(AtomicUsize::new(0));
        let children = Arc::new(Mutex::new(Vec::new()));
        let peer = Peer {
            first: true,
            mode,
            pending: sender,
            channels: HashMap::new(),
            requests: requests.clone(),
            cancel_on_request,
            children: children.clone(),
        };
        let serving = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            server::run_stream(config, socket, peer)
                .await
                .unwrap()
                .await
        });
        let (session, mut events) = ManagedSession::new(Size::new(80, 24).unwrap(), 100).unwrap();
        let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
        session
            .connect(
                ConnectConfig::new("127.0.0.1".into(), port, "synthetic-user".into()),
                Authentication::Password(Zeroizing::new("synthetic-password".into())),
                HostKeyPolicy::Pinned {
                    sha256: fingerprint,
                },
            )
            .await
            .unwrap();
        Self {
            session: Arc::new(session),
            pending,
            requests,
            serving,
            drain,
            children,
        }
    }
    async fn shutdown(self) {
        self.session.shutdown();
        timeout(Duration::from_secs(4), self.session.wait_closed())
            .await
            .unwrap();
        timeout(Duration::from_secs(3), self.drain)
            .await
            .unwrap()
            .unwrap();
        match timeout(Duration::from_secs(3), self.serving)
            .await
            .unwrap()
            .unwrap()
        {
            Ok(()) => {}
            Err(russh::Error::IO(error))
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::UnexpectedEof | std::io::ErrorKind::ConnectionReset
                ) => {}
            other => panic!("controlled SSH shutdown failed: {other:?}"),
        }
        let children = std::mem::take(&mut *self.children.lock().unwrap());
        for child in children {
            timeout(Duration::from_secs(3), child)
                .await
                .unwrap()
                .unwrap();
        }
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sftp_caller_abort_keeps_all_unknown_opens_bounded_until_original_root_retires() {
    let mut h = Harness::new(Mode::HoldOpens).await;
    let mut calls = Vec::new();
    for _ in 0..64 {
        let owner = h.session.clone();
        calls.push(tokio::spawn(async move { owner.open_sftp().await }));
    }
    let mut held = Vec::new();
    for _ in 0..64 {
        held.push(
            timeout(Duration::from_secs(4), h.pending.recv())
                .await
                .unwrap()
                .unwrap(),
        );
    }
    for call in calls {
        call.abort();
        let Err(error) = call.await else {
            panic!("aborted SFTP caller unexpectedly completed");
        };
        assert!(error.is_cancelled());
    }
    assert!(matches!(
        timeout(Duration::from_secs(2), h.session.open_sftp())
            .await
            .unwrap(),
        Err(SshError::SftpCapacity)
    ));
    assert_eq!(h.requests.load(Ordering::SeqCst), 0);
    h.shutdown().await;
    drop(held);
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn late_sftp_open_ack_closes_without_requesting_a_subsystem_and_leaves_pty_connected() {
    let mut h = Harness::new(Mode::HoldOpens).await;
    let source = h.session.clone();
    let call = tokio::spawn(async move { source.open_sftp().await });
    let (reply, channel) = timeout(Duration::from_secs(3), h.pending.recv())
        .await
        .unwrap()
        .unwrap();
    call.abort();
    let Err(error) = call.await else {
        panic!("aborted SFTP caller unexpectedly completed");
    };
    assert!(error.is_cancelled());
    reply.accept().await;
    let mut stream = channel.into_stream();
    let mut bytes = Vec::new();
    timeout(Duration::from_secs(3), stream.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    assert!(bytes.is_empty());
    assert_eq!(h.requests.load(Ordering::SeqCst), 0);
    assert_eq!(h.session.status().phase, SessionPhase::Connected);
    h.shutdown().await;
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn only_two_channel_retries_are_allowed_and_a_wrong_generation_never_opens_a_subsystem() {
    for fail in [2, usize::MAX] {
        let h = Harness::new(Mode::CloseFirst(fail)).await;
        let generation = h.session.status().generation;
        let result = timeout(
            Duration::from_secs(8),
            h.session
                .open_sftp_with_retry(generation, &CancellationToken::new()),
        )
        .await
        .unwrap();
        assert_eq!(h.requests.load(Ordering::SeqCst), 3);
        if fail == 2 {
            result.unwrap().close().await.unwrap();
        } else {
            assert!(result.is_err());
        }
        assert!(
            h.session
                .open_sftp_with_retry(generation + 1, &CancellationToken::new())
                .await
                .is_err()
        );
        assert_eq!(h.requests.load(Ordering::SeqCst), 3);
        assert_eq!(h.session.status().phase, SessionPhase::Connected);
        h.shutdown().await;
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_subsystem_denial_is_not_retried_and_cancellation_stops_a_transient_attempt() {
    let h = Harness::new(Mode::Deny).await;
    assert!(matches!(
        h.session
            .open_sftp_with_retry(h.session.status().generation, &CancellationToken::new())
            .await,
        Err(SshError::RequestDenied(Stage::Sftp))
    ));
    assert_eq!(h.requests.load(Ordering::SeqCst), 1);
    h.shutdown().await;
    let stop = CancellationToken::new();
    let h = Harness::with_cancel(Mode::CloseFirst(usize::MAX), Some(stop.clone())).await;
    let source = h.session.clone();
    let token = stop.clone();
    let work = tokio::spawn(async move {
        source
            .open_sftp_with_retry(source.status().generation, &token)
            .await
    });
    assert!(work.await.unwrap().is_err());
    assert_eq!(h.requests.load(Ordering::SeqCst), 1);
    h.shutdown().await;
}
