use hspterm_term_core::{ShellPhase, Size, Terminal};

fn terminal() -> Terminal {
    Terminal::new(Size::new(40, 5).unwrap(), 100).unwrap()
}

#[test]
fn passive_marks_survive_every_split_without_capturing_commands_or_rewriting_text() {
    let input = "\x1b]133;A\x07prompt> \x1b]133;B\x1b\\echo 中文\r\n\x1b]133;C;cmdline=do-not-capture-secret\x07中文\r\n\x1b]133;D;0\x1b\\";
    for split in 0..=input.len() {
        let mut t = terminal();
        t.feed(&input.as_bytes()[..split]).unwrap();
        t.feed(&input.as_bytes()[split..]).unwrap();
        let context = t.shell_context();
        assert_eq!(context.phase, ShellPhase::Finished);
        assert_eq!(context.sequence, 1);
        assert_eq!(context.exit_status, Some(0));
        assert_eq!(t.snapshot().text().trim_end(), "prompt> echo 中文\n中文");
        assert!(t.take_events().is_empty());
    }
}

#[test]
fn input_phase_needs_a_primary_prompt_and_incomplete_or_secondary_sequences_fail_closed() {
    let mut t = terminal();
    t.feed(b"\x1b]133;B\x07").unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
    t.feed(b"\x1b]133;A\x07\x1b]133;B\x07").unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Input);
    t.feed(b"\x1b]133;D\x07").unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
    t.feed(b"\x1b]133;A;k=s\x07\x1b]133;B\x07").unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
    t.feed(b"\x1b]133;A\x07\x1b]133;C\x07").unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
    t.feed(b"\x1b]133;A\x07\x1b]133;B\x07\x1b]133;C\x07")
        .unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Output);
}

#[test]
fn exit_status_is_bounded_optional_and_never_inferred_from_screen_text() {
    for (suffix, phase, status) in [
        ("D", ShellPhase::Finished, None),
        ("D;255", ShellPhase::Finished, Some(255)),
        ("D;000", ShellPhase::Finished, Some(0)),
        ("D;256", ShellPhase::Unknown, None),
        ("D;-1", ShellPhase::Unknown, None),
        ("D;0;unexpected", ShellPhase::Unknown, None),
        ("X", ShellPhase::Unknown, None),
    ] {
        let mut t = terminal();
        t.feed(b"\x1b]133;A\x07\x1b]133;B\x07\x1b]133;C\x07SUCCESS")
            .unwrap();
        t.feed(format!("\x1b]133;{suffix}\x07").as_bytes()).unwrap();
        assert_eq!(t.shell_context().phase, phase);
        assert_eq!(t.shell_context().exit_status, status);
    }
}

#[test]
fn cancelled_or_incomplete_markers_do_not_open_an_input_phase() {
    for suffix in [b"\x18".as_slice(), b"\x1a", b"\x1b[31m"] {
        let mut t = terminal();
        t.feed(b"\x1b]133;A\x07\x1b]133;B").unwrap();
        t.feed(suffix).unwrap();
        assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
    }
    let mut t = terminal();
    t.feed(b"\x1b]133;A\x07\x1b]133;B\x1b").unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Prompt);
    t.feed(b"\\").unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Input);
}

#[test]
fn tui_reset_disconnect_reflow_and_new_pty_invalidate_passive_context() {
    for reset in [b"\x1b[?1049h".as_slice(), b"\x1bc"] {
        let mut t = terminal();
        t.feed(b"\x1b]133;A\x07\x1b]133;B\x07").unwrap();
        t.feed(reset).unwrap();
        assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
    }
    let mut t = terminal();
    t.feed(b"\x1b[?1049h\x1b]133;A\x07\x1b]133;B\x07\x1b[?1049l")
        .unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
    t.feed(b"\x1b]133;A\x07\x1b]133;B\x07").unwrap();
    t.resize(Size::new(30, 5).unwrap()).unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
    t.feed(b"\x1b]133;A\x07\x1b]133;B\x07").unwrap();
    t.finish_stream();
    assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
    t.feed(b"\x1b[?2026h\x1b]133;A\x07\x1b]133;B\x07").unwrap();
    t.begin_new_generation();
    assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
}

#[test]
fn synchronized_marks_commit_with_output_and_only_latest_metadata_is_retained() {
    let mut t = terminal();
    t.feed(b"\x1b[?2026h\x1b]133;A\x07\x1b]133;B\x07").unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
    t.feed(b"\x1b[?2026l").unwrap();
    assert_eq!(t.shell_context().phase, ShellPhase::Input);
    for _ in 0..1000 {
        t.feed(b"\x1b]133;A\x07\x1b]133;B\x07\x1b]133;C\x07\x1b]133;D;0\x07")
            .unwrap();
    }
    assert_eq!(t.shell_context().sequence, 1001);
    assert_eq!(t.shell_context().phase, ShellPhase::Finished);
    assert!(t.take_events().is_empty());
    assert!(t.snapshot().text().trim().is_empty());
}

#[test]
fn truncated_or_oversized_properties_cannot_publish_partial_context() {
    for control in [
        format!("\x1b]133;C{}\x07", ";cmdline=ignored".repeat(40)),
        format!(
            "\x1b]133;C;cmdline={}\x07",
            "s".repeat(14 * 1024 * 1024 + 1)
        ),
    ] {
        let mut t = terminal();
        t.feed(b"\x1b]133;A\x07\x1b]133;B\x07").unwrap();
        t.feed(control.as_bytes()).unwrap();
        assert_eq!(t.shell_context().phase, ShellPhase::Unknown);
        t.feed(b"\x1b]133;A\x07\x1b]133;B\x07").unwrap();
        assert_eq!(t.shell_context().phase, ShellPhase::Input);
        assert!(t.snapshot().text().trim().is_empty());
    }
}
