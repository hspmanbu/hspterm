use super::*;
use hspterm_ssh_core::{ProxyConfig, ProxyCredentials, ProxyError, ProxyKind, Stage};
use tokio::net::{TcpListener, TcpStream};

// A synthetic one-use relay only accepts the requested target, never external DNS.
pub(super) async fn relay(
    kind: ProxyKind,
    target: &str,
    port: u16,
) -> (ProxyConfig, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = ProxyConfig {
        kind,
        address: "127.0.0.1".into(),
        port: listener.local_addr().unwrap().port(),
        authentication: Some(ProxyCredentials::new(
            "fixture-user".into(),
            "fixture-pass".into(),
        )),
    };
    let target = target.to_owned();
    let task = tokio::spawn(async move {
        let (mut client, _) = listener.accept().await.unwrap();
        match kind {
            ProxyKind::HttpConnect => {
                let mut header = Vec::new();
                while !header.ends_with(b"\r\n\r\n") {
                    header.push(client.read_u8().await.unwrap());
                    assert!(header.len() < 4096);
                }
                let expected = format!(
                    "CONNECT {target}:{port} HTTP/1.1\r\nHost: {target}:{port}\r\nProxy-Authorization: Basic Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzcw==\r\n\r\n"
                );
                assert_eq!(header, expected.as_bytes());
                client.write_all(b"HTTP/1.1 200 OK\r\n\r\n").await.unwrap();
            }
            ProxyKind::Socks5 => {
                let mut bytes = [0; 3];
                client.read_exact(&mut bytes).await.unwrap();
                assert_eq!(bytes, [5, 1, 2]);
                client.write_all(&[5, 2]).await.unwrap();
                let mut auth = [0; 27];
                client.read_exact(&mut auth).await.unwrap();
                assert_eq!(&auth, b"\x01\x0cfixture-user\x0cfixture-pass");
                client.write_all(&[1, 0]).await.unwrap();
                let mut request = [0; 5];
                client.read_exact(&mut request).await.unwrap();
                assert_eq!(&request[..4], &[5, 1, 0, 3]);
                let mut domain = vec![0; request[4] as usize];
                client.read_exact(&mut domain).await.unwrap();
                assert_eq!(domain, target.as_bytes());
                assert_eq!(client.read_u16().await.unwrap(), port);
                client
                    .write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 0])
                    .await
                    .unwrap();
            }
        }
        let mut ssh = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        // Remote key rejection can close a relay before sshd drains; the client
        // observes the concrete verification result, not this relay I/O result.
        let _ = tokio::io::copy_bidirectional(&mut client, &mut ssh).await;
    });
    (proxy, task)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn proxies_preserve_original_identity_and_share_pty_sftp_transport() {
    let server = Server::start().await;
    for kind in [ProxyKind::HttpConnect, ProxyKind::Socks5] {
        let mut config = server.config.clone();
        config.address = "ssh-only-at-proxy.invalid".into();
        let (proxy, relay) = relay(kind, &config.address, config.port).await;
        config.proxy = Some(proxy);
        let (requests, mut receiver) = mpsc::channel(1);
        let auth = server.auth();
        let expected = config.clone();
        let attempt = tokio::spawn(async move {
            SshConnection::connect(
                config,
                auth,
                HostKeyPolicy::Confirm { requests },
                CancellationToken::new(),
            )
            .await
        });
        let request = timeout(Duration::from_secs(5), receiver.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(request.key.address, expected.address);
        assert_eq!(request.key.port, expected.port);
        assert_eq!(request.key.sha256, server.fingerprint);
        request.decision.send(true).unwrap();
        let mut ssh = attempt.await.unwrap().unwrap();
        let mut term = Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap();
        ssh.write(b"printf '%s%s\\n' PROXY_ CONNECTED\n")
            .await
            .unwrap();
        until_text(&mut ssh, &mut term, "PROXY_CONNECTED").await;
        ssh.resize(93, 31).await.unwrap();
        ssh.write(b"stty size\n").await.unwrap();
        until_text(&mut ssh, &mut term, "31 93").await;
        let sftp = ssh.open_sftp().await.unwrap();
        let path = server
            .dir
            .path()
            .join("proxy-file")
            .to_str()
            .unwrap()
            .to_owned();
        let payload = vec![73; 128 * 1024 + 7];
        let mut file = sftp.create(&path).await.unwrap();
        file.write_all(&payload).await.unwrap();
        file.close().await.unwrap();
        let mut file = sftp.open(&path).await.unwrap();
        let mut received = Vec::new();
        file.read_to_end(&mut received).await.unwrap();
        file.close().await.unwrap();
        assert_eq!(payload, received);
        sftp.remove_file(&path).await.unwrap();
        sftp.close().await.unwrap();
        ssh.close().await.unwrap();
        timeout(Duration::from_secs(3), relay)
            .await
            .unwrap()
            .unwrap();

        let (proxy, relay) = self::relay(kind, &expected.address, expected.port).await;
        let mut changed = expected;
        changed.proxy = Some(proxy);
        let result = SshConnection::test_connection(
            changed,
            HostKeyPolicy::Pinned {
                sha256: "SHA256:changed".into(),
            },
            CancellationToken::new(),
        )
        .await;
        assert!(matches!(result, Err(SshError::HostKeyChanged { .. })));
        timeout(Duration::from_secs(3), relay)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn proxy_timeout_and_cancel_close_socket_without_ssh_handshake() {
    for kind in [ProxyKind::HttpConnect, ProxyKind::Socks5] {
        for cancelled in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let mut config = ConnectConfig::new("target.invalid".into(), 22, "fixture".into());
            config.timeout = Duration::from_millis(200);
            config.proxy = Some(ProxyConfig {
                kind,
                address: "127.0.0.1".into(),
                port: listener.local_addr().unwrap().port(),
                authentication: None,
            });
            let cancel = CancellationToken::new();
            let token = cancel.clone();
            let attempt = tokio::spawn(async move {
                SshConnection::test_connection(
                    config,
                    HostKeyPolicy::Pinned {
                        sha256: "unused".into(),
                    },
                    token,
                )
                .await
            });
            let (mut client, _) = listener.accept().await.unwrap();
            let mut first = [0; 1];
            client.read_exact(&mut first).await.unwrap();
            if cancelled {
                cancel.cancel();
            }
            let result = timeout(Duration::from_secs(2), attempt)
                .await
                .unwrap()
                .unwrap();
            if cancelled {
                assert!(matches!(result, Err(SshError::Cancelled)));
            } else {
                assert!(matches!(result, Err(SshError::Timeout(Stage::Proxy))));
            }
            let mut rest = Vec::new();
            timeout(Duration::from_secs(2), client.read_to_end(&mut rest))
                .await
                .unwrap()
                .unwrap();
            assert!(!rest.windows(4).any(|w| w == b"SSH-"));
        }
    }
}

#[tokio::test]
async fn rejected_proxy_never_falls_back_to_reachable_ssh_target() {
    let server = Server::start().await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut config = server.config.clone();
    config.proxy = Some(ProxyConfig {
        kind: ProxyKind::HttpConnect,
        address: "127.0.0.1".into(),
        port: listener.local_addr().unwrap().port(),
        authentication: None,
    });
    let relay = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut header = Vec::new();
        while !header.ends_with(b"\r\n\r\n") {
            header.push(stream.read_u8().await.unwrap());
        }
        stream
            .write_all(b"HTTP/1.1 403 synthetic-denied\r\n\r\n")
            .await
            .unwrap();
        let mut remainder = Vec::new();
        stream.read_to_end(&mut remainder).await.unwrap();
        assert!(remainder.is_empty());
    });
    let result = SshConnection::connect(
        config,
        server.auth(),
        server.pinned(),
        CancellationToken::new(),
    )
    .await;
    assert!(matches!(
        result,
        Err(SshError::Proxy(ProxyError::HttpStatus(403)))
    ));
    timeout(Duration::from_secs(2), relay)
        .await
        .unwrap()
        .unwrap();
}
