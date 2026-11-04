//! Encrypted global and saved-host SFTP directory configuration. No networking,
//! CWD inference, shell injection or device-local directory cache contents.
use crate::{Repository, StorageError, Vault};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use zeroize::Zeroizing;

const RECORD: &str = "sftp-bookmarks-v1";
const MAX_BYTES: usize = 2 * 1024 * 1024;
#[derive(thiserror::Error, Debug)]
pub enum BookmarkError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error(transparent)]
    Repository(#[from] crate::RepositoryError),
    #[error("书签名称、路径或所属主机无效")]
    Invalid,
    #[error("书签已不存在，请刷新列表")]
    Missing,
    #[error("目录书签格式无效或版本不受支持；未覆盖原数据")]
    Format,
    #[error("目录书签超过安全容量；未修改原数据")]
    Capacity,
}
type Result<T> = std::result::Result<T, BookmarkError>;
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bookmark {
    /// Empty only when requesting creation; persisted IDs are opaque/stable.
    pub id: String,
    pub name: String,
    pub path: String,
    /// None means available on every host, never an automatic connection target.
    pub host_id: Option<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    version: u32,
    items: Vec<Bookmark>,
}
fn valid_id(id: &str, prefix: &str) -> bool {
    id.strip_prefix(prefix)
        .is_some_and(|v| v.len() == 32 && v.bytes().all(|c| c.is_ascii_hexdigit()))
}
impl Bookmark {
    fn valid(&self) -> bool {
        valid_id(&self.id, "bookmark-")
            && !self.name.trim().is_empty()
            && self.name.len() <= 1024
            && !self.name.chars().any(char::is_control)
            && self.path.starts_with('/')
            && self.path.len() <= 131072
            && !self.path.contains('\0')
            && self.host_id.as_ref().is_none_or(|id| valid_id(id, "host-"))
    }
}
pub struct BookmarkRepository<'a> {
    vault: &'a mut Vault,
}
impl<'a> BookmarkRepository<'a> {
    pub(crate) fn validate_backup(&self) -> Result<()> {
        self.read().map(|_| ())
    }
    pub fn new(vault: &'a mut Vault) -> Self {
        Self { vault }
    }
    fn read(&self) -> Result<Document> {
        let Some(raw) = self.vault.get(RECORD)? else {
            return Ok(Document {
                version: 1,
                items: vec![],
            });
        };
        if raw.len() > MAX_BYTES {
            return Err(BookmarkError::Capacity);
        }
        let value: Document = serde_json::from_slice(&raw).map_err(|_| BookmarkError::Format)?;
        if value.version != 1 || value.items.len() > 10_000 {
            return Err(BookmarkError::Format);
        }
        let mut seen = HashSet::new();
        if value
            .items
            .iter()
            .any(|item| !item.valid() || !seen.insert(&item.id))
        {
            return Err(BookmarkError::Format);
        }
        Ok(value)
    }
    fn write(&mut self, document: &Document) -> Result<()> {
        if document.items.len() > 10_000 {
            return Err(BookmarkError::Capacity);
        }
        let raw = Zeroizing::new(serde_json::to_vec(document).map_err(|_| BookmarkError::Format)?);
        if raw.len() > MAX_BYTES {
            return Err(BookmarkError::Capacity);
        }
        self.vault.put(RECORD, &raw)?;
        Ok(())
    }
    /// Stable saved order. A deleted host's bookmarks are not reassigned to
    /// another host; existing sessions may still inspect their original scope.
    pub fn list(&self, host: &str) -> Result<Vec<Bookmark>> {
        if !valid_id(host, "host-") {
            return Err(BookmarkError::Invalid);
        }
        Ok(self
            .read()?
            .items
            .into_iter()
            .filter(|b| b.host_id.as_deref().is_none_or(|id| id == host))
            .collect())
    }
    pub fn save(&mut self, mut bookmark: Bookmark) -> Result<Bookmark> {
        let creating = bookmark.id.is_empty();
        if creating {
            bookmark.id = format!("bookmark-{:032x}", rand::random::<u128>());
        }
        bookmark.name = bookmark.name.trim().to_owned();
        if !bookmark.valid() {
            return Err(BookmarkError::Invalid);
        }
        // Saving configuration does not canonicalize or probe the remote path.
        if let Some(host) = &bookmark.host_id
            && Repository::new(self.vault).host(host)?.is_none()
        {
            return Err(BookmarkError::Invalid);
        }
        let mut document = self.read()?;
        if creating {
            document.items.push(bookmark.clone());
        } else {
            let index = document
                .items
                .iter()
                .position(|b| b.id == bookmark.id)
                .ok_or(BookmarkError::Missing)?;
            document.items[index] = bookmark.clone();
        }
        self.write(&document)?;
        Ok(bookmark)
    }
    pub fn remove(&mut self, id: &str) -> Result<()> {
        if !valid_id(id, "bookmark-") {
            return Err(BookmarkError::Invalid);
        }
        let mut document = self.read()?;
        let index = document
            .items
            .iter()
            .position(|b| b.id == id)
            .ok_or(BookmarkError::Missing)?;
        document.items.remove(index);
        self.write(&document)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AuthMethod, Credential, HostRecord};
    fn host(v: &mut Vault) -> String {
        Repository::new(v)
            .save(
                HostRecord::new(
                    "Fixture".into(),
                    "fixture.invalid".into(),
                    "fixture".into(),
                    AuthMethod::Password,
                ),
                Some(Credential {
                    secret: "test-only-bookmark-credential".into(),
                    passphrase: None,
                }),
            )
            .unwrap()
            .id
    }
    fn item(host: Option<String>) -> Bookmark {
        Bookmark {
            id: String::new(),
            name: " 项目目录 ".into(),
            path: "/private-fixture/中文 ' $; é".into(),
            host_id: host,
        }
    }
    #[test]
    fn global_and_host_bookmarks_reopen_encrypted_without_cross_host_reassignment() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("bookmarks.vault");
        let mut vault = Vault::create(&path, b"test-only-bookmark-master").unwrap();
        let a = host(&mut vault);
        let b = host(&mut vault);
        let mut repo = BookmarkRepository::new(&mut vault);
        let global = repo.save(item(None)).unwrap();
        let mut private = repo.save(item(Some(a.clone()))).unwrap();
        assert_eq!(private.name, "项目目录");
        assert_eq!(repo.list(&a).unwrap().len(), 2);
        assert_eq!(repo.list(&b).unwrap().len(), 1);
        let original_id = private.id.clone();
        private.name = "重命名".into();
        repo.save(private).unwrap();
        drop(vault);
        let raw = std::fs::read(&path).unwrap();
        assert!(
            !raw.windows(b"private-fixture".len())
                .any(|w| w == b"private-fixture")
        );
        let mut vault = Vault::open(&path, b"test-only-bookmark-master").unwrap();
        let mut repo = BookmarkRepository::new(&mut vault);
        let restored = repo.list(&a).unwrap();
        assert_eq!(restored[1].id, original_id);
        assert_eq!(restored[1].name, "重命名");
        repo.remove(&global.id).unwrap();
        assert!(repo.list(&b).unwrap().is_empty());
        Repository::new(&mut vault)
            .delete(std::slice::from_ref(&a))
            .unwrap();
        let mut repo = BookmarkRepository::new(&mut vault);
        assert!(repo.save(item(Some(a.clone()))).is_err());
        assert_eq!(repo.list(&a).unwrap().len(), 1);
        assert!(repo.list(&b).unwrap().is_empty());
    }
    #[test]
    fn invalid_changes_unknown_versions_and_database_failure_preserve_bookmarks() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &temp.path().join("guard.vault"),
            b"test-only-bookmark-guard",
        )
        .unwrap();
        let a = host(&mut vault);
        let saved = BookmarkRepository::new(&mut vault)
            .save(item(Some(a.clone())))
            .unwrap();
        let old = vault.get(RECORD).unwrap().unwrap();
        let mut repo = BookmarkRepository::new(&mut vault);
        for path in ["relative", "", "/has\0nul"] {
            assert!(
                repo.save(Bookmark {
                    path: path.into(),
                    ..saved.clone()
                })
                .is_err()
            );
        }
        assert!(
            repo.save(Bookmark {
                name: "  ".into(),
                ..saved.clone()
            })
            .is_err()
        );
        assert!(
            repo.save(Bookmark {
                id: "bookmark-00000000000000000000000000000000".into(),
                ..saved.clone()
            })
            .is_err()
        );
        assert_eq!(
            vault.get(RECORD).unwrap().unwrap().as_slice(),
            old.as_slice()
        );
        vault.db.execute_batch("CREATE TRIGGER deny_bookmarks BEFORE INSERT ON records WHEN NEW.id='sftp-bookmarks-v1' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;").unwrap();
        assert!(
            BookmarkRepository::new(&mut vault)
                .remove(&saved.id)
                .is_err()
        );
        assert_eq!(
            vault.get(RECORD).unwrap().unwrap().as_slice(),
            old.as_slice()
        );
        vault
            .db
            .execute_batch("DROP TRIGGER deny_bookmarks")
            .unwrap();
        vault.put(RECORD, br#"{"version":2,"items":[]}"#).unwrap();
        let mut repo = BookmarkRepository::new(&mut vault);
        assert!(repo.list(&a).is_err());
        assert!(repo.save(item(None)).is_err());
        assert!(repo.remove(&saved.id).is_err());
        assert_eq!(
            vault.get(RECORD).unwrap().unwrap().as_slice(),
            br#"{"version":2,"items":[]}"#
        );
    }
}
