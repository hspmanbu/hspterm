//! Encrypted host proxy metadata and independently stored authentication.
use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProxyKind {
    HttpConnect,
    Socks5,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProxySettings {
    pub kind: ProxyKind,
    pub address: String,
    pub port: u16,
    pub authenticate: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProxyCredential {
    pub username: String,
    pub password: String,
}
impl Drop for ProxyCredential {
    fn drop(&mut self) {
        self.username.zeroize();
        self.password.zeroize();
    }
}

pub(crate) fn host(value: &str) -> bool {
    if value.starts_with('[') || value.ends_with(']') {
        return value
            .strip_prefix('[')
            .and_then(|s| s.strip_suffix(']'))
            .is_some_and(|s| s.parse::<std::net::Ipv6Addr>().is_ok());
    }
    value.parse::<std::net::IpAddr>().is_ok()
        || (!value.is_empty()
            && value.len() <= 253
            && value.bytes().any(|b| b.is_ascii_alphanumeric())
            && value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b)))
}
impl ProxySettings {
    pub(crate) fn valid(&self, target: &str) -> bool {
        self.port != 0 && host(&self.address) && host(target)
    }
    pub(crate) fn credential_valid(&self, c: &ProxyCredential) -> bool {
        match self.kind {
            ProxyKind::HttpConnect => {
                !c.username.is_empty()
                    && !c.username.contains(':')
                    && c.username.len().saturating_add(c.password.len()) <= 4096
                    && !c
                        .username
                        .chars()
                        .chain(c.password.chars())
                        .any(char::is_control)
            }
            ProxyKind::Socks5 => {
                (1..=255).contains(&c.username.len()) && (1..=255).contains(&c.password.len())
            }
        }
    }
}
