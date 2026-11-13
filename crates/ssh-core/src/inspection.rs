//! Explicit, bounded inspection of the original SSH Transport. No PTY input,
//! automatic SSH connection or arbitrary remote exec API. The visible tmux
//! history rail polls bounded metadata on its explicitly attached Transport.
use crate::{Client, SshError};
use russh::{Channel, ChannelMsg, client};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, sync::Arc, time::Duration};
use tokio::sync::{Semaphore, oneshot};
use tokio_util::sync::CancellationToken;

const SCRIPT: &str = include_str!("inspection/probe.py");
const OUTPUT_LIMIT: usize = 256 * 1024;
const DEADLINE: Duration = Duration::from_secs(8);
#[derive(Debug, thiserror::Error)]
pub enum InspectionError {
    #[error("远端检查正在处理或等待旧通道结束；未开始新请求")]
    Busy,
    #[error("远端资源检查不可用或响应无效；需要 Linux procfs 与 Python 3")]
    Unavailable,
    #[error("远端检查已取消或超时；原 SSH 不会自动重连，结束进程结果可能未确认")]
    Unconfirmed,
    #[error("进程身份无效或原列表已过期；未开始发送信号")]
    Identity,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sample {
    pub version: u32,
    pub boot: String,
    pub millis: u64,
    pub cpu_total: u64,
    pub cpu_idle: u64,
    pub memory_total: u64,
    pub memory_available: u64,
    pub disk_total: u64,
    pub disk_available: u64,
    pub rx: u64,
    pub tx: u64,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Process {
    pub pid: u32,
    pub name: String,
    pub state: String,
    pub start: u64,
    pub ticks: u64,
    pub rss: u64,
    pub uid: u32,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Processes {
    pub version: u32,
    pub boot: String,
    pub processes: Vec<Process>,
    pub truncated: bool,
    pub skipped: u32,
    pub can_signal: bool,
}
fn valid_boot(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit() && !c.is_ascii_uppercase()
            }
        })
}
impl Sample {
    fn parse(raw: &[u8]) -> Result<Self, InspectionError> {
        let result: Self = serde_json::from_slice(raw).map_err(|_| InspectionError::Unavailable)?;
        if result.version != 1
            || !valid_boot(&result.boot)
            || result.cpu_idle > result.cpu_total
            || result.memory_total == 0
            || result.memory_available > result.memory_total
            || result.disk_total == 0
            || result.disk_available > result.disk_total
        {
            return Err(InspectionError::Unavailable);
        }
        Ok(result)
    }
}
impl Processes {
    fn parse(raw: &[u8]) -> Result<Self, InspectionError> {
        let result: Self = serde_json::from_slice(raw).map_err(|_| InspectionError::Unavailable)?;
        let mut ids = HashSet::new();
        if result.version != 1
            || !valid_boot(&result.boot)
            || result.processes.len() > 512
            || result.skipped > 4096
            || result.processes.iter().any(|p| {
                p.pid == 0
                    || !ids.insert(p.pid)
                    || p.name.len() > 256
                    || p.name.chars().any(|c| {
                        c.is_control()
                            || matches!(c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
                    })
                    || p.state.len() != 1
                    || !matches!(
                        p.state.as_str(),
                        "R" | "S" | "D" | "Z" | "T" | "t" | "X" | "x" | "K" | "W" | "P" | "I"
                    )
            })
        {
            return Err(InspectionError::Unavailable);
        }
        Ok(result)
    }
}
// Only this private typed enum can become a command; callers cannot supply a
// shell script, path, signal number, command name or unquoted remote text.
enum Action {
    Sample,
    Processes,
    ServerCopy(String),
    TmuxHistory(String),
    DirSize(String),
    Terminate { pid: u32, start: u64, boot: String },
}
fn command(action: &Action) -> Result<String, InspectionError> {
    if let Action::TmuxHistory(request) = action {
        if request.is_empty()
            || request.len() > 4096
            || !request.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(InspectionError::Identity);
        }
        return Ok(format!(
            "python3 -I -S -c '{}' {request}",
            include_str!("inspection/tmux_history.py").replace('\'', "'\\''")
        ));
    }

