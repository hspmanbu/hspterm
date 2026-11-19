use super::*;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    task::JoinHandle,
};

async fn server(reply: Vec<u8>) -> (String, JoinHandle<Vec<u8>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let worker = tokio::spawn(async move {
        let (mut stream, _) = tokio::time::timeout(Duration::from_secs(5), listener.accept())
            .await
            .unwrap()
            .unwrap();
        let mut request = Vec::new();
        let mut chunk = [0; 4096];
        loop {
            let n = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut chunk))
                .await
                .unwrap()
                .unwrap();
            assert!(n > 0, "synthetic peer closed before complete request");
            request.extend_from_slice(&chunk[..n]);
            assert!(request.len() < 64 * 1024);
            if let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                let headers = std::str::from_utf8(&request[..end]).unwrap();
                let length = headers
                    .lines()
                    .find_map(|line| {
                        line.split_once(':')
                            .filter(|(k, _)| k.eq_ignore_ascii_case("content-length"))
                            .map(|(_, v)| v.trim().parse::<usize>().unwrap())
                    })
                    .unwrap_or(0);
                if request.len() >= end + 4 + length {
                    break;
                }
            }
        }
        tokio::time::timeout(Duration::from_secs(5), stream.write_all(&reply))
            .await
            .unwrap()
            .unwrap();
        stream.shutdown().await.unwrap();
        request
    });
    (format!("http://{address}/private-object.hspconfig"), worker)
}
fn client(endpoint: &str) -> WebDav {
    WebDav::new(
        endpoint,
        Some(Authentication {
            username: "synthetic-user".into(),
            password: Zeroizing::new("synthetic-webdav-password".into()),
        }),
        None,
        3,
    )
    .unwrap()
}
fn response(status: &str, headers: &str, body: &[u8]) -> Vec<u8> {
    let mut bytes = format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n",
        body.len()
    )
    .into_bytes();
    bytes.extend_from_slice(body);
    bytes
}
fn upload(condition: PublicationCondition) -> PendingUpload {
    // HTTP-only fixture. The envelope protocol is separately covered by the
    // authenticated exchange test; these bytes are not claimed as valid E2E.
    super::super::exchange::http_fixture_upload(condition)
}
#[tokio::test]
async fn bounded_get_keeps_strong_validator_and_does_not_expose_authentication_as_url_or_body() {
    let (url, worker) = server(response(
        "200 OK",
        "ETag: \"synthetic-get\"\r\n",
        &[0x83, 0x45, 0x21],
    ))
    .await;
    let read = client(&url).read(&CancellationToken::new()).await.unwrap();
    let RemoteRead::Present { etag, ciphertext } = read else {
        panic!("expected existing synthetic object")
    };
    assert_eq!(etag.header_value(), "\"synthetic-get\"");
    assert_eq!(ciphertext, [0x83, 0x45, 0x21]);
    let request = worker.await.unwrap();
    let text = std::str::from_utf8(&request).unwrap().to_lowercase();
    assert!(text.starts_with("get /private-object.hspconfig http/1.1\r\n"));
    assert!(text.contains("authorization: basic "));
    assert!(text.contains("accept-encoding: identity"));
    assert!(!text.contains("synthetic-webdav-password"));
}
#[tokio::test]
async fn absence_requires_404_and_weak_etags_redirects_partial_or_encoded_data_are_never_applied() {
    for (status, headers, missing) in [
        ("404 Not Found", "", true),
        ("401 Unauthorized", "", false),
        (
            "302 Found",
            "Location: https://unrelated-fixture.invalid/private\r\n",
            false,
        ),
        ("206 Partial Content", "ETag: \"partial\"\r\n", false),
        ("200 OK", "ETag: W/\"weak\"\r\n", false),
        ("200 OK", "ETag: \"one\"\r\nETag: \"two\"\r\n", false),
        (
            "200 OK",
            "ETag: \"one\"\r\nContent-Encoding: gzip\r\n",
            false,
        ),
    ] {
        let (url, worker) = server(response(status, headers, b"synthetic-server-body")).await;
        let result = client(&url).read(&CancellationToken::new()).await;
        if missing {
            assert!(matches!(result, Ok(RemoteRead::Missing)));
        } else {
            assert!(result.is_err());
        }
        worker.await.unwrap();
    }
    let oversized = format!(
        "HTTP/1.1 200 OK\r\nETag: \"too-large\"\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        MAX_ENCRYPTED_BYTES + 1
    );
    let (url, worker) = server(oversized.into_bytes()).await;
    assert!(matches!(
        client(&url).read(&CancellationToken::new()).await,
        Err(TransportError::Capacity)
    ));
    worker.await.unwrap();
}
#[tokio::test]
async fn writes_always_send_exact_conditions_and_missing_ack_or_412_cannot_advance_the_baseline() {
    for condition in [
        PublicationCondition::CreateOnly,
        PublicationCondition::Match(EntityTag::parse("\"prior\"").unwrap()),
    ] {
        let create = matches!(condition, PublicationCondition::CreateOnly);
        let (url, worker) = server(response("201 Created", "ETag: \"saved\"\r\n", b"")).await;
        assert!(matches!(
            client(&url)
                .publish(upload(condition), &CancellationToken::new())
                .await
                .unwrap(),
            PutResponse::Confirmed(_)
        ));
        let bytes = worker.await.unwrap();
        let text = String::from_utf8_lossy(&bytes).to_lowercase();
        if create {
            assert!(text.contains("if-none-match: *\r\n"));
            assert!(!text.contains("if-match:"));
        } else {
            assert!(text.contains("if-match: \"prior\"\r\n"));
            assert!(!text.contains("if-none-match:"));
        }
        assert!(bytes.ends_with(&[0x81, 0x93, 0x67]));
    }
    let (url, worker) = server(response("412 Precondition Failed", "", b"")).await;
    assert!(matches!(
        client(&url)
            .publish(
                upload(PublicationCondition::CreateOnly),
                &CancellationToken::new()
            )
            .await
            .unwrap(),
        PutResponse::PreconditionFailed
    ));
    worker.await.unwrap();
    let (url, worker) = server(response("204 No Content", "", b"")).await;
    assert!(matches!(
        client(&url)
            .publish(
                upload(PublicationCondition::CreateOnly),
                &CancellationToken::new()
            )
            .await,
        Err(TransportError::WriteUnknown)
    ));
    worker.await.unwrap();
}
#[tokio::test]
async fn cancellation_does_not_launch_a_request_and_config_rejects_unsupported_schemes_or_userinfo()
{
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}/object", listener.local_addr().unwrap());
    let transport = client(&endpoint);
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert!(matches!(
        transport.read(&cancel).await,
        Err(TransportError::Cancelled)
    ));
    assert!(matches!(
        transport
            .publish(upload(PublicationCondition::CreateOnly), &cancel)
            .await,
        Err(TransportError::WriteUnknown)
    ));
    assert!(
        tokio::time::timeout(Duration::from_millis(30), listener.accept())
            .await
            .is_err()
    );
    for endpoint in [
        "ftp://127.0.0.1/object",
        "https://user:password@fixture.invalid/object",
        "https://fixture.invalid/object?secret=value",
        "https://fixture.invalid/dir/",
    ] {
        assert!(WebDav::new(endpoint, None, None, 3).is_err());
    }
}

