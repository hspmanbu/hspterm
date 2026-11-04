//! Current-terminal search/export over a frozen grid. No SSH commands are sent.
use crate::TerminalError;
use alacritty_terminal::{
    grid::{Dimensions, Grid},
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
    pub(crate) grid: Grid<Cell>,
    pub(crate) check: Arc<dyn Fn() -> io::Result<()> + Send + Sync>,
}
impl SearchDocument {
    pub fn rows(&self) -> usize {
        self.grid.total_lines()
    }
    pub fn row(&self, index: usize) -> Result<Vec<Cell>, TerminalError> {
        if index >= self.rows() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "历史行位置已失效").into());
        }
        (self.check)()?;
        let cells = self.grid[Line(index as i32 - self.history_lines as i32)].owned_cells();
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
        for row in 0..self.rows() {
            if cancelled() {
                return Err(SearchError::Cancelled);
            }
            row_offsets.push(corpus.len());
            let cells = self.row(row)?;
            let (text, wrap) = row_text(&cells);
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
            markers[row * 128 / self.rows().max(1)] += 1;
            count += 1;
        }
        Ok(SearchIndex {
            document: self,
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
type PointMaps = HashMap<usize, Vec<(usize, usize, u16, u16)>>;
pub struct SearchIndex {
    document: SearchDocument,
    corpus: Zeroizing<String>,
    regex: Regex,
    row_offsets: Vec<usize>,
    checkpoints: Vec<MatchCursor>,
    pub count: u32,
    pub markers: Vec<u32>,
}
impl SearchIndex {
    pub fn revision(&self) -> u64 {
        self.document.revision
    }
    pub fn rows(&self) -> usize {
        self.document.rows()
    }
    fn point(
        &self,
        byte: usize,
        end: bool,
        maps: &mut PointMaps,
    ) -> Result<TextPoint, SearchError> {
        let row = self
            .row_offsets
            .partition_point(|offset| *offset <= byte)
            .saturating_sub(1)
            .min(self.document.rows() - 1);
        // Decode a cold row once per navigation/frame, rather than twice per
        // match (e.g. thousands of single-character regex hits in a viewport).
        if let std::collections::hash_map::Entry::Vacant(entry) = maps.entry(row) {
            let mut position = 0;
            let mut map = Vec::new();
            for (column, cell) in self.document.row(row)?.iter().enumerate() {
                if cell
                    .flags
                    .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
                {
                    continue;
                }
                let length = cell.c.len_utf8()
                    + cell
                        .zerowidth()
                        .map_or(0, |c| c.iter().map(|c| c.len_utf8()).sum());
                let right = column
                    + if cell.flags.contains(Flags::WIDE_CHAR) {
                        2
                    } else {
                        1
                    };
                map.push((position, position + length, column as u16, right as u16));
                position += length;
            }
            entry.insert(map);
        }
        let map = &maps[&row];
        let target = byte - self.row_offsets[row];
        let index =
            map.partition_point(|(_, right, _, _)| *right < target || !end && *right == target);
        let column = if let Some(&(left, _, column, right)) = map.get(index) {
            if target == left || !end {
                column
            } else {
                right
            }
        } else {
            map.last().map_or(0, |c| c.3)
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
