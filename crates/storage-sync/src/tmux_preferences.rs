//! Device-local encrypted defaults for a saved host's tmux selection dialog.
use crate::{RecordChange, Repository, StorageError, Vault};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
const RECORD: &str = "device-host-tmux-view-v1";
const MAX_BYTES: usize = 256 * 1024;
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("tmux观看偏好格式无效，原记录保留")]
    Format,
    #[error("tmux观看偏好所属主机已删除或记录已改变")]
    Changed,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    hosts: BTreeMap<String, bool>,
}
fn read(v: &Vault) -> Result<Stored, Error> {
    let value = match v.get_bounded(RECORD, MAX_BYTES)? {
        Some(raw) => serde_json::from_slice::<Stored>(&raw).map_err(|_| Error::Format)?,
        None => Stored {
            version: 1,
            hosts: BTreeMap::new(),
        },
    };
    if value.version != 1
        || value.hosts.len() > 4096
        || value
            .hosts
            .keys()
            .any(|id| !crate::repository::valid_id(id, "host"))
    {
        return Err(Error::Format);
    }
    Ok(value)
}
pub fn load(v: &mut Vault, host: &str) -> Result<bool, Error> {
    if Repository::new(v)
        .host(host)
        .map_err(|_| Error::Changed)?
        .is_none()
    {
        return Err(Error::Changed);
    }
    Ok(read(v)?.hosts.get(host).copied().unwrap_or(true))
}
pub fn save(v: &mut Vault, host: &str, readonly: bool) -> Result<(), Error> {
    load(v, host)?;
    let prior = v.get_bounded(RECORD, MAX_BYTES)?;
    let mut value = read(v)?;
    value.hosts.insert(host.into(), readonly);
    let raw = serde_json::to_vec(&value).map_err(|_| Error::Format)?;
    if value.hosts.len() > 4096 || raw.len() > MAX_BYTES {
        return Err(Error::Format);
    }
    if !v.apply_checked(
        &[(RECORD, prior.as_deref().map(Vec::as_slice))],
        &[RecordChange::Put(RECORD, &raw)],
    )? {
        return Err(Error::Changed);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn saved_host_defaults_survive_reopen_without_cross_host_inheritance() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("tmux.vault");
        let mut vault = Vault::create(&path, b"synthetic-tmux-master").unwrap();
        let mut hosts = Vec::new();
        for name in ["first", "second"] {
            hosts.push(
                Repository::new(&mut vault)
                    .save(
                        crate::HostRecord::new(
                            name.into(),
                            "fixture.invalid".into(),
                            "fixture".into(),
                            crate::AuthMethod::Password,
                        ),
                        None,
                    )
                    .unwrap()
                    .id,
            );
        }
        assert!(load(&mut vault, &hosts[0]).unwrap());
        save(&mut vault, &hosts[0], false).unwrap();
        assert!(!load(&mut vault, &hosts[0]).unwrap());
        assert!(load(&mut vault, &hosts[1]).unwrap());
        drop(vault);
        let mut vault = Vault::open(&path, b"synthetic-tmux-master").unwrap();
        assert!(!load(&mut vault, &hosts[0]).unwrap());
        assert!(save(&mut vault, "host-not-present", false).is_err());
        vault.put(RECORD, b"invalid-version-or-json").unwrap();
        assert!(save(&mut vault, &hosts[0], true).is_err());
        assert_eq!(
            vault
                .get_bounded(RECORD, MAX_BYTES)
                .unwrap()
                .unwrap()
                .as_slice(),
            b"invalid-version-or-json"
        );
    }
}
