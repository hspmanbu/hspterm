//! A single explicit TCP proxy hop. No direct fallback, credential logging or
//! local DNS lookup for a SOCKS destination. SSH host-key verification follows.
use crate::SshError;
use base64::{Engine, engine::general_purpose::STANDARD};
use std::{fmt, net::IpAddr};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use zeroize::Zeroizing;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyKind {
    HttpConnect,
    Socks5,
}

#[derive(Clone)]
pub struct ProxyCredentials {
    pub username: Zeroizing<String>,
    pub password: Zeroizing<String>,
}
impl ProxyCredentials {
    pub fn new(username: String, password: String) -> Self {
        Self {
            username: Zeroizing::new(username),
            password: Zeroizing::new(password),
        }
    }
}
impl fmt::Debug for ProxyCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("ProxyCredentials(<redacted>)")
    }
}

#[derive(Clone)]
pub struct ProxyConfig {
    pub kind: ProxyKind,
    pub address: String,
    pub port: u16,
    pub authentication: Option<ProxyCredentials>,
}
impl fmt::Debug for ProxyConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ProxyConfig")
            .field("kind", &self.kind)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ProxyError {
    #[error("代理配置或目标地址无效")]
    InvalidConfig,
    #[error("代理协商响应无效或超过限制")]
    InvalidResponse,
    #[error("代理认证失败")]
    Authentication,
    #[error("代理未接受配置的认证方式")]
    AuthenticationMethod,
    #[error("HTTP 代理拒绝请求（状态 {0}）")]
    HttpStatus(u16),
    #[error("SOCKS5 代理拒绝目标连接（状态 {0}）")]
    SocksStatus(u8),
}

pub(crate) fn host(value: &str) -> Option<&str> {
    if value.starts_with('[') || value.ends_with(']') {
        let inner = value.strip_prefix('[')?.strip_suffix(']')?;
        return inner.parse::<std::net::Ipv6Addr>().ok().map(|_| inner);
    }
    if value.parse::<IpAddr>().is_ok() {
        return Some(value);
    }
    if value.is_empty()
        || value.len() > 253
        || !value.bytes().any(|b| b.is_ascii_alphanumeric())
        || !value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
    {
        return None;
    }
    Some(value)
}
impl ProxyConfig {
    pub(crate) fn validate(&self, target: &str, port: u16) -> Result<(), ProxyError> {
        if self.port == 0 || port == 0 || host(&self.address).is_none() || host(target).is_none() {
            return Err(ProxyError::InvalidConfig);
        }
        if let Some(auth) = &self.authentication {
            let user = auth.username.as_str();
            let password = auth.password.as_str();
            let valid = match self.kind {
                ProxyKind::HttpConnect => {
                    !user.is_empty()
                        && !user.contains(':')
                        && user.len().saturating_add(password.len()) <= 4096
                        && !user.chars().chain(password.chars()).any(char::is_control)
                }
                ProxyKind::Socks5 => {
                    (1..=255).contains(&user.len()) && (1..=255).contains(&password.len())
                }
            };
            if !valid {
                return Err(ProxyError::InvalidConfig);
            }
        }
        Ok(())
    }
}

pub(crate) async fn negotiate<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    proxy: &ProxyConfig,
    target: &str,
    port: u16,
) -> Result<(), SshError> {
    proxy.validate(target, port)?;
    let target = host(target).ok_or(ProxyError::InvalidConfig)?;
    match proxy.kind {
        ProxyKind::HttpConnect => http(stream, proxy.authentication.as_ref(), target, port).await,
        ProxyKind::Socks5 => socks(stream, proxy.authentication.as_ref(), target, port).await,
    }
}

async fn http<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    auth: Option<&ProxyCredentials>,
    target: &str,
    port: u16,
) -> Result<(), SshError> {
    let authority = if target.parse::<std::net::Ipv6Addr>().is_ok() {
        format!("[{target}]:{port}")
    } else {
        format!("{target}:{port}")
    };
    {
        let mut request = Zeroizing::new(
            format!("CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n").into_bytes(),
        );
        if let Some(auth) = auth {
            let raw = Zeroizing::new(format!(
                "{}:{}",
                auth.username.as_str(),
                auth.password.as_str()
            ));
            let encoded = Zeroizing::new(STANDARD.encode(raw.as_bytes()));
            request.extend_from_slice(b"Proxy-Authorization: Basic ");
            request.extend_from_slice(encoded.as_bytes());
            request.extend_from_slice(b"\r\n");
        }
        request.extend_from_slice(b"\r\n");
        stream.write_all(&request).await?;
        stream.flush().await?;
    }
    for _ in 0..5 {
        let mut response = Zeroizing::new(Vec::new());
        // Never buffer past the header: the same packet may contain the SSH banner.
        while !response.ends_with(b"\r\n\r\n") {
            if response.len() >= 16 * 1024 {
                return Err(ProxyError::InvalidResponse.into());
            }
            response.push(stream.read_u8().await?);
        }
        let status = http_status(&response)?;
        match status {
            200..=299 => return Ok(()),
            100..=199 => continue,
            407 => return Err(ProxyError::Authentication.into()),
            n => return Err(ProxyError::HttpStatus(n).into()),
        }
    }
    Err(ProxyError::InvalidResponse.into())
}