    if let Action::DirSize(path) = action {
        // Fixed script, plain argv: the path is never interpolated into a
        // shell string, and only an absolute POSIX path is accepted.
        if !path.starts_with('/')
            || path.len() > 16384
            || path.contains('\u{0000}')
            || path.bytes().any(|b| b < 0x20)
        {
            return Err(InspectionError::Identity);
        }
        // No `--` separator: with -c, python passes the remaining argv to the
        // script verbatim and a literal "--" would arrive as sys.argv[1],
        // breaking every invocation (2026-11-06: this exact bug silently
        // forced the slow SFTP fallback). The path is single-quoted as one
        // shell word and validated above.
        return Ok(format!(
            "python3 -I -S -c '{}' {}",
            include_str!("inspection/dir_size.py").replace('\'', "'\\''"),
            path.replace('\'', "'\\''"),
        ));
    }
    if let Action::ServerCopy(request) = action {
        if request.len() > 200_000 || !request.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(InspectionError::Identity);
        }
        return Ok(format!(
            "python3 -I -S -c '{}' {request}",
            include_str!("inspection/server_copy.py").replace('\'', "'\\''")
        ));
    }
    let args = match action {
        Action::Sample => "sample".into(),
        Action::Processes => "processes".into(),
        Action::Terminate { pid, start, boot } if *pid > 1 && *start > 0 && valid_boot(boot) => {
            format!("terminate {pid} {start} {boot}")
        }
        _ => return Err(InspectionError::Identity),
    };
    Ok(format!(
        "python3 -I -S -c '{}' {args}",
        SCRIPT.replace('\'', "'\\''")
    ))
}
/// Shared one-slot bound across every acquisition from the same Transport.
/// A timed-out channel-open stays owned until its late ACK or Root closes.
/// Totals from the fixed server-side size walk.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DirectorySize {
    pub size: u64,
    pub files: u64,
    pub directories: u64,
}

