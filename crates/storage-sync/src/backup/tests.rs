use super::*;
use crate::{AuthMethod, Credential, HostRecord};
fn host(v: &mut Vault, name: &str) -> HostRecord {
    Repository::new(v)
        .save(
            HostRecord::new(
                name.into(),
                "fixture.example.test".into(),
                "fixture".into(),
                AuthMethod::Password,
            ),
            Some(Credential {
                secret: format!("synthetic-{name}-credential"),
                passphrase: None,
            }),
        )
        .unwrap()
}
fn selections(preview: &Preview) -> Vec<String> {
    preview
        .items
        .iter()
        .filter(|i| i.default_incoming)
        .map(|i| i.id.clone())
        .collect()
}
#[test]
fn allowlisted_snapshot_excludes_device_tasks_drafts_writer_and_secret_previews() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("config.vault"), b"synthetic-master").unwrap();
    let h = host(&mut v, "fixture");
    for key in [
        "local-task-private",
        "local-explorer-owner-v1-fixture",
        "device-command-history-writer-v1",
        "draft-orphan",
        "local-preview-private",
        crate::google_drive_account::RECORD,
    ] {
        v.put(key, b"synthetic-excluded-body").unwrap();
    }
    let snapshot = Snapshot::capture(&v).unwrap();
    assert!(!snapshot.records.keys().any(|key| key.starts_with("local-")
        || key.starts_with("draft-")
        || key == "device-command-history-writer-v1"));
    let preview = preview(&v, &snapshot, "merge").unwrap();
    let json = serde_json::to_string(&preview).unwrap();
    assert!(!json.contains("synthetic-fixture-credential"));
    assert!(preview.items.iter().any(|i| i.id == h.id));
    let mut oversized = Vec::new();
    oversized.extend_from_slice(&1u32.to_be_bytes());
    oversized.extend_from_slice(&1u32.to_be_bytes());
    oversized.extend_from_slice(&u32::MAX.to_be_bytes());
    assert!(Snapshot::read(&mut oversized.as_slice()).is_err());
}
#[test]
fn encrypted_file_roundtrip_never_overwrites_existing_or_leaks_secret() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("source.vault"), b"synthetic-master").unwrap();
    host(&mut v, "roundtrip");
    let source = Snapshot::capture(&v).unwrap();
    let path = dir.path().join("complete.hspbackup");
    source
        .write_encrypted(&path, b"synthetic-backup-password")
        .unwrap();
    let bytes = std::fs::read(&path).unwrap();
    assert!(
        !bytes
            .windows(b"synthetic-roundtrip-credential".len())
            .any(|w| w == b"synthetic-roundtrip-credential")
    );
    let loaded = Snapshot::read_encrypted(&path, b"synthetic-backup-password").unwrap();
    assert_eq!(source.revision(&v), loaded.revision(&v));
    assert!(
        source
            .write_encrypted(&path, b"synthetic-another-password")
            .is_err()
    );
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    assert!(Snapshot::read_encrypted(&path, b"synthetic-wrong-password").is_err());
}
#[test]
fn merge_defaults_keep_local_conflicts_and_import_new_host_with_independent_credentials() {
    let dir = tempfile::tempdir().unwrap();
    let mut local =
        Vault::create(&dir.path().join("local.vault"), b"synthetic-local-master").unwrap();
    let first = host(&mut local, "local-first");
    let second = host(&mut local, "local-only");
    let mut remote =
        Vault::create(&dir.path().join("remote.vault"), b"synthetic-remote-master").unwrap();
    let mut different = first.clone();
    different.name = "incoming-conflict".into();
    Repository::new(&mut remote)
        .save(
            different,
            Some(Credential {
                secret: "synthetic-incoming-conflict-secret".into(),
                passphrase: None,
            }),
        )
        .unwrap();
    let third = host(&mut remote, "incoming-new");
    local
        .put("local-task-preserved", b"synthetic-device-state")
        .unwrap();
    let incoming = Snapshot::capture(&remote).unwrap();
    let p = preview(&local, &incoming, "merge").unwrap();
    assert!(
        !p.items
            .iter()
            .find(|i| i.id == first.id)
            .unwrap()
            .default_incoming
    );
    assert!(
        !p.items
            .iter()
            .find(|i| i.id == second.id)
            .unwrap()
            .default_incoming
    );
    let plan = prepare_restore(
        &local,
        &incoming,
        &p.vault_scope,
        &p.revision,
        &selections(&p),
    )
    .unwrap();
    plan.commit(&mut local).unwrap();
    assert_ne!(local.instance_id(), p.vault_scope);
    let repo = Repository::new(&mut local);
    assert_eq!(repo.host(&first.id).unwrap().unwrap().name, "local-first");
    assert!(repo.host(&second.id).unwrap().is_some());
    assert_ne!(
        repo.host(&third.id).unwrap().unwrap().credential_id,
        third.credential_id
    );
    assert_eq!(
        repo.credential(&third.id).unwrap().unwrap().secret,
        "synthetic-incoming-new-credential"
    );
    assert_eq!(
        local
            .get("local-task-preserved")
            .unwrap()
            .unwrap()
            .as_slice(),
        b"synthetic-device-state"
    );
    assert!(
        prepare_restore(
            &local,
            &incoming,
            &p.vault_scope,
            &p.revision,
            &selections(&p)
        )
        .is_err()
    );
}
#[test]
fn replace_removes_only_selected_formal_units_and_keeps_local_drafts() {
    let dir = tempfile::tempdir().unwrap();
    let mut local = Vault::create(&dir.path().join("local.vault"), b"synthetic-master").unwrap();
    let old = host(&mut local, "old");
    let draft = HostRecord::new(
        "synthetic draft".into(),
        "draft.example.test".into(),
        "fixture".into(),
        AuthMethod::Password,
    );
    Repository::new(&mut local)
        .save_draft(&crate::HostDraft {
            host: draft.clone(),
            credential: None,
            proxy_credential: None,
        })
        .unwrap();
    let draft_key = format!("draft-{}", draft.id);
    let draft_before = local.get(&draft_key).unwrap().unwrap();
    let remote =
        Vault::create(&dir.path().join("remote.vault"), b"synthetic-remote-master").unwrap();
    let incoming = Snapshot::capture(&remote).unwrap();
    let p = preview(&local, &incoming, "replace").unwrap();
    prepare_restore(
        &local,
        &incoming,
        &p.vault_scope,
        &p.revision,
        &selections(&p),
    )
    .unwrap()
    .commit(&mut local)
    .unwrap();
    assert!(Repository::new(&mut local).list().unwrap().is_empty());
    assert!(local.get(&old.id).unwrap().is_none());
    assert!(
        local
            .get(old.credential_id.as_deref().unwrap())
            .unwrap()
            .is_none()
    );
    assert_eq!(
        local.get(&draft_key).unwrap().unwrap().as_slice(),
        draft_before.as_slice()
    );
    assert_eq!(
        Repository::new(&mut local).drafts().unwrap()[0].host.id,
        draft.id
    );
}
#[test]
fn phantom_external_record_is_rejected_and_sql_failure_keeps_all_source_rows() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("local.vault");
    let mut local = Vault::create(&path, b"synthetic-master").unwrap();
    let old = host(&mut local, "old");
    let mut remote =
        Vault::create(&dir.path().join("remote.vault"), b"synthetic-remote-master").unwrap();
    host(&mut remote, "new");
    let incoming = Snapshot::capture(&remote).unwrap();
    let p = preview(&local, &incoming, "replace").unwrap();
    let plan = prepare_restore(
        &local,
        &incoming,
        &p.vault_scope,
        &p.revision,
        &selections(&p),
    )
    .unwrap();
    let mut other = Vault::open(&path, b"synthetic-master").unwrap();
    other
        .put(
            &format!("trust-{}", "a".repeat(64)),
            format!("SHA256:{}", "A".repeat(43)).as_bytes(),
        )
        .unwrap();
    assert!(matches!(plan.commit(&mut local), Err(BackupError::Changed)));
    let p = preview(&local, &incoming, "replace").unwrap();
    let plan = prepare_restore(
        &local,
        &incoming,
        &p.vault_scope,
        &p.revision,
        &selections(&p),
    )
    .unwrap();
    local.db.execute_batch("CREATE TEMP TRIGGER reject_restore BEFORE INSERT ON records WHEN NEW.id GLOB 'credential-*' BEGIN SELECT RAISE(FAIL, 'synthetic restore failure'); END;").unwrap();
    assert!(plan.commit(&mut local).is_err());
    assert_eq!(local.instance_id(), p.vault_scope);
    assert_eq!(
        Repository::new(&mut local)
            .host(&old.id)
            .unwrap()
            .unwrap()
            .name,
        "old"
    );
}
#[test]
fn restore_history_merges_clear_epochs_instead_of_resurrecting_old_commands() {
    let dir = tempfile::tempdir().unwrap();
    let mut local = Vault::create(&dir.path().join("history.vault"), b"synthetic-master").unwrap();
    let h = host(&mut local, "history");
    crate::command_history::HistoryRepository::new(&mut local)
        .record_qualified(&h.id, "printf synthetic-history-before-clear")
        .unwrap();
    let incoming = Snapshot::capture(&local).unwrap();
    crate::command_history::HistoryRepository::new(&mut local)
        .clear(None)
        .unwrap();
    let p = preview(&local, &incoming, "merge").unwrap();
    prepare_restore(
        &local,
        &incoming,
        &p.vault_scope,
        &p.revision,
        &[HISTORY.into()],
    )
    .unwrap()
    .commit(&mut local)
    .unwrap();
    let payload = crate::command_history::HistoryRepository::new(&mut local)
        .export_payload()
        .unwrap();
    assert!(
        !std::str::from_utf8(&payload)
            .unwrap()
            .contains("synthetic-history-before-clear")
    );
}
#[test]
fn unknown_namespaces_and_broken_jump_references_are_rejected_without_writes() {
    let dir = tempfile::tempdir().unwrap();
    let mut local = Vault::create(&dir.path().join("local.vault"), b"synthetic-master").unwrap();
    let h = host(&mut local, "fixture");
    let before = Snapshot::capture(&local).unwrap();
    let mut invalid = before.clone();
    invalid.records.insert(
        "local-editor-private".into(),
        Arc::new(Zeroizing::new(b"synthetic-body".to_vec())),
    );
    assert!(invalid.validate().is_err());
    let mut invalid = before.clone();
    let mut bad = h.clone();
    bad.jump_host_id = Some(format!("host-{}", "f".repeat(32)));
    invalid.records.insert(h.id.clone(), json(&bad).unwrap());
    assert!(invalid.validate().is_err());
    assert_eq!(
        Snapshot::capture(&local).unwrap().revision(&local),
        before.revision(&local)
    );
}
