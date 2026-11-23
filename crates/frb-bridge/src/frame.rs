use crate::api::{RenderCell, RenderFrame, RenderHyperlink, RenderRow};
pub(crate) use hspterm_term_core::default_color as base_color;
use hspterm_term_core::{Cell, CellColor, FrameFingerprint, Snapshot};

mod hyperlinks;

fn palette(snapshot: &Snapshot, index: usize) -> u32 {
    match snapshot.palette.get(index).copied().flatten() {
        Some([r, g, b]) => 0xff000000 | (u32::from(r) << 16) | (u32::from(g) << 8) | u32::from(b),
        None => base_color(index),
    }
}
fn color(snapshot: &Snapshot, color: &CellColor) -> u32 {
    match color {
        CellColor::Named(i) => palette(snapshot, *i as usize),
        CellColor::Indexed(i) => palette(snapshot, *i as usize),
        CellColor::Rgb(r, g, b) => {
            0xff000000 | (u32::from(*r) << 16) | (u32::from(*g) << 8) | u32::from(*b)
        }
    }
}
pub(crate) fn changed_rows<'a>(
    previous: Option<&'a FrameFingerprint>,
    current: &'a FrameFingerprint,
) -> impl Iterator<Item = u16> + 'a {
    let full =
        previous.is_none_or(|p| p.content != current.content || p.rows.len() != current.rows.len());
    (0..current.rows.len())
        .filter(move |i| full || previous.is_none_or(|p| p.rows[*i] != current.rows[*i]))
        .map(|i| i as u16)
}

