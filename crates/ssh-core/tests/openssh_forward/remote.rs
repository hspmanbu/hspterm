use super::*;
use hspterm_ssh_core::remote_forward::{RemoteForward, RemotePhase, RemoteStatus};
use tokio::net::TcpStream;

async fn settled(forward: &RemoteForward, condition: impl Fn(&RemoteStatus) -> bool) {
    let mut state = forward.subscribe();
    timeout(Duration::from_secs(5), async {
        while !condition(&state.borrow_and_update()) {
            state.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_listener_streams_multiple_windows_and_half_close_without_blocking_pty_or_sftp() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = target.local_addr().unwrap().port();
    let echo = tokio::spawn(async move {
        let (mut socket, _) = target.accept().await.unwrap();
        let (mut r, mut w) = socket.split();
        tokio::io::copy(&mut r, &mut w).await.unwrap();
    });
    let cap = session.remote_connector().await.unwrap();
    let forward = cap
        .listen(
            "127.0.0.1:0".parse().unwrap(),
            "localhost".into(),
            port,
            Duration::from_secs(3),
        )
        .unwrap();
    let address = forward.wait_started().await.unwrap();
    assert_ne!(address.port(), 0);
    let mut socket = TcpStream::connect(address).await.unwrap();
    let bytes: Vec<u8> = (0..8 * 1024 * 1024 + 17).map(|i| (i % 251) as u8).collect();
    let (mut r, mut w) = socket.split();
    let (sent, got) = timeout(Duration::from_secs(20), async {
        tokio::join!(
            async {
                w.write_all(&bytes).await?;
                w.shutdown().await
            },
            async {
                let mut result = Vec::new();
                r.read_to_end(&mut result).await?;
                Ok::<_, std::io::Error>(result)
            }
        )
    })
    .await
    .unwrap();
    sent.unwrap();
    assert_eq!(got.unwrap(), bytes);
    echo.await.unwrap();
    session
        .write(b"printf '%s%s\\n' REMOTE_ FORWARD\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "REMOTE_FORWARD").await;
    let sftp = session.open_sftp().await.unwrap();
    sftp.read_dir(server.dir.path().to_str().unwrap())
        .await
        .unwrap();
    sftp.close().await.unwrap();
    settled(&forward, |s| s.active == 0).await;
    assert_eq!(forward.status().accepted, 1);
    assert_eq!(forward.status().failed, 0);
    forward.stop().await.unwrap();
    assert_eq!(forward.status().phase, RemotePhase::Stopped);
    assert!(TcpStream::connect(address).await.is_err());
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_stop_is_independent_and_old_handles_cannot_cancel_recreated_listeners_or_reconnect()
{
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let cap = session.remote_connector().await.unwrap();
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = target.local_addr().unwrap().port();
    let first = cap
        .listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            port,
            Duration::from_secs(3),
        )
        .unwrap();
    let a = first.wait_started().await.unwrap();
    let sibling = cap
        .listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            port,
            Duration::from_secs(3),
        )
        .unwrap();
    let b = sibling.wait_started().await.unwrap();
    first.stop().await.unwrap();
    let later = cap
        .listen(a, "127.0.0.1".into(), port, Duration::from_secs(3))
        .unwrap();
    assert_eq!(later.wait_started().await.unwrap(), a);
    first.stop().await.unwrap();
    for address in [a, b] {
        let mut remote = TcpStream::connect(address).await.unwrap();
        let (mut local, _) = timeout(Duration::from_secs(3), target.accept())
            .await
            .unwrap()
            .unwrap();
        remote.write_all(b"same-original-session").await.unwrap();
        let mut result = [0; 21];
        local.read_exact(&mut result).await.unwrap();
        assert_eq!(&result, b"same-original-session");
    }
    session.disconnect().await.unwrap();
    settled(&sibling, |s| s.phase == RemotePhase::Disconnected).await;
    // Transport teardown does not acknowledge when the remote OS has finally
    // released its listener. Observe eventual cleanup, not instant TCP refusal.
    timeout(Duration::from_secs(3), async {
        while TcpStream::connect(b).await.is_ok() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    assert!(matches!(
        cap.listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            port,
            Duration::from_secs(3)
        ),
        Err(SshError::Disconnected)
    ));
    let fresh = session.remote_connector().await.unwrap();
    let new = fresh
        .listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            port,
            Duration::from_secs(3),
        )
        .unwrap();
    new.wait_started().await.unwrap();
    new.stop().await.unwrap();
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn denied_or_invalid_remote_rules_never_probe_the_local_target_or_disconnect_ssh() {
    let server = Server::start_with_forwarding(false).await;
    let (session, drain) = session(&server).await;
    let cap = session.remote_connector().await.unwrap();
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = target.local_addr().unwrap().port();
    assert!(matches!(
        cap.listen(
            "127.0.0.1:0".parse().unwrap(),
            "bad\r\n.invalid".into(),
            port,
            Duration::from_secs(3)
        ),
        Err(SshError::InvalidConfig)
    ));
    let forward = cap
        .listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            port,
            Duration::from_secs(3),
        )
        .unwrap();
    assert!(matches!(
        forward.wait_started().await,
        Err(SshError::RequestDenied(_))
    ));
    assert_eq!(forward.status().phase, RemotePhase::Failed);
    forward.stop().await.unwrap();
    assert!(
        timeout(Duration::from_millis(50), target.accept())
            .await
            .is_err()
    );
    session
        .write(b"printf '%s%s\\n' REMOTE_ DENIED\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "REMOTE_DENIED").await;
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_slow_local_target_does_not_block_the_remote_forward_ssh_dispatcher() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let cap = session.remote_connector().await.unwrap();
    let forward = cap
        .listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            target.local_addr().unwrap().port(),
            Duration::from_secs(3),
        )
        .unwrap();
    let address = forward.wait_started().await.unwrap();
    let cancel = CancellationToken::new();
    let token = cancel.clone();
    let (flowing, started) = tokio::sync::oneshot::channel();
    let writer = tokio::spawn(async move {
        let mut socket = TcpStream::connect(address).await.unwrap();
        let mut flowing = Some(flowing);
        let chunk = vec![149; 65536];
        for index in 0..256 {
            tokio::select! { biased; _ = token.cancelled() => return, r = socket.write_all(&chunk) => if r.is_err() { return; } }
            if index == 31 {
                let _ = flowing.take().unwrap().send(());
            }
        }
        token.cancelled().await;
    });
    let (slow, _) = timeout(Duration::from_secs(5), target.accept())
        .await
        .unwrap()
        .unwrap();
    timeout(Duration::from_secs(5), started)
        .await
        .unwrap()
        .unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;
    let responsive = timeout(Duration::from_secs(2), async {
        session
            .write(b"printf '%s%s\\n' SLOW_REMOTE_ OK\n".to_vec())
            .await
            .unwrap();
        session_text(&session, "SLOW_REMOTE_OK").await;
    })
    .await
    .is_ok();
    cancel.cancel();
    let stopped = forward.stop().await;
    drop(slow);
    writer.await.unwrap();
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
    assert!(responsive, "slow local target blocked shared PTY");
    stopped.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_rule_limit_is_shared_across_acquisitions_and_released_after_acknowledged_stop() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let cap = session.remote_connector().await.unwrap();
    let again = session.remote_connector().await.unwrap();
    let mut rules = Vec::new();
    for _ in 0..32 {
        let rule = cap
            .listen(
                "127.0.0.1:0".parse().unwrap(),
                "127.0.0.1".into(),
                43211,
                Duration::from_secs(3),
            )
            .unwrap();
        rule.wait_started().await.unwrap();
        rules.push(rule);
    }
    assert!(matches!(
        again.listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            43211,
            Duration::from_secs(3)
        ),
        Err(SshError::Busy)
    ));
    let first = rules.pop().unwrap();
    first.stop().await.unwrap();
    let new = again
        .listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            43211,
            Duration::from_secs(3),
        )
        .unwrap();
    new.wait_started().await.unwrap();
    new.stop().await.unwrap();
    for rule in rules {
        rule.stop().await.unwrap();
    }
    assert_eq!(session.status().phase, SessionPhase::Connected);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_forward_uses_the_authenticated_target_transport_through_one_jump() {
    let jump = Server::start().await;
    let target = Server::start().await;
    let mut config = target.config.clone();
    config.jump = Some(hspterm_ssh_core::JumpHost {
        address: jump.config.address.clone(),
        port: jump.config.port,
        username: jump.config.username.clone(),
        authentication: jump.auth(),
        host_key: jump.pinned(),
    });
    let (session, mut events) = ManagedSession::new(Size::new(80, 24).unwrap(), 100).unwrap();
    let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
    session
        .connect(config, target.auth(), target.pinned())
        .await
        .unwrap();
    let local = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let rule = session
        .remote_connector()
        .await
        .unwrap()
        .listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            local.local_addr().unwrap().port(),
            Duration::from_secs(3),
        )
        .unwrap();
    let mut remote = TcpStream::connect(rule.wait_started().await.unwrap())
        .await
        .unwrap();
    let (mut socket, _) = timeout(Duration::from_secs(3), local.accept())
        .await
        .unwrap()
        .unwrap();
    remote.write_all(b"jump-target").await.unwrap();
    let mut bytes = [0; 11];
    socket.read_exact(&mut bytes).await.unwrap();
    assert_eq!(&bytes, b"jump-target");
    session
        .write(b"printf '%s%s\\n' JUMP_REMOTE_ OK\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "JUMP_REMOTE_OK").await;
    rule.stop().await.unwrap();
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}
