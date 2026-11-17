//! Controlled SSH peer for direct-probe late OPEN ownership. No rsync,
//! source/target authentication or remote helper is executed by this test.
use super::*;
use russh::{Channel, ChannelId, Pty, server};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

struct Peer {
    initial: bool,
    execs: Arc<AtomicUsize>,
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
    async fn agent_request(
        &mut self,
        _: ChannelId,
        _: &mut server::Session,
    ) -> Result<bool, Self::Error> {
        Ok(true)
    }
    async fn exec_request(
        &mut self,
        channel: ChannelId,
        _: &[u8],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.execs.fetch_add(1, Ordering::SeqCst);
        session.channel_failure(channel)
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
async fn cancelled_direct_probe_retains_unknown_open_and_root_close_waits_for_its_worker() {
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
    let execs = Arc::new(AtomicUsize::new(0));
    let observed_execs = execs.clone();
    let serving = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        server::run_stream(
            config,
            socket,
            Peer {
                initial: true,
                execs: observed_execs,
                pty: None,
                requests,
            },
        )
        .await
        .unwrap()
        .await
    });
    let mut connection = ConnectConfig::new("127.0.0.1".into(), port, "synthetic-user".into());
    connection.agent_forwarding = true;
    let mut ssh = SshConnection::connect(
        connection,
        Authentication::Password(Zeroizing::new("synthetic-password".into())),
        HostKeyPolicy::Pinned {
            sha256: fingerprint,
        },
        CancellationToken::new(),
    )
    .await
    .unwrap();
    let cap = ssh.direct_connector();
    let endpoint = ssh.verified_host_key().clone();
    let agent = ssh.agent_connector();
    let grant = agent
        .authorise(
            agent.status().epoch,
            vec![russh::keys::load_secret_key(&key_path, None).unwrap()],
            Duration::from_secs(120),
        )
        .await
        .unwrap();
    let epoch = grant.epoch;
    let cancel = CancellationToken::new();
    let token = cancel.clone();
    let worker = cap.clone();
    let probe_target = endpoint.clone();
    let work = tokio::spawn(async move {
        worker
            .probe(&probe_target, "synthetic-user", epoch, token)
            .await
    });
    let (reply, channel) = timeout(Duration::from_secs(3), pending.recv())
        .await
        .unwrap()
        .unwrap();
    cancel.cancel();
    assert!(work.await.unwrap().is_err());
    // The read-only path now waits for the single slot instead of failing
    // immediately, and the wait stays cancellable without dispatching anything.
    let waiting = CancellationToken::new();
    let waiter_token = waiting.clone();
    let waiter = tokio::spawn({
        let cap = cap.clone();
        let target = endpoint.clone();
        async move {
            cap.probe(&target, "synthetic-user", epoch, waiter_token)
                .await
        }
    });
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        !waiter.is_finished(),
        "a held slot must keep the read-only probe waiting, not failing"
    );
    assert!(
        pending.try_recv().is_err(),
        "cancelled open must still own the only slot"
    );
    waiting.cancel();
    assert!(matches!(
        waiter.await.unwrap(),
        Err(SshError::DirectPreparation(
            hspterm_ssh_core::direct_transfer::DirectPreparationError::Unconfirmed
        ))
    ));
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
    assert_eq!(
        execs.load(Ordering::SeqCst),
        0,
        "late cancellation must not dispatch an exec request"
    );
    assert!(!ssh.is_closed());

    // A new pending channel is admitted only after the actual old worker retires.
    // Retry Busy locally; no failed attempt below can start a second SSH.
    let (reply, channel, work) = timeout(Duration::from_secs(3), async {
        loop {
            let cap = cap.clone();
            let target = endpoint.clone();
            let mut work = tokio::spawn(async move { cap.probe(&target, "synthetic-user", epoch, CancellationToken::new()).await });
            tokio::select! {
                request = pending.recv() => {
                    let (reply, channel) = request.unwrap();
                    break (reply, channel, work);
                }
                result = &mut work => {
                    assert!(matches!(result.unwrap(), Err(SshError::DirectPreparation(hspterm_ssh_core::direct_transfer::DirectPreparationError::Busy))));
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
    assert_eq!(execs.load(Ordering::SeqCst), 0);
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
