//! Device-local, encrypted per-host resource-bar visibility. Never grants process access.
use crate::{RecordChange, Repository, StorageError, Vault};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
const RECORD: &str = "device-host-resource-bars-v1";
const MAX_BYTES: usize = 256 * 1024;
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("资源栏偏好版本或字段无效，原记录保留")]
    Format,
    #[error("原主机配置库已改变或主机已删除，未保存资源栏偏好")]
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
            .any(|id| id.is_empty() || id.len() > 256 || !id.bytes().all(|b| b.is_ascii_graphic()))
    {
        return Err(Error::Format);
    }
    Ok(value)
}
fn check(v: &mut Vault, scope: &str, host: &str) -> Result<(), Error> {
    if v.instance_id() != scope
        || Repository::new(v)
            .host(host)
            .map_err(|_| Error::Changed)?
            .is_none()
    {
        return Err(Error::Changed);
    }
    Ok(())
}
pub fn load(v: &mut Vault, scope: &str, host: &str) -> Result<bool, Error> {
    check(v, scope, host)?;
    Ok(read(v)?.hosts.get(host).copied().unwrap_or(false))
}
pub fn save(v: &mut Vault, scope: &str, host: &str, enabled: bool) -> Result<(), Error> {
    check(v, scope, host)?;
    let prior = v.get_bounded(RECORD, MAX_BYTES)?;
    let mut value = read(v)?;
    if enabled {
        value.hosts.insert(host.into(), true);
    } else {
        value.hosts.remove(host);
    }
    if value.hosts.len() > 4096 {
        return Err(Error::Format);
    }
    let bytes = serde_json::to_vec(&value).map_err(|_| Error::Format)?;
    if bytes.len() > MAX_BYTES {
        return Err(Error::Format);
    }
    if !v.apply_checked(
        &[(RECORD, prior.as_deref().map(Vec::as_slice))],
        &[RecordChange::Put(RECORD, &bytes)],
    )? {
        return Err(Error::Changed);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AuthMethod, HostRecord};
    #[test]
    fn encrypted_host_preference_is_scoped_and_never_stores_process_consent() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &temp.path().join("resource.vault"),
            b"synthetic-resource-master",
        )
        .unwrap();
        let first = Repository::new(&mut vault)
            .save(
                HostRecord::new(
                    "first".into(),
                    "first.invalid".into(),
                    "fixture".into(),
                    AuthMethod::Password,
                ),
                None,
            )
            .unwrap();
        let second = Repository::new(&mut vault)
            .save(
                HostRecord::new(
                    "second".into(),
                    "second.invalid".into(),
                    "fixture".into(),
                    AuthMethod::Password,
                ),
                None,
            )
            .unwrap();
        let scope = vault.instance_id().to_owned();
        assert!(!load(&mut vault, &scope, &first.id).unwrap());
        save(&mut vault, &scope, &first.id, true).unwrap();
        assert!(load(&mut vault, &scope, &first.id).unwrap());
        assert!(!load(&mut vault, &scope, &second.id).unwrap());
        assert!(save(&mut vault, "stale-scope", &first.id, false).is_err());
        assert!(load(&mut vault, &scope, &first.id).unwrap());
        save(&mut vault, &scope, &first.id, false).unwrap();
        assert!(!load(&mut vault, &scope, &first.id).unwrap());
        let raw = vault.get_bounded(RECORD, MAX_BYTES).unwrap().unwrap();
        let value: serde_json::Value = serde_json::from_slice(&raw).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 2);
        assert!(value.get("processes").is_none());
    }
}
