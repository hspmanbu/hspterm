//! Controlled real SSH global-request ordering, not OpenSSH interoperability.
use super::incoming::{Fixture, Request};
use super::*;
use hspterm_ssh_core::{
    RemoteForward,
    remote_forward::{RemotePhase, RemoteStatus},
};

async fn request(fixture: &mut Fixture) -> Request {
    timeout(Duration::from_secs(3), fixture.requests.recv())
        .await
        .unwrap()
        .unwrap()
}
async fn started(fixture: &mut Fixture, allocated: u32) {
    match request(fixture).await {
        Request::Start {
            address,
            port,
            reply,
        } => {
            assert_eq!(address, "127.0.0.1");
            assert_eq!(port, 0);
            reply.send(Some(allocated)).unwrap();
        }
        _ => panic!("expected original start request"),
    }
}
async fn cancel(fixture: &mut Fixture, expected: u32) -> tokio::sync::oneshot::Sender<bool> {
    match request(fixture).await {
        Request::Cancel {
            address,
            port,
            reply,
        } => {
            assert_eq!(address, "127.0.0.1");
            assert_eq!(port, expected);
            reply
        }
        _ => panic!("expected cancel of the original allocated port"),
    }
}
async fn settled(state: &mut tokio::sync::watch::Receiver<RemoteStatus>, phase: RemotePhase) {
    timeout(Duration::from_secs(3), async {
        while state.borrow_and_update().phase != phase {
            state.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
}
fn rule(fixture: &Fixture, timeout: Duration) -> RemoteForward {
    fixture
        .ssh
        .remote_connector()
        .unwrap()
        .listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            43211,
            timeout,
        )
        .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn timed_out_start_drains_its_late_port_then_tracks_unknown_cancel_until_ack() {
    let mut fixture = Fixture::new().await;
    let forward = rule(&fixture, Duration::from_millis(80));
    let original = request(&mut fixture).await;
    assert!(matches!(
        forward.wait_started().await,
        Err(SshError::Timeout(_))
    ));
    assert_eq!(forward.status().phase, RemotePhase::CleanupPending);
    match original {
        Request::Start { port, reply, .. } => {
            assert_eq!(port, 0);
            reply.send(Some(34567)).unwrap();
        }
        _ => panic!("start expected"),
    }
    let reply = cancel(&mut fixture, 34567).await;
    let mut state = forward.subscribe();
    settled(&mut state, RemotePhase::CleanupPending).await;
    assert!(matches!(forward.stop().await, Err(SshError::Timeout(_))));
    // No duplicate cancel may be put on the wire while the original is unknown.
    assert!(
        timeout(Duration::from_millis(100), fixture.requests.recv())
            .await
            .is_err()
    );
    reply.send(true).unwrap();
    settled(&mut state, RemotePhase::Stopped).await;
    assert!(matches!(
        forward.wait_started().await,
        Err(SshError::Timeout(_))
    ));
    forward.stop().await.unwrap();
    assert!(!fixture.ssh.is_closed());
    fixture.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropped_owner_and_aborted_start_waiter_do_not_activate_or_leak_a_late_listener() {
    let mut fixture = Fixture::new().await;
    let forward = std::sync::Arc::new(rule(&fixture, Duration::from_secs(3)));
    let mut state = forward.subscribe();
    let owner = forward.clone();
    let waiting = tokio::spawn(async move { owner.wait_started().await });
    let original = request(&mut fixture).await;
    waiting.abort();
    assert!(waiting.await.unwrap_err().is_cancelled());
    drop(forward);
    match original {
        Request::Start { reply, .. } => reply.send(Some(34568)).unwrap(),
        _ => panic!("start expected"),
    }
    cancel(&mut fixture, 34568).await.send(true).unwrap();
    settled(&mut state, RemotePhase::Stopped).await;
    assert!(!fixture.ssh.is_closed());
    fixture.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn aborted_stop_can_be_reawaited_and_definitive_denial_requires_explicit_retry() {
    let mut fixture = Fixture::new().await;
    let forward = std::sync::Arc::new(rule(&fixture, Duration::from_secs(2)));
    started(&mut fixture, 34569).await;
    forward.wait_started().await.unwrap();
    let owner = forward.clone();
    let stopping = tokio::spawn(async move { owner.stop().await });
    let reply = cancel(&mut fixture, 34569).await;
    stopping.abort();
    assert!(stopping.await.unwrap_err().is_cancelled());
    reply.send(false).unwrap();
    let mut state = forward.subscribe();
    settled(&mut state, RemotePhase::CleanupDenied).await;
    assert!(
        timeout(Duration::from_millis(80), fixture.requests.recv())
            .await
            .is_err()
    );
    let owner = forward.clone();
    let retry = tokio::spawn(async move { owner.stop().await });
    cancel(&mut fixture, 34569).await.send(true).unwrap();
    retry.await.unwrap().unwrap();
    assert_eq!(forward.status().phase, RemotePhase::Stopped);
    forward.stop().await.unwrap();
    fixture.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn inbound_routes_require_the_exact_active_rule_and_never_probe_targets_on_start() {
    let mut fixture = Fixture::new().await;
    let local = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let forward = fixture
        .ssh
        .remote_connector()
        .unwrap()
        .listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".into(),
            local.local_addr().unwrap().port(),
            Duration::from_secs(3),
        )
        .unwrap();
    started(&mut fixture, 34570).await;
    forward.wait_started().await.unwrap();
    assert!(
        timeout(Duration::from_millis(50), local.accept())
            .await
            .is_err()
    );
    for (address, port) in [
        ("127.0.0.1", 34571),
        ("127.0.0.2", 34570),
        ("untrusted.invalid", 34570),
    ] {
        let result = fixture
            .peer
            .channel_open_forwarded_tcpip(address, port, "127.0.0.1", 40000)
            .await;
        assert!(matches!(
            result,
            Err(russh::Error::ChannelOpenFailure(
                russh::ChannelOpenFailure::AdministrativelyProhibited
            ))
        ));
    }
    assert!(
        timeout(Duration::from_millis(50), local.accept())
            .await
            .is_err()
    );
    let opening = {
        let handle = fixture.peer.clone();
        tokio::spawn(async move {
            handle
                .channel_open_forwarded_tcpip("127.0.0.1", 34570, "127.0.0.1", 40000)
                .await
                .unwrap()
                .into_stream()
        })
    };
    let (mut socket, _) = timeout(Duration::from_secs(3), local.accept())
        .await
        .unwrap()
        .unwrap();
    let mut stream = opening.await.unwrap();
    stream.write_all(b"authorized").await.unwrap();
    let mut bytes = [0; 10];
    socket.read_exact(&mut bytes).await.unwrap();
    assert_eq!(&bytes, b"authorized");
    let owner = std::sync::Arc::new(forward);
    let stop_owner = owner.clone();
    let stopping = tokio::spawn(async move { stop_owner.stop().await });
    cancel(&mut fixture, 34570).await.send(true).unwrap();
    stopping.await.unwrap().unwrap();
    match timeout(Duration::from_secs(3), socket.read_u8())
        .await
        .unwrap()
    {
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::UnexpectedEof | std::io::ErrorKind::ConnectionReset
            ) => {}
        other => panic!("local target was not closed after explicit stop: {other:?}"),
    }
    fixture.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn inconsistent_allocated_port_cannot_route_or_cancel_an_existing_original_rule() {
    let mut fixture = Fixture::new().await;
    let first = rule(&fixture, Duration::from_secs(3));
    started(&mut fixture, 34572).await;
    first.wait_started().await.unwrap();
    let invalid = rule(&fixture, Duration::from_secs(3));
    started(&mut fixture, 34572).await;
    assert!(matches!(
        invalid.wait_started().await,
        Err(SshError::ForwardWorker)
    ));
    assert_eq!(invalid.status().phase, RemotePhase::CleanupPending);
    assert_eq!(first.status().phase, RemotePhase::Listening);
    assert!(
        timeout(Duration::from_millis(80), fixture.requests.recv())
            .await
            .is_err()
    );
    let owner = std::sync::Arc::new(first);
    let stopping_owner = owner.clone();
    let stopping = tokio::spawn(async move { stopping_owner.stop().await });
    cancel(&mut fixture, 34572).await.send(true).unwrap();
    stopping.await.unwrap().unwrap();
    assert!(
        timeout(Duration::from_millis(80), fixture.requests.recv())
            .await
            .is_err()
    );
    fixture.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn inbound_stream_budget_is_shared_between_rules_and_released_after_stream_close() {
    let mut fixture = Fixture::new().await;
    let local = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let cap = fixture.ssh.remote_connector().unwrap();
    let mut rules = Vec::new();
    for port in [34573, 34574] {
        let rule = cap
            .listen(
                "127.0.0.1:0".parse().unwrap(),
                "127.0.0.1".into(),
                local.local_addr().unwrap().port(),
                Duration::from_secs(3),
            )
            .unwrap();
        started(&mut fixture, port).await;
        rule.wait_started().await.unwrap();
        rules.push(rule);
    }
    let mut sockets = Vec::new();
    let mut streams = Vec::new();
    for index in 0..64 {
        let channel = fixture
            .peer
            .channel_open_forwarded_tcpip(
                "127.0.0.1",
                34573 + index % 2,
                "127.0.0.1",
                40000 + index,
            )
            .await
            .unwrap();
        streams.push(channel.into_stream());
        sockets.push(
            timeout(Duration::from_secs(3), local.accept())
                .await
                .unwrap()
                .unwrap()
                .0,
        );
    }
    let denied = fixture
        .peer
        .channel_open_forwarded_tcpip("127.0.0.1", 34574, "127.0.0.1", 45000)
        .await;
    assert!(matches!(denied, Err(russh::Error::ChannelOpenFailure(_))));
    assert!(
        timeout(Duration::from_millis(50), local.accept())
            .await
            .is_err()
    );
    drop(sockets.pop());
    drop(streams.pop());
    let mut states = rules[1].subscribe();
    timeout(Duration::from_secs(3), async {
        while states.borrow_and_update().active != 31 {
            states.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
    let channel = fixture
        .peer
        .channel_open_forwarded_tcpip("127.0.0.1", 34574, "127.0.0.1", 45001)
        .await
        .unwrap();
    streams.push(channel.into_stream());
    sockets.push(local.accept().await.unwrap().0);
    for (rule, port) in rules.into_iter().zip([34573, 34574]) {
        let owner = std::sync::Arc::new(rule);
        let stopping_owner = owner.clone();
        let stopping = tokio::spawn(async move { stopping_owner.stop().await });
        cancel(&mut fixture, port).await.send(true).unwrap();
        stopping.await.unwrap().unwrap();
        assert_eq!(owner.status().active, 0);
    }
    drop(sockets);
    drop(streams);
    fixture.close().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stopping_during_unconfirmed_start_has_a_finite_deadline_and_drains_the_late_allocation() {
    let mut fixture = Fixture::new().await;
    let forward = rule(&fixture, Duration::from_millis(80));
    let original = request(&mut fixture).await;
    assert!(matches!(
        timeout(Duration::from_secs(1), forward.stop())
            .await
            .unwrap(),
        Err(SshError::Timeout(_))
    ));
    assert_eq!(forward.status().phase, RemotePhase::CleanupPending);
    assert!(matches!(
        forward.wait_started().await,
        Err(SshError::Cancelled)
    ));
    match original {
        Request::Start { reply, .. } => reply.send(Some(34575)).unwrap(),
        _ => panic!("start expected"),
    }
    cancel(&mut fixture, 34575).await.send(true).unwrap();
    let mut state = forward.subscribe();
    settled(&mut state, RemotePhase::Stopped).await;
    forward.stop().await.unwrap();
    fixture.close().await;
}
