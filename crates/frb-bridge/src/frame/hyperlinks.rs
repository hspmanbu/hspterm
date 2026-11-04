//! Bounded, per-patch OSC 8 spans. Never expand one URI into every cell.
use super::{Cell, RenderHyperlink};
pub(super) struct Budget {
    bytes: usize,
    spans: usize,
    cells: usize,
}
impl Default for Budget {
    fn default() -> Self {
        Self {
            bytes: 256 * 1024,
            spans: 2048,
            cells: 64 * 1024,
        }
    }
}
pub(super) fn spans(row: &[Cell], budget: &mut Budget) -> Vec<RenderHyperlink> {
    let blocked = || {
        vec![RenderHyperlink {
            start: 0,
            end: row.len() as u16,
            uri: None,
        }]
    };
    if row.len() > budget.cells {
        return if row.iter().any(|cell| cell.hyperlink.is_some()) {
            blocked()
        } else {
            Vec::new()
        };
    }
    budget.cells -= row.len();
    let mut spans = Vec::new();
    let mut x = 0;
    while x < row.len() {
        let Some(link) = row[x].hyperlink.as_ref() else {
            x += 1;
            continue;
        };
        let start = x;
        x += 1;
        while x < row.len() && row[x].hyperlink.as_ref() == Some(link) {
            x += 1;
        }
        // The UI checks the actual clicked cell for concealment before using
        // this metadata; no hidden text is added to the span.
        if budget.spans == 0 {
            return vec![RenderHyperlink {
                start: 0,
                end: row.len() as u16,
                uri: None,
            }];
        }
        budget.spans -= 1;
        let value = link.uri();
        let uri = if value.len() <= 4096
            && value.len() <= budget.bytes
            && !value.chars().any(char::is_control)
        {
            budget.bytes -= value.len();
            Some(value.to_owned())
        } else {
            None
        };
        spans.push(RenderHyperlink {
            start: start as u16,
            end: x as u16,
            uri,
        });
    }
    spans
}

#[cfg(test)]
mod tests {
    use super::*;
    use hspterm_term_core::{Size, Terminal};
    #[test]
    fn long_labels_coalesce_and_exhausted_budgets_suppress_unsafe_fallback() {
        let mut t = Terminal::new(Size::new(1000, 4).unwrap(), 10).unwrap();
        t.feed(
            format!(
                "\x1b]8;;https://example.invalid/{}\x1b\\{}\x1b]8;;\x1b\\",
                "x".repeat(2000),
                "L".repeat(1000)
            )
            .as_bytes(),
        )
        .unwrap();
        let s = t.snapshot();
        let links = spans(&s.cells[..1000], &mut Budget::default());
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].end, 1000);
        let links = spans(
            &s.cells[..1000],
            &mut Budget {
                bytes: 2,
                spans: 10,
                cells: 1000,
            },
        );
        assert!(links[0].uri.is_none());
        let links = spans(
            &s.cells[..1000],
            &mut Budget {
                bytes: 1024,
                spans: 0,
                cells: 1000,
            },
        );
        assert_eq!((links[0].start, links[0].end), (0, 1000));
        assert!(links[0].uri.is_none());
        let links = spans(
            &s.cells[..1000],
            &mut Budget {
                bytes: 4096,
                spans: 10,
                cells: 999,
            },
        );
        assert_eq!((links[0].start, links[0].end), (0, 1000));
        assert!(links[0].uri.is_none());
    }
}
