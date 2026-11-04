//! Desktop OAuth: an external browser, PKCE S256, exact loopback callback and
//! offline appDataFolder consent. No embedded browser or ambient credentials.
//! This module does not persist tokens or start work on application startup.
use super::webdav::{self, IndependentProxy, TransportError};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::{RngCore, rngs::OsRng};
use reqwest::{Client, StatusCode, Url, header};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};
use tokio_util::sync::CancellationToken;
use zeroize::{Zeroize, Zeroizing};

pub const SCOPE: &str = "https://www.googleapis.com/auth/drive.appdata";
const AUTH: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN: &str = "https://oauth2.googleapis.com/token";
const REVOKE: &str = "https://oauth2.googleapis.com/revoke";
const JSON_LIMIT: usize = 64 * 1024;
const CALLBACK_LIMIT: usize = 16 * 1024;
const LIFETIME: Duration = Duration::from_secs(300);

#[derive(Debug, thiserror::Error)]
pub enum AuthorizationError {
    #[error("另一个Google Drive账号操作尚未结束，请稍后手动重试")]
    Busy,
    #[error("Google 桌面客户端配置无效；请提供自己注册的桌面 OAuth 客户端")]
    Configuration,
    #[error("Google 授权已取消或过期；没有保存账号")]
    Cancelled,
    #[error("Google 拒绝授权或授权范围不完整；没有保存账号")]
    Denied,
    #[error("Google 授权回调或令牌响应无效；没有保存账号")]
    Response,
    #[error("Google 授权网络请求失败；没有保存账号")]
    Network,
    #[error("本机回环授权监听失败；没有保存账号")]
    Listener,
    #[error("Google 撤销结果未确认；本机凭据仍保留，可再次明确撤销")]
    RevokeUnknown,
}
type Result<T> = std::result::Result<T, AuthorizationError>;

/// A public desktop client ID is not an application password. An optional
/// provider-issued client secret is accepted write-only, never embedded here.
pub struct DesktopClient {
    pub client_id: String,
    pub client_secret: Zeroizing<String>,
}
pub fn valid_client_id(id: &str) -> bool {
    id.len() <= 256
        && id.ends_with(".apps.googleusercontent.com")
        && id.len() > ".apps.googleusercontent.com".len()
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.'))
}
fn valid_token(token: &str) -> bool {
    !token.is_empty()
        && token.len() <= 16 * 1024
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._~+/=".contains(&b))
}
impl DesktopClient {
    pub fn validate(&self) -> Result<()> {
        if !valid_client_id(&self.client_id)
            || self.client_secret.len() > 4096
            || self.client_secret.chars().any(char::is_control)
        {
            return Err(AuthorizationError::Configuration);
        }
        Ok(())
    }
}
fn random_token() -> String {
    let mut bytes = Zeroizing::new([0u8; 32]);
    OsRng.fill_bytes(bytes.as_mut());
    URL_SAFE_NO_PAD.encode(bytes.as_ref())
}
fn challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}
fn same_state(a: &str, b: &str) -> bool {
    a.len() == b.len()
        && a.as_bytes()
            .iter()
            .zip(b.as_bytes())
            .fold(0u8, |diff, (a, b)| diff | (a ^ b))
            == 0
}