fn http_status(header: &[u8]) -> Result<u16, ProxyError> {
    let mut lines = header.split(|b| *b == b'\n');
    let line = lines
        .next()
        .and_then(|s| s.strip_suffix(b"\r"))
        .ok_or(ProxyError::InvalidResponse)?;
    if line.len() < 12
        || !matches!(&line[..8], b"HTTP/1.0" | b"HTTP/1.1")
        || line[8] != b' '
        || !line[9..12].iter().all(u8::is_ascii_digit)
        || (line.len() > 12 && line[12] != b' ')
    {
        return Err(ProxyError::InvalidResponse);
    }
    let status = u16::from(line[9] - b'0') * 100
        + u16::from(line[10] - b'0') * 10
        + u16::from(line[11] - b'0');
    if !(100..=599).contains(&status) {
        return Err(ProxyError::InvalidResponse);
    }
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let line = line
            .strip_suffix(b"\r")
            .ok_or(ProxyError::InvalidResponse)?;
        if line.is_empty() {
            continue;
        }
        let colon = line
            .iter()
            .position(|b| *b == b':')
            .ok_or(ProxyError::InvalidResponse)?;
        if colon == 0
            || !line[..colon]
                .iter()
                .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(b))
            || line[colon + 1..]
                .iter()
                .any(|b| (*b < 32 && *b != b'\t') || *b == 127)
        {
            return Err(ProxyError::InvalidResponse);
        }
    }
    Ok(status)
}

async fn socks<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    auth: Option<&ProxyCredentials>,
    target: &str,
    port: u16,
) -> Result<(), SshError> {
    let method = if auth.is_some() { 2 } else { 0 };
    stream.write_all(&[5, 1, method]).await?;
    stream.flush().await?;
    let mut selected = [0; 2];
    stream.read_exact(&mut selected).await?;
    if selected != [5, method] {
        return Err(ProxyError::AuthenticationMethod.into());
    }
    if let Some(auth) = auth {
        {
            let mut request = Zeroizing::new(vec![1, auth.username.len() as u8]);
            request.extend_from_slice(auth.username.as_bytes());
            request.push(auth.password.len() as u8);
            request.extend_from_slice(auth.password.as_bytes());
            stream.write_all(&request).await?;
            stream.flush().await?;
        }
        let mut reply = [0; 2];
        stream.read_exact(&mut reply).await?;
        if reply != [1, 0] {
            return Err(ProxyError::Authentication.into());
        }
    }
    let mut request = vec![5, 1, 0];
    match target.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => {
            request.push(1);
            request.extend_from_slice(&ip.octets());
        }
        Ok(IpAddr::V6(ip)) => {
            request.push(4);
            request.extend_from_slice(&ip.octets());
        }
        Err(_) => {
            request.extend_from_slice(&[3, target.len() as u8]);
            request.extend_from_slice(target.as_bytes());
        }
    }
    request.extend_from_slice(&port.to_be_bytes());
    stream.write_all(&request).await?;
    stream.flush().await?;
    let mut reply = [0; 4];
    stream.read_exact(&mut reply).await?;
    if reply[0] != 5 || reply[2] != 0 {
        return Err(ProxyError::InvalidResponse.into());
    }
    if reply[1] != 0 {
        return Err(ProxyError::SocksStatus(reply[1]).into());
    }
    let length = match reply[3] {
        1 => 4,
        4 => 16,
        3 => {
            let n = stream.read_u8().await?;
            if n == 0 {
                return Err(ProxyError::InvalidResponse.into());
            }
            n as usize
        }
        _ => return Err(ProxyError::InvalidResponse.into()),
    };
    let mut bound_address = Zeroizing::new(vec![0; length + 2]);
    stream.read_exact(&mut bound_address).await?;
    Ok(())
}

#[cfg(test)]
mod tests;
