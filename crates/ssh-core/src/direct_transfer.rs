//! Direct rsync over a task-scoped application authentication capability: probes
//! and fixed writes to a one-use private staging capability from original SFTP.
//! No grant, arbitrary exec, final-path write, source deletion or new app Root.
//! The owner binds the destination to its actual authenticated SSH receipt.
use crate::{AgentPhase, AgentStatus, HostKey};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD},
};
use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

pub(crate) mod auth;
mod connector;
pub use connector::DirectConnector;

const PROBE_SCRIPT: &str = include_str!("direct_transfer/probe.py");
fn script() -> String {
    format!(
        "{}\n{}",
        include_str!("direct_transfer/auth.py"),
        PROBE_SCRIPT
    )
}
#[derive(Debug, thiserror::Error)]
pub enum DirectPreparationError {
    #[error("原SSH直传探测正在处理或等待旧通道结束，未开始新请求")]
    Busy,
    #[error("安全直传操作已取消或结果及收尾未确认；原SSH不会自动重连")]
    Unconfirmed,
    #[error("直传端点或已验证主机指纹无效；未开始直传")]
    InvalidTarget,
    #[error("直传认证通道不可用或已失效；请检查应用内Agent socket与目标凭据")]
    AgentUnavailable,
    #[error("安全直传响应无效；不能据此确认写入")]
    InvalidReply,
}
#[derive(Serialize)]
struct Endpoint<'a> {
    version: u32,
    address: &'a str,
    port: u16,
    username: &'a str,
    fingerprint: &'a str,
    algorithm: &'a str,
}
/// Not a copy capability. A successful probe authorizes no source deletion or
/// target overwrite, and does not establish a lasting host/authentication fact.
pub struct DirectProbe {
    command: String,
    agent_epoch: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProbeStatus {
    Available,
    MissingTools,
    AgentUnavailable,
    AuthenticationFailed,
    Timeout,
    Unsupported,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Reply {
    version: u32,
    status: ProbeStatus,
}
fn valid_target(key: &HostKey, username: &str) -> bool {
    let address = &key.address;
    let host = if address.parse::<std::net::IpAddr>().is_ok() {
        true
    } else {
        !address.starts_with('-')
            && address
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'-' | b'_'))
    };
    let digest = key
        .sha256
        .strip_prefix("SHA256:")
        .and_then(|s| STANDARD_NO_PAD.decode(s).ok());
    !address.is_empty()
        && address.len() <= 253
        && host
        && key.port != 0
        && !username.is_empty()
        && username.len() <= 1024
        && !username.chars().any(char::is_control)
        && matches!(
            key.algorithm.as_str(),
            "ssh-ed25519"
                | "ssh-rsa"
                | "ecdsa-sha2-nistp256"
                | "ecdsa-sha2-nistp384"
                | "ecdsa-sha2-nistp521"
        )
        && digest.is_some_and(|s| s.len() == 32)
}
impl DirectProbe {
    pub fn prepare(
        target: &HostKey,
        username: &str,
        source_agent: &AgentStatus,
        expected_agent_epoch: u64,
    ) -> Result<Self, DirectPreparationError> {
        if !valid_target(target, username) {
            return Err(DirectPreparationError::InvalidTarget);
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| DirectPreparationError::AgentUnavailable)?
            .as_millis();
        if source_agent.phase != AgentPhase::Active
            || source_agent.key_count == 0
            || expected_agent_epoch == 0
            || source_agent.epoch != expected_agent_epoch
            || source_agent
                .expires_unix_millis
                .is_none_or(|end| u128::from(end) <= now + 15_000)
        {
            return Err(DirectPreparationError::AgentUnavailable);
        }
        let endpoint = Endpoint {
            version: 1,
            address: &target.address,
            port: target.port,
            username,
            fingerprint: &target.sha256,
            algorithm: &target.algorithm,
        };
        let payload = STANDARD.encode(
            serde_json::to_vec(&endpoint).map_err(|_| DirectPreparationError::InvalidTarget)?,
        );
        // The outer login shell sees only fixed code plus a base64 public
        // metadata argument. Endpoint text never becomes shell syntax.
        let command = format!(
            "/usr/bin/python3 -I -S -c '{}' '{}'",
            script().replace('\'', "'\\''"),
            payload
        );
        Ok(Self {
            command,
            agent_epoch: expected_agent_epoch,
        })
    }
    pub fn command(&self) -> &str {
        &self.command
    }
    pub fn agent_epoch(&self) -> u64 {
        self.agent_epoch
    }
    pub fn parse_reply(raw: &[u8]) -> Result<ProbeStatus, DirectPreparationError> {
        if raw.len() > 1024 {
            return Err(DirectPreparationError::InvalidReply);
        }
        let reply: Reply =
            serde_json::from_slice(raw).map_err(|_| DirectPreparationError::InvalidReply)?;
        if reply.version != 1 {
            return Err(DirectPreparationError::InvalidReply);
        }
        Ok(reply.status)
    }
}
/// Captured original source connector, pinned destination and consent epoch.
/// Owners recheck both task endpoint generations before/after each batch.
#[derive(Clone)]
pub struct DirectRoute {
    connector: DirectConnector,
    target: HostKey,
    username: String,
    epoch: u64,
    pub(crate) relay_permitted: bool,
    operations: std::sync::Arc<Operations>,
    relayed: std::sync::Arc<std::sync::atomic::AtomicBool>,
}
#[derive(Default)]
struct Operations(parking_lot::Mutex<Vec<std::sync::Arc<Operation>>>);
struct Operation {
    done: std::sync::atomic::AtomicBool,
    changed: tokio::sync::Notify,
}
struct Finished(std::sync::Arc<Operation>);
impl Drop for Finished {
    fn drop(&mut self) {
        self.0
            .done
            .store(true, std::sync::atomic::Ordering::Release);
        self.0.changed.notify_waiters();
    }
}
impl Operations {
    fn begin(&self) -> Finished {
        let operation = std::sync::Arc::new(Operation {
            done: std::sync::atomic::AtomicBool::new(false),
            changed: tokio::sync::Notify::new(),
        });
        let mut active = self.0.lock();
        active.retain(|op| !op.done.load(std::sync::atomic::Ordering::Acquire));
        active.push(operation.clone());
        Finished(operation)
    }
    fn idle(&self) -> bool {
        let mut active = self.0.lock();
        active.retain(|op| !op.done.load(std::sync::atomic::Ordering::Acquire));
        active.is_empty()
    }
    async fn wait(&self) {
        let active = self.0.lock().clone();
        for op in active {
            loop {
                let changed = op.changed.notified();
                if op.done.load(std::sync::atomic::Ordering::Acquire) {
                    break;
                }
                changed.await;
            }
        }
    }
}
impl DirectRoute {
    pub fn new(
        connector: DirectConnector,
        target: HostKey,
        username: String,
        epoch: u64,
        relay_permitted: bool,
    ) -> Result<Self, DirectPreparationError> {
        if !valid_target(&target, &username) || epoch == 0 {
            return Err(DirectPreparationError::InvalidTarget);
        }
        Ok(Self {
            connector,
            target,
            username,
            epoch,
            relay_permitted,
            operations: Default::default(),
            relayed: Default::default(),
        })
    }
    pub fn used_relay(&self) -> bool {
        self.relayed.load(std::sync::atomic::Ordering::Acquire)
    }
    pub(crate) fn mark_relay(&self) {
        self.relayed
            .store(true, std::sync::atomic::Ordering::Release);
    }
    pub(crate) fn can_stage(&self, source: &str, staged: &str) -> bool {
        let grant = self.connector.agent_status();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()
            .map(|d| d.as_millis());
        valid_write_paths(source, staged)
            && grant.phase == AgentPhase::Active
            && grant.epoch == self.epoch
            && now.is_some_and(|now| {
                grant
                    .expires_unix_millis
                    .is_some_and(|end| u128::from(end) > now + 15_000)
            })
    }
    pub fn is_idle(&self) -> bool {
        self.operations.idle()
    }
    pub async fn wait_idle(&self) {
        self.operations.wait().await;
    }
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn stage(
        &self,
        source: &str,
        staged: &str,
        bytes: u64,
        nonce: &[u8; 32],
        attempt: u64,
        target_sftp: &crate::SftpSession,
        stop: &tokio_util::sync::CancellationToken,
    ) -> Result<(), crate::SshError> {
        use crate::SftpOpenFlags;
        use tokio::io::AsyncWriteExt;
        if stop.is_cancelled() {
            return Err(DirectPreparationError::Unconfirmed.into());
        }
        let mut file = target_sftp
            .open_with_flags_and_attributes(
                staged,
                SftpOpenFlags::WRITE | SftpOpenFlags::CREATE | SftpOpenFlags::EXCLUDE,
                russh_sftp::protocol::FileAttributes {
                    permissions: Some(0o600),
                    ..Default::default()
                },
            )
            .await?;
        let marker = async {
            let attrs = file.metadata().await?;
            if !attrs.is_regular()
                || attrs.size != Some(0)
                || attrs.permissions.is_none_or(|p| p & 0o777 != 0o600)
            {
                return Err(DirectPreparationError::Unconfirmed.into());
            }
            file.write_all(nonce).await?;
            file.flush().await?;
            Ok::<_, crate::SshError>(())
        }
        .await;
        let closed = file.shutdown().await;
        if closed.is_err() {
            return Err(DirectPreparationError::Unconfirmed.into());
        }
        marker?;
        if stop.is_cancelled() {
            return Err(DirectPreparationError::Unconfirmed.into());
        }
        self.connector
            .stage_attempt_owned(
                &self.target,
                &self.username,
                self.epoch,
                source,
                staged,
                bytes,
                nonce,
                attempt,
                None,
                stop.clone(),
                Some(self.operations.clone()),
            )
            .await
    }
    pub(crate) async fn inspect(
        &self,
        staged: &str,
        bytes: u64,
        nonce: &[u8; 32],
        stop: &tokio_util::sync::CancellationToken,
    ) -> Result<ReceiptReply, crate::SshError> {
        self.connector
            .inspect_owned(
                &self.target,
                &self.username,
                self.epoch,
                staged,
                bytes,
                nonce,
                stop.clone(),
                Some(self.operations.clone()),
            )
            .await
    }
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn resume(
        &self,
        source: &str,
        staged: &str,
        bytes: u64,
        nonce: &[u8; 32],
        attempt: u64,
        previous: Option<u64>,
        stop: &tokio_util::sync::CancellationToken,
    ) -> Result<(), crate::SshError> {
        self.connector
            .stage_attempt_owned(
                &self.target,
                &self.username,
                self.epoch,
                source,
                staged,
                bytes,
                nonce,
                attempt,
                previous,
                stop.clone(),
                Some(self.operations.clone()),
            )
            .await
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReceiptStatus {
    Unavailable,
    Busy,
    Unclaimed,
    Partial,
    Complete,
}
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReceiptReply {
    version: u32,
    pub status: ReceiptStatus,
    pub attempt: Option<u64>,
    pub bytes: u64,
}
struct DirectQuery {
    command: String,
    agent_epoch: u64,
}
impl DirectQuery {
    fn prepare(
        target: &HostKey,
        username: &str,
        agent: &AgentStatus,
        epoch: u64,
        staged: &str,
        bytes: u64,
        nonce: &[u8],
    ) -> Result<Self, DirectPreparationError> {
        DirectProbe::prepare(target, username, agent, epoch)?;
        if nonce.len() != 32 || !valid_write_paths(staged, staged) {
            return Err(DirectPreparationError::InvalidTarget);
        }
        let endpoint = Endpoint {
            version: 1,
            address: &target.address,
            port: target.port,
            username,
            fingerprint: &target.sha256,
            algorithm: &target.algorithm,
        };
        let inspect = format!(
            "{}\n{}",
            include_str!("direct_transfer/receipt.py"),
            include_str!("direct_transfer/inspect.py")
        );
        let payload = STANDARD.encode(serde_json::to_vec(&serde_json::json!({"endpoint": endpoint, "staged": staged, "bytes": bytes, "nonce": STANDARD.encode(nonce), "inspect": inspect})).map_err(|_| DirectPreparationError::InvalidTarget)?);
        let base = script();
        let common = base
            .split_once("\nif __name__ == '__main__':")
            .ok_or(DirectPreparationError::InvalidReply)?
            .0;
        let script = format!(
            "{}\n{}",
            common,
            include_str!("direct_transfer/query_sender.py")
        );
        Ok(Self {
            command: format!(
                "/usr/bin/python3 -I -S -c '{}' '{}'",
                script.replace('\'', "'\\''"),
                payload
            ),
            agent_epoch: epoch,
        })
    }
    fn parse(raw: &[u8], bytes: u64) -> Result<ReceiptReply, DirectPreparationError> {
        if raw.len() > 4096 {
            return Err(DirectPreparationError::InvalidReply);
        }
        let reply: ReceiptReply =
            serde_json::from_slice(raw).map_err(|_| DirectPreparationError::InvalidReply)?;
        if reply.version != 1
            || reply.bytes > bytes
            || reply.attempt == Some(0)
            || (reply.status == ReceiptStatus::Complete
                && (reply.bytes != bytes || reply.attempt.is_none()))
            || (reply.status == ReceiptStatus::Partial && reply.attempt.is_none())
            || (reply.status == ReceiptStatus::Unclaimed
                && (reply.attempt.is_some() || reply.bytes != 0))
        {
            return Err(DirectPreparationError::InvalidReply);
        }
        Ok(reply)
    }
}

/// One fixed rsync transfer to an application's exact private staging name.
/// The task persists Intent first. Any absent success remains uncertain; there
/// is no automatic retry, final-path write, source delete or relay fallback.
pub struct DirectWrite {
    command: String,
    agent_epoch: u64,
}
fn valid_write_paths(source: &str, staged: &str) -> bool {
    let name = staged.rsplit('/').next().unwrap_or("");
    let body = name
        .strip_prefix(".hspterm-copy-")
        .and_then(|s| s.strip_suffix(".part"));
    body.and_then(|s| s.rsplit_once('-'))
        .is_some_and(|(id, index)| {
            id.len() == 32
                && id
                    .bytes()
                    .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
                && !index.is_empty()
                && index.len() <= 7
                && index.bytes().all(|c| c.is_ascii_digit())
        })
        && [source, staged].iter().all(|s| {
            s.starts_with('/')
                && s.len() <= 16384
                && !s.contains('\0')
                && s.split('/')
                    .skip(1)
                    .all(|c| !c.is_empty() && c != "." && c != "..")
        })
}
impl DirectWrite {
    #[cfg(test)]
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn prepare(
        target: &HostKey,
        username: &str,
        agent: &AgentStatus,
        epoch: u64,
        source: &str,
        staged: &str,
        bytes: u64,
        nonce: &[u8],
    ) -> Result<Self, DirectPreparationError> {
        Self::prepare_attempt(
            target, username, agent, epoch, source, staged, bytes, nonce, 1, None,
        )
    }
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn prepare_attempt(
        target: &HostKey,
        username: &str,
        agent: &AgentStatus,
        epoch: u64,
        source: &str,
        staged: &str,
        bytes: u64,
        nonce: &[u8],
        attempt: u64,
        previous: Option<u64>,
    ) -> Result<Self, DirectPreparationError> {
        let _qualified = DirectProbe::prepare(target, username, agent, epoch)?;
        if nonce.len() != 32
            || !valid_write_paths(source, staged)
            || attempt == 0
            || previous.is_some_and(|v| v == 0 || v >= attempt)
        {
            return Err(DirectPreparationError::InvalidTarget);
        }
        let endpoint = Endpoint {
            version: 1,
            address: &target.address,
            port: target.port,
            username,
            fingerprint: &target.sha256,
            algorithm: &target.algorithm,
        };
        let payload = STANDARD.encode(
            serde_json::to_vec(&serde_json::json!({
                "endpoint": endpoint, "source": source, "staged": staged, "bytes": bytes, "nonce": STANDARD.encode(nonce),
                "receiver": format!("{}\n{}", include_str!("direct_transfer/receipt.py"), include_str!("direct_transfer/receiver.py")),
                "attempt": attempt, "previous": previous
            }))
            .map_err(|_| DirectPreparationError::InvalidTarget)?,
        );
        let base = script();
        let common = base
            .split_once("\nif __name__ == '__main__':")
            .ok_or(DirectPreparationError::InvalidReply)?
            .0;
        let script = format!("{}\n{}", common, include_str!("direct_transfer/sender.py"));
        let command = format!(
            "/usr/bin/python3 -I -S -c '{}' '{}'",
            script.replace('\'', "'\\''"),
            payload
        );
        Ok(Self {
            command,
            agent_epoch: epoch,
        })
    }
    fn parse_reply(raw: &[u8]) -> Result<(), DirectPreparationError> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Written {
            version: u32,
            status: String,
        }
        if raw.len() > 1024 {
            return Err(DirectPreparationError::Unconfirmed);
        }
        let reply: Written =
            serde_json::from_slice(raw).map_err(|_| DirectPreparationError::Unconfirmed)?;
        if reply.version != 1 || reply.status != "copied" {
            return Err(DirectPreparationError::Unconfirmed);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn receipt_decoder_never_turns_a_partial_length_or_missing_attempt_into_completion() {
        assert_eq!(
            DirectQuery::parse(
                br#"{"version":1,"status":"partial","attempt":2,"bytes":10}"#,
                10
            )
            .unwrap()
            .status,
            ReceiptStatus::Partial
        );
        assert_eq!(
            DirectQuery::parse(
                br#"{"version":1,"status":"complete","attempt":1,"bytes":10}"#,
                10
            )
            .unwrap()
            .status,
            ReceiptStatus::Complete
        );
        for raw in [
            br#"{"version":1,"status":"complete","attempt":null,"bytes":10}"#.as_slice(),
            br#"{"version":1,"status":"complete","attempt":1,"bytes":9}"#,
            br#"{"version":1,"status":"partial","attempt":0,"bytes":10}"#,
            br#"{"version":1,"status":"unclaimed","attempt":1,"bytes":0}"#,
            br#"{"version":1,"status":"busy","attempt":null,"bytes":11}"#,
        ] {
            assert!(DirectQuery::parse(raw, 10).is_err());
        }
    }
    fn fixture() -> (HostKey, AgentStatus) {
        let key = HostKey {
            address: "127.0.0.1".into(),
            port: 2222,
            algorithm: "ssh-ed25519".into(),
            sha256: format!("SHA256:{}", STANDARD_NO_PAD.encode([0u8; 32])),
        };
        let status = AgentStatus {
            epoch: 3,
            phase: AgentPhase::Active,
            key_count: 1,
            expires_unix_millis: Some(
                (SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_millis()
                    + 60_000) as u64,
            ),
            failed_streams: 0,
        };
        (key, status)
    }
    #[test]
    fn write_compiler_only_accepts_exact_private_staging_paths_and_confirmed_replies() {
        let (key, grant) = fixture();
        let staged = "/target/.hspterm-copy-0123456789abcdef0123456789abcdef-12.part";
        let nonce = [7; 32];
        let write = DirectWrite::prepare(
            &key,
            "synthetic",
            &grant,
            3,
            "/source/a '$ 中文",
            staged,
            5,
            &nonce,
        )
        .unwrap();
        assert!(!write.command.contains("/source/a '$ 中文"));
        assert!(!write.command.contains(staged));
        for path in [
            "/target/user.txt",
            "/target/.hspterm-copy-short-0.part",
            "/target/../.hspterm-copy-0123456789abcdef0123456789abcdef-0.part",
        ] {
            assert!(
                DirectWrite::prepare(
                    &key,
                    "synthetic",
                    &grant,
                    3,
                    "/source/file",
                    path,
                    5,
                    &nonce
                )
                .is_err()
            );
        }
        assert!(DirectWrite::parse_reply(br#"{"version":1,"status":"copied"}"#).is_ok());
        assert!(DirectWrite::parse_reply(br#"{"version":1,"status":"unconfirmed"}"#).is_err());
        assert!(DirectWrite::parse_reply(br#"{"version":1,"status":"copied","bytes":5}"#).is_err());
    }
    #[tokio::test]
    async fn direct_io_retirement_is_per_task_and_waits_for_actual_worker_end() {
        use tokio::time::{Duration, timeout};
        let first = Operations::default();
        let other = Operations::default();
        let finished = first.begin();
        let other_finished = other.begin();
        let mut wait = Box::pin(first.wait());
        assert!(timeout(Duration::from_millis(20), &mut wait).await.is_err());
        assert!(!first.idle());
        drop(finished);
        timeout(Duration::from_secs(1), wait).await.unwrap();
        assert!(first.idle());
        assert!(!other.idle());
        drop(other_finished);
    }
    #[test]
    fn probe_requires_the_original_live_explicit_agent_grant() {
        let (key, mut grant) = fixture();
        assert!(DirectProbe::prepare(&key, "synthetic", &grant, 3).is_ok());
        assert!(DirectProbe::prepare(&key, "synthetic", &grant, 4).is_err());
        grant.phase = AgentPhase::Ready;
        assert!(DirectProbe::prepare(&key, "synthetic", &grant, 3).is_err());
        grant.phase = AgentPhase::Active;
        grant.expires_unix_millis = Some(0);
        assert!(DirectProbe::prepare(&key, "synthetic", &grant, 3).is_err());
    }
    #[test]
    fn probe_endpoint_text_is_encoded_and_cannot_add_outer_shell_commands() {
        let (mut key, grant) = fixture();
        let user = "synthetic' $(unsafe) ; user";
        let probe = DirectProbe::prepare(&key, user, &grant, 3).unwrap();
        assert!(!probe.command().contains(user));
        assert_eq!(probe.agent_epoch(), 3);
        for address in [
            "-oProxyCommand=unsafe",
            "server;unsafe",
            "user@server",
            "server%unsafe",
            "server/path",
        ] {
            key.address = address.into();
            assert!(DirectProbe::prepare(&key, "synthetic", &grant, 3).is_err());
        }
        key.address = "::1".into();
        assert!(DirectProbe::prepare(&key, "synthetic", &grant, 3).is_ok());
    }
    #[test]
    fn probe_only_accepts_bounded_typed_replies_not_remote_error_text() {
        assert_eq!(
            DirectProbe::parse_reply(br#"{"version":1,"status":"available"}"#).unwrap(),
            ProbeStatus::Available
        );
        for raw in [
            br#"{"version":2,"status":"available"}"#.as_slice(),
            br#"{"version":1,"status":"available","secret":"untrusted stderr"}"#,
            br#"{"version":1,"status":"invented"}"#,
        ] {
            assert!(DirectProbe::parse_reply(raw).is_err());
        }
        assert!(DirectProbe::parse_reply(&vec![b' '; 1025]).is_err());
    }
}
