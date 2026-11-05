use hspterm_term_core::{Key, KeyEvent, Size, Terminal, integration::Nonce};
fn terminal(enabled: bool) -> Terminal {
    let mut t = Terminal::new(Size::new(40, 5).unwrap(), 100).unwrap();
    if enabled {
        t.configure_integration(Nonce::parse("a".repeat(64)));
    }
    t
}
fn packet(prompt: u64, kind: &str, text: &str) -> String {
    let hex: String = text.bytes().map(|byte| format!("{byte:02x}")).collect();
    format!(
        "\x1b]777;hspterm;HSP1;{};{prompt};{kind};0;{};{hex}\x1b\\",
        "a".repeat(64),
        text.len()
    )
}
fn enter(t: &Terminal) {
    t.observe_integration_text(b"printf fixture");
    t.observe_integration_key(&KeyEvent::press(Key::Enter), b"\r");
}
#[test]
fn private_protocol_uses_complete_same_parser_frames_and_never_grid_text() {
    let ready = packet(1, "R", "");
    for split in 0..=ready.len() {
        let mut t = terminal(true);
        t.feed(&ready.as_bytes()[..split]).unwrap();
        t.feed(&ready.as_bytes()[split..]).unwrap();
        enter(&t);
        let report = packet(1, "S", "printf fixture");
        for byte in report.bytes() {
            t.feed(&[byte]).unwrap();
        }
        let accepted = t.take_integration_submissions();
        assert_eq!(accepted.len(), 1);
        assert_eq!(accepted[0].text.as_str(), "printf fixture");
        assert!(t.snapshot().text().trim().is_empty());
        assert!(t.take_events().is_empty());
    }
}
#[test]
fn disabled_truncated_and_reset_contexts_never_qualify_a_line() {
    for enabled in [false, true] {
        let mut t = terminal(enabled);
        t.feed(packet(1, "R", "").as_bytes()).unwrap();
        if enabled {
            t.feed(b"\x1b]777;hspterm;HSP1;unfinished\x1bx").unwrap();
        }
        enter(&t);
        t.feed(packet(1, "S", "printf fixture").as_bytes()).unwrap();
        assert!(t.take_integration_submissions().is_empty());
    }
    for sequence in [b"\x1bc".as_slice(), b"\x1b[?1049h\x1b[?1049l".as_slice()] {
        let mut t = terminal(true);
        t.feed(packet(1, "R", "").as_bytes()).unwrap();
        t.feed(sequence).unwrap();
        enter(&t);
        t.feed(packet(1, "S", "printf fixture").as_bytes()).unwrap();
        assert!(t.take_integration_submissions().is_empty());
    }
}
#[test]
fn protocol_events_redact_command_and_nonce_from_debug() {
    let event =
        alacritty_terminal::event::Event::ShellIntegration(Some("synthetic-private-packet".into()));
    assert_eq!(format!("{event:?}"), "ShellIntegration(<redacted>)");
}

#[test]
fn readline_keypad_and_public_command_anchor_reflow_do_not_revoke_private_input() {
    let mut t = terminal(true);
    t.feed(b"\x1b[?1h\x1b=").unwrap();
    t.feed(packet(1, "R", "").as_bytes()).unwrap();
    let proof = t
        .integration_proof()
        .expect("Readline application keypad is not a TUI proof");
    t.feed(b"\x1b]133;A\x07prompt\x1b]133;B\x07\x1b]133;C\x07output\r\n")
        .unwrap();
    t.resize(Size::new(60, 8).unwrap()).unwrap();
    assert_eq!(t.integration_proof(), Some(proof));
    t.feed(b"\x1b[?1049h\x1b[?1049l").unwrap();
    assert!(
        t.integration_proof().is_none(),
        "actual alternate-screen entry still revokes private readiness"
    );
}
