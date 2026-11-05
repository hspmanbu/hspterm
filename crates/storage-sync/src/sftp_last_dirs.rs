//! Device-local last SFTP directory per formal host. Convenience only: never
//! synced, never backed up, and never proof that the path still exists.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

pub const RECORD: &str = "device-sftp-last-dirs-v1";
const MAX_HOSTS: usize = 64;
const MAX_PATH_BYTES: usize = 4096;
const MAX_RECORD_BYTES: usize = 512 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum SftpLastDirsError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("SFTP上次目录记录版本不受支持或格式损坏，原记录保留")]
    Format,
}
type Result<T> = std::result::Result<T, SftpLastDirsError>;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    hosts: Vec<(String, String)>,
}

fn valid(host: &str, path: &str) -> bool {
    if host.is_empty()
        || host.len() > 256
        || !host.bytes().all(|b| b.is_ascii_graphic())
        || !path.starts_with('/')
        || path.contains('\0')
        || path.len() > MAX_PATH_BYTES
    {
        return false;
    }
    // Absolute POSIX path: no empty segment other than the root itself.
    path == "/" || path.split('/').skip(1).all(|segment| !segment.is_empty())
}

/// Bounded, host-unique view of the stored pairs; load drops foreign noise.
pub fn load(v: &Vault) -> Result<Vec<(String, String)>> {
    let raw = v.get_bounded(RECORD, MAX_RECORD_BYTES)?;
    let Some(raw) = raw.as_deref() else {
        return Ok(Vec::new());
    };
    let stored: Stored = serde_json::from_slice(raw).map_err(|_| SftpLastDirsError::Format)?;
    if stored.version != 1 {
        return Err(SftpLastDirsError::Format);
    }
    let mut out: Vec<(String, String)> = Vec::with_capacity(stored.hosts.len());
    for (host, path) in stored.hosts {
        if valid(&host, &path) && !out.iter().any(|(h, _)| *h == host) {
            out.push((host, path));
            if out.len() == MAX_HOSTS {
                break;
            }
        }
    }
    Ok(out)
}

/// Moves the host entry to the front of the bounded list.
pub fn record(v: &mut Vault, host: &str, path: &str) -> Result<Vec<(String, String)>> {
    if !valid(host, path) {
        return Err(SftpLastDirsError::Format);
    }
    let mut next = vec![(host.to_owned(), path.to_owned())];
    for (h, p) in load(v)? {
        if h != host {
            next.push((h, p));
        }
    }
    next.truncate(MAX_HOSTS);
    let stored = Stored {
        version: 1,
        hosts: next.clone(),
    };
    let bytes = Zeroizing::new(serde_json::to_vec(&stored).map_err(|_| SftpLastDirsError::Format)?);
    if bytes.len() > MAX_RECORD_BYTES {
        return Err(SftpLastDirsError::Format);
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

    fn vault(dir: &tempfile::TempDir) -> Vault {
        Vault::create(
            &dir.path().join("last-dirs.vault"),
            b"synthetic-last-dirs-master",
        )
        .unwrap()
    }

    #[test]
    fn record_moves_to_front_and_validates_paths() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = vault(&dir);
        assert!(load(&v).unwrap().is_empty());
        let a = "host-11111111111111111111111111111111";
        let b = "host-22222222222222222222222222222222";
        record(&mut v, a, "/var/www").unwrap();
        record(&mut v, b, "/etc").unwrap();
        assert_eq!(
            load(&v).unwrap(),
            vec![
                (b.to_owned(), "/etc".to_owned()),
                (a.to_owned(), "/var/www".to_owned())
            ]
        );
        record(&mut v, a, "/srv").unwrap();
        assert_eq!(load(&v).unwrap().first().unwrap().0, a);
        // Relative paths, NUL and non-absolute roots are rejected outright.
        assert!(record(&mut v, a, "var/www").is_err());
        assert!(record(&mut v, a, "/va\0r").is_err());
    }
}
