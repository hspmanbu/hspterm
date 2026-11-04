use super::*;
use hspterm_ssh_core::{ManagedSession, SessionPhase};
use std::net::SocketAddr;
use tokio::net::TcpListener;
mod dynamic;
mod incoming;
mod late;
mod local;
mod remote;
mod remote_late;

async fn session(server: &Server) -> (ManagedSession, tokio::task::JoinHandle<()>) {
    let (session, mut events) = ManagedSession::new(Size::new(80, 24).unwrap(), 100).unwrap();
    let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    (session, drain)
}
fn origin() -> SocketAddr {
    "127.0.0.1:54321".parse().unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn channel_capacity_is_shared_across_acquisitions_and_released_without_reconnecting() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let connector = session.tcp_connector().await.unwrap();
    let mut streams = Vec::new();
    let mut remote = Vec::new();
    for _ in 0..64 {
        streams.push(
            connector
                .open(
                    "127.0.0.1",
                    port,
                    origin(),
                    Duration::from_secs(3),
                    CancellationToken::new(),
                )
                .await
                .unwrap(),
        );
        remote.push(listener.accept().await.unwrap().0);
    }
    let again = session.tcp_connector().await.unwrap();
    assert!(matches!(
        again
            .open(
                "127.0.0.1",
                port,
                origin(),
                Duration::from_millis(25),
                CancellationToken::new()
            )
            .await,
        Err(SshError::Timeout(hspterm_ssh_core::Stage::Forward))
    ));
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert!(matches!(
        again
            .open("127.0.0.1", port, origin(), Duration::from_secs(3), cancel)
            .await,
        Err(SshError::Cancelled)
    ));
    drop(streams.pop());
    let stream = again
        .open(
            "127.0.0.1",
            port,
            origin(),
            Duration::from_secs(3),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    remote.push(listener.accept().await.unwrap().0);
    assert_eq!(session.status().phase, SessionPhase::Connected);
    drop(stream);
    drop(streams);
    drop(remote);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn direct_tcpip_capability_streams_binary_data_without_blocking_pty_or_sftp() {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let echo = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let (mut reader, mut writer) = socket.split();
        tokio::io::copy(&mut reader, &mut writer).await.unwrap();
    });
    let connector = session.tcp_connector().await.unwrap();
    for address in [
        "https://invalid/path",
        "bad\r\n.invalid",
        "target\0.invalid",
        "[not-ipv6]",
    ] {
        assert!(matches!(
            connector
                .open(
                    address,
                    port,
                    origin(),
                    Duration::from_secs(3),
                    CancellationToken::new()
                )
                .await,
            Err(SshError::InvalidConfig)
        ));
    }
    assert!(matches!(
        connector
            .open(
                "127.0.0.1",
                0,
                origin(),
                Duration::from_secs(3),
                CancellationToken::new()
            )
            .await,
        Err(SshError::InvalidConfig)
    ));
    assert!(matches!(
        connector
            .open(
                "127.0.0.1",
                port,
                origin(),
                Duration::ZERO,
                CancellationToken::new()
            )
            .await,
        Err(SshError::InvalidConfig)
    ));
    let mut stream = connector
        .open(
            "localhost",
            port,
            origin(),
            Duration::from_secs(3),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let payload = (0..256 * 1024 + 37)
        .map(|n| (n % 251) as u8)
        .collect::<Vec<_>>();
    stream.write_all(&payload).await.unwrap();
    stream.shutdown().await.unwrap();
    // While channel data is in flight, the same session actor must drain PTY.
    session
        .write(b"printf '%s%s\\n' FORWARD_ PTY\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "FORWARD_PTY").await;
    let sftp = session.open_sftp().await.unwrap();
    assert!(
        sftp.read_dir(server.dir.path().to_str().unwrap())
            .await
            .unwrap()
            .next()
            .is_some()
    );
    sftp.close().await.unwrap();
    let mut result = Vec::new();
    timeout(Duration::from_secs(5), stream.read_to_end(&mut result))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(result, payload);
    echo.await.unwrap();
    assert_eq!(session.status().phase, SessionPhase::Connected);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancelling_one_forward_stream_does_not_cancel_ssh_and_old_capabilities_cannot_survive_reconnect()
 {
    let server = Server::start().await;
    let (session, drain) = session(&server).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let old = session.tcp_connector().await.unwrap();
    let cancel = CancellationToken::new();
    let mut stream = old
        .open(
            "127.0.0.1",
            port,
            origin(),
            Duration::from_secs(3),
            cancel.clone(),
        )
        .await
        .unwrap();
    let (mut remote, _) = listener.accept().await.unwrap();
    cancel.cancel();
    assert!(
        timeout(Duration::from_secs(1), stream.read_u8())
            .await
            .unwrap()
            .is_err()
    );
    drop(stream);
    let mut rest = Vec::new();
    timeout(Duration::from_secs(3), remote.read_to_end(&mut rest))
        .await
        .unwrap()
        .unwrap();
    session
        .write(b"printf '%s%s\\n' AFTER_ CHANNEL_CANCEL\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "AFTER_CHANNEL_CANCEL").await;
    let mut stream = old
        .open(
            "127.0.0.1",
            port,
            origin(),
            Duration::from_secs(3),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let (mut remote, _) = listener.accept().await.unwrap();
    let generation = session.status().generation;
    session.disconnect().await.unwrap();
    assert!(
        timeout(Duration::from_secs(1), stream.read_u8())
            .await
            .unwrap()
            .is_err()
    );
    drop(stream);
    timeout(Duration::from_secs(3), remote.read_to_end(&mut rest))
        .await
        .unwrap()
        .unwrap();
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    assert_eq!(session.status().generation, generation + 1);
    assert!(matches!(
        old.open(
            "127.0.0.1",
            port,
            origin(),
            Duration::from_secs(3),
            CancellationToken::new()
        )
        .await,
        Err(SshError::Cancelled | SshError::Disconnected)
    ));
    let fresh = session.tcp_connector().await.unwrap();
    let mut stream = fresh
        .open(
            "127.0.0.1",
            port,
            origin(),
            Duration::from_secs(3),
            CancellationToken::new(),
        )
        .await
        .unwrap();
    let (mut remote, _) = listener.accept().await.unwrap();
    stream.write_all(b"new-generation-only").await.unwrap();
    let mut bytes = [0; 19];
    remote.read_exact(&mut bytes).await.unwrap();
    assert_eq!(&bytes, b"new-generation-only");
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn server_denial_never_falls_back_to_direct_tcp_and_does_not_disconnect_the_terminal() {
    let server = Server::start_with_forwarding(false).await;
    let (session, drain) = session(&server).await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let connector = session.tcp_connector().await.unwrap();
    assert!(matches!(
        connector
            .open(
                "127.0.0.1",
                listener.local_addr().unwrap().port(),
                origin(),
                Duration::from_secs(3),
                CancellationToken::new()
            )
            .await,
        Err(SshError::Protocol(_))
    ));
    assert!(
        timeout(Duration::from_millis(50), listener.accept())
            .await
            .is_err()
    );
    session
        .write(b"printf '%s%s\\n' FORWARD_ DENIED\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "FORWARD_DENIED").await;
    assert_eq!(session.status().phase, SessionPhase::Connected);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}
