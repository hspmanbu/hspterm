//! Bounded visible-grid decoration. This code never changes the terminal,
//! consumes SSH bytes, searches retained history or produces terminal input.
use crate::{CellColor, Snapshot};
use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

const MAX_RULES: usize = 32;
const MAX_PATTERN: usize = 512;
const MAX_ROW_BYTES: usize = 8192;
const MAX_FRAME_BYTES: usize = 128 * 1024;
const MAX_PAINTED_CELLS: usize = 16 * 1024;
const MAX_MATCHES: usize = 128;
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Style {
    pub foreground: Option<u32>,
    pub background: Option<u32>,
    pub underline: bool,
}
impl Style {
    fn valid(&self) -> bool {
        [self.foreground, self.background]
            .into_iter()
            .flatten()
            .all(|c| c >> 24 == 255)
    }
    fn overlay(&mut self, other: &Self) {
        if other.foreground.is_some() {
            self.foreground = other.foreground;
        }
        if other.background.is_some() {
            self.background = other.background;
        }
        self.underline |= other.underline;
    }
    fn empty(&self) -> bool {
        self.foreground.is_none() && self.background.is_none() && !self.underline
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Rule {
    pub id: String,
    pub name: String,
    pub pattern: String,
    pub regex: bool,
    pub case_sensitive: bool,
    pub enabled: bool,
    pub force_color: bool,
    pub style: Style,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub version: u32,
    pub enabled: bool,
    pub semantic: bool,
    pub rainbow: bool,
    pub same_word: bool,
    pub same_word_case_sensitive: bool,
    pub allow_in_alternate_screen: bool,
    /// First rule has highest priority. Reordering does not alter remote data.
    pub rules: Vec<Rule>,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            version: 1,
            enabled: false,
            semantic: false,
            rainbow: false,
            same_word: false,
            same_word_case_sensitive: true,
            allow_in_alternate_screen: false,
            rules: Vec::new(),
        }
    }
}
#[derive(Debug, thiserror::Error)]
pub enum DecorationError {
    #[error("显示增强配置无效或版本不支持")]
    Format,
    #[error("第{0}条规则无效或超过正则容量限制；未修改原配置")]
    Rule(usize),
    #[error("规则测试超过文本或匹配工作量上限，请缩短样例或简化规则；未保存配置")]
    TestLimit,
}
pub struct Decorator {
    config: Config,
    rules: Vec<(usize, Regex)>,
    semantic: Vec<(Regex, u32)>,
    addresses: Option<Regex>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PaintedCell {
    pub row: u16,
    pub column: u16,
    pub style: Style,
}
#[derive(Default)]
pub struct Decorations {
    pub cells: Vec<PaintedCell>,
    pub limited: bool,
    pub skipped_rows: usize,
}
fn compile(pattern: &str, sensitive: bool) -> Result<Regex, ()> {
    RegexBuilder::new(pattern)
        .case_insensitive(!sensitive)
        .size_limit(64 * 1024)
        .dfa_size_limit(64 * 1024)
        .nest_limit(64)
        .build()
        .map_err(|_| ())
}
impl Decorator {
    pub fn new(config: Config) -> Result<Self, DecorationError> {
        if config.version != 1 || config.rules.len() > MAX_RULES {
            return Err(DecorationError::Format);
        }
        let mut ids = std::collections::BTreeSet::new();
        let mut rules = Vec::new();
        for (i, r) in config.rules.iter().enumerate() {
            if r.id.is_empty()
                || r.id.len() > 128
                || r.id.chars().any(char::is_control)
                || !ids.insert(&r.id)
                || r.name.trim().is_empty()
                || r.name.len() > 256
                || r.name.chars().any(char::is_control)
                || r.pattern.is_empty()
                || r.pattern.len() > MAX_PATTERN
                || !r.style.valid()
                || r.style.empty()
            {
                return Err(DecorationError::Rule(i + 1));
            }
            let pattern = if r.regex {
                r.pattern.clone()
            } else {
                regex::escape(&r.pattern)
            };
            let re =
                compile(&pattern, r.case_sensitive).map_err(|_| DecorationError::Rule(i + 1))?;
            if re.is_match("") {
                return Err(DecorationError::Rule(i + 1));
            }
            if r.enabled {
                rules.push((i, re));
            }
        }
        let mut semantic = Vec::new();
        if config.semantic {
            for (pattern, color) in [
                (
                    r"\b[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])[T ](?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]\b",
                    0xff8ca6ca,
                ),
                (r"(?:/[A-Za-z0-9_.-]+)+/?", 0xff7fae9c),
                (r"\b[0-9]+(?:\.[0-9]+)?\b", 0xffb4a1c8),
                (r"\B--?[A-Za-z][A-Za-z0-9_-]*\b", 0xff90b8c7),
            ] {
                semantic.push((
                    compile(pattern, true).map_err(|_| DecorationError::Format)?,
                    color,
                ));
            }
        }
        let addresses = if config.semantic {
            Some(compile(r"[0-9A-Fa-f:.]{2,45}", true).map_err(|_| DecorationError::Format)?)
        } else {
            None
        };
        Ok(Self {
            config,
            rules,
            semantic,
            addresses,
        })
    }
    pub fn config(&self) -> &Config {
        &self.config
    }
    pub fn decorate(&self, snapshot: &Snapshot) -> Decorations {
        self.decorate_rows(snapshot, None)
    }
    pub fn decorate_rows(
        &self,
        snapshot: &Snapshot,
        changed: Option<&std::collections::BTreeSet<u16>>,
    ) -> Decorations {
        self.decorate_with_budget(snapshot, changed, Duration::from_millis(8))
    }
    fn decorate_with_budget(
        &self,
        snapshot: &Snapshot,
        changed: Option<&std::collections::BTreeSet<u16>>,
        budget: Duration,
    ) -> Decorations {
        let mut result = Decorations::default();
        if !self.config.enabled
            || (snapshot.alternate_screen && !self.config.allow_in_alternate_screen)
            || (!self.config.semantic && !self.config.rainbow && self.rules.is_empty())
        {
            return result;
        }
        let started = Instant::now();
        let mut frame_bytes = 0usize;
        let columns = usize::from(snapshot.size.columns);
        for (row, cells) in snapshot.cells.chunks(columns).enumerate() {
            if changed.is_some_and(|rows| !rows.contains(&(row as u16))) {
                continue;
            }
            if started.elapsed() >= budget {
                result.limited = true;
                result.skipped_rows += usize::from(snapshot.size.rows) - row;
                return result;
            }
            let mut text = String::new();
            // Byte boundaries map back to physical cells, including wide glyphs.
            let mut mapping = Vec::new();
            let mut over = false;
            for (column, cell) in cells.iter().enumerate() {
                if cell.flags & (64 | 256) != 0 {
                    continue;
                }
                let segment = if cell.flags & 1024 != 0 {
                    " "
                } else {
                    &cell.text
                };
                if text.len() + segment.len() > MAX_ROW_BYTES {
                    over = true;
                    break;
                }
                let width = if cell.flags & 32 != 0 { 2 } else { 1 };
                let start = text.len();
                text.push_str(segment);
                mapping.push((start, text.len(), column, (column + width).min(cells.len())));
            }
            if over || frame_bytes + text.len() > MAX_FRAME_BYTES {
                result.skipped_rows += 1;
                result.limited = true;
                continue;
            }
            frame_bytes += text.len();
            let mut styles = vec![Style::default(); cells.len()];
            let mut paint = |start: usize, end: usize, style: &Style, force: bool| {
                let first = mapping.partition_point(|(_, b, _, _)| *b <= start);
                for &(_, _, left, right) in
                    mapping[first..].iter().take_while(|(a, _, _, _)| *a < end)
                {
                    for column in left..right {
                        let cell = &cells[column];
                        if cell.flags & (1 | 1024) != 0 {
                            continue;
                        }
                        let mut permitted = style.clone();
                        if !force
                            && (cell.foreground != CellColor::Named(256) || cell.flags & 128 != 0)
                        {
                            permitted.foreground = None;
                        }
                        if !force && cell.background != CellColor::Named(257) {
                            permitted.background = None;
                        }
                        styles[column].overlay(&permitted);
                    }
                }
            };
            // Automatic styling is lowest priority and never overrides ANSI.
            for (re, color) in self.semantic.iter().rev() {
                for (ordinal, m) in re.find_iter(&text).take(MAX_MATCHES + 1).enumerate() {
                    if started.elapsed() >= budget {
                        result.limited = true;
                        return result;
                    }
                    if ordinal == MAX_MATCHES {
                        result.limited = true;
                        break;
                    }
                    paint(
                        m.start(),
                        m.end(),
                        &Style {
                            foreground: Some(*color),
                            ..Style::default()
                        },
                        false,
                    );
                }
            }
            if let Some(addresses) = &self.addresses {
                for (ordinal, m) in addresses.find_iter(&text).take(MAX_MATCHES + 1).enumerate() {
                    if started.elapsed() >= budget {
                        result.limited = true;
                        return result;
                    }
                    if ordinal == MAX_MATCHES {
                        result.limited = true;
                        break;
                    }
                    if m.as_str().parse::<std::net::IpAddr>().is_ok() {
                        paint(
                            m.start(),
                            m.end(),
                            &Style {
                                foreground: Some(0xff87b8c9),
                                ..Style::default()
                            },
                            false,
                        );
                    }
                }
            }
            if self.config.rainbow {
                for (offset, color) in brackets(&text) {
                    if started.elapsed() >= budget {
                        result.limited = true;
                        return result;
                    }
                    paint(
                        offset,
                        offset + 1,
                        &Style {
                            foreground: Some(color),
                            ..Style::default()
                        },
                        false,
                    );
                }
            }
            for (index, re) in self.rules.iter().rev() {
                let rule = &self.config.rules[*index];
                for (ordinal, m) in re.find_iter(&text).take(MAX_MATCHES + 1).enumerate() {
                    if started.elapsed() >= budget {
                        result.limited = true;
                        return result;
                    }
                    if ordinal == MAX_MATCHES {
                        result.limited = true;
                        break;
                    }
                    paint(m.start(), m.end(), &rule.style, rule.force_color);
                }
            }
            for (column, style) in styles.into_iter().enumerate() {
                if style.empty() {
                    continue;
                }
                if result.cells.len() >= MAX_PAINTED_CELLS {
                    result.limited = true;
                    return result;
                }
                result.cells.push(PaintedCell {
                    row: row as u16,
                    column: column as u16,
                    style,
                });
            }
        }
        result
    }
    /// Match plain sample rows using the same line-local semantics as painting.
    pub fn test(&self, text: &str) -> Result<Vec<(String, usize)>, DecorationError> {
        if text.len() > MAX_ROW_BYTES {
            return Err(DecorationError::TestLimit);
        }
        let started = Instant::now();
        let mut results = Vec::new();
        for (index, re) in &self.rules {
            let mut count = 0usize;
            for line in text.lines() {
                for (ordinal, _) in re.find_iter(line).take(MAX_MATCHES + 1).enumerate() {
                    if ordinal == MAX_MATCHES || started.elapsed() >= Duration::from_millis(8) {
                        return Err(DecorationError::TestLimit);
                    }
                    count += 1;
                }
                if started.elapsed() >= Duration::from_millis(8) {
                    return Err(DecorationError::TestLimit);
                }
            }
            results.push((self.config.rules[*index].id.clone(), count));
        }
        Ok(results)
    }
}
fn brackets(text: &str) -> Vec<(usize, u32)> {
    const COLORS: [u32; 6] = [
        0xffdca971, 0xff92bdad, 0xffa1a8dc, 0xffca99ba, 0xff86b9c8, 0xffb8bd83,
    ];
    let mut stack = Vec::new();
    let mut matched = Vec::new();
    let mut quote = None;
    let mut escaped = false;
    for (offset, c) in text.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if let Some(q) = quote {
            if c == '\\' {
                escaped = true;
            } else if c == q {
                quote = None;
            }
            continue;
        }
        if c == '\'' || c == '"' {
            quote = Some(c);
            continue;
        }
        if matches!(c, '(' | '[' | '{') {
            if stack.len() >= 64 {
                return Vec::new();
            }
            stack.push((c, offset, stack.len()));
        } else if matches!(c, ')' | ']' | '}') {
            let Some((left, start, depth)) = stack.pop() else {
                return Vec::new();
            };
            if !matches!((left, c), ('(', ')') | ('[', ']') | ('{', '}')) {
                return Vec::new();
            }
            let color = COLORS[depth % COLORS.len()];
            matched.extend([(start, color), (offset, color)]);
        }
    }
    if quote.is_some() || !stack.is_empty() {
        Vec::new()
    } else {
        matched
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Size, Terminal};
    fn rule(pattern: &str, color: u32) -> Rule {
        Rule {
            id: format!("{pattern}-{color:x}"),
            name: pattern.into(),
            pattern: pattern.into(),
            regex: false,
            case_sensitive: true,
            enabled: true,
            force_color: false,
            style: Style {
                foreground: Some(color),
                ..Style::default()
            },
        }
    }
    #[test]
    fn colors_do_not_change_source_search_export_width_or_explicit_remote_ansi() {
        let mut t = Terminal::new(Size::new(40, 4).unwrap(), 100).unwrap();
        t.feed("中e\u{301} ERROR \x1b[31mERROR\x1b[0m (ok)".as_bytes())
            .unwrap();
        let before = t.snapshot();
        let text = before.text();
        let mut config = Config {
            enabled: true,
            rainbow: true,
            ..Config::default()
        };
        config.rules.push(rule("ERROR", 0xff123456));
        let d = Decorator::new(config.clone()).unwrap().decorate(&before);
        assert!(
            d.cells
                .iter()
                .any(|c| c.style.foreground == Some(0xff123456))
        );
        assert!(d.cells.iter().all(|c| {
            before.cells[usize::from(c.row) * 40 + usize::from(c.column)].foreground
                == CellColor::Named(256)
        }));
        assert_eq!(t.snapshot(), before);
        assert_eq!(t.snapshot().text(), text);
        config.rules[0].force_color = true;
        assert!(
            Decorator::new(config)
                .unwrap()
                .decorate(&before)
                .cells
                .len()
                > d.cells.len()
        );
    }
    #[test]
    fn priority_wide_cells_alternate_screen_and_unsafe_regex_limits() {
        let mut t = Terminal::new(Size::new(20, 3).unwrap(), 20).unwrap();
        t.feed("中文".as_bytes()).unwrap();
        let c = Config {
            enabled: true,
            rules: vec![rule("中文", 0xff112233), rule("中文", 0xff556677)],
            ..Config::default()
        };
        let d = Decorator::new(c.clone()).unwrap();
        let painted = d.decorate(&t.snapshot());
        assert_eq!(painted.cells.len(), 4);
        assert!(
            painted
                .cells
                .iter()
                .all(|c| c.style.foreground == Some(0xff112233))
        );
        t.feed(b"\x1b[?1049h").unwrap();
        assert!(d.decorate(&t.snapshot()).cells.is_empty());
        let mut invalid = c;
        invalid.rules[0].regex = true;
        invalid.rules[0].pattern = "(a+)+$".into();
        assert!(
            Decorator::new(invalid.clone())
                .unwrap()
                .test(&"a".repeat(8193))
                .is_err()
        );
        invalid.rules[0].pattern = "a*".into();
        assert!(Decorator::new(invalid).is_err());
        assert!(brackets("([mismatch})").is_empty());
        assert!(brackets("(incomplete").is_empty());
        assert_eq!(
            brackets("{\"literal\": \"[ignored]\", \"x\": (1)}").len(),
            4
        );
    }
}