/// Secrets never implement Debug/Serialize. Access tokens only live inside a
/// running native operation; the refresh token is handed to the encrypted
/// local account repository, never to Flutter or configuration sync.
pub struct Grant {
    pub(crate) client: DesktopClient,
    pub(crate) refresh_token: Zeroizing<String>,
    access: AccessToken,
}
pub struct AccessToken {
    value: Zeroizing<String>,
    expires: Instant,
}
/// A provider can rotate an offline credential. The eventual Drive driver
/// must publish a replacement through the original local-account CAS instead
/// of silently discarding it or claiming the old refresh token stays usable.
pub struct Refreshed {
    pub(crate) access: AccessToken,
    pub(crate) rotated_refresh_token: Option<Zeroizing<String>>,
    source_tag: [u8; 32],
}
fn refresh_source(client: &DesktopClient, refresh_token: &str) -> [u8; 32] {
    let mut hash = Sha256::new();
    hash.update(b"HSPTerm original Drive refresh capability v1\0");
    for part in [
        client.client_id.as_str(),
        client.client_secret.as_str(),
        refresh_token,
    ] {
        hash.update((part.len() as u64).to_be_bytes());
        hash.update(part.as_bytes());
    }
    hash.finalize().into()
}
impl Refreshed {
    pub(crate) fn matches(&self, client: &DesktopClient, token: &str) -> bool {
        self.source_tag
            .iter()
            .zip(refresh_source(client, token))
            .fold(0u8, |diff, (a, b)| diff | (a ^ b))
            == 0
    }
}
impl AccessToken {
    pub fn expires_within(&self, duration: Duration) -> bool {
        self.expires.saturating_duration_since(Instant::now()) <= duration
    }
    pub(super) fn authenticate(&self, request: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        request.bearer_auth(self.value.as_str())
    }
}
impl Grant {
    pub fn access(&self) -> &AccessToken {
        &self.access
    }
}

pub struct Authorization {
    listener: TcpListener,
    client: DesktopClient,
    http: Client,
    verifier: Zeroizing<String>,
    state: Zeroizing<String>,
    redirect: String,
    deadline: tokio::time::Instant,
}
impl Authorization {
    /// Binding does not send network requests. Only IPv4 loopback is opened,
    /// on a fresh OS-selected port, before the browser is handed a URL.
    pub async fn bind(
        client: DesktopClient,
        proxy: Option<IndependentProxy>,
        timeout_seconds: u32,
    ) -> Result<Self> {
        if cfg!(target_os = "android") {
            return Err(AuthorizationError::Configuration);
        }
        client.validate()?;
        let http = webdav::client(proxy, timeout_seconds, false)
            .map_err(|_| AuthorizationError::Configuration)?;
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .map_err(|_| AuthorizationError::Listener)?;
        let port = listener
            .local_addr()
            .map_err(|_| AuthorizationError::Listener)?
            .port();
        Ok(Self {
            listener,
            client,
            http,
            verifier: Zeroizing::new(random_token()),
            state: Zeroizing::new(random_token()),
            redirect: format!("http://127.0.0.1:{port}/oauth2/callback"),
            deadline: tokio::time::Instant::now() + LIFETIME,
        })
    }
    pub fn authorization_url(&self) -> String {
        let mut url = Url::parse(AUTH).expect("constant Google authorization endpoint");
        url.query_pairs_mut()
            .append_pair("client_id", &self.client.client_id)
            .append_pair("redirect_uri", &self.redirect)
            .append_pair("response_type", "code")
            .append_pair("scope", SCOPE)
            .append_pair("state", &self.state)
            .append_pair("code_challenge", &challenge(&self.verifier))
            .append_pair("code_challenge_method", "S256")
            .append_pair("access_type", "offline")
            .append_pair("prompt", "consent select_account");
        url.to_string()
    }
    pub async fn finish(self, cancel: &CancellationToken) -> Result<Grant> {
        tokio::select! { biased;
            _ = cancel.cancelled() => Err(AuthorizationError::Cancelled),
            _ = tokio::time::sleep_until(self.deadline) => Err(AuthorizationError::Cancelled),
            result = self.finish_inner() => result,
        }
    }
    async fn finish_inner(self) -> Result<Grant> {
        // A malformed local request must not consume the callback. The number
        // of connections and per-socket read time are bounded, even for a local
        // process filling the listener with incomplete requests.
        for _ in 0..64 {
            let (mut socket, peer) = self
                .listener
                .accept()
                .await
                .map_err(|_| AuthorizationError::Listener)?;
            if !peer.ip().is_loopback() {
                continue;
            }
            let callback = match tokio::time::timeout(
                Duration::from_secs(2),
                read_callback(&mut socket, &self.redirect, &self.state),
            )
            .await
            {
                Ok(Ok(c)) => c,
                _ => {
                    let _ = respond(&mut socket, false).await;
                    continue;
                }
            };
            // Fixed text only, no code/error/state/redirect reflection. The
            // outer deadline and cancellation also bound this response write.
            let _browser_response = respond(&mut socket, true).await;
            let code = callback?;
            drop(socket);
            let mut fields = vec![
                ("client_id", self.client.client_id.as_str()),
                ("grant_type", "authorization_code"),
                ("code", code.as_str()),
                ("code_verifier", self.verifier.as_str()),
                ("redirect_uri", self.redirect.as_str()),
            ];
            if !self.client.client_secret.is_empty() {
                fields.push(("client_secret", self.client.client_secret.as_str()));
            }
            let token = token_request(&self.http, &fields, true).await?;
            let access = token.access()?;
            let refresh_token = token
                .refresh_token
                .as_ref()
                .filter(|v| valid_token(v))
                .ok_or(AuthorizationError::Response)?;
            return Ok(Grant {
                client: self.client,
                refresh_token: Zeroizing::new(refresh_token.clone()),
                access,
            });
        }
        Err(AuthorizationError::Response)
    }
}

