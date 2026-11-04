use hspterm_term_core::{Size, Terminal};
const BEGIN: &[u8] = b"\x1b]133;A\x07$ \x1b]133;B\x07echo\r\n\x1b]133;C\x07";
const END: &[u8] = b"\x1b]133;D;0\x07";
fn terminal(history: usize) -> Terminal {
    Terminal::new(Size::new(40, 5).unwrap(), history).unwrap()
}
fn output(t: &Terminal, id: u64) -> String {
    let (document, range) = t.command_document(id).unwrap();
    let mut text = Vec::new();
    document
        .export_range(range.start, range.end, &mut text)
        .unwrap();
    String::from_utf8(text).unwrap()
}
fn complete(t: &mut Terminal, text: &[u8]) -> u64 {
    t.feed(BEGIN).unwrap();
    t.feed(text).unwrap();
    t.feed(END).unwrap();
    t.command_ranges().last().unwrap().id
}
#[test]
fn complete_boundaries_copy_only_real_unicode_output_at_every_byte_split() {
    let text = "中文 e\u{301}\r\n";
    let input = [BEGIN, text.as_bytes(), END].concat();
    for split in 0..=input.len() {
        let mut t = terminal(100);
        t.feed(&input[..split]).unwrap();
        t.feed(&input[split..]).unwrap();
        let ranges = t.command_ranges();
        assert_eq!(ranges.len(), 1);
        assert_eq!(ranges[0].exit_status, Some(0));
        assert_eq!(output(&t, ranges[0].id), "中文 e\u{301}\n");
        assert!(t.take_events().is_empty());
        assert!(t.snapshot().text().starts_with("$ echo\n中文 e\u{301}"));
    }
}
#[test]
fn cold_output_ranges_are_metadata_only_and_stream_across_encrypted_pages() {
    let mut t = terminal(2000);
    let mut expected = String::new();
    t.feed(BEGIN).unwrap();
    for i in 0..700 {
        let line = format!("line {i:04} 中文");
        t.feed(format!("{line}\r\n").as_bytes()).unwrap();
        expected.push_str(&line);
        expected.push('\n');
    }
    t.feed(END).unwrap();
    t.maintain_history().unwrap();
    let reads = t.history_stats().disk_reads;
    let range = t.command_ranges().pop().unwrap();
    let (doc, points) = t.command_document(range.id).unwrap();
    assert_eq!(t.history_stats().disk_reads, reads);
    let resident = t.history_stats().resident_history_cells;
    let mut copied = Vec::new();
    doc.export_range(points.start, points.end, &mut copied)
        .unwrap();
    assert_eq!(String::from_utf8(copied).unwrap(), expected);
    assert_eq!(t.history_stats().resident_history_cells, resident);
}
#[test]
fn later_overwrite_even_restoring_same_text_rejects_old_mutable_row_proof() {
    let mut t = terminal(100);
    let id = complete(&mut t, b"old\r\n");
    assert_eq!(output(&t, id), "old\n");
    t.feed(b"\x1b[1A\rnew\rold").unwrap();
    assert!(t.command_document(id).is_err());
    assert!(t.command_ranges().is_empty());
}
#[test]
fn retention_discards_only_unreliable_markers_without_holding_old_cold_rows_alive() {
    let mut t = terminal(10);
    let first = complete(&mut t, b"old-command\r\n");
    for _ in 0..40 {
        complete(&mut t, b"new-command\r\n");
    }
    assert!(t.command_document(first).is_err());
    assert!(t.command_ranges().len() < 10);
    let last = t.command_ranges().last().unwrap().id;
    assert_eq!(output(&t, last), "new-command\n");
}
#[test]
fn disconnected_complete_output_stays_readable_but_new_pty_invalidates_without_id_reuse() {
    let mut t = terminal(100);
    let first = complete(&mut t, b"retained\r\n");
    t.finish_stream();
    assert_eq!(output(&t, first), "retained\n");
    t.feed(BEGIN).unwrap();
    t.feed(b"unfinished").unwrap();
    t.finish_stream();
    assert_eq!(t.command_ranges().len(), 1);
    t.begin_new_generation();
    assert!(t.command_document(first).is_err());
    assert!(complete(&mut t, b"new-root\r\n") > first);
}
#[test]
fn alternate_screen_and_malformed_markers_fail_closed_but_proven_reflow_keeps_ranges() {
    for disturbance in [b"\x1b[?1049h".as_slice(), b"\x1b]133;unknown\x07", b"\x1bc"] {
        let mut t = terminal(100);
        let id = complete(&mut t, b"old\r\n");
        t.feed(disturbance).unwrap();
        assert!(t.command_document(id).is_err());
    }
    let mut t = terminal(100);
    let id = complete(&mut t, b"retained\r\n");
    t.resize(Size::new(20, 5).unwrap()).unwrap();
    assert_eq!(output(&t, id), "retained\n");
    assert!(t.document().unwrap().rows() >= 5);
    let fresh = complete(&mut t, b"new-size\r\n");
    assert_eq!(output(&t, fresh), "new-size\n");
}