#[cfg(test)]
mod budget_tests {
    use super::*;
    use crate::{Size, Terminal};
    #[test]
    fn malicious_regex_and_large_rows_are_bounded_without_mutating_or_losing_text() {
        let mut config = Config {
            enabled: true,
            ..Config::default()
        };
        config.rules.push(Rule {
            id: "bounded".into(),
            name: "bounded".into(),
            pattern: "(a+)+$".into(),
            regex: true,
            case_sensitive: true,
            enabled: true,
            force_color: false,
            style: Style {
                foreground: Some(0xff778899),
                ..Style::default()
            },
        });
        let d = Decorator::new(config.clone()).unwrap();
        assert_eq!(d.test(&format!("{}!", "a".repeat(8191))).unwrap()[0].1, 0);
        let mut terminal = Terminal::new(Size::new(1024, 32).unwrap(), 0).unwrap();
        terminal.feed(&vec![b'a'; 32700]).unwrap();
        let before = terminal.snapshot();
        config.rules[0].pattern = ".+".into();
        let d = Decorator::new(config).unwrap().decorate(&before);
        assert!(d.limited);
        assert!(d.cells.len() <= MAX_PAINTED_CELLS);
        assert_eq!(terminal.snapshot(), before);
        let mut oversized = before.clone();
        oversized.cells[0].text = "a".repeat(MAX_ROW_BYTES + 1);
        assert!(
            Decorator::new(Config {
                enabled: true,
                semantic: true,
                ..Config::default()
            })
            .unwrap()
            .decorate(&oversized)
            .skipped_rows
                > 0
        );
    }
    #[test]
    fn changed_rows_and_concealed_text_cannot_create_hidden_decorations() {
        let mut t = Terminal::new(Size::new(40, 3).unwrap(), 10).unwrap();
        t.feed(b"\x1b[8mERROR\x1b[0m\r\nERROR").unwrap();
        let c = Config {
            enabled: true,
            rules: vec![Rule {
                id: "safe".into(),
                name: "safe".into(),
                pattern: "ERROR".into(),
                regex: false,
                case_sensitive: true,
                enabled: true,
                force_color: true,
                style: Style {
                    foreground: Some(0xff112233),
                    ..Style::default()
                },
            }],
            ..Config::default()
        };
        let d = Decorator::new(c).unwrap();
        let before = t.snapshot();
        let paints = d.decorate(&before);
        assert_eq!(paints.cells.len(), 5);
        assert!(paints.cells.iter().all(|c| c.row == 1));
        let only_first = std::collections::BTreeSet::from([0]);
        assert!(d.decorate_rows(&before, Some(&only_first)).cells.is_empty());
        assert_eq!(before, t.snapshot());
    }
}

