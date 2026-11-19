//! Soft-wrap + caret movement regression coverage.
//!
//! Problem-B background (2026-11-19 investigation): after a command whose
//! output has no trailing newline, bash's Readline draws the prompt on the
//! same physical row but models it as starting at column zero. Once the
//! input soft-wraps, that wrong baseline makes Readline emit plain `\x08`
//! deltas across physical row boundaries — a stream no conforming terminal
//! can move the caret up with, because Backspace at column 0 is a no-op
//! (verified against tmux's emulator; Ctrl+C's fresh CRLF+prompt resyncs
//! Readline, which is why the symptom disappears afterwards). The emulator
//! core itself is faithful: the byte-for-byte replay below was captured from
//! a real bash PTY (20x10, default prompt) and its cursor positions after
//! every phase match tmux exactly, including the wrap-boundary crossing.
use hspterm_term_core::{Size, Terminal};

#[test]
fn replayed_readline_soft_wrap_matches_xterm_semantics() {
    let mut t = Terminal::new(Size::new(20, 10).unwrap(), 200).unwrap();
    // Raw LF from the command echo keeps the column (xterm IND semantics).
    let phases: &[(&str, &[u8], (i64, usize))] = &[
        ("boot", b"\x1b[?2004hbash-5.2# ", (0, 10)),
        ("cmd_echo", b"printf no-newline-tail\n", (2, 12)),
        // Unterminated output tail; the prompt follows on the same row.
        (
            "run",
            b"\x1b[?2004l\rno-newline-tail\x1b[?2004hbash-5.2# ",
            (3, 5),
        ),
        // Readline echoes 30 chars (the terminal wraps), then its space+CR
        // reconciliation for a line that is an exact width multiple.
        ("type_long", b"abcdefghijabcdefghijabcdefghij \r", (4, 0)),
        // ArrowLeft across the wrapped boundary: Readline emits CUU plus CUF
        // to the previous row's last column.
        (
            "left_1",
            b"\x1b[A\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C\x1b[C",
            (3, 19),
        ),
        ("left_2", b"\x08", (3, 18)),
        ("left_3", b"\x08", (3, 17)),
        ("left_6", b"\x08\x08\x08", (3, 14)),
        ("left_12", b"\x08\x08\x08\x08\x08\x08", (3, 8)),
    ];
    for (name, bytes, (row, col)) in phases {
        t.feed(bytes).unwrap();
        let s = t.snapshot();
        assert_eq!(
            (s.cursor_row, s.cursor_column),
            (*row, *col),
            "phase {name}: caret must return to the input start row exactly as xterm"
        );
    }
    let s = t.snapshot();
    assert!(s.text().contains("no-newline-tailbash-"));
    assert!(s.text().contains("5.2# abcdefghijabcde"));
}

#[test]
fn backspace_at_column_zero_never_moves_up_but_cuu_cuf_crosses() {
    let mut t = Terminal::new(Size::new(20, 3).unwrap(), 50).unwrap();
    // Fill the screen exactly; the cursor rests on the last column of the
    // bottom row with the deferred wrap pending.
    t.feed(b"AAAAAAAAAAAAAAAAAAAABBBBBBBBBBBBBBBBBBBBCCCCCCCCCCCCCCCCCCCC")
        .unwrap();
    let s = t.snapshot();
    assert_eq!((s.cursor_row, s.cursor_column), (2, 19));
    // One more character wraps at the bottom row, scrolls the grid and is
    // written at the start of the new bottom row.
    t.feed(b"X").unwrap();
    let s = t.snapshot();
    assert_eq!((s.cursor_row, s.cursor_column), (2, 1));
    assert_eq!(s.cells.len(), 60);
    // Backspace walks to column 0 and further plain Backspace is a no-op:
    // this is exactly why Readline's naive BS-only streams (desynced by an
    // unterminated output line) cannot bring the caret back to the input
    // start row in any conforming terminal.
    t.feed(b"\x08\x08\x08").unwrap();
    let s = t.snapshot();
    assert_eq!((s.cursor_row, s.cursor_column), (2, 0));
    // The cursor-up + cursor-forward pair Readline emits when its model is
    // synced does cross the wrapped boundary and lands on the previous row.
    let mut up_forward: Vec<u8> = b"\x1b[A".to_vec();
    for _ in 0..19 {
        up_forward.extend_from_slice(b"\x1b[C");
    }
    t.feed(&up_forward).unwrap();
    let s = t.snapshot();
    assert_eq!((s.cursor_row, s.cursor_column), (1, 19));
}

#[test]
fn wide_chars_wrap_with_spacer_and_caret_walks_back() {
    let mut t = Terminal::new(Size::new(10, 4).unwrap(), 50).unwrap();
    // Five wide glyphs fill the row exactly; the reported caret column snaps
    // back to the fifth glyph's lead cell (column 8) from its spacer.
    t.feed("中中中中中".as_bytes()).unwrap();
    let s = t.snapshot();
    assert_eq!((s.cursor_row, s.cursor_column), (0, 8));
    // A further wide glyph cannot fit: the row wraps behind a leading
    // placeholder cell and the glyph lands on the next row.
    t.feed("文".as_bytes()).unwrap();
    let s = t.snapshot();
    assert_eq!((s.cursor_row, s.cursor_column), (1, 2));
    assert!(s.text().contains("中中中中中"));
    assert!(s.text().contains("文"));
    // Backspace walks onto the glyph's lead cell and stops at column 0.
    t.feed(b"\x08").unwrap();
    let s = t.snapshot();
    assert_eq!((s.cursor_row, s.cursor_column), (1, 0));
    t.feed(b"\x08\x08").unwrap();
    let s = t.snapshot();
    assert_eq!((s.cursor_row, s.cursor_column), (1, 0));
}
