//! Versioned, encrypted display-only configuration. No terminal mutation or I/O.
use crate::{RecordChange, StorageError, Vault};
use hspterm_term_core::decorations::{Config, Decorator};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;
const MAX_BYTES: usize = 64 * 1024;
const GLOBAL: &str = "config-terminal-decorations-v1";
#[derive(Debug, thiserror::Error)]
pub enum DisplayError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("显示设置无效或版本不支持；原数据保留")]
    Format,
    #[error("显示设置已更改，请重新载入后保存")]
    Changed,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DisplaySettings {
    pub version: u32,
    pub revision: u64,
    /// None means built-in defaults globally, or inherit global for a host.
    pub config: Option<Config>,
}
impl Default for DisplaySettings {
    fn default() -> Self {
        Self {
            version: 1,
            revision: 0,
            config: None,
        }
    }
}
pub(crate) fn host_key(id: &str) -> String {
    format!("host-terminal-decorations-v1-{id}")
}
fn key(host: Option<&str>) -> Result<String, DisplayError> {
    match host {
        None => Ok(GLOBAL.into()),
        Some(id) if crate::repository::valid_id(id, "host") => Ok(host_key(id)),
        _ => Err(DisplayError::Format),
    }
}
impl DisplaySettings {
    pub fn load(vault: &Vault, host: Option<&str>) -> Result<Self, DisplayError> {
        let Some(raw) = vault.get_bounded(&key(host)?, MAX_BYTES)? else {
            return Ok(Self::default());
        };
        let value: Self = serde_json::from_slice(&raw).map_err(|_| DisplayError::Format)?;
        value.validate()?;
        Ok(value)
    }
    fn validate(&self) -> Result<(), DisplayError> {
        if self.version != 1 {
            return Err(DisplayError::Format);
        }
        if let Some(config) = &self.config {
            Decorator::new(config.clone()).map_err(|_| DisplayError::Format)?;
        }
        Ok(())
    }
    pub fn effective(vault: &Vault, host: Option<&str>) -> Result<Config, DisplayError> {
        if let Some(id) = host
            && let Some(config) = Self::load(vault, Some(id))?.config
        {
            return Ok(config);
        }
        Ok(Self::load(vault, None)?.config.unwrap_or_default())
    }
    pub fn save(
        vault: &mut Vault,
        host: Option<&str>,
        expected_revision: u64,
        config: Option<Config>,
    ) -> Result<Self, DisplayError> {
        let key = key(host)?;
        let prior = vault.get_bounded(&key, MAX_BYTES)?;
        let old = Self::load(vault, host)?;
        if old.revision != expected_revision {
            return Err(DisplayError::Changed);
        }
        let value = Self {
            version: 1,
            revision: old.revision.checked_add(1).ok_or(DisplayError::Format)?,
            config,
        };
        value.validate()?;
        let bytes = Zeroizing::new(serde_json::to_vec(&value).map_err(|_| DisplayError::Format)?);
        if bytes.len() > MAX_BYTES {
            return Err(DisplayError::Format);
        }
        if !vault.apply_checked(
            &[(&key, prior.as_deref().map(Vec::as_slice))],
            &[RecordChange::Put(&key, &bytes)],
        )? {
            return Err(DisplayError::Changed);
        }
        Ok(value)
    }
    /// Copy only the explicit override, with a fresh local revision. Both this
    /// row and the draft catalog are published by Repository's single transaction.
    pub(crate) fn copy_raw(
        vault: &Vault,
        host: &str,
    ) -> Result<Option<Zeroizing<Vec<u8>>>, DisplayError> {
        let mut document = Self::load(vault, Some(host))?;
        if document.config.is_none() {
            return Ok(None);
        }
        document.revision = 1;
        Ok(Some(Zeroizing::new(
            serde_json::to_vec(&document).map_err(|_| DisplayError::Format)?,
        )))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn encrypted_revision_scope_inheritance_tombstone_and_future_format_are_preserved() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("display.vault");
        let mut vault = Vault::create(&path, b"synthetic-display-master").unwrap();
        let host = "host-00000000000000000000000000000001";
        let config = Config {
            enabled: true,
            semantic: true,
            ..Config::default()
        };
        let saved = DisplaySettings::save(&mut vault, None, 0, Some(config.clone())).unwrap();
        assert_eq!(saved.revision, 1);
        assert_eq!(
            DisplaySettings::effective(&vault, Some(host)).unwrap(),
            config
        );
        let custom = Config {
            rainbow: true,
            ..config.clone()
        };
        DisplaySettings::save(&mut vault, Some(host), 0, Some(custom.clone())).unwrap();
        assert_eq!(
            DisplaySettings::effective(&vault, Some(host)).unwrap(),
            custom
        );
        DisplaySettings::save(&mut vault, Some(host), 1, None).unwrap();
        assert!(matches!(
            DisplaySettings::save(&mut vault, Some(host), 0, Some(custom)),
            Err(DisplayError::Changed)
        ));
        assert_eq!(
            DisplaySettings::effective(&vault, Some(host)).unwrap(),
            config
        );
        vault
            .put(GLOBAL, b"{\"version\":9,\"revision\":2,\"config\":null}")
            .unwrap();
        let before = vault.get(GLOBAL).unwrap().unwrap();
        assert!(DisplaySettings::save(&mut vault, None, 2, None).is_err());
        assert_eq!(&*vault.get(GLOBAL).unwrap().unwrap(), &*before);
    }
}

