//! User configuration, separate from device-local resumable task manifests.
use crate::{StorageError, Vault};
use serde::{Deserialize, Serialize};
const RECORD: &str = "config-transfer-settings-v1";
/// Engineering bound, not a claim about achievable network throughput.
pub const MAX_RATE: u64 = 1024 * 1024 * 1024 * 1024;
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DefaultConflict {
    #[default]
    Ask,
    Overwrite,
    Skip,
    Rename,
}
impl DefaultConflict {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ask => "ask",
            Self::Overwrite => "overwrite",
            Self::Skip => "skip",
            Self::Rename => "rename",
        }
    }
    pub fn parse(value: &str) -> Result<Self, StorageError> {
        match value {
            "ask" => Ok(Self::Ask),
            "overwrite" => Ok(Self::Overwrite),
            "skip" => Ok(Self::Skip),
            "rename" => Ok(Self::Rename),
            _ => Err(StorageError::Format),
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TransferSettings {
    pub version: u32,
    pub concurrency: u32,
    pub upload_bytes_per_second: u64,
    pub download_bytes_per_second: u64,
    #[serde(default)]
    pub default_conflict: DefaultConflict,
    /// Applies only to an explicit reconnect in the same running application.
    #[serde(default)]
    pub resume_on_reconnect: bool,
}
impl Default for TransferSettings {
    fn default() -> Self {
        Self {
            version: 1,
            concurrency: 3,
            upload_bytes_per_second: 0,
            download_bytes_per_second: 0,
            default_conflict: DefaultConflict::Ask,
            resume_on_reconnect: false,
        }
    }
}
impl TransferSettings {
    pub fn validate(&self) -> Result<(), StorageError> {
        if self.version != 1
            || !(1..=32).contains(&self.concurrency)
            || self.upload_bytes_per_second > MAX_RATE
            || self.download_bytes_per_second > MAX_RATE
        {
            return Err(StorageError::Format);
        }
        Ok(())
    }
    pub fn load(vault: &Vault) -> Result<Self, StorageError> {
        let Some(raw) = vault.get(RECORD)? else {
            return Ok(Self::default());
        };
        if raw.len() > 4096 {
            return Err(StorageError::Format);
        }
        let value: Self = serde_json::from_slice(&raw).map_err(|_| StorageError::Format)?;
        value.validate()?;
        Ok(value)
    }
    /// Validate before write. Newer/invalid records are never silently reset.
    pub fn save(&self, vault: &mut Vault) -> Result<(), StorageError> {
        self.validate()?;
        Self::load(vault)?;
        let raw = serde_json::to_vec(self).map_err(|_| StorageError::Format)?;
        vault.put(RECORD, &raw)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn settings_reopen_and_invalid_changes_preserve_the_saved_record() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("settings.vault");
        let mut vault = Vault::create(&path, b"test-only-settings").unwrap();
        assert_eq!(
            TransferSettings::load(&vault).unwrap(),
            TransferSettings::default()
        );
        let settings = TransferSettings {
            concurrency: 2,
            upload_bytes_per_second: 123456789,
            download_bytes_per_second: 987654321,
            default_conflict: DefaultConflict::Rename,
            ..TransferSettings::default()
        };
        settings.save(&mut vault).unwrap();
        for invalid in [
            TransferSettings {
                concurrency: 0,
                ..settings
            },
            TransferSettings {
                upload_bytes_per_second: MAX_RATE + 1,
                ..settings
            },
        ] {
            assert!(invalid.save(&mut vault).is_err());
            assert_eq!(TransferSettings::load(&vault).unwrap(), settings);
        }
        drop(vault);
        assert!(!String::from_utf8_lossy(&std::fs::read(&path).unwrap()).contains("123456789"));
        let mut vault = Vault::open(&path, b"test-only-settings").unwrap();
        assert_eq!(TransferSettings::load(&vault).unwrap(), settings);
        vault.put(RECORD, br#"{"version":2,"concurrency":3,"upload_bytes_per_second":0,"download_bytes_per_second":0}"#).unwrap();
        assert!(TransferSettings::load(&vault).is_err());
        assert!(settings.save(&mut vault).is_err());
    }

    #[test]
    fn reconnect_restore_is_opt_in_and_old_records_do_not_authorize_network_work() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault =
            Vault::create(&temp.path().join("reconnect.vault"), b"test-only-policy").unwrap();
        vault.put(RECORD, br#"{"version":1,"concurrency":3,"upload_bytes_per_second":0,"download_bytes_per_second":0}"#).unwrap();
        let mut settings = TransferSettings::load(&vault).unwrap();
        assert!(!settings.resume_on_reconnect);
        settings.resume_on_reconnect = true;
        settings.save(&mut vault).unwrap();
        assert!(TransferSettings::load(&vault).unwrap().resume_on_reconnect);
        settings.resume_on_reconnect = false;
        settings.save(&mut vault).unwrap();
        assert!(!TransferSettings::load(&vault).unwrap().resume_on_reconnect);
    }
    #[test]
    fn old_records_default_to_ask_and_unknown_policies_are_not_overwritten() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault =
            Vault::create(&temp.path().join("policy.vault"), b"test-only-policy").unwrap();
        vault.put(RECORD, br#"{"version":1,"concurrency":3,"upload_bytes_per_second":0,"download_bytes_per_second":0}"#).unwrap();
        assert_eq!(
            TransferSettings::load(&vault).unwrap().default_conflict,
            DefaultConflict::Ask
        );
        for policy in [
            DefaultConflict::Ask,
            DefaultConflict::Skip,
            DefaultConflict::Overwrite,
            DefaultConflict::Rename,
        ] {
            assert_eq!(DefaultConflict::parse(policy.as_str()).unwrap(), policy);
            let value = TransferSettings {
                default_conflict: policy,
                ..TransferSettings::default()
            };
            value.save(&mut vault).unwrap();
            assert_eq!(TransferSettings::load(&vault).unwrap(), value);
        }
        assert!(DefaultConflict::parse("unrecognized").is_err());
        let unknown = br#"{"version":1,"concurrency":3,"upload_bytes_per_second":0,"download_bytes_per_second":0,"default_conflict":"future_strategy"}"#;
        vault.put(RECORD, unknown).unwrap();
        assert!(TransferSettings::load(&vault).is_err());
        assert!(TransferSettings::default().save(&mut vault).is_err());
        assert_eq!(vault.get(RECORD).unwrap().unwrap().as_slice(), unknown);
    }
}
