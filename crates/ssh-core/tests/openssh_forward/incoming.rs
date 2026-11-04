//! A real SSH peer must not obtain unsolicited inbound channels merely because
//! russh's default callbacks accept them. No system agent or local TCP is used.
use super::*;
use russh::{Channel, ChannelId, Pty, server};
use std::sync::Arc;

pub(super) enum Request {
    Start {
        address: String,
        port: u32,
        reply: tokio::sync::oneshot::Sender<Option<u32>>,
    },
    Cancel {
        address: String,
        port: u32,
        reply: tokio::sync::oneshot::Sender<bool>,
    },
}
struct Peer {
    requests: mpsc::Sender<Request>,
    ready: Option<tokio::sync::oneshot::Sender<server::Handle>>,
    sessions: Vec<Channel<server::Msg>>,
}
impl server::Handler for Peer {
    type Error = russh::Error;
    async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
        Ok(server::Auth::Accept)
    }
    async fn tcpip_forward(
        &mut self,
        address: &str,
        port: &mut u32,
        _: &mut server::Session,
    ) -> Result<bool, Self::Error> {
        let (reply, response) = tokio::sync::oneshot::channel();
        if self
            .requests
            .send(Request::Start {
                address: address.into(),
                port: *port,
                reply,
            })
            .await
            .is_err()
        {
            return Ok(false);
        }
        match response.await {
            Ok(Some(value)) => {
                *port = value;
                Ok(true)
            }
            _ => Ok(false),
        }
    }
    async fn cancel_tcpip_forward(
        &mut self,
        address: &str,
        port: u32,
        _: &mut server::Session,
    ) -> Result<bool, Self::Error> {
        let (reply, response) = tokio::sync::oneshot::channel();
        if self
            .requests
            .send(Request::Cancel {
                address: address.into(),
                port,
                reply,
            })
            .await
            .is_err()
        {
            return Ok(false);
        }
        Ok(response.await.unwrap_or(false))
    }
    async fn channel_open_session(
        &mut self,
        channel: Channel<server::Msg>,
        reply: server::ChannelOpenHandle,
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.sessions.push(channel);
        reply.accept().await;
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
        session.channel_success(id)?;
        self.ready.take().unwrap().send(session.handle()).unwrap();
        Ok(())
    }
}

pub(super) struct Fixture {
    pub ssh: SshConnection,
    pub peer: server::Handle,
    pub requests: mpsc::Receiver<Request>,
    serving: tokio::task::JoinHandle<Result<(), russh::Error>>,
}
impl Fixture {
    pub async fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let key_path = dir.path().join("synthetic-host");
        generate_key(&key_path, "");
        let key =
            russh::keys::decode_secret_key(&fs::read_to_string(key_path).unwrap(), None).unwrap();
        let fingerprint = key
            .public_key()
            .fingerprint(russh::keys::HashAlg::Sha256)
            .to_string();
        let config = Arc::new(server::Config {
            keys: vec![key],
            auth_rejection_time: Duration::ZERO,
            ..Default::default()
        });
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (ready, receive) = tokio::sync::oneshot::channel();
        let (requests_tx, requests) = mpsc::channel(64);
        let serving = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            server::run_stream(
                config,
                socket,
                Peer {
                    requests: requests_tx,
                    ready: Some(ready),
                    sessions: Vec::new(),
                },
            )
            .await
            .unwrap()
            .await
        });
        let ssh = SshConnection::connect(
            ConnectConfig::new("127.0.0.1".into(), port, "synthetic-user".into()),
            Authentication::Password(Zeroizing::new("synthetic-password".into())),
            HostKeyPolicy::Pinned {
                sha256: fingerprint,
            },
            CancellationToken::new(),
        )
        .await
        .unwrap();
        Self {
            ssh,
            peer: receive.await.unwrap(),
            requests,
            serving,
        }
    }
    pub async fn close(mut self) {
        self.ssh.close().await.unwrap();
        match timeout(Duration::from_secs(3), self.serving)
            .await
            .unwrap()
            .unwrap()
        {
            Ok(()) => {}
            Err(russh::Error::IO(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::UnexpectedEof | std::io::ErrorKind::ConnectionReset
                ) => {}
            other => panic!("unexpected peer shutdown: {other:?}"),
        }
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn unsolicited_server_channels_are_rejected_without_disconnecting_the_terminal() {
    let fixture = Fixture::new().await;
    let peer = fixture.peer.clone();

    let mut rejected = Vec::new();
    macro_rules! check {
        ($name:expr, $open:expr) => {{
            let result = timeout(Duration::from_secs(2), $open).await;
            let denied = matches!(
                result,
                Ok(Err(russh::Error::ChannelOpenFailure(
                    russh::ChannelOpenFailure::AdministrativelyProhibited
                )))
            );
            if let Ok(Ok(channel)) = result {
                drop(channel.into_stream());
            }
            rejected.push(($name, denied));
        }};
    }
    check!(
        "forwarded-tcpip",
        peer.channel_open_forwarded_tcpip("127.0.0.1", 43210, "127.0.0.1", 12345)
    );
    check!("agent", peer.channel_open_agent());
    check!("session", peer.channel_open_session());
    check!(
        "direct-tcpip",
        peer.channel_open_direct_tcpip("127.0.0.1", 43210, "127.0.0.1", 12345)
    );
    check!(
        "forwarded-streamlocal",
        peer.channel_open_forwarded_streamlocal("/synthetic/unrequested.sock")
    );
    check!(
        "direct-streamlocal",
        peer.channel_open_direct_streamlocal("/synthetic/unrequested.sock")
    );
    check!("x11", peer.channel_open_x11("127.0.0.1", 12345));
    assert!(!fixture.ssh.is_closed());
    fixture.close().await;
    assert!(
        rejected.iter().all(|(_, denied)| *denied),
        "unsolicited acceptance: {rejected:?}"
    );
}
