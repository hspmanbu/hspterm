//! SSH terminal state. No local process or shell is created by this crate.
mod commands;
pub mod decorations;
pub use commands::CommandRange;
mod history;
mod input;
pub mod integration;
pub mod notifications;
pub mod preferences;
mod search;
mod shell;
pub use shell::{ShellContext, ShellPhase};
mod working_directory;
pub use history::HistoryStats;
pub use input::{
    InputError, Key, KeyEvent, KeyKind, Modifiers, MouseAction, MouseButton, MouseEvent, PastePlan,
};
pub use search::{SearchDocument, SearchError, SearchHit, SearchIndex, TextPoint};
use std::sync::Arc;
use std::time::Instant;
pub use working_directory::{
    RemotePathError, WorkingDirectory, relative_remote_path, resolve_remote_path,
    resolve_remote_reference,
};

use alacritty_terminal::{
    Term,
    event::{Event, EventListener},
    grid::{Dimensions, Scroll},
    index::{Column, Line, Point},
    term::{Config, Osc52, TermMode, cell::Flags},
    vte::ansi::{Color, Processor},
};
use parking_lot::Mutex;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum TerminalError {
    #[error("终端行列必须在 2..=4096，且可见单元格不得超过 1048576")]
    InvalidSize,
    #[error("终端临时历史不可用：{0}")]
    History(#[from] std::io::Error),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Size {
    pub columns: u16,
    pub rows: u16,
}
impl Size {
    pub fn new(columns: u16, rows: u16) -> Result<Self, TerminalError> {
        if !(2..=4096).contains(&columns)
            || !(2..=4096).contains(&rows)
            || u32::from(columns) * u32::from(rows) > 1_048_576
        {
            return Err(TerminalError::InvalidSize);
        }
        Ok(Self { columns, rows })
    }
}
impl Dimensions for Size {
    fn columns(&self) -> usize {
        usize::from(self.columns)
    }
    fn screen_lines(&self) -> usize {
        usize::from(self.rows)
    }
    fn total_lines(&self) -> usize {
        self.screen_lines()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CellColor {
    Named(u16),
    Indexed(u8),
    Rgb(u8, u8, u8),
}
impl From<Color> for CellColor {
    fn from(color: Color) -> Self {
        match color {
            Color::Named(v) => Self::Named(v as u16),
            Color::Indexed(v) => Self::Indexed(v),
            Color::Spec(v) => Self::Rgb(v.r, v.g, v.b),
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct Cell {
    pub text: String,
    pub foreground: CellColor,
    pub background: CellColor,
    pub flags: u16,
    pub wide_spacer: bool,
    /// Shared passive OSC 8 metadata; never part of copied/exported text.
    pub hyperlink: Option<alacritty_terminal::term::cell::Hyperlink>,
}
impl std::fmt::Debug for Cell {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Cell")
            .field("flags", &self.flags)
            .field("wide_spacer", &self.wide_spacer)
            .finish_non_exhaustive()
    }
}
#[derive(Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub working_directory: Option<WorkingDirectory>,
    pub size: Size,
    pub cells: Vec<Cell>,
    pub cursor_column: usize,
    /// May be outside the viewport while the user is viewing history.
    pub cursor_row: i64,
    pub cursor_visible: bool,
    pub cursor_shape: u8,
    pub cursor_blink: bool,
    pub osc52_enabled: bool,
    pub right_click_paste: bool,
    pub palette: Vec<Option<[u8; 3]>>,
    pub mouse_reporting: bool,
    pub alternate_screen: bool,
    pub history_lines: usize,
    pub display_offset: usize,
    pub revision: u64,
    pub content_revision: u64,
    pub output_lines: u64,
    pub size_locked: bool,
}
impl std::fmt::Debug for Snapshot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Snapshot")
            .field("size", &self.size)
            .field("revision", &self.revision)
            .field("content_revision", &self.content_revision)
            .field("history_lines", &self.history_lines)
            .field("display_offset", &self.display_offset)
            .finish_non_exhaustive()
    }
}
impl Snapshot {
    /// Visible physical rows, useful for regression tests; not full-history export.
    pub fn text(&self) -> String {
        self.cells
            .chunks(usize::from(self.size.columns))
            .map(|row| {
                row.iter()
                    .filter(|c| !c.wide_spacer)
                    .map(|c| c.text.as_str())
                    .collect::<String>()
                    .trim_end()
                    .to_owned()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

pub const MAX_CLIPBOARD_BYTES: usize = 10 * 1024 * 1024;
struct EventBuffer {
    notices: notifications::Engine,
    shell: shell::ShellState,
    integration: Option<integration::State>,
    submissions: Vec<integration::Submission>,
    commands: commands::Commands,
    working_directory: Option<WorkingDirectory>,
    directory_revision: u64,
    events: Vec<Event>,
    clipboard_rejections: usize,
    osc52_enabled: bool,
}
impl EventBuffer {
    fn set_directory(&mut self, directory: Option<WorkingDirectory>) {
        if self.working_directory != directory {
            self.working_directory = directory;
            self.directory_revision = self.directory_revision.wrapping_add(1);
        }
    }
}
#[derive(Clone)]
struct Collector(Arc<Mutex<EventBuffer>>);
impl EventListener for Collector {
    fn send_event(&self, event: Event) {
        let event = match event {
            Event::Bell => {
                self.0.lock().notices.bell(Instant::now());
                return;
            }
            Event::Notification { title, body } => {
                self.0.lock().notices.osc(&title, &body, Instant::now());
                return;
            }
            Event::NotificationLine(line) => {
                self.0.lock().notices.line(&line, Instant::now());
                return;
            }
            Event::ShellIntegration(packet) => {
                let mut state = self.0.lock();
                if let Some(integration) = &mut state.integration {
                    let accepted = match packet {
                        Some(packet) => {
                            integration.report(&zeroize::Zeroizing::new(packet), Instant::now())
                        }
                        None => {
                            integration.invalidate();
                            None
                        }
                    };
                    if let Some(accepted) = accepted {
                        // The SSH actor drains after each feed. Overflow drops
                        // qualification, never terminal bytes or live input.
                        if state.submissions.len() < 32 {
                            state.submissions.push(accepted);
                        }
                    }
                }
                return;
            }
            Event::ShellMarker(marker) => {
                let mut state = self.0.lock();
                state.shell.apply(marker);
                if matches!(marker, alacritty_terminal::vte::ansi::ShellMarker::Invalid) {
                    state.commands.invalidate();
                }
                return;
            }
            Event::CommandBoundary(boundary) => {
                self.0.lock().commands.apply(boundary);
                return;
            }
            Event::CommandBoundaryInvalid => {
                let mut state = self.0.lock();
                state.commands.abort();
                if let Some(integration) = &mut state.integration {
                    integration.invalidate();
                }
                return;
            }
            Event::WorkingDirectory(uri) => {
                self.0
                    .lock()
                    .set_directory(uri.as_deref().and_then(WorkingDirectory::parse));
                return;
            }
            Event::ClipboardStore(_, ref text) if text.len() > MAX_CLIPBOARD_BYTES => {
                self.0.lock().clipboard_rejections += 1;
                return;
            }
            Event::ClipboardLoad(kind, formatter) => {
                let state = Arc::downgrade(&self.0);
                Event::ClipboardLoad(
                    kind,
                    Arc::new(move |text| {
                        let Some(state) = state.upgrade() else {
                            return String::new();
                        };
                        let mut state = state.lock();
                        if !state.osc52_enabled {
                            return String::new();
                        }
                        if text.len() > MAX_CLIPBOARD_BYTES {
                            state.clipboard_rejections += 1;
                            return String::new();
                        }
                        drop(state);
                        formatter(text)
                    }),
                )
            }
            event => event,
        };
        self.0.lock().events.push(event);
    }
}

pub struct Terminal {
    term: Term<Collector>,
    parser: Processor,
    events: Collector,
    size: Size,
    revision: u64,
    config: Config,
    cell_pixels: (u16, u16),
    history: history::HistoryPager,
    content_revision: u64,
    output_lines: u64,
    size_locked: bool,
    user_colors: Option<preferences::Colors>,
    right_click_paste: bool,
}
impl Terminal {
    pub fn new(size: Size, history_lines: usize) -> Result<Self, TerminalError> {
        let size = Size::new(size.columns, size.rows)?;
        let events = Collector(Arc::new(Mutex::new(EventBuffer {
            notices: notifications::Engine::default(),
            shell: Default::default(),
            integration: None,
            submissions: Vec::new(),
            commands: Default::default(),
            working_directory: None,
            directory_revision: 0,
            events: Vec::new(),
            clipboard_rejections: 0,
            osc52_enabled: true,
        })));
        let config = Config {
            scrolling_history: history_lines,
            kitty_keyboard: true,
            osc52: Osc52::CopyPaste,
            ..Config::default()
        };
        let term = Term::new(config.clone(), &size, events.clone());
        Ok(Self {
            term,
            parser: Processor::new(),
            events,
            size,
            revision: 0,
            config,
            cell_pixels: (8, 16),
            history: history::HistoryPager::new(history::DEFAULT_RAM_HISTORY_ROWS)?,
            content_revision: 0,
            output_lines: 0,
            size_locked: false,
            user_colors: None,
            right_click_paste: false,
        })
    }

    pub fn feed(&mut self, bytes: &[u8]) -> Result<(), TerminalError> {
        self.history.check()?;
        for chunk in bytes.chunks(4096) {
            let scrolls = self.term.history_scrolls();
            self.parser.advance(&mut self.term, chunk);
            self.output_lines = self
                .output_lines
                .saturating_add(self.term.history_scrolls().saturating_sub(scrolls));
            self.checkpoint_history(false)?;
        }
        if !bytes.is_empty() {
            self.events.0.lock().notices.activity(Instant::now());
            self.revision = self.revision.wrapping_add(1);
            self.content_revision = self.content_revision.wrapping_add(1);
        }
        Ok(())
    }

    /// Call from an actor timer even if no further SSH output arrives.
    pub fn flush_expired_sync(&mut self, now: Instant) -> bool {
        if self
            .parser
            .sync_timeout()
            .sync_timeout()
            .is_some_and(|deadline| now >= deadline)
        {
            let scrolls = self.term.history_scrolls();
            self.parser.stop_sync(&mut self.term);
            self.output_lines = self
                .output_lines
                .saturating_add(self.term.history_scrolls().saturating_sub(scrolls));
            self.content_revision = self.content_revision.wrapping_add(1);
            self.revision = self.revision.wrapping_add(1);
            true
        } else {
            false
        }
    }

    /// Archive the old screen and reset parser, modes, cursor and protocol stacks
    /// for a new remote PTY. Old text remains in bounded history, without synthetic bytes.
    pub fn begin_new_generation(&mut self) {
        self.parser.stop_sync(&mut self.term);
        if self.term.mode().contains(TermMode::ALT_SCREEN) {
            let rows: Vec<_> = (0..self.size.screen_lines())
                .map(|i| self.term.grid()[Line(i as i32)].clone())
                .collect();
            self.term.swap_alt();
            self.term.grid_mut().cursor = Default::default();
            self.term.grid_mut().clear_viewport();
            for (i, row) in rows.into_iter().enumerate() {
                self.term.grid_mut()[Line(i as i32)] = row;
            }
        }
        self.term.grid_mut().cursor = Default::default();
        self.term.grid_mut().saved_cursor = Default::default();
        self.term.grid_mut().clear_viewport();
        let mut fresh = Term::new(self.config.clone(), &self.size, self.events.clone());
        std::mem::swap(fresh.grid_mut(), self.term.grid_mut());
        self.term = fresh;
        // Deferred old synchronized output may itself have generated notices.
        // Retire them after flushing, before the new PTY can publish anything.
        self.events.0.lock().notices.reset();
        let rules = self.events.0.lock().notices.rules_enabled();
        self.term.set_notification_rules(rules);
        self.content_revision = self.content_revision.wrapping_add(1);
        self.parser = Processor::new();
        self.events.0.lock().events.clear();
        self.events.0.lock().set_directory(None);
        self.events.0.lock().shell.invalidate();
        self.configure_integration(None);
        self.events.0.lock().commands.invalidate();
        self.revision = self.revision.wrapping_add(1);
    }

    /// Commit already-received synchronized output when the stream ends.
    pub fn finish_stream(&mut self) {
        self.events.0.lock().notices.disconnect();
        self.parser.stop_sync(&mut self.term);
        self.events.0.lock().set_directory(None);
        self.events.0.lock().shell.invalidate();
        self.configure_integration(None);
        self.events.0.lock().commands.abort();
        self.content_revision = self.content_revision.wrapping_add(1);
        self.revision = self.revision.wrapping_add(1);
    }

    pub fn resize(&mut self, size: Size) -> Result<(), TerminalError> {
        let size = Size::new(size.columns, size.rows)?;
        if self.size != size && !self.size_locked {
            // Geometry/reflow does not edit Readline's line or cursor. The
            // helper still compares the entire real line before accepting a
            // controlled edit; losing proof here strands an idle prompt after
            // the renderer's initial PTY resize (its PS1 redraw is a replay).
            self.events.0.lock().shell.invalidate();
            let command_reflow = self
                .events
                .0
                .lock()
                .commands
                .prepare_reflow(self.term.grid(), self.size.columns);
            self.history.check()?;
            if self
                .history
                .needs_reflow_paging(self.term.grid().history_size())
            {
                let history = &mut self.history;
                self.term
                    .resize_with_reflow_hook(size, &mut |row| history.page_reflow_row(row));
            } else {
                self.term.resize(size);
            }
            self.size = size;
            self.content_revision = self.content_revision.wrapping_add(1);
            self.checkpoint_history(true)?;
            self.events.0.lock().commands.restore_reflow(
                command_reflow,
                self.term.grid(),
                self.size.columns,
            );
            if let Err(error) = self.history.check() {
                self.events.0.lock().commands.invalidate();
                return Err(error.into());
            }
            self.revision = self.revision.wrapping_add(1);
        }
        Ok(())
    }

    pub fn scroll(&mut self, delta: i32) -> Result<(), TerminalError> {
        self.checkpoint_history(true)?;
        self.term.scroll_display(Scroll::Delta(delta));
        self.revision = self.revision.wrapping_add(1);
        Ok(())
    }

    /// Drain after each input batch; platform requests are adapted by the bridge.
    /// Never log these events: clipboard payloads and terminal replies may be sensitive.
    pub fn take_events(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.events.0.lock().events)
    }

    pub fn working_directory(&self) -> Option<WorkingDirectory> {
        self.events.0.lock().working_directory.clone()
    }
    pub fn configure_integration(&mut self, nonce: Option<integration::Nonce>) {
        let mut state = self.events.0.lock();
        state.integration = nonce.map(integration::State::new);
        state.submissions.clear();
    }
    pub fn invalidate_integration(&self) {
        if let Some(state) = &mut self.events.0.lock().integration {
            state.invalidate();
        }
    }
    pub fn integration_proof(&self) -> Option<integration::Proof> {
        let mut events = self.events.0.lock();
        let state = events.integration.as_mut()?;
        state.expire(Instant::now());
        if !self.integration_mode_safe() {
            if state.proof().is_some() || state.deadline().is_some() {
                state.invalidate();
            }
            return None;
        }
        state.proof()
    }
    pub fn integration_input(&self) -> Option<(integration::Proof, zeroize::Zeroizing<String>)> {
        self.integration_proof()?;
        self.events.0.lock().integration.as_ref()?.input()
    }
    pub fn integration_status(&self) -> &'static str {
        let ready = self.integration_proof().is_some();
        let events = self.events.0.lock();
        let Some(state) = &events.integration else {
            return "ShellUnavailable";
        };
        if !self.integration_mode_safe() {
            return "TerminalMode";
        }
        if ready {
            "Ready"
        } else if !state.has_prompt() {
            "WaitingForHelper"
        } else {
            "InputStateUnknown"
        }
    }
    pub fn integration_revision(&self) -> u64 {
        self.events
            .0
            .lock()
            .integration
            .as_ref()
            .map_or(0, integration::State::revision)
    }
    pub fn integration_deadline(&self) -> Option<Instant> {
        self.events
            .0
            .lock()
            .integration
            .as_ref()
            .and_then(integration::State::deadline)
    }
    pub fn expire_integration(&self, now: Instant) {
        if let Some(state) = &mut self.events.0.lock().integration {
            state.expire(now);
        }
    }
    pub fn integration_outcome(&self, request: u64) -> Option<bool> {
        self.events.0.lock().integration.as_ref()?.outcome(request)
    }
    pub fn plan_integration(
        &self,
        proof: integration::Proof,
        edit: integration::Edit<'_>,
        empty: bool,
    ) -> Result<integration::Plan, integration::Failure> {
        self.integration_proof()
            .ok_or(integration::Failure::Unavailable)?;
        let mut events = self.events.0.lock();
        let state = events
            .integration
            .as_mut()
            .ok_or(integration::Failure::Unavailable)?;
        if empty && state.prefix() != Some("") {
            return Err(integration::Failure::Changed);
        }
        state.plan(proof, edit, Instant::now())
    }
    pub fn take_integration_submissions(&self) -> Vec<integration::Submission> {
        std::mem::take(&mut self.events.0.lock().submissions)
    }
    /// Observe actual encoded bytes in the owning SSH actor, before writing.
    /// Complex edits do not get reconstructed from the screen or key guesses.
    pub fn observe_integration_key(&self, key: &KeyEvent, encoded: &[u8]) {
        if encoded.is_empty() {
            return;
        }
        if !self.integration_mode_safe() {
            self.invalidate_integration();
            return;
        }
        let mut events = self.events.0.lock();
        let Some(state) = &mut events.integration else {
            return;
        };
        let m = key.modifiers;
        if m.control || m.alt || m.super_key || m.hyper || m.meta {
            state.invalidate();
            return;
        }
        match key.key {
            Key::Enter if !m.shift && (encoded == b"\r" || encoded == b"\n") => {
                state.submitted_enter(Instant::now())
            }
            Key::Backspace if encoded == b"\x7f" || encoded == b"\x08" => {
                let _ = state.backspace();
            }
            Key::Character(_) => match std::str::from_utf8(encoded) {
                Ok(text) => {
                    let _ = state.typed(text);
                }
                Err(_) => state.invalidate(),
            },
            _ => state.invalidate(),
        }
    }
    pub fn observe_integration_text(&self, encoded: &[u8]) {
        if !self.integration_mode_safe() {
            self.invalidate_integration();
            return;
        }
        let mut events = self.events.0.lock();
        if let Some(state) = &mut events.integration {
            match std::str::from_utf8(encoded) {
                Ok(text) => {
                    let _ = state.typed(text);
                }
                Err(_) => state.invalidate(),
            }
        }
    }
    fn integration_mode_safe(&self) -> bool {
        !self.term.mode().intersects(
            TermMode::ALT_SCREEN
                | TermMode::APP_CURSOR
                | TermMode::APP_KEYPAD
                | TermMode::MOUSE_MODE
                | TermMode::KITTY_KEYBOARD_PROTOCOL,
        ) && self.term.modify_other_keys() == 0
    }

    pub fn shell_context(&self) -> ShellContext {
        self.events.0.lock().shell.context
    }
    /// Metadata only, no materialization of any cold terminal row.
    pub fn command_ranges(&self) -> Vec<CommandRange> {
        if self.term.mode().contains(TermMode::ALT_SCREEN) {
            return Vec::new();
        }
        self.events
            .0
            .lock()
            .commands
            .ranges(self.term.grid(), self.size.columns)
    }
    pub fn command_document(
        &self,
        id: u64,
    ) -> Result<(SearchDocument, CommandRange), TerminalError> {
        if self.term.mode().contains(TermMode::ALT_SCREEN) {
            return Err(std::io::Error::other("备用屏幕没有可靠命令输出范围").into());
        }
        self.events
            .0
            .lock()
            .commands
            .document(id, self.term.grid(), self.size.columns, || self.document())
    }

    /// Small metadata snapshot; does not materialize any grid or cold history row.
    pub fn directory_context(&self) -> (u64, Option<WorkingDirectory>) {
        let state = self.events.0.lock();
        (state.directory_revision, state.working_directory.clone())
    }

    pub fn directory_revision(&self) -> u64 {
        self.events.0.lock().directory_revision
    }

    /// Disable both directions, including outstanding clipboard read callbacks.
    pub fn set_osc52_enabled(&mut self, enabled: bool) {
        let mut events = self.events.0.lock();
        events.osc52_enabled = enabled;
        if !enabled {
            events
                .events
                .retain(|e| !matches!(e, Event::ClipboardStore(..) | Event::ClipboardLoad(..)));
        }
        drop(events);
        self.config.osc52 = if enabled {
            Osc52::CopyPaste
        } else {
            Osc52::Disabled
        };
        self.term.set_options(self.config.clone());
    }
    /// Persistent defaults do not erase remote OSC/DECSCUSR overrides and never
    /// resize/truncate active history. The line limit applies at creation only.
    pub fn set_preferences(
        &mut self,
        value: &preferences::Settings,
    ) -> Result<(), preferences::PreferencesError> {
        self.apply_preferences(&value.validated()?);
        Ok(())
    }
    pub fn apply_preferences(&mut self, validated: &preferences::Validated) {
        use alacritty_terminal::vte::ansi::{CursorShape, CursorStyle};
        let value = validated.settings();
        self.term.set_notification_rules(
            value.notifications.enabled && !value.notifications.rules.is_empty(),
        );
        self.events
            .0
            .lock()
            .notices
            .configure(validated.notifications());
        self.config.default_cursor_style = CursorStyle {
            shape: match value.cursor_shape.as_str() {
                "underline" => CursorShape::Underline,
                "beam" => CursorShape::Beam,
                _ => CursorShape::Block,
            },
            blinking: value.cursor_blink,
        };
        self.user_colors = Some(value.colors.clone());
        self.right_click_paste = value.right_click_paste;
        self.set_osc52_enabled(value.osc52);
        self.revision = self.revision.wrapping_add(1);
    }
    pub fn notification_deadline(&self) -> Option<Instant> {
        self.events.0.lock().notices.deadline()
    }
    pub fn notification_policy(&self) -> u64 {
        self.events.0.lock().notices.policy()
    }
    pub fn flush_notifications(&mut self, now: Instant) {
        self.events.0.lock().notices.flush(now);
    }
    pub fn take_notifications(&mut self) -> Vec<notifications::Notice> {
        self.events.0.lock().notices.take()
    }
    pub fn take_clipboard_rejections(&mut self) -> usize {
        std::mem::take(&mut self.events.0.lock().clipboard_rejections)
    }

    pub fn encode_key(&self, event: &KeyEvent) -> Result<Vec<u8>, InputError> {
        input::key(*self.term.mode(), self.term.modify_other_keys(), event)
    }
    /// Committed IME text uses the negotiated keyboard protocol too.
    pub fn encode_text(&self, text: &str) -> Result<Vec<u8>, InputError> {
        let mut result = Vec::new();
        for character in text.chars() {
            result.extend(self.encode_key(&KeyEvent::press(Key::Character(character)))?);
        }
        Ok(result)
    }
    pub fn set_cell_pixels(&mut self, width: u16, height: u16) {
        self.cell_pixels = (width.max(1), height.max(1));
    }
    /// Reply in the network actor, never by a UI callback into that same actor.
    pub fn protocol_reply(&self, event: &Event) -> Option<String> {
        use alacritty_terminal::{event::WindowSize, vte::ansi::Rgb};
        match event {
            Event::PtyWrite(reply) => Some(reply.clone()),
            Event::ColorRequest(index, formatter) => {
                let color = if *index < 269 {
                    self.term.colors()[*index]
                } else {
                    None
                };
                let argb = self
                    .user_colors
                    .as_ref()
                    .and_then(|c| c.color(*index))
                    .map(|c| 0xff000000 | c)
                    .unwrap_or_else(|| default_color(*index));
                Some(formatter(color.unwrap_or(Rgb {
                    r: (argb >> 16) as u8,
                    g: (argb >> 8) as u8,
                    b: argb as u8,
                })))
            }
            Event::TextAreaSizeRequest(formatter) => Some(formatter(WindowSize {
                num_lines: self.size.rows,
                num_cols: self.size.columns,
                cell_width: self.cell_pixels.0,
                cell_height: self.cell_pixels.1,
            })),
            _ => None,
        }
    }
    pub fn encode_mouse(&self, event: MouseEvent) -> Vec<u8> {
        input::mouse(*self.term.mode(), self.size.columns, self.size.rows, event)
    }
    pub fn prepare_paste(&self, text: &str, confirmed: bool) -> Result<PastePlan, InputError> {
        input::paste(self.bracketed_paste(), text, confirmed)
    }

    pub fn bracketed_paste(&self) -> bool {
        self.term.mode().contains(TermMode::BRACKETED_PASTE)
    }
    pub fn application_cursor(&self) -> bool {
        self.term.mode().contains(TermMode::APP_CURSOR)
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn sync_deadline(&self) -> Option<Instant> {
        self.parser.sync_timeout().sync_timeout()
    }
    pub fn focus_bytes(&self, focused: bool) -> Vec<u8> {
        if self.term.mode().contains(TermMode::FOCUS_IN_OUT) {
            if focused {
                b"\x1b[I".to_vec()
            } else {
                b"\x1b[O".to_vec()
            }
        } else {
            Vec::new()
        }
    }
    pub fn set_size_locked(&mut self, locked: bool) {
        self.size_locked = locked;
        self.invalidate_view();
    }
    pub fn size_locked(&self) -> bool {
        self.size_locked
    }
    pub fn invalidate_view(&mut self) {
        self.revision = self.revision.wrapping_add(1);
    }
    pub fn content_revision(&self) -> u64 {
        self.content_revision
    }
    pub fn document(&self) -> Result<SearchDocument, TerminalError> {
        self.history.check()?;
        Ok(SearchDocument {
            revision: self.content_revision,
            columns: self.size.columns,
            history_lines: self.term.grid().history_size(),
            grid: self.term.grid().clone(),
            check: self.history.fault_checker(),
        })
    }
    pub fn seek(&mut self, top_row: usize) -> Result<(), TerminalError> {
        let history = self.term.grid().history_size();
        let target = history.saturating_sub(top_row.min(history));
        let delta = target as i32 - self.term.grid().display_offset() as i32;
        self.scroll(delta)
    }
    /// Called after synchronized-output flushes as well as ordinary feed batches.
    pub fn maintain_history(&mut self) -> Result<(), TerminalError> {
        self.checkpoint_history(false)
    }
    fn checkpoint_history(&mut self, full: bool) -> Result<(), TerminalError> {
        let (active, inactive) = self.term.grids_mut();
        self.history.checkpoint(active, full)?;
        self.history.checkpoint(inactive, full)?;
        Ok(())
    }
    pub fn history_stats(&self) -> HistoryStats {
        self.history.stats(self.term.grid())
    }
    pub fn try_snapshot(&self) -> Result<Snapshot, TerminalError> {
        self.history.check()?;
        let snapshot = self.snapshot();
        self.history.check()?;
        Ok(snapshot)
    }
    pub fn snapshot(&self) -> Snapshot {
        let grid = self.term.grid();
        let offset = grid.display_offset();
        let mut cells = Vec::with_capacity(self.size.columns() * self.size.screen_lines());
        for row in 0..self.size.screen_lines() {
            for column in 0..self.size.columns() {
                let cell = &grid[Point::new(Line(row as i32 - offset as i32), Column(column))];
                let mut text = cell.c.to_string();
                if let Some(extra) = cell.zerowidth() {
                    text.extend(extra.iter());
                }
                cells.push(Cell {
                    text,
                    foreground: cell.fg.into(),
                    background: cell.bg.into(),
                    flags: cell.flags.bits(),
                    wide_spacer: cell.flags.contains(Flags::WIDE_CHAR_SPACER),
                    hyperlink: cell.hyperlink(),
                });
            }
        }
        Snapshot {
            working_directory: self.working_directory(),
            size: self.size,
            cells,
            cursor_column: grid.cursor.point.column.0,
            cursor_row: i64::from(grid.cursor.point.line.0) + offset as i64,
            cursor_visible: self.term.mode().contains(TermMode::SHOW_CURSOR),
            cursor_shape: match self.term.cursor_style().shape {
                alacritty_terminal::vte::ansi::CursorShape::Block => 0,
                alacritty_terminal::vte::ansi::CursorShape::Underline => 1,
                alacritty_terminal::vte::ansi::CursorShape::Beam => 2,
                alacritty_terminal::vte::ansi::CursorShape::HollowBlock => 3,
                alacritty_terminal::vte::ansi::CursorShape::Hidden => 4,
            },
            cursor_blink: self.term.cursor_style().blinking,
            osc52_enabled: self.events.0.lock().osc52_enabled,
            right_click_paste: self.right_click_paste,
            palette: (0..269)
                .map(|i| {
                    self.term.colors()[i].map(|v| [v.r, v.g, v.b]).or_else(|| {
                        self.user_colors
                            .as_ref()
                            .and_then(|c| c.color(i))
                            .map(|c| [(c >> 16) as u8, (c >> 8) as u8, c as u8])
                    })
                })
                .collect(),
            mouse_reporting: self.term.mode().intersects(TermMode::MOUSE_MODE),
            alternate_screen: self.term.mode().contains(TermMode::ALT_SCREEN),
            history_lines: grid.history_size(),
            display_offset: offset,
            revision: self.revision,
            content_revision: self.content_revision,
            output_lines: self.output_lines,
            size_locked: self.size_locked,
        }
    }
}

pub fn default_color(index: usize) -> u32 {
    const ANSI: [u32; 16] = [
        0x1d2028, 0xf07178, 0xc3e88d, 0xffcb6b, 0x82aaff, 0xc792ea, 0x89ddff, 0xd8dee9, 0x616e88,
        0xff8b92, 0xddffa7, 0xffe585, 0x9cc4ff, 0xe1acff, 0xa3f7ff, 0xffffff,
    ];
    let rgb = match index {
        0..=15 => ANSI[index],
        16..=231 => {
            let n = index - 16;
            let c = |v| if v == 0 { 0 } else { 55 + 40 * v };
            (c(n / 36) << 16 | c(n / 6 % 6) << 8 | c(n % 6)) as u32
        }
        232..=255 => {
            let v = (8 + 10 * (index - 232)) as u32;
            v << 16 | v << 8 | v
        }
        257 | 268 => 0x10151d,
        259..=266 => {
            let color = ANSI[index - 259];
            ((color >> 16 & 255) * 2 / 3) << 16
                | ((color >> 8 & 255) * 2 / 3) << 8
                | ((color & 255) * 2 / 3)
        }
        _ => 0xd8dee9,
    };
    0xff000000 | rgb
}

#[cfg(test)]
mod tests {
    use super::*;
    fn term() -> Terminal {
        Terminal::new(Size::new(40, 6).unwrap(), 100).unwrap()
    }

    #[test]
    fn fragmented_unicode_colors_combining_and_cursor() {
        let bytes = "\x1b[38;2;12;34;56m中e\u{301}\x1b[0m\x1b[2;4HX".as_bytes();
        let mut whole = term();
        whole.feed(bytes).unwrap();
        for chunk_size in 1..=bytes.len() {
            let mut split = term();
            for chunk in bytes.chunks(chunk_size) {
                split.feed(chunk).unwrap();
            }
            let a = split.snapshot();
            let b = whole.snapshot();
            assert_eq!(a.cells, b.cells);
            assert_eq!((a.cursor_row, a.cursor_column), (1, 4));
            assert_eq!(a.cells[0].foreground, CellColor::Rgb(12, 34, 56));
            assert!(a.cells[1].wide_spacer);
            assert_eq!(a.cells[2].text, "e\u{301}");
        }
    }

    #[test]
    fn alternate_screen_restores_primary_and_modes() {
        let mut t = term();
        t.feed(b"original\x1b[?1049h\x1b[?1h\x1b[?2004hTUI")
            .unwrap();
        assert!(t.snapshot().alternate_screen);
        assert!(t.application_cursor());
        assert!(t.bracketed_paste());
        t.feed(b"\x1b[?1049l\x1b[?1l\x1b[?2004l").unwrap();
        assert!(t.snapshot().text().starts_with("original"));
        assert!(!t.snapshot().alternate_screen);
        assert!(!t.application_cursor());
        assert!(!t.bracketed_paste());
    }

    #[test]
    fn scroll_anchor_does_not_follow_new_output_or_resize_lose_content() {
        let mut t = term();
        for i in 0..30 {
            t.feed(format!("line{i}\r\n").as_bytes()).unwrap();
        }
        t.scroll(10).unwrap();
        let before = t.snapshot();
        t.feed(b"new-output\r\n").unwrap();
        let after = t.snapshot();
        assert_eq!(before.text(), after.text());
        assert!(after.display_offset > before.display_offset);
        t.resize(Size::new(30, 8).unwrap()).unwrap();
        assert_eq!(t.snapshot().cells.len(), 240);
    }

    #[test]
    fn device_queries_and_kitty_stack_reply_to_remote() {
        let mut t = term();
        t.feed(b"\x1b[6n\x1b[>1u\x1b[?u\x1b[<u\x1b[?u").unwrap();
        let replies: Vec<_> = t
            .take_events()
            .into_iter()
            .filter_map(|e| match e {
                Event::PtyWrite(s) => Some(s),
                _ => None,
            })
            .collect();
        assert!(replies.iter().any(|s| s == "\x1b[1;1R"));
        assert!(replies.iter().any(|s| s == "\x1b[?1u"));
        assert!(replies.iter().any(|s| s == "\x1b[?0u"));
    }

    #[test]
    fn reconnect_resets_parser_and_modes_and_preserves_primary_and_alt_text() {
        let mut t = term();
        t.feed(b"primary\x1b[?1049h\x1b[>1u\x1b[?1h\x1b[?2004hfinal-TUI\x1b[")
            .unwrap();
        t.begin_new_generation();
        assert!(!t.snapshot().alternate_screen);
        assert!(!t.application_cursor());
        assert!(!t.bracketed_paste());
        t.feed(b"new-PTY\x1b[?u").unwrap();
        assert!(t.snapshot().text().starts_with("new-PTY"));
        let replies = t.take_events();
        assert!(
            replies
                .iter()
                .any(|e| matches!(e, Event::PtyWrite(s) if s == "\x1b[?0u"))
        );
        t.scroll(100).unwrap();
        let mut retained = t.snapshot().text();
        for _ in 0..20 {
            t.scroll(-1).unwrap();
            retained.push_str(&t.snapshot().text());
        }
        assert!(retained.contains("primary"));
        assert!(retained.contains("final-TUI"));
    }

    #[test]
    fn locked_pty_and_output_counter_preserve_history_anchor_at_retention_cap() {
        let mut term = Terminal::new(Size::new(20, 4).unwrap(), 10).unwrap();
        for i in 0..30 {
            term.feed(format!("{i:04}\r\n").as_bytes()).unwrap();
        }
        term.scroll(5).unwrap();
        let old = term.try_snapshot().unwrap();
        term.feed(b"next\r\n").unwrap();
        let next = term.try_snapshot().unwrap();
        assert_eq!(next.history_lines, old.history_lines);
        assert_eq!(next.display_offset, old.display_offset + 1);
        assert_eq!(next.output_lines, old.output_lines + 1);
        assert_eq!(&next.cells[..60], &old.cells[..60]);
        term.set_size_locked(true);
        term.resize(Size::new(11, 7).unwrap()).unwrap();
        assert_eq!(term.try_snapshot().unwrap().size, old.size);
        term.set_size_locked(false);
        term.resize(Size::new(11, 7).unwrap()).unwrap();
        assert_eq!(term.try_snapshot().unwrap().size.columns, 11);
        let before_alt = term.try_snapshot().unwrap().output_lines;
        term.feed(b"\x1b[?1049h").unwrap();
        for _ in 0..20 {
            term.feed(b"alt\r\n").unwrap();
        }
        term.feed(b"\x1b[?1049l").unwrap();
        assert_eq!(term.try_snapshot().unwrap().output_lines, before_alt);
    }

    #[test]
    fn synchronized_output_flushes_on_end_or_timeout() {
        let mut t = term();
        t.feed(b"\x1b[?2026hbatched").unwrap();
        assert!(!t.snapshot().text().contains("batched"));
        let revision = t.content_revision();
        assert!(t.flush_expired_sync(Instant::now() + std::time::Duration::from_secs(1)));
        assert!(t.snapshot().text().contains("batched"));
        assert!(t.content_revision() > revision);
        t.feed(b"\x1b[?2026h-end\x1b[?2026l").unwrap();
        assert!(t.snapshot().text().contains("batched-end"));
    }
}