#[derive(Clone)]
pub struct Inspector {
    handle: Arc<client::Handle<Client>>,
    transport: CancellationToken,
    slot: Arc<Semaphore>,
    sample_waiter: Arc<Semaphore>,
    tmux: Arc<parking_lot::Mutex<Option<crate::tmux::Identity>>>,
    readonly: bool,
}
impl Inspector {
    pub(crate) fn new(
        handle: Arc<client::Handle<Client>>,
        transport: CancellationToken,
        tmux: Option<crate::tmux::Identity>,
        readonly: bool,
    ) -> Self {
        Self {
            handle,
            transport,
            slot: Arc::new(Semaphore::new(1)),
            sample_waiter: Arc::new(Semaphore::new(1)),
            tmux: Arc::new(parking_lot::Mutex::new(tmux)),
            readonly,
        }
    }
    pub(crate) fn clear_tmux(&self) {
        self.tmux.lock().take();
    }
    pub(crate) async fn wait_closed(&self) {
        // Called only AFTER original Root cancellation. Pending open workers
        // then retire; this does not wait for a peer that can no longer reply.
        if let Ok(permit) = self.slot.acquire().await {
            drop(permit);
        }
    }
    async fn execute(
        &self,
        action: Action,
        cancel: CancellationToken,
    ) -> Result<Vec<u8>, SshError> {
        let deadline = if matches!(action, Action::ServerCopy(_) | Action::DirSize(_)) {
            Duration::from_secs(120)
        } else {
            DEADLINE
        };
        let command = command(&action)?;
        if self.transport.is_cancelled() || self.handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        if cancel.is_cancelled() {
            return Err(InspectionError::Unconfirmed.into());
        }
        let permit = acquire_slot(
            &self.slot,
            &self.sample_waiter,
            matches!(action, Action::Sample),
            &cancel,
            &self.transport,
        )
        .await?;
        let local = cancel.child_token();
        let _lifetime = crate::transport::Lifetime(local.clone());
        let worker_cancel = local.clone();
        let root = self.transport.clone();
        let handle = self.handle.clone();
        let (send, receive) = oneshot::channel();
        tokio::spawn(async move {
            let _permit = permit;
            let result = async {
                let mut channel = tokio::select! {
                    biased;
                    _ = root.cancelled() => return Err(SshError::Disconnected),
                    result = handle.channel_open_session_flow_controlled() => result?,
                };
                // Never abandon a pending russh channel-open on local timeout.
                // Once owned, cancellation drops only this operation/channel.
                let mut peer_closed = false;
                let result = tokio::select! {
                    biased;
                    _ = root.cancelled() => Err(SshError::Disconnected),
                    _ = worker_cancel.cancelled() => Err(InspectionError::Unconfirmed.into()),
                    result = tokio::time::timeout(deadline, collect(&mut channel, &command, &mut peer_closed)) => result.unwrap_or_else(|_| Err(InspectionError::Unconfirmed.into())),
                };
                if !root.is_cancelled() {
                    // Sending CLOSE only queues it. Require peer retirement as
                    // well before admitting another exec on this original Root.
                    let closed = tokio::select! {
                        _ = root.cancelled() => false,
                        value = tokio::time::timeout(Duration::from_secs(2), close_channel(&mut channel, peer_closed)) => matches!(value, Ok(Ok(()))),
                    };
                    if !closed {
                        drop(channel.into_stream());
                        // A blocked close sender must not accumulate across
                        // manual retries. Keep the sole slot until Root retires.
                        root.cancelled().await;
                        return Err(InspectionError::Unconfirmed.into());
                    }
                }
                result
            }.await;
            // The reply certifies local channel retirement. Release admission
            // before waking a caller that can immediately submit another action.
            drop(_permit);
            drop(send.send(result));
        });
        tokio::select! {
            biased;
            _ = self.transport.cancelled() => Err(SshError::Disconnected),
            _ = local.cancelled() => Err(InspectionError::Unconfirmed.into()),
            result = tokio::time::timeout(deadline + Duration::from_secs(2), receive) => result.map_err(|_| InspectionError::Unconfirmed)?.map_err(|_| InspectionError::Unconfirmed)?,
        }
    }
    /// Only a fixed server-side file copier, never arbitrary shell commands.
    /// The bridge owns the SFTP namespace marker and validates these fields.
    /// Server-local directory size for the properties dialog: one fixed
    /// read-only python walk (same execution model as the server copy), a
    /// single round trip instead of per-directory SFTP listings.
    pub async fn directory_size(
        &self,
        path: &str,
        cancel: CancellationToken,
    ) -> Result<DirectorySize, SshError> {
        let raw = self
            .execute(Action::DirSize(path.to_owned()), cancel)
            .await?;
        let line = raw
            .split(|&b| b == b'\n')
            .rev()
            .find(|line| line.starts_with(b"{"))
            .ok_or(InspectionError::Unconfirmed)?;
        let value: serde_json::Value =
            serde_json::from_slice(line).map_err(|_| InspectionError::Unconfirmed)?;
        if value.get("error").is_some() {
            return Err(InspectionError::Unavailable.into());
        }
        let pick = |key: &str| {
            value
                .get(key)
                .and_then(serde_json::Value::as_u64)
                .ok_or(InspectionError::Unconfirmed)
        };
        Ok(DirectorySize {
            size: pick("size")?,
            files: pick("files")?,
            directories: pick("dirs")?,
        })
    }

