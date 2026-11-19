//! Device-local periodic sync check interval in minutes (0 disables, default
//! 10, range 0–1440). Versioned JSON with the same record CAS discipline as
//! the other device preferences; never synced, never in backups, no network.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};

const RECORD: &str = "device-sync-check-interval-v1";
const MAX_BYTES: usize = 4096;
pub const DEFAULT_MINUTES: u32 = 10;
pub const MAX_MINUTES: u32 = 1440;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("同步检查间隔版本或字段无效，原记录保留")]
    Format,
    #[error("原配置库记录已改变，未保存检查间隔；请重新载入后重试")]
    Changed,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stored {
    version: u32,
    minutes: u32,
}

fn parse(raw: Option<&[u8]>) -> Result<u32, Error> {
    match raw {
        None => Ok(DEFAULT_MINUTES),
        Some(raw) => {
            let value: Stored = serde_json::from_slice(raw).map_err(|_| Error::Format)?;
            if value.version != 1 || value.minutes > MAX_MINUTES {
                return Err(Error::Format);
            }
            Ok(value.minutes)
        }
    }
}

/// Absence yields the documented default; a corrupt record is an explicit
/// error instead of a silent fallback that could re-enable periodic sync.
pub fn load(v: &mut Vault) -> Result<u32, Error> {
    parse(
        v.get_bounded(RECORD, MAX_BYTES)?
            .as_deref()
            .map(Vec::as_slice),
    )
}

pub fn save(v: &mut Vault, minutes: u32) -> Result<u32, Error> {
    if minutes > MAX_MINUTES {
        return Err(Error::Format);
    }
    let prior = v.get_bounded(RECORD, MAX_BYTES)?;
    parse(prior.as_deref().map(Vec::as_slice))?;
    let bytes = serde_json::to_vec(&Stored {
        version: 1,
        minutes,
    })
    .map_err(|_| Error::Format)?;
    if bytes.len() > MAX_BYTES {
        return Err(Error::Format);
    }
    if !v.apply_checked(
        &[(RECORD, prior.as_deref().map(|b| b.as_slice()))],
        &[RecordChange::Put(RECORD, &bytes)],
    )? {
        return Err(Error::Changed);
    }
    Ok(minutes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interval_defaults_persists_and_rejects_out_of_range_or_corrupt_records() {
        let root = tempfile::tempdir().unwrap();
        let mut v =
            Vault::create(&root.path().join("interval.vault"), b"synthetic-master").unwrap();
        assert_eq!(load(&mut v).unwrap(), DEFAULT_MINUTES);
        assert_eq!(save(&mut v, 0).unwrap(), 0);
        assert_eq!(load(&mut v).unwrap(), 0);
        save(&mut v, MAX_MINUTES).unwrap();
        assert_eq!(load(&mut v).unwrap(), MAX_MINUTES);
        assert!(save(&mut v, MAX_MINUTES + 1).is_err());
        v.put(RECORD, b"{\"version\":2,\"minutes\":5}").unwrap();
        assert!(matches!(load(&mut v), Err(Error::Format)));
        assert!(matches!(save(&mut v, 5), Err(Error::Format)));
        let raw = v.get_bounded(RECORD, MAX_BYTES).unwrap().unwrap();
        assert_eq!(
            std::str::from_utf8(raw.as_slice()).unwrap(),
            "{\"version\":1,\"minutes\":1440}"
        );
    }
}
