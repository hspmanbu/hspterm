use super::*;
use hspterm_ssh_core::{JumpHost, ManagedSession, ProxyConfig, ProxyKind, SessionPhase, Stage};
use tokio::net::{TcpListener, TcpStream};

fn jump_host(server: &Server) -> JumpHost {
    JumpHost {
        address: server.config.address.clone(),
        port: server.config.port,
        username: server.config.username.clone(),
        authentication: server.auth(),
        host_key: server.pinned(),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn proxy_jump_and_target_handshake_share_one_total_timeout_and_release_sockets() {
    let jump = Server::start().await;
    let jump_port = jump.config.port;
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut config = ConnectConfig::new(
        "127.0.0.1".into(),
        target.local_addr().unwrap().port(),
        "not-authenticated".into(),
    );
    config.timeout = Duration::from_secs(3);
    config.jump = Some(jump_host(&jump));
    config.proxy = Some(ProxyConfig {
        kind: ProxyKind::HttpConnect,
        address: "127.0.0.1".into(),
        port: proxy.local_addr().unwrap().port(),
        authentication: None,
    });
    let relay = tokio::spawn(async move {
        let (mut client, _) = proxy.accept().await.unwrap();
        let mut header = Vec::new();
        while !header.ends_with(b"\r\n\r\n") {
            header.push(client.read_u8().await.unwrap());
            assert!(header.len() < 4096);
        }
        assert!(
            header.starts_with(format!("CONNECT 127.0.0.1:{jump_port} HTTP/1.1\r\n").as_bytes())
        );
        // A real elapsed delay at an earlier stage must consume the same budget.
        tokio::time::sleep(Duration::from_secs(1)).await;
        client.write_all(b"HTTP/1.1 200 OK\r\n\r\n").await.unwrap();
        let mut server = TcpStream::connect(("127.0.0.1", jump_port)).await.unwrap();
        let _ = tokio::io::copy_bidirectional(&mut client, &mut server).await;
    });
    let raw_target = tokio::spawn(async move {
        let (mut stream, _) = target.accept().await.unwrap();
        let mut bytes = Vec::new();
        stream.read_to_end(&mut bytes).await.unwrap();
        assert!(bytes.starts_with(b"SSH-"));
    });
    let result = timeout(
        Duration::from_millis(3600),
        SshConnection::test_connection(
            config,
            HostKeyPolicy::Pinned {
                sha256: "never-received-target-key".into(),
            },
            CancellationToken::new(),
        ),
    )
    .await
    .expect("later stages must not reset the three-second total budget");
    assert!(matches!(result, Err(SshError::Timeout(Stage::Handshake))));
    timeout(Duration::from_secs(3), relay)
        .await
        .unwrap()
        .unwrap();
    timeout(Duration::from_secs(3), raw_target)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn aborting_a_probe_during_nested_target_handshake_releases_jump_and_forwarded_socket() {
    let jump = Server::start().await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut config = ConnectConfig::new(
        "127.0.0.1".into(),
        listener.local_addr().unwrap().port(),
        "not-authenticated".into(),
    );
    config.jump = Some(jump_host(&jump));
    let (session, _events) = ManagedSession::new(Size::new(80, 24).unwrap(), 0).unwrap();
    let session = std::sync::Arc::new(session);
    let subject = session.clone();
    let attempt = tokio::spawn(async move {
        subject
            .test_connection(
                config,
                HostKeyPolicy::Pinned {
                    sha256: "never-received-target-key".into(),
                },
            )
            .await
    });
    let (mut socket, _) = timeout(Duration::from_secs(5), listener.accept())
        .await
        .unwrap()
        .unwrap();
    let mut banner = [0; 4];
    timeout(Duration::from_secs(3), socket.read_exact(&mut banner))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&banner, b"SSH-");
    attempt.abort();
    assert!(attempt.await.unwrap_err().is_cancelled());
    let mut rest = Vec::new();
    timeout(Duration::from_secs(3), socket.read_to_end(&mut rest))
        .await
        .unwrap()
        .unwrap();
    timeout(Duration::from_secs(3), async {
        let mut states = session.subscribe();
        while states.borrow_and_update().phase == SessionPhase::Connecting {
            states.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
    assert_eq!(session.status().phase, SessionPhase::Failed);
    session.shutdown();
    timeout(Duration::from_secs(3), session.wait_closed())
        .await
        .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn independent_jump_and_target_keys_authenticate_before_real_pty_resize_and_sftp() {
    let jump = Server::start().await;
    let target = Server::start().await;
    let (requests, mut receiver) = mpsc::channel(1);
    let mut hop = jump_host(&jump);
    hop.host_key = HostKeyPolicy::ConfirmTagged {
        requests: requests.clone(),
        context: 71,
    };
    let mut config = target.config.clone();
    config.jump = Some(hop);
    let auth = target.auth();
    let attempt = tokio::spawn(async move {
        SshConnection::connect(
            config,
            auth,
            HostKeyPolicy::ConfirmTagged {
                requests,
                context: 93,
            },
            CancellationToken::new(),
        )
        .await
    });
    for (server, context) in [(&jump, 71), (&target, 93)] {
        let request = timeout(Duration::from_secs(5), receiver.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(request.key.address, server.config.address);
        assert_eq!(request.context, Some(context));
        assert_eq!(request.key.port, server.config.port);
        assert_eq!(request.key.sha256, server.fingerprint);
        request.decision.send(true).unwrap();
    }
    let mut ssh = attempt.await.unwrap().unwrap();
    let mut term = Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap();
    ssh.write(b"printf '%s%s\\n' JUMP_ READY\n").await.unwrap();
    until_text(&mut ssh, &mut term, "JUMP_READY").await;
    ssh.resize(110, 31).await.unwrap();
    term.resize(Size::new(110, 31).unwrap()).unwrap();
    ssh.write(b"stty size\n").await.unwrap();
    until_text(&mut ssh, &mut term, "31 110").await;
    let sftp = ssh.open_sftp().await.unwrap();
    let path = target
        .dir
        .path()
        .join("jump 中文.bin")
        .to_str()
        .unwrap()
        .to_owned();
    let payload = vec![193; 256 * 1024 + 29];
    let mut file = sftp.create(&path).await.unwrap();
    file.write_all(&payload).await.unwrap();
    file.close().await.unwrap();
    let mut file = sftp.open(&path).await.unwrap();
    let mut received = Vec::new();
    file.read_to_end(&mut received).await.unwrap();
    file.close().await.unwrap();
    assert_eq!(received, payload);
    sftp.remove_file(path).await.unwrap();
    sftp.close().await.unwrap();
    ssh.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn jump_or_target_key_and_authentication_failures_never_try_a_direct_fallback() {
    let jump = Server::start().await;
    let target = Server::start().await;
    for failure in 0..4 {
        let mut hop = jump_host(&jump);
        if failure == 0 {
            hop.host_key = HostKeyPolicy::Pinned {
                sha256: "SHA256:changed-jump".into(),
            };
        }
        if failure == 1 {
            hop.authentication =
                Authentication::Password(Zeroizing::new("synthetic-wrong-jump-password".into()));
        }
        let mut config = target.config.clone();
        config.jump = Some(hop);
        let policy = if failure == 2 {
            HostKeyPolicy::Pinned {
                sha256: "SHA256:changed-target".into(),
            }
        } else {
            target.pinned()
        };
        let auth = if failure == 3 {
            Authentication::Password(Zeroizing::new("synthetic-wrong-target-password".into()))
        } else {
            target.auth()
        };
        let result = SshConnection::connect(config, auth, policy, CancellationToken::new()).await;
        assert!(
            match (failure, &result) {
                (0, Err(SshError::Jump(e))) =>
                    matches!(e.as_ref(), SshError::HostKeyChanged { .. }),
                (1, Err(SshError::Jump(e))) => matches!(e.as_ref(), SshError::Authentication),
                (2, Err(SshError::HostKeyChanged { .. })) | (3, Err(SshError::Authentication)) =>
                    true,
                _ => false,
            },
            "the concrete failing hop must be preserved without fallback"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn denied_direct_tcpip_does_not_execute_commands_or_bypass_jump() {
    let jump = Server::start_with_forwarding(false).await;
    let target = Server::start().await;
    let mut config = target.config.clone();
    config.jump = Some(jump_host(&jump));
    let result = SshConnection::connect(
        config,
        target.auth(),
        target.pinned(),
        CancellationToken::new(),
    )
    .await;
    assert!(
        matches!(result, Err(SshError::Jump(e)) if matches!(e.as_ref(), SshError::Protocol(_)))
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn one_outer_proxy_routes_to_jump_and_closes_both_transports_on_target_exit() {
    let jump = Server::start().await;
    let target = Server::start().await;
    for kind in [ProxyKind::HttpConnect, ProxyKind::Socks5] {
        // This fixture accepts only CONNECT/direct-to-jump, never the target.
        let virtual_jump = "jump-only-via-proxy.invalid";
        let (proxy, relay) =
            super::openssh_proxy::relay(kind, virtual_jump, jump.config.port).await;
        let mut config = target.config.clone();
        config.proxy = Some(proxy);
        let mut hop = jump_host(&jump);
        hop.address = virtual_jump.into();
        config.jump = Some(hop);
        let mut ssh = SshConnection::connect(
            config,
            target.auth(),
            target.pinned(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
        let mut term = Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap();
        ssh.write(b"printf '%s%s\\n' PROXIED_ JUMP\n")
            .await
            .unwrap();
        until_text(&mut ssh, &mut term, "PROXIED_JUMP").await;
        ssh.close().await.unwrap();
        timeout(Duration::from_secs(3), relay)
            .await
            .unwrap()
            .unwrap();
    }
}
