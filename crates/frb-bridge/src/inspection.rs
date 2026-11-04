//! Volatile per-session inspection consent. No Vault rows, cloud payloads,
//! command arguments or process metadata enter diagnostics.
use anyhow::{Result, ensure};
use hspterm_ssh_core::inspection::{Process, Processes};
use parking_lot::Mutex;
use serde::Serialize;
use std::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;
#[derive(Clone)]
pub(crate) struct Lease {
    pub generation: u64,
    serial: u64,
    pub cancel: CancellationToken,
}
struct Listed {
    token: String,
    value: Processes,
    until: Instant,
}
struct State {
    generation: u64,
    serial: u64,
    sequence: u64,
    metrics: bool,
    processes: bool,
    cancel: CancellationToken,
    list: Option<Listed>,
    closed: bool,
}
pub(crate) struct Registry(Mutex<State>);
impl Default for Registry {
    fn default() -> Self {
        Self(Mutex::new(State {
            generation: 0,
            serial: 0,
            sequence: 0,
            metrics: false,
            processes: false,
            cancel: CancellationToken::new(),
            list: None,
            closed: false,
        }))
    }
}
#[derive(Serialize)]
pub(crate) struct ListView<'a> {
    pub revision: &'a str,
    #[serde(flatten)]
    pub value: &'a Processes,
}
impl Registry {
    pub fn configure(&self, generation: u64, metrics: bool, processes: bool) -> Result<()> {
        let mut state = self.0.lock();
        ensure!(!state.closed, "终端已关闭；未启用远端检查");
        let serial = state
            .serial
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("远端检查能力已耗尽，请重启应用"))?;
        state.cancel.cancel();
        state.cancel = CancellationToken::new();
        state.serial = serial;
        state.generation = generation;
        state.metrics = metrics;
        state.processes = processes;
        state.list = None;
        Ok(())
    }
    pub fn lease(&self, generation: u64, processes: bool) -> Result<Lease> {
        let s = self.0.lock();
        ensure!(
            !s.closed
                && s.generation == generation
                && if processes { s.processes } else { s.metrics },
            "原终端未启用该项远端检查，请明确授权"
        );
        Ok(Lease {
            generation,
            serial: s.serial,
            cancel: s.cancel.clone(),
        })
    }
    pub fn current(&self, lease: &Lease) -> Result<()> {
        let s = self.0.lock();
        ensure!(
            !s.closed
                && s.generation == lease.generation
                && s.serial == lease.serial
                && !lease.cancel.is_cancelled(),
            "原远端检查授权已撤销或会话已改变"
        );
        Ok(())
    }
    pub fn publish(&self, lease: &Lease, value: Processes) -> Result<String> {
        let mut s = self.0.lock();
        ensure!(
            !s.closed
                && s.generation == lease.generation
                && s.serial == lease.serial
                && !lease.cancel.is_cancelled(),
            "原远端检查授权已撤销或会话已改变"
        );
        let next = s
            .sequence
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("进程列表修订已耗尽，请重启应用"))?;
        let token = format!("{}-{next}", s.serial);
        let json = serde_json::to_string(&ListView {
            revision: &token,
            value: &value,
        })?;
        s.sequence = next;
        s.list = Some(Listed {
            token,
            value,
            until: Instant::now() + Duration::from_secs(30),
        });
        Ok(json)
    }
    pub fn consume(&self, lease: &Lease, revision: &str, pid: u32) -> Result<(Process, String)> {
        let mut s = self.0.lock();
        ensure!(
            !s.closed
                && s.generation == lease.generation
                && s.serial == lease.serial
                && !lease.cancel.is_cancelled(),
            "原远端检查授权已撤销或会话已改变"
        );
        let list = s
            .list
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("原进程列表已失效，请明确刷新后重新确认"))?;
        ensure!(
            list.token == revision && Instant::now() < list.until && list.value.can_signal,
            "原进程列表过期或服务器不支持安全发送信号；请刷新"
        );
        let row = list
            .value
            .processes
            .iter()
            .find(|row| row.pid == pid && pid > 1 && row.start > 0)
            .ok_or_else(|| anyhow::anyhow!("进程不在原列表中或不可作为操作目标"))?
            .clone();
        let boot = list.value.boot.clone();
        // Consume before network, including unknown results. No blind replay.
        s.list = None;
        Ok((row, boot))
    }
    pub fn close(&self) {
        let mut s = self.0.lock();
        s.closed = true;
        s.cancel.cancel();
        s.list = None;
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn list() -> Processes {
        Processes {
            version: 1,
            boot: "01234567-89ab-cdef-0123-456789abcdef".into(),
            processes: vec![Process {
                pid: 123,
                start: 55,
                name: "synthetic".into(),
                state: "S".into(),
                ticks: 4,
                rss: 4000,
                uid: 1000,
            }],
            truncated: false,
            skipped: 0,
            can_signal: true,
        }
    }
    #[test]
    fn consent_is_separate_generation_bound_and_old_leases_stay_revoked() {
        let r = Registry::default();
        assert!(r.lease(7, false).is_err());
        r.configure(7, true, false).unwrap();
        let old = r.lease(7, false).unwrap();
        assert!(r.lease(7, true).is_err());
        assert!(r.lease(8, false).is_err());
        r.configure(7, true, true).unwrap();
        assert!(r.current(&old).is_err());
        assert!(old.cancel.is_cancelled());
        r.close();
        assert!(r.configure(8, true, true).is_err());
    }
    #[test]
    fn process_signal_uses_original_list_once_and_never_accepts_an_arbitrary_pid() {
        let r = Registry::default();
        r.configure(7, false, true).unwrap();
        let lease = r.lease(7, true).unwrap();
        let raw = r.publish(&lease, list()).unwrap();
        let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let ticket = v["revision"].as_str().unwrap();
        assert!(r.consume(&lease, ticket, 1).is_err());
        assert!(r.consume(&lease, ticket, 124).is_err());
        let (process, _) = r.consume(&lease, ticket, 123).unwrap();
        assert_eq!(process.start, 55);
        assert!(r.consume(&lease, ticket, 123).is_err());
        r.publish(&lease, list()).unwrap();
        assert!(r.consume(&lease, ticket, 123).is_err());
        r.0.lock().list.as_mut().unwrap().until = Instant::now();
        let expired = r.0.lock().list.as_ref().unwrap().token.clone();
        assert!(r.consume(&lease, &expired, 123).is_err());
    }
}
