//! Passive, bounded OSC133 output anchors. No shell/input inference and no
//! command text. Mutable rows are proven at D; cold paging preserves row IDs.
use crate::{SearchDocument, TerminalError, TextPoint};
use alacritty_terminal::{
    event::{CommandBoundary, CommandPosition},
    grid::{Dimensions, Grid},
    index::Line,
    term::cell::Cell,
    vte::ansi::ShellMarker,
};
use std::{collections::VecDeque, io};

const MAX_COMMANDS: usize = 8192;
const MAX_MUTABLE_PROOFS: usize = 32768;
mod reflow;
#[derive(Clone, Debug)]
pub struct CommandRange {
    pub id: u64,
    pub prompt: Option<TextPoint>,
    pub start: TextPoint,
    pub end: TextPoint,
    pub exit_status: Option<u8>,
}
struct Retained {
    id: u64,
    prompt: Option<Anchor>,
    start: Anchor,
    end: Anchor,
    exit_status: Option<u8>,
    tail: Vec<(i128, (u64, u64))>,
}
#[derive(Clone, Copy)]
struct Anchor {
    // Height changes can move retained rows before the initial scroll origin.
    // Keep the event wire coordinate unsigned; only internal anchors are signed.
    row: i128,
    column: usize,
    row_identity: u64,
}
impl From<CommandPosition> for Anchor {
    fn from(point: CommandPosition) -> Self {
        Self {
            row: point.row.into(),
            column: point.column,
            row_identity: point.row_identity,
        }
    }
}
#[derive(Default)]
pub(crate) struct Commands {
    sequence: u64,
    prompt: Option<CommandPosition>,
    input: bool,
    output: Option<CommandPosition>,
    retained: VecDeque<Retained>,
    proof_rows: usize,
}
impl Commands {
    pub fn invalidate(&mut self) {
        self.abort();
        self.retained.clear();
        self.proof_rows = 0;
    }
    pub fn abort(&mut self) {
        self.prompt = None;
        self.input = false;
        self.output = None;
    }
    pub fn apply(&mut self, boundary: CommandBoundary) {
        let point = boundary.position;
        match boundary.marker {
            ShellMarker::Prompt => {
                self.abort();
                self.prompt = Some(point);
            }
            ShellMarker::Input if self.prompt.is_some() && !self.input && self.output.is_none() => {
                self.input = true
            }
            ShellMarker::Output if self.prompt.is_some() && self.input && self.output.is_none() => {
                self.input = false;
                self.output = Some(point);
            }
            ShellMarker::Finished(exit_status) if self.output.is_some() => {
                let start = self.output.take().unwrap();
                let prompt = self.prompt.take().unwrap();
                if (start.row, start.column) > (point.row, point.column) || start.row_identity == 0
                {
                    self.abort();
                    return;
                }
                let Some(id) = self.sequence.checked_add(1) else {
                    self.invalidate();
                    return;
                };
                self.sequence = id;
                let tail: Vec<_> = boundary
                    .screen
                    .into_iter()
                    .filter(|(row, _)| {
                        *row >= start.row
                            && (*row < point.row || point.column != 0 && *row == point.row)
                    })
                    .map(|(row, proof)| (i128::from(row), proof))
                    .collect();
                if tail.len() > MAX_MUTABLE_PROOFS {
                    self.abort();
                    return;
                }
                while self.retained.len() >= MAX_COMMANDS
                    || self.proof_rows + tail.len() > MAX_MUTABLE_PROOFS
                {
                    if let Some(old) = self.retained.pop_front() {
                        self.proof_rows -= old.tail.len();
                    } else {
                        break;
                    }
                }
                self.proof_rows += tail.len();
                self.retained.push_back(Retained {
                    id,
                    prompt: Some(prompt.into()),
                    start: start.into(),
                    end: point.into(),
                    exit_status,
                    tail,
                });
            }
            _ => self.abort(),
        }
    }
    fn project(range: &Retained, grid: &Grid<Cell>, columns: u16) -> Option<CommandRange> {
        let scrolls = grid.history_scrolls();
        // Height-only changes can move retained rows before the initial event
        // origin. Reflow anchors use signed internal coordinates for that case.
        let earliest = i128::from(scrolls) - grid.history_size() as i128;
        let last = i128::from(scrolls) + grid.screen_lines() as i128;
        let coordinate = |point: Anchor| {
            if point.row < earliest || point.row >= last || point.column > columns as usize {
                return None;
            }
            Some(TextPoint {
                row: u32::try_from(point.row - earliest).ok()?,
                column: point.column as u16,
            })
        };
        let row_at = |absolute: i128| {
            if absolute < earliest || absolute >= last {
                return None;
            }
            let line = i32::try_from(absolute - i128::from(scrolls)).ok()?;
            Some(&grid[Line(line)])
        };
        let start = coordinate(range.start)?;
        let end = coordinate(range.end)?;
        if row_at(range.start.row)?.proof().0 != range.start.row_identity {
            return None;
        }
        for (row, proof) in &range.tail {
            if proof.0 == 0 || row_at(*row)?.proof() != *proof {
                return None;
            }
        }
        let prompt = range.prompt.and_then(|prompt| {
            coordinate(prompt)
                .filter(|_| row_at(prompt.row).is_some_and(|r| r.proof().0 == prompt.row_identity))
        });
        Some(CommandRange {
            id: range.id,
            prompt,
            start,
            end,
            exit_status: range.exit_status,
        })
    }
    pub fn ranges(&self, grid: &Grid<Cell>, columns: u16) -> Vec<CommandRange> {
        self.retained
            .iter()
            .filter_map(|r| Self::project(r, grid, columns))
            .collect()
    }
    pub fn document(
        &self,
        id: u64,
        grid: &Grid<Cell>,
        columns: u16,
        document: impl FnOnce() -> Result<SearchDocument, TerminalError>,
    ) -> Result<(SearchDocument, CommandRange), TerminalError> {
        let range = self
            .retained
            .iter()
            .find(|r| r.id == id)
            .and_then(|r| Self::project(r, grid, columns))
            .ok_or_else(|| io::Error::other("OSC133命令范围已失效，请手动选择文本"))?;
        Ok((document()?, range))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mutable_proof_budget_is_global_to_the_terminal_not_per_command() {
        let mut commands = Commands::default();
        for _ in 0..100 {
            for marker in [
                ShellMarker::Prompt,
                ShellMarker::Input,
                ShellMarker::Output,
                ShellMarker::Finished(None),
            ] {
                commands.apply(CommandBoundary {
                    marker,
                    position: CommandPosition {
                        row: if matches!(marker, ShellMarker::Finished(_)) {
                            2000
                        } else {
                            0
                        },
                        column: 0,
                        row_identity: 1,
                    },
                    screen: if matches!(marker, ShellMarker::Finished(_)) {
                        (0..2000).map(|r| (r, (r + 1, 0))).collect()
                    } else {
                        Vec::new()
                    },
                });
            }
        }
        assert!(commands.proof_rows <= MAX_MUTABLE_PROOFS);
        assert!(commands.retained.len() <= MAX_COMMANDS);
        assert!(commands.retained.len() < 100);
    }
}
