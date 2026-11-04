use alacritty_terminal::{event::Event, term::ClipboardType};
use hspterm_term_core::{Size, Terminal};
use std::sync::Mutex;

struct Recorder(Mutex<Vec<String>>);
static LOGS: Recorder = Recorder(Mutex::new(Vec::new()));
impl log::Log for Recorder {
    fn enabled(&self, _: &log::Metadata<'_>) -> bool {
        true
    }
    fn log(&self, record: &log::Record<'_>) {
        let mut messages = self.0.lock().unwrap();
        if messages.len() < 2048 {
            messages.push(record.args().to_string());
        }
    }
    fn flush(&self) {}
}
#[test]
fn terminal_debug_and_trace_never_format_payloads_or_unknown_osc_dcs_bytes() {
    const MARKER: &str = "synthetic-clipboard-title-terminal-secret";
    log::set_logger(&LOGS).unwrap();
    log::set_max_level(log::LevelFilter::Trace);
    let mut t = Terminal::new(Size::new(80, 4).unwrap(), 100).unwrap();
    let output = format!(
        "{MARKER}\x1b]2;{MARKER}\x07\x1b[22;0t\x1b]9090;{MARKER}\x07\x1b]22;{MARKER}\x07\x1bP0;1q{MARKER}\x1b\\"
    );
    t.feed(output.as_bytes()).unwrap();
    assert!(
        t.snapshot().text().contains(MARKER),
        "redaction must not change terminal text"
    );
    let snapshot = t.snapshot();
    assert!(!format!("{snapshot:?}").contains(MARKER));
    assert!(!format!("{:?}", snapshot.cells).contains(MARKER));
    for e in [
        Event::Title(MARKER.into()),
        Event::PtyWrite(MARKER.into()),
        Event::ClipboardStore(ClipboardType::Clipboard, MARKER.into()),
        Event::Notification {
            title: MARKER.into(),
            body: MARKER.into(),
        },
    ] {
        assert!(!format!("{e:?}").contains(MARKER));
    }
    let messages = LOGS.0.lock().unwrap();
    if log::STATIC_MAX_LEVEL == log::LevelFilter::Off {
        assert!(
            messages.is_empty(),
            "application dependency logging is compiled out"
        );
    } else {
        assert!(
            messages
                .iter()
                .any(|m| m.contains("unhandled osc_dispatch"))
        );
    }
    assert!(!messages.iter().any(|m| m.contains("unhandled put")));
    assert!(
        !messages
            .iter()
            .any(|m| m.contains(MARKER) || m.contains("byte=") || m.contains("params="))
    );
}
