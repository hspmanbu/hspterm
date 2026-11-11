//! Terminal defaults only; remote OSC colors and DECSCUSR remain authoritative.
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Colors {
    pub foreground: u32,
    pub background: u32,
    pub cursor: u32,
    pub ansi: Vec<u32>,
}
impl Default for Colors {
    fn default() -> Self {
        Self {
            foreground: 0xe6ebf4,
            background: 0x10151d,
            cursor: 0xe6ebf4,
            ansi: (0..16)
                .map(|i| crate::default_color(i) & 0xffffff)
                .collect(),
        }
    }
}
impl Colors {
    /// Exact pre-round-12 default, used by the load-time fingerprint
    /// migration: a stored palette that matches this byte-for-byte was
    /// never customized and safely upgrades to the new default.
    pub fn legacy_default() -> Self {
        Self {
            foreground: 0xd8dee9,
            background: 0x10151d,
            cursor: 0xd8dee9,
            ansi: crate::legacy_default_ansi().to_vec(),
        }
    }
}
impl Colors {
    pub fn light() -> Self {
        Self {
            foreground: 0x24364a,
            background: 0xf6f8fb,
            cursor: 0x24364a,
            ansi: vec![
                0x1c2733, 0xb42330, 0x387531, 0x926600, 0x225cb6, 0x7543a2, 0x177477, 0x526174,
                0x6c7a89, 0xd43944, 0x42923a, 0xb08000, 0x3c73ce, 0x9757be, 0x198d92, 0xc3cbd5,
            ],
        }
    }
    pub fn color(&self, index: usize) -> Option<u32> {
        Some(match index {
            0..=15 => *self.ansi.get(index)?,
            256 | 267 => self.foreground,
            257 => self.background,
            258 => self.cursor,
            259..=266 => dim(*self.ansi.get(index - 259)?),
            268 => dim(self.foreground),
            _ => return None,
        })
    }
}
fn dim(rgb: u32) -> u32 {
    (((rgb >> 16 & 255) * 2 / 3) << 16) | (((rgb >> 8 & 255) * 2 / 3) << 8) | ((rgb & 255) * 2 / 3)
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Typography {
    pub size: f64,
    pub line_height: f64,
    pub padding: f64,
    pub ligatures: bool,
    /// Only bundled families are portable. Device font mappings remain local.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub builtin_family: Option<String>,
}
impl Typography {
    pub fn validate(&self) -> Result<(), PreferencesError> {
        if !self.size.is_finite()
            || !(9.0..=36.0).contains(&self.size)
            || !self.line_height.is_finite()
            || !(1.0..=2.0).contains(&self.line_height)
            || !self.padding.is_finite()
            || !(0.0..=32.0).contains(&self.padding)
            || self.builtin_family.as_ref().is_some_and(|family| {
                !matches!(
                    family.as_str(),
                    "JetBrainsMono" | "NotoSansCJK" | "JetBrainsMonoNerd"
                )
            })
        {
            return Err(PreferencesError);
        }
        Ok(())
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImagePasteShortcut {
    pub enabled: bool,
    pub key: String,
    pub modifiers: u8,
}
impl Default for ImagePasteShortcut {
    fn default() -> Self {
        Self {
            enabled: true,
            key: "KeyV".into(),
            modifiers: 6,
        }
    }
}
impl ImagePasteShortcut {
    fn validate(&self) -> Result<(), PreferencesError> {
        let key = self
            .key
            .strip_prefix("Key")
            .is_some_and(|k| k.len() == 1 && k.bytes().all(|b| b.is_ascii_uppercase()))
            || self
                .key
                .strip_prefix('F')
                .and_then(|k| k.parse::<u8>().ok())
                .is_some_and(|n| (1..=12).contains(&n) && self.key == format!("F{n}"));
        // Require an explicit Ctrl+Alt or Ctrl+Shift chord. Ordinary typing,
        // text paste/copy and terminal search keep their established keys.
        if !key
            || !matches!(self.modifiers, 5..=7)
            || self.modifiers == 5 && matches!(self.key.as_str(), "KeyV" | "KeyC" | "KeyF")
        {
            return Err(PreferencesError);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub version: u32,
    pub history_lines: u32,
    pub cursor_shape: String,
    pub cursor_blink: bool,
    pub osc52: bool,
    pub right_click_paste: bool,
    /// Copy on mouse-selection release; an all-whitespace selection copies
    /// nothing. Purely local clipboard behavior, never remote content edits.
    #[serde(default)]
    pub copy_on_selection: bool,
    /// Allow pasting quoted paths straight into the interactive program when
    /// the exact shell-integration insert is unavailable. Default on
    /// (round-8); old records without the key keep the default.
    #[serde(default = "default_paste_paths_direct")]
    pub paste_paths_direct: bool,
    #[serde(default)]
    pub image_paste_shortcut: ImagePasteShortcut,
    pub colors: Colors,
    #[serde(default)]
    pub notifications: crate::notifications::Settings,
    /// Portable layout and bundled preset. No system/imported font name/path/bytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub typography: Option<Typography>,
}
fn default_paste_paths_direct() -> bool {
    true
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            version: 1,
            history_lines: 100000,
            cursor_shape: "block".into(),
            cursor_blink: false,
            osc52: true,
            right_click_paste: false,
            copy_on_selection: false,
            paste_paths_direct: true,
            image_paste_shortcut: ImagePasteShortcut::default(),
            colors: Colors::default(),
            notifications: crate::notifications::Settings::default(),
            typography: None,
        }
    }
}
#[derive(Debug, thiserror::Error)]
#[error("终端设置格式或参数范围无效；原设置保留")]
pub struct PreferencesError;
pub struct Validated(Settings, crate::notifications::Prepared);
impl Validated {
    pub fn settings(&self) -> &Settings {
        &self.0
    }
    pub(crate) fn notifications(&self) -> crate::notifications::Prepared {
        self.1.clone()
    }
}
impl Settings {
    pub fn validated(&self) -> Result<Validated, PreferencesError> {
        self.validate()?;
        Ok(Validated(self.clone(), self.notifications.prepare()?))
    }
    pub fn validate(&self) -> Result<(), PreferencesError> {
        self.image_paste_shortcut.validate()?;
        if let Some(value) = &self.typography {
            value.validate()?;
        }
        self.notifications.prepare()?;
        if self.version != 1
            || self.history_lines > 1000000
            || !matches!(self.cursor_shape.as_str(), "block" | "underline" | "beam")
            || self.colors.ansi.len() != 16
            || [
                self.colors.foreground,
                self.colors.background,
                self.colors.cursor,
            ]
            .into_iter()
            .chain(self.colors.ansi.iter().copied())
            .any(|c| c > 0xffffff)
        {
            return Err(PreferencesError);
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Size, Terminal};
    #[test]
    fn paste_paths_direct_defaults_on_and_reads_old_records() {
        // Old v1 records (round-7 and earlier) carry no key: the direct path
        // paste fallback stays enabled by default, and explicit false
        // round-trips.
        let mut value = Settings::default();
        assert!(value.paste_paths_direct);
        let mut old = serde_json::to_value(&value).unwrap();
        value.paste_paths_direct = false;
        let disabled = serde_json::to_value(&value).unwrap();
        assert_eq!(disabled["paste_paths_direct"], false);
        old.as_object_mut().unwrap().remove("paste_paths_direct");
        let parsed: Settings = serde_json::from_value(old).unwrap();
        assert!(parsed.paste_paths_direct);
        // A future unknown field still fails closed instead of being dropped.
        let mut unknown = serde_json::to_value(Settings::default()).unwrap();
        unknown
            .as_object_mut()
            .unwrap()
            .insert("future_field".into(), serde_json::Value::Bool(true));
        assert!(serde_json::from_value::<Settings>(unknown).is_err());
    }
    #[test]
    fn portable_geometry_is_finite_bounded_and_validated_with_shared_preferences() {
        let geometry = Typography {
            size: 17.,
            line_height: 1.4,
            padding: 8.,
            ligatures: false,
            builtin_family: None,
        };
        geometry.validate().unwrap();
        assert!(
            Typography {
                builtin_family: Some("private-local-font".into()),
                ..geometry.clone()
            }
            .validate()
            .is_err()
        );
        for bad in [f64::NAN, f64::INFINITY, 0., 37.] {
            assert!(
                Typography {
                    size: bad,
                    ..geometry.clone()
                }
                .validate()
                .is_err()
            );
        }
        let invalid = Typography {
            line_height: 2.1,
            ..geometry.clone()
        };
        assert!(
            Settings {
                typography: Some(invalid),
                ..Settings::default()
            }
            .validated()
            .is_err()
        );
        for padding in [-1., 33., f64::NAN] {
            assert!(
                Typography {
                    padding,
                    ..geometry.clone()
                }
                .validate()
                .is_err()
            );
        }
    }
    #[test]
    fn remote_cursor_and_palette_temporarily_override_defaults_then_reset() {
        let mut t = Terminal::new(Size::new(20, 4).unwrap(), 100).unwrap();
        let mut p = Settings {
            cursor_shape: "beam".into(),
            cursor_blink: true,
            colors: Colors::light(),
            ..Settings::default()
        };
        t.set_preferences(&p).unwrap();
        let s = t.snapshot();
        assert_eq!(s.cursor_shape, 2);
        assert!(s.cursor_blink);
        assert_eq!(s.palette[257], Some([246, 248, 251]));
        t.feed(b"\x1b[4 q\x1b]11;#112233\x07").unwrap();
        p.cursor_shape = "block".into();
        p.colors.background = 0xabcdef;
        t.set_preferences(&p).unwrap();
        let s = t.snapshot();
        assert_eq!(s.cursor_shape, 1);
        assert!(!s.cursor_blink);
        assert_eq!(s.palette[257], Some([17, 34, 51]));
        t.feed(b"\x1b[0 q\x1b]111\x07").unwrap();
        let s = t.snapshot();
        assert_eq!(s.cursor_shape, 0);
        assert!(s.cursor_blink);
        assert_eq!(s.palette[257], Some([171, 205, 239]));
        t.begin_new_generation();
        let s = t.snapshot();
        assert_eq!(s.cursor_shape, 0);
        assert_eq!(s.palette[257], Some([171, 205, 239]));
    }
    #[test]
    fn defaults_do_not_rewrite_grid_or_truecolor_and_invalid_changes_are_atomic() {
        let mut t = Terminal::new(Size::new(20, 4).unwrap(), 100).unwrap();
        t.feed(b"\x1b[38;2;1;2;3mOriginal").unwrap();
        let before = t.snapshot();
        let p = Settings {
            osc52: false,
            colors: Colors::light(),
            ..Settings::default()
        };
        t.set_preferences(&p).unwrap();
        let after = t.snapshot();
        assert_eq!(after.cells, before.cells);
        assert_eq!(after.content_revision, before.content_revision);
        let mut invalid = p.clone();
        invalid.colors.ansi.clear();
        assert!(t.set_preferences(&invalid).is_err());
        assert_eq!(t.snapshot().palette, after.palette);
    }
    #[test]
    fn color_queries_use_user_defaults_without_overriding_remote_osc() {
        let mut t = Terminal::new(Size::new(20, 4).unwrap(), 100).unwrap();
        let p = Settings {
            colors: Colors::light(),
            ..Settings::default()
        };
        t.set_preferences(&p).unwrap();
        t.feed(b"\x1b]11;?\x07").unwrap();
        let replies: Vec<_> = t
            .take_events()
            .iter()
            .filter_map(|e| t.protocol_reply(e))
            .collect();
        assert!(replies.iter().any(|s| s.contains("f6f6/f8f8/fbfb")));
        t.feed(b"\x1b]11;#112233\x07\x1b]11;?\x07").unwrap();
        let replies: Vec<_> = t
            .take_events()
            .iter()
            .filter_map(|e| t.protocol_reply(e))
            .collect();
        assert!(replies.iter().any(|s| s.contains("1111/2222/3333")));
    }
    #[test]
    fn image_shortcut_defaults_migrate_and_invalid_chords_do_not_change_terminal() {
        let mut value = serde_json::to_value(Settings::default()).unwrap();
        value
            .as_object_mut()
            .unwrap()
            .remove("image_paste_shortcut");
        let settings: Settings = serde_json::from_value(value).unwrap();
        assert_eq!(settings.image_paste_shortcut, ImagePasteShortcut::default());
        let mut terminal = Terminal::new(Size::new(20, 4).unwrap(), 100).unwrap();
        terminal.set_preferences(&settings).unwrap();
        let before = terminal.snapshot().image_paste_shortcut;
        for key in ["KeyV", "KeyC", "KeyF", "F01", "Enter"] {
            let mut invalid = settings.clone();
            invalid.image_paste_shortcut.key = key.into();
            invalid.image_paste_shortcut.modifiers = 5;
            assert!(terminal.set_preferences(&invalid).is_err());
            assert_eq!(terminal.snapshot().image_paste_shortcut, before);
        }
        let mut changed = settings;
        changed.image_paste_shortcut.key = "F12".into();
        terminal.set_preferences(&changed).unwrap();
        assert!(terminal.snapshot().image_paste_shortcut.contains("F12"));
    }
}
