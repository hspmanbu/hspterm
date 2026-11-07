//! Device-local SFTP listing sort preference per formal host: convenience
//! only, never synced or backed up.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
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

/// Per-host column layout for the SFTP listing (round-9): stable column
/// ids, display order, hidden set and widths. Persisted alongside the sort
/// preference in the same v1 record; the field defaults to empty so data
/// written before round-9 keeps loading.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HostColumns {
    pub host: String,
    pub order: Vec<String>,
    pub hidden: Vec<String>,
    pub widths: Vec<(String, u16)>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    hosts: Vec<(String, u32, bool)>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    columns: Vec<HostColumns>,
}

/// Stable column identifiers this build understands; unknown persisted ids
/// are rejected so a future layout never silently corrupts an old order.
pub const COLUMN_IDS: [&str; 6] = ["name", "modified", "size", "kind", "permissions", "owner"];
const MAX_COLUMNS: usize = COLUMN_IDS.len();

fn column_id_valid(id: &str) -> bool {
    COLUMN_IDS.contains(&id)
}

fn columns_valid(entry: &HostColumns) -> bool {
    host_valid(&entry.host)
        && !entry.order.is_empty()
        && entry.order.len() <= MAX_COLUMNS
        && entry.hidden.len() <= MAX_COLUMNS
        && entry.widths.len() <= MAX_COLUMNS
        && entry.order.iter().all(|id| column_id_valid(id))
        && entry.order.iter().collect::<HashSet<_>>().len() == entry.order.len()
        && entry.hidden.iter().all(|id| column_id_valid(id))
        && entry
            .widths
            .iter()
            .all(|(id, w)| column_id_valid(id) && (40..=600).contains(w))
        && !entry.hidden.iter().any(|id| id == "name")
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
        if host_valid(&host) && column <= MAX_SORT_COLUMN && !out.iter().any(|(h, _, _)| *h == host)
        {
            out.push((host, column, ascending));
            if out.len() == MAX_HOSTS {
                break;
            }
        }
    }
    Ok(out)
}

/// Round-9: the listing grew permission and owner columns, so the sort
/// index range widened; records saved by older builds stay valid.
const MAX_SORT_COLUMN: u32 = 5;

/// Moves the host entry to the front of the bounded list.
pub fn record(
    v: &mut Vault,
    host: &str,
    column: u32,
    ascending: bool,
) -> Result<Vec<(String, u32, bool)>> {
    if !host_valid(host) || column > MAX_SORT_COLUMN {
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
        columns: load_columns(v)?,
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

/// Bounded, host-unique view of the stored column layouts.
pub fn load_columns(v: &Vault) -> Result<Vec<HostColumns>> {
    let raw = v.get_bounded(RECORD, MAX_RECORD_BYTES)?;
    let Some(raw) = raw.as_deref() else {
        return Ok(Vec::new());
    };
    let stored: Stored = serde_json::from_slice(raw).map_err(|_| SftpHostPrefsError::Format)?;
    if stored.version != 1 {
        return Err(SftpHostPrefsError::Format);
    }
    let mut out = Vec::new();
    for entry in stored.columns {
        if columns_valid(&entry) && !out.iter().any(|e: &HostColumns| e.host == entry.host) {
            out.push(entry);
            if out.len() == MAX_HOSTS {
                break;
            }
        }
    }
    Ok(out)
}

/// Replaces one host's column layout, preserving the sort preferences.
pub fn record_columns(v: &mut Vault, entry: &HostColumns) -> Result<()> {
    if !columns_valid(entry) {
        return Err(SftpHostPrefsError::Format);
    }
    let mut columns = vec![entry.clone()];
    for existing in load_columns(v)? {
        if existing.host != entry.host {
            columns.push(existing);
        }
    }
    columns.truncate(MAX_HOSTS);
    let stored = Stored {
        version: 1,
        hosts: load(v)?,
        columns,
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
        return Ok(());
    }
    Ok(())
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
        assert!(record(&mut v, a, 6, true).is_err());
        assert!(record(&mut v, "bad id", 0, true).is_err());
    }

    #[test]
    fn column_layouts_round_trip_and_reject_invalid() {
        let dir = tempfile::tempdir().unwrap();
        let mut v =
            Vault::create(&dir.path().join("cols.vault"), b"synthetic-cols-master").unwrap();
        assert!(load_columns(&v).unwrap().is_empty());
        let host = "host-22222222222222222222222222222222";
        record(&mut v, host, 2, false).unwrap();
        let entry = HostColumns {
            host: host.to_owned(),
            order: vec![
                "name".to_owned(),
                "size".to_owned(),
                "modified".to_owned(),
                "kind".to_owned(),
                "permissions".to_owned(),
                "owner".to_owned(),
            ],
            hidden: vec!["kind".to_owned()],
            widths: vec![("name".to_owned(), 420), ("owner".to_owned(), 110)],
        };
        record_columns(&mut v, &entry).unwrap();
        // The sort preference survived the column write.
        assert_eq!(load(&v).unwrap(), vec![(host.to_owned(), 2, false)]);
        assert_eq!(load_columns(&v).unwrap(), vec![entry.clone()]);
        // Duplicate order entries, unknown ids, hidden name, bad width and
        // bad host are all rejected; the stored layout is untouched.
        for bad in [
            HostColumns {
                order: vec!["name".to_owned(), "name".to_owned()],
                ..entry.clone()
            },
            HostColumns {
                order: vec!["name".to_owned(), "future".to_owned()],
                ..entry.clone()
            },
            HostColumns {
                hidden: vec!["name".to_owned()],
                ..entry.clone()
            },
            HostColumns {
                widths: vec![("name".to_owned(), 10)],
                ..entry.clone()
            },
            HostColumns {
                host: "bad id".to_owned(),
                ..entry.clone()
            },
        ] {
            assert!(record_columns(&mut v, &bad).is_err());
        }
        assert_eq!(load_columns(&v).unwrap(), vec![entry]);
        // Old records without the columns field still load.
        let raw = br#"{"version":1,"hosts":[["host-33333333333333333333333333333333",1,true]]}"#;
        let prior = v.get_bounded(RECORD, MAX_RECORD_BYTES).unwrap();
        v.apply_checked(
            &[(RECORD, prior.as_deref().map(Vec::as_slice))],
            &[RecordChange::Put(RECORD, raw)],
        )
        .unwrap();
        assert!(load_columns(&v).unwrap().is_empty());
        assert_eq!(load(&v).unwrap().len(), 1);
    }
}
