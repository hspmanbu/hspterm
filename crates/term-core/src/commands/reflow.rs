//! Re-anchor only a verified, unchanged logical text stream. No terminal cell
//! mutation, whole-output copies, persistent hashes, or repeated-text guessing.
//! Truncation, ambiguous padding or work-budget exhaustion fails closed.
use super::*;
use alacritty_terminal::term::cell::Flags;
use sha2::{Digest, Sha256};
use std::time::{Duration, Instant};

const MAX_CELLS: usize = 16 * 1024 * 1024;
const MAX_BYTES: u64 = 64 * 1024 * 1024;
const SCAN_TIME: Duration = Duration::from_millis(250);
#[derive(PartialEq, Eq)]
struct Signature {
    hash: [u8; 32],
    bytes: u64,
}
struct PreparedRange {
    id: u64,
    start: u64,
    end: u64,
    prompt: Option<u64>,
    exit_status: Option<u8>,
}
pub(crate) struct Reflow {
    sequence: u64,
    signature: Signature,
    ranges: Vec<PreparedRange>,
}

// New empty viewport rows do not change content. Delay hard newlines and keep
// only the first trailing newline; interior blank lines remain significant.
struct Stream {
    hash: Sha256,
    offset: u64,
    pending: u64,
    content: bool,
}
impl Stream {
    fn flush_newlines(&mut self, mut count: u64) {
        const NEWLINES: [u8; 256] = [b'\n'; 256];
        while count != 0 {
            let length = count.min(NEWLINES.len() as u64) as usize;
            self.hash.update(&NEWLINES[..length]);
            count -= length as u64;
        }
    }
    fn character(&mut self, character: char) {
        self.flush_newlines(self.pending);
        self.pending = 0;
        let mut utf8 = [0; 4];
        let bytes = character.encode_utf8(&mut utf8).as_bytes();
        self.hash.update(bytes);
        self.offset += bytes.len() as u64;
        self.content = true;
    }
    fn newline(&mut self) {
        self.pending += 1;
        self.offset += 1;
    }
    fn finish(mut self) -> Signature {
        let trailing = u64::from(self.content && self.pending != 0);
        self.flush_newlines(trailing);
        Signature {
            hash: self.hash.finalize().into(),
            bytes: self.offset - self.pending + trailing,
        }
    }
}
fn scan(
    grid: &Grid<Cell>,
    columns: u16,
    mut visit: impl FnMut(TextPoint, u64),
) -> Option<Signature> {
    let rows = grid.total_lines();
    if rows.checked_mul(usize::from(columns))? > MAX_CELLS {
        return None;
    }
    let started = Instant::now();
    let mut stream = Stream {
        hash: Sha256::new(),
        offset: 0,
        pending: 0,
        content: false,
    };
    for row in 0..rows {
        if row.is_multiple_of(32) && started.elapsed() > SCAN_TIME {
            return None;
        }
        let cells = grid[Line(i32::try_from(row as i128 - grid.history_size() as i128).ok()?)]
            .owned_cells();
        if cells.len() != columns as usize {
            return None;
        }
        let wrap = cells
            .last()
            .is_some_and(|c| c.flags.contains(Flags::WRAPLINE));
        let limit = if wrap {
            cells.len()
        } else {
            cells
                .iter()
                .rposition(|c| {
                    !c.flags
                        .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
                        && (c.c != ' ' || c.zerowidth().is_some_and(|extra| !extra.is_empty()))
                })
                .map_or(0, |i| {
                    (i + 1 + usize::from(cells[i].flags.contains(Flags::WIDE_CHAR)))
                        .min(cells.len())
                })
        };
        for (column, cell) in cells.iter().enumerate().take(limit) {
            if column.is_multiple_of(1024) && started.elapsed() > SCAN_TIME {
                return None;
            }
            if cell
                .flags
                .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }
            visit(
                TextPoint {
                    row: u32::try_from(row).ok()?,
                    column: u16::try_from(column).ok()?,
                },
                stream.offset,
            );
            stream.character(cell.c);
            if let Some(extra) = cell.zerowidth() {
                for (index, character) in extra.iter().enumerate() {
                    if index.is_multiple_of(1024)
                        && (started.elapsed() > SCAN_TIME || stream.offset > MAX_BYTES)
                    {
                        return None;
                    }
                    stream.character(*character);
                }
            }
        }
        // This is outside a wide glyph, even when limit ends at its spacer.
        visit(
            TextPoint {
                row: u32::try_from(row).ok()?,
                column: u16::try_from(limit).ok()?,
            },
            stream.offset,
        );
        if !wrap {
            stream.newline();
        }
        if stream.offset > MAX_BYTES {
            return None;
        }
    }
    if started.elapsed() > SCAN_TIME {
        return None;
    }
    Some(stream.finish())
}
fn offsets(
    grid: &Grid<Cell>,
    columns: u16,
    points: &[TextPoint],
) -> Option<(Signature, Vec<Option<u64>>)> {
    let mut wanted: Vec<_> = points
        .iter()
        .enumerate()
        .map(|(i, p)| ((p.row, p.column), i))
        .collect();
    wanted.sort_unstable();
    let mut result = vec![None; points.len()];
    let mut cursor = 0;
    let signature = scan(grid, columns, |point, offset| {
        while cursor < wanted.len() && wanted[cursor].0 <= (point.row, point.column) {
            if wanted[cursor].0 == (point.row, point.column) {
                result[wanted[cursor].1] = Some(offset);
            }
            cursor += 1;
        }
    })?;
    for offset in &mut result {
        if offset.is_some_and(|value| value > signature.bytes) {
            *offset = None;
        }
    }
    Some((signature, result))
}
fn points(
    grid: &Grid<Cell>,
    columns: u16,
    offsets: &[u64],
) -> Option<(Signature, Vec<Option<TextPoint>>)> {
    let mut wanted: Vec<_> = offsets
        .iter()
        .copied()
        .enumerate()
        .map(|(i, offset)| (offset, i))
        .collect();
    wanted.sort_unstable();
    let mut result = vec![None; offsets.len()];
    let mut cursor = 0;
    let signature = scan(grid, columns, |point, offset| {
        while cursor < wanted.len() && wanted[cursor].0 <= offset {
            if wanted[cursor].0 == offset {
                result[wanted[cursor].1] = Some(point);
            }
            cursor += 1;
        }
    })?;
    for (index, value) in result.iter_mut().enumerate() {
        if offsets[index] > signature.bytes {
            *value = None;
        }
    }
    Some((signature, result))
}
impl Commands {
    pub fn prepare_reflow(&mut self, grid: &Grid<Cell>, columns: u16) -> Option<Reflow> {
        self.abort(); // A partly edited/executing command is never promoted.
        let valid = self.ranges(grid, columns);
        self.retained.clear();
        self.proof_rows = 0;
        if valid.is_empty() {
            return None;
        }
        let locations: Vec<_> = valid
            .iter()
            .flat_map(|r| [Some(r.start), Some(r.end), r.prompt])
            .flatten()
            .collect();
        let (signature, positions) = offsets(grid, columns, &locations)?;
        let mut cursor = 0;
        let mut ranges = Vec::with_capacity(valid.len());
        for range in valid {
            let start = positions[cursor];
            let end = positions[cursor + 1];
            cursor += 2;
            let prompt = if range.prompt.is_some() {
                let p = positions[cursor];
                cursor += 1;
                p
            } else {
                None
            };
            if let (Some(start), Some(end)) = (start, end) {
                ranges.push(PreparedRange {
                    id: range.id,
                    start,
                    end,
                    prompt,
                    exit_status: range.exit_status,
                });
            }
        }
        Some(Reflow {
            sequence: self.sequence,
            signature,
            ranges,
        })
    }
    pub fn restore_reflow(&mut self, reflow: Option<Reflow>, grid: &Grid<Cell>, columns: u16) {
        let Some(reflow) = reflow else {
            return;
        };
        if reflow.sequence != self.sequence || !self.retained.is_empty() {
            return;
        }
        let offsets: Vec<_> = reflow
            .ranges
            .iter()
            .flat_map(|r| [Some(r.start), Some(r.end), r.prompt])
            .flatten()
            .collect();
        let Some((signature, locations)) = points(grid, columns, &offsets) else {
            return;
        };
        if signature != reflow.signature {
            return;
        }
        let anchor = |point: TextPoint| -> Option<Anchor> {
            let line = i32::try_from(i128::from(point.row) - grid.history_size() as i128).ok()?;
            let row_identity = grid[Line(line)].proof().0;
            (row_identity != 0).then_some(Anchor {
                row: i128::from(grid.history_scrolls()) + i128::from(line),
                column: usize::from(point.column),
                row_identity,
            })
        };
        let mut cursor = 0;
        for range in reflow.ranges {
            let start = locations[cursor];
            let end = locations[cursor + 1];
            cursor += 2;
            let prompt = if range.prompt.is_some() {
                let p = locations[cursor];
                cursor += 1;
                p.and_then(anchor)
            } else {
                None
            };
            let (Some(start), Some(end)) = (start, end) else {
                continue;
            };
            let tail_end = end.row as usize + usize::from(end.column != 0);
            let tail: Vec<_> = (usize::max(start.row as usize, grid.history_size())..tail_end)
                .map(|row| {
                    let line = row as i32 - grid.history_size() as i32;
                    (
                        i128::from(grid.history_scrolls()) + i128::from(line),
                        grid[Line(line)].proof(),
                    )
                })
                .collect();
            if tail.len() > MAX_MUTABLE_PROOFS {
                continue;
            }
            let (Some(start), Some(end)) = (anchor(start), anchor(end)) else {
                continue;
            };
            while self.proof_rows + tail.len() > MAX_MUTABLE_PROOFS
                || self.retained.len() >= MAX_COMMANDS
            {
                let Some(old) = self.retained.pop_front() else {
                    break;
                };
                self.proof_rows -= old.tail.len();
            }
            self.proof_rows += tail.len();
            self.retained.push_back(Retained {
                id: range.id,
                prompt,
                start,
                end,
                exit_status: range.exit_status,
                tail,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Size, Terminal};
    #[test]
    fn offsets_never_point_inside_a_wide_cell_or_a_combining_sequence() {
        let mut terminal = Terminal::new(Size::new(12, 5).unwrap(), 100).unwrap();
        terminal.feed("中e\u{301}".as_bytes()).unwrap();
        let grid = terminal.term.grid();
        let locations: Vec<_> = (0..4).map(|column| TextPoint { row: 0, column }).collect();
        let (before, mapped) = offsets(grid, 12, &locations).unwrap();
        assert_eq!(mapped, vec![Some(0), None, Some(3), Some(6)]);
        let (after, mapped) = points(grid, 12, &[0, 3, 4, 6]).unwrap();
        assert!(before == after);
        assert_eq!(
            mapped,
            vec![
                Some(locations[0]),
                Some(locations[2]),
                None,
                Some(locations[3])
            ]
        );
    }
    #[test]
    fn viewport_padding_is_not_command_text_or_a_source_of_guessed_positions() {
        let mut a = Terminal::new(Size::new(12, 3).unwrap(), 100).unwrap();
        let mut b = Terminal::new(Size::new(12, 8).unwrap(), 100).unwrap();
        a.feed(b"xy").unwrap();
        b.feed(b"xy").unwrap();
        let a_grid = a.term.grid();
        let b_grid = b.term.grid();
        let (one, mapped) = offsets(
            a_grid,
            12,
            &[
                TextPoint { row: 0, column: 3 },
                TextPoint { row: 1, column: 0 },
                TextPoint { row: 2, column: 0 },
            ],
        )
        .unwrap();
        let two = scan(b_grid, 12, |_, _| {}).unwrap();
        assert!(one == two);
        assert_eq!(one.bytes, 3);
        assert_eq!(mapped, vec![None, Some(3), None]);
    }
}
