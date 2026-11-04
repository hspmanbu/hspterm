//! Non-secret application appearance, eligible for encrypted configuration
//! sync/backup. Window geometry and local font files are separate device data.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

pub const RECORD: &str = "config-appearance-v1";
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Theme {
    Dark,
    Light,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    theme: Theme,
}
#[derive(Clone, Serialize)]
pub struct View {
    pub vault_scope: String,
    pub revision: String,
    pub theme: Theme,
}
#[derive(Debug, thiserror::Error)]
pub enum AppearanceError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("外观配置版本不受支持或格式损坏，原设置保留")]
    Format,
    #[error("原配置库或外观设置已改变，请重新读取")]
    Changed,
}
type Result<T> = std::result::Result<T, AppearanceError>;
fn revision(scope: &str, bytes: Option<&[u8]>) -> String {
    let mut hash = Sha256::new();
    hash.update(b"HSPTerm appearance v1\0");
    hash.update(scope.as_bytes());
    match bytes {
        Some(raw) => {
            hash.update([1]);
            hash.update(raw);
        }
        None => hash.update([0]),
    }
    hash.finalize().iter().map(|b| format!("{b:02x}")).collect()
}
fn read(v: &Vault) -> Result<(Option<Zeroizing<Vec<u8>>>, Theme)> {
    let raw = v.get_bounded(RECORD, 1024)?;
    let theme = match &raw {
        None => Theme::Dark,
        Some(raw) => {
            let stored: Stored =
                serde_json::from_slice(raw).map_err(|_| AppearanceError::Format)?;
            if stored.version != 1 {
                return Err(AppearanceError::Format);
            }
            stored.theme
        }
    };
    Ok((raw, theme))
}
pub fn load(v: &Vault) -> Result<View> {
    let (raw, theme) = read(v)?;
    Ok(View {
        vault_scope: v.instance_id().into(),
        revision: revision(v.instance_id(), raw.as_deref().map(Vec::as_slice)),
        theme,
    })
}
pub fn save(v: &mut Vault, scope: &str, expected: &str, theme: Theme) -> Result<View> {
    if scope != v.instance_id() {
        return Err(AppearanceError::Changed);
    }
    let (prior, _) = read(v)?;
    if revision(scope, prior.as_deref().map(Vec::as_slice)) != expected {
        return Err(AppearanceError::Changed);
    }
    let raw = Zeroizing::new(
        serde_json::to_vec(&Stored { version: 1, theme }).map_err(|_| AppearanceError::Format)?,
    );
    let result = View {
        vault_scope: scope.into(),
        revision: revision(scope, Some(&raw)),
        theme,
    };
    if !v.apply_checked(
        &[(RECORD, prior.as_deref().map(Vec::as_slice))],
        &[RecordChange::Put(RECORD, &raw)],
    )? {
        return Err(AppearanceError::Changed);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dark_default_roundtrip_and_stale_vault_and_revision_protection() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("appearance.vault");
        let mut v = Vault::create(&path, b"synthetic-master").unwrap();
        let first = load(&v).unwrap();
        assert!(first.theme == Theme::Dark);
        let saved = save(&mut v, &first.vault_scope, &first.revision, Theme::Light).unwrap();
        assert!(load(&v).unwrap().theme == Theme::Light);
        assert!(save(&mut v, &first.vault_scope, &first.revision, Theme::Dark).is_err());
        drop(v);
        let mut reopened = Vault::open(&path, b"synthetic-master").unwrap();
        assert!(load(&reopened).unwrap().theme == Theme::Light);
        let revision = load(&reopened).unwrap().revision;
        assert!(save(&mut reopened, &saved.vault_scope, &revision, Theme::Dark).is_err());
    }
    #[test]
    fn unknown_format_or_failed_sql_does_not_overwrite_or_acknowledge_a_theme_change() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("bad.vault"), b"synthetic-master").unwrap();
        let first = load(&v).unwrap();
        v.db.execute_batch("CREATE TRIGGER fail_theme BEFORE INSERT ON records WHEN NEW.id='config-appearance-v1' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;").unwrap();
        assert!(save(&mut v, &first.vault_scope, &first.revision, Theme::Light).is_err());
        assert!(load(&v).unwrap().theme == Theme::Dark);
        v.db.execute_batch("DROP TRIGGER fail_theme;").unwrap();
        v.put(RECORD, br#"{"version":99,"theme":"light"}"#).unwrap();
        assert!(load(&v).is_err());
        assert!(save(&mut v, &first.vault_scope, &first.revision, Theme::Light).is_err());
    }
}
