//! Current-terminal search/export over a frozen grid. No SSH commands are sent.
use crate::TerminalError;
use alacritty_terminal::{
    grid::{Dimensions, Grid, RowBacking},
    index::Line,
    term::cell::{Cell, Flags},
};
use regex::{Regex, RegexBuilder};
use std::{
    collections::HashMap,
    io::{self, Write},
    sync::Arc,
};
use zeroize::Zeroizing;

pub struct SearchDocument {
    pub revision: u64,
    pub columns: u16,
    pub history_lines: usize,
    rows: Vec<FrozenRow>,
    pub(crate) check: Arc<dyn Fn() -> io::Result<()> + Send + Sync>,
}
// Search/export do not need cursor state, row mutation proofs, spare capacity
// or decoded viewport caches from Grid. Cold pages are immutable/shared; only
// hot cells need a copy to preserve the captured terminal revision.
enum FrozenRow {
    Hot(Vec<Cell>),
    Cold(Arc<dyn RowBacking<Cell>>),
}
impl SearchDocument {
    pub(crate) fn capture(
        revision: u64,
        columns: u16,
        history_lines: usize,
        grid: &Grid<Cell>,
        check: Arc<dyn Fn() -> io::Result<()> + Send + Sync>,
    ) -> Self {
        let rows = (0..grid.total_lines())
            .map(|row| {
                let source = &grid[Line(row as i32 - history_lines as i32)];
                match source.frozen_page() {
                    Some(page) => FrozenRow::Cold(page),
                    None => FrozenRow::Hot(source.owned_cells()),
                }
            })
            .collect();
        Self {
            revision,
            columns,
            history_lines,
            rows,
            check,
        }
    }
    pub fn rows(&self) -> usize {
        self.rows.len()
    }
    pub fn row(&self, index: usize) -> Result<Vec<Cell>, TerminalError> {
        if index >= self.rows() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "历史行位置已失效").into());
        }
        (self.check)()?;
        let cells = match &self.rows[index] {
            FrozenRow::Hot(cells) => cells.clone(),
            FrozenRow::Cold(page) => page.load(),
        };
        (self.check)()?;
        Ok(cells)
    }
    /// Stream plain UTF-8 without synthetic reconnect/search/highlight markers.
    pub fn export<W: Write>(&self, writer: &mut W) -> Result<(), TerminalError> {
        for row in 0..self.rows() {
            let cells = self.row(row)?;
            let (text, wrap) = row_text(&cells);
            writer.write_all(text.as_bytes())?;
            if !wrap && row + 1 < self.rows() {
                writer.write_all(b"\n")?;
            }
        }
        Ok(())
    }

    /// Stream a half-open cell range from this frozen revision. Callers must
    /// establish the range's provenance; this does not infer command boundaries.
    /// Intermediate hard-line padding is trimmed, soft wraps add no newline,
    /// and the explicit final column preserves selected trailing spaces.
    pub fn export_range<W: Write>(
        &self,
        start: TextPoint,
        end: TextPoint,
        writer: &mut W,
    ) -> Result<(), TerminalError> {
        let invalid = || {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "文字范围已失效或位于宽字符内部",
            )
        };
        if start.row as usize >= self.rows()
            || end.row as usize >= self.rows()
            || start.column > self.columns
            || end.column > self.columns
            || (start.row, start.column) > (end.row, end.column)
        {
            return Err(invalid().into());
        }
        if start == end {
            return Ok(());
        }
        let mut first = Some(self.row(start.row as usize)?);
        let aligned = |cells: &[Cell], column: u16| {
            cells.len() == self.columns as usize
                && !cells
                    .get(column as usize)
                    .is_some_and(|c| c.flags.contains(Flags::WIDE_CHAR_SPACER))
        };
        if !aligned(first.as_ref().unwrap(), start.column) {
            return Err(invalid().into());
        }
        let mut last = if end.row != start.row && end.column != 0 {
            Some(self.row(end.row as usize)?)
        } else {
            None
        };
        let end_cells = if end.row == start.row {
            first.as_ref()
        } else {
            last.as_ref()
        };
        if end_cells.is_some_and(|cells| !aligned(cells, end.column)) {
            return Err(invalid().into());
        }
        let mut utf8 = [0; 4];
        for row in start.row..=end.row {
            if row == end.row && end.column == 0 {
                break;
            }
            let cells = if row == start.row {
                first.take().unwrap()
            } else if row == end.row {
                last.take().unwrap()
            } else {
                self.row(row as usize)?
            };
            if cells.len() != self.columns as usize {
                return Err(invalid().into());
            }
            let begin = if row == start.row {
                start.column as usize
            } else {
                0
            };
            let mut limit = if row == end.row {
                end.column as usize
            } else {
                cells.len()
            };
            let wrap = cells
                .last()
                .is_some_and(|c| c.flags.contains(Flags::WRAPLINE));
            if row != end.row && !wrap {
                limit = cells
                    .iter()
                    .rposition(|cell| {
                        !cell
                            .flags
                            .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
                            && (cell.c != ' '
                                || cell.zerowidth().is_some_and(|chars| !chars.is_empty()))
                    })
                    .map_or(0, |i| i + 1);
            }
            if begin < limit {
                for cell in &cells[begin..limit] {
                    if cell
                        .flags
                        .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
                    {
                        continue;
                    }
                    writer.write_all(cell.c.encode_utf8(&mut utf8).as_bytes())?;
                    if let Some(chars) = cell.zerowidth() {
                        for character in chars {
                            writer.write_all(character.encode_utf8(&mut utf8).as_bytes())?;
                        }
                    }
                }
            }
            if row < end.row && !wrap {
                writer.write_all(b"\n")?;
            }
        }
        (self.check)()?;
        Ok(())
    }
    pub fn search(
        self,
        query: &str,
        regular_expression: bool,
        case_sensitive: bool,
    ) -> Result<SearchIndex, SearchError> {
        self.search_cancellable(query, regular_expression, case_sensitive, || false)
    }
    pub fn search_cancellable(
        self,
        query: &str,
        regular_expression: bool,
        case_sensitive: bool,
        cancelled: impl Fn() -> bool,
    ) -> Result<SearchIndex, SearchError> {
        if query.is_empty() {
            return Err(SearchError::Query("请输入搜索文本".into()));
        }
        if query.len() > 4096 {
            return Err(SearchError::Query("搜索表达式过长".into()));
        }
        let pattern = if regular_expression {
            query.to_owned()
        } else {
            regex::escape(query)
        };
        let regex = RegexBuilder::new(&pattern)
            .case_insensitive(!case_sensitive)
            .size_limit(10 * 1024 * 1024)
            .dfa_size_limit(8 * 1024 * 1024)
            .build()
            .map_err(|_| SearchError::Query("无效或过于复杂的正则表达式".into()))?;
        let mut corpus = Zeroizing::new(String::new());
        let mut row_offsets = Vec::with_capacity(self.rows());
        let mut layouts = Vec::with_capacity(self.rows());
        let mut widths = PackedWidths::default();
        let mut gaps = Vec::new();
        for row in 0..self.rows() {
            if cancelled() {
                return Err(SearchError::Cancelled);
            }
            row_offsets.push(corpus.len());
            let cells = self.row(row)?;
            let (text, wrap) = row_text(&cells);
            layouts.push(RowLayout::capture(&cells, &text, &mut widths, &mut gaps)?);
            corpus.push_str(&text);
            if !wrap && row + 1 < self.rows() {
                corpus.push('\n');
            }
            if corpus.len() > 256 * 1024 * 1024 {
                return Err(SearchError::Query(
                    "当前搜索文本超过256MiB工作量限制".into(),
                ));
            }
        }
        // Scanning/counting and buffer compaction no longer need the frozen
        // cells. Release them before a realloc can briefly hold both buffers.
        let rows = self.rows();
        let revision = self.revision;
        let check = self.check.clone();
        drop(self);
        corpus.shrink_to_fit();
        widths.bytes.shrink_to_fit();
        gaps.shrink_to_fit();
        let mut cursor = MatchCursor::default();
        let mut checkpoints = Vec::new();
        let mut count = 0u32;
        let mut row = 0usize;
        let mut markers = vec![0u32; 128];
        loop {
            if count.is_multiple_of(4096) && cancelled() {
                return Err(SearchError::Cancelled);
            }
            let before = cursor;
            let Some((start, _)) = cursor.next(&regex, &corpus) else {
                break;
            };
            if count.is_multiple_of(512) {
                checkpoints.push(before);
            }
            while row + 1 < row_offsets.len() && row_offsets[row + 1] <= start {
                row += 1;
            }
            markers[row * 128 / rows.max(1)] += 1;
            count += 1;
        }
        checkpoints.shrink_to_fit();
        Ok(SearchIndex {
            revision,
            check,
            layouts,
            widths,
            gaps,
            corpus,
            regex,
            row_offsets,
            checkpoints,
            count,
            markers,
        })
    }
}
fn row_text(cells: &[Cell]) -> (String, bool) {
    let wrap = cells
        .last()
        .is_some_and(|c| c.flags.contains(Flags::WRAPLINE));
    let mut text = String::new();
    for cell in cells {
        if cell
            .flags
            .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
        {
            continue;
        }
        text.push(cell.c);
        if let Some(extra) = cell.zerowidth() {
            text.extend(extra.iter());
        }
    }
    if !wrap {
        text.truncate(text.trim_end_matches(' ').len());
    }
    (text, wrap)
}
#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    #[error("{0}")]
    Query(String),
    #[error("搜索已取消")]
    Cancelled,
    #[error(transparent)]
    Terminal(#[from] TerminalError),
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TextPoint {
    pub row: u32,
    pub column: u16,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchHit {
    pub start: TextPoint,
    pub end: TextPoint,
}
#[derive(Clone, Copy, Default)]
struct MatchCursor {
    offset: usize,
    last_nonempty_end: Option<usize>,
    finished: bool,
}
impl MatchCursor {
    fn next(&mut self, regex: &Regex, text: &str) -> Option<(usize, usize)> {
        while !self.finished {
            let found = regex.find_at(text, self.offset)?;
            let (start, end) = (found.start(), found.end());
            if start == end {
                self.offset = end;
                if let Some(c) = text[end..].chars().next() {
                    self.offset += c.len_utf8();
                } else {
                    self.finished = true;
                }
                if self.last_nonempty_end == Some(end) {
                    continue;
                }
            } else {
                self.offset = end;
                self.last_nonempty_end = Some(end);
            }
            return Some((start, end));
        }
        None
    }
}
/// Two bits per scalar preserve the terminal's *actual* cell widths. Zero
/// denotes a combining scalar belonging to the previous cell; ASCII rows need
/// no width payload. No Unicode-width heuristic is used when mapping hits.
#[derive(Default)]
struct PackedWidths {
    bytes: Vec<u8>,
    count: usize,
}
impl PackedWidths {
    fn push(&mut self, width: u8) {
        if self.count.is_multiple_of(4) {
            self.bytes.push(0);
        }
        self.bytes[self.count / 4] |= width << ((self.count % 4) * 2);
        self.count += 1;
    }
    fn get(&self, index: usize) -> u8 {
        (self.bytes[index / 4] >> ((index % 4) * 2)) & 3
    }
}
struct RowGap {
    scalar: u32,
    column: u16,
}
struct RowLayout {
    codes: u32,
    bytes: u32,
    gaps: u32,
    gap_count: u16,
    tail_start: u16,
    tail_end: u16,
}
impl RowLayout {
    fn capture(
        cells: &[Cell],
        text: &str,
        widths: &mut PackedWidths,
        gaps: &mut Vec<RowGap>,
    ) -> Result<Self, SearchError> {
        let bytes =
            u32::try_from(text.len()).map_err(|_| SearchError::Query("搜索行过长".into()))?;
        let mut result = Self {
            codes: u32::MAX,
            bytes,
            gaps: 0,
            gap_count: 0,
            tail_start: 0,
            tail_end: 0,
        };
        if cells.iter().all(|c| {
            c.c.is_ascii()
                && c.zerowidth().is_none_or(|z| z.is_empty())
                && !c.flags.intersects(
                    Flags::WIDE_CHAR | Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER,
                )
        }) {
            result.tail_start = text.len() as u16;
            result.tail_end = result.tail_start;
            return Ok(result);
        }
        result.codes = u32::try_from(widths.count)
            .map_err(|_| SearchError::Query("搜索位置索引过大".into()))?;
        result.gaps =
            u32::try_from(gaps.len()).map_err(|_| SearchError::Query("搜索位置索引过大".into()))?;
        let mut tail_start = None;
        let mut tail_end = None;
        let mut byte = 0;
        let mut scalar = 0;
        let mut expected_column = 0;
        for (column, cell) in cells.iter().enumerate() {
            if cell
                .flags
                .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
            {
                continue;
            }
            let indexed = byte < text.len();
            if indexed && column != expected_column {
                gaps.push(RowGap {
                    scalar,
                    column: column as u16,
                });
            }
            let width = if cell.flags.contains(Flags::WIDE_CHAR) {
                2
            } else {
                1
            };
            if indexed {
                widths.push(width);
                scalar += 1;
            }
            let mut length = cell.c.len_utf8();
            if let Some(extra) = cell.zerowidth() {
                for c in extra {
                    if indexed {
                        widths.push(0);
                        scalar += 1;
                    }
                    length += c.len_utf8();
                }
            }
            let right = column + width as usize;
            if tail_start.is_none() && byte + length > text.len() {
                tail_start = Some(column as u16);
            }
            if tail_end.is_none() && byte + length >= text.len() {
                tail_end = Some(if byte == text.len() {
                    column as u16
                } else {
                    right as u16
                });
            }
            byte += length;
            expected_column = right;
        }
        result.gap_count = u16::try_from(gaps.len() - result.gaps as usize)
            .map_err(|_| SearchError::Query("搜索行位置过多".into()))?;
        result.tail_start = tail_start.unwrap_or(expected_column as u16);
        result.tail_end = tail_end.unwrap_or(expected_column as u16);
        Ok(result)
    }
}
fn column_at(map: &[(usize, usize, u16, u16)], target: usize, end: bool) -> u16 {
    let index = map.partition_point(|(_, right, _, _)| *right < target || !end && *right == target);
    if let Some(&(left, _, column, right)) = map.get(index) {
        if target == left || !end {
            column
        } else {
            right
        }
    } else {
        map.last().map_or(0, |c| c.3)
    }
}
type PointMaps = HashMap<usize, Vec<(usize, usize, u16, u16)>>;
pub struct SearchIndex {
    revision: u64,
    check: Arc<dyn Fn() -> io::Result<()> + Send + Sync>,
    layouts: Vec<RowLayout>,
    widths: PackedWidths,
    gaps: Vec<RowGap>,
    corpus: Zeroizing<String>,
    regex: Regex,
    row_offsets: Vec<usize>,
    checkpoints: Vec<MatchCursor>,
    pub count: u32,
    pub markers: Vec<u32>,
}
impl SearchIndex {
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn rows(&self) -> usize {
        self.layouts.len()
    }
    fn point(
        &self,
        byte: usize,
        end: bool,
        maps: &mut PointMaps,
    ) -> Result<TextPoint, SearchError> {
        (self.check)().map_err(TerminalError::from)?;
        let row = self
            .row_offsets
            .partition_point(|offset| *offset <= byte)
            .saturating_sub(1)
            .min(self.rows() - 1);
        let layout = &self.layouts[row];
        let target = byte - self.row_offsets[row];
        let column = if target >= layout.bytes as usize {
            if end {
                layout.tail_end
            } else {
                layout.tail_start
            }
        } else if layout.codes == u32::MAX {
            target as u16
        } else {
            if let std::collections::hash_map::Entry::Vacant(entry) = maps.entry(row) {
                let text = &self.corpus
                    [self.row_offsets[row]..self.row_offsets[row] + layout.bytes as usize];
                let gaps = &self.gaps
                    [layout.gaps as usize..layout.gaps as usize + layout.gap_count as usize];
                let mut gap = 0;
                let mut column = 0u16;
                let mut map = Vec::<(usize, usize, u16, u16)>::new();
                for (scalar, (start, c)) in text.char_indices().enumerate() {
                    if gap < gaps.len() && gaps[gap].scalar as usize == scalar {
                        column = gaps[gap].column;
                        gap += 1;
                    }
                    let width = self.widths.get(layout.codes as usize + scalar);
                    if width == 0 {
                        if let Some(last) = map.last_mut() {
                            last.1 = start + c.len_utf8();
                        }
                    } else {
                        let right = column + width as u16;
                        map.push((start, start + c.len_utf8(), column, right));
                        column = right;
                    }
                }
                entry.insert(map);
            }
            column_at(&maps[&row], target, end)
        };
        Ok(TextPoint {
            row: row as u32,
            column,
        })
    }
    pub fn hit(&self, ordinal: u32) -> Result<Option<SearchHit>, SearchError> {
        if ordinal >= self.count {
            return Ok(None);
        }
        let mut cursor = self.checkpoints[ordinal as usize / 512];
        for _ in 0..ordinal % 512 {
            cursor.next(&self.regex, &self.corpus);
        }
        let Some((start, end)) = cursor.next(&self.regex, &self.corpus) else {
            return Ok(None);
        };
        let mut maps = HashMap::new();
        Ok(Some(SearchHit {
            start: self.point(start, false, &mut maps)?,
            end: self.point(end, true, &mut maps)?,
        }))
    }
    pub fn visible_hits(&self, first: usize, rows: usize) -> Result<Vec<SearchHit>, SearchError> {
        let begin = *self.row_offsets.get(first).unwrap_or(&self.corpus.len());
        let checkpoint = self
            .checkpoints
            .partition_point(|c| c.offset <= begin)
            .saturating_sub(1);
        let mut cursor = self
            .checkpoints
            .get(checkpoint)
            .copied()
            .unwrap_or_default();
        let mut hits = Vec::new();
        let mut maps = HashMap::new();
        let end = *self
            .row_offsets
            .get(first + rows)
            .unwrap_or(&self.corpus.len());
        while let Some((a, b)) = cursor.next(&self.regex, &self.corpus) {
            if a > end {
                break;
            }
            if b >= begin {
                hits.push(SearchHit {
                    start: self.point(a, false, &mut maps)?,
                    end: self.point(b, true, &mut maps)?,
                });
            }
        }
        Ok(hits)
    }
}

#[cfg(test)]
mod tests {
    use crate::{Size, Terminal};
    // Independent full-cell oracle: compare every UTF-8 boundary, including
    // combining scalars and newline boundaries, against the old grid walk.
    fn verify_positions(document: super::SearchDocument) {
        use alacritty_terminal::term::cell::Flags;
        let rows: Vec<_> = (0..document.rows())
            .map(|row| {
                let mut byte = 0;
                document
                    .row(row)
                    .unwrap()
                    .into_iter()
                    .enumerate()
                    .filter_map(|(col, cell)| {
                        if cell
                            .flags
                            .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
                        {
                            return None;
                        }
                        let length = cell.c.len_utf8()
                            + cell
                                .zerowidth()
                                .map_or(0, |z| z.iter().map(|c| c.len_utf8()).sum::<usize>());
                        let start = byte;
                        byte += length;
                        Some((
                            start,
                            byte,
                            col as u16,
                            col as u16
                                + if cell.flags.contains(Flags::WIDE_CHAR) {
                                    2
                                } else {
                                    1
                                },
                        ))
                    })
                    .collect::<Vec<_>>()
            })
            .collect();
        let index = document.search(".", true, true).unwrap();
        let mut maps = std::collections::HashMap::new();
        for byte in index
            .corpus
            .char_indices()
            .map(|(i, _)| i)
            .chain(std::iter::once(index.corpus.len()))
        {
            let row = index
                .row_offsets
                .partition_point(|offset| *offset <= byte)
                .saturating_sub(1)
                .min(rows.len() - 1);
            let target = byte - index.row_offsets[row];
            for end in [false, true] {
                let expected = rows[row].iter().find(|(_, right, _, _)| {
                    if end {
                        *right >= target
                    } else {
                        *right > target
                    }
                });
                let column = match expected {
                    Some(&(left, _, column, right)) => {
                        if target == left || !end {
                            column
                        } else {
                            right
                        }
                    }
                    None => rows[row].last().map_or(0, |c| c.3),
                };
                assert_eq!(
                    index.point(byte, end, &mut maps).unwrap(),
                    super::TextPoint {
                        row: row as u32,
                        column
                    },
                    "byte={byte}, end={end}"
                );
            }
        }
    }
    #[test]
    fn compact_positions_match_grid_for_unicode_reflow_and_spacer_gaps() {
        use alacritty_terminal::term::cell::Flags;
        let mut term = Terminal::new(Size::new(23, 5).unwrap(), 2000).unwrap();
        for _ in 0..400 {
            term.feed("ascii  中文 é⃗ 😀 ❤️ xyz   \r\n\r\n".as_bytes())
                .unwrap();
        }
        for width in [23, 7, 41, 13] {
            term.resize(Size::new(width, 5).unwrap()).unwrap();
            verify_positions(term.document().unwrap());
        }
        let mut gap_term = Terminal::new(Size::new(12, 4).unwrap(), 10).unwrap();
        gap_term.feed(b"ABCD\r\nEFGH").unwrap();
        let mut doc = gap_term.document().unwrap();
        let super::FrozenRow::Hot(cells) = &mut doc.rows[0] else {
            panic!("fixture is resident");
        };
        cells[0].flags.insert(Flags::WIDE_CHAR_SPACER);
        cells[2].flags.insert(Flags::LEADING_WIDE_CHAR_SPACER);
        verify_positions(doc);
    }
    #[test]
    fn compact_index_checks_history_faults_without_reloading_cell_pages() {
        use std::sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        };
        let term = Terminal::new(Size::new(20, 4).unwrap(), 10).unwrap();
        let mut document = term.document().unwrap();
        let failed = Arc::new(AtomicBool::new(false));
        let flag = failed.clone();
        document.check = Arc::new(move || {
            if flag.load(Ordering::Acquire) {
                Err(std::io::Error::other("synthetic history failure"))
            } else {
                Ok(())
            }
        });
        let index = document.search("(?m)^", true, true).unwrap();
        assert!(index.hit(0).unwrap().is_some());
        failed.store(true, Ordering::Release);
        assert!(index.hit(0).is_err());
        assert!(index.visible_hits(0, 4).is_err());
    }
    #[test]
    fn frozen_rows_survive_live_erasure_without_copying_viewport_caches() {
        let mut term = Terminal::new(Size::new(40, 6).unwrap(), 2000).unwrap();
        for i in 0..1000 {
            term.feed(format!("{i:04} original 中文 é\r\n").as_bytes())
                .unwrap();
        }
        let document = term.document().unwrap();
        assert!(
            document
                .rows
                .iter()
                .any(|r| matches!(r, super::FrozenRow::Cold(_)))
        );
        term.feed(b"\x1b[3J\x1b[2J\x1b[Hlive replacement").unwrap();
        let index = document.search("original", false, true).unwrap();
        assert_eq!(index.count, 1000);
        assert_eq!(index.hit(999).unwrap().unwrap().start.column, 5);
        assert!(term.snapshot().text().contains("live replacement"));
        assert!(!term.snapshot().text().contains("original"));
    }
    #[test]
    fn literal_regex_case_navigation_and_zero_width_are_consistent() {
        let mut term = Terminal::new(Size::new(30, 4).unwrap(), 1000).unwrap();
        term.feed("Hello 中文é hello\r\n[abc] HELLO".as_bytes())
            .unwrap();
        let search = term
            .document()
            .unwrap()
            .search("hello", false, false)
            .unwrap();
        assert_eq!(search.count, 3);
        let hit = search.hit(0).unwrap().unwrap();
        assert_eq!(hit.start.column, 0);
        assert_eq!(search.hit(2).unwrap().unwrap().start.row, 1);
        assert_eq!(
            term.document()
                .unwrap()
                .search("Hello", false, true)
                .unwrap()
                .count,
            1
        );
        assert_eq!(
            term.document()
                .unwrap()
                .search("\\[abc\\]", true, true)
                .unwrap()
                .count,
            1
        );
        assert!(term.document().unwrap().search("[", true, true).is_err());
        let search = term.document().unwrap().search("中|é", true, true).unwrap();
        assert_eq!(search.count, 2);
        let chinese = search.hit(0).unwrap().unwrap();
        assert_eq!(chinese.end.column - chinese.start.column, 2);
        let s = term.document().unwrap().search("a*", true, true).unwrap();
        assert_eq!(s.count as usize, s.regex.find_iter(&s.corpus).count());
    }
    #[test]
    fn export_and_search_preserve_exact_logical_unicode_lines_across_cold_reflow() {
        let mut term = Terminal::new(Size::new(23, 5).unwrap(), 5000).unwrap();
        let lines: Vec<_> = (0..500).map(|i| format!("{i:04} 中文 é 😀 xyz")).collect();
        let expected = format!("{}\nEND", lines.join("\n"));
        term.feed(format!("{}\r\nEND", lines.join("\r\n")).as_bytes())
            .unwrap();
        for columns in [23, 7, 41, 13, 23] {
            term.resize(Size::new(columns, 5).unwrap()).unwrap();
            let mut output = Vec::new();
            term.document().unwrap().export(&mut output).unwrap();
            let output = String::from_utf8(output).unwrap();
            let actual = output.trim_end_matches('\n');
            let first_difference = actual
                .char_indices()
                .zip(expected.char_indices())
                .find_map(|((byte, left), (_, right))| (left != right).then_some(byte));
            assert!(
                actual == expected,
                "Unicode export changed at columns={columns}, first differing byte={first_difference:?}, lengths={}/{}",
                actual.len(),
                expected.len()
            );
            let search = term
                .document()
                .unwrap()
                .search("中文 é 😀", false, true)
                .unwrap();
            assert_eq!(search.count, 500);
        }
    }
    #[test]
    fn sparse_navigation_zero_width_and_cancellation_are_exact() {
        let mut term = Terminal::new(Size::new(40, 5).unwrap(), 2000).unwrap();
        for i in 0..1300 {
            term.feed(format!("{i:04} Ab中é hello\r\n").as_bytes())
                .unwrap();
        }
        for query in ["a*", "(?m)^|$", ".", "中|é", "\\b", "[a-z]+"] {
            let search = term.document().unwrap().search(query, true, false).unwrap();
            assert_eq!(
                search.count as usize,
                search.regex.find_iter(&search.corpus).count(),
                "{query}"
            );
            for ordinal in [0, 511, 512, 1023, search.count - 1] {
                if ordinal >= search.count {
                    continue;
                }
                let hit = search.hit(ordinal).unwrap().unwrap();
                assert!(hit.start.row < search.rows() as u32);
                assert!(hit.start.column <= 40 && hit.end.column <= 40);
            }
            let hits = search.visible_hits(350, 30).unwrap();
            assert!(!hits.is_empty());
        }
        let search = term
            .document()
            .unwrap()
            .search("hello", false, true)
            .unwrap();
        assert_eq!(search.count, 1300);
        assert_eq!(search.hit(512).unwrap().unwrap().start.row, 512);
        assert!(matches!(
            term.document()
                .unwrap()
                .search_cancellable("hello", false, true, || true),
            Err(super::SearchError::Cancelled)
        ));
        assert!(
            term.document()
                .unwrap()
                .search(&"x".repeat(4097), false, true)
                .is_err()
        );
        // A frozen result keeps its own encrypted segments when the live history
        // is subsequently pruned/reflowed, without returning new-session text.
        for _ in 0..3000 {
            term.feed(b"new\r\n").unwrap();
        }
        term.resize(Size::new(10, 7).unwrap()).unwrap();
        assert_eq!(search.hit(512).unwrap().unwrap().start.row, 512);
        assert_eq!(
            term.document()
                .unwrap()
                .search("hello", false, true)
                .unwrap()
                .count,
            0
        );
    }
    #[test]
    fn cold_rows_reflow_search_export_and_limits_match_memory_grid() {
        let mut paged = Terminal::new(Size::new(23, 5).unwrap(), 1500).unwrap();
        let mut memory = Terminal::new(Size::new(23, 5).unwrap(), 1500).unwrap();
        memory.history = crate::history::HistoryPager::new(usize::MAX - 1).unwrap();
        for i in 0..2000 {
            let output = format!("{i:04}: 中文é 😀 {}\r\n", "xyz".repeat(i % 9));
            paged.feed(output.as_bytes()).unwrap();
            memory.feed(output.as_bytes()).unwrap();
        }
        assert!(paged.history_stats().disk_bytes > 0);
        assert!(paged.history_stats().resident_history_cells <= 256 * 23);
        for size in [
            Size::new(13, 7).unwrap(),
            Size::new(41, 5).unwrap(),
            Size::new(7, 9).unwrap(),
            Size::new(23, 5).unwrap(),
        ] {
            paged.resize(size).unwrap();
            memory.resize(size).unwrap();
            for delta in [900, -17, 10000, -10000] {
                paged.scroll(delta).unwrap();
                memory.scroll(delta).unwrap();
                assert_eq!(paged.try_snapshot().unwrap().cells, memory.snapshot().cells);
            }
            let mut a = Vec::new();
            let mut b = Vec::new();
            paged.document().unwrap().export(&mut a).unwrap();
            memory.document().unwrap().export(&mut b).unwrap();
            assert_eq!(a, b);
            let a = paged
                .document()
                .unwrap()
                .search("中文é", false, true)
                .unwrap();
            let b = memory
                .document()
                .unwrap()
                .search("中文é", false, true)
                .unwrap();
            assert_eq!(a.count, b.count);
            assert_eq!(a.hit(a.count / 2).unwrap(), b.hit(b.count / 2).unwrap());
        }
    }
}
