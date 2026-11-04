//! Passive, session-local OSC 7 metadata. It is never evidence of a safe shell input state.
use std::net::IpAddr;

pub const MAX_REMOTE_PATH_BYTES: usize = 16 * 1024;

#[derive(Clone, PartialEq, Eq)]
pub struct WorkingDirectory {
    pub authority: String,
    pub path: String,
}
impl std::fmt::Debug for WorkingDirectory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("WorkingDirectory(<redacted>)")
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum RemotePathError {
    #[error("路径为空、过长或包含控制字符；未定位")]
    Invalid,
    #[error("没有同一服务器的可靠 OSC 7 工作目录；请使用绝对路径")]
    UnknownDirectory,
    #[error("文件链接的服务器与原SSH目标不一致；未定位")]
    ForeignAuthority,
    #[error("无法可靠生成不含父目录跳转的相对路径；请复制绝对路径")]
    UncertainRelative,
}

/// A file URI emitted by a remote terminal belongs only to that authenticated
/// stream. Never turn it into a local file open, DNS lookup or another SSH root.
/// Literal path handling stays separate: percent decoding happens exactly once
/// for URIs, and never changes a literal POSIX path or its symlink/.. semantics.
pub fn resolve_remote_reference(
    text: &str,
    cwd: Option<&WorkingDirectory>,
    host: &str,
) -> Result<String, RemotePathError> {
    if text
        .get(..7)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("file://"))
    {
        if text.len() > MAX_REMOTE_PATH_BYTES {
            return Err(RemotePathError::Invalid);
        }
        let uri = format!("file://{}", &text[7..]);
        let file = WorkingDirectory::parse(&uri).ok_or(RemotePathError::Invalid)?;
        if !file.matches_host(host) {
            return Err(RemotePathError::ForeignAuthority);
        }
        if file.path.chars().any(|c| matches!(c,
            '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'))
        {
            return Err(RemotePathError::Invalid);
        }
        return Ok(file.path);
    }
    resolve_remote_path(text, cwd, host)
}

fn valid_path(path: &str) -> bool {
    !path.is_empty() && path.len() <= MAX_REMOTE_PATH_BYTES && !path.chars().any(char::is_control)
}

impl WorkingDirectory {
    /// Strictly decode once, without URL normalization (which would change symlink/.. semantics).
    /// Invalid reports replace rather than retain an older, now unreliable working directory.
    pub fn parse(uri: &str) -> Option<Self> {
        if uri.len() > MAX_REMOTE_PATH_BYTES || uri.contains(['?', '#']) {
            return None;
        }
        let rest = uri.strip_prefix("file://")?;
        let (authority, encoded_path) = rest.split_at(rest.find('/')?);
        if authority.starts_with('[') {
            authority
                .strip_prefix('[')?
                .strip_suffix(']')?
                .parse::<std::net::Ipv6Addr>()
                .ok()?;
        } else if !authority
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
        {
            return None;
        }
        let mut decoded = Vec::with_capacity(encoded_path.len());
        let mut bytes = encoded_path.bytes();
        while let Some(b) = bytes.next() {
            decoded.push(if b == b'%' {
                let a = (bytes.next()? as char).to_digit(16)?;
                let b = (bytes.next()? as char).to_digit(16)?;
                (a * 16 + b) as u8
            } else {
                b
            });
        }
        let path = String::from_utf8(decoded).ok()?;
        if !valid_path(&path) || !path.starts_with('/') {
            return None;
        }
        Some(Self {
            authority: authority.to_owned(),
            path,
        })
    }

    pub fn matches_host(&self, host: &str) -> bool {
        if self.authority.is_empty() {
            // An authority-less report belongs only to the authenticated stream that emitted it.
            return true;
        }
        let unbracket = |s: &str| {
            s.strip_prefix('[')
                .and_then(|s| s.strip_suffix(']'))
                .unwrap_or(s)
                .to_owned()
        };
        let a = unbracket(&self.authority);
        let b = unbracket(host);
        match (a.parse::<IpAddr>(), b.parse::<IpAddr>()) {
            (Ok(a), Ok(b)) => a == b,
            _ => a
                .trim_end_matches('.')
                .eq_ignore_ascii_case(b.trim_end_matches('.')),
        }
    }

