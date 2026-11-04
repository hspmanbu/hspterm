use super::*;

fn request(query: &str) -> Vec<u8> {
    format!("GET /oauth2/callback?{query} HTTP/1.1\r\nHost: 127.0.0.1:43001\r\n\r\n").into_bytes()
}
const REDIRECT: &str = "http://127.0.0.1:43001/oauth2/callback";
#[test]
fn pkce_matches_rfc7636_and_random_values_have_full_length() {
    assert_eq!(
        challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    );
    let a = random_token();
    let b = random_token();
    assert_eq!(a.len(), 43);
    assert_ne!(a, b);
    assert!(
        a.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    );
}
#[test]
fn callback_requires_exact_host_state_unique_parameters_and_no_smuggled_body() {
    let valid = request("state=synthetic-state&code=synthetic%2Bcode");
    assert_eq!(
        parse_callback(&valid, REDIRECT, "synthetic-state")
            .unwrap()
            .unwrap()
            .as_str(),
        "synthetic+code"
    );
    for bad in [
        request("state=other-state&code=synthetic-code"),
        request("state=synthetic-state&state=synthetic-state&code=synthetic-code"),
        request("state=synthetic-state&code=one&code=two"),
        request("state=synthetic-state&code=synthetic%0Acode"),
        request("state=synthetic-state&code=synthetic-code&error=denied"),
        String::from_utf8(valid.clone())
            .unwrap()
            .replace("Host: 127.0.0.1:43001", "Host: attacker.invalid")
            .into_bytes(),
        String::from_utf8(valid.clone())
            .unwrap()
            .replace("\r\n\r\n", "\r\nHost: 127.0.0.1:43001\r\n\r\n")
            .into_bytes(),
        String::from_utf8(valid.clone())
            .unwrap()
            .replace("\r\n\r\n", "\r\nOrigin: https://attacker.invalid\r\n\r\n")
            .into_bytes(),
        String::from_utf8(valid.clone())
            .unwrap()
            .replace("\r\n\r\n", "\r\nContent-Length: 1\r\n\r\nx\r\n\r\n")
            .into_bytes(),
        String::from_utf8(valid.clone())
            .unwrap()
            .replace(
                "/oauth2/callback?",
                "http://127.0.0.1:43001/oauth2/callback?",
            )
            .into_bytes(),
    ] {
        assert!(parse_callback(&bad, REDIRECT, "synthetic-state").is_err());
    }
    assert!(matches!(
        parse_callback(
            &request("state=synthetic-state&error=access_denied"),
            REDIRECT,
            "synthetic-state"
        )
        .unwrap(),
        Err(AuthorizationError::Denied)
    ));
}
#[tokio::test]
async fn binding_only_allocates_loopback_and_cancel_closes_listener_without_http() {
    let auth = Authorization::bind(
        DesktopClient {
            client_id: "synthetic-desktop.apps.googleusercontent.com".into(),
            client_secret: Zeroizing::new(String::new()),
        },
        None,
        5,
    )
    .await
    .unwrap();
    let local = auth.listener.local_addr().unwrap();
    assert!(local.ip().is_loopback());
    let url = Url::parse(&auth.authorization_url()).unwrap();
    assert_eq!(url.host_str(), Some("accounts.google.com"));
    let params = url
        .query_pairs()
        .collect::<std::collections::BTreeMap<_, _>>();
    assert_eq!(params.get("scope").unwrap(), SCOPE);
    assert_eq!(params.get("code_challenge_method").unwrap(), "S256");
    assert!(!params.contains_key("client_secret"));
    assert!(!params.contains_key("code_verifier"));
    assert!(!params.contains_key("access_token"));
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert!(matches!(
        auth.finish(&cancel).await,
        Err(AuthorizationError::Cancelled)
    ));
    assert!(TcpStream::connect(local).await.is_err());
}
#[test]
fn client_and_token_validation_rejects_untrusted_shape_and_lifetimes() {
    assert!(!valid_client_id(
        "client.apps.googleusercontent.com.attacker.invalid"
    ));
    assert!(!valid_client_id("a\n.apps.googleusercontent.com"));
    assert!(!valid_token("secret\r\nAuthorization: injected"));
    let mut token = TokenWire {
        access_token: "synthetic-access-token".into(),
        token_type: "Bearer".into(),
        expires_in: 3600,
        refresh_token: None,
        scope: Some(SCOPE.into()),
    };
    assert!(
        !token
            .access()
            .unwrap()
            .expires_within(Duration::from_secs(10))
    );
    token.expires_in = u64::MAX;
    assert!(token.access().is_err());
    token.expires_in = 0;
    assert!(token.access().is_err());
    token.expires_in = 3600;
    token.token_type = "unknown".into();
    assert!(token.access().is_err());
}
#[test]
fn exchanged_grant_is_encrypted_locally_and_joins_original_route_preconditions() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("grant.vault");
    let mut vault = crate::Vault::create(&path, b"synthetic-master").unwrap();
    let view = crate::google_drive_account::load(&vault).unwrap();
    let source =
        crate::google_drive_account::source(&vault, &view.vault_scope, &view.revision).unwrap();
    let route = super::super::settings::authorization_route(&vault).unwrap();
    let wire = TokenWire {
        access_token: "synthetic-access-token".into(),
        token_type: "Bearer".into(),
        expires_in: 3600,
        refresh_token: None,
        scope: Some(SCOPE.into()),
    };
    let grant = Grant {
        client: DesktopClient {
            client_id: "synthetic-client.apps.googleusercontent.com".into(),
            client_secret: Zeroizing::new("synthetic-client-secret".into()),
        },
        refresh_token: Zeroizing::new("synthetic-refresh-token".into()),
        access: wire.access().unwrap(),
    };
    let saved = source
        .save(&mut vault, grant, &route.preconditions())
        .unwrap();
    let raw = serde_json::to_string(&saved).unwrap();
    assert!(!raw.contains("synthetic-refresh-token"));
    assert!(!raw.contains("synthetic-access-token"));
    assert!(!raw.contains("synthetic-client-secret"));
    assert_eq!(
        crate::google_drive_account::load(&vault).unwrap().revision,
        saved.revision
    );
    drop(vault);
    let disk = std::fs::read(path).unwrap();
    assert!(
        !disk
            .windows(b"synthetic-refresh-token".len())
            .any(|s| s == b"synthetic-refresh-token")
    );
}