#[cfg(test)]
mod deadline_tests {
    use super::*;
    use crate::{Size, Terminal};
    #[test]
    fn expired_budget_only_skips_display_effects_and_never_discards_terminal_text() {
        let mut t = Terminal::new(Size::new(80, 4).unwrap(), 20).unwrap();
        t.feed(b"ERROR full retained text [a=(42)]").unwrap();
        let before = t.snapshot();
        let decorator = Decorator::new(Config {
            enabled: true,
            semantic: true,
            rainbow: true,
            ..Config::default()
        })
        .unwrap();
        let result = decorator.decorate_with_budget(&before, None, Duration::ZERO);
        assert!(result.limited);
        assert!(result.cells.is_empty());
        assert_eq!(before, t.snapshot());
        assert!(
            !decorator
                .decorate_with_budget(&before, None, Duration::from_secs(1))
                .cells
                .is_empty()
        );
    }
}

#[cfg(test)]
mod sample_tests {
    use super::*;
    #[test]
    fn sample_matches_are_line_local_and_limits_are_explicit_instead_of_false_counts() {
        let rule = |id: &str, pattern: &str| Rule {
            id: id.into(),
            name: id.into(),
            pattern: pattern.into(),
            regex: true,
            case_sensitive: true,
            enabled: true,
            force_color: false,
            style: Style {
                foreground: Some(0xffeeeeee),
                ..Style::default()
            },
        };
        let config = Config {
            rules: vec![
                rule("cross-line", r"(?s)ERROR.*WARN"),
                rule("prefix", r"^ERROR"),
            ],
            ..Config::default()
        };
        let decorator = Decorator::new(config).unwrap();
        let result = decorator.test("ERROR\r\nWARN\nERROR").unwrap();
        assert_eq!(result, vec![("cross-line".into(), 0), ("prefix".into(), 2)]);
        let d = Decorator::new(Config {
            rules: vec![rule("bounded", "ERROR")],
            ..Config::default()
        })
        .unwrap();
        assert!(matches!(
            d.test(&"ERROR ".repeat(129)),
            Err(DecorationError::TestLimit)
        ));
    }
}