#[test]
fn unicode_wide_combining_and_repeated_width_reflow_keep_the_same_command_id_and_output() {
    let mut t = terminal(2000);
    let text = "中文 e\u{301} 🦀 box─┬─ long-output-0123456789\r\nnext 中\r\n";
    let id = complete(&mut t, text.as_bytes());
    let expected = output(&t, id);
    for columns in [20, 7, 61, 11, 40] {
        t.resize(Size::new(columns, 5).unwrap()).unwrap();
        assert_eq!(output(&t, id), expected, "columns={columns}");
        assert_eq!(t.command_ranges().last().unwrap().id, id);
    }
}

#[test]
fn cold_history_reflow_keeps_exact_plain_output_without_holding_a_second_grid() {
    let mut t = terminal(5000);
    t.feed(BEGIN).unwrap();
    let mut expected = String::new();
    for i in 0..700 {
        let line = format!("retained {i:04} 中文 e\u{301} long-output");
        expected.push_str(&line);
        expected.push('\n');
        t.feed(format!("{line}\r\n").as_bytes()).unwrap();
    }
    t.feed(END).unwrap();
    let id = t.command_ranges().last().unwrap().id;
    assert!(t.history_stats().disk_bytes > 0);
    for columns in [17, 61, 9, 40] {
        t.resize(Size::new(columns, 5).unwrap()).unwrap();
        assert_eq!(output(&t, id), expected, "cold columns={columns}");
        let stats = t.history_stats();
        assert!(stats.resident_history_cells <= (256 + 5) * columns as usize);
    }
}

#[test]
fn height_changes_can_reanchor_old_output_before_the_unsigned_event_origin() {
    let mut t = Terminal::new(Size::new(40, 8).unwrap(), 2000).unwrap();
    let id = complete(&mut t, b"old-height\r\n");
    t.feed(b"later-2\r\nlater-3\r\nlater-4\r\nlater-5\r\nlater-6")
        .unwrap();
    for (columns, rows) in [(40, 3), (17, 3), (40, 12), (21, 5)] {
        t.resize(Size::new(columns, rows).unwrap()).unwrap();
        assert_eq!(output(&t, id), "old-height\n");
    }
}

#[test]
fn equal_text_in_different_commands_does_not_allow_reflow_to_resurrect_a_mutated_row() {
    let mut t = Terminal::new(Size::new(40, 20).unwrap(), 1000).unwrap();
    let ids: Vec<_> = (0..4).map(|_| complete(&mut t, b"repeat\r\n")).collect();
    t.resize(Size::new(8, 20).unwrap()).unwrap();
    let ranges = t.command_ranges();
    assert_eq!(ranges.iter().map(|r| r.id).collect::<Vec<_>>(), ids);
    assert!(ranges.windows(2).all(|r| r[0].start.row < r[1].start.row));
    let last = ranges.last().unwrap();
    let visible = last.start.row as usize - t.document().unwrap().history_lines;
    t.feed(
        format!(
            "\x1b[{};{}HX\x1b[{};{}Hr",
            visible + 1,
            last.start.column + 1,
            visible + 1,
            last.start.column + 1
        )
        .as_bytes(),
    )
    .unwrap();
    assert!(t.command_document(last.id).is_err());
    t.resize(Size::new(40, 20).unwrap()).unwrap();
    assert!(t.command_document(last.id).is_err());
    for id in &ids[..ids.len() - 1] {
        assert_eq!(output(&t, *id), "repeat\n");
    }
}

