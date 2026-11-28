//! Allowlisted configuration snapshots, authenticated encrypted backup files,
//! and source-Vault-bound all-or-nothing restore plans. No network operations.
pub mod cloud_sync;
mod crypto;
mod restore;
#[cfg(test)]
mod tests;
use crate::{
    RecordChange, Repository, StorageError, Vault,
    repository::{Catalog, HostRecord, valid_id},
};
use rand::{RngCore, rngs::OsRng};
pub use restore::{DiffItem, PreparedRestore, Preview, prepare_restore, preview};
#[cfg(unix)]
use std::fs::File;
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{Read, Write},
    path::Path,
    sync::Arc,
};
use zeroize::Zeroizing;

const CATALOG: &str = "host-catalog-v1";
const HISTORY: &str = "config-command-history-v1";
const TYPOGRAPHY: &str = "local-terminal-typography-v1";
const MAX_RECORDS: usize = 80_000;
const GLOBALS: &[&str] = &[
    crate::appearance::RECORD,
    crate::sftp_view_settings::RECORD,
    "config-ssh-network-defaults-v1",
    "config-transfer-settings-v1",
    "config-file-open-settings-v1",
    "config-terminal-decorations-v1",
    "config-command-palette-shortcut-v1",
    crate::terminal_preferences::RECORD,
    HISTORY,
    "sftp-bookmarks-v1",
];
type Bytes = Arc<Zeroizing<Vec<u8>>>;
type Records = BTreeMap<String, Bytes>;
#[derive(Debug, thiserror::Error)]
pub enum BackupError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("备份文件读写失败；未确认的操作不记成功")]
    Io(#[from] std::io::Error),
    #[error("备份密码错误、格式不支持、引用不完整或数据损坏；未修改配置")]
    Invalid,
    #[error("配置备份超过安全容量；原数据保留")]
    Capacity,
    #[error("原配置库或配置已改变，请重新预览；没有恢复")]
    Changed,
    #[error("恢复选择导致主机“{0}”的分组或跳板引用不完整；请核对其关联项目")]
    Selection(String),
    #[error("备份文件已创建，但目录持久化未确认；请保留并检查该文件，不要重复覆盖")]
    Published,
}
pub type Result<T> = std::result::Result<T, BackupError>;
fn invalid<E>(_: E) -> BackupError {
    BackupError::Invalid
}
fn crypto_error(error: std::io::Error) -> BackupError {
    if matches!(
        error.kind(),
        std::io::ErrorKind::InvalidData | std::io::ErrorKind::UnexpectedEof
    ) {
        BackupError::Invalid
    } else {
        BackupError::Io(error)
    }
}
fn json<T: serde::Serialize>(value: &T) -> Result<Bytes> {
    serde_json::to_vec(value)
        .map(|v| Arc::new(Zeroizing::new(v)))
        .map_err(invalid)
}
fn decode<T: for<'de> serde::Deserialize<'de>>(data: &[u8]) -> Result<T> {
    serde_json::from_slice(data).map_err(invalid)
}
fn slice(value: &Bytes) -> &[u8] {
    value.as_ref().as_slice()
}
fn proxy_key(host: &str) -> String {
    format!("host-proxy-credential-{host}")
}
/// Host-key trust records are device-local pinning decisions that a complete
/// backup must carry, never silently drop. Direct pins are
/// `trust-<sha256(address:port)>` (api::trust_id); a route through a jump host
/// pins the target key as observed via that jump and is
/// `trust-jump-<sha256(versioned jump+target tuple)>` (connections::
/// target_identity). Both categories share the 10 000-record trust budget.
/// Any other `trust-*` shape stays rejected: an unknown future category must
/// fail loudly instead of vanishing from a purported complete backup.
fn trust_key(id: &str) -> bool {
    trust_route(id).is_some()
}
/// Valid trust id split into its 64-hex digest and whether it pins a jump
/// route, for capture, validation and restore labeling.
fn trust_route(id: &str) -> Option<(&str, bool)> {
    fn hex64(suffix: &str) -> bool {
        suffix.len() == 64 && suffix.bytes().all(|b| b.is_ascii_hexdigit())
    }
    id.strip_prefix("trust-jump-")
        .filter(|s| hex64(s))
        .map(|hex| (hex, true))
        .or_else(|| {
            id.strip_prefix("trust-")
                .filter(|s| hex64(s))
                .map(|hex| (hex, false))
        })
}
fn font_key(id: &str) -> bool {
    id.strip_prefix("device-terminal-font-v1-")
        .is_some_and(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
}
fn host_keys(host: &HostRecord) -> Vec<String> {
    let mut keys = vec![
        host.id.clone(),
        proxy_key(&host.id),
        crate::forwarding_rules::record_key(&host.id),
        crate::display_settings::host_key(&host.id),
    ];
    if let Some(id) = &host.credential_id {
        keys.push(id.clone());
    }
    keys
}
fn limit(id: &str) -> usize {
    if font_key(id) {
        crate::typography::FONT_LIMIT
    } else if id == HISTORY {
        8 * 1024 * 1024
    } else {
        2 * 1024 * 1024
    }
}
fn read_record(vault: &Vault, id: &str) -> Result<Option<Bytes>> {
    vault
        .get_bounded(id, limit(id))
        .map(|v| v.map(Arc::new))
        .map_err(Into::into)
}
fn catalog(vault: &Vault) -> Result<Catalog> {
    let value: Catalog = read_record(vault, CATALOG)?
        .as_ref()
        .map(|v| decode(slice(v)))
        .transpose()?
        .unwrap_or_default();
    check_catalog(&value)?;
    Ok(value)
}
fn check_catalog(c: &Catalog) -> Result<()> {
    let mut groups = BTreeSet::new();
    let mut hosts = BTreeSet::new();
    let mut drafts = BTreeSet::new();
    if !c.within_limits()
        || c.groups.iter().any(|g| {
            !valid_id(&g.id, "group") && g.id != "group-default"
                || g.name.trim().is_empty()
                || g.name.len() > 1024
                || g.name.chars().any(char::is_control)
                || !groups.insert(&g.id)
        })
        || c.hosts
            .iter()
            .any(|id| !valid_id(id, "host") || !hosts.insert(id))
        || c.drafts
            .iter()
            .any(|id| !valid_id(id, "host") || !drafts.insert(id))
    {
        return Err(BackupError::Invalid);
    }
    Ok(())
}

/// Plaintext only in bounded, zeroizing native buffers. Not Debug/Serialize,
/// never returned over FFI; preview DTOs contain no secret or command strings.
#[derive(Clone)]
pub struct Snapshot {
    records: Records,
    data_version: Option<i64>,
}
impl Snapshot {
    pub fn capture(vault: &Vault) -> Result<Self> {
        Self::capture_kind(vault, true)
    }
    fn capture_kind(vault: &Vault, include_device: bool) -> Result<Self> {
        // All decrypted rows come from one SQLite read snapshot, including
        // callers using another connection to this same database.
        let tx = vault
            .db
            .unchecked_transaction()
            .map_err(StorageError::from)?;
        let mut value = Self::capture_inner(vault, include_device)?;
        value.data_version = Some(
            tx.query_row("PRAGMA data_version", [], |row| row.get(0))
                .map_err(StorageError::from)?,
        );
        tx.commit().map_err(StorageError::from)?;
        value.validate()?;
        Ok(value)
    }
    fn capture_inner(vault: &Vault, include_device: bool) -> Result<Self> {
        // An unknown future user configuration is not silently omitted from a
        // purported complete backup. Add its typed validator to the registry.
        let mut configs = vault
            .db
            .prepare("SELECT id FROM records WHERE id GLOB 'config-*' LIMIT 1001")
            .map_err(StorageError::from)?;
        let ids = configs
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(StorageError::from)?;
        for id in ids {
            let id = id.map_err(StorageError::from)?;
            if !GLOBALS.contains(&id.as_str()) {
                return Err(BackupError::Invalid);
            }
        }
        let mut records = Records::new();
        let mut c = catalog(vault)?;
        for id in &c.hosts {
            let raw = read_record(vault, id)?.ok_or(BackupError::Invalid)?;
            let host: HostRecord = decode(slice(&raw))?;
            if host.id != *id {
                return Err(BackupError::Invalid);
            }
            for key in host_keys(&host) {
                if let Some(value) = read_record(vault, &key)? {
                    records.insert(key, value);
                }
            }
        }
        // Drafts and their credentials never leave the source device.
        c.drafts.clear();
        records.insert(CATALOG.into(), json(&c)?);
        for key in GLOBALS {
            if let Some(value) = read_record(vault, key)? {
                records.insert((*key).into(), value);
            }
        }
        if include_device {
            let mut stmt = vault
                .db
                .prepare("SELECT id FROM records WHERE id GLOB 'trust-*' ORDER BY id LIMIT 10001")
                .map_err(StorageError::from)?;
            let trust = stmt
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(StorageError::from)?;
            let mut count = 0;
            for id in trust {
                let id = id.map_err(StorageError::from)?;
                count += 1;
                if count > 10_000 || !trust_key(&id) {
                    return Err(BackupError::Capacity);
                }
                records.insert(
                    id.clone(),
                    read_record(vault, &id)?.ok_or(BackupError::Invalid)?,
                );
            }
            if let Some(raw) = read_record(vault, TYPOGRAPHY)? {
                let view = crate::typography::load(vault).map_err(invalid)?;
                records.insert(TYPOGRAPHY.into(), raw);
                for font in view.fonts {
                    let id = format!("device-terminal-font-v1-{}", font.id);
                    records.insert(
                        id.clone(),
                        read_record(vault, &id)?.ok_or(BackupError::Invalid)?,
                    );
                }
            }
        }
        Ok(Self {
            records,
            data_version: None,
        })
    }
    fn sandbox(&self) -> Result<Vault> {
        let db = rusqlite::Connection::open_in_memory().map_err(StorageError::from)?;
        db.execute_batch("CREATE TABLE records(id TEXT PRIMARY KEY, nonce BLOB NOT NULL, ciphertext BLOB NOT NULL);").map_err(StorageError::from)?;
        let mut key = Zeroizing::new([0; 32]);
        OsRng.fill_bytes(key.as_mut());
        let mut vault = Vault {
            instance_id: "backup-validation-only".into(),
            db,
            key,
        };
        let changes: Vec<_> = self
            .records
            .iter()
            .map(|(id, data)| RecordChange::Put(id, slice(data)))
            .collect();
        vault.apply(&changes)?;
        Ok(vault)
    }
    fn validate(&self) -> Result<()> {
        let size = self.records.iter().try_fold(4usize, |n, (id, data)| {
            n.checked_add(id.len())
                .and_then(|n| n.checked_add(data.len()))
                .and_then(|n| n.checked_add(8))
                .ok_or(BackupError::Capacity)
        })?;
        if self.records.len() > MAX_RECORDS
            || size > crypto::MAX_PLAIN
            || self.records.keys().filter(|id| trust_key(id)).count() > 10_000
        {
            return Err(BackupError::Capacity);
        }
        let c: Catalog = decode(slice(
            self.records.get(CATALOG).ok_or(BackupError::Invalid)?,
        ))?;
        check_catalog(&c)?;
        if !c.drafts.is_empty() {
            return Err(BackupError::Invalid);
        }
        let mut vault = self.sandbox()?;
        let mut allowed = BTreeSet::from([CATALOG.to_string()]);
        let mut credentials = BTreeSet::new();
        for id in &c.hosts {
            let repo = Repository::new(&mut vault);
            let host = repo
                .host(id)
                .map_err(invalid)?
                .ok_or(BackupError::Invalid)?;
            host.validate().map_err(invalid)?;
            if host.id != *id || !c.groups.iter().any(|g| g.id == host.group_id) {
                return Err(BackupError::Invalid);
            }
            repo.jump_host(&host).map_err(invalid)?;
            if let Some(credential) = &host.credential_id
                && (!valid_id(credential, "credential")
                    || !credentials.insert(credential.clone())
                    || repo.credential(id).map_err(invalid)?.is_none())
            {
                return Err(BackupError::Invalid);
            }
            if let Some(proxy) = &host.proxy
                && proxy.authenticate
            {
                let credential = repo
                    .proxy_credential(id)
                    .map_err(invalid)?
                    .ok_or(BackupError::Invalid)?;
                if !proxy.credential_valid(&credential) {
                    return Err(BackupError::Invalid);
                }
            } else if self.records.contains_key(&proxy_key(id)) {
                return Err(BackupError::Invalid);
            }
            for key in host_keys(&host) {
                allowed.insert(key);
            }
            crate::forwarding_rules::ForwardingConfig::load(&mut vault, id).map_err(invalid)?;
            crate::display_settings::DisplaySettings::load(&vault, Some(id)).map_err(invalid)?;
        }
        allowed.extend(GLOBALS.iter().map(|s| (*s).to_owned()));
        crate::network_defaults::NetworkDefaults::load(&vault).map_err(invalid)?;
        crate::transfer_settings::TransferSettings::load(&vault)?;
        crate::file_open_settings::FileOpenSettings::load(&vault)?;
        crate::display_settings::DisplaySettings::load(&vault, None).map_err(invalid)?;
        crate::shortcut_settings::load(&vault).map_err(invalid)?;
        crate::terminal_preferences::load(&vault).map_err(invalid)?;
        crate::appearance::load(&vault).map_err(invalid)?;
        crate::sftp_view_settings::load(&vault).map_err(invalid)?;
        crate::bookmarks::BookmarkRepository::new(&mut vault)
            .validate_backup()
            .map_err(invalid)?;
        crate::command_history::HistoryRepository::new(&mut vault)
            .export_payload()
            .map_err(invalid)?;
        let fonts = crate::typography::load(&vault).map_err(invalid)?;
        allowed.insert(TYPOGRAPHY.into());
        for font in &fonts.fonts {
            crate::typography::font_bytes(&vault, &fonts.vault_scope, &fonts.revision, &font.id)
                .map_err(invalid)?;
            allowed.insert(format!("device-terminal-font-v1-{}", font.id));
        }
        for (id, value) in &self.records {
            if trust_key(id) {
                let text = std::str::from_utf8(slice(value)).map_err(invalid)?;
                if !text.strip_prefix("SHA256:").is_some_and(|s| {
                    s.len() == 43
                        && s.bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
                }) {
                    return Err(BackupError::Invalid);
                }
            } else if !allowed.contains(id) {
                return Err(BackupError::Invalid);
            }
        }
        Ok(())
    }
    /// Only a Vault-keyed identifier may leave Rust. Never expose a fast hash
    /// of the decrypted credential-bearing backup or cloud projection.
    pub fn revision(&self, vault: &Vault) -> String {
        let mut tag = vault.revision(b"configuration backup v1");
        for (id, data) in &self.records {
            tag.part(Some(id.as_bytes()));
            tag.part(Some(slice(data)));
        }
        tag.finish()
    }
    fn write(&self, writer: &mut impl Write) -> Result<()> {
        writer.write_all(&(self.records.len() as u32).to_be_bytes())?;
        for (id, data) in &self.records {
            writer.write_all(&(id.len() as u32).to_be_bytes())?;
            writer.write_all(&(data.len() as u32).to_be_bytes())?;
            writer.write_all(id.as_bytes())?;
            writer.write_all(slice(data))?;
        }
        Ok(())
    }
    fn read(reader: &mut impl Read) -> Result<Self> {
        fn number(r: &mut impl Read) -> Result<usize> {
            let mut n = [0; 4];
            r.read_exact(&mut n)?;
            Ok(u32::from_be_bytes(n) as usize)
        }
        let count = number(reader)?;
        if count == 0 || count > MAX_RECORDS {
            return Err(BackupError::Capacity);
        }
        let mut records = Records::new();
        let mut total = 4usize;
        for _ in 0..count {
            let id_len = number(reader)?;
            let size = number(reader)?;
            if id_len == 0 || id_len > 256 {
                return Err(BackupError::Invalid);
            }
            total = total
                .checked_add(id_len)
                .and_then(|n| n.checked_add(size))
                .and_then(|n| n.checked_add(8))
                .ok_or(BackupError::Capacity)?;
            if total > crypto::MAX_PLAIN {
                return Err(BackupError::Capacity);
            }
            let mut id = vec![0; id_len];
            reader.read_exact(&mut id)?;
            let id = String::from_utf8(id).map_err(invalid)?;
            if size > limit(&id) || records.contains_key(&id) {
                return Err(BackupError::Invalid);
            }
            let mut data = Zeroizing::new(vec![0; size]);
            reader.read_exact(&mut data)?;
            records.insert(id, Arc::new(data));
        }
        let mut extra = [0; 1];
        if reader.read(&mut extra)? != 0 {
            return Err(BackupError::Invalid);
        }
        let value = Self {
            records,
            data_version: None,
        };
        value.validate()?;
        Ok(value)
    }
    pub fn write_encrypted(&self, path: &Path, password: &[u8]) -> Result<()> {
        self.validate()?;
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        let mut staging = tempfile::Builder::new()
            .prefix(".hspterm-backup-")
            .tempfile_in(parent)?;
        let mut writer =
            crypto::EncryptedWriter::new(staging.as_file_mut(), password).map_err(crypto_error)?;
        self.write(&mut writer)?;
        writer.finish()?;
        staging.as_file().sync_all()?;
        let file = staging.persist_noclobber(path).map_err(|e| e.error)?;
        file.sync_all().map_err(|_| BackupError::Published)?;
        #[cfg(unix)]
        File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|_| BackupError::Published)?;
        Ok(())
    }
    pub fn read_encrypted(path: &Path, password: &[u8]) -> Result<Self> {
        let mut options = std::fs::OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(
                (rustix::fs::OFlags::NOFOLLOW | rustix::fs::OFlags::NONBLOCK).bits() as i32,
            );
        }
        let file = options.open(path)?;
        let metadata = file.metadata()?;
        if !metadata.is_file() || metadata.len() > crypto::MAX_CIPHER {
            return Err(BackupError::Capacity);
        }
        let mut reader = crypto::EncryptedReader::new(file.take(crypto::MAX_CIPHER + 1), password)
            .map_err(crypto_error)?;
        Self::read(&mut reader).map_err(|error| match error {
            BackupError::Io(error) => crypto_error(error),
            other => other,
        })
    }
}
