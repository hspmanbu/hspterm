//! Device-local list of recently opened formal host IDs. Convenience state
//! only: never synced, never backed up, and never a source of connection
//! truth. Host records themselves stay in the encrypted catalog.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

pub const RECORD: &str = "device-recent-hosts-v1";
const LIMIT: usize = 10;
const MAX_ID_BYTES: usize = 256;
const MAX_RECORD_BYTES: usize = 16 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum RecentHostsError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("最近主机记录版本不受支持或格式损坏，原记录保留")]
    Format,
}
type Result<T> = std::result::Result<T, RecentHostsError>;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    hosts: Vec<String>,
}

fn id_valid(id: &str) -> bool {
    !id.is_empty() && id.len() <= MAX_ID_BYTES && id.bytes().all(|b| b.is_ascii_graphic())
}

fn normalize(hosts: Vec<String>) -> Vec<String> {
    let mut result = Vec::with_capacity(LIMIT);
    for id in hosts {
        if id_valid(&id) && !result.contains(&id) {
            result.push(id);
            if result.len() == LIMIT {
                break;
            }
        }
    }
    result
}

/// Device-local record; bounded read, defensive parse of foreign bytes.
pub fn load(v: &Vault) -> Result<Vec<String>> {
    let raw = v.get_bounded(RECORD, MAX_RECORD_BYTES)?;
    Ok(match raw.as_deref() {
        None => Vec::new(),
        Some(bytes) => {
            let stored: Stored =
                serde_json::from_slice(bytes).map_err(|_| RecentHostsError::Format)?;
            if stored.version != 1 {
                return Err(RecentHostsError::Format);
            }
            normalize(stored.hosts)
        }
    })
}

/// Moves the host to the front and persists the bounded list. The record only
/// changes when the list actually differs.
pub fn record(v: &mut Vault, host_id: &str) -> Result<Vec<String>> {
    if !id_valid(host_id) {
        return Err(RecentHostsError::Format);
    }
    let mut next = vec![host_id.to_owned()];
    for id in load(v)? {
        if id != host_id {
            next.push(id);
        }
    }
    next.truncate(LIMIT);
    let prior = v.get_bounded(RECORD, MAX_RECORD_BYTES)?;
    let stored = Stored {
        version: 1,
        hosts: next.clone(),
    };
    let bytes = Zeroizing::new(serde_json::to_vec(&stored).map_err(|_| RecentHostsError::Format)?);
    if bytes.len() > MAX_RECORD_BYTES {
        return Err(RecentHostsError::Format);
    }
    if !v.apply_checked(
        &[(RECORD, prior.as_deref().map(Vec::as_slice))],
        &[RecordChange::Put(RECORD, &bytes)],
    )? {
        // Another writer raced us; report the durable list instead of failing
        // the host-open path that calls this.
        return load(v);
    }
    Ok(next)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vault(dir: &tempfile::TempDir) -> Vault {
        let path = dir.path().join("recent.vault");
        Vault::create(&path, b"synthetic-recent-master").unwrap()
    }

    #[test]
    fn record_moves_to_front_dedups_and_keeps_bound() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = vault(&dir);
        let host = "host-11111111111111111111111111111111";
        let other = "host-22222222222222222222222222222222";
        assert!(load(&v).unwrap().is_empty());
        assert_eq!(record(&mut v, other).unwrap(), vec![other.to_owned()]);
        assert_eq!(
            record(&mut v, host).unwrap(),
            vec![host.to_owned(), other.to_owned()]
        );
        assert_eq!(
            record(&mut v, other).unwrap(),
            vec![other.to_owned(), host.to_owned()]
        );
        for i in 0..12 {
            let id = format!("host-{i:032}");
            record(&mut v, &id).unwrap();
        }
        let list = load(&v).unwrap();
        assert_eq!(list.len(), LIMIT);
        assert_eq!(list[0], "host-00000000000000000000000000000011");
        assert!(list.contains(&"host-00000000000000000000000000000002".to_owned()));
        // The oldest entries fell out of the bounded device-local list.
        assert!(!list.contains(&"host-00000000000000000000000000000001".to_owned()));
        assert!(!list.contains(&host.to_owned()));
        assert!(!list.contains(&other.to_owned()));
    }

    #[test]
    fn invalid_ids_and_foreign_records_never_overwrite_existing_data() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = vault(&dir);
        assert!(record(&mut v, "bad id\n").is_err());
        assert!(record(&mut v, "").is_err());
        let long = format!("host-{}", "x".repeat(MAX_ID_BYTES));
        assert!(record(&mut v, &long).is_err());
        v.put(RECORD, b"{\"version\":9,\"hosts\":[]}").unwrap();
        assert!(matches!(load(&v), Err(RecentHostsError::Format)));
    }

    #[test]
    fn record_body_is_bounded_and_load_drops_unknown_shape_entries() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = vault(&dir);
        for i in 0..LIMIT {
            record(&mut v, &format!("host-{i:032}")).unwrap();
        }
        let raw = v.get_bounded(RECORD, MAX_RECORD_BYTES).unwrap().unwrap();
        assert!(raw.len() <= MAX_RECORD_BYTES);
        let stored: Stored = serde_json::from_slice(&raw).unwrap();
        // Foreign duplicate/lowercase noise is normalized away on load.
        let noisy = Stored {
            version: 1,
            hosts: vec![
                "host-00000000000000000000000000000009".to_owned(),
                "host-00000000000000000000000000000009".to_owned(),
                "not valid".to_owned(),
            ],
        };
        v.put(RECORD, &serde_json::to_vec(&noisy).unwrap()).unwrap();
        assert_eq!(
            load(&v).unwrap(),
            vec!["host-00000000000000000000000000000009".to_owned()]
        );
        assert_eq!(stored.hosts.len(), LIMIT);
    }
}
