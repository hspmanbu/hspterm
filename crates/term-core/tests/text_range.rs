use hspterm_term_core::{Size, Terminal, TextPoint};
use std::io::{self, Write};

fn point(row: u32, column: u16) -> TextPoint {
    TextPoint { row, column }
}
fn terminal(columns: u16, rows: u16) -> Terminal {
    Terminal::new(Size::new(columns, rows).unwrap(), 1024).unwrap()
}

#[test]
fn exact_half_open_ranges_preserve_chinese_combining_text_and_real_line_boundaries() {
    let mut t = terminal(8, 4);
    t.feed("header\r\n甲e\u{301}xx\r\nbody\r\nprompt".as_bytes())
        .unwrap();
    let doc = t.document().unwrap();
    let mut output = Vec::new();
    doc.export_range(point(1, 0), point(3, 0), &mut output)
        .unwrap();
    assert_eq!(String::from_utf8(output).unwrap(), "甲e\u{301}xx\nbody\n");
    let mut output = Vec::new();
    doc.export_range(point(1, 2), point(1, 3), &mut output)
        .unwrap();
    assert_eq!(String::from_utf8(output).unwrap(), "e\u{301}");
}

#[test]
fn soft_wraps_add_no_newline_and_explicit_final_column_preserves_selected_spaces() {
    let mut t = terminal(6, 3);
    t.feed(b"abc   def\r\nnext").unwrap();
    let doc = t.document().unwrap();
    let mut output = Vec::new();
    doc.export_range(point(0, 0), point(2, 2), &mut output)
        .unwrap();
    assert_eq!(String::from_utf8(output).unwrap(), "abc   def\nne");
    let mut output = Vec::new();
    doc.export_range(point(0, 0), point(0, 6), &mut output)
        .unwrap();
    assert_eq!(output, b"abc   ");
    let mut t = terminal(10, 3);
    t.feed(b"p> x\r\na  ").unwrap();
    let mut output = Vec::new();
    t.document()
        .unwrap()
        .export_range(point(1, 0), point(1, 3), &mut output)
        .unwrap();
    assert_eq!(output, b"a  ");
}

#[test]
fn invalid_or_partial_wide_character_endpoints_fail_before_writing_anything() {
    let mut t = terminal(8, 3);
    t.feed("甲text".as_bytes()).unwrap();
    let doc = t.document().unwrap();
    for (a, b) in [
        (point(0, 1), point(0, 3)),
        (point(0, 0), point(0, 1)),
        (point(0, 9), point(1, 0)),
        (point(0, 0), point(doc.rows() as u32, 0)),
        (point(1, 0), point(0, 0)),
        (point(0, 5), point(0, 3)),
    ] {
        let mut output = b"unchanged".to_vec();
        assert!(doc.export_range(a, b, &mut output).is_err());
        assert_eq!(output, b"unchanged");
    }
    let mut output = Vec::new();
    doc.export_range(point(0, 0), point(0, 2), &mut output)
        .unwrap();
    assert_eq!(String::from_utf8(output).unwrap(), "甲");
}

#[test]
fn frozen_range_is_read_from_cold_history_without_loading_unrelated_rows_or_filling_viewport_cache()
{
    let mut t = terminal(20, 4);
    for i in 0..700 {
        t.feed(format!("冷{i:04} e\u{301}\r\n").as_bytes()).unwrap();
    }
    let doc = t.document().unwrap();
    let before = t.history_stats();
    assert!(before.disk_writes > 0);
    let mut output = Vec::new();
    doc.export_range(point(17, 0), point(20, 0), &mut output)
        .unwrap();
    assert_eq!(
        String::from_utf8(output).unwrap(),
        "冷0017 e\u{301}\n冷0018 e\u{301}\n冷0019 e\u{301}\n"
    );
    let after = t.history_stats();
    assert!((3..=5).contains(&(after.disk_reads - before.disk_reads)));
    assert_eq!(after.resident_history_cells, before.resident_history_cells);
    // The document, not the mutable live viewport, owns this revision's coordinates.
    t.feed(b"\x1b[2Jnew output").unwrap();
    let mut output = Vec::new();
    doc.export_range(point(17, 0), point(18, 0), &mut output)
        .unwrap();
    assert_eq!(String::from_utf8(output).unwrap(), "冷0017 e\u{301}\n");
}

struct RefuseAfter(usize);
impl Write for RefuseAfter {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > self.0 {
            return Err(io::Error::other("synthetic output failure"));
        }
        self.0 -= bytes.len();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn writer_failure_stops_streaming_and_empty_ranges_read_no_cold_rows() {
    let mut t = terminal(20, 4);
    for i in 0..700 {
        t.feed(format!("row{i:04}\r\n").as_bytes()).unwrap();
    }
    let doc = t.document().unwrap();
    let before = t.history_stats().disk_reads;
    doc.export_range(point(17, 0), point(17, 0), &mut Vec::new())
        .unwrap();
    assert_eq!(t.history_stats().disk_reads, before);
    assert!(
        doc.export_range(point(17, 0), point(30, 0), &mut RefuseAfter(3))
            .is_err()
    );
    assert!(t.history_stats().disk_reads - before <= 2);
}

#[test]
fn a_leading_wide_spacer_is_not_text_and_a_split_glyph_end_is_rejected_atomically() {
    let mut t = terminal(5, 3);
    t.feed("abcd甲e\u{301}".as_bytes()).unwrap();
    let doc = t.document().unwrap();
    let mut output = Vec::new();
    doc.export_range(point(0, 0), point(1, 3), &mut output)
        .unwrap();
    assert_eq!(String::from_utf8(output).unwrap(), "abcd甲e\u{301}");
    let mut output = b"original".to_vec();
    assert!(
        doc.export_range(point(0, 0), point(1, 1), &mut output)
            .is_err()
    );
    assert_eq!(output, b"original");
}