    pub fn resolve(&self, path: &str, host: &str) -> Result<String, RemotePathError> {
        resolve_remote_path(path, Some(self), host)
    }
}

/// Literal POSIX paths only: no tilde/environment expansion, Shell unquoting or network lookup.
pub fn resolve_remote_path(
    path: &str,
    cwd: Option<&WorkingDirectory>,
    host: &str,
) -> Result<String, RemotePathError> {
    if !valid_path(path) {
        return Err(RemotePathError::Invalid);
    }
    if path.starts_with('/') {
        return Ok(path.to_owned());
    }
    let cwd = cwd
        .filter(|cwd| cwd.matches_host(host))
        .ok_or(RemotePathError::UnknownDirectory)?;
    let result = format!("{}/{}", cwd.path.trim_end_matches('/'), path);
    if !valid_path(&result) {
        return Err(RemotePathError::Invalid);
    }
    Ok(result)
}

/// A descendant-only relative spelling. Never synthesize '..': resolving a
/// parent through a symlink can change its meaning. Outside that provable case
/// the caller must offer the original absolute path instead of guessing.
pub fn relative_remote_path(
    path: &str,
    cwd: Option<&WorkingDirectory>,
    host: &str,
) -> Result<String, RemotePathError> {
    let cwd = cwd
        .filter(|d| d.matches_host(host))
        .ok_or(RemotePathError::UnknownDirectory)?;
    fn simple(path: &str) -> bool {
        path.starts_with('/')
            && !path.starts_with("//")
            && path.len() <= MAX_REMOTE_PATH_BYTES
            && !path.contains('\0')
            && (path == "/"
                || path
                    .trim_end_matches('/')
                    .split('/')
                    .skip(1)
                    .all(|p| !p.is_empty() && p != "." && p != ".."))
    }
    if !simple(path) || !simple(&cwd.path) {
        return Err(RemotePathError::UncertainRelative);
    }
    let base = cwd.path.trim_end_matches('/');
    if path.trim_end_matches('/') == base {
        return Ok(".".into());
    }
    let suffix = path
        .strip_prefix(base)
        .and_then(|s| s.strip_prefix('/'))
        .filter(|s| !s.is_empty())
        .ok_or(RemotePathError::UncertainRelative)?;
    // An option-looking file name stays a path argument when copied into a
    // command. './' also distinguishes relative paths from bare command names.
    Ok(format!("./{suffix}"))
}
#[cfg(test)]
mod relative_tests {
    use super::*;
    #[test]
    fn descendant_paths_preserve_unicode_quotes_and_literal_newlines_without_shell_expansion() {
        let cwd = WorkingDirectory::parse("file://server/home/u/my%20project").unwrap();
        assert_eq!(
            relative_remote_path(
                "/home/u/my project/中文 'x';$name\nfile",
                Some(&cwd),
                "SERVER."
            )
            .unwrap(),
            "./中文 'x';$name\nfile"
        );
        assert_eq!(
            relative_remote_path("/home/u/my project", Some(&cwd), "server").unwrap(),
            "."
        );
        assert_eq!(
            relative_remote_path("/home/u/my project/-rf", Some(&cwd), "server").unwrap(),
            "./-rf"
        );
        let root = WorkingDirectory::parse("file:///").unwrap();
        assert_eq!(
            relative_remote_path("/a/b", Some(&root), "server").unwrap(),
            "./a/b"
        );
    }
    #[test]
    fn unknown_foreign_parent_prefix_and_symlink_ambiguous_spellings_are_rejected() {
        let cwd = WorkingDirectory::parse("file://server/a/link").unwrap();
        for target in [
            "/a/other",
            "/a/link-other/x",
            "/a/link/../x",
            "/a/link/a//b",
            "//a/link/file",
            "relative",
            "/a/link/a\0b",
        ] {
            assert!(relative_remote_path(target, Some(&cwd), "server").is_err());
        }
        assert!(relative_remote_path("/a/link/file", None, "server").is_err());
        assert!(relative_remote_path("/a/link/file", Some(&cwd), "other").is_err());
        let ambiguous = WorkingDirectory::parse("file://server/a/link/../b").unwrap();
        assert!(relative_remote_path("/a/link/../b/file", Some(&ambiguous), "server").is_err());
    }
}
