//! Controlled SSH peer for late session-channel ACK ownership. Not OpenSSH
//! interoperability and never a remote Python/process signal test.
use super::*;
use russh::{Channel, ChannelId, Pty, server};
use std::sync::Arc;

struct Peer {
    initial: bool,
    pty: Option<Channel<server::Msg>>,
    requests: mpsc::Sender<(server::ChannelOpenHandle, Channel<server::Msg>)>,
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
        if self.initial {
            self.initial = false;
            self.pty = Some(channel);
            reply.accept().await;
        } else {
            self.requests
                .send((reply, channel))
                .await
                .map_err(|_| russh::Error::Disconnect)?;
        }
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
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancelled_inspection_retains_the_single_open_until_late_ack_and_root_close_waits_real_worker()
 {
    let dir = tempfile::tempdir().unwrap();
    let key_path = dir.path().join("synthetic-host");
    generate_key(&key_path, "");
    let key = russh::keys::load_secret_key(&key_path, None).unwrap();
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
    let (requests, mut pending) = mpsc::channel(1);
    let serving = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        server::run_stream(
            config,
            socket,
            Peer {
                initial: true,
                pty: None,
                requests,
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
    let cap = ssh.inspector().unwrap();
    let cancel = CancellationToken::new();
    let token = cancel.clone();
    let worker = cap.clone();
    let work = tokio::spawn(async move { worker.sample(token).await });
    let (reply, channel) = timeout(Duration::from_secs(3), pending.recv())
        .await
        .unwrap()
        .unwrap();
    cancel.cancel();
    assert!(work.await.unwrap().is_err());
    assert!(matches!(
        cap.sample(CancellationToken::new()).await,
        Err(SshError::Inspection(
            hspterm_ssh_core::inspection::InspectionError::Busy
        ))
    ));
    assert!(
        pending.try_recv().is_err(),
        "cancelled open must still own the only slot"
    );
    reply.accept().await;
    let mut stream = channel.into_stream();
    let mut body = Vec::new();
    timeout(Duration::from_secs(3), stream.read_to_end(&mut body))
        .await
        .unwrap()
        .unwrap();
    assert!(
        body.is_empty(),
        "late cancelled channel must not send the probe command"
    );
    assert!(!ssh.is_closed());

    // A new pending channel is admitted only after the actual old worker retires.
    // Retry Busy locally; no failed attempt below can start a second SSH.
    let (reply, channel, work) = timeout(Duration::from_secs(3), async {
        loop {
            let cap = cap.clone();
            let mut work = tokio::spawn(async move { cap.sample(CancellationToken::new()).await });
            tokio::select! {
                request = pending.recv() => {
                    let (reply, channel) = request.unwrap();
                    break (reply, channel, work);
                }
                result = &mut work => {
                    assert!(matches!(result.unwrap(), Err(SshError::Inspection(hspterm_ssh_core::inspection::InspectionError::Busy))));
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
            }
        }
    }).await.unwrap();
    // Do not confirm this second open. Root close must cancel its actual worker
    // rather than waiting for this held external response indefinitely.
    timeout(Duration::from_secs(3), ssh.close())
        .await
        .unwrap()
        .unwrap();
    assert!(work.await.unwrap().is_err());
    drop((reply, channel, stream));
    match timeout(Duration::from_secs(3), serving)
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
        other => panic!("controlled peer shutdown failed: {other:?}"),
    }
}
