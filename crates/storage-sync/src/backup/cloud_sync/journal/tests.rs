use super::*;
use crate::{AuthMethod, Credential, HostDraft, Repository};
fn vault(root: &std::path::Path) -> Vault {
    Vault::create(&root.join("journal.vault"), b"synthetic-journal-master").unwrap()
}
fn host(v: &mut Vault) -> HostRecord {
    Repository::new(v)
        .save(
            HostRecord::new(
                "Synthetic formal host".into(),
                "journal-fixture.invalid".into(),
                "fixture".into(),
                AuthMethod::Password,
            ),
            Some(Credential {
                secret: "synthetic-only-journal-password".into(),
                passphrase: None,
            }),
        )
        .unwrap()
}
fn raw(v: &Vault) -> Zeroizing<Vec<u8>> {
    v.get_bounded(RECORD, LIMIT).unwrap().unwrap()
}
fn read(v: &Vault) -> Journal {
    Journal::decode(&raw(v), now_millis().unwrap()).unwrap()
}
fn local_events(rx: &mut tokio::sync::broadcast::Receiver<String>, scope: &str) -> usize {
    let mut count = 0;
    loop {
        match rx.try_recv() {
            Ok(value) => count += usize::from(value == scope),
            Err(tokio::sync::broadcast::error::TryRecvError::Lagged(_)) => continue,
            Err(_) => return count,
        }
    }
}
#[test]
fn explicit_enable_is_idempotent_and_capture_retains_the_actual_transaction_time() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let h = host(&mut v);
    assert!(v.get(RECORD).unwrap().is_none());
    enable(&mut v).unwrap();
    let initial = raw(&v);
    enable(&mut v).unwrap();
    assert!(initial.as_slice() == raw(&v).as_slice());
    let now = now_millis().unwrap();
    let collection = "0123456789abcdef0123456789abcdef";
    let baseline = Baseline::load(&v, collection, now).unwrap();
    let first = baseline.capture_local(&v, now).unwrap();
    baseline
        .prepare_apply(&v, &first, first.document(), None, now)
        .unwrap()
        .commit(&mut v)
        .unwrap();
    let mut h = Repository::new(&mut v).host(&h.id).unwrap().unwrap();
    h.name = "Changed at write".into();
    Repository::new(&mut v).save(h.clone(), None).unwrap();
    let actual_stamp = read(&v).pending[&h.id].clone();
    let delayed = now_millis().unwrap() + 60 * 60 * 1000;
    let baseline = Baseline::load(&v, collection, delayed).unwrap();
    let captured = baseline.capture_local(&v, delayed).unwrap();
    let stamp = &captured
        .document()
        .items
        .iter()
        .find(|i| i.id == h.id)
        .unwrap()
        .stamp;
    assert!(stamp == &actual_stamp);
    assert!(stamp.unix_ms < delayed);
}
#[test]
fn a_failed_configuration_or_journal_write_rolls_back_both_and_does_not_notify() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let mut h = host(&mut v);
    enable(&mut v).unwrap();
    let original = v.get(&h.id).unwrap().unwrap();
    let before = raw(&v);
    let scope = v.instance_id().to_owned();
    let mut rx = subscribe();
    v.db.execute_batch(&format!("CREATE TRIGGER fail_sync_clock BEFORE INSERT ON records WHEN NEW.id='{RECORD}' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;")).unwrap();
    h.name = "Must not publish".into();
    assert!(Repository::new(&mut v).save(h.clone(), None).is_err());
    assert!(v.get(&h.id).unwrap().unwrap().as_slice() == original.as_slice());
    assert!(raw(&v).as_slice() == before.as_slice());
    assert_eq!(local_events(&mut rx, &scope), 0);
    v.db.execute_batch("DROP TRIGGER fail_sync_clock;").unwrap();
    v.db.execute_batch(&format!("CREATE TRIGGER fail_sync_host BEFORE INSERT ON records WHEN NEW.id='{}' BEGIN SELECT RAISE(ABORT,'synthetic host failure'); END;", h.id)).unwrap();
    assert!(Repository::new(&mut v).save(h.clone(), None).is_err());
    assert!(raw(&v).as_slice() == before.as_slice());
    assert_eq!(local_events(&mut rx, &scope), 0);
    v.db.execute_batch("DROP TRIGGER fail_sync_host;").unwrap();
    Repository::new(&mut v).save(h, None).unwrap();
    assert_eq!(local_events(&mut rx, &scope), 1);
}
#[test]
fn drafts_device_bodies_same_bytes_missing_delete_and_failed_cas_are_not_sync_changes() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let h = host(&mut v);
    enable(&mut v).unwrap();
    let before = raw(&v);
    let mut rx = subscribe();
    let scope = v.instance_id().to_owned();
    v.put("local-task-fixture", b"synthetic-body").unwrap();
    v.delete("local-task-fixture").unwrap();
    let draft = HostRecord::new(
        "Draft only".into(),
        "draft.invalid".into(),
        "fixture".into(),
        AuthMethod::Password,
    );
    Repository::new(&mut v)
        .save_draft(&HostDraft {
            host: draft,
            credential: None,
            proxy_credential: None,
        })
        .unwrap();
    let original = v.get(&h.id).unwrap().unwrap();
    v.put(&h.id, &original).unwrap();
    assert!(!v.delete("config-file-open-settings-v1").unwrap());
    assert!(
        !v.apply_checked(&[(&h.id, None)], &[RecordChange::Delete(&h.id)])
            .unwrap()
    );
    assert!(raw(&v).as_slice() == before.as_slice());
    assert_eq!(local_events(&mut rx, &scope), 0);
}
#[test]
fn secret_only_updates_are_owned_by_the_formal_host_and_metadata_never_copies_the_secret() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let h = host(&mut v);
    enable(&mut v).unwrap();
    let before = read(&v).pending[&h.id].clone();
    let credential = Credential {
        secret: "synthetic-updated-journal-secret".into(),
        passphrase: None,
    };
    let bytes = Zeroizing::new(serde_json::to_vec(&credential).unwrap());
    v.put(h.credential_id.as_ref().unwrap(), &bytes).unwrap();
    let after = read(&v);
    assert!(after.pending[&h.id] > before);
    let decoded = raw(&v);
    let text = std::str::from_utf8(&decoded).unwrap();
    for secret in [
        "synthetic-updated-journal-secret",
        "Synthetic formal host",
        "journal-fixture.invalid",
        "credential-",
    ] {
        assert!(!text.contains(secret));
    }
}
#[test]
fn cloud_ack_observes_remote_clock_retires_pending_atomically_and_does_not_trigger_upload_feedback()
{
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let h = host(&mut v);
    enable(&mut v).unwrap();
    let now = now_millis().unwrap();
    let baseline = Baseline::load(&v, "0123456789abcdef0123456789abcdef", now).unwrap();
    let proposal = baseline.capture_local(&v, now).unwrap();
    let mut remote = proposal.document().clone();
    for item in &mut remote.items {
        item.stamp = Stamp::next(None, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", now + 1000).unwrap();
    }
    let (merged, _) = proposal
        .document()
        .merge(baseline.document(), &remote, now + 1000)
        .unwrap();
    let mut rx = subscribe();
    baseline
        .prepare_apply(&v, &proposal, &merged, None, now + 1000)
        .unwrap()
        .commit(&mut v)
        .unwrap();
    assert!(read(&v).pending.is_empty());
    assert_eq!(local_events(&mut rx, v.instance_id()), 0);
    let mut changed = Repository::new(&mut v).host(&h.id).unwrap().unwrap();
    changed.note = "new local edit".into();
    Repository::new(&mut v).save(changed, None).unwrap();
    let stamp = read(&v).pending[&h.id].clone();
    assert!(stamp.unix_ms >= now + 1000);
    assert!(stamp > merged.items.iter().map(|i| &i.stamp).max().unwrap().clone());
}
#[test]
fn edits_then_revert_to_same_bytes_still_retire_a_proposal_through_the_journal_cas() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let h = host(&mut v);
    enable(&mut v).unwrap();
    let now = now_millis().unwrap();
    let baseline = Baseline::load(&v, "0123456789abcdef0123456789abcdef", now).unwrap();
    let proposal = baseline.capture_local(&v, now).unwrap();
    let original = v.get(&h.id).unwrap().unwrap();
    let mut changed = h.clone();
    changed.note = "intervening mutation".into();
    Repository::new(&mut v).save(changed, None).unwrap();
    Repository::new(&mut v).save(h, None).unwrap();
    assert!(
        v.get(&serde_json::from_slice::<HostRecord>(&original).unwrap().id)
            .unwrap()
            .unwrap()
            .as_slice()
            == original.as_slice()
    );
    assert!(matches!(
        baseline.prepare_apply(
            &v,
            &proposal,
            proposal.document(),
            None,
            now_millis().unwrap()
        ),
        Err(SyncError::Changed)
    ));
}
#[test]
fn future_or_damaged_tracking_cannot_be_silently_reset_by_a_configuration_save() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let mut h = host(&mut v);
    enable(&mut v).unwrap();
    let old = v.get(&h.id).unwrap().unwrap();
    let future = br#"{"version":99}"#;
    v.put(RECORD, future).unwrap();
    h.name = "Blocked by unknown tracking".into();
    assert!(Repository::new(&mut v).save(h, None).is_err());
    assert!(
        v.get(&serde_json::from_slice::<HostRecord>(&old).unwrap().id)
            .unwrap()
            .unwrap()
            .as_slice()
            == old.as_slice()
    );
    assert!(raw(&v).as_slice() == future);
    assert!(enable(&mut v).is_err());
}
