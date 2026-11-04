use hspterm_term_core::{Size, Terminal};

fn terminal(columns: u16) -> Terminal {
    Terminal::new(Size::new(columns, 4).unwrap(), 1024).unwrap()
}
fn link(uri: &str, label: &str) -> String {
    format!("\x1b]8;id=fixture;{uri}\x1b\\{label}\x1b]8;;\x1b\\")
}

#[test]
fn osc8_is_passive_chunk_independent_and_preserves_actual_labels() {
    let bytes = link("https://example.invalid/a;b?q=one", "中e\u{301} label");
    for split in 0..=bytes.len() {
        let mut t = terminal(24);
        t.feed(&bytes.as_bytes()[..split]).unwrap();
        t.feed(&bytes.as_bytes()[split..]).unwrap();
        t.feed(b" plain").unwrap();
        let s = t.try_snapshot().unwrap();
        assert_eq!(
            s.cells[0].hyperlink.as_ref().unwrap().uri(),
            "https://example.invalid/a;b?q=one"
        );
        assert_eq!(s.cells[2].text, "e\u{301}");
        assert!(s.cells[9].hyperlink.is_none());
        assert!(s.text().starts_with("中e\u{301} label plain"));
        let mut output = Vec::new();
        t.document().unwrap().export(&mut output).unwrap();
        let text = String::from_utf8(output).unwrap();
        assert!(text.contains("中e\u{301} label plain"));
        assert!(!text.contains("https://"));
        assert!(t.take_events().is_empty());
    }
}

#[test]
fn cold_history_reflow_stream_end_and_new_pty_keep_metadata_on_original_cells_only() {
    let mut t = terminal(20);
    t.feed(link("https://example.invalid/cold", "冷e\u{301}old label").as_bytes())
        .unwrap();
    t.feed(b"\r\n").unwrap();
    for i in 0..700 {
        t.feed(format!("row{i:04}\r\n").as_bytes()).unwrap();
    }
    t.scroll(i32::MAX).unwrap();
    assert_eq!(
        t.try_snapshot().unwrap().cells[0]
            .hyperlink
            .as_ref()
            .unwrap()
            .uri(),
        "https://example.invalid/cold"
    );
    assert!(t.history_stats().disk_reads > 0);
    for columns in [8, 32, 20] {
        t.resize(Size::new(columns, 4).unwrap()).unwrap();
        t.scroll(i32::MAX).unwrap();
        let s = t.try_snapshot().unwrap();
        assert_eq!(
            s.cells[0].hyperlink.as_ref().unwrap().uri(),
            "https://example.invalid/cold"
        );
    }
    t.finish_stream();
    assert!(t.try_snapshot().unwrap().cells[0].hyperlink.is_some());
    t.begin_new_generation();
    t.scroll(i32::MIN).unwrap();
    t.feed(b"fresh").unwrap();
    assert!(
        t.try_snapshot()
            .unwrap()
            .cells
            .iter()
            .all(|c| c.hyperlink.is_none())
    );
    t.scroll(i32::MAX).unwrap();
    assert!(t.try_snapshot().unwrap().cells[0].hyperlink.is_some());
}

#[test]
fn overwrite_clear_and_alternate_screen_cannot_activate_retired_labels() {
    let mut t = terminal(24);
    t.feed(link("https://example.invalid/a", "old").as_bytes())
        .unwrap();
    t.feed(b"\rnew").unwrap();
    assert!(
        t.try_snapshot()
            .unwrap()
            .cells
            .iter()
            .all(|c| c.hyperlink.is_none())
    );
    t.feed(b"\r").unwrap();
    t.feed(link("https://example.invalid/b", "main").as_bytes())
        .unwrap();
    t.feed(b"\x1b[?1049h").unwrap();
    assert!(
        t.try_snapshot()
            .unwrap()
            .cells
            .iter()
            .all(|c| c.hyperlink.is_none())
    );
    t.feed(link("https://example.invalid/alt", "inner").as_bytes())
        .unwrap();
    t.feed(b"\x1b[?1049l").unwrap();
    assert_eq!(
        t.try_snapshot().unwrap().cells[0]
            .hyperlink
            .as_ref()
            .unwrap()
            .uri(),
        "https://example.invalid/b"
    );
    t.feed(b"\x1b[2J").unwrap();
    assert!(
        t.try_snapshot()
            .unwrap()
            .cells
            .iter()
            .all(|c| c.hyperlink.is_none())
    );
}

#[test]
fn oversized_targets_are_blocked_before_retention_and_close_is_still_distinct() {
    let mut t = terminal(40);
    t.feed(
        link(
            &format!("https://example.invalid/{}", "x".repeat(6000)),
            "http://localhost:1234",
        )
        .as_bytes(),
    )
    .unwrap();
    assert_eq!(
        t.try_snapshot().unwrap().cells[0]
            .hyperlink
            .as_ref()
            .unwrap()
            .uri(),
        ""
    );
    t.feed(b" plain").unwrap();
    assert!(t.try_snapshot().unwrap().cells[21].hyperlink.is_none());
    t.feed(
        format!(
            "\x1b]8;id={};https://example.invalid/short\x07id\x1b]8;;\x07",
            "x".repeat(6000)
        )
        .as_bytes(),
    )
    .unwrap();
    let snapshot = t.try_snapshot().unwrap();
    let retained = snapshot
        .cells
        .iter()
        .find_map(|c| c.hyperlink.as_ref().filter(|l| !l.uri().is_empty()))
        .unwrap();
    assert_eq!(retained.uri(), "https://example.invalid/short");
    assert!(retained.id().len() <= 1024);
}

#[test]
fn many_literal_uri_semicolons_are_not_cut_at_the_osc_parameter_limit() {
    let uri = format!("https://example.invalid/{}END?q=one", "part;".repeat(40));
    let mut t = terminal(24);
    t.feed(link(&uri, "literal label").as_bytes()).unwrap();
    assert_eq!(
        t.try_snapshot().unwrap().cells[0]
            .hyperlink
            .as_ref()
            .unwrap()
            .uri(),
        uri
    );
}

#[test]
fn aborted_osc8_never_commits_a_partial_target_or_inherits_the_old_one() {
    for abort in [b"\x18".as_slice(), b"\x1a", b"\x1b[0m"] {
        let mut t = terminal(40);
        t.feed(b"\x1b]8;;https://example.invalid/old\x1b\\")
            .unwrap();
        t.feed(b"\x1b]8;;https://example.invalid/partial").unwrap();
        t.feed(abort).unwrap();
        t.feed(b"https://example.invalid/deceptive-label").unwrap();
        assert_eq!(
            t.try_snapshot().unwrap().cells[0]
                .hyperlink
                .as_ref()
                .unwrap()
                .uri(),
            ""
        );
    }
}

#[test]
fn invalid_utf8_uri_is_blocked_instead_of_becoming_a_valid_close() {
    let mut t = terminal(24);
    t.feed(b"\x1b]8;;https://example.invalid/\xff\x07label")
        .unwrap();
    assert_eq!(
        t.try_snapshot().unwrap().cells[0]
            .hyperlink
            .as_ref()
            .unwrap()
            .uri(),
        ""
    );
    t.feed(b"\x1b]8;;\x07normal").unwrap();
    assert!(t.try_snapshot().unwrap().cells[5].hyperlink.is_none());
}