pub(crate) fn delta(
    previous: Option<&FrameFingerprint>,
    mut snapshot: Snapshot,
    current: &FrameFingerprint,
) -> RenderFrame {
    // Row filtering compares the grid-borrowed fingerprints; a scalar
    // mismatch (size/palette/cursor/mode...) or a different row count
    // republishes everything, matching the previous full-snapshot semantics.
    let full =
        previous.is_none_or(|p| p.content != current.content || p.rows.len() != current.rows.len());
    let columns = usize::from(snapshot.size.columns);
    let mut link_budget = hyperlinks::Budget::default();
    // Decoration has already inspected the complete snapshot. Transfer the
    // owned strings to FRB instead of allocating a second string per changed
    // cell; unchanged rows are dropped here, never sent across the bridge.
    let mut cells = std::mem::take(&mut snapshot.cells);
    let changed_rows = cells
        .chunks_mut(columns)
        .enumerate()
        .filter(|(i, _row)| full || previous.is_none_or(|p| p.rows[*i] != current.rows[*i]))
        .map(|(i, row)| RenderRow {
            index: i as u16,
            hyperlinks: Some(hyperlinks::spans(row, &mut link_budget)),
            cells: row
                .iter_mut()
                .map(|c| RenderCell {
                    text: std::mem::take(&mut c.text),
                    foreground: {
                        let value = color(&snapshot, &c.foreground);
                        if c.flags & 128 != 0 {
                            0xff000000
                                | (((value >> 16 & 255) * 2 / 3) << 16)
                                | (((value >> 8 & 255) * 2 / 3) << 8)
                                | ((value & 255) * 2 / 3)
                        } else {
                            value
                        }
                    },
                    background: color(&snapshot, &c.background),
                    flags: c.flags,
                })
                .collect(),
        })
        .collect();
    RenderFrame {
        revision: snapshot.revision,
        content_revision: snapshot.content_revision,
        output_lines: snapshot.output_lines,
        size_locked: snapshot.size_locked,
        same_word_enabled: None,
        same_word_case_sensitive: None,
        decorations_limited: None,
        search_revision: None,
        search_spans: Vec::new(),
        columns: snapshot.size.columns,
        rows: snapshot.size.rows,
        full,
        changed_rows,
        cursor_column: snapshot.cursor_column as u16,
        cursor_row: snapshot.cursor_row,
        cursor_visible: snapshot.cursor_visible,
        cursor_shape: snapshot.cursor_shape,
        cursor_blink: snapshot.cursor_blink,
        osc52_enabled: Some(snapshot.osc52_enabled),
        right_click_paste: Some(snapshot.right_click_paste),
        copy_on_selection: Some(snapshot.copy_on_selection),
        image_paste_shortcut: Some(snapshot.image_paste_shortcut.clone()),
        cursor_color: palette(&snapshot, 258),
        background: palette(&snapshot, 257),
        alternate_screen: snapshot.alternate_screen,
        mouse_reporting: snapshot.mouse_reporting,
        history_lines: snapshot.history_lines as u32,
        display_offset: snapshot.display_offset as u32,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use hspterm_term_core::{Size, Terminal};
    #[test]
    fn bridge_rows_take_ownership_of_text_allocations_without_copying() {
        let mut t = Terminal::new(Size::new(24, 4).unwrap(), 10).unwrap();
        t.feed("中文 e\u{301} \x1b[38;2;12;34;56mtruecolor".as_bytes())
            .unwrap();
        let snapshot = t.snapshot();
        let texts: Vec<_> = snapshot
            .cells
            .iter()
            .map(|c| (c.text.as_ptr(), c.text.len()))
            .collect();
        let fingerprint = t.frame_fingerprint();
        let indices: Vec<_> = changed_rows(None, &fingerprint).collect();
        let frame = delta(None, snapshot, &fingerprint);
        assert_eq!(
            frame
                .changed_rows
                .iter()
                .map(|r| r.index)
                .collect::<Vec<_>>(),
            indices
        );
        let delivered: Vec<_> = frame
            .changed_rows
            .iter()
            .flat_map(|r| &r.cells)
            .map(|c| (c.text.as_ptr(), c.text.len()))
            .collect();
        assert_eq!(
            delivered, texts,
            "every owned cell buffer must move into its DTO"
        );
        assert!(
            frame.changed_rows[0]
                .cells
                .iter()
                .any(|c| c.foreground == 0xff0c2238)
        );
    }
    #[test]
    fn osc8_span_changes_are_published_even_when_label_and_colors_stay_the_same() {
        let mut t = Terminal::new(Size::new(24, 4).unwrap(), 10).unwrap();
        t.feed(b"\x1b]8;id=x;https://example.invalid/a\x1b\\same\x1b]8;;\x1b\\")
            .unwrap();
        let first = t.snapshot();
        let first_fp = t.frame_fingerprint();
        let links = delta(None, first.clone(), &first_fp).changed_rows[0]
            .hyperlinks
            .clone()
            .unwrap();
        assert_eq!((links[0].start, links[0].end), (0, 4));
        assert_eq!(links[0].uri.as_deref(), Some("https://example.invalid/a"));
        t.feed(b"\r\x1b]8;id=x;https://example.invalid/b\x1b\\same\x1b]8;;\x1b\\")
            .unwrap();
        let next = t.snapshot();
        let next_fp = t.frame_fingerprint();
        let patch = delta(Some(&first_fp), next.clone(), &next_fp);
        assert_eq!(patch.changed_rows.len(), 1);
        assert_eq!(
            patch.changed_rows[0].hyperlinks.as_ref().unwrap()[0]
                .uri
                .as_deref(),
            Some("https://example.invalid/b")
        );
        assert!(
            delta(Some(&next_fp), next.clone(), &next_fp)
                .changed_rows
                .is_empty()
        );
        t.feed(b"\rsame").unwrap();
        assert!(
            delta(Some(&next_fp), t.snapshot(), &t.frame_fingerprint()).changed_rows[0]
                .hyperlinks
                .as_ref()
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn changes_only_changed_rows_and_resolves_palette_and_cursor() {
        let mut t = Terminal::new(Size::new(20, 4).unwrap(), 10).unwrap();
        let first = t.snapshot();
        let first_fp = t.frame_fingerprint();
        assert!(delta(None, first.clone(), &first_fp).full);
        t.feed(b"\x1b[2;1H\x1b[38;5;196mred\x1b[6 q").unwrap();
        let next = t.snapshot();
        let next_fp = t.frame_fingerprint();
        let patch = delta(Some(&first_fp), next.clone(), &next_fp);
        assert!(!patch.full);
        assert_eq!(patch.changed_rows.len(), 1);
        assert_eq!(patch.changed_rows[0].index, 1);
        assert_eq!(patch.changed_rows[0].cells[0].foreground, 0xffff0000);
        assert_eq!(patch.cursor_shape, 2);
        assert!(!patch.cursor_blink);
        assert!(
            delta(Some(&next_fp), next.clone(), &next_fp)
                .changed_rows
                .is_empty()
        );
    }
}
