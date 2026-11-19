//! Current process only. No raw foreign errors, command/output, credentials or
//! paths enter this sink; callers provide audited messages and numeric metadata.
use parking_lot::Mutex;
use std::{
    collections::VecDeque,
    sync::OnceLock,
    time::{Instant, SystemTime, UNIX_EPOCH},
};
const BUDGET: usize = 4 * 1024 * 1024;
struct Log {
    started: Instant,
    unix_ms: u128,
    bytes: usize,
    dropped: u64,
    lines: VecDeque<String>,
}
impl Log {
    fn new() -> Self {
        Self {
            started: Instant::now(),
            unix_ms: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis(),
            bytes: 0,
            dropped: 0,
            lines: VecDeque::new(),
        }
    }
    fn push(&mut self, level: &str, module: &str, message: &str) {
        let line = format!(
            "{} +{}ms [{level}] {module}: {message}\n",
            self.unix_ms + self.started.elapsed().as_millis(),
            self.started.elapsed().as_millis()
        );
        if line.len() > 4096 {
            self.dropped += 1;
            return;
        }
        while self.bytes + line.len() > BUDGET {
            if let Some(old) = self.lines.pop_front() {
                self.bytes -= old.len();
                self.dropped += 1;
            } else {
                break;
            }
        }
        self.bytes += line.len();
        self.lines.push_back(line);
    }
    fn export(&self) -> String {
        let mut out = format!(
            "HSPTerm native current-process log v1\nstart-unix-ms={} budget-bytes={} dropped={}\n",
            self.unix_ms, BUDGET, self.dropped
        );
        for line in &self.lines {
            out.push_str(line);
        }
        out
    }
}
fn log() -> &'static Mutex<Log> {
    static LOG: OnceLock<Mutex<Log>> = OnceLock::new();
    LOG.get_or_init(|| Mutex::new(Log::new()))
}
pub(crate) fn prepare() {
    let _ = log();
}
pub(crate) fn state(
    code: crate::diagnostics::DiagnosticCode,
    id: Option<u32>,
    generation: Option<u64>,
) {
    let level = match code {
        crate::diagnostics::DiagnosticCode::ConnectionRejected
        | crate::diagnostics::DiagnosticCode::StateFailed
        | crate::diagnostics::DiagnosticCode::TransferRequestRejected
        | crate::diagnostics::DiagnosticCode::CoreWorkerPanicked => "ERROR",
        crate::diagnostics::DiagnosticCode::HostKeyRejected
        | crate::diagnostics::DiagnosticCode::ConnectionInterrupted => "WARN",
        _ => "INFO",
    };
    log().lock().push(
        level,
        "core",
        &format!("{code:?} terminal={id:?} generation={generation:?}"),
    );
}
pub(crate) fn decision(operation: &'static str, reason: &'static str, id: u32, generation: u64) {
    log().lock().push(
        "INFO",
        operation,
        &format!("{reason} terminal={id} generation={generation}"),
    );
}
/// Typed configuration-sync failure category: bounded enum names only, never
/// foreign error text, credentials or endpoints.
pub(crate) fn sync_failure(code: &'static str, kind: &'static str) {
    log().lock().push(
        "ERROR",
        "configuration_sync",
        &format!("status={code} kind={kind}"),
    );
}
pub(crate) fn failure(
    error: &anyhow::Error,
    safe_message: &str,
    caller: &std::panic::Location<'_>,
) {
    // The public boundary has already audited safe_message. Include typed OS /
    // SSH categories and source coordinates, never Debug or source-chain text.
    let kind = if let Some(io) = error.downcast_ref::<std::io::Error>() {
        format!("io.{:?} os-code={:?}", io.kind(), io.raw_os_error())
    } else if let Some(ssh) = error.downcast_ref::<hspterm_ssh_core::SshError>() {
        use hspterm_ssh_core::SshError;
        match ssh {
            SshError::Io(io) => format!("ssh.io.{:?} os-code={:?}", io.kind(), io.raw_os_error()),
            SshError::Timeout(stage) => format!("ssh.timeout.{stage:?}"),
            SshError::RequestDenied(stage) => format!("ssh.denied.{stage:?}"),
            SshError::Authentication => "ssh.authentication".into(),
            SshError::Protocol(_) => "ssh.protocol".into(),
            SshError::Sftp(_) => "ssh.sftp".into(),
            _ => "ssh.operation".into(),
        }
    } else if error.is::<serde_json::Error>() {
        "data.format".into()
    } else {
        "operation".into()
    };
    let source = caller.file().rsplit(['/', '\\']).next().unwrap_or("native");
    log().lock().push(
        "ERROR",
        "native",
        &format!("{source}:{} kind={kind} {safe_message}", caller.line()),
    );
}
pub(crate) fn panic_location(location: Option<&std::panic::Location<'_>>) {
    // Panic hook must never wait for a lock already held by the failing thread.
    if let Some(mut sink) = log().try_lock() {
        let message = location
            .map(|loc| {
                format!(
                    "{}:{}",
                    loc.file().rsplit(['/', '\\']).next().unwrap_or("native"),
                    loc.line()
                )
            })
            .unwrap_or_else(|| "unknown-location".into());
        sink.push("ERROR", "native.panic", &message);
    }
}
pub(crate) fn export() -> String {
    log().lock().export()
}
pub(crate) fn clear() {
    let mut log = log().lock();
    log.lines.clear();
    log.bytes = 0;
    log.dropped = 0;
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn logs_are_bounded_and_a_new_process_store_has_no_previous_entries() {
        let mut first = Log::new();
        first.push("INFO", "test", "synthetic-first-run");
        assert!(first.export().contains("synthetic-first-run"));
        let second = Log::new();
        assert!(!second.export().contains("synthetic-first-run"));
        for _ in 0..20000 {
            first.push("INFO", "test", &"x".repeat(512));
        }
        assert!(first.bytes <= BUDGET && first.dropped > 0);
    }
    #[test]
    fn foreign_error_body_never_enters_log() {
        let error = anyhow::anyhow!("password=synthetic-secret /private/fixture");
        let safe = crate::public_errors::summary(&error);
        failure(&error, &safe, std::panic::Location::caller());
        let out = export();
        assert!(!out.contains("synthetic-secret") && !out.contains("/private/fixture"));
        assert!(out.contains("ERROR") && out.contains("kind=operation"));
    }
}
