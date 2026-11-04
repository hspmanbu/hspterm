//! One configurable application palette binding. This record contains no
//! terminal input and does not alter SSH keyboard-protocol encoding.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
const RECORD: &str = "config-command-palette-shortcut-v1";
#[derive(Debug, thiserror::Error)]
pub enum ShortcutError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("应用快捷键配置无效或版本不支持；原配置保留")]
    Format,
    #[error("应用快捷键与系统或已保留的复制/粘贴/新建标签键冲突")]
    Reserved,
    #[error("原配置库或快捷键设置已改变，请重新载入")]
    Changed,
}
type Result<T> = std::result::Result<T, ShortcutError>;
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PaletteShortcut {
    pub version: u32,
    pub enabled: bool,
    /// KeyA..KeyZ, Digit0..Digit9, F1..F12. Layout-independent logical names.
    pub key: String,
    /// Shift=1, Alt=2, Ctrl=4. Caps/Num lock never change this binding.
    pub modifiers: u8,
    /// Explicit opt-in: application consumes this one chord in SSH views.
    /// False preserves the existing remote terminal's first refusal.
    pub application_in_terminal: bool,
}
impl Default for PaletteShortcut {
    fn default() -> Self {
        Self {
            version: 1,
            enabled: true,
            key: "KeyP".into(),
            modifiers: 5,
            application_in_terminal: false,
        }
    }
}
impl PaletteShortcut {
    pub fn validate(&self) -> Result<()> {
        let key = self
            .key
            .strip_prefix("Key")
            .is_some_and(|s| s.len() == 1 && s.bytes().all(|b| b.is_ascii_uppercase()))
            || self
                .key
                .strip_prefix("Digit")
                .is_some_and(|s| s.len() == 1 && s.bytes().all(|b| b.is_ascii_digit()))
            || (1..=12).any(|i| self.key == format!("F{i}"));
        if self.version != 1 || !key || self.modifiers & !7 != 0 || self.modifiers & 6 == 0 {
            return Err(ShortcutError::Format);
        }
        if (self.key == "F4" && self.modifiers & 2 != 0)
            || (self.modifiers == 5 && ["KeyC", "KeyV", "KeyT"].contains(&self.key.as_str()))
            || (self.key == "KeyC" && self.modifiers == 4)
        {
            return Err(ShortcutError::Reserved);
        }
        Ok(())
    }
}
#[derive(Clone)]
pub struct ShortcutView {
    pub vault_scope: String,
    pub revision: String,
    pub value: PaletteShortcut,
}
fn revision(scope: &str, raw: Option<&[u8]>) -> String {
    let mut h = Sha256::new();
    h.update(b"HSPTerm palette shortcut v1\0");
    h.update((scope.len() as u64).to_le_bytes());
    h.update(scope.as_bytes());
    match raw {
        None => h.update([0]),
        Some(v) => {
            h.update([1]);
            h.update(v);
        }
    }
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}
pub fn load(vault: &Vault) -> Result<ShortcutView> {
    let raw = vault.get_bounded(RECORD, 4096)?;
    let value = match &raw {
        None => PaletteShortcut::default(),
        Some(v) => {
            serde_json::from_slice::<PaletteShortcut>(v).map_err(|_| ShortcutError::Format)?
        }
    };
    value.validate()?;
    Ok(ShortcutView {
        vault_scope: vault.instance_id().into(),
        revision: revision(vault.instance_id(), raw.as_deref().map(Vec::as_slice)),
        value,
    })
}
pub fn save(
    vault: &mut Vault,
    scope: &str,
    expected: &str,
    value: PaletteShortcut,
) -> Result<ShortcutView> {
    value.validate()?;
    if scope != vault.instance_id() {
        return Err(ShortcutError::Changed);
    }
    let old = load(vault)?;
    if old.revision != expected {
        return Err(ShortcutError::Changed);
    }
    let prior = vault.get_bounded(RECORD, 4096)?;
    if revision(scope, prior.as_deref().map(Vec::as_slice)) != expected {
        return Err(ShortcutError::Changed);
    }
    let next = serde_json::to_vec(&value).map_err(|_| ShortcutError::Format)?;
    if !vault.apply_checked(
        &[(RECORD, prior.as_deref().map(Vec::as_slice))],
        &[RecordChange::Put(RECORD, &next)],
    )? {
        return Err(ShortcutError::Changed);
    }
    Ok(ShortcutView {
        vault_scope: scope.into(),
        revision: revision(scope, Some(&next)),
        value,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validate_reserved_keys_and_default_remote_priority() {
        let mut value = PaletteShortcut::default();
        value.validate().unwrap();
        assert!(!value.application_in_terminal);
        for key in ["KeyA", "Digit8", "F12"] {
            value.key = key.into();
            value.validate().unwrap();
        }
        for key in ["KeyC", "KeyV", "KeyT"] {
            value.key = key.into();
            assert!(matches!(value.validate(), Err(ShortcutError::Reserved)));
        }
        for (key, modifiers) in [
            ("KeyP", 0),
            ("KeyP", 1),
            ("KeyP", 128),
            ("F13", 5),
            ("Keyé", 5),
            ("keyP", 5),
        ] {
            value.key = key.into();
            value.modifiers = modifiers;
            assert!(value.validate().is_err());
        }
        value.key = "F4".into();
        value.modifiers = 2;
        assert!(matches!(value.validate(), Err(ShortcutError::Reserved)));
    }
    #[test]
    fn encrypted_reopen_scope_stale_and_future_fields_preserve_data() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("shortcut.vault");
        let mut v = Vault::create(&path, b"synthetic-shortcut-master").unwrap();
        let first = load(&v).unwrap();
        let mut chosen = first.value.clone();
        chosen.key = "F8".into();
        chosen.modifiers = 3;
        chosen.application_in_terminal = true;
        let saved = save(&mut v, &first.vault_scope, &first.revision, chosen.clone()).unwrap();
        assert_eq!(saved.revision, load(&v).unwrap().revision);
        assert!(matches!(
            save(
                &mut v,
                &first.vault_scope,
                &first.revision,
                PaletteShortcut::default()
            ),
            Err(ShortcutError::Changed)
        ));
        assert!(matches!(
            save(&mut v, "other-scope", &saved.revision, chosen.clone()),
            Err(ShortcutError::Changed)
        ));
        drop(v);
        let mut v = Vault::open(&path, b"synthetic-shortcut-master").unwrap();
        assert_eq!(load(&v).unwrap().value, chosen);
        assert!(matches!(
            save(&mut v, &saved.vault_scope, &saved.revision, chosen),
            Err(ShortcutError::Changed)
        ));
        let valid = load(&v).unwrap();
        let mut future = serde_json::to_value(&valid.value).unwrap();
        future["future"] = true.into();
        let bytes = serde_json::to_vec(&future).unwrap();
        v.put(RECORD, &bytes).unwrap();
        assert!(load(&v).is_err());
        assert!(
            save(
                &mut v,
                &valid.vault_scope,
                &valid.revision,
                PaletteShortcut::default()
            )
            .is_err()
        );
        assert_eq!(v.get(RECORD).unwrap().unwrap().as_slice(), bytes);
    }
    #[test]
    fn storage_failure_does_not_publish_and_original_proposal_can_be_explicitly_retried() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(
            &dir.path().join("failure.vault"),
            b"synthetic-shortcut-master",
        )
        .unwrap();
        let before = load(&v).unwrap();
        v.db.execute_batch(&format!("CREATE TRIGGER reject_shortcut BEFORE INSERT ON records WHEN NEW.id='{RECORD}' BEGIN SELECT RAISE(ABORT,'synthetic shortcut failure'); END;")).unwrap();
        let mut value = before.value.clone();
        value.enabled = false;
        assert!(save(&mut v, &before.vault_scope, &before.revision, value.clone()).is_err());
        assert_eq!(load(&v).unwrap().revision, before.revision);
        v.db.execute_batch("DROP TRIGGER reject_shortcut").unwrap();
        assert!(
            !save(&mut v, &before.vault_scope, &before.revision, value)
                .unwrap()
                .value
                .enabled
        );
    }
}
