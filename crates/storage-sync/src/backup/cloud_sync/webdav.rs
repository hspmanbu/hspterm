//! Exact-object WebDAV GET/conditional PUT. No directory scans, MKCOL, DELETE,
//! redirects, ambient proxy, SSH credentials, startup timer or automatic retry.
use super::{
    Acknowledged, EntityTag, MAX_ENCRYPTED_BYTES, PendingUpload, PublicationCondition, RemoteRead,
};
use reqwest::{Client, RequestBuilder, Response, StatusCode, Url, header};
use std::{sync::OnceLock, time::Duration};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("同步地址、认证、独立代理或超时配置无效")]
    Configuration,
    #[error("同步读取已取消；本机配置未应用")]
    Cancelled,
    #[error("同步网络或TLS请求失败；未把失败当作云端数据不存在")]
    Network,
    #[error("同步目标拒绝访问；请核对目标和认证")]
    Denied,
    #[error("同步服务器响应不支持安全条件写入或格式无效")]
    Response,
    #[error("同步响应超过安全容量")]
    Capacity,
    #[error("同步写入结果未确认；可能已写入，后续必须重新读取，不可盲目重发")]
    WriteUnknown,
}
type Result<T> = std::result::Result<T, TransportError>;

/// Separate network route, deliberately not an SSH ProxySettings reference.
/// Only http CONNECT and socks5h (proxy-side DNS) are supported here.
pub struct IndependentProxy {
    pub address: String,
    pub username: Option<String>,
    pub password: Zeroizing<String>,
}
pub struct Authentication {
    pub username: String,
    pub password: Zeroizing<String>,
}
/// One object URL, not a base directory. Creating parent directories is an
/// explicit server-side setup task, never an implicit sync write elsewhere.
pub struct WebDav {
    client: Client,
    endpoint: Url,
    authentication: Option<Authentication>,
}
pub enum PutResponse {
    Confirmed(Acknowledged),
    PreconditionFailed,
}