    pub async fn copy_file(
        &self,
        request: serde_json::Value,
        cancel: CancellationToken,
    ) -> Result<(), SshError> {
        let nonce = request
            .get("nonce")
            .and_then(serde_json::Value::as_str)
            .filter(|value| {
                value.len() == 64
                    && value
                        .bytes()
                        .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
            })
            .ok_or(InspectionError::Identity)?;
        let acknowledgement = format!("\nHSPTERM_SERVER_COPY_V1_{nonce}\n");
        let payload = serde_json::to_vec(&request).map_err(|_| InspectionError::Identity)?;
        let hex: String = payload.iter().map(|b| format!("{b:02x}")).collect();
        let result = self.execute(Action::ServerCopy(hex), cancel).await?;
        if !result
            .windows(acknowledgement.len())
            .any(|part| part == acknowledgement.as_bytes())
        {
            return Err(InspectionError::Unconfirmed.into());
        }
        Ok(())
    }
    /// Uses the identity remembered at attach, never a caller-supplied session.
    pub async fn tmux_history(
        &self,
        pane: Option<String>,
        offset: Option<u32>,
        cancel: CancellationToken,
    ) -> Result<serde_json::Value, SshError> {
        let identity = self
            .tmux
            .lock()
            .clone()
            .ok_or(InspectionError::Unavailable)?;
        if offset.is_some()
            && (self.readonly
                || pane.as_ref().is_none_or(|p| {
                    p.len() < 2
                        || !p.starts_with('%')
                        || p.len() > 13
                        || !p[1..].bytes().all(|b| b.is_ascii_digit())
                }))
        {
            return Err(InspectionError::Identity.into());
        }
        let mut request = serde_json::to_value(identity).map_err(|_| InspectionError::Identity)?;
        request["pane"] = serde_json::json!(pane);
        request["offset"] = serde_json::json!(offset);
        request["readonly"] = serde_json::json!(self.readonly);
        let payload = serde_json::to_vec(&request).map_err(|_| InspectionError::Identity)?;
        let hex = payload.iter().map(|b| format!("{b:02x}")).collect();
        let output = self.execute(Action::TmuxHistory(hex), cancel).await?;
        let line = output
            .split(|b| *b == b'\n')
            .rev()
            .find(|l| !l.is_empty())
            .ok_or(InspectionError::Unavailable)?;
        serde_json::from_slice(line).map_err(|_| InspectionError::Unavailable.into())
    }
    pub async fn sample(&self, cancel: CancellationToken) -> Result<Sample, SshError> {
        Ok(Sample::parse(&self.execute(Action::Sample, cancel).await?)?)
    }
    pub async fn processes(&self, cancel: CancellationToken) -> Result<Processes, SshError> {
        Ok(Processes::parse(
            &self.execute(Action::Processes, cancel).await?,
        )?)
    }
    /// The application must bind this frozen identity to an unexpired list and
    /// receive explicit consent. SIGTERM ACK does NOT prove process exit.
    pub async fn terminate(
        &self,
        process: &Process,
        boot: &str,
        cancel: CancellationToken,
    ) -> Result<(), SshError> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Reply {
            version: u32,
            sent: bool,
        }
        let raw = self
            .execute(
                Action::Terminate {
                    pid: process.pid,
                    start: process.start,
                    boot: boot.into(),
                },
                cancel,
            )
            .await?;
        let reply: Reply =
            serde_json::from_slice(&raw).map_err(|_| InspectionError::Unconfirmed)?;
        if reply.version != 1 || !reply.sent {
            return Err(InspectionError::Unconfirmed.into());
        }
        Ok(())
    }
}
// Fair admission for a metrics request waiting on a short tmux history probe.
// One waiter, one active channel; history/CRUD continue to fail fast.
async fn acquire_slot(
    slot: &Arc<Semaphore>,
    waiter: &Arc<Semaphore>,
    sample: bool,
    cancel: &CancellationToken,
    root: &CancellationToken,
) -> Result<tokio::sync::OwnedSemaphorePermit, SshError> {
    if !sample {
        return slot
            .clone()
            .try_acquire_owned()
            .map_err(|_| InspectionError::Busy.into());
    }
    let _waiting = waiter
        .clone()
        .try_acquire_owned()
        .map_err(|_| InspectionError::Busy)?;
    tokio::select! {
        biased;
        _ = root.cancelled() => Err(SshError::Disconnected),
        _ = cancel.cancelled() => Err(InspectionError::Unconfirmed.into()),
        permit = tokio::time::timeout(Duration::from_secs(2), slot.clone().acquire_owned()) => {
            permit.map_err(|_| InspectionError::Busy)?.map_err(|_| InspectionError::Busy.into())
        }
    }
}

