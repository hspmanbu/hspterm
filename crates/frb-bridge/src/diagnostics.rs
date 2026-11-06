//! Process-only diagnostics. Intentionally no API accepts free-form messages,
//! errors, paths, targets, commands, terminal bytes or credential material.
use parking_lot::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::{collections::VecDeque, sync::OnceLock, time::Instant};
static PANICS_NOT_QUEUED: AtomicU64 = AtomicU64::new(0);
const CAPACITY: usize = 1000;
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
pub enum DiagnosticCode {
    TerminalCreated,
    TerminalCloseRequested,
    ConnectionRequested,
    ConnectionSucceeded,
    ConnectionRejected,
    ConnectionInterrupted,
    StateIdle,
    StateConnecting,
    StateConnected,
    StateDisconnected,
    StateFailed,
    StateClosed,
    ConnectionCancelRequested,
    DisconnectRequested,
    HostKeyAccepted,
    HostKeyRejected,
    VaultOpened,
    ConfigurationRestored,
    TerminalPreferencesSaved,
    UploadQueued,
    DownloadQueued,
    TransferRequestRejected,
    CoreWorkerPanicked,
    DirectorySizeRemote,
    DirectorySizeFallback,
}
#[derive(Clone, serde::Serialize)]
pub struct DiagnosticEvent {
    pub sequence: u64,
    pub elapsed_ms: u64,
    pub terminal_id: Option<u32>,
    pub generation: Option<u64>,
    pub code: DiagnosticCode,
}
#[derive(Clone, serde::Serialize)]
pub struct DiagnosticSnapshot {
    pub capacity: u32,
    pub dropped: u64,
    pub events: Vec<DiagnosticEvent>,
}
struct Store {
    started: Instant,
    next: u64,
    dropped: u64,
    events: VecDeque<DiagnosticEvent>,
}
impl Store {
    fn new() -> Self {
        Self {
            started: Instant::now(),
            next: 0,
            dropped: 0,
            events: VecDeque::with_capacity(CAPACITY),
        }
    }
    fn push(&mut self, code: DiagnosticCode, terminal_id: Option<u32>, generation: Option<u64>) {
        if self.next == u64::MAX {
            self.dropped = self.dropped.saturating_add(self.events.len() as u64);
            self.events.clear();
            self.next = 0;
        }
        self.next += 1;
        if self.events.len() == CAPACITY {
            self.events.pop_front();
            self.dropped = self.dropped.saturating_add(1);
        }
        self.events.push_back(DiagnosticEvent {
            sequence: self.next,
            elapsed_ms: self.started.elapsed().as_millis().min(u64::MAX as u128) as u64,
            terminal_id,
            generation,
            code,
        });
    }
    fn snapshot(&self) -> DiagnosticSnapshot {
        DiagnosticSnapshot {
            capacity: CAPACITY as u32,
            dropped: self.dropped,
            events: self.events.iter().cloned().collect(),
        }
    }
    fn clear(&mut self) {
        self.events.clear();
        self.dropped = 0;
    }
}
fn store() -> &'static Mutex<Store> {
    static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(Store::new()))
}
pub(crate) fn record(code: DiagnosticCode, id: Option<u32>, generation: Option<u64>) {
    store().lock().push(code, id, generation);
    crate::run_log::state(code, id, generation);
}
pub(crate) fn snapshot() -> DiagnosticSnapshot {
    let mut snapshot = store().lock().snapshot();
    snapshot.dropped = snapshot
        .dropped
        .saturating_add(PANICS_NOT_QUEUED.load(Ordering::Relaxed));
    snapshot
}
pub(crate) fn clear() {
    store().lock().clear();
    PANICS_NOT_QUEUED.store(0, Ordering::Relaxed);
    crate::run_log::clear();
}
pub(crate) fn prepare_panic_recording() {
    let _ = store();
}
pub(crate) fn panic_record() {
    // A panic while the diagnostics lock is held must never deadlock the hook.
    // No payload, location, formatting or original hook is called here.
    if let Some(mut state) = store().try_lock() {
        state.push(DiagnosticCode::CoreWorkerPanicked, None, None);
    } else {
        let _ = PANICS_NOT_QUEUED.try_update(Ordering::Relaxed, Ordering::Relaxed, |n| {
            Some(n.saturating_add(1))
        });
    }
}
pub(crate) fn status(id: u32, generation: u64, phase: hspterm_ssh_core::SessionPhase) {
    use hspterm_ssh_core::SessionPhase;
    let code = match phase {
        SessionPhase::Idle => DiagnosticCode::StateIdle,
        SessionPhase::Connecting => DiagnosticCode::StateConnecting,
        SessionPhase::Connected => DiagnosticCode::StateConnected,
        SessionPhase::Disconnected => DiagnosticCode::StateDisconnected,
        SessionPhase::Failed => DiagnosticCode::StateFailed,
        SessionPhase::Closed => DiagnosticCode::StateClosed,
    };
    record(code, Some(id), Some(generation));
}
/// A dropped/aborted Rust Future is explicitly different from a returned error.
/// The guard contains only a numeric UI identity, never its arguments/result.
pub(crate) struct ConnectionTrace {
    id: u32,
    done: bool,
}
impl ConnectionTrace {
    pub fn begin(id: u32) -> Self {
        record(DiagnosticCode::ConnectionRequested, Some(id), None);
        Self { id, done: false }
    }
    pub fn finish(mut self, ok: bool) {
        self.done = true;
        record(
            if ok {
                DiagnosticCode::ConnectionSucceeded
            } else {
                DiagnosticCode::ConnectionRejected
            },
            Some(self.id),
            None,
        );
    }
}
impl Drop for ConnectionTrace {
    fn drop(&mut self) {
        if !self.done {
            record(DiagnosticCode::ConnectionInterrupted, Some(self.id), None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn panic_recording_does_not_wait_for_an_already_held_diagnostics_lock() {
        let held = store().lock();
        let (done, waiting) = std::sync::mpsc::channel();
        let worker = std::thread::spawn(move || {
            panic_record();
            done.send(()).unwrap();
        });
        let result = waiting.recv_timeout(std::time::Duration::from_secs(1));
        // Even a regression that blocks must release its thread before failing.
        drop(held);
        worker.join().unwrap();
        assert!(result.is_ok());
    }
    #[test]
    fn public_schema_has_only_fixed_codes_and_numeric_metadata() {
        let mut s = Store::new();
        s.push(DiagnosticCode::ConnectionRejected, Some(12), Some(3));
        let value = serde_json::to_value(s.snapshot()).unwrap();
        let event = value["events"][0].as_object().unwrap();
        assert_eq!(
            event
                .keys()
                .map(String::as_str)
                .collect::<std::collections::BTreeSet<_>>(),
            [
                "code",
                "elapsed_ms",
                "generation",
                "sequence",
                "terminal_id"
            ]
            .into_iter()
            .collect()
        );
        for (key, value) in event {
            if key == "code" {
                assert_eq!(value.as_str(), Some("ConnectionRejected"));
            } else {
                assert!(value.is_u64() || value.is_null());
            }
        }
    }
    #[test]
    fn ring_is_fixed_size_and_clear_does_not_reuse_sequence() {
        let mut s = Store::new();
        for i in 0..1250 {
            s.push(DiagnosticCode::ConnectionRequested, Some(i), Some(1));
        }
        let snap = s.snapshot();
        assert_eq!(snap.events.len(), CAPACITY);
        assert_eq!(snap.dropped, 250);
        assert_eq!(snap.events[0].sequence, 251);
        assert_eq!(snap.events[999].terminal_id, Some(1249));
        s.clear();
        s.push(DiagnosticCode::VaultOpened, None, None);
        assert_eq!(s.snapshot().events[0].sequence, 1251);
        assert_eq!(s.dropped, 0);
    }
    #[test]
    fn snapshot_is_owned_and_sequence_rollover_discards_ambiguous_old_events() {
        let mut s = Store::new();
        s.push(DiagnosticCode::HostKeyRejected, Some(1), Some(2));
        let old = s.snapshot();
        s.next = u64::MAX;
        s.push(DiagnosticCode::StateClosed, Some(1), Some(2));
        assert_eq!(old.events[0].code, DiagnosticCode::HostKeyRejected);
        let snap = s.snapshot();
        assert_eq!(snap.events.len(), 1);
        assert_eq!(snap.events[0].sequence, 1);
        assert_eq!(snap.dropped, 1);
    }
}
