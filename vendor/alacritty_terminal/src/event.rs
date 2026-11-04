use std::borrow::Cow;
use std::fmt::{self, Debug, Formatter};
use std::process::ExitStatus;
use std::sync::Arc;

use crate::term::ClipboardType;
use crate::vte::ansi::Rgb;

#[cfg(feature = "hspterm-history")]
#[derive(Clone, Copy, Debug)]
pub struct CommandPosition {
    pub row: u64,
    pub column: usize,
    pub row_identity: u64,
}
#[cfg(feature = "hspterm-history")]
#[derive(Clone)]
pub struct CommandBoundary {
    pub marker: crate::vte::ansi::ShellMarker,
    pub position: CommandPosition,
    /// Mutable screen rows at the exact D marker. No cells or text are copied.
    pub screen: Vec<(u64, (u64, u64))>,
}

/// Terminal event.
///
/// These events instruct the UI over changes that can't be handled by the terminal emulation layer
/// itself.
#[derive(Clone)]
pub enum Event {
    /// Grid has changed possibly requiring a mouse cursor shape change.
    MouseCursorDirty,

    /// Window title change.
    Title(String),

    /// Reset to the default window title.
    ResetTitle,

    /// HSPTerm passive OSC 7 metadata, intentionally redacted in Debug.
    WorkingDirectory(Option<String>),
    /// HSPTerm passive shell phase only; never contains remote command text.
    ShellMarker(crate::vte::ansi::ShellMarker),
    /// Opt-in private protocol; only the core's collector consumes this body.
    ShellIntegration(Option<String>),
    #[cfg(feature = "hspterm-history")]
    CommandBoundary(CommandBoundary),
    #[cfg(feature = "hspterm-history")]
    CommandBoundaryInvalid,

    /// Request to store a text string in the clipboard.
    ClipboardStore(ClipboardType, String),

    /// Request to write the contents of the clipboard to the PTY.
    ///
    /// The attached function is a formatter which will correctly transform the clipboard content
    /// into the expected escape sequence format.
    ClipboardLoad(ClipboardType, Arc<dyn Fn(&str) -> String + Sync + Send + 'static>),

    /// Request to write the RGB value of a color to the PTY.
    ///
    /// The attached function is a formatter which will correctly transform the RGB color into the
    /// expected escape sequence format.
    ColorRequest(usize, Arc<dyn Fn(Rgb) -> String + Sync + Send + 'static>),

    /// Write some text to the PTY.
    PtyWrite(String),

    /// Request to write the text area size.
    TextAreaSizeRequest(Arc<dyn Fn(WindowSize) -> String + Sync + Send + 'static>),

    /// Cursor blinking state has changed.
    CursorBlinkingChange,

    /// New terminal content available.
    Wakeup,

    /// Terminal bell ring.
    Bell,
    /// HSPTerm passive remote notice. Debug intentionally omits output.
    Notification { title: String, body: String },
    /// Opt-in bounded plain output fragments; consumed by core rules, never UI logs.
    NotificationLine(String),

    /// Shutdown request.
    Exit,

    /// Child process exited.
    ChildExit(ExitStatus),
}

impl Debug for Event {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        match self {
            Event::ClipboardStore(ty, _) => write!(f, "ClipboardStore({ty:?}, <redacted>)"),
            Event::ClipboardLoad(ty, _) => write!(f, "ClipboardLoad({ty:?})"),
            Event::TextAreaSizeRequest(_) => write!(f, "TextAreaSizeRequest"),
            Event::ColorRequest(index, _) => write!(f, "ColorRequest({index})"),
            Event::PtyWrite(_) => write!(f, "PtyWrite(<redacted>)"),
            Event::Title(_) => write!(f, "Title(<redacted>)"),
            Event::CursorBlinkingChange => write!(f, "CursorBlinkingChange"),
            Event::MouseCursorDirty => write!(f, "MouseCursorDirty"),
            Event::ResetTitle => write!(f, "ResetTitle"),
            Event::WorkingDirectory(_) => write!(f, "WorkingDirectory(<redacted>)"),
            Event::ShellMarker(marker) => write!(f, "ShellMarker({marker:?})"),
            Event::ShellIntegration(_) => write!(f, "ShellIntegration(<redacted>)"),
            #[cfg(feature = "hspterm-history")]
            Event::CommandBoundary(_) => write!(f, "CommandBoundary(<metadata>)"),
            #[cfg(feature = "hspterm-history")]
            Event::CommandBoundaryInvalid => write!(f, "CommandBoundaryInvalid"),
            Event::Wakeup => write!(f, "Wakeup"),
            Event::Bell => write!(f, "Bell"),
            Event::Notification { .. } => write!(f, "Notification(<redacted>)"),
            Event::NotificationLine(_) => write!(f, "NotificationLine(<redacted>)"),
            Event::Exit => write!(f, "Exit"),
            Event::ChildExit(status) => write!(f, "ChildExit({status:?})"),
        }
    }
}

/// Byte sequences are sent to a `Notify` in response to some events.
pub trait Notify {
    /// Notify that an escape sequence should be written to the PTY.
    ///
    /// TODO this needs to be able to error somehow.
    fn notify<B: Into<Cow<'static, [u8]>>>(&self, _: B);
}

#[derive(Copy, Clone, Debug)]
pub struct WindowSize {
    pub num_lines: u16,
    pub num_cols: u16,
    pub cell_width: u16,
    pub cell_height: u16,
}

/// Types that are interested in when the display is resized.
pub trait OnResize {
    fn on_resize(&mut self, window_size: WindowSize);
}

/// Event Loop for notifying the renderer about terminal events.
pub trait EventListener {
    fn send_event(&self, _event: Event) {}
}

/// Null sink for events.
pub struct VoidListener;

impl EventListener for VoidListener {}
