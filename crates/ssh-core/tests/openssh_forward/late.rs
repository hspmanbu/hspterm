//! Controlled real SSH peer: deliberately confirms channels after the caller
//! has cancelled. Complements, and is not counted as, OpenSSH interoperability.
use super::*;
use russh::{Channel, ChannelId, Pty, server};
use std::sync::Arc;

struct Delayed {
    requests: mpsc::Sender<(server::ChannelOpenHandle, Channel<server::Msg>)>,
    sessions: Vec<Channel<server::Msg>>,
}
impl server::Handler for Delayed {
    type Error = russh::Error;
    async fn auth_password(
        &mut self,
        user: &str,
        password: &str,
    ) -> Result<server::Auth, Self::Error> {
        assert_eq!(user, "synthetic-user");
        assert_eq!(password, "synthetic-password");
        Ok(server::Auth::Accept)
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
        channel: ChannelId,
        _: &str,
        _: u32,
        _: u32,
        _: u32,
        _: u32,
        _: &[(Pty, u32)],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)
    }
    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)
    }
    async fn channel_open_direct_tcpip(
        &mut self,
        channel: Channel<server::Msg>,
        host: &str,
        port: u32,
        _: &str,
        _: u32,
        reply: server::ChannelOpenHandle,
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        assert_eq!(host, "server-resolved.invalid");
        assert_eq!(port, 22);
        self.requests
            .send((reply, channel))
            .await
            .map_err(|_| russh::Error::Disconnect)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn timed_out_cancelled_and_aborted_opens_close_their_late_channels_without_closing_ssh() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("synthetic-host");
    generate_key(&path, "");
    let key = russh::keys::decode_secret_key(&fs::read_to_string(path).unwrap(), None).unwrap();
    let fingerprint = key
        .public_key()
        .fingerprint(russh::keys::HashAlg::Sha256)
        .to_string();
    let config = Arc::new(server::Config {
        keys: vec![key],
        auth_rejection_time: Duration::ZERO,
        ..server::Config::default()
    });
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (tx, mut requests) = mpsc::channel(1);
    let server = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        server::run_stream(
            config,
            socket,
            Delayed {
                requests: tx,
                sessions: Vec::new(),
            },
        )
        .await
        .unwrap()
        .await
    });
    let mut ssh = SshConnection::connect(
        ConnectConfig::new("127.0.0.1".into(), port, "synthetic-user".into()),
        Authentication::Password(Zeroizing::new("synthetic-password".into())),
        HostKeyPolicy::Pinned {
            sha256: fingerprint,
        },
        CancellationToken::new(),
    )
    .await
    .unwrap();
    let connector = ssh.tcp_connector().unwrap();
    for kind in 0..3 {
        let cap = connector.clone();
        let cancel = CancellationToken::new();
        let token = cancel.clone();
        let deadline = if kind == 0 {
            Duration::from_millis(100)
        } else {
            Duration::from_secs(5)
        };
        let opening = tokio::spawn(async move {
            cap.open("server-resolved.invalid", 22, origin(), deadline, token)
                .await
        });
        let (reply, channel) = timeout(Duration::from_secs(3), requests.recv())
            .await
            .unwrap()
            .unwrap();
        if kind == 2 {
            opening.abort();
            let Err(error) = opening.await else {
                panic!("aborted caller unexpectedly returned");
            };
            assert!(error.is_cancelled());
        } else {
            if kind == 1 {
                cancel.cancel();
            }
            let result = opening.await.unwrap();
            assert!(matches!(
                (kind, result),
                (0, Err(SshError::Timeout(hspterm_ssh_core::Stage::Forward)))
                    | (1, Err(SshError::Cancelled))
            ));
        }
        let mut stream = channel.into_stream();
        reply.accept().await;
        let mut bytes = Vec::new();
        timeout(Duration::from_secs(3), stream.read_to_end(&mut bytes))
            .await
            .unwrap()
            .unwrap();
        assert!(bytes.is_empty());
        assert!(
            !ssh.is_closed(),
            "the late channel must close, not the owning SSH transport"
        );
    }
    ssh.close().await.unwrap();
    let result = timeout(Duration::from_secs(3), server)
        .await
        .unwrap()
        .unwrap();
    // The owner cancels TCP immediately on close; delivery of the queued SSH
    // disconnect packet is not guaranteed. TCP can report EOF, or a reset when
    // channel-close packets are still unread. Other SSH/IO errors remain failures.
    match result {
        Ok(()) => {}
        Err(russh::Error::IO(error))
            if matches!(
                error.kind(),
                std::io::ErrorKind::UnexpectedEof | std::io::ErrorKind::ConnectionReset
            ) => {}
        other => panic!("unexpected controlled peer shutdown: {other:?}"),
    }
}
