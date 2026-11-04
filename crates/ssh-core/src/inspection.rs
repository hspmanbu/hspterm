//! Explicit, bounded inspection of the original SSH Transport. No PTY input,
//! automatic SSH connection, background probing or arbitrary remote exec API.
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
    Terminate { pid: u32, start: u64, boot: String },
}
fn command(action: &Action) -> Result<String, InspectionError> {
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
#[derive(Clone)]
pub struct Inspector {
    handle: Arc<client::Handle<Client>>,
    transport: CancellationToken,
    slot: Arc<Semaphore>,
}
impl Inspector {
    pub(crate) fn new(handle: Arc<client::Handle<Client>>, transport: CancellationToken) -> Self {
        Self {
            handle,
            transport,
            slot: Arc::new(Semaphore::new(1)),
        }
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
        let command = command(&action)?;
        if self.transport.is_cancelled() || self.handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        if cancel.is_cancelled() {
            return Err(InspectionError::Unconfirmed.into());
        }
        let permit = self
            .slot
            .clone()
            .try_acquire_owned()
            .map_err(|_| InspectionError::Busy)?;
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
                    result = tokio::time::timeout(DEADLINE, collect(&mut channel, &command, &mut peer_closed)) => result.unwrap_or_else(|_| Err(InspectionError::Unconfirmed.into())),
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
            result = tokio::time::timeout(DEADLINE + Duration::from_secs(2), receive) => result.map_err(|_| InspectionError::Unconfirmed)?.map_err(|_| InspectionError::Unconfirmed)?,
        }
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
mod tests {
    use super::*;
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
