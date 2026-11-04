use super::super::{EntityTag, exchange::http_fixture_upload};
use super::*;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    task::JoinHandle,
};
const COLLECTION: &str = "0123456789abcdef0123456789abcdef";
#[tokio::test]
async fn missing_is_only_allowed_for_the_same_pregenerated_creation_capability() {
    let (files, server) = server(vec![
        response("404 Not Found", None, b""),
        response("404 Not Found", None, b""),
    ])
    .await;
    let cancel = CancellationToken::new();
    assert!(
        files
            .read("synthetic-generated-id", COLLECTION, &cancel)
            .await
            .is_err()
    );
    let reserved = ReservedObject::restore("synthetic-generated-id").unwrap();
    assert!(matches!(
        files
            .read_reserved(&reserved, COLLECTION, &cancel)
            .await
            .unwrap(),
        RemoteRead::Missing
    ));
    let requests = server.await.unwrap();
    assert!(
        requests
            .iter()
            .all(|r| r.starts_with(b"GET /drive/v3/files/synthetic-generated-id?"))
    );
}
fn metadata(id: &str) -> serde_json::Value {
    serde_json::json!({"id": id, "name": name(COLLECTION), "mimeType": MIME, "size": "3", "spaces": ["appDataFolder"], "trashed": false, "appProperties": properties(COLLECTION)})
}
fn response(status: &str, etag: Option<&str>, body: &[u8]) -> Vec<u8> {
    let mut bytes = format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n", body.len()).into_bytes();
    if let Some(tag) = etag {
        bytes.extend_from_slice(format!("ETag: {tag}\r\n").as_bytes());
    }
    bytes.extend_from_slice(b"\r\n");
    bytes.extend_from_slice(body);
    bytes
}
async fn server(replies: Vec<Vec<u8>>) -> (DriveFiles, JoinHandle<Vec<Vec<u8>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let worker = tokio::spawn(async move {
        let mut requests = Vec::new();
        for reply in replies {
            let (mut socket, _) =
                tokio::time::timeout(std::time::Duration::from_secs(5), listener.accept())
                    .await
                    .unwrap()
                    .unwrap();
            let mut raw = Vec::new();
            loop {
                let mut part = [0; 4096];
                let n =
                    tokio::time::timeout(std::time::Duration::from_secs(5), socket.read(&mut part))
                        .await
                        .unwrap()
                        .unwrap();
                assert!(n > 0);
                raw.extend_from_slice(&part[..n]);
                assert!(raw.len() <= 64 * 1024);
                if let Some(end) = raw.windows(4).position(|s| s == b"\r\n\r\n") {
                    let header = std::str::from_utf8(&raw[..end]).unwrap();
                    let length = header
                        .lines()
                        .filter_map(|l| l.split_once(':'))
                        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
                        .map(|(_, v)| v.trim().parse::<usize>().unwrap())
                        .unwrap_or(0);
                    if raw.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            requests.push(raw);
            socket.write_all(&reply).await.unwrap();
            socket.shutdown().await.unwrap();
        }
        requests
    });
    let client = DriveFiles {
        client: webdav::client(None, 3, true).unwrap(),
        access: drive_oauth::fixture_access(),
        api: Url::parse(&format!("http://{address}/drive/v3/files")).unwrap(),
        upload: Url::parse(&format!("http://{address}/upload/drive/v3/files")).unwrap(),
    };
    (client, worker)
}
#[tokio::test]
async fn discovery_follows_pages_and_preserves_same_collection_distinct_ids_for_explicit_choice() {
    let a = serde_json::to_vec(&serde_json::json!({"files": [metadata("synthetic-a")], "nextPageToken": "synthetic-next", "incompleteSearch": false})).unwrap();
    let b = serde_json::to_vec(
        &serde_json::json!({"files": [metadata("synthetic-b")], "incompleteSearch": false}),
    )
    .unwrap();
    let (client, worker) = server(vec![
        response("200 OK", None, &a),
        response("200 OK", None, &b),
    ])
    .await;
    let files = client.discover(&CancellationToken::new()).await.unwrap();
    assert_eq!(files.len(), 2);
    assert_eq!(files[0].collection, files[1].collection);
    let requests = worker.await.unwrap();
    let first = String::from_utf8_lossy(&requests[0]);
    assert!(first.contains("spaces=appDataFolder"));
    assert!(
        first
            .to_ascii_lowercase()
            .contains("authorization: bearer synthetic-access-token")
    );
    assert!(!first.lines().next().unwrap().contains("access_token"));
    assert!(String::from_utf8_lossy(&requests[1]).contains("pageToken=synthetic-next"));
}
#[tokio::test]
async fn incomplete_or_unknown_objects_never_become_an_empty_successful_collection() {
    let incomplete =
        serde_json::to_vec(&serde_json::json!({"files": [], "incompleteSearch": true})).unwrap();
    let (client, worker) = server(vec![response("200 OK", None, &incomplete)]).await;
    assert!(client.discover(&CancellationToken::new()).await.is_err());
    worker.await.unwrap();
    let mut invalid = metadata("synthetic-id");
    invalid["appProperties"]["hsptermFormat"] = "2".into();
    let unknown =
        serde_json::to_vec(&serde_json::json!({"files": [invalid], "incompleteSearch": false}))
            .unwrap();
    let (client, worker) = server(vec![response("200 OK", None, &unknown)]).await;
    assert!(client.discover(&CancellationToken::new()).await.is_err());
    worker.await.unwrap();
}
#[tokio::test]
async fn saved_object_404_is_not_missing_and_media_read_requires_original_metadata_tag() {
    let (client, worker) = server(vec![response("404 Not Found", None, b"{}")]).await;
    assert!(
        client
            .read("synthetic-id", COLLECTION, &CancellationToken::new())
            .await
            .is_err()
    );
    worker.await.unwrap();
    let info = serde_json::to_vec(&metadata("synthetic-id")).unwrap();
    let (client, worker) = server(vec![
        response("200 OK", Some("\"r1\""), &info),
        response("200 OK", None, &[0x81, 0x93, 0x67]),
    ])
    .await;
    let read = client
        .read("synthetic-id", COLLECTION, &CancellationToken::new())
        .await
        .unwrap();
    assert!(
        matches!(read, RemoteRead::Present { ciphertext, .. } if ciphertext == [0x81, 0x93, 0x67])
    );
    let requests = worker.await.unwrap();
    assert!(
        String::from_utf8_lossy(&requests[1])
            .to_ascii_lowercase()
            .contains("if-match: \"r1\"")
    );
    assert!(String::from_utf8_lossy(&requests[1]).contains("alt=media"));
}
#[tokio::test]
async fn update_validates_original_object_and_uses_conditional_patch_with_checked_id_ack() {
    let info = serde_json::to_vec(&metadata("synthetic-id")).unwrap();
    let (client, worker) = server(vec![
        response("200 OK", Some("\"r1\""), &info),
        response("200 OK", Some("\"r2\""), br#"{"id":"synthetic-id"}"#),
    ])
    .await;
    let upload = http_fixture_upload(PublicationCondition::Match(
        EntityTag::parse("\"r1\"").unwrap(),
    ));
    assert!(matches!(
        client
            .publish("synthetic-id", upload, &CancellationToken::new())
            .await
            .unwrap(),
        PutResponse::Confirmed(_)
    ));
    let requests = worker.await.unwrap();
    assert!(
        String::from_utf8_lossy(&requests[1])
            .starts_with("PATCH /upload/drive/v3/files/synthetic-id?")
    );
    for request in requests {
        assert!(
            String::from_utf8_lossy(&request)
                .to_ascii_lowercase()
                .contains("if-match: \"r1\"")
        );
    }
}
#[tokio::test]
async fn generated_id_is_consumed_by_explicit_encrypted_create_and_missing_tag_is_unknown() {
    let ids = br#"{"ids":["synthetic-generated"],"space":"appDataFolder"}"#;
    let (client, worker) = server(vec![
        response("200 OK", None, ids),
        response("200 OK", Some("\"r1\""), br#"{"id":"synthetic-generated"}"#),
    ])
    .await;
    let reserved = client
        .reserve_object(&CancellationToken::new())
        .await
        .unwrap();
    assert_eq!(reserved.id(), "synthetic-generated");
    assert!(matches!(
        client
            .create(
                reserved,
                http_fixture_upload(PublicationCondition::CreateOnly),
                &CancellationToken::new()
            )
            .await
            .unwrap(),
        PutResponse::Confirmed(_)
    ));
    let requests = worker.await.unwrap();
    let request = String::from_utf8_lossy(&requests[1]);
    assert!(request.starts_with("POST /upload/drive/v3/files?"));
    assert!(request.to_ascii_lowercase().contains("if-none-match: *"));
    assert!(request.contains("multipart/related"));
    assert!(request.contains("synthetic-generated"));
    assert!(request.contains("appDataFolder"));
    let info = serde_json::to_vec(&metadata("synthetic-id")).unwrap();
    let (client, worker) = server(vec![
        response("200 OK", Some("\"r1\""), &info),
        response("200 OK", None, br#"{"id":"synthetic-id"}"#),
    ])
    .await;
    assert!(matches!(
        client
            .publish(
                "synthetic-id",
                http_fixture_upload(PublicationCondition::Match(
                    EntityTag::parse("\"r1\"").unwrap()
                )),
                &CancellationToken::new()
            )
            .await,
        Err(TransportError::WriteUnknown)
    ));
    worker.await.unwrap();
}
#[test]
fn wrong_space_cross_collection_metadata_and_path_injection_are_rejected() {
    for id in [
        "../other",
        "x/y",
        "x?access_token=secret",
        "x%2fy",
        "",
        "x\r\n",
    ] {
        assert!(!valid_id(id));
    }
    let mut bad = metadata("synthetic-id");
    bad["spaces"] = serde_json::json!(["drive"]);
    assert!(
        serde_json::from_value::<Metadata>(bad)
            .unwrap()
            .checked()
            .is_err()
    );
    let mut bad = metadata("synthetic-id");
    bad["appProperties"]["hsptermCollection"] = serde_json::json!("a".repeat(32));
    assert!(
        serde_json::from_value::<Metadata>(bad)
            .unwrap()
            .checked()
            .is_err()
    );
}
