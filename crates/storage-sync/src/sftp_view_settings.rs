//! Portable, encrypted SFTP browsing defaults. Per-window menu choices are local.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::Zeroizing;

pub const RECORD: &str = "config-sftp-view-v1";
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub folders_first: bool,
    pub show_hidden: bool,
    pub compact: bool,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            folders_first: true,
            show_hidden: false,
            compact: false,
        }
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    settings: Settings,
}
#[derive(Clone, Serialize)]
pub struct View {
    pub vault_scope: String,
    pub revision: String,
    pub settings: Settings,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Proposal {
    pub vault_scope: String,
    pub revision: String,
    pub settings: Settings,
}
#[derive(Debug, thiserror::Error)]
pub enum ViewSettingsError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("SFTP浏览配置版本不受支持或格式损坏，原设置保留")]
    Format,
    #[error("原配置库或SFTP浏览设置已改变，请重新读取")]
    Changed,
}
type Result<T> = std::result::Result<T, ViewSettingsError>;
fn revision(scope: &str, bytes: Option<&[u8]>) -> String {
    let mut hash = Sha256::new();
    hash.update(b"HSPTerm SFTP view v1\0");
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
fn read(v: &Vault) -> Result<(Option<Zeroizing<Vec<u8>>>, Settings)> {
    let raw = v.get_bounded(RECORD, 1024)?;
    let settings = match &raw {
        None => Settings::default(),
        Some(raw) => {
            let stored: Stored =
                serde_json::from_slice(raw).map_err(|_| ViewSettingsError::Format)?;
            if stored.version != 1 {
                return Err(ViewSettingsError::Format);
            }
            stored.settings
        }
    };
    Ok((raw, settings))
}
pub fn load(v: &Vault) -> Result<View> {
    let (raw, settings) = read(v)?;
    Ok(View {
        vault_scope: v.instance_id().into(),
        revision: revision(v.instance_id(), raw.as_deref().map(Vec::as_slice)),
        settings,
    })
}
pub fn save(v: &mut Vault, proposal: Proposal) -> Result<View> {
    let Proposal {
        vault_scope: scope,
        revision: expected,
        settings,
    } = proposal;
    if scope != v.instance_id() {
        return Err(ViewSettingsError::Changed);
    }
    let (prior, _) = read(v)?;
    if revision(&scope, prior.as_deref().map(Vec::as_slice)) != expected {
        return Err(ViewSettingsError::Changed);
    }
    let raw = Zeroizing::new(
        serde_json::to_vec(&Stored {
            version: 1,
            settings,
        })
        .map_err(|_| ViewSettingsError::Format)?,
    );
    let result = View {
        vault_scope: scope.clone(),
        revision: revision(&scope, Some(&raw)),
        settings,
    };
    if !v.apply_checked(
        &[(RECORD, prior.as_deref().map(Vec::as_slice))],
        &[RecordChange::Put(RECORD, &raw)],
    )? {
        return Err(ViewSettingsError::Changed);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn proposal(source: &View, settings: Settings) -> Proposal {
        Proposal {
            vault_scope: source.vault_scope.clone(),
            revision: source.revision.clone(),
            settings,
        }
    }
    #[test]
    fn defaults_roundtrip_stale_revision_and_original_vault() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("view.vault");
        let mut v = Vault::create(&path, b"synthetic-master").unwrap();
        let first = load(&v).unwrap();
        assert_eq!(first.settings, Settings::default());
        let selected = Settings {
            folders_first: false,
            show_hidden: true,
            compact: true,
        };
        let saved = save(&mut v, proposal(&first, selected)).unwrap();
        assert_eq!(load(&v).unwrap().settings, selected);
        assert!(save(&mut v, proposal(&first, Settings::default())).is_err());
        drop(v);
        let mut reopened = Vault::open(&path, b"synthetic-master").unwrap();
        let current = load(&reopened).unwrap();
        assert_eq!(current.settings, selected);
        assert!(
            save(
                &mut reopened,
                Proposal {
                    vault_scope: saved.vault_scope,
                    revision: current.revision,
                    settings: selected
                }
            )
            .is_err()
        );
    }
    #[test]
    fn malformed_or_failed_transaction_never_acknowledges_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("view.vault"), b"synthetic-master").unwrap();
        let first = load(&v).unwrap();
        v.db.execute_batch("CREATE TRIGGER fail_view BEFORE INSERT ON records WHEN NEW.id='config-sftp-view-v1' BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
        assert!(
            save(
                &mut v,
                proposal(
                    &first,
                    Settings {
                        show_hidden: true,
                        ..Settings::default()
                    }
                )
            )
            .is_err()
        );
        assert_eq!(load(&v).unwrap().settings, Settings::default());
        v.db.execute_batch("DROP TRIGGER fail_view;").unwrap();
        for raw in [br#"{"version":99,"settings":{"folders_first":true,"show_hidden":false,"compact":false}}"#.as_slice(), br#"{"version":1,"settings":{"folders_first":true,"show_hidden":false,"compact":false,"unknown":true}}"#] {
            v.put(RECORD, raw).unwrap();
            assert!(load(&v).is_err());
            assert!(save(&mut v, proposal(&first, Settings::default())).is_err());
        }
    }
}
