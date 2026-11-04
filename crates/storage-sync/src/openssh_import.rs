//! Explicit, bounded metadata import. Never reads files, evaluates Match/Include,
//! executes commands, loads keys or participates in SSH runtime resolution.
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use thiserror::Error;

pub const MAX_BYTES: usize = 1024 * 1024;
const MAX_LINES: usize = 8192;
const MAX_HOSTS: usize = 256;
const MAX_WARNINGS: usize = 48;
#[derive(Debug, Error)]
pub enum ImportError {
    #[error("SSH配置超过导入容量限制（1MiB、8192行、256个明确主机）")]
    Limit,
    #[error("第{0}行SSH配置语法无效；未导入任何主机")]
    Syntax(usize),
    #[error("所选导入主机无效、重复或尚需处理警告；未保存")]
    Selection,
}
#[derive(Clone)]
pub struct ImportHost {
    pub alias: String,
    pub address: String,
    pub port: u16,
    pub username: String,
    pub private_key: bool,
    pub timeout_seconds: u32,
    pub keepalive_seconds: u32,
    pub keepalive_failures: u32,
    pub jump_alias: Option<String>,
    pub warnings: Vec<String>,
    pub blocked: bool,
}
#[derive(Clone)]
pub struct ImportPreview {
    pub hosts: Vec<ImportHost>,
    pub warnings: Vec<String>,
}
struct Directive {
    patterns: Option<Arc<[String]>>,
    key: String,
    value: Vec<String>,
    line: usize,
}
fn warning(warnings: &mut Vec<String>, value: String) {
    if warnings.len() < MAX_WARNINGS && !warnings.contains(&value) {
        warnings.push(value);
    }
}
fn literal(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 255
        && !value.starts_with('!')
        && !value
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || "*?%$\\\"'=,".contains(c))
}
/// Byte glob; aliases and patterns are bounded, with no regex/backtracking.
fn glob(pattern: &str, host: &str) -> bool {
    let p = pattern.as_bytes();
    let h = host.as_bytes();
    let (mut i, mut j, mut star, mut retry) = (0, 0, None, 0);
    while j < h.len() {
        if i < p.len() && (p[i] == b'?' || p[i].eq_ignore_ascii_case(&h[j])) {
            i += 1;
            j += 1;
        } else if i < p.len() && p[i] == b'*' {
            star = Some(i);
            i += 1;
            retry = j;
        } else if let Some(s) = star {
            retry += 1;
            j = retry;
            i = s + 1;
        } else {
            return false;
        }
    }
    while i < p.len() && p[i] == b'*' {
        i += 1;
    }
    i == p.len()
}
fn applies(patterns: &Option<Arc<[String]>>, alias: &str) -> bool {
    patterns.as_ref().is_none_or(|patterns| {
        let mut matched = false;
        for pattern in patterns.iter() {
            if let Some(no) = pattern.strip_prefix('!') {
                if glob(no, alias) {
                    return false;
                }
            } else if glob(pattern, alias) {
                matched = true;
            }
        }
        matched
    })
}
fn words(line: &str, number: usize) -> Result<Vec<String>, ImportError> {
    let mut result = Vec::new();
    let mut word = String::new();
    let (mut quoted, mut escaped, mut started) = (false, false, false);
    for c in line.chars() {
        if c.is_control() && c != '\t' {
            return Err(ImportError::Syntax(number));
        }
        if escaped {
            word.push(c);
            escaped = false;
            started = true;
        } else if c == '\\' {
            escaped = true;
            started = true;
        } else if c == '"' {
            quoted = !quoted;
            started = true;
        } else if c == '#' && !quoted {
            break;
        } else if c.is_whitespace() && !quoted {
            if started {
                result.push(std::mem::take(&mut word));
                started = false;
            }
        } else {
            word.push(c);
            started = true;
        }
    }
    if quoted || escaped {
        return Err(ImportError::Syntax(number));
    }
    if started {
        result.push(word);
    }
    if result.len() > 64 {
        return Err(ImportError::Limit);
    }
    Ok(result)
}
fn directive(line: &str, number: usize) -> Result<Option<(String, Vec<String>)>, ImportError> {
    let line = line.trim_start();
    if line.is_empty() || line.starts_with('#') {
        return Ok(None);
    }
    let cut = line
        .find(|c: char| c.is_whitespace() || c == '=')
        .unwrap_or(line.len());
    let key = &line[..cut];
    if key.is_empty() || key.len() > 64 || !key.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(ImportError::Syntax(number));
    }
    let rest = line[cut..].trim_start();
    let rest = rest.strip_prefix('=').map(str::trim_start).unwrap_or(rest);
    let values = words(rest, number)?;
    if values.is_empty() {
        return Err(ImportError::Syntax(number));
    }
    Ok(Some((key.to_ascii_lowercase(), values)))
}
fn expand_hostname(value: &str, alias: &str) -> Option<String> {
    let mut out = String::new();
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        match chars.next()? {
            'h' | 'n' => out.push_str(alias),
            '%' => out.push('%'),
            _ => return None,
        }
    }
    if out.is_empty()
        || out.len() > 1024
        || out.contains(['$', '%'])
        || out.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        None
    } else {
        Some(out)
    }
}
/// First obtained values win, including wildcard/global stanzas in source order.
/// Only literal Host aliases become candidates; wildcard stanzas provide defaults.
pub fn preview(text: &str, default_username: &str) -> Result<ImportPreview, ImportError> {
    if text.len() > MAX_BYTES || default_username.len() > 1024 || text.contains('\0') {
        return Err(ImportError::Limit);
    }
    let mut directives = Vec::new();
    let mut aliases = Vec::new();
    let mut unique = BTreeSet::new();
    let mut patterns = None;
    let mut skip_match = false;
    let mut warnings = Vec::new();
    for (index, line) in text
        .strip_prefix('\u{feff}')
        .unwrap_or(text)
        .lines()
        .enumerate()
    {
        let number = index + 1;
        if number > MAX_LINES || line.len() > 16384 {
            return Err(ImportError::Limit);
        }
        let Some((key, value)) = directive(line.trim_end_matches('\r'), number)? else {
            continue;
        };
        if key == "host" {
            for alias in &value {
                if literal(alias) && unique.insert(alias.to_ascii_lowercase()) {
                    aliases.push(alias.clone());
                    if aliases.len() > MAX_HOSTS {
                        return Err(ImportError::Limit);
                    }
                }
            }
            patterns = Some(value.into());
            skip_match = false;
        } else if key == "match" {
            skip_match = true;
            warning(
                &mut warnings,
                format!("第{number}行：未执行Match条件，其后的条件块未导入；请核对主机预览"),
            );
        } else if key == "include" {
            warning(
                &mut warnings,
                format!("第{number}行：未读取Include文件；外部文件可能影响参数，请核对预览"),
            );
        } else if !skip_match {
            directives.push(Directive {
                patterns: patterns.clone(),
                key,
                value,
                line: number,
            });
        }
    }
    let mut hosts = Vec::new();
    let mut work = 0usize;
    for alias in aliases {
        let mut values = BTreeMap::new();
        let mut host_warnings = Vec::new();
        for d in &directives {
            work += d
                .patterns
                .as_ref()
                .map(|p| p.iter().map(|p| p.len() + alias.len()).sum::<usize>())
                .unwrap_or(1);
            if work > 16 * 1024 * 1024 {
                return Err(ImportError::Limit);
            }
            if !applies(&d.patterns, &alias) {
                continue;
            }
            if !matches!(
                d.key.as_str(),
                "hostname"
                    | "user"
                    | "port"
                    | "connecttimeout"
                    | "serveraliveinterval"
                    | "serveralivecountmax"
                    | "identityfile"
                    | "proxyjump"
                    | "proxycommand"
            ) {
                warning(
                    &mut host_warnings,
                    format!("第{}行：未转换{}，导入不继承此选项", d.line, d.key),
                );
            } else {
                values.entry(d.key.as_str()).or_insert(d);
            }
        }
        let mut host = ImportHost {
            address: alias.clone(),
            alias,
            port: 22,
            username: default_username.into(),
            private_key: false,
            timeout_seconds: 30,
            keepalive_seconds: 30,
            keepalive_failures: 3,
            jump_alias: None,
            warnings: host_warnings,
            blocked: false,
        };
        for (key, d) in values {
            if d.value.len() != 1 && key != "proxycommand" {
                host.blocked = true;
                warning(
                    &mut host.warnings,
                    format!("第{}行：{}需要单个参数", d.line, key),
                );
                continue;
            }
            let v = &d.value[0];
            let invalid = match key {
                "hostname" => match expand_hostname(v, &host.alias) {
                    Some(v) => {
                        host.address = v;
                        false
                    }
                    None => true,
                },
                "user" => {
                    host.username = v.clone();
                    v.is_empty()
                        || v.len() > 1024
                        || v.chars().any(|c| c.is_control() || c.is_whitespace())
                        || v.contains(['%', '$'])
                }
                "port" => match v.parse::<u16>() {
                    Ok(n) if n > 0 => {
                        host.port = n;
                        false
                    }
                    _ => true,
                },
                "connecttimeout" => match v.parse::<u32>() {
                    Ok(n) if (1..=3600).contains(&n) => {
                        host.timeout_seconds = n;
                        false
                    }
                    _ => true,
                },
                "serveraliveinterval" => match v.parse::<u32>() {
                    Ok(n) if n <= 86400 => {
                        host.keepalive_seconds = n;
                        false
                    }
                    _ => true,
                },
                "serveralivecountmax" => match v.parse::<u32>() {
                    Ok(n) if (1..=100).contains(&n) => {
                        host.keepalive_failures = n;
                        false
                    }
                    _ => true,
                },
                "identityfile" => {
                    host.private_key = v != "none";
                    warning(&mut host.warnings, "IdentityFile仅提示私钥认证；没有读取、导入或保存其文件路径，请在主机认证页另行导入密钥".into());
                    false
                }
                "proxyjump" if v.eq_ignore_ascii_case("none") => false,
                "proxyjump" if literal(v) && !v.contains(['@', ':', '/', '[', ']']) => {
                    host.jump_alias = Some(v.clone());
                    false
                }
                "proxycommand" if d.value.len() == 1 && v.eq_ignore_ascii_case("none") => false,
                "proxycommand" | "proxyjump" => true,
                _ => true,
            };
            if invalid {
                host.blocked = true;
                warning(
                    &mut host.warnings,
                    format!(
                        "第{}行：{}无法安全转换；需修改源内容后重新预览",
                        d.line, key
                    ),
                );
            }
        }
        if host.username.is_empty()
            || host
                .username
                .chars()
                .any(|c| c.is_control() || c.is_whitespace())
            || host.username.contains(['%', '$'])
        {
            host.blocked = true;
            warning(
                &mut host.warnings,
                "缺少有效用户名；填写默认用户名或在源内容中指定User后重新预览".into(),
            );
        }
        hosts.push(host);
    }
    let lookup: BTreeMap<_, _> = hosts
        .iter()
        .map(|h| {
            (
                h.alias.to_ascii_lowercase(),
                (h.jump_alias.is_some(), h.blocked),
            )
        })
        .collect();
    for h in &mut hosts {
        if let Some(jump) = &h.jump_alias
            && (jump.eq_ignore_ascii_case(&h.alias)
                || lookup
                    .get(&jump.to_ascii_lowercase())
                    .is_none_or(|(nested, blocked)| *nested || *blocked))
        {
            h.blocked = true;
            warning(
                &mut h.warnings,
                "跳板必须是本次预览中独立、有效且无跳板的明确Host别名；不自动改为直连".into(),
            );
        }
    }
    Ok(ImportPreview { hosts, warnings })
}
impl ImportPreview {
    pub fn selected(
        &self,
        aliases: &[String],
        acknowledge_partial: bool,
    ) -> Result<Vec<ImportHost>, ImportError> {
        if aliases.is_empty() || aliases.len() > MAX_HOSTS {
            return Err(ImportError::Selection);
        }
        let mut seen = BTreeSet::new();
        let mut result = Vec::new();
        for alias in aliases {
            let key = alias.to_ascii_lowercase();
            if !seen.insert(key) {
                return Err(ImportError::Selection);
            }
            let h = self
                .hosts
                .iter()
                .find(|h| h.alias == *alias)
                .ok_or(ImportError::Selection)?;
            if h.blocked
                || (!acknowledge_partial && (!self.warnings.is_empty() || !h.warnings.is_empty()))
            {
                return Err(ImportError::Selection);
            }
            result.push(h.clone());
        }
        if result.iter().any(|h| {
            h.jump_alias
                .as_ref()
                .is_some_and(|j| !seen.contains(&j.to_ascii_lowercase()))
        }) {
            return Err(ImportError::Selection);
        }
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn first_values_wildcards_negation_aliases_quotes_and_comments() {
        let p=preview("\u{feff}Host Alpha Beta\r\n HostName=%h.example.invalid # note\r\n User \"fixture#name\"\r\n Port = 2201\r\nHost * !Beta\r\n ConnectTimeout 12\r\nHost *\r\n Port 9999\r\n ServerAliveInterval 0\r\n User default\r\n", "").unwrap();
        assert_eq!(p.hosts.len(), 2);
        assert_eq!(p.hosts[0].address, "Alpha.example.invalid");
        assert_eq!(p.hosts[1].port, 2201);
        assert_eq!(p.hosts[0].username, "fixture#name");
        assert_eq!(p.hosts[0].timeout_seconds, 12);
        assert_eq!(p.hosts[1].timeout_seconds, 30);
        assert_eq!(p.hosts[0].keepalive_seconds, 0);
        assert!(!p.hosts[0].blocked);
        let p = preview("User first\nHost a\n User second\nHost A\n Port 33", "").unwrap();
        assert_eq!(p.hosts.len(), 1);
        assert_eq!(p.hosts[0].username, "first");
        assert_eq!(p.hosts[0].port, 33);
    }
    #[test]
    fn never_runs_commands_reads_files_or_silently_drops_routes() {
        let p=preview("Include /cannot-read\nHost a\n ProxyCommand arbitrary payload\nHost b\n IdentityFile /cannot-read-secret\n RemoteCommand ignored\nMatch exec \"untrusted command\"\n HostName hidden.invalid\nHost c\n HostName visible.invalid", "fixture").unwrap();
        assert_eq!(p.warnings.len(), 2);
        assert!(p.hosts[0].blocked);
        assert!(p.hosts[1].private_key);
        assert_eq!(p.hosts[1].address, "b");
        assert!(p.selected(&["b".into()], false).is_err());
        assert!(p.selected(&["b".into()], true).is_ok());
        assert_eq!(p.hosts[2].address, "visible.invalid");
        assert!(!p.hosts[1].warnings.join("").contains("cannot-read-secret"));
        for source in [
            "Host a\n HostName ${ENV}",
            "Host a\n Port 0",
            "Host a\n User %r",
            "Host a\n ProxyJump a,b",
            "Host a\n HostName %j",
        ] {
            assert!(preview(source, "fixture").unwrap().hosts[0].blocked);
        }
    }
    #[test]
    fn one_hop_requires_selected_dependency_and_has_no_recursive_or_missing_fallback() {
        let p = preview(
            "Host target\n ProxyJump jump\nHost jump\n User fixture",
            "fixture",
        )
        .unwrap();
        assert!(!p.hosts[0].blocked);
        assert!(p.selected(&["target".into()], true).is_err());
        assert!(p.selected(&["target".into(), "jump".into()], true).is_ok());
        for text in [
            "Host a\n ProxyJump a",
            "Host a\n ProxyJump absent",
            "Host a\n ProxyJump b\nHost b\n ProxyJump c\nHost c",
        ] {
            assert!(preview(text, "fixture").unwrap().hosts[0].blocked);
        }
    }
    #[test]
    fn bounds_syntax_and_selection_do_not_return_source_values_in_errors() {
        assert!(preview(&"x".repeat(MAX_BYTES + 1), "fixture").is_err());
        assert!(preview("Host \"unterminated", "fixture").is_err());
        assert!(preview("Host a\n User", "fixture").is_err());
        let p = preview("Host a\n User fixture", "").unwrap();
        assert!(p.selected(&["a".into(), "a".into()], true).is_err());
        assert!(p.selected(&["unknown".into()], true).is_err());
        assert!(
            preview("Host * ? !other", "fixture")
                .unwrap()
                .hosts
                .is_empty()
        );
        assert!(glob("a*?z", "ABcz"));
        assert!(!glob("a*?z", "az"));
    }
}
