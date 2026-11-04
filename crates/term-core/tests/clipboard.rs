use alacritty_terminal::event::Event;
use base64::{Engine, engine::general_purpose::STANDARD};
use hspterm_term_core::{MAX_CLIPBOARD_BYTES, Size, Terminal};
fn term() -> Terminal {
    Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap()
}
#[test]
fn clipboard_write_exact_limit_and_oversize_rejection() {
    let mut terminal = term();
    for size in [MAX_CLIPBOARD_BYTES, MAX_CLIPBOARD_BYTES + 1] {
        let payload = "x".repeat(size);
        let encoded = STANDARD.encode(payload.as_bytes());
        terminal.feed(b"\x1b]52;c;").unwrap();
        for chunk in encoded.as_bytes().chunks(65536) {
            terminal.feed(chunk).unwrap();
        }
        terminal.feed(b"\x1b\\").unwrap();
        let stores: Vec<_> = terminal
            .take_events()
            .into_iter()
            .filter_map(|e| match e {
                Event::ClipboardStore(_, s) => Some(s),
                _ => None,
            })
            .collect();
        if size == MAX_CLIPBOARD_BYTES {
            assert_eq!(stores, [payload]);
            assert_eq!(terminal.take_clipboard_rejections(), 0);
        } else {
            assert!(stores.is_empty());
            assert_eq!(terminal.take_clipboard_rejections(), 1);
        }
    }
}
#[test]
fn clipboard_reads_enforce_limit_and_can_be_revoked() {
    let mut terminal = term();
    terminal.feed(b"\x1b]52;c;?\x07").unwrap();
    let formatter = terminal
        .take_events()
        .into_iter()
        .find_map(|e| match e {
            Event::ClipboardLoad(_, f) => Some(f),
            _ => None,
        })
        .unwrap();
    assert_eq!(formatter("ok"), "\x1b]52;c;b2s=\x07");
    assert_eq!(formatter(&"x".repeat(MAX_CLIPBOARD_BYTES + 1)), "");
    assert_eq!(terminal.take_clipboard_rejections(), 1);
    terminal.set_osc52_enabled(false);
    assert_eq!(formatter("no-longer-permitted"), "");
    terminal.feed(b"\x1b]52;c;?\x07\x1b]52;c;b2s=\x07").unwrap();
    assert!(
        !terminal
            .take_events()
            .iter()
            .any(|e| matches!(e, Event::ClipboardStore(..) | Event::ClipboardLoad(..)))
    );
    terminal.set_osc52_enabled(true);
    terminal.feed(b"\x1b]52;c;b2s=\x07").unwrap();
    assert!(
        terminal
            .take_events()
            .iter()
            .any(|e| matches!(e,Event::ClipboardStore(_,s) if s=="ok"))
    );
}
