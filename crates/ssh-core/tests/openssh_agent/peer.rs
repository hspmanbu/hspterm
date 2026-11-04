//! Real SSH transport against a controlled RFC9987 peer (not real OpenSSH).
use super::*;
use russh::{Channel, ChannelId, ChannelMsg, Pty, server};
use std::sync::{
    Arc,
    atomic::{AtomicU8, Ordering},
};
use tokio::sync::oneshot;

struct Peer {
    ready: Option<oneshot::Sender<(server::Handle, ChannelId)>>,
    requested: Arc<AtomicU8>,
}
impl server::Handler for Peer {
    type Error = russh::Error;
    async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
        Ok(server::Auth::Accept)
    }
    async fn channel_open_session(
        &mut self,
        mut channel: Channel<server::Msg>,
        reply: server::ChannelOpenHandle,
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        let requested = self.requested.clone();
        tokio::spawn(async move {
            while let Some(message) = channel.wait().await {
                match message {
                    ChannelMsg::AgentForward { .. } => {
                        requested.store(1, Ordering::SeqCst);
                    }
                    ChannelMsg::AgentForwardStandard { .. } => {
                        requested.store(2, Ordering::SeqCst);
                    }
                    ChannelMsg::Close => break,
                    _ => {}
                }
            }
        });
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
    async fn agent_request(
        &mut self,
        _: ChannelId,
        _: &mut server::Session,
    ) -> Result<bool, Self::Error> {
        Ok(true)
    }
    async fn shell_request(
        &mut self,
        id: ChannelId,
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(id)?;
        self.ready.take().unwrap().send((session.handle(), id)).ok();
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agent_standard_negotiation_and_legacy_aliases_are_authorized_once_and_bounded() {
    for standard in [false, true] {
        let key = PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519).unwrap();
        let fingerprint = key.public_key().fingerprint(HashAlg::Sha256).to_string();
        let config = Arc::new(server::Config {
            keys: vec![key],
            auth_rejection_time: Duration::ZERO,
            agent_forwarding_v0: standard,
            ..Default::default()
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (ready, response) = oneshot::channel();
        let requested = Arc::new(AtomicU8::new(0));
        let peer = Peer {
            ready: Some(ready),
            requested: requested.clone(),
        };
        let serving = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            server::run_stream(config, stream, peer)
                .await
                .unwrap()
                .await
        });
        let mut config = ConnectConfig::new("127.0.0.1".into(), port, "fixture".into());
        config.agent_forwarding = true;
        let (session, mut events) = ManagedSession::new(Size::new(120, 30).unwrap(), 100).unwrap();
        let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
        session
            .connect(
                config,
                Authentication::Password(Zeroizing::new("synthetic".into())),
                HostKeyPolicy::Pinned {
                    sha256: fingerprint,
                },
            )
            .await
            .unwrap();
        let (peer, pty) = response.await.unwrap();
        let agent = session.agent_connector().await.unwrap();
        assert_eq!(agent.status().phase, AgentPhase::Ready);
        assert!(peer.channel_open_agent().await.is_err());
        let selected =
            PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519).unwrap();
        let public_blob = selected.public_key().to_bytes().unwrap();
        agent
            .authorise(0, vec![selected], Duration::from_secs(60))
            .await
            .unwrap();
        timeout(Duration::from_secs(2), async {
            while requested.load(Ordering::SeqCst) == 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert_eq!(
            requested.load(Ordering::SeqCst),
            if standard { 2 } else { 1 }
        );
        // Both channel aliases reach the same original grant, not two sessions.
        for alias in [false, true] {
            let channel = if alias {
                peer.channel_open_agent_standard().await
            } else {
                peer.channel_open_agent().await
            }
            .unwrap();
            let mut stream = channel.into_stream();
            stream.write_all(&[0, 0, 0, 1, 11]).await.unwrap();
            let length = stream.read_u32().await.unwrap();
            assert!(length < 16384);
            let mut bytes = vec![0; length as usize];
            stream.read_exact(&mut bytes).await.unwrap();
            assert_eq!(&bytes[..5], &[12, 0, 0, 0, 1]);
        }
        // An oversized frame is rejected per-stream and counted, not swallowed.
        let mut malformed = peer.channel_open_agent().await.unwrap().into_stream();
        malformed.write_all(&[0xff; 4]).await.unwrap();
        let mut byte = [0];
        assert_eq!(
            timeout(Duration::from_secs(2), malformed.read(&mut byte))
                .await
                .unwrap()
                .unwrap(),
            0
        );
        assert_eq!(agent.status().failed_streams, 1);
        // Four signing streams exert sustained inbound pressure. Drain replies
        // on this controlled peer: its upstream default queue is intentionally
        // not flow-controlled, so an unread peer queue would stall the peer's
        // own dispatcher, testing the wrong endpoint. The real OpenSSH test
        // separately exercises a remote consumer which does not read replies.
        let mut floods = Vec::new();
        let mut frame = vec![13];
        frame.extend_from_slice(&(public_blob.len() as u32).to_be_bytes());
        frame.extend_from_slice(&public_blob);
        frame.extend_from_slice(&(128u32 * 1024).to_be_bytes());
        frame.resize(frame.len() + 128 * 1024, 65);
        frame.extend_from_slice(&0u32.to_be_bytes());
        let mut body = (frame.len() as u32).to_be_bytes().to_vec();
        body.extend(frame);
        for _ in 0..4 {
            let stream = peer.channel_open_agent().await.unwrap().into_stream();
            let body = body.clone();
            floods.push(tokio::spawn(async move {
                let (mut reader, mut writer) = tokio::io::split(stream);
                let mut sink = tokio::io::sink();
                tokio::select! {
                    _ = tokio::io::copy(&mut reader, &mut sink) => {},
                    _ = async { loop { if writer.write_all(&body).await.is_err() { break; } } } => {},
                }
            }));
        }
        assert!(
            timeout(Duration::from_secs(2), peer.channel_open_agent())
                .await
                .unwrap()
                .is_err()
        );
        peer.data(pty, bytes::Bytes::from_static(b"AGENT_FLOW_PTY_OK\r\n"))
            .await
            .unwrap();
        text(&session, "AGENT_FLOW_PTY_OK").await;
        agent.revoke().await.unwrap();
        for flood in floods {
            flood.abort();
            if let Err(error) = flood.await {
                assert!(error.is_cancelled());
            }
        }
        assert!(
            !session
                .status()
                .phase
                .eq(&hspterm_ssh_core::SessionPhase::Disconnected)
        );
        finish(session, drain).await;
        let result = timeout(Duration::from_secs(3), serving)
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(
            result,
            Ok(())
                | Err(russh::Error::IO(_))
                | Err(russh::Error::HUP)
                | Err(russh::Error::Disconnect)
        ));
    }
}
