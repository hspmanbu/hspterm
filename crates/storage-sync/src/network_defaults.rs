//! Encrypted application defaults. Existing hosts retain explicit values until
//! the user opts into inheritance; saving this never reconfigures a live SSH.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum NetworkDefaultsError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("SSH网络默认参数无效或版本不支持；原数据保留")]
    Format,
    #[error("SSH网络默认参数已被其他操作更改，请重新载入后保存")]
    Changed,
}
type Result<T> = std::result::Result<T, NetworkDefaultsError>;

const RECORD: &str = "config-ssh-network-defaults-v1";
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetworkDefaults {
    pub version: u32,
    pub timeout_seconds: u32,
    pub keepalive_seconds: u32,
    pub keepalive_failures: u32,
    pub response_timeout_seconds: u32,
}
impl Default for NetworkDefaults {
    fn default() -> Self {
        Self {
            version: 1,
            timeout_seconds: 30,
            keepalive_seconds: 30,
            keepalive_failures: 3,
            response_timeout_seconds: 10,
        }
    }
}
impl NetworkDefaults {
    pub fn validate(&self) -> Result<()> {
        if self.version != 1
            || !(1..=3600).contains(&self.timeout_seconds)
            || self.keepalive_seconds > 86400
            || !(1..=100).contains(&self.keepalive_failures)
            || !(1..=3600).contains(&self.response_timeout_seconds)
        {
            return Err(NetworkDefaultsError::Format);
        }
        Ok(())
    }
    pub fn load(vault: &Vault) -> Result<Self> {
        let Some(raw) = vault.get_bounded(RECORD, 4096)? else {
            return Ok(Self::default());
        };
        let value: Self = serde_json::from_slice(&raw).map_err(|_| NetworkDefaultsError::Format)?;
        value.validate()?;
        Ok(value)
    }
    pub fn save(self, vault: &mut Vault) -> Result<()> {
        self.validate()?;
        let previous = vault.get_bounded(RECORD, 4096)?;
        Self::load(vault)?;
        let raw = serde_json::to_vec(&self).map_err(|_| NetworkDefaultsError::Format)?;
        if !vault.apply_checked(
            &[(RECORD, previous.as_deref().map(Vec::as_slice))],
            &[RecordChange::Put(RECORD, &raw)],
        )? {
            return Err(NetworkDefaultsError::Changed);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn limits_and_disabled_keepalive_are_checked_without_silently_clamping() {
        NetworkDefaults::default().validate().unwrap();
        NetworkDefaults {
            keepalive_seconds: 0,
            ..NetworkDefaults::default()
        }
        .validate()
        .unwrap();
        for value in [
            NetworkDefaults {
                timeout_seconds: 0,
                ..NetworkDefaults::default()
            },
            NetworkDefaults {
                timeout_seconds: 3601,
                ..NetworkDefaults::default()
            },
            NetworkDefaults {
                keepalive_seconds: 86401,
                ..NetworkDefaults::default()
            },
            NetworkDefaults {
                keepalive_failures: 0,
                ..NetworkDefaults::default()
            },
            NetworkDefaults {
                keepalive_failures: 101,
                ..NetworkDefaults::default()
            },
        ] {
            assert!(value.validate().is_err());
        }
    }
    #[test]
    fn settings_reopen_encrypted_and_unknown_records_are_preserved() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("network.vault");
        let mut vault = Vault::create(&path, b"synthetic-network-master").unwrap();
        assert_eq!(
            NetworkDefaults::load(&vault).unwrap(),
            NetworkDefaults::default()
        );
        let chosen = NetworkDefaults {
            timeout_seconds: 1234,
            keepalive_seconds: 0,
            keepalive_failures: 11,
            response_timeout_seconds: 7,
            version: 1,
        };
        chosen.save(&mut vault).unwrap();
        drop(vault);
        assert!(
            !String::from_utf8_lossy(&std::fs::read(&path).unwrap()).contains("timeout_seconds")
        );
        let mut vault = Vault::open(&path, b"synthetic-network-master").unwrap();
        assert_eq!(NetworkDefaults::load(&vault).unwrap(), chosen);
        let newer =
            br#"{"version":99,"timeout_seconds":1,"keepalive_seconds":0,"keepalive_failures":1}"#;
        vault.put(RECORD, newer).unwrap();
        assert!(NetworkDefaults::default().save(&mut vault).is_err());
        assert_eq!(vault.get(RECORD).unwrap().unwrap().as_slice(), newer);
    }
}