async fn close_channel(
    channel: &mut Channel<client::Msg>,
    mut peer_closed: bool,
) -> Result<(), ()> {
    channel.close().await.map_err(|_| ())?;
    let mut discarded = 0usize;
    let mut events = 0u32;
    while !peer_closed {
        events = events.wrapping_add(1);
        if events.is_multiple_of(64) {
            tokio::task::yield_now().await;
        }
        match channel.wait().await {
            Some(ChannelMsg::Close) | None => peer_closed = true,
            Some(ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. }) => {
                discarded = discarded.checked_add(data.len()).ok_or(())?;
                if discarded > OUTPUT_LIMIT {
                    return Err(());
                }
            }
            _ => {}
        }
    }
    Ok(())
}
async fn collect(
    channel: &mut Channel<client::Msg>,
    command: &str,
    peer_closed: &mut bool,
) -> Result<Vec<u8>, SshError> {
    channel.exec(true, command.as_bytes()).await?;
    channel.eof().await?;
    let mut output = Vec::new();
    let mut bytes = 0usize;
    let mut accepted = false;
    let mut status = None;
    let mut events = 0u32;
    loop {
        events = events.wrapping_add(1);
        if events.is_multiple_of(64) {
            tokio::task::yield_now().await;
        }
        match channel.wait().await {
            Some(ChannelMsg::Success) if !accepted => accepted = true,
            Some(ChannelMsg::Data { data }) => {
                bytes = bytes
                    .checked_add(data.len())
                    .ok_or(InspectionError::Unavailable)?;
                if bytes > OUTPUT_LIMIT {
                    return Err(InspectionError::Unavailable.into());
                }
                output.extend_from_slice(&data);
            }
            Some(ChannelMsg::ExtendedData { data, .. }) => {
                bytes = bytes
                    .checked_add(data.len())
                    .ok_or(InspectionError::Unavailable)?;
                if bytes > OUTPUT_LIMIT {
                    return Err(InspectionError::Unavailable.into());
                }
                // Never expose the remote shell's stderr or Python diagnostics.
            }
            Some(ChannelMsg::ExitStatus { exit_status }) if status.is_none() => {
                status = Some(exit_status)
            }
            Some(ChannelMsg::Eof | ChannelMsg::WindowAdjusted { .. }) => {}
            Some(ChannelMsg::Close) | None => {
                *peer_closed = true;
                if !accepted || status != Some(0) {
                    return Err(InspectionError::Unavailable.into());
                }
                return Ok(output);
            }
            _ => return Err(InspectionError::Unavailable.into()),
        }
    }
}