#[tokio::test]
async fn an_explicit_http_proxy_failure_never_falls_back_to_the_target_socket() {
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (proxy_url, worker) = server(response("407 Proxy Authentication Required", "", b"")).await;
    let mut proxy_address = Url::parse(&proxy_url).unwrap();
    proxy_address.set_path("");
    let endpoint = format!("http://{}/object", target.local_addr().unwrap());
    let transport = WebDav::new(
        &endpoint,
        None,
        Some(IndependentProxy {
            address: proxy_address.to_string(),
            username: Some("synthetic-proxy-user".into()),
            password: Zeroizing::new("synthetic-proxy-pass".into()),
        }),
        3,
    )
    .unwrap();
    assert!(transport.read(&CancellationToken::new()).await.is_err());
    let request = worker.await.unwrap();
    let text = String::from_utf8_lossy(&request).to_lowercase();
    assert!(text.contains("proxy-authorization: basic "));
    assert!(!text.contains("synthetic-proxy-pass"));
    assert!(
        tokio::time::timeout(Duration::from_millis(30), target.accept())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn socks5_authentication_and_target_dns_stay_on_the_independent_proxy() {
    let proxy = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = proxy.local_addr().unwrap();
    let worker = tokio::spawn(async move {
        let (mut peer, _) = proxy.accept().await.unwrap();
        let mut prefix = [0; 2];
        peer.read_exact(&mut prefix).await.unwrap();
        assert_eq!(prefix[0], 5);
        let mut methods = vec![0; prefix[1] as usize];
        peer.read_exact(&mut methods).await.unwrap();
        assert!(methods.contains(&2));
        peer.write_all(&[5, 2]).await.unwrap();
        peer.read_exact(&mut prefix).await.unwrap();
        assert_eq!(prefix[0], 1);
        let mut username = vec![0; prefix[1] as usize];
        peer.read_exact(&mut username).await.unwrap();
        let length = peer.read_u8().await.unwrap();
        let mut password = vec![0; length as usize];
        peer.read_exact(&mut password).await.unwrap();
        assert_eq!(username.as_slice(), b"synthetic-proxy-user");
        assert_eq!(password.as_slice(), b"synthetic-proxy-pass");
        peer.write_all(&[1, 0]).await.unwrap();
        let mut command = [0; 4];
        peer.read_exact(&mut command).await.unwrap();
        assert_eq!(command, [5, 1, 0, 3]);
        let length = peer.read_u8().await.unwrap();
        let mut domain = vec![0; length as usize];
        peer.read_exact(&mut domain).await.unwrap();
        assert_eq!(domain.as_slice(), b"socks-target-fixture.invalid");
        let port = peer.read_u16().await.unwrap();
        assert_eq!(port, 443);
        // Explicit proxy refusal; no target DNS or direct retry is permitted.
        peer.write_all(&[5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
            .await
            .unwrap();
    });
    let transport = WebDav::new(
        "https://socks-target-fixture.invalid/object",
        None,
        Some(IndependentProxy {
            address: format!("socks5h://{address}"),
            username: Some("synthetic-proxy-user".into()),
            password: Zeroizing::new("synthetic-proxy-pass".into()),
        }),
        3,
    )
    .unwrap();
    assert!(transport.read(&CancellationToken::new()).await.is_err());
    tokio::time::timeout(Duration::from_secs(5), worker)
        .await
        .unwrap()
        .unwrap();
}

#[test]
fn public_webdav_accepts_explicit_http_without_relaxing_url_boundaries() {
    for endpoint in [
        "http://127.0.0.1/object",
        "http://dav.internal/config.enc",
        "https://dav.internal/config.enc",
    ] {
        assert!(WebDav::new(endpoint, None, None, 3).is_ok());
        assert!(checked_endpoint(endpoint).is_ok());
    }
    for endpoint in [
        "http://user:secret@dav.internal/object",
        "http://dav.internal/dir/",
        "http://dav.internal/object?token=x",
        "file:///tmp/object",
    ] {
        assert!(checked_endpoint(endpoint).is_err());
    }
}

#[test]
fn roots_normalize_to_one_object_and_derivation_rejects_ambiguous_input() {
    for (root, object) in [
        (
            "https://dav.internal",
            "https://dav.internal/hspterm/config.hspterm",
        ),
        (
            "https://dav.internal/",
            "https://dav.internal/hspterm/config.hspterm",
        ),
        (
            "http://127.0.0.1:8443/dav",
            "http://127.0.0.1:8443/dav/hspterm/config.hspterm",
        ),
        (
            "http://127.0.0.1:8443/dav/",
            "http://127.0.0.1:8443/dav/hspterm/config.hspterm",
        ),
    ] {
        assert_eq!(derive_object(root).unwrap(), object);
    }
    for root in [
        "ftp://dav.internal",
        "https://user:secret@dav.internal",
        "https://dav.internal/?token=x",
        "https://dav.internal/#section",
        "not a url",
    ] {
        assert!(checked_root(root).is_err());
        assert!(derive_object(root).is_err());
    }
}

#[tokio::test]
async fn first_sync_collection_creation_is_explicit_single_and_fail_closed() {
    for (status, ready) in [
        ("201 Created", true),
        ("405 Method Not Allowed", true),
        ("200 OK", true),
        ("204 No Content", true),
        ("409 Conflict", false),
        ("404 Not Found", false),
        ("500 Internal Server Error", false),
    ] {
        let (url, worker) = server(response(status, "", b"")).await;
        let result = client(&url)
            .ensure_collection(&CancellationToken::new())
            .await;
        assert_eq!(result.is_ok(), ready, "{status}");
        let request = worker.await.unwrap();
        let text = String::from_utf8_lossy(&request).to_lowercase();
        assert!(text.starts_with("mkcol / http/1.1\r\n"), "{status}");
        assert!(text.contains("authorization: *** "), "{status}");
    }
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!(
        "http://{}/dav/hspterm/config.hspterm",
        listener.local_addr().unwrap()
    );
    let transport = client(&endpoint);
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert!(matches!(
        transport.ensure_collection(&cancel).await,
        Err(TransportError::Cancelled)
    ));
    assert!(
        tokio::time::timeout(Duration::from_millis(30), listener.accept())
            .await
            .is_err()
    );
}
