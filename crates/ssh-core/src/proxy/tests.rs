use super::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};

#[tokio::test]
async fn socks_rejects_failed_authentication_and_malformed_or_denied_connect_replies() {
    for reply in [
        vec![4, 0, 0, 1],
        vec![5, 0, 1, 1],
        vec![5, 0, 0, 2],
        vec![5, 0, 0, 3, 0],
        vec![5, 5, 0, 1],
    ] {
        let (mut client, mut server) = tokio::io::duplex(32768);
        let remote = tokio::spawn(async move {
            let mut greeting = [0; 3];
            server.read_exact(&mut greeting).await.unwrap();
            server.write_all(&[5, 0]).await.unwrap();
            let mut request = [0; 22];
            server.read_exact(&mut request).await.unwrap();
            assert_eq!(&request[..4], &[5, 1, 0, 4]);
            assert_eq!(&request[4..20], &std::net::Ipv6Addr::LOCALHOST.octets());
            assert_eq!(&request[20..], &[0, 22]);
            server.write_all(&reply).await.unwrap();
        });
        assert!(matches!(
            negotiate(&mut client, &config(ProxyKind::Socks5, None), "[::1]", 22).await,
            Err(SshError::Proxy(_))
        ));
        remote.await.unwrap();
    }
    let (mut client, mut server) = tokio::io::duplex(32768);
    let remote = tokio::spawn(async move {
        let mut greeting = [0; 3];
        server.read_exact(&mut greeting).await.unwrap();
        server.write_all(&[5, 2]).await.unwrap();
        let mut auth = [0; 5];
        server.read_exact(&mut auth).await.unwrap();
        assert_eq!(&auth, b"\x01\x01u\x01p");
        server.write_all(&[1, 1]).await.unwrap();
        let mut remaining = Vec::new();
        server.read_to_end(&mut remaining).await.unwrap();
        assert!(remaining.is_empty());
    });
    assert!(matches!(
        negotiate(
            &mut client,
            &config(
                ProxyKind::Socks5,
                Some(ProxyCredentials::new("u".into(), "p".into()))
            ),
            "target",
            22
        )
        .await,
        Err(SshError::Proxy(ProxyError::Authentication))
    ));
    drop(client);
    remote.await.unwrap();
}

#[tokio::test]
async fn truncated_or_unbounded_http_responses_fail_without_a_tunnel() {
    for response in [
        b"HTTP/1.1 200 OK\r\nBad Header: x\r\n\r\n".to_vec(),
        b"HTTP/1.1 200 OK\r\nBad: \x00\r\n\r\n".to_vec(),
        b"HTTP/1.1 200 OK\r\n".to_vec(),
        b"HTTP/1.1 100 Continue\r\n\r\n".repeat(5),
    ] {
        let (mut client, mut server) = tokio::io::duplex(32768);
        let remote = tokio::spawn(async move {
            header(&mut server).await;
            server.write_all(&response).await.unwrap();
        });
        assert!(
            negotiate(
                &mut client,
                &config(ProxyKind::HttpConnect, None),
                "target",
                22
            )
            .await
            .is_err()
        );
        remote.await.unwrap();
    }
}

#[test]
fn proxy_validation_bounds_ports_hosts_and_utf8_authentication_before_tcp() {
    let mut proxy = config(ProxyKind::Socks5, None);
    for target in [
        "x".repeat(254),
        "[host]".into(),
        "[127.0.0.1]".into(),
        "a/b".into(),
    ] {
        assert!(proxy.validate(&target, 22).is_err());
    }
    assert!(proxy.validate("target", 0).is_err());
    proxy.port = 0;
    assert!(proxy.validate("target", 22).is_err());
    proxy.port = 1080;
    for (user, password) in [
        ("u".into(), String::new()),
        ("用".repeat(86), "p".into()),
        ("u".into(), "p".repeat(256)),
    ] {
        proxy.authentication = Some(ProxyCredentials::new(user, password));
        assert!(proxy.validate("target", 22).is_err());
    }
    proxy.authentication = Some(ProxyCredentials::new("u".repeat(255), "p".repeat(255)));
    assert!(proxy.validate("target", 22).is_ok());
}

fn config(kind: ProxyKind, authentication: Option<ProxyCredentials>) -> ProxyConfig {
    ProxyConfig {
        kind,
        address: "127.0.0.1".into(),
        port: 8080,
        authentication,
    }
}
async fn header(stream: &mut DuplexStream) -> Vec<u8> {
    let mut result = Vec::new();
    while !result.ends_with(b"\r\n\r\n") {
        result.push(stream.read_u8().await.unwrap());
        assert!(result.len() < 8192);
    }
    result
}