pub(super) fn valid_auth(username: &str, password: &str) -> bool {
    !username.is_empty()
        && username.len() <= 1024
        && !username.contains(':')
        && !username.chars().any(char::is_control)
        && password.len() <= 4096
        && !password.chars().any(char::is_control)
}
fn exact_url(value: &str) -> Result<Url> {
    if value.len() > 8192 || value.chars().any(char::is_control) {
        return Err(TransportError::Configuration);
    }
    let url = Url::parse(value).map_err(|_| TransportError::Configuration)?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() == "/"
        || url.path().ends_with('/')
    {
        return Err(TransportError::Configuration);
    }
    Ok(url)
}
pub(super) fn checked_endpoint(value: &str) -> Result<String> {
    let result = exact_url(value)?.to_string();
    if result.len() > 8192 {
        return Err(TransportError::Configuration);
    }
    Ok(result)
}
pub(super) fn checked_proxy(value: &str) -> Result<bool> {
    if value.len() > 4096 || value.chars().any(char::is_control) {
        return Err(TransportError::Configuration);
    }
    let url = Url::parse(value).map_err(|_| TransportError::Configuration)?;
    if !matches!(url.scheme(), "http" | "socks5h")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/")
    {
        return Err(TransportError::Configuration);
    }
    Ok(url.scheme() == "socks5h")
}
/// OAuth/Drive keep HTTPS-only clients. WebDAV explicitly permits HTTP URLs
/// chosen by the user; redirects remain disabled for both protocols.
pub(super) fn client(
    proxy: Option<IndependentProxy>,
    timeout_seconds: u32,
    allow_http: bool,
) -> Result<Client> {
    if !(1..=300).contains(&timeout_seconds) {
        return Err(TransportError::Configuration);
    }
    // Only ring is enabled by this manifest. If another consumer installed
    // an explicit provider first, preserve it instead of changing process
    // TLS policy underneath already-running connections.
    static TLS: OnceLock<()> = OnceLock::new();
    TLS.get_or_init(|| {
        if rustls::crypto::CryptoProvider::get_default().is_none() {
            let _already_installed = rustls::crypto::ring::default_provider().install_default();
        }
    });
    let mut builder = Client::builder()
        .tls_backend_rustls()
        .https_only(!allow_http)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .referer(false)
        .retry(reqwest::retry::never())
        .no_gzip()
        .no_brotli()
        .no_deflate()
        .no_zstd()
        .http1_only()
        .http1_max_headers(64)
        .connection_verbose(false)
        .timeout(Duration::from_secs(timeout_seconds.into()))
        .connect_timeout(Duration::from_secs(u64::from(timeout_seconds.min(30))))
        .pool_max_idle_per_host(0)
        .tcp_keepalive(None);
    if let Some(proxy) = proxy {
        let socks = checked_proxy(&proxy.address)?;
        let url = Url::parse(&proxy.address).map_err(|_| TransportError::Configuration)?;
        let mut route = reqwest::Proxy::all(url).map_err(|_| TransportError::Configuration)?;
        if let Some(username) = &proxy.username {
            if !valid_auth(username, &proxy.password)
                || socks
                    && (username.len() > 255
                        || proxy.password.is_empty()
                        || proxy.password.len() > 255)
            {
                return Err(TransportError::Configuration);
            }
            route = route.basic_auth(username, &proxy.password);
        } else if !proxy.password.is_empty() {
            return Err(TransportError::Configuration);
        }
        builder = builder.proxy(route);
    }
    builder.build().map_err(|_| TransportError::Configuration)
}
impl WebDav {
    pub fn new(
        endpoint: &str,
        authentication: Option<Authentication>,
        proxy: Option<IndependentProxy>,
        timeout_seconds: u32,
    ) -> Result<Self> {
        if !(1..=300).contains(&timeout_seconds)
            || authentication
                .as_ref()
                .is_some_and(|a| !valid_auth(&a.username, &a.password))
        {
            return Err(TransportError::Configuration);
        }
        let endpoint = exact_url(endpoint)?;
        let client = client(proxy, timeout_seconds, endpoint.scheme() == "http")?;
        Ok(Self {
            client,
            endpoint,
            authentication,
        })
    }
    fn authenticate(&self, request: RequestBuilder) -> RequestBuilder {
        let request = request
            .header(header::ACCEPT_ENCODING, "identity")
            .header(header::CACHE_CONTROL, "no-store");
        match &self.authentication {
            Some(a) => request.basic_auth(&a.username, Some(a.password.as_str())),
            None => request,
        }
    }
    pub async fn read(&self, cancel: &CancellationToken) -> Result<RemoteRead> {
        tokio::select! { biased;
            _ = cancel.cancelled() => Err(TransportError::Cancelled),
            result = self.read_inner() => result,
        }
    }
    async fn read_inner(&self) -> Result<RemoteRead> {
        let mut response = self
            .authenticate(self.client.get(self.endpoint.clone()))
            .send()
            .await
            .map_err(|_| TransportError::Network)?;
        match response.status() {
            StatusCode::NOT_FOUND => return Ok(RemoteRead::Missing),
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => return Err(TransportError::Denied),
            StatusCode::OK => {}
            _ => return Err(TransportError::Response),
        }
        if response.headers().contains_key(header::CONTENT_RANGE)
            || response
                .headers()
                .get(header::CONTENT_ENCODING)
                .is_some_and(|v| v.as_bytes() != b"identity")
        {
            return Err(TransportError::Response);
        }
        let etag = response_tag(&response)?;
        if response
            .content_length()
            .is_some_and(|n| n > MAX_ENCRYPTED_BYTES as u64)
        {
            return Err(TransportError::Capacity);
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| TransportError::Network)?
        {
            if bytes
                .len()
                .checked_add(chunk.len())
                .is_none_or(|n| n > MAX_ENCRYPTED_BYTES)
            {
                return Err(TransportError::Capacity);
            }
            bytes.extend_from_slice(&chunk);
        }
        Ok(RemoteRead::Present {
            etag,
            ciphertext: bytes,
        })
    }
    pub async fn publish(
        &self,
        upload: PendingUpload,
        cancel: &CancellationToken,
    ) -> Result<PutResponse> {
        // Even cancellation before the caller observes headers is conservatively
        // unknown: transport cancellation cannot retract a server-side write.
        tokio::select! { biased;
            _ = cancel.cancelled() => Err(TransportError::WriteUnknown),
            result = self.publish_inner(upload) => result,
        }
    }
    async fn publish_inner(&self, upload: PendingUpload) -> Result<PutResponse> {
        let mut request = self
            .authenticate(self.client.put(self.endpoint.clone()))
            .header(header::CONTENT_TYPE, "application/octet-stream");
        request = match upload.condition() {
            PublicationCondition::CreateOnly => request.header(header::IF_NONE_MATCH, "*"),
            PublicationCondition::Match(tag) => {
                request.header(header::IF_MATCH, tag.header_value())
            }
        };
        // Only ciphertext enters the HTTP library. Its internal request buffer
        // cannot contain decrypted host credentials or command history.
        let response = request
            .body(upload.ciphertext().to_vec())
            .send()
            .await
            .map_err(|_| TransportError::WriteUnknown)?;
        match response.status() {
            StatusCode::PRECONDITION_FAILED => Ok(PutResponse::PreconditionFailed),
            StatusCode::OK | StatusCode::CREATED | StatusCode::NO_CONTENT => {
                let tag = response_tag(&response).map_err(|_| TransportError::WriteUnknown)?;
                Ok(PutResponse::Confirmed(upload.acknowledge(tag)))
            }
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => Err(TransportError::Denied),
            // Server errors/redirects can arrive after a write reached storage.
            // Preserve the local baseline, and re-read on a future explicit run.
            _ => Err(TransportError::WriteUnknown),
        }
    }
}
pub(super) fn response_tag(response: &Response) -> Result<EntityTag> {
    let mut tags = response.headers().get_all(header::ETAG).iter();
    let value = tags.next().ok_or(TransportError::Response)?;
    if tags.next().is_some() {
        return Err(TransportError::Response);
    }
    EntityTag::parse(value.to_str().map_err(|_| TransportError::Response)?)
        .map_err(|_| TransportError::Response)
}

#[cfg(test)]
mod tests;