#[cfg(test)]
#[cfg(unix)]
mod dir_size_tests {
    // Runs the shipped script exactly as sshd would (`python3 -I -S -c ...`)
    // against a synthetic tree with a symlink and nested directories.
    #[test]
    fn script_matches_du_and_find_on_synthetic_tree() {
        let dir = std::env::temp_dir().join(format!("hspterm-du-{}", std::process::id(),));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("a/b")).unwrap();
        std::fs::write(dir.join("f1.txt"), b"12345").unwrap();
        std::fs::write(dir.join("a/f2.txt"), b"1234567890").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(dir.join("f1.txt"), dir.join("link")).unwrap();
        // Direct argv here (no shell quoting, unlike the production command).
        let script = include_str!("inspection/dir_size.py");
        let output = std::process::Command::new("python3")
            .arg("-I")
            .arg("-S")
            .arg("-c")
            .arg(script)
            .arg(&dir)
            .output()
            .expect("python3 required for this test");
        assert!(
            output.status.success(),
            "python failed: {}",
            String::from_utf8_lossy(&output.stderr),
        );
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = stdout.lines().last().unwrap();
        let value: serde_json::Value = serde_json::from_str(line).unwrap();
        assert_eq!(value["size"], 15, "symlink must not count");
        assert_eq!(value["files"], 2);
        assert_eq!(value["dirs"], 3, "root + a + b");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn metrics_wait_fairly_without_extra_channels_or_unbounded_waiters() {
        let slot = Arc::new(Semaphore::new(1));
        let waiter = Arc::new(Semaphore::new(1));
        let cancel = CancellationToken::new();
        let root = CancellationToken::new();
        let old = slot.clone().try_acquire_owned().unwrap();
        let pending = acquire_slot(&slot, &waiter, true, &cancel, &root);
        tokio::pin!(pending);
        tokio::select! {
            biased;
            _ = &mut pending => panic!("sample admitted before old channel retired"),
            _ = std::future::ready(()) => {}
        }
        assert!(matches!(
            acquire_slot(&slot, &waiter, true, &cancel, &root).await,
            Err(SshError::Inspection(InspectionError::Busy))
        ));
        drop(old);
        // The queued metrics request owns next admission, even if history polls.
        assert!(matches!(
            acquire_slot(&slot, &waiter, false, &cancel, &root).await,
            Err(SshError::Inspection(InspectionError::Busy))
        ));
        let metrics = pending.await.unwrap();
        assert_eq!(slot.available_permits(), 0);
        drop(metrics);
        assert_eq!(slot.available_permits(), 1);
        cancel.cancel();
        assert!(matches!(
            acquire_slot(&slot, &waiter, true, &cancel, &root).await,
            Err(SshError::Inspection(InspectionError::Unconfirmed))
        ));
        assert_eq!(slot.available_permits(), 1);
    }
    const BOOT: &str = "01234567-89ab-cdef-0123-456789abcdef";
    #[test]
    fn terminate_arguments_are_typed_and_reject_shell_fragments_or_pid_one() {
        for (pid, start, boot) in [(1, 1, BOOT), (2, 0, BOOT), (2, 1, "x; touch /tmp/unsafe")] {
            assert!(
                command(&Action::Terminate {
                    pid,
                    start,
                    boot: boot.into()
                })
                .is_err()
            );
        }
        let cmd = command(&Action::Terminate {
            pid: 123,
            start: 456,
            boot: BOOT.into(),
        })
        .unwrap();
        assert!(cmd.ends_with(&format!("terminate 123 456 {BOOT}")));
        assert!(cmd.starts_with("python3 -I -S -c '"));
    }
    #[test]
    fn malformed_metadata_and_duplicate_processes_are_not_partially_published() {
        let row = Process {
            pid: 123,
            start: 45,
            name: "synthetic".into(),
            state: "S".into(),
            ticks: 4,
            rss: 4096,
            uid: 1000,
        };
        let mut list = Processes {
            version: 1,
            boot: BOOT.into(),
            processes: vec![row.clone()],
            truncated: true,
            skipped: 3,
            can_signal: false,
        };
        assert!(
            Processes::parse(&serde_json::to_vec(&list).unwrap())
                .unwrap()
                .truncated
        );
        list.processes.push(row);
        assert!(Processes::parse(&serde_json::to_vec(&list).unwrap()).is_err());
        list.processes.pop();
        list.processes[0].name = "bad\u{202e}name".into();
        assert!(Processes::parse(&serde_json::to_vec(&list).unwrap()).is_err());
    }
    #[test]
    fn impossible_sample_values_and_unknown_fields_fail_closed() {
        let mut s = Sample {
            version: 1,
            boot: BOOT.into(),
            millis: 100,
            cpu_total: 40,
            cpu_idle: 10,
            memory_total: 100,
            memory_available: 50,
            disk_total: 1000,
            disk_available: 10,
            rx: 12,
            tx: 40,
        };
        assert!(Sample::parse(&serde_json::to_vec(&s).unwrap()).is_ok());
        s.memory_available = 101;
        assert!(Sample::parse(&serde_json::to_vec(&s).unwrap()).is_err());
        assert!(Sample::parse(br#"{"version":1,"unexpected":"private"}"#).is_err());
    }
}