/// Only exact origin-form GET, exact Host and no body/transfer/origin header.
/// Parse only after the entire bounded header arrives. A matching-state denial
/// ends this attempt; a wrong-state request cannot end another authorization.
async fn read_callback(
    socket: &mut TcpStream,
    redirect: &str,
    state: &str,
) -> Result<Result<Zeroizing<String>>> {
    let mut bytes = Zeroizing::new(Vec::new());
    loop {
        if bytes.len() >= CALLBACK_LIMIT {
            return Err(AuthorizationError::Response);
        }
        let mut part = Zeroizing::new([0u8; 1024]);
        let count = socket
            .read(part.as_mut())
            .await
            .map_err(|_| AuthorizationError::Response)?;
        if count == 0 {
            return Err(AuthorizationError::Response);
        }
        bytes.extend_from_slice(&part[..count]);
        if bytes.windows(4).any(|b| b == b"\r\n\r\n") {
            break;
        }
    }
    parse_callback(&bytes, redirect, state)
}
fn parse_callback(bytes: &[u8], redirect: &str, state: &str) -> Result<Result<Zeroizing<String>>> {
    if bytes.len() > CALLBACK_LIMIT
        || bytes.windows(4).position(|s| s == b"\r\n\r\n") != bytes.len().checked_sub(4)
    {
        return Err(AuthorizationError::Response);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| AuthorizationError::Response)?;
    let mut lines = text.split("\r\n");
    let first = lines.next().ok_or(AuthorizationError::Response)?;
    let words: Vec<_> = first.split(' ').collect();
    if words.len() != 3
        || words[0] != "GET"
        || words[2] != "HTTP/1.1"
        || !words[1].starts_with("/oauth2/callback?")
        || words[1].chars().any(char::is_control)
        || words[1].contains('#')
    {
        return Err(AuthorizationError::Response);
    }
    let local = Url::parse(redirect).map_err(|_| AuthorizationError::Configuration)?;
    let host = format!(
        "127.0.0.1:{}",
        local.port().ok_or(AuthorizationError::Configuration)?
    );
    let mut hosts = 0;
    for line in lines.take_while(|s| !s.is_empty()) {
        let (name, value) = line.split_once(':').ok_or(AuthorizationError::Response)?;
        if name.is_empty()
            || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            || value.chars().any(|c| c.is_control() && c != '\t')
        {
            return Err(AuthorizationError::Response);
        }
        if name.eq_ignore_ascii_case("host") {
            hosts += 1;
            if value.trim() != host {
                return Err(AuthorizationError::Response);
            }
        }
        if ["content-length", "transfer-encoding", "origin"]
            .iter()
            .any(|n| name.eq_ignore_ascii_case(n))
        {
            return Err(AuthorizationError::Response);
        }
    }
    if hosts != 1 {
        return Err(AuthorizationError::Response);
    }
    let url = Url::parse(&format!("http://{host}{}", words[1]))
        .map_err(|_| AuthorizationError::Response)?;
    if url.path() != "/oauth2/callback" {
        return Err(AuthorizationError::Response);
    }
    let mut params = std::collections::BTreeMap::new();
    for (key, value) in url.query_pairs() {
        if params.len() >= 12
            || params
                .insert(key.into_owned(), Zeroizing::new(value.into_owned()))
                .is_some()
        {
            return Err(AuthorizationError::Response);
        }
    }
    if !params
        .get("state")
        .is_some_and(|value| same_state(value, state))
    {
        return Err(AuthorizationError::Response);
    }
    let code = params.remove("code");
    if params.contains_key("error") {
        if code.is_some() {
            return Err(AuthorizationError::Response);
        }
        return Ok(Err(AuthorizationError::Denied));
    }
    let code = code
        .filter(|v| !v.is_empty() && v.len() <= 4096 && !v.chars().any(char::is_control))
        .ok_or(AuthorizationError::Response)?;
    Ok(Ok(code))
}
async fn respond(socket: &mut TcpStream, accepted: bool) -> std::io::Result<()> {
    let (status, body) = if accepted {
        (
            "200 OK",
            "HSPTerm authorization received. Return to the application.",
        )
    } else {
        ("400 Bad Request", "Invalid HSPTerm authorization callback.")
    };
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    socket.write_all(response.as_bytes()).await?;
    socket.shutdown().await
}

