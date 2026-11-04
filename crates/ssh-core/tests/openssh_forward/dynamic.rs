use super::*;
use hspterm_ssh_core::forwarding::LocalForward;
use tokio::net::TcpStream;

fn request(port: u16, domain: bool) -> Vec<u8> {
    let mut bytes = vec![5, 1, 0, 5, 1, 0]; // method + CONNECT, may arrive together
    if domain {
        bytes.extend_from_slice(b"\x03\x09localhost");
    } else {
        bytes.extend_from_slice(b"\x01\x7f\0\0\x01");
    }
    bytes.extend_from_slice(&port.to_be_bytes());
    bytes
}
async fn reply(client: &mut TcpStream, expected: u8) {
    let mut bytes = [0; 12];
    timeout(Duration::from_secs(3), client.read_exact(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&bytes[..2], &[5, 0]);
    assert_eq!(&bytes[2..6], &[5, expected, 0, 1]);
}
async fn settled(forward: &LocalForward, failed: u64) {
    let mut states = forward.subscribe();
    timeout(Duration::from_secs(3), async {
        while states.borrow_and_update().failed != failed {
            states.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dynamic_socks5_pipelining_preserves_binary_payload_and_resolves_domains_on_ssh_server() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let echo = tokio::spawn(async move {
        for _ in 0..2 {
            let (mut socket, _) = listener.accept().await.unwrap();
            let (mut r, mut w) = socket.split();
            tokio::io::copy(&mut r, &mut w).await.unwrap();
        }
    });
    let mut forward = LocalForward::socks5(
        session.tcp_connector().await.unwrap(),
        "127.0.0.1:0".parse().unwrap(),
        Duration::from_secs(3),
    )
    .await
    .unwrap();
    for domain in [false, true] {
        let mut client = TcpStream::connect(forward.local_addr()).await.unwrap();
        let payload = vec![199; 128 * 1024 + 17];
        let mut packet = request(port, domain);
        packet.extend_from_slice(&payload);
        client.write_all(&packet).await.unwrap();
        client.shutdown().await.unwrap();
        reply(&mut client, 0).await;
        let mut result = Vec::new();
        timeout(Duration::from_secs(5), client.read_to_end(&mut result))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result, payload);
    }
    echo.await.unwrap();
    assert_eq!(forward.status().failed, 0);
    session
        .write(b"printf '%s%s\\n' DYNAMIC_ PTY\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "DYNAMIC_PTY").await;
    forward.stop().await.unwrap();
    assert!(forward.status().stopped);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dynamic_ssh_denial_is_an_explicit_socks_failure_without_direct_fallback() {
    let server = Server::start_with_forwarding(false).await;
    let (session, drain) = session(&server).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut forward = LocalForward::socks5(
        session.tcp_connector().await.unwrap(),
        "127.0.0.1:0".parse().unwrap(),
        Duration::from_secs(3),
    )
    .await
    .unwrap();
    let mut client = TcpStream::connect(forward.local_addr()).await.unwrap();
    client
        .write_all(&request(listener.local_addr().unwrap().port(), false))
        .await
        .unwrap();
    reply(&mut client, 2).await;
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    settled(&forward, 1).await;
    assert!(forward.status().last_error.is_some());
    assert_eq!(session.status().phase, SessionPhase::Connected);
    forward.stop().await.unwrap();
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_slow_or_unsupported_socks_client_is_bounded_and_does_not_pin_other_clients_or_ssh() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let mut forward = LocalForward::socks5(
        session.tcp_connector().await.unwrap(),
        "127.0.0.1:0".parse().unwrap(),
        Duration::from_millis(50),
    )
    .await
    .unwrap();
    let mut slow = TcpStream::connect(forward.local_addr()).await.unwrap();
    slow.write_all(&[5]).await.unwrap();
    assert!(
        timeout(Duration::from_secs(2), slow.read_u8())
            .await
            .unwrap()
            .is_err()
    );
    settled(&forward, 1).await;
    let mut unsupported = TcpStream::connect(forward.local_addr()).await.unwrap();
    unsupported.write_all(&[5, 1, 0, 5, 3, 0, 1]).await.unwrap();
    reply(&mut unsupported, 7).await;
    settled(&forward, 2).await;
    assert_eq!(session.status().phase, SessionPhase::Connected);
    forward.stop().await.unwrap();
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dynamic_ipv6_target_round_trips_over_the_ipv4_ssh_transport() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let listener = TcpListener::bind("[::1]:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let echo = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let (mut r, mut w) = socket.split();
        tokio::io::copy(&mut r, &mut w).await.unwrap();
    });
    let mut forward = LocalForward::socks5(
        session.tcp_connector().await.unwrap(),
        "127.0.0.1:0".parse().unwrap(),
        Duration::from_secs(3),
    )
    .await
    .unwrap();
    let mut client = TcpStream::connect(forward.local_addr()).await.unwrap();
    let mut packet = vec![5, 1, 0, 5, 1, 0, 4];
    packet.extend_from_slice(&std::net::Ipv6Addr::LOCALHOST.octets());
    packet.extend_from_slice(&port.to_be_bytes());
    packet.extend_from_slice(b"ipv6-target");
    client.write_all(&packet).await.unwrap();
    client.shutdown().await.unwrap();
    reply(&mut client, 0).await;
    let mut payload = Vec::new();
    client.read_to_end(&mut payload).await.unwrap();
    assert_eq!(payload, b"ipv6-target");
    echo.await.unwrap();
    forward.stop().await.unwrap();
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stopping_dynamic_listener_cancels_an_unfinished_long_handshake_without_waiting_for_timeout()
 {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let mut forward = LocalForward::socks5(
        session.tcp_connector().await.unwrap(),
        "127.0.0.1:0".parse().unwrap(),
        Duration::from_secs(30),
    )
    .await
    .unwrap();
    let mut client = TcpStream::connect(forward.local_addr()).await.unwrap();
    client.write_all(&[5]).await.unwrap();
    let mut states = forward.subscribe();
    timeout(Duration::from_secs(3), async {
        while states.borrow_and_update().accepted != 1 {
            states.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
    timeout(Duration::from_secs(1), forward.stop())
        .await
        .unwrap()
        .unwrap();
    assert!(
        timeout(Duration::from_secs(1), client.read_u8())
            .await
            .unwrap()
            .is_err()
    );
    assert_eq!(forward.status().failed, 0);
    assert!(forward.status().stopped);
    assert_eq!(session.status().phase, SessionPhase::Connected);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}
