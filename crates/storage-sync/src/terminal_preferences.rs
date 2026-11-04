//! Sync-eligible non-secret terminal preferences, separate from local font data.
use crate::{RecordChange, StorageError, Vault};
pub use hspterm_term_core::preferences::Settings;
use serde::Serialize;
use sha2::{Digest, Sha256};
pub const RECORD: &str = "config-terminal-preferences-v1";
#[derive(Debug, thiserror::Error)]
pub enum PreferencesError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error(transparent)]
    Invalid(#[from] hspterm_term_core::preferences::PreferencesError),
    #[error("终端设置版本不受支持或格式损坏；原设置保留")]
    Format,
    #[error("原配置库或终端设置已改变，请重新载入")]
    Changed,
}
type Result<T> = std::result::Result<T, PreferencesError>;
#[derive(Clone, Serialize)]
pub struct View {
    pub vault_scope: String,
    pub revision: String,
    pub value: Settings,
}
fn revision(scope: &str, raw: Option<&[u8]>) -> String {
    let mut h = Sha256::new();
    h.update(b"HSPTerm terminal preferences v1\0");
    h.update((scope.len() as u64).to_le_bytes());
    h.update(scope.as_bytes());
    match raw {
        Some(r) => {
            h.update([1]);
            h.update(r);
        }
        None => h.update([0]),
    };
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}
pub fn load(v: &Vault) -> Result<View> {
    load_with_history_default(v, platform_history_default())
}
pub(crate) fn platform_history_default() -> u32 {
    if cfg!(target_os = "android") {
        30_000
    } else {
        100_000
    }
}
pub fn load_with_history_default(v: &Vault, history_lines: u32) -> Result<View> {
    let raw = v.get_bounded(RECORD, 16384)?;
    let value = match &raw {
        None => Settings {
            history_lines,
            ..Settings::default()
        },
        Some(b) => serde_json::from_slice::<Settings>(b).map_err(|_| PreferencesError::Format)?,
    };
    value.validate()?;
    Ok(View {
        vault_scope: v.instance_id().into(),
        revision: revision(v.instance_id(), raw.as_deref().map(Vec::as_slice)),
        value,
    })
}
pub fn save(v: &mut Vault, scope: &str, expected: &str, value: Settings) -> Result<View> {
    value.validate()?;
    if scope != v.instance_id() {
        return Err(PreferencesError::Changed);
    }
    let old = load(v)?;
    if old.revision != expected {
        return Err(PreferencesError::Changed);
    }
    let prior = v.get_bounded(RECORD, 16384)?;
    if revision(scope, prior.as_deref().map(Vec::as_slice)) != expected {
        return Err(PreferencesError::Changed);
    }
    let next =
        zeroize::Zeroizing::new(serde_json::to_vec(&value).map_err(|_| PreferencesError::Format)?);
    let result = View {
        vault_scope: scope.into(),
        revision: revision(scope, Some(&next)),
        value,
    };
    if !v.apply_checked(
        &[(RECORD, prior.as_deref().map(Vec::as_slice))],
        &[RecordChange::Put(RECORD, &next)],
    )? {
        return Err(PreferencesError::Changed);
    }
    Ok(result)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_preferences_default_notifications_and_new_rules_persist_without_plaintext() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("notices.vault");
        let mut v = Vault::create(&path, b"synthetic-notices-master").unwrap();
        let source = load(&v).unwrap();
        let mut old = serde_json::to_value(&source.value).unwrap();
        old.as_object_mut().unwrap().remove("notifications");
        v.put(RECORD, &serde_json::to_vec(&old).unwrap()).unwrap();
        let legacy = load(&v).unwrap();
        assert_eq!(
            legacy.value.notifications,
            hspterm_term_core::notifications::Settings::default()
        );
        let mut next = legacy.value.clone();
        next.notifications.desktop = true;
        next.notifications.quiet_seconds = 15;
        next.notifications
            .rules
            .push(hspterm_term_core::notifications::Rule {
                text: "synthetic-output-rule-not-public".into(),
                regex: false,
                case_sensitive: true,
            });
        save(&mut v, &legacy.vault_scope, &legacy.revision, next.clone()).unwrap();
        drop(v);
        let v = Vault::open(&path, b"synthetic-notices-master").unwrap();
        assert_eq!(load(&v).unwrap().value, next);
        let bytes = std::fs::read(path).unwrap();
        const MARK: &[u8] = b"synthetic-output-rule-not-public";
        assert!(!bytes.windows(MARK.len()).any(|w| w == MARK));
    }
    #[test]
    fn encrypted_roundtrip_old_scope_revision_and_unknown_format_protection() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("terminal.vault");
        let mut v = Vault::create(&path, b"synthetic-terminal-master").unwrap();
        let initial = load(&v).unwrap();
        let mut settings = initial.value.clone();
        settings.osc52 = false;
        settings.cursor_shape = "beam".into();
        let saved = save(
            &mut v,
            &initial.vault_scope,
            &initial.revision,
            settings.clone(),
        )
        .unwrap();
        assert_eq!(saved.revision, load(&v).unwrap().revision);
        assert!(
            save(
                &mut v,
                &initial.vault_scope,
                &initial.revision,
                settings.clone()
            )
            .is_err()
        );
        drop(v);
        let mut v = Vault::open(&path, b"synthetic-terminal-master").unwrap();
        assert_eq!(load(&v).unwrap().value, settings);
        let reopened_revision = load(&v).unwrap().revision;
        assert!(
            save(
                &mut v,
                &saved.vault_scope,
                &reopened_revision,
                settings.clone()
            )
            .is_err()
        );
        v.put(RECORD, br#"{"version":99}"#).unwrap();
        assert!(load(&v).is_err());
        let scope = v.instance_id().to_owned();
        assert!(save(&mut v, &scope, "unknown", settings).is_err());
    }
}

#[cfg(test)]
mod transaction_tests {
    use super::*;
    #[test]
    fn sql_failure_does_not_acknowledge_or_replace_preferences() {
        let dir = tempfile::tempdir().unwrap();
        let mut v =
            Vault::create(&dir.path().join("preferences.vault"), b"synthetic-master").unwrap();
        let source = load(&v).unwrap();
        v.db.execute_batch("CREATE TRIGGER fail_preferences BEFORE INSERT ON records WHEN NEW.id='config-terminal-preferences-v1' BEGIN SELECT RAISE(ABORT,'synthetic preference failure'); END;").unwrap();
        let mut next = source.value.clone();
        next.osc52 = false;
        assert!(save(&mut v, &source.vault_scope, &source.revision, next).is_err());
        assert_eq!(load(&v).unwrap().revision, source.revision);
        assert!(v.get(RECORD).unwrap().is_none());
    }
}
