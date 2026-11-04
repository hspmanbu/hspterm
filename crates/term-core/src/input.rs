//! Protocol-aware input encoding. Reference: kitty keyboard protocol and xterm ctlseqs.
use alacritty_terminal::term::TermMode;
use thiserror::Error;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Modifiers {
    pub shift: bool,
    pub alt: bool,
    pub control: bool,
    pub super_key: bool,
    pub hyper: bool,
    pub meta: bool,
    pub caps_lock: bool,
    pub num_lock: bool,
}
impl Modifiers {
    fn bits(self) -> u16 {
        u16::from(self.shift)
            | (u16::from(self.alt) << 1)
            | (u16::from(self.control) << 2)
            | (u16::from(self.super_key) << 3)
            | (u16::from(self.hyper) << 4)
            | (u16::from(self.meta) << 5)
            | (u16::from(self.caps_lock) << 6)
            | (u16::from(self.num_lock) << 7)
    }
    fn shortcut(self) -> bool {
        self.alt || self.control || self.super_key || self.hyper || self.meta
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    /// Unshifted logical key; text and shifted alternatives come from the platform.
    Character(char),
    Enter,
    Tab,
    Backspace,
    Escape,
    Insert,
    Delete,
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    Function(u8),
    /// A key from kitty's functional-key table, including modifier/keypad keys.
    Functional(u32),
}
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum KeyKind {
    #[default]
    Press,
    Repeat,
    Release,
}
/// Input payloads may contain secrets; deliberately does not implement Debug.
pub struct KeyEvent {
    pub key: Key,
    pub modifiers: Modifiers,
    pub kind: KeyKind,
    pub text: Option<String>,
    pub shifted_key: Option<char>,
    pub base_key: Option<char>,
}
impl KeyEvent {
    pub fn press(key: Key) -> Self {
        Self {
            key,
            modifiers: Modifiers::default(),
            kind: KeyKind::Press,
            text: match key {
                Key::Character(c) => Some(c.to_string()),
                _ => None,
            },
            shifted_key: None,
            base_key: None,
        }
    }
}
#[derive(Debug, Error)]
pub enum InputError {
    #[error("不支持的按键代码")]
    InvalidKey,
    #[error("粘贴内容含括号粘贴结束序列，不能安全发送")]
    PasteDelimiter,
}

pub(crate) fn key(
    mode: TermMode,
    modify_other_keys: u8,
    event: &KeyEvent,
) -> Result<Vec<u8>, InputError> {
    let kitty_active = mode.intersects(
        TermMode::DISAMBIGUATE_ESC_CODES
            | TermMode::REPORT_EVENT_TYPES
            | TermMode::REPORT_ALL_KEYS_AS_ESC
            | TermMode::REPORT_ALTERNATE_KEYS
            | TermMode::REPORT_ASSOCIATED_TEXT,
    );
    if modify_other_keys != 0 && !kitty_active {
        if event.kind == KeyKind::Release {
            return Ok(Vec::new());
        }
        let m = event.modifiers;
        if modify_other_keys == 1 && event.key == Key::Backspace {
            let mut bytes = if m.alt { vec![27] } else { Vec::new() };
            bytes.push(if m.control { 8 } else { 127 });
            return Ok(bytes);
        }
        let character = match event.key {
            Key::Character(c) => Some(
                event
                    .text
                    .as_deref()
                    .and_then(|s| {
                        let mut chars = s.chars();
                        let first = chars.next()?;
                        (chars.next().is_none() && !first.is_control()).then_some(first)
                    })
                    .or(event.shifted_key.filter(|_| m.shift))
                    .unwrap_or(c),
            ),
            Key::Enter => Some('\r'),
            Key::Tab => Some('\t'),
            Key::Backspace => Some('\x7f'),
            Key::Escape => Some('\x1b'),
            _ => None,
        };
        if let Some(c) = character {
            // Level 1 preserves conventional Control aliases and Shift typing;
            // level 2 also disambiguates these combinations. Caps/NumLock alone
            // do not change traditional xterm modifier encoding.
            let modified = m.bits() & 0x3f;
            let well_defined = !m.alt
                && !m.super_key
                && !m.hyper
                && !m.meta
                && (m.shift && !m.control && !c.is_control() || m.control && ctrl(c) != c);
            if modified != 0 && (modify_other_keys == 2 || !well_defined) {
                return Ok(format!("\x1b[27;{};{}~", modified + 1, c as u32).into_bytes());
            }
        }
    }
    let all = mode.contains(TermMode::REPORT_ALL_KEYS_AS_ESC);
    let disambiguate = mode.contains(TermMode::DISAMBIGUATE_ESC_CODES);
    let report_events = mode.contains(TermMode::REPORT_EVENT_TYPES);
    let simple = matches!(event.key, Key::Enter | Key::Tab | Key::Backspace)
        && !event.modifiers.shortcut()
        && !event.modifiers.shift;
    let functional_modifier = matches!(event.key, Key::Functional(57358..=57360 | 57441..=57454));
    if functional_modifier && !all {
        return Ok(Vec::new());
    }
    if event.kind == KeyKind::Release && (!report_events || (simple && !all)) {
        return Ok(Vec::new());
    }
    let extended = all
        || (disambiguate && (event.modifiers.shortcut() || event.key == Key::Escape))
        || (event.modifiers.shift && matches!(event.key, Key::Enter | Key::Backspace))
        || (disambiguate && event.modifiers.shift && event.key == Key::Tab)
        || (report_events && event.key == Key::Escape)
        || event.modifiers.super_key
        || event.modifiers.hyper
        || event.modifiers.meta
        || (event.modifiers.control && event.modifiers.shift);
    let special = !matches!(
        event.key,
        Key::Character(_) | Key::Enter | Key::Tab | Key::Backspace | Key::Escape
    );
    if extended || (special && (disambiguate || report_events)) {
        return kitty(mode, event);
    }
    if event.kind == KeyKind::Release {
        return Ok(Vec::new());
    }
    let m = event.modifiers;
    let mut output = Vec::new();
    match event.key {
        Key::Character(c) => {
            if m.alt {
                output.push(0x1b);
            }
            let text = if m.control {
                ctrl(c).to_string()
            } else {
                event.text.clone().unwrap_or_else(|| {
                    event
                        .shifted_key
                        .filter(|_| m.shift)
                        .unwrap_or(c)
                        .to_string()
                })
            };
            output.extend_from_slice(text.as_bytes());
        }
        Key::Enter | Key::Tab | Key::Backspace | Key::Escape => {
            if event.key == Key::Tab && m.shift {
                output.extend_from_slice(b"\x1b[Z");
            } else {
                if m.alt {
                    output.push(0x1b);
                }
                output.push(match event.key {
                    Key::Enter => {
                        if m.control {
                            b'\n'
                        } else {
                            b'\r'
                        }
                    }
                    Key::Tab => b'\t',
                    Key::Backspace => {
                        if m.control {
                            8
                        } else {
                            127
                        }
                    }
                    Key::Escape => 27,
                    _ => unreachable!(),
                });
            }
        }
        _ => {
            let (number, suffix) = code(event.key, false)?;
            let modifiers = (m.bits() & 0x3f) + 1;
            if suffix == 'u' {
                return kitty(mode, event);
            }
            if modifiers != 1 {
                output.extend_from_slice(format!("\x1b[{number};{modifiers}{suffix}").as_bytes());
            } else if suffix != '~' {
                let application = mode.contains(TermMode::APP_CURSOR)
                    && matches!(
                        event.key,
                        Key::Left | Key::Right | Key::Up | Key::Down | Key::Home | Key::End
                    );
                let function = matches!(event.key, Key::Function(1..=4));
                output.extend_from_slice(
                    format!(
                        "\x1b{}{suffix}",
                        if application || function { 'O' } else { '[' }
                    )
                    .as_bytes(),
                );
            } else {
                output.extend_from_slice(format!("\x1b[{number}~").as_bytes());
            }
        }
    }
    Ok(output)
}
fn kitty(mode: TermMode, event: &KeyEvent) -> Result<Vec<u8>, InputError> {
    let (number, suffix) = code(event.key, true)?;
    let mut key = number.to_string();
    if mode.contains(TermMode::REPORT_ALTERNATE_KEYS) && matches!(event.key, Key::Character(_)) {
        let shifted = event.shifted_key.filter(|_| event.modifiers.shift);
        if shifted.is_some() || event.base_key.is_some() {
            key.push(':');
            if let Some(c) = shifted {
                key.push_str(&(c as u32).to_string());
            }
            if let Some(c) = event.base_key {
                key.push(':');
                key.push_str(&(c as u32).to_string());
            }
        }
    }
    let mut mods = event.modifiers.bits() + 1;
    if !mode.contains(TermMode::REPORT_ALL_KEYS_AS_ESC) {
        mods = (event.modifiers.bits() & 0x3f) + 1;
    }
    let mut modifier_field = mods.to_string();
    if mode.contains(TermMode::REPORT_EVENT_TYPES) && event.kind != KeyKind::Press {
        modifier_field.push_str(if event.kind == KeyKind::Repeat {
            ":2"
        } else {
            ":3"
        });
    }
    let text = event
        .text
        .as_deref()
        .filter(|s| !s.is_empty() && s.chars().all(|c| !c.is_control()))
        .filter(|_| {
            event.kind != KeyKind::Release
                && mode.contains(TermMode::REPORT_ASSOCIATED_TEXT)
                && mode.contains(TermMode::REPORT_ALL_KEYS_AS_ESC)
        });
    if let Some(text) = text {
        let points = text
            .chars()
            .map(|c| (c as u32).to_string())
            .collect::<Vec<_>>()
            .join(":");
        return Ok(format!("\x1b[{key};{modifier_field};{points}{suffix}").into_bytes());
    }
    if mods == 1 && event.kind == KeyKind::Press {
        if suffix != '~' && suffix != 'u' {
            return Ok(format!("\x1b[{suffix}").into_bytes());
        }
        return Ok(format!("\x1b[{key}{suffix}").into_bytes());
    }
    Ok(format!("\x1b[{key};{modifier_field}{suffix}").into_bytes())
}
fn code(key: Key, kitty: bool) -> Result<(u32, char), InputError> {
    Ok(match key {
        Key::Character(c) => (c as u32, 'u'),
        Key::Enter => (13, 'u'),
        Key::Tab => (9, 'u'),
        Key::Backspace => (127, 'u'),
        Key::Escape => (27, 'u'),
        Key::Insert => (2, '~'),
        Key::Delete => (3, '~'),
        Key::Left => (1, 'D'),
        Key::Right => (1, 'C'),
        Key::Up => (1, 'A'),
        Key::Down => (1, 'B'),
        Key::Home => (1, 'H'),
        Key::End => (1, 'F'),
        Key::PageUp => (5, '~'),
        Key::PageDown => (6, '~'),
        Key::Function(1) => (1, 'P'),
        Key::Function(2) => (1, 'Q'),
        Key::Function(3) => {
            if kitty {
                (13, '~')
            } else {
                (1, 'R')
            }
        }
        Key::Function(4) => (1, 'S'),
        Key::Function(n @ 5..=12) => ([15, 17, 18, 19, 20, 21, 23, 24][usize::from(n - 5)], '~'),
        Key::Function(n @ 13..=35) => (57376 + u32::from(n - 13), 'u'),
        Key::Functional(n @ 57358..=57454) => (n, 'u'),
        Key::Function(_) | Key::Functional(_) => return Err(InputError::InvalidKey),
    })
}
fn ctrl(c: char) -> char {
    match c {
        'a'..='z' => char::from(c as u8 - b'a' + 1),
        'A'..='Z' => char::from(c as u8 - b'A' + 1),
        ' ' | '@' | '2' => '\0',
        '[' | '3' => '\x1b',
        '\\' | '4' => '\x1c',
        ']' | '5' => '\x1d',
        '^' | '~' | '6' => '\x1e',
        '_' | '/' | '7' => '\x1f',
        '?' | '8' => '\x7f',
        _ => c,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Middle,
    Right,
}
#[derive(Debug, Clone, Copy)]
pub enum MouseAction {
    Press(MouseButton),
    Release(MouseButton),
    Motion(Option<MouseButton>),
    WheelUp,
    WheelDown,
}
#[derive(Debug, Clone, Copy)]
pub struct MouseEvent {
    pub column: u16,
    pub row: u16,
    pub action: MouseAction,
    pub modifiers: Modifiers,
}
pub(crate) fn mouse(mode: TermMode, columns: u16, rows: u16, event: MouseEvent) -> Vec<u8> {
    if !mode.intersects(TermMode::MOUSE_MODE) || event.column >= columns || event.row >= rows {
        return Vec::new();
    }
    let button = |b| match b {
        MouseButton::Left => 0,
        MouseButton::Middle => 1,
        MouseButton::Right => 2,
    };
    let mut release = false;
    let mut cb = match event.action {
        MouseAction::Press(b) => button(b),
        MouseAction::Release(b) => {
            release = true;
            button(b)
        }
        MouseAction::WheelUp => 64,
        MouseAction::WheelDown => 65,
        MouseAction::Motion(b) => {
            if !mode.contains(TermMode::MOUSE_MOTION)
                && !(mode.contains(TermMode::MOUSE_DRAG) && b.is_some())
            {
                return Vec::new();
            }
            32 + b.map(button).unwrap_or(3)
        }
    };
    cb += u16::from(event.modifiers.shift) * 4
        + u16::from(event.modifiers.alt) * 8
        + u16::from(event.modifiers.control) * 16;
    let x = event.column + 1;
    let y = event.row + 1;
    if mode.contains(TermMode::SGR_MOUSE) {
        format!("\x1b[<{cb};{x};{y}{}", if release { 'm' } else { 'M' }).into_bytes()
    } else {
        if release {
            cb = 3 + (cb & 28);
        }
        let mut out = b"\x1b[M".to_vec();
        if mode.contains(TermMode::UTF8_MOUSE) {
            if x > 2015 || y > 2015 {
                return Vec::new();
            }
            for n in [cb + 32, x + 32, y + 32] {
                if let Some(c) = char::from_u32(n.into()) {
                    out.extend_from_slice(c.encode_utf8(&mut [0; 4]).as_bytes());
                }
            }
        } else {
            if x > 223 || y > 223 {
                return Vec::new();
            }
            out.extend_from_slice(&[(cb + 32) as u8, (x + 32) as u8, (y + 32) as u8]);
        }
        out
    }
}

/// Preview UI owns the text. This result intentionally does not implement Debug.
pub enum PastePlan {
    Confirm {
        lines: usize,
        bytes: usize,
        bracketed: bool,
    },
    Ready(Vec<u8>),
}
pub(crate) fn paste(bracketed: bool, text: &str, confirmed: bool) -> Result<PastePlan, InputError> {
    if bracketed && text.contains("\x1b[201~") {
        return Err(InputError::PasteDelimiter);
    }
    if !confirmed
        && (text.contains(['\r', '\n'])
            || text.len() >= 4096
            || text.chars().any(|c| c.is_control() && c != '\t'))
    {
        let lines = text
            .split('\n')
            .map(|s| s.split('\r').count())
            .sum::<usize>()
            - text.matches("\r\n").count();
        return Ok(PastePlan::Confirm {
            lines,
            bytes: text.len(),
            bracketed,
        });
    }
    let mut out = Vec::with_capacity(text.len() + 12);
    if bracketed {
        out.extend_from_slice(b"\x1b[200~");
    }
    out.extend_from_slice(text.as_bytes());
    if bracketed {
        out.extend_from_slice(b"\x1b[201~");
    }
    Ok(PastePlan::Ready(out))
}