#[derive(Deserialize)]
struct TokenWire {
    access_token: String,
    token_type: String,
    expires_in: u64,
    refresh_token: Option<String>,
    scope: Option<String>,
}
impl Drop for TokenWire {
    fn drop(&mut self) {
        self.access_token.zeroize();
        self.refresh_token.zeroize();
    }
}
impl TokenWire {
    fn access(&self) -> Result<AccessToken> {
        if self.token_type != "Bearer"
            || !valid_token(&self.access_token)
            || !(1..=86400).contains(&self.expires_in)
        {
            return Err(AuthorizationError::Response);
        }
        Ok(AccessToken {
            value: Zeroizing::new(self.access_token.clone()),
            expires: Instant::now() + Duration::from_secs(self.expires_in),
        })
    }
}
pub(super) async fn bounded(
    response: &mut reqwest::Response,
    limit: usize,
) -> Result<Zeroizing<Vec<u8>>> {
    if response.headers().contains_key(header::CONTENT_RANGE)
        || response
            .headers()
            .get_all(header::CONTENT_ENCODING)
            .iter()
            .any(|v| v.as_bytes() != b"identity")
        || response.content_length().is_some_and(|n| n > limit as u64)
    {
        return Err(AuthorizationError::Response);
    }
    let mut bytes = Zeroizing::new(Vec::new());
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| AuthorizationError::Network)?
    {
        if bytes
            .len()
            .checked_add(chunk.len())
            .is_none_or(|n| n > limit)
        {
            return Err(AuthorizationError::Response);
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}
async fn token_request(
    http: &Client,
    fields: &[(&str, &str)],
    require_scope: bool,
) -> Result<TokenWire> {
    // URL form encoding is held in a zeroizing owner. reqwest/hyper internal
    // request buffers cannot provide an end-to-end erasure guarantee.
    let body = Zeroizing::new(
        Url::parse_with_params("https://localhost/", fields.iter().copied())
            .map_err(|_| AuthorizationError::Configuration)?
            .query()
            .unwrap_or_default()
            .to_owned(),
    );
    let mut response = http
        .post(TOKEN)
        .header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
        .header(header::ACCEPT_ENCODING, "identity")
        .header(header::CACHE_CONTROL, "no-store")
        .body(body.as_bytes().to_vec())
        .send()
        .await
        .map_err(|_| AuthorizationError::Network)?;
    if matches!(
        response.status(),
        StatusCode::BAD_REQUEST | StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN
    ) {
        return Err(AuthorizationError::Denied);
    }
    if response.status() != StatusCode::OK {
        return Err(AuthorizationError::Network);
    }
    let bytes = bounded(&mut response, JSON_LIMIT).await?;
    let token: TokenWire =
        serde_json::from_slice(&bytes).map_err(|_| AuthorizationError::Response)?;
    if (require_scope && token.scope.is_none()) || token.scope.as_ref().is_some_and(|s| s != SCOPE)
    {
        return Err(AuthorizationError::Denied);
    }
    token.access()?;
    Ok(token)
}
/// One explicit sync operation can refresh its original device-local account.
/// No background refresh thread or retry/fallback to another account.
pub async fn refresh(
    client: &DesktopClient,
    refresh_token: &str,
    proxy: Option<IndependentProxy>,
    timeout_seconds: u32,
    cancel: &CancellationToken,
) -> Result<Refreshed> {
    client.validate()?;
    if !valid_token(refresh_token) {
        return Err(AuthorizationError::Configuration);
    }
    let http = webdav::client(proxy, timeout_seconds, false)
        .map_err(|_| AuthorizationError::Configuration)?;
    let mut fields = vec![
        ("client_id", client.client_id.as_str()),
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token),
    ];
    if !client.client_secret.is_empty() {
        fields.push(("client_secret", client.client_secret.as_str()));
    }
    tokio::select! { biased;
        _ = cancel.cancelled() => Err(AuthorizationError::Cancelled),
        token = token_request(&http, &fields, false) => {
            let token = token?;
            if token.refresh_token.as_ref().is_some_and(|v| !valid_token(v)) {
                return Err(AuthorizationError::Response);
            }
            Ok(Refreshed { access: token.access()?, rotated_refresh_token: token.refresh_token.as_ref().map(|s| Zeroizing::new(s.clone())), source_tag: refresh_source(client, refresh_token) })
        },
    }
}
/// Revocation is a remote, explicit action. Local deletion is separate and
/// must not be reported as a successful Google-side revoke.
pub async fn revoke(
    refresh_token: &str,
    proxy: Option<IndependentProxy>,
    timeout_seconds: u32,
    cancel: &CancellationToken,
) -> Result<()> {
    if !valid_token(refresh_token) {
        return Err(AuthorizationError::Configuration);
    }
    let http = webdav::client(proxy, timeout_seconds, false)
        .map_err(|_| AuthorizationError::Configuration)?;
    let body = Zeroizing::new(
        Url::parse_with_params("https://localhost/", [("token", refresh_token)])
            .map_err(|_| AuthorizationError::Configuration)?
            .query()
            .unwrap_or_default()
            .to_owned(),
    );
    tokio::select! { biased;
        _ = cancel.cancelled() => Err(AuthorizationError::RevokeUnknown),
        result = http.post(REVOKE).header(header::CONTENT_TYPE, "application/x-www-form-urlencoded")
            .header(header::CACHE_CONTROL, "no-store").body(body.as_bytes().to_vec()).send() => {
            let response = result.map_err(|_| AuthorizationError::RevokeUnknown)?;
            if response.status() == StatusCode::OK { Ok(()) }
            else { Err(AuthorizationError::RevokeUnknown) }
        },
    }
}
impl From<TransportError> for AuthorizationError {
    fn from(_: TransportError) -> Self {
        Self::Configuration
    }
}

#[cfg(test)]
pub(super) fn fixture_access() -> AccessToken {
    AccessToken {
        value: Zeroizing::new("synthetic-access-token".into()),
        expires: Instant::now() + Duration::from_secs(3600),
    }
}
#[cfg(test)]
pub(crate) fn fixture_refresh(client: &DesktopClient, old: &str, next: Option<&str>) -> Refreshed {
    Refreshed {
        access: fixture_access(),
        rotated_refresh_token: next.map(|s| Zeroizing::new(s.into())),
        source_tag: refresh_source(client, old),
    }
}
#[cfg(test)]
#[path = "drive_oauth_tests.rs"]
mod tests;
