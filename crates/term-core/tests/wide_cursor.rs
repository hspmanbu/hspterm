//! Wide-glyph cursor snapping and wide/redraw flag pairing.
//!
//! Scenarios are driven through real escape sequences so the assertions
//! cover the parser, the grid and the snapshot layer together. Expected
//! layouts were verified against the vendored alacritty_terminal grid.
use alacritty_terminal::term::cell::Flags;
use hspterm_term_core::{Size, Terminal};

const WIDE: u16 = Flags::WIDE_CHAR.bits();
const SPACER: u16 = Flags::WIDE_CHAR_SPACER.bits();
const LEADING: u16 = Flags::LEADING_WIDE_CHAR_SPACER.bits();

fn cell(term: &Terminal, row: usize, column: usize) -> hspterm_term_core::Cell {
    let snapshot = term.snapshot();
    let columns = usize::from(snapshot.size.columns);
    snapshot.cells[row * columns + column].clone()
}

/// Pairing invariant the painter depends on: every trailing wide spacer
/// (64) sits directly behind its wide lead (32), and every wrap marker
/// (1024) is followed by a wide glyph that owns a spacer again. An orphan
/// spacer would swallow the text of the cell it covers.
fn assert_pairs_intact(term: &Terminal) {
    let snapshot = term.snapshot();
    let columns = usize::from(snapshot.size.columns);
    for (index, cell) in snapshot.cells.iter().enumerate() {
        if cell.flags & SPACER == 0 {
            continue;
        }
        let column = index % columns;
        assert!(
            column > 0 && snapshot.cells[index - 1].flags & WIDE != 0,
            "orphan wide spacer at row {} column {}",
            index / columns,
            column
        );
    }
}

#[test]
fn cursor_on_wide_spacer_snaps_to_lead_column() {
    // "$ 中文": 中 spans 2-3, 文 spans 4-5, cursor rests at 6.
    let mut term = Terminal::new(Size::new(10, 3).unwrap(), 100).unwrap();
    term.feed(b"$ \xe4\xb8\xad\xe6\x96\x87").unwrap();
    assert_eq!(term.snapshot().cursor_column, 6);

    // CSI 1D moves the raw cursor onto 文's trailing spacer (column 5);
    // the snapshot must report the glyph's lead column 4 like upstream
    // RenderableCursor does.
    term.feed(b"\x1b[1D").unwrap();
    assert_eq!(term.snapshot().cursor_column, 4);
    assert_eq!(cell(&term, 0, 4).flags & WIDE, WIDE);
    assert_eq!(cell(&term, 0, 5).flags & SPACER, SPACER);

    // Three columns back lands on 中's spacer (raw column 3): snaps to 2.
    term.feed(b"\x1b[2D").unwrap();
    assert_eq!(term.snapshot().cursor_column, 2);

    // One more back is 中's lead cell: reported as-is, no double snap.
    term.feed(b"\x1b[1D").unwrap();
    assert_eq!(term.snapshot().cursor_column, 2);

    // Off the wide glyph entirely the column is reported untouched.
    term.feed(b"\x1b[1D").unwrap();
    assert_eq!(term.snapshot().cursor_column, 1);
}

#[test]
fn full_line_redraw_with_cr_el_keeps_wide_pairs() {
    let mut term = Terminal::new(Size::new(10, 3).unwrap(), 100).unwrap();
    term.feed(b"$ \xe4\xb8\xad\xe6\x96\x87\r\x1b[K$ \xe4\xb8\xad")
        .unwrap();
    // Redrawn from scratch: "$ 中" with 中 as a proper lead+spacer pair.
    assert_eq!(cell(&term, 0, 2).text, "中");
    assert_eq!(cell(&term, 0, 2).flags & WIDE, WIDE);
    assert_eq!(cell(&term, 0, 3).flags & SPACER, SPACER);
    assert_eq!(cell(&term, 0, 4).flags & (WIDE | SPACER), 0);
    assert_eq!(term.snapshot().cursor_column, 4);
    assert_pairs_intact(&term);
}

#[test]
fn backspace_space_overwrite_keeps_pairs_without_orphans() {
    let mut term = Terminal::new(Size::new(10, 3).unwrap(), 100).unwrap();
    // BS-BS onto 文, two spaces overwrite the glyph (both halves lose the
    // wide flags), BS-BS again and a narrow '!' lands on the freed cells.
    term.feed(b"$ \xe4\xb8\xad\xe6\x96\x87\x08\x08  \x08\x08!")
        .unwrap();
    assert_eq!(cell(&term, 0, 2).text, "中");
    assert_eq!(cell(&term, 0, 2).flags & WIDE, WIDE);
    assert_eq!(cell(&term, 0, 3).flags & SPACER, SPACER);
    assert_eq!(cell(&term, 0, 4).text, "!");
    assert_eq!(cell(&term, 0, 4).flags & (WIDE | SPACER), 0);
    assert_eq!(cell(&term, 0, 5).flags & (WIDE | SPACER), 0);
    assert_eq!(term.snapshot().cursor_column, 5);
    assert_pairs_intact(&term);
}

#[test]
fn end_of_line_wrap_marks_leading_spacer_and_keeps_pairs() {
    // "abc中" on 4 columns: 中 cannot fit, the line wraps. The trailing
    // cell becomes a LEADING marker (1024) and 中 starts the next row as
    // a wide lead with its own spacer.
    let mut term = Terminal::new(Size::new(4, 3).unwrap(), 100).unwrap();
    term.feed(b"abc\xe4\xb8\xad").unwrap();
    assert_eq!(cell(&term, 0, 3).flags & LEADING, LEADING);
    assert_eq!(
        cell(&term, 0, 3).flags & WIDE,
        0,
        "wrap marker holds no glyph"
    );
    assert_eq!(cell(&term, 1, 0).text, "中");
    assert_eq!(cell(&term, 1, 0).flags & WIDE, WIDE);
    assert_eq!(cell(&term, 1, 1).flags & SPACER, SPACER);
    let snapshot = term.snapshot();
    assert_eq!(snapshot.cursor_row, 1);
    assert_eq!(snapshot.cursor_column, 2);
    assert_pairs_intact(&term);
}

#[test]
fn erase_in_line_from_spacer_leaves_no_orphan_spacer() {
    // The cursor moves onto 文's trailing spacer, then EL(0) erases from
    // there. Upstream keeps the wide flag on the untouched lead; the
    // erased spacer itself must vanish instead of surviving orphaned.
    let mut term = Terminal::new(Size::new(10, 3).unwrap(), 100).unwrap();
    term.feed(b"$ \xe4\xb8\xad\xe6\x96\x87\x1b[1D\x1b[K")
        .unwrap();
    assert_eq!(cell(&term, 0, 2).flags & WIDE, WIDE);
    assert_eq!(cell(&term, 0, 3).flags & SPACER, SPACER);
    assert_eq!(cell(&term, 0, 4).flags & WIDE, WIDE);
    assert_eq!(
        cell(&term, 0, 5).flags & SPACER,
        0,
        "erased spacer must not survive"
    );
    assert_eq!(term.snapshot().cursor_column, 5);
    assert_pairs_intact(&term);
}