#[test]
fn unfinished_output_does_not_gain_an_end_marker_from_resize_and_size_lock_keeps_old_geometry() {
    let mut t = terminal(1000);
    let id = complete(&mut t, b"completed\r\n");
    t.set_size_locked(true);
    t.resize(Size::new(8, 2).unwrap()).unwrap();
    assert_eq!(t.snapshot().size.columns, 40);
    assert_eq!(output(&t, id), "completed\n");
    t.set_size_locked(false);
    t.feed(BEGIN).unwrap();
    t.feed(b"unfinished").unwrap();
    t.resize(Size::new(20, 5).unwrap()).unwrap();
    t.feed(END).unwrap();
    assert_eq!(
        t.command_ranges().iter().map(|r| r.id).collect::<Vec<_>>(),
        vec![id]
    );
    assert_eq!(output(&t, id), "completed\n");
}

#[test]
fn trimming_during_reflow_rejects_old_ranges_without_guessing_similar_surviving_text() {
    let mut t = terminal(3);
    let id = complete(&mut t, b"old text 012345678901234567890123456789\r\n");
    for _ in 0..3 {
        t.feed(b"later text 012345678901234567890\r\n").unwrap();
    }
    t.resize(Size::new(5, 5).unwrap()).unwrap();
    assert!(t.command_document(id).is_err());
    assert!(t.command_ranges().iter().all(|r| r.id != id));
    assert!(t.document().unwrap().rows() <= 8);
}
#[test]
fn new_ranges_work_after_height_resize_puts_pre_zero_rows_into_history() {
    let mut t = Terminal::new(Size::new(40, 8).unwrap(), 100).unwrap();
    t.feed(b"1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7").unwrap();
    t.resize(Size::new(40, 3).unwrap()).unwrap();
    let id = complete(&mut t, b"after-height\r\n");
    assert_eq!(output(&t, id), "after-height\n");
}
#[test]
fn partial_scroll_or_clear_during_output_never_promotes_an_uncertain_range() {
    for disturbance in [
        b"\x1b[2;4r\x1b[S".as_slice(),
        b"\x1b[2J",
        b"\x1b[K",
        b"\x1b[P",
    ] {
        let mut t = terminal(100);
        t.feed(BEGIN).unwrap();
        t.feed(b"output").unwrap();
        t.feed(disturbance).unwrap();
        t.feed(END).unwrap();
        assert!(t.command_ranges().is_empty());
    }
}
#[test]
fn synchronized_output_only_publishes_complete_boundaries_with_the_batch() {
    let mut t = terminal(100);
    t.feed(b"\x1b[?2026h").unwrap();
    t.feed(BEGIN).unwrap();
    t.feed(b"batch\r\n").unwrap();
    t.feed(END).unwrap();
    assert!(t.command_ranges().is_empty());
    t.feed(b"\x1b[?2026l").unwrap();
    let id = t.command_ranges().last().unwrap().id;
    assert_eq!(output(&t, id), "batch\n");
}

#[test]
fn reflow_keeps_completed_output_with_surrounding_wrapped_prompt_lines() {
    for before in [0, 1, 19, 23, 40, 80, 120, 160, 220] {
        for after in [0, 1, 19, 23, 40, 80, 120, 160, 220] {
            let mut terminal = Terminal::new(Size::new(80, 24).unwrap(), 1000).unwrap();
            terminal
                .feed(format!("{}\r\n", "p".repeat(before)).as_bytes())
                .unwrap();
            let id = complete(&mut terminal, "RANGE_READY中文é\r\n".as_bytes());
            terminal.feed("p".repeat(after).as_bytes()).unwrap();
            for columns in [23, 65, 17] {
                terminal.resize(Size::new(columns, 24).unwrap()).unwrap();
                assert!(
                    terminal.command_document(id).is_ok(),
                    "before={before} after={after} columns={columns}"
                );
                assert_eq!(output(&terminal, id), "RANGE_READY中文é\n");
            }
        }
    }
}
