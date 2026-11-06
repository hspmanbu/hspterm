//! Device-local SFTP listing sort preference per formal host: convenience
//! only, never synced or backed up.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

pub const RECORD: &str = "device-sftp-host-prefs-v1";
const MAX_HOSTS: usize = 64;
const MAX_RECORD_BYTES: usize = 128 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum SftpHostPrefsError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("SFTP排序偏好版本不受支持或格式损坏，原记录保留")]
    Format,
}
type Result<T> = std::result::Result<T, SftpHostPrefsError>;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    hosts: Vec<(String, u32, bool)>,
}

fn host_valid(host: &str) -> bool {
    !host.is_empty() && host.len() <= 256 && host.bytes().all(|b| b.is_ascii_graphic())
}

/// Bounded, host-unique view of the stored sort preferences.
pub fn load(v: &Vault) -> Result<Vec<(String, u32, bool)>> {
    let raw = v.get_bounded(RECORD, MAX_RECORD_BYTES)?;
    let Some(raw) = raw.as_deref() else {
        return Ok(Vec::new());
    };
    let stored: Stored = serde_json::from_slice(raw).map_err(|_| SftpHostPrefsError::Format)?;
    if stored.version != 1 {
        return Err(SftpHostPrefsError::Format);
    }
    let mut out: Vec<(String, u32, bool)> = Vec::new();
    for (host, column, ascending) in stored.hosts {
        if host_valid(&host) && column <= 3 && !out.iter().any(|(h, _, _)| *h == host) {
            out.push((host, column, ascending));
            if out.len() == MAX_HOSTS {
                break;
            }
        }
    }
    Ok(out)
}

/// Moves the host entry to the front of the bounded list.
pub fn record(
    v: &mut Vault,
    host: &str,
    column: u32,
    ascending: bool,
) -> Result<Vec<(String, u32, bool)>> {
    if !host_valid(host) || column > 3 {
        return Err(SftpHostPrefsError::Format);
    }
    let mut next = vec![(host.to_owned(), column, ascending)];
    for (h, c, a) in load(v)? {
        if h != host {
            next.push((h, c, a));
        }
    }
    next.truncate(MAX_HOSTS);
    let stored = Stored {
        version: 1,
        hosts: next.clone(),
    };
    let bytes =
        Zeroizing::new(serde_json::to_vec(&stored).map_err(|_| SftpHostPrefsError::Format)?);
    if bytes.len() > MAX_RECORD_BYTES {
        return Err(SftpHostPrefsError::Format);
    }
    let prior = v.get_bounded(RECORD, MAX_RECORD_BYTES)?;
    if !v.apply_checked(
        &[(RECORD, prior.as_deref().map(Vec::as_slice))],
        &[RecordChange::Put(RECORD, &bytes)],
    )? {
        return load(v);
    }
    Ok(next)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_moves_to_front_and_validates_columns() {
        let dir = tempfile::tempdir().unwrap();
        let mut v =
            Vault::create(&dir.path().join("prefs.vault"), b"synthetic-prefs-master").unwrap();
        assert!(load(&v).unwrap().is_empty());
        let a = "host-11111111111111111111111111111111";
        record(&mut v, a, 0, true).unwrap();
        record(&mut v, a, 2, false).unwrap();
        assert_eq!(load(&v).unwrap(), vec![(a.to_owned(), 2, false)]);
        assert!(record(&mut v, a, 4, true).is_err());
        assert!(record(&mut v, "bad id", 0, true).is_err());
    }
}