#[cfg(test)]
mod host_tests {
    use super::*;
    use crate::{AuthMethod, Credential, HostRecord, Repository};
    #[test]
    fn host_copy_discard_delete_and_failed_copy_keep_override_in_the_same_transaction() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &dir.path().join("host-display.vault"),
            b"synthetic-display-master",
        )
        .unwrap();
        let original = Repository::new(&mut vault)
            .save(
                HostRecord::new(
                    "display fixture".into(),
                    "fixture.invalid".into(),
                    "fixture".into(),
                    AuthMethod::Password,
                ),
                Some(Credential {
                    secret: "synthetic-only-password".into(),
                    passphrase: None,
                }),
            )
            .unwrap();
        let config = Config {
            enabled: true,
            rainbow: true,
            ..Config::default()
        };
        DisplaySettings::save(&mut vault, Some(&original.id), 0, Some(config.clone())).unwrap();
        vault.db.execute_batch("CREATE TRIGGER reject_display_copy BEFORE INSERT ON records WHEN NEW.id LIKE 'host-terminal-decorations-v1-%' BEGIN SELECT RAISE(ABORT,'synthetic rejection'); END;").unwrap();
        assert!(
            Repository::new(&mut vault)
                .copy_to_draft(&original.id)
                .is_err()
        );
        assert!(Repository::new(&mut vault).drafts().unwrap().is_empty());
        assert_eq!(Repository::new(&mut vault).list().unwrap().len(), 1);
        vault
            .db
            .execute_batch("DROP TRIGGER reject_display_copy;")
            .unwrap();
        let draft = Repository::new(&mut vault)
            .copy_to_draft(&original.id)
            .unwrap();
        assert_eq!(
            DisplaySettings::load(&vault, Some(&draft.id))
                .unwrap()
                .config,
            Some(config.clone())
        );
        Repository::new(&mut vault)
            .discard_draft(&draft.id)
            .unwrap();
        assert!(vault.get(&host_key(&draft.id)).unwrap().is_none());
        assert_eq!(
            DisplaySettings::load(&vault, Some(&original.id))
                .unwrap()
                .config,
            Some(config)
        );
        Repository::new(&mut vault)
            .delete(std::slice::from_ref(&original.id))
            .unwrap();
        assert!(vault.get(&host_key(&original.id)).unwrap().is_none());
    }
    #[test]
    fn imported_metadata_without_credentials_can_be_copied_to_an_unconnectable_draft() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &dir.path().join("metadata-display.vault"),
            b"synthetic-display-master",
        )
        .unwrap();
        let host = Repository::new(&mut vault)
            .import_openssh(
                "Host imported\n User fixture",
                "",
                &["imported".into()],
                true,
                "group-default",
            )
            .unwrap()
            .remove(0);
        let draft = Repository::new(&mut vault).copy_to_draft(&host.id).unwrap();
        let mut repo = Repository::new(&mut vault);
        assert!(repo.host(&draft.id).unwrap().is_none());
        assert!(repo.drafts().unwrap()[0].credential.is_none());
        assert!(repo.save(draft, None).is_err());
        assert_eq!(repo.list().unwrap().len(), 1);
    }
}
