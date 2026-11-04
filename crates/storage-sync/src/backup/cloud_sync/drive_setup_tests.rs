use super::*;
use crate::{AuthMethod, Credential, HostRecord, Repository, google_drive_account as accounts};
fn account(v: &mut Vault) -> Account {
    v.put(accounts::RECORD, br#"{"version":1,"authorization_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","client_id":"synthetic-client.apps.googleusercontent.com","client_secret":"","refresh_token":"synthetic-refresh-token"}"#).unwrap();
    let view = accounts::load(v).unwrap();
    accounts::capture(v, &view.vault_scope, &view.revision).unwrap()
}
fn staged(v: &mut Vault, account: &Account) -> Creation {
    let route = settings::authorization_route(v).unwrap();
    stage(
        v,
        account,
        &route,
        ReservedObject::restore("synthetic-generated-id").unwrap(),
        Zeroizing::new("synthetic-e2e-password".into()),
        false,
        false,
    )
    .unwrap()
}
#[test]
fn restart_retains_same_generated_id_and_exact_body_without_selecting_target_or_exporting_intent() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("restart.vault");
    let mut v = Vault::create(&path, b"synthetic-master").unwrap();
    Repository::new(&mut v)
        .save(
            HostRecord::new(
                "initial".into(),
                "fixture.invalid".into(),
                "fixture".into(),
                AuthMethod::Password,
            ),
            Some(Credential {
                secret: "synthetic-initial-host-secret".into(),
                passphrase: None,
            }),
        )
        .unwrap();
    let account = account(&mut v);
    let creation = staged(&mut v, &account);
    let original = creation.view(&v).unwrap();
    let body = creation.body.to_vec();
    assert!(settings::load(&v).unwrap().target.is_none());
    assert!(
        !serde_json::to_string(&original)
            .unwrap()
            .contains("synthetic-e2e-password")
    );
    let backup = Snapshot::capture(&v).unwrap();
    for id in [META, BODY, accounts::RECORD] {
        assert!(!backup.records.contains_key(id));
    }
    drop(creation);
    drop(account);
    drop(v);
    let mut v = Vault::open(&path, b"synthetic-master").unwrap();
    let source = accounts::load(&v).unwrap();
    let account = accounts::capture(&v, &source.vault_scope, &source.revision).unwrap();
    let current = load(&v).unwrap().unwrap();
    assert_ne!(original.vault_scope, current.vault_scope);
    assert_eq!(original.id, current.id);
    let creation = capture(&v, &current.vault_scope, &current.revision).unwrap();
    creation.ensure_source(&v, &account).unwrap();
    let creation = creation.mark_attempt(&mut v, &account).unwrap();
    assert!(creation.view(&v).unwrap().attempted);
    assert!(capture(&v, &current.vault_scope, &current.revision).is_err());
    assert!(creation.same_ciphertext(&body));
    assert_eq!(
        creation
            .upload(journal::now_millis().unwrap())
            .unwrap()
            .ciphertext(),
        body
    );
    assert!(settings::load(&v).unwrap().target.is_none());
}
#[test]
fn changed_plaintext_or_account_never_republishes_old_snapshot_and_keeps_recovery_record() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("changed.vault"), b"synthetic-master").unwrap();
    let account = account(&mut v);
    let creation = staged(&mut v, &account);
    let source = crate::appearance::load(&v).unwrap();
    crate::appearance::save(
        &mut v,
        &source.vault_scope,
        &source.revision,
        crate::appearance::Theme::Light,
    )
    .unwrap();
    assert!(creation.ensure_source(&v, &account).is_err());
    assert!(load(&v).unwrap().is_some());
    assert!(settings::load(&v).unwrap().target.is_none());
    let route = settings::authorization_route(&v).unwrap();
    assert!(
        stage(
            &mut v,
            &account,
            &route,
            ReservedObject::restore("synthetic-other-id").unwrap(),
            Zeroizing::new("synthetic-other-password".into()),
            false,
            false
        )
        .is_err()
    );
}
#[test]
fn target_selection_and_intent_retirement_are_one_transaction_and_ack_has_no_post_commit_read() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("atomic.vault"), b"synthetic-master").unwrap();
    let account = account(&mut v);
    let creation = staged(&mut v, &account)
        .mark_attempt(&mut v, &account)
        .unwrap();
    let source = creation.view(&v).unwrap();
    let acknowledged = creation
        .upload(journal::now_millis().unwrap())
        .unwrap()
        .acknowledge(EntityTag::parse("\"synthetic-created\"").unwrap());
    v.db.execute_batch("CREATE TRIGGER fail_creation_retirement BEFORE DELETE ON records WHEN OLD.id='local-google-drive-creation-v1' BEGIN SELECT RAISE(ABORT,'synthetic retirement failure'); END;").unwrap();
    assert!(creation.finish(&mut v, &account, &acknowledged).is_err());
    assert!(settings::load(&v).unwrap().target.is_none());
    assert_eq!(load(&v).unwrap().unwrap().revision, source.revision);
    v.db.execute_batch("DROP TRIGGER fail_creation_retirement;")
        .unwrap();
    let creation = capture(&v, &source.vault_scope, &source.revision).unwrap();
    let saved = creation.finish(&mut v, &account, &acknowledged).unwrap();
    assert_eq!(saved.target.unwrap().drive.unwrap().file_id, source.id);
    assert!(load(&v).unwrap().is_none());
    assert!(v.get(BODY).unwrap().is_none());
    assert_eq!(settings::load(&v).unwrap().revision, saved.revision);
}
#[test]
fn local_discard_requires_exact_revision_and_confirmation_and_does_not_touch_target() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("discard.vault"), b"synthetic-master").unwrap();
    let account = account(&mut v);
    let creation = staged(&mut v, &account);
    let old = creation.view(&v).unwrap();
    let creation = creation.mark_attempt(&mut v, &account).unwrap();
    assert!(discard(&mut v, &old.vault_scope, &old.revision, true).is_err());
    let current = creation.view(&v).unwrap();
    assert!(discard(&mut v, &current.vault_scope, &current.revision, false).is_err());
    discard(&mut v, &current.vault_scope, &current.revision, true).unwrap();
    assert!(load(&v).unwrap().is_none());
    assert!(settings::load(&v).unwrap().target.is_none());
}
#[test]
fn future_metadata_and_incomplete_body_fail_closed_without_discarding_original_rows() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("corrupt.vault"), b"synthetic-master").unwrap();
    let account = account(&mut v);
    let mut creation = staged(&mut v, &account);
    creation.stored.version = 99;
    v.put(META, &encode(&creation.stored).unwrap()).unwrap();
    assert!(load(&v).is_err());
    assert!(v.get(BODY).unwrap().is_some());
    creation.stored.version = 1;
    v.put(META, &encode(&creation.stored).unwrap()).unwrap();
    v.put(BODY, b"synthetic-truncated-ciphertext").unwrap();
    assert!(load(&v).is_err());
    assert!(v.get(META).unwrap().is_some());
}
