use super::*;
use hspterm_ssh_core::forwarding::LocalForward;

async fn settled(
    forward: &LocalForward,
    condition: impl Fn(&hspterm_ssh_core::forwarding::ForwardStatus) -> bool,
) {
    let mut states = forward.subscribe();
    timeout(Duration::from_secs(3), async {
        while !condition(&states.borrow_and_update()) {
            states.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn local_listener_forwards_exact_bytes_and_half_close_while_terminal_stays_responsive() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let target_port = target.local_addr().unwrap().port();
    let echo = tokio::spawn(async move {
        let (mut socket, _) = target.accept().await.unwrap();
        let (mut r, mut w) = socket.split();
        tokio::io::copy(&mut r, &mut w).await.unwrap();
    });
    let mut forward = LocalForward::start(
        session.tcp_connector().await.unwrap(),
        "127.0.0.1:0".parse().unwrap(),
        "localhost".into(),
        target_port,
        Duration::from_secs(3),
    )
    .await
    .unwrap();
    let addr = forward.local_addr();
    let mut client = tokio::net::TcpStream::connect(addr).await.unwrap();
    let bytes = vec![239; 128 * 1024 + 23];
    client.write_all(&bytes).await.unwrap();
    client.shutdown().await.unwrap();
    session
        .write(b"printf '%s%s\\n' LOCAL_ FORWARD\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "LOCAL_FORWARD").await;
    let mut result = Vec::new();
    timeout(Duration::from_secs(5), client.read_to_end(&mut result))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result, bytes);
    echo.await.unwrap();
    settled(&forward, |s| s.accepted == 1 && s.active == 0).await;
    assert_eq!(forward.status().failed, 0);
    assert!(forward.status().last_error.is_none());
    forward.stop().await.unwrap();
    forward.stop().await.unwrap();
    assert!(forward.status().stopped);
    assert!(tokio::net::TcpStream::connect(addr).await.is_err());
    assert_eq!(session.status().phase, SessionPhase::Connected);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stopping_one_listener_preserves_sibling_and_ssh_disconnect_releases_all_old_listeners() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = target.local_addr().unwrap().port();
    let echo = tokio::spawn(async move {
        let mut jobs = tokio::task::JoinSet::new();
        for _ in 0..2 {
            let (mut socket, _) = target.accept().await.unwrap();
            jobs.spawn(async move {
                let (mut r, mut w) = socket.split();
                tokio::io::copy(&mut r, &mut w).await.unwrap();
            });
        }
        while let Some(job) = jobs.join_next().await {
            job.unwrap();
        }
    });
    let cap = session.tcp_connector().await.unwrap();
    let mut a = LocalForward::start(
        cap.clone(),
        "127.0.0.1:0".parse().unwrap(),
        "127.0.0.1".into(),
        port,
        Duration::from_secs(3),
    )
    .await
    .unwrap();
    let mut b = LocalForward::start(
        cap.clone(),
        "127.0.0.1:0".parse().unwrap(),
        "127.0.0.1".into(),
        port,
        Duration::from_secs(3),
    )
    .await
    .unwrap();
    let mut ca = tokio::net::TcpStream::connect(a.local_addr())
        .await
        .unwrap();
    let mut cb = tokio::net::TcpStream::connect(b.local_addr())
        .await
        .unwrap();
    for c in [&mut ca, &mut cb] {
        c.write_all(b"x").await.unwrap();
        assert_eq!(c.read_u8().await.unwrap(), b'x');
    }
    a.stop().await.unwrap();
    assert!(
        timeout(Duration::from_secs(3), ca.read_u8())
            .await
            .unwrap()
            .is_err()
    );
    cb.write_all(b"b").await.unwrap();
    assert_eq!(cb.read_u8().await.unwrap(), b'b');
    assert!(!b.status().stopped);
    assert_eq!(session.status().phase, SessionPhase::Connected);
    let generation = session.status().generation;
    session.disconnect().await.unwrap();
    settled(&b, |s| s.stopped).await;
    b.stop().await.unwrap();
    assert!(
        timeout(Duration::from_secs(3), cb.read_u8())
            .await
            .unwrap()
            .is_err()
    );
    assert!(
        tokio::net::TcpStream::connect(b.local_addr())
            .await
            .is_err()
    );
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    assert_eq!(session.status().generation, generation + 1);
    assert!(
        LocalForward::start(
            cap,
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            port,
            Duration::from_secs(3)
        )
        .await
        .is_err()
    );
    echo.await.unwrap();
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn denied_forward_reports_failure_without_terminating_ssh_or_claiming_success() {
    let server = Server::start_with_forwarding(false).await;
    let (session, drain) = session(&server).await;
    let mut forward = LocalForward::start(
        session.tcp_connector().await.unwrap(),
        "127.0.0.1:0".parse().unwrap(),
        "127.0.0.1".into(),
        22,
        Duration::from_secs(3),
    )
    .await
    .unwrap();
    let mut client = tokio::net::TcpStream::connect(forward.local_addr())
        .await
        .unwrap();
    assert!(
        timeout(Duration::from_secs(3), client.read_u8())
            .await
            .unwrap()
            .is_err()
    );
    settled(&forward, |s| s.failed == 1).await;
    assert_eq!(forward.status().active, 0);
    assert!(forward.status().last_error.is_some());
    assert!(!forward.status().stopped);
    assert_eq!(session.status().phase, SessionPhase::Connected);
    forward.stop().await.unwrap();
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn invalid_targets_and_occupied_ports_fail_before_listener_publication() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let cap = session.tcp_connector().await.unwrap();
    let occupied = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let bind = occupied.local_addr().unwrap();
    for (target, port, deadline) in [
        ("https://invalid/path", 22, Duration::from_secs(1)),
        ("localhost", 0, Duration::from_secs(1)),
        ("localhost", 22, Duration::ZERO),
    ] {
        assert!(matches!(
            LocalForward::start(cap.clone(), bind, target.into(), port, deadline).await,
            Err(SshError::InvalidConfig)
        ));
    }
    assert!(matches!(
        LocalForward::start(cap, bind, "localhost".into(), 22, Duration::from_secs(1)).await,
        Err(SshError::Io(_))
    ));
    assert_eq!(session.status().phase, SessionPhase::Connected);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test]
async fn aborting_a_stop_future_does_not_make_a_repeated_stop_return_before_cleanup() {
    use std::{
        future::{Future, poll_fn},
        task::Poll,
    };
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let mut forward = LocalForward::start(
        session.tcp_connector().await.unwrap(),
        "127.0.0.1:0".parse().unwrap(),
        "localhost".into(),
        22,
        Duration::from_secs(3),
    )
    .await
    .unwrap();
    // Current-thread runtime: poll the stop once without scheduling its runner,
    // then abandon that caller. A second caller must still wait for the runner.
    let mut first = Box::pin(forward.stop());
    assert!(poll_fn(|cx| Poll::Ready(first.as_mut().poll(cx).is_pending())).await);
    drop(first);
    let mut second = Box::pin(forward.stop());
    assert!(
        poll_fn(|cx| Poll::Ready(second.as_mut().poll(cx).is_pending())).await,
        "a cancelled stop must not detach its cleanup from future stop callers"
    );
    second.await.unwrap();
    assert!(forward.status().stopped);
    assert!(
        tokio::net::TcpStream::connect(forward.local_addr())
            .await
            .is_err()
    );
    assert_eq!(session.status().phase, SessionPhase::Connected);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_slow_local_tcp_reader_does_not_block_pty_on_the_shared_ssh_transport() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let stop = CancellationToken::new();
    let token = stop.clone();
    let (flowing, started) = tokio::sync::oneshot::channel();
    let writer = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let bytes = vec![149; 64 * 1024];
        let mut flowing = Some(flowing);
        for index in 0..256 {
            tokio::select! {
                biased;
                _ = token.cancelled() => return,
                result = socket.write_all(&bytes) => if result.is_err() { return; },
            }
            if index == 31 {
                let _ = flowing.take().unwrap().send(());
            }
        }
        token.cancelled().await;
    });
    let mut forward = LocalForward::start(
        session.tcp_connector().await.unwrap(),
        "127.0.0.1:0".parse().unwrap(),
        "127.0.0.1".into(),
        port,
        Duration::from_secs(3),
    )
    .await
    .unwrap();
    let slow = tokio::net::TcpStream::connect(forward.local_addr())
        .await
        .unwrap();
    timeout(Duration::from_secs(5), started)
        .await
        .unwrap()
        .unwrap();
    // Real socket backpressure: the client deliberately consumes no bytes.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let responsive = timeout(Duration::from_secs(2), async {
        session
            .write(b"printf '%s%s\\n' SLOW_ FORWARD_OK\n".to_vec())
            .await
            .unwrap();
        session_text(&session, "SLOW_FORWARD_OK").await;
    })
    .await
    .is_ok();
    // Cleanup before asserting, including the failure path, so a blocked shared
    // dispatch loop does not leave fixture transports or sockets behind.
    stop.cancel();
    forward.stop().await.unwrap();
    drop(slow);
    writer.await.unwrap();
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
    assert!(
        responsive,
        "a slow forwarded TCP reader blocked the independent PTY for over two seconds"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn local_forward_replenishes_many_receive_windows_without_losing_any_binary_byte() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let echo = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let (mut r, mut w) = socket.split();
        tokio::io::copy(&mut r, &mut w).await.unwrap();
    });
    let mut forward = LocalForward::start(
        session.tcp_connector().await.unwrap(),
        "127.0.0.1:0".parse().unwrap(),
        "127.0.0.1".into(),
        port,
        Duration::from_secs(3),
    )
    .await
    .unwrap();
    let mut client = tokio::net::TcpStream::connect(forward.local_addr())
        .await
        .unwrap();
    let (mut r, mut w) = client.split();
    let writing = async {
        let bytes = (0..65536).map(|n| (n % 251) as u8).collect::<Vec<_>>();
        for _ in 0..128 {
            w.write_all(&bytes).await.unwrap();
        }
        w.write_all(&bytes[..17]).await.unwrap();
        w.shutdown().await.unwrap();
    };
    let reading = async {
        let mut buffer = vec![0; 4093];
        let mut offset = 0;
        loop {
            let count = r.read(&mut buffer).await.unwrap();
            if count == 0 {
                break;
            }
            for (index, byte) in buffer[..count].iter().enumerate() {
                assert_eq!(*byte, (((offset + index) % 65536) % 251) as u8);
            }
            offset += count;
        }
        assert_eq!(offset, 8 * 1024 * 1024 + 17);
    };
    timeout(Duration::from_secs(15), async {
        tokio::join!(writing, reading);
    })
    .await
    .unwrap();
    echo.await.unwrap();
    forward.stop().await.unwrap();
    assert_eq!(forward.status().failed, 0);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}
