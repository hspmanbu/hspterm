//! User configuration only; file bodies and preview tickets never enter Vault.
use crate::{StorageError, Vault};
use serde::{Deserialize, Serialize};

const RECORD: &str = "config-file-open-settings-v1";
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileOpenSettings {
    pub version: u32,
    /// Zero asks for every file, including empty files. Otherwise ask strictly
    /// above this many MiB. u32 MiB fits exactly in a u64 byte count.
    pub confirmation_mib: u32,
}
impl Default for FileOpenSettings {
    fn default() -> Self {
        Self {
            version: 1,
            confirmation_mib: 100,
        }
    }
}
impl FileOpenSettings {
    pub fn requires_confirmation(self, size: u64) -> bool {
        self.confirmation_mib == 0 || size > u64::from(self.confirmation_mib) * 1024 * 1024
    }
    pub fn load(vault: &Vault) -> Result<Self, StorageError> {
        let Some(raw) = vault.get(RECORD)? else {
            return Ok(Self::default());
        };
        if raw.len() > 4096 {
            return Err(StorageError::Format);
        }
        let value: Self = serde_json::from_slice(&raw).map_err(|_| StorageError::Format)?;
        if value.version != 1 {
            return Err(StorageError::Format);
        }
        Ok(value)
    }
    pub fn save(self, vault: &mut Vault) -> Result<(), StorageError> {
        if self.version != 1 {
            return Err(StorageError::Format);
        }
        // Refuse to replace an unreadable or newer configuration with defaults.
        Self::load(vault)?;
        vault.put(
            RECORD,
            &serde_json::to_vec(&self).map_err(|_| StorageError::Format)?,
        )
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn confirmation_is_strict_and_zero_always_asks_without_byte_overflow() {
        let value = FileOpenSettings::default();
        assert!(!value.requires_confirmation(0));
        assert!(!value.requires_confirmation(100 * 1024 * 1024));
        assert!(value.requires_confirmation(100 * 1024 * 1024 + 1));
        assert!(
            FileOpenSettings {
                confirmation_mib: 0,
                ..value
            }
            .requires_confirmation(0)
        );
        let largest = FileOpenSettings {
            confirmation_mib: u32::MAX,
            ..value
        };
        let boundary = u64::from(u32::MAX) * 1024 * 1024;
        assert!(!largest.requires_confirmation(boundary));
        assert!(largest.requires_confirmation(boundary + 1));
    }
    #[test]
    fn encrypted_settings_reopen_and_unknown_versions_cannot_be_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("file-settings.vault");
        let mut vault = Vault::create(&path, b"test-only-file-settings").unwrap();
        let defaults = FileOpenSettings::default();
        assert_eq!(FileOpenSettings::load(&vault).unwrap(), defaults);
        let custom = FileOpenSettings {
            confirmation_mib: 1234567,
            ..defaults
        };
        custom.save(&mut vault).unwrap();
        drop(vault);
        assert!(!String::from_utf8_lossy(&std::fs::read(&path).unwrap()).contains("1234567"));
        let mut vault = Vault::open(&path, b"test-only-file-settings").unwrap();
        assert_eq!(FileOpenSettings::load(&vault).unwrap(), custom);
        for raw in [
            br#"{"version":2,"confirmation_mib":100}"#.as_slice(),
            br#"{"version":1,"confirmation_mib":-1}"#,
            br#"{"version":1,"confirmation_mib":100,"new_option":true}"#,
        ] {
            vault.put(RECORD, raw).unwrap();
            assert!(FileOpenSettings::load(&vault).is_err());
            assert!(defaults.save(&mut vault).is_err());
            assert_eq!(vault.get(RECORD).unwrap().unwrap().as_slice(), raw);
        }
    }
}