#[tokio::test]
async fn http_auth_interim_response_and_coalesced_banner_preserve_tunnel_bytes() {
    let (mut client, mut server) = tokio::io::duplex(32768);
    let remote = tokio::spawn(async move {
        let request = header(&mut server).await;
        assert!(
            request.starts_with(
                b"CONNECT ssh-target.test:22 HTTP/1.1\r\nHost: ssh-target.test:22\r\n"
            )
        );
        assert!(
            request
                .windows(b"Proxy-Authorization: Basic dXNlcjpwYXNz".len())
                .any(|w| w == b"Proxy-Authorization: Basic dXNlcjpwYXNz")
        );
        assert!(
            !request
                .windows(b"\r\nAuthorization:".len())
                .any(|w| w == b"\r\nAuthorization:")
        );
        server.write_all(b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 Connection established\r\nProxy-Agent: synthetic\r\n\r\nSSH-2.0-fixture\r\n").await.unwrap();
    });
    negotiate(
        &mut client,
        &config(
            ProxyKind::HttpConnect,
            Some(ProxyCredentials::new("user".into(), "pass".into())),
        ),
        "ssh-target.test",
        22,
    )
    .await
    .unwrap();
    let mut bytes = Vec::new();
    client.read_to_end(&mut bytes).await.unwrap();
    assert_eq!(bytes, b"SSH-2.0-fixture\r\n");
    remote.await.unwrap();
}

#[tokio::test]
async fn http_ipv6_authority_and_non_200_success_are_supported() {
    let (mut client, mut server) = tokio::io::duplex(32768);
    let remote = tokio::spawn(async move {
        assert!(
            header(&mut server)
                .await
                .starts_with(b"CONNECT [::1]:2222 HTTP/1.1\r\n")
        );
        server
            .write_all(b"HTTP/1.0 204 Tunnel\r\n\r\nx")
            .await
            .unwrap();
    });
    negotiate(
        &mut client,
        &config(ProxyKind::HttpConnect, None),
        "::1",
        2222,
    )
    .await
    .unwrap();
    assert_eq!(client.read_u8().await.unwrap(), b'x');
    remote.await.unwrap();
}

#[tokio::test]
async fn invalid_host_and_http_credential_inputs_send_no_bytes() {
    for target in [
        "",
        "target\r\nInjected: header",
        "http://target",
        "a b",
        "bad:port",
    ] {
        let (mut client, mut server) = tokio::io::duplex(32768);
        assert!(
            negotiate(
                &mut client,
                &config(ProxyKind::HttpConnect, None),
                target,
                22
            )
            .await
            .is_err()
        );
        drop(client);
        let mut bytes = Vec::new();
        server.read_to_end(&mut bytes).await.unwrap();
        assert!(bytes.is_empty());
    }
    for user in ["user:other", "user\r\n", ""] {
        let (mut client, mut server) = tokio::io::duplex(32768);
        let proxy = config(
            ProxyKind::HttpConnect,
            Some(ProxyCredentials::new(
                user.into(),
                "synthetic secret".into(),
            )),
        );
        assert!(negotiate(&mut client, &proxy, "target", 22).await.is_err());
        drop(client);
        let mut bytes = Vec::new();
        server.read_to_end(&mut bytes).await.unwrap();
        assert!(bytes.is_empty());
    }
}

#[tokio::test]
async fn socks_domain_resolution_and_reply_domain_do_not_consume_payload() {
    let (mut client, mut server) = tokio::io::duplex(32768);
    let remote = tokio::spawn(async move {
        let mut greeting = [0; 3];
        server.read_exact(&mut greeting).await.unwrap();
        assert_eq!(greeting, [5, 1, 0]);
        server.write_all(&[5, 0]).await.unwrap();
        let mut request = [0; 4];
        server.read_exact(&mut request).await.unwrap();
        assert_eq!(request, [5, 1, 0, 3]);
        let length = server.read_u8().await.unwrap();
        let mut name = vec![0; length as usize];
        server.read_exact(&mut name).await.unwrap();
        assert_eq!(name, b"ssh-target.test");
        assert_eq!(server.read_u16().await.unwrap(), 22);
        server
            .write_all(b"\x05\x00\x00\x03\x01x\x00\x16payload")
            .await
            .unwrap();
    });
    negotiate(
        &mut client,
        &config(ProxyKind::Socks5, None),
        "ssh-target.test",
        22,
    )
    .await
    .unwrap();
    let mut bytes = Vec::new();
    client.read_to_end(&mut bytes).await.unwrap();
    assert_eq!(bytes, b"payload");
    remote.await.unwrap();
}

#[tokio::test]
async fn socks_utf8_credentials_use_byte_lengths_and_ipv6_bound_address_is_consumed_exactly() {
    let (mut client, mut server) = tokio::io::duplex(32768);
    let remote = tokio::spawn(async move {
        let mut greeting = [0; 3];
        server.read_exact(&mut greeting).await.unwrap();
        assert_eq!(greeting, [5, 1, 2]);
        server.write_all(&[5, 2]).await.unwrap();
        assert_eq!(server.read_u8().await.unwrap(), 1);
        let n = server.read_u8().await.unwrap();
        let mut user = vec![0; n as usize];
        server.read_exact(&mut user).await.unwrap();
        assert_eq!(user, "用户".as_bytes());
        let n = server.read_u8().await.unwrap();
        let mut pass = vec![0; n as usize];
        server.read_exact(&mut pass).await.unwrap();
        assert_eq!(pass, "合成口令".as_bytes());
        server.write_all(&[1, 0]).await.unwrap();
        let mut request = [0; 10];
        server.read_exact(&mut request).await.unwrap();
        assert_eq!(request, [5, 1, 0, 1, 127, 0, 0, 1, 0, 22]);
        let mut reply = vec![5, 0, 0, 4];
        reply.extend_from_slice(&[0; 16]);
        reply.extend_from_slice(&[0, 22]);
        reply.extend_from_slice(b"ssh payload");
        server.write_all(&reply).await.unwrap();
    });
    let proxy = config(
        ProxyKind::Socks5,
        Some(ProxyCredentials::new("用户".into(), "合成口令".into())),
    );
    negotiate(&mut client, &proxy, "127.0.0.1", 22)
        .await
        .unwrap();
    let mut bytes = Vec::new();
    client.read_to_end(&mut bytes).await.unwrap();
    assert_eq!(bytes, b"ssh payload");
    remote.await.unwrap();
}

#[tokio::test]
async fn configured_socks_auth_never_downgrades_or_sends_credentials_for_an_unoffered_method() {
    let (mut client, mut server) = tokio::io::duplex(32768);
    let remote = tokio::spawn(async move {
        let mut greeting = [0; 3];
        server.read_exact(&mut greeting).await.unwrap();
        assert_eq!(greeting, [5, 1, 2]);
        server.write_all(&[5, 0]).await.unwrap();
        let mut remainder = Vec::new();
        server.read_to_end(&mut remainder).await.unwrap();
        assert!(remainder.is_empty());
    });
    let proxy = config(
        ProxyKind::Socks5,
        Some(ProxyCredentials::new(
            "not-transmitted-user".into(),
            "not-transmitted-password".into(),
        )),
    );
    assert!(negotiate(&mut client, &proxy, "target", 22).await.is_err());
    drop(client);
    remote.await.unwrap();
}

#[tokio::test]
async fn proxy_errors_and_debug_do_not_include_untrusted_response_text_or_credentials() {
    for response in [
        b"HTTP/1.1 407 synthetic-response-secret\r\nEcho: synthetic-response-secret\r\n\r\n"
            .to_vec(),
        b"HTTP/1.1 200oops synthetic-response-secret\r\n\r\n".to_vec(),
        [
            b"HTTP/1.1 200 OK\r\nEcho: ".as_slice(),
            &vec![b'a'; 17000],
            b"\r\n\r\n",
        ]
        .concat(),
    ] {
        let (mut client, mut server) = tokio::io::duplex(32768);
        let remote = tokio::spawn(async move {
            header(&mut server).await;
            server.write_all(&response).await.unwrap();
        });
        let proxy = config(
            ProxyKind::HttpConnect,
            Some(ProxyCredentials::new(
                "synthetic-config-user".into(),
                "synthetic-config-password".into(),
            )),
        );
        let error = negotiate(&mut client, &proxy, "target", 22)
            .await
            .unwrap_err();
        let text = format!("{error} {error:?} {proxy:?}");
        assert!(!text.contains("synthetic-response-secret"));
        assert!(!text.contains("synthetic-config-user"));
        assert!(!text.contains("synthetic-config-password"));
        drop(client);
        remote.await.unwrap();
    }
}
