use hspterm_storage_sync::shortcut_settings as domain;
#[derive(Clone)]
pub struct PaletteShortcutView {
    pub vault_scope: String,
    pub revision: String,
    pub enabled: bool,
    pub key: String,
    pub modifiers: u8,
    pub application_in_terminal: bool,
}
impl From<domain::ShortcutView> for PaletteShortcutView {
    fn from(v: domain::ShortcutView) -> Self {
        Self {
            vault_scope: v.vault_scope,
            revision: v.revision,
            enabled: v.value.enabled,
            key: v.value.key,
            modifiers: v.value.modifiers,
            application_in_terminal: v.value.application_in_terminal,
        }
    }
}
impl PaletteShortcutView {
    pub(crate) fn config(self) -> domain::PaletteShortcut {
        domain::PaletteShortcut {
            version: 1,
            enabled: self.enabled,
            key: self.key,
            modifiers: self.modifiers,
            application_in_terminal: self.application_in_terminal,
        }
    }
}
