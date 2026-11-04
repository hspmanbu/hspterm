//! Explicit history preferences/clear controls. No command strings leave this
//! module; it does not classify input, read terminal output or collect commands.
use super::*;

#[derive(Clone)]
pub struct HostCount {
    pub id: String,
    pub name: String,
    pub count: u32,
}
#[derive(Clone)]
pub struct Controls {
    pub vault_scope: String,
    pub revision: String,
    pub enabled: bool,
    /// Includes orphaned saved-host histories; Clear All also covers them.
    pub total: u32,
    pub hosts: Vec<HostCount>,
}
fn revision(vault: &Vault, raw: Option<&[u8]>) -> String {
    let mut tag = vault.revision(b"history controls v1");
    tag.part(raw);
    tag.finish()
}

fn view(vault: &mut Vault, document: &Document, revision: String) -> Result<Controls> {
    let hosts = Repository::new(vault).list()?;
    Ok(Controls {
        vault_scope: vault.instance_id().to_owned(),
        revision,
        enabled: document.enabled,
        total: document
            .hosts
            .values()
            .map(|h| h.entries.len() as u32)
            .sum(),
        hosts: hosts
            .into_iter()
            .map(|h| HostCount {
                count: document
                    .hosts
                    .get(&h.id)
                    .map_or(0, |v| v.entries.len() as u32),
                id: h.id,
                name: h.name,
            })
            .collect(),
    })
}
pub fn load(vault: &mut Vault) -> Result<Controls> {
    let (raw, document) = HistoryRepository::new(vault).read()?;
    let revision = revision(vault, raw.as_deref().map(Vec::as_slice));
    view(vault, &document, revision)
}
pub enum Action {
    Enabled(bool),
    ClearAll,
    ClearHost(String),
}
pub fn apply(vault: &mut Vault, scope: &str, expected: &str, action: Action) -> Result<Controls> {
    if scope != vault.instance_id() || expected.len() != 64 {
        return Err(HistoryError::Changed);
    }
    let mut repository = HistoryRepository::new(vault);
    let (raw, mut document) = repository.read()?;
    if revision(repository.vault, raw.as_deref().map(Vec::as_slice)) != expected {
        return Err(HistoryError::Changed);
    }
    if let Action::ClearHost(id) = &action {
        repository.host(id)?;
    }
    // Validate the projection before publishing, so unreadable host metadata
    // cannot turn a committed history clear into a reported transaction failure.
    let mut result = view(repository.vault, &document, expected.to_owned())?;
    if matches!(&action, Action::Enabled(v) if *v == document.enabled) {
        return Ok(result);
    }
    let (old_writer, actor) = repository.actor()?;
    let stamp = document.tick(&actor)?;
    match action {
        Action::Enabled(value) => {
            document.enabled = value;
            document.enabled_at = stamp;
        }
        Action::ClearAll => {
            document.clear_all = stamp;
            document.hosts.clear();
        }
        Action::ClearHost(id) => {
            document.hosts.insert(
                id,
                HostHistory {
                    clear: stamp,
                    entries: vec![],
                },
            );
        }
    }
    let next_revision = {
        let candidate = document.encode()?;
        revision(repository.vault, Some(&candidate))
    };
    repository.commit(
        raw.as_deref().map(Vec::as_slice),
        &document,
        Some((old_writer.as_deref().map(Vec::as_slice), &actor)),
    )?;
    result.revision = next_revision;
    result.enabled = document.enabled;
    result.total = document
        .hosts
        .values()
        .map(|h| h.entries.len() as u32)
        .sum();
    for host in &mut result.hosts {
        host.count = document
            .hosts
            .get(&host.id)
            .map_or(0, |h| h.entries.len() as u32);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AuthMethod, Credential, HostRecord};
    fn host(vault: &mut Vault) -> String {
        Repository::new(vault)
            .save(
                HostRecord::new(
                    "History controls fixture".into(),
                    "fixture.invalid".into(),
                    "fixture".into(),
                    AuthMethod::Password,
                ),
                Some(Credential {
                    secret: "synthetic-controls-host-password".into(),
                    passphrase: None,
                }),
            )
            .unwrap()
            .id
    }
    fn apply_view(vault: &mut Vault, before: &Controls, action: Action) -> Controls {
        let after = apply(vault, &before.vault_scope, &before.revision, action).unwrap();
        assert_eq!(load(vault).unwrap().revision, after.revision);
        after
    }
    #[test]
    fn encrypted_preferences_counts_and_host_global_clear_keep_epochs() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("controls.vault");
        let mut vault = Vault::create(&path, b"synthetic-history-controls-master").unwrap();
        let a = host(&mut vault);
        let b = host(&mut vault);
        // Explicit synthetic already-qualified data, never terminal collection.
        HistoryRepository::new(&mut vault)
            .record_qualified(&a, "git status")
            .unwrap();
        HistoryRepository::new(&mut vault)
            .record_qualified(&b, "ls /tmp")
            .unwrap();
        let old = HistoryRepository::new(&mut vault).export_payload().unwrap();
        let before = load(&mut vault).unwrap();
        assert_eq!(before.total, 2);
        let disabled = apply_view(&mut vault, &before, Action::Enabled(false));
        assert!(!disabled.enabled);
        assert!(
            !HistoryRepository::new(&mut vault)
                .record_qualified(&a, "git log")
                .unwrap()
        );
        let one = apply_view(&mut vault, &disabled, Action::ClearHost(a.clone()));
        assert_eq!(one.total, 1);
        assert_eq!(one.hosts.iter().find(|h| h.id == a).unwrap().count, 0);
        HistoryRepository::new(&mut vault)
            .merge_payload(&old)
            .unwrap();
        assert_eq!(load(&mut vault).unwrap().total, 1);
        let now = load(&mut vault).unwrap();
        let all = apply_view(&mut vault, &now, Action::ClearAll);
        assert_eq!(all.total, 0);
        HistoryRepository::new(&mut vault)
            .merge_payload(&old)
            .unwrap();
        assert_eq!(load(&mut vault).unwrap().total, 0);
        drop(vault);
        let disk = std::fs::read(&path).unwrap();
        assert!(
            !disk
                .windows(b"git status".len())
                .any(|b| b == b"git status")
        );
        let mut reopened = Vault::open(&path, b"synthetic-history-controls-master").unwrap();
        assert!(!load(&mut reopened).unwrap().enabled);
        assert!(matches!(
            apply(
                &mut reopened,
                &all.vault_scope,
                &all.revision,
                Action::ClearAll
            ),
            Err(HistoryError::Changed)
        ));
    }
    #[test]
    fn stale_scope_history_changed_and_unknown_format_never_overwrite() {
        let tmp = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &tmp.path().join("first.vault"),
            b"synthetic-controls-master",
        )
        .unwrap();
        let a = host(&mut vault);
        let before = load(&mut vault).unwrap();
        HistoryRepository::new(&mut vault)
            .record_qualified(&a, "git status")
            .unwrap();
        let bytes = vault.get(RECORD).unwrap().unwrap();
        assert!(matches!(
            apply(
                &mut vault,
                &before.vault_scope,
                &before.revision,
                Action::ClearAll
            ),
            Err(HistoryError::Changed)
        ));
        assert_eq!(
            vault.get(RECORD).unwrap().unwrap().as_slice(),
            bytes.as_slice()
        );
        let fresh = load(&mut vault).unwrap();
        let mut other = Vault::create(
            &tmp.path().join("other.vault"),
            b"synthetic-controls-master",
        )
        .unwrap();
        assert!(matches!(
            apply(
                &mut other,
                &fresh.vault_scope,
                &fresh.revision,
                Action::ClearAll
            ),
            Err(HistoryError::Changed)
        ));
        assert!(other.get(RECORD).unwrap().is_none());
        Repository::new(&mut vault)
            .delete(std::slice::from_ref(&a))
            .unwrap();
        assert_eq!(load(&mut vault).unwrap().total, 1);
        assert!(
            apply(
                &mut vault,
                &fresh.vault_scope,
                &fresh.revision,
                Action::ClearHost(a)
            )
            .is_err()
        );
        let orphan = load(&mut vault).unwrap();
        assert_eq!(apply_view(&mut vault, &orphan, Action::ClearAll).total, 0);
        let now = load(&mut vault).unwrap();
        let unknown = br#"{"version":99}"#;
        vault.put(RECORD, unknown).unwrap();
        assert!(load(&mut vault).is_err());
        assert!(
            apply(
                &mut vault,
                &now.vault_scope,
                &now.revision,
                Action::Enabled(false)
            )
            .is_err()
        );
        assert_eq!(vault.get(RECORD).unwrap().unwrap().as_slice(), unknown);
    }
    #[test]
    fn failure_preserves_original_history_and_writer_then_explicit_retry() {
        let tmp = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &tmp.path().join("failure.vault"),
            b"synthetic-controls-master",
        )
        .unwrap();
        let a = host(&mut vault);
        HistoryRepository::new(&mut vault)
            .record_qualified(&a, "git status")
            .unwrap();
        let before = load(&mut vault).unwrap();
        let old = vault.get(RECORD).unwrap().unwrap();
        let writer = vault.get(WRITER).unwrap().unwrap();
        vault.db.execute_batch(&format!("CREATE TRIGGER fail_controls BEFORE INSERT ON records WHEN NEW.id='{WRITER}' BEGIN SELECT RAISE(ABORT, 'synthetic controls failure'); END;")).unwrap();
        assert!(
            apply(
                &mut vault,
                &before.vault_scope,
                &before.revision,
                Action::ClearAll
            )
            .is_err()
        );
        assert_eq!(
            vault.get(RECORD).unwrap().unwrap().as_slice(),
            old.as_slice()
        );
        assert_eq!(
            vault.get(WRITER).unwrap().unwrap().as_slice(),
            writer.as_slice()
        );
        vault
            .db
            .execute_batch("DROP TRIGGER fail_controls")
            .unwrap();
        assert_eq!(apply_view(&mut vault, &before, Action::ClearAll).total, 0);
    }
}
