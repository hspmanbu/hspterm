use super::*;
use crate::{
    AuthMethod, Credential, HostRecord, RecordChange, Repository,
    command_history::HistoryRepository,
};

const COLLECTION: &str = "0123456789abcdef0123456789abcdef";
const ACTOR_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const ACTOR_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const NOW: u64 = 1_800_000_000_000;
#[test]
fn sftp_view_defaults_are_allowlisted_for_backup_and_encrypted_configuration_units() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "sftp-defaults.vault");
    let source = crate::sftp_view_settings::load(&v).unwrap();
    crate::sftp_view_settings::save(
        &mut v,
        crate::sftp_view_settings::Proposal {
            vault_scope: source.vault_scope,
            revision: source.revision,
            settings: crate::sftp_view_settings::Settings {
                folders_first: false,
                show_hidden: true,
                compact: true,
                restore_last_directory: false,
            },
        },
    )
    .unwrap();
    let full = Snapshot::capture(&v).unwrap();
    assert!(full.records.contains_key(crate::sftp_view_settings::RECORD));
    let document = Document::empty(COLLECTION)
        .unwrap()
        .capture(&v, ACTOR_A, NOW)
        .unwrap();
    assert!(
        document
            .items
            .iter()
            .any(|item| item.id == crate::sftp_view_settings::RECORD)
    );
}
#[test]
fn portable_typography_syncs_geometry_without_local_family_or_font_bytes() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "geometry-sync.vault");
    let original = crate::typography::load(&v).unwrap();
    let bytes = std::fs::read(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../ui_flutter/assets/fonts/JetBrainsMono-Regular.ttf"
    ))
    .unwrap();
    let imported = crate::typography::import(
        &mut v,
        &original.vault_scope,
        &original.revision,
        "Synthetic device-only family".into(),
        &bytes,
    )
    .unwrap();
    let id = imported.fonts[0].id.clone();
    crate::typography::save(
        &mut v,
        crate::typography::Proposal {
            vault_scope: imported.vault_scope,
            revision: imported.revision,
            settings: crate::typography::Settings {
                kind: "imported".into(),
                family: id.clone(),
                size: 19.,
                ..crate::typography::Settings::default()
            },
        },
    )
    .unwrap();
    let document = Document::empty(COLLECTION)
        .unwrap()
        .capture(&v, ACTOR_A, NOW)
        .unwrap();
    assert!(
        !document
            .items
            .iter()
            .any(|item| item.id == "local-terminal-typography-v1"
                || item.id.starts_with("device-terminal-font-"))
    );
    let item = document
        .items
        .iter()
        .find(|item| item.id == crate::terminal_preferences::RECORD)
        .unwrap();
    let bundle = item.value.as_ref().unwrap();
    assert_eq!(bundle.records.len(), 1);
    let raw = &bundle.records[crate::terminal_preferences::RECORD];
    let value: serde_json::Value = serde_json::from_slice(raw).unwrap();
    assert_eq!(value["typography"]["size"].as_f64(), Some(19.));
    assert_eq!(value["typography"].as_object().unwrap().len(), 4);
    let text = std::str::from_utf8(raw).unwrap();
    assert!(!text.contains(&id));
    assert!(!text.contains("Synthetic device-only family"));
    let full = Snapshot::capture(&v).unwrap();
    assert!(full.records.contains_key("local-terminal-typography-v1"));
    assert!(
        full.records
            .contains_key(&format!("device-terminal-font-v1-{id}"))
    );
}
#[test]
fn appearance_is_sync_and_backup_eligible_and_unknown_versions_fail_validation() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "appearance-sync.vault");
    let source = crate::appearance::load(&v).unwrap();
    crate::appearance::save(
        &mut v,
        &source.vault_scope,
        &source.revision,
        crate::appearance::Theme::Light,
    )
    .unwrap();
    let document = Document::empty(COLLECTION)
        .unwrap()
        .capture(&v, ACTOR_A, NOW)
        .unwrap();
    assert!(
        document
            .items
            .iter()
            .any(|item| item.id == crate::appearance::RECORD)
    );
    assert!(
        Snapshot::capture(&v)
            .unwrap()
            .records
            .contains_key(crate::appearance::RECORD)
    );
    v.put(
        crate::appearance::RECORD,
        br#"{"version":99,"theme":"light"}"#,
    )
    .unwrap();
    assert!(
        Document::empty(COLLECTION)
            .unwrap()
            .capture(&v, ACTOR_A, NOW)
            .is_err()
    );
    assert!(Snapshot::capture(&v).is_err());
}
fn vault(dir: &std::path::Path, name: &str) -> Vault {
    Vault::create(&dir.join(name), b"synthetic-cloud-fixture-master").unwrap()
}
fn host(v: &mut Vault, name: &str) -> HostRecord {
    Repository::new(v)
        .save(
            HostRecord::new(
                name.into(),
                "sync-fixture.invalid".into(),
                "fixture".into(),
                AuthMethod::Password,
            ),
            Some(Credential {
                secret: "synthetic-cloud-only-credential".into(),
                passphrase: None,
            }),
        )
        .unwrap()
}
fn encoded(doc: &Document) -> Zeroizing<Vec<u8>> {
    doc.encode(NOW + 1000).unwrap()
}
fn apply(v: &mut Vault, baseline: &Baseline, proposal: &LocalProposal, doc: &Document) {
    baseline
        .prepare_apply(
            v,
            proposal,
            doc,
            Some(EntityTag::parse("\"fixture-revision\"").unwrap()),
            NOW + 1000,
        )
        .unwrap()
        .commit(v)
        .unwrap();
}

#[test]
fn explicit_cloud_allowlist_never_reads_local_fonts_or_trust_and_canonicalizes_secret_ids() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "allowlist.vault");
    let h = host(&mut v, "Formal host");
    let draft = HostRecord::new(
        "Unsaved draft".into(),
        "draft.invalid".into(),
        "fixture".into(),
        AuthMethod::Password,
    );
    Repository::new(&mut v)
        .save_draft(&crate::HostDraft {
            host: draft,
            credential: Some(Credential {
                secret: "synthetic-excluded-draft".into(),
                passphrase: None,
            }),
            proxy_credential: None,
        })
        .unwrap();
    for id in [
        "local-task-sensitive",
        "device-command-history-writer-v1",
        "local-preview-sensitive",
        "local-terminal-typography-v1",
        "device-terminal-font-v1-private",
        "trust-not-a-valid-hash",
        crate::google_drive_account::RECORD,
    ] {
        v.put(id, b"synthetic-excluded-body").unwrap();
        // If synchronization tries to read any of these, GCM verification fails.
        v.db.execute("UPDATE records SET nonce=x'00' WHERE id=?1", [id])
            .unwrap();
    }
    let doc = Document::empty(COLLECTION)
        .unwrap()
        .capture(&v, ACTOR_A, NOW)
        .unwrap();
    let plain = encoded(&doc);
    let text = std::str::from_utf8(&plain).unwrap();
    for excluded in [
        "Unsaved draft",
        "synthetic-excluded-body",
        "local-task-",
        "local-preview-",
        "local-terminal-",
        "device-terminal-",
        "trust-",
    ] {
        assert!(!text.contains(excluded));
    }
    let item = doc.items.iter().find(|i| i.id == h.id).unwrap();
    let bytes = &item.value.as_ref().unwrap().records[&h.id];
    let wire_host: HostRecord = serde_json::from_slice(bytes).unwrap();
    assert_eq!(
        wire_host.credential_id.as_deref(),
        Some(format!("credential-{}", &h.id[5..]).as_str())
    );
    assert_ne!(wire_host.credential_id, h.credential_id);
}

#[test]
fn two_devices_merge_disjoint_hosts_then_apply_without_a_credential_or_order_resync_loop() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = vault(dir.path(), "a.vault");
    let mut b = vault(dir.path(), "b.vault");
    let x = host(&mut a, "Host A");
    let mut y = host(&mut b, "Host B");
    y.address = "different-endpoint.invalid".into();
    Repository::new(&mut b).save(y.clone(), None).unwrap();
    let ba = Baseline::load(&a, COLLECTION, NOW).unwrap();
    let bb = Baseline::load(&b, COLLECTION, NOW).unwrap();
    let pa = ba.capture_local(&a, NOW).unwrap();
    let pb = bb.capture_local(&b, NOW + 1).unwrap();
    let empty = Document::empty(COLLECTION).unwrap();
    let (merged, _) = pa.document().merge(&empty, pb.document(), NOW + 2).unwrap();
    let (reverse, _) = pb.document().merge(&empty, pa.document(), NOW + 2).unwrap();
    assert!(encoded(&merged).as_slice() == encoded(&reverse).as_slice());
    apply(&mut a, &ba, &pa, &merged);
    apply(&mut b, &bb, &pb, &merged);
    assert_eq!(Repository::new(&mut a).list().unwrap().len(), 2);
    assert_eq!(Repository::new(&mut b).list().unwrap().len(), 2);
    let imported = Repository::new(&mut b).host(&x.id).unwrap().unwrap();
    assert_ne!(imported.credential_id, x.credential_id);
    assert_eq!(
        Repository::new(&mut b)
            .host(&y.id)
            .unwrap()
            .unwrap()
            .credential_id,
        y.credential_id
    );
    let old_cred = imported.credential_id;
    let fresh = Baseline::load(&b, COLLECTION, NOW + 3).unwrap();
    let next = fresh.capture_local(&b, NOW + 4).unwrap();
    assert!(encoded(next.document()).as_slice() == encoded(&merged).as_slice());
    assert_eq!(
        Repository::new(&mut b)
            .host(&x.id)
            .unwrap()
            .unwrap()
            .credential_id,
        old_cred
    );
}

#[test]
fn lww_deletions_survive_an_offline_device_and_equal_timestamp_equivocation_is_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "delete.vault");
    let h = host(&mut v, "Delete fixture");
    let initial = Document::empty(COLLECTION)
        .unwrap()
        .capture(&v, ACTOR_A, NOW)
        .unwrap();
    Repository::new(&mut v)
        .delete(std::slice::from_ref(&h.id))
        .unwrap();
    let deleted = initial.capture(&v, ACTOR_A, NOW + 10).unwrap();
    // A device whose baseline is the pre-deletion document pulls the deletion:
    // its side is unchanged since the baseline, so the cloud tombstone wins.
    let (merged, summary) = initial.merge(&initial, &deleted, NOW + 20).unwrap();
    assert_eq!(summary.incoming_deletions, 1);
    assert_eq!(summary.conflicts, 0);
    assert!(
        merged
            .items
            .iter()
            .find(|i| i.id == h.id)
            .unwrap()
            .value
            .is_none()
    );
    // Re-applying the same merge from the same unchanged baseline is
    // idempotent: the old snapshot cannot revive the deleted host.
    let (again, summary) = initial.merge(&initial, &merged, NOW + 20).unwrap();
    assert_eq!(summary.incoming_deletions, 1);
    assert!(encoded(&again).as_slice() == encoded(&merged).as_slice());
    // A device that MODIFIED the host while another device deleted it has no
    // automatic winner: the unit is reported for an explicit direction choice.
    let mut modified = initial.clone();
    let item = modified.items.iter_mut().find(|i| i.id == h.id).unwrap();
    item.stamp = Stamp::next(Some(&item.stamp), ACTOR_B, NOW + 5).unwrap();
    let (divergent, diverged_summary) = modified.merge(&initial, &deleted, NOW + 20).unwrap();
    assert_eq!(diverged_summary.conflicts, 1);
    assert_eq!(diverged_summary.diverged.as_slice(), [h.id.as_str()]);
    assert!(
        divergent
            .items
            .iter()
            .find(|i| i.id == h.id)
            .unwrap()
            .value
            .is_some()
    );
    let (mut corrupted, _) = modified
        .merge_candidate(&initial, &deleted, NOW + 20, Divergence::PreferRemote)
        .unwrap();
    assert!(
        corrupted
            .items
            .iter()
            .find(|i| i.id == h.id)
            .unwrap()
            .value
            .is_none()
    );
    corrupted = initial.clone();
    corrupted
        .items
        .iter_mut()
        .find(|i| i.id == h.id)
        .unwrap()
        .value = None;
    assert!(matches!(
        initial.merge(&empty_base(), &corrupted, NOW + 20),
        Err(SyncError::Invalid)
    ));
    // Explicit later recreation is an actual new local operation, not an old
    // offline snapshot resurfacing after deletion-marker pruning.
}

fn empty_base() -> Document {
    Document::empty(COLLECTION).unwrap()
}

#[test]
fn synchronization_keeps_unrelated_proposal_scope_and_reports_only_actual_incoming_units() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "stable-scope.vault");
    let h = host(&mut v, "Stable scope fixture");
    let scope = v.instance_id().to_owned();
    let original = h.credential_id.clone();
    let baseline = Baseline::load(&v, COLLECTION, NOW).unwrap();
    let proposal = baseline.capture_local(&v, NOW).unwrap();
    let plan = baseline
        .prepare_apply(&v, &proposal, proposal.document(), None, NOW)
        .unwrap();
    assert!(plan.changed_units().is_empty());
    plan.commit(&mut v).unwrap();
    assert_eq!(v.instance_id(), scope);
    assert_eq!(
        Repository::new(&mut v)
            .host(&h.id)
            .unwrap()
            .unwrap()
            .credential_id,
        original
    );
    assert!(baseline.capture_local(&v, NOW + 1).is_err());
}

#[test]
fn history_merges_commands_and_clear_epochs_even_if_the_other_document_has_a_newer_lww_stamp() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "history.vault");
    let h = host(&mut v, "History fixture");
    HistoryRepository::new(&mut v)
        .record_qualified(&h.id, "git status")
        .unwrap();
    let initial = Document::empty(COLLECTION)
        .unwrap()
        .capture(&v, ACTOR_A, NOW)
        .unwrap();
    let old_payload = HistoryRepository::new(&mut v).export_payload().unwrap();
    HistoryRepository::new(&mut v).clear(None).unwrap();
    let cleared = initial.capture(&v, ACTOR_A, NOW + 10).unwrap();
    let mut stale = initial.clone();
    stale
        .items
        .iter_mut()
        .find(|i| i.id == super::super::HISTORY)
        .unwrap()
        .stamp = Stamp::next(None, ACTOR_B, NOW + 20).unwrap();
    let (merged, _) = cleared
        .merge(&Document::empty(COLLECTION).unwrap(), &stale, NOW + 30)
        .unwrap();
    let item = merged
        .items
        .iter()
        .find(|i| i.id == super::super::HISTORY)
        .unwrap();
    let payload = projection::history(item).unwrap();
    assert!(payload != old_payload.as_slice());
    let again = crate::command_history::merge_sync_payload(payload, &old_payload).unwrap();
    assert!(again.as_slice() == payload);
    assert!(!std::str::from_utf8(payload).unwrap().contains("git status"));
    let mut deletion = cleared.clone();
    deletion
        .items
        .iter_mut()
        .find(|i| i.id == super::super::HISTORY)
        .unwrap()
        .value = None;
    assert!(deletion.validate(NOW + 30).is_err());
}

#[test]
fn proposal_rejects_edits_during_network_io_and_failed_commit_preserves_config_and_ledger() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "atomic.vault");
    let h = host(&mut v, "Atomic fixture");
    let baseline = Baseline::load(&v, COLLECTION, NOW).unwrap();
    let proposal = baseline.capture_local(&v, NOW).unwrap();
    let saved = Repository::new(&mut v).host(&h.id).unwrap().unwrap();
    let mut edited = saved.clone();
    edited.name = "User edited during network IO".into();
    Repository::new(&mut v).save(edited, None).unwrap();
    assert!(matches!(
        baseline.prepare_apply(&v, &proposal, proposal.document(), None, NOW + 1),
        Err(SyncError::Changed)
    ));
    let fresh = baseline.capture_local(&v, NOW + 2).unwrap();
    let original_scope = v.instance_id().to_owned();
    let original = v.get(&h.id).unwrap().unwrap();
    let plan = baseline
        .prepare_apply(&v, &fresh, fresh.document(), None, NOW + 3)
        .unwrap();
    v.db.execute_batch(&format!("CREATE TRIGGER fail_cloud BEFORE INSERT ON records WHEN NEW.id='{LEDGER}' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;")).unwrap();
    assert!(plan.commit(&mut v).is_err());
    assert_eq!(v.instance_id(), original_scope);
    assert!(v.get(LEDGER).unwrap().is_none());
    assert!(v.get(&h.id).unwrap().unwrap().as_slice() == original.as_slice());
    v.db.execute_batch("DROP TRIGGER fail_cloud;").unwrap();
    apply(&mut v, &baseline, &fresh, fresh.document());
    assert!(v.get(LEDGER).unwrap().is_some());
    assert!(baseline.capture_local(&v, NOW + 4).is_err());
}

#[test]
fn record_and_external_sqlite_changes_cannot_race_atomic_publication() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "external.vault");
    host(&mut v, "External fixture");
    let b = Baseline::load(&v, COLLECTION, NOW).unwrap();
    let p = b.capture_local(&v, NOW).unwrap();
    let plan = b
        .prepare_apply(&v, &p, p.document(), None, NOW + 1)
        .unwrap();
    let mut other = Vault::open(
        &dir.path().join("external.vault"),
        b"synthetic-cloud-fixture-master",
    )
    .unwrap();
    other
        .put("local-independent-phantom", b"synthetic-phantom")
        .unwrap();
    assert!(plan.commit(&mut v).is_err());
    assert!(v.get(LEDGER).unwrap().is_none());
}

#[test]
fn bounded_format_future_clock_unknown_records_and_weak_tags_fail_closed() {
    for value in [
        "W/\"weak\"",
        "*",
        "unquoted",
        "\"bad\r\nheader\"",
        "\"inner\"quote\"",
    ] {
        assert!(EntityTag::parse(value).is_err());
    }
    for value in ["\"\"", "\"strong-opaque\""] {
        assert!(EntityTag::parse(value).is_ok());
    }
    let bad = Bundle {
        records: BTreeMap::from([("local-task-v1".into(), b"synthetic".to_vec())]),
    };
    assert!(projection::validate_unit("local-task-v1", &bad).is_err());
    let duplicate = br#"{"records":{"x":[],"x":[]}}"#;
    assert!(serde_json::from_slice::<Bundle>(duplicate).is_err());
    let mut doc = Document::empty(COLLECTION).unwrap();
    doc.version = 99;
    assert!(doc.validate(NOW).is_err());
    assert!(matches!(
        Stamp::next(None, ACTOR_A, NOW + MAX_SKEW_MS + 1)
            .unwrap()
            .validate(NOW),
        Err(SyncError::Clock)
    ));
    let stamp = Stamp::next(None, ACTOR_A, NOW).unwrap();
    let next = Stamp::next(Some(&stamp), ACTOR_B, NOW - 100).unwrap();
    assert!(next > stamp);
    assert!(Document::decode(&vec![b' '; MAX_PLAIN + 1], COLLECTION, NOW).is_err());
}

#[test]
fn authenticated_wire_domain_never_exposes_plaintext_and_rejects_tampering_truncation_and_wrong_collection()
 {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "crypto.vault");
    host(&mut v, "Crypto fixture");
    let doc = Document::empty(COLLECTION)
        .unwrap()
        .capture(&v, ACTOR_A, NOW)
        .unwrap();
    let encrypted = doc
        .encrypt(b"synthetic-independent-sync-passphrase", NOW)
        .unwrap();
    assert!(
        !encrypted
            .windows(b"synthetic-cloud-only-credential".len())
            .any(|w| w == b"synthetic-cloud-only-credential")
    );
    let decoded = Document::decrypt(
        &encrypted,
        b"synthetic-independent-sync-passphrase",
        COLLECTION,
        NOW,
    )
    .unwrap();
    assert!(encoded(&doc).as_slice() == encoded(&decoded).as_slice());
    assert!(Document::decrypt(&encrypted, b"synthetic-wrong-password", COLLECTION, NOW).is_err());
    assert!(
        Document::decrypt(
            &encrypted,
            b"synthetic-independent-sync-passphrase",
            ACTOR_A,
            NOW
        )
        .is_err()
    );
    for mode in 0..4 {
        let mut bytes = encrypted.clone();
        match mode {
            0 => bytes[76] ^= 1,
            1 => bytes.truncate(bytes.len() - 1),
            2 => bytes.push(0),
            _ => bytes[..8].copy_from_slice(b"HSPBKP01"),
        }
        assert!(
            Document::decrypt(
                &bytes,
                b"synthetic-independent-sync-passphrase",
                COLLECTION,
                NOW
            )
            .is_err()
        );
    }
    // Atomic local publication stores the secret-bearing ledger encrypted too.
    let baseline = Baseline::load(&v, COLLECTION, NOW).unwrap();
    let proposal = baseline.capture_local(&v, NOW).unwrap();
    apply(&mut v, &baseline, &proposal, proposal.document());
    drop(v);
    let disk = std::fs::read(dir.path().join("crypto.vault")).unwrap();
    assert!(
        !disk
            .windows(b"synthetic-cloud-only-credential".len())
            .any(|w| w == b"synthetic-cloud-only-credential")
    );
}

#[test]
fn plaintext_local_rows_unchanged_by_failed_reference_merge_and_unknown_future_config() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "invalid.vault");
    let h = host(&mut v, "References fixture");
    let original = v.get(&h.id).unwrap().unwrap();
    let doc = Document::empty(COLLECTION)
        .unwrap()
        .capture(&v, ACTOR_A, NOW)
        .unwrap();
    let mut broken = doc.clone();
    let unit = broken
        .items
        .iter_mut()
        .find(|i| i.id == h.id)
        .unwrap()
        .value
        .as_mut()
        .unwrap();
    let mut host: HostRecord = serde_json::from_slice(&unit.records[&h.id]).unwrap();
    host.jump_host_id = Some("host-11111111111111111111111111111111".into());
    let mut old = unit
        .records
        .insert(h.id.clone(), serde_json::to_vec(&host).unwrap())
        .unwrap();
    old.zeroize();
    assert!(broken.validate(NOW).is_err());
    assert!(
        broken
            .merge(&Document::empty(COLLECTION).unwrap(), &doc, NOW)
            .is_err()
    );
    assert!(v.get(&h.id).unwrap().unwrap().as_slice() == original.as_slice());
    v.apply(&[RecordChange::Put(
        "config-unknown-future",
        b"synthetic-version",
    )])
    .unwrap();
    assert!(doc.capture(&v, ACTOR_A, NOW + 1).is_err());
}

#[test]
fn conditional_exchange_uses_frozen_local_changes_and_never_acknowledges_conflict_or_unknown_write()
{
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "exchange.vault");
    host(&mut v, "Exchange fixture");
    let baseline = Baseline::load(&v, COLLECTION, NOW).unwrap();
    let proposal = baseline.capture_local(&v, NOW).unwrap();
    let mut exchange = Exchange::new(&proposal, baseline.document());
    let ExchangeStep::Upload(pending) = exchange
        .accept_read(RemoteRead::Missing, b"synthetic-sync-key", NOW, false)
        .unwrap()
    else {
        panic!("new target requires create-only upload")
    };
    assert!(matches!(
        pending.condition(),
        PublicationCondition::CreateOnly
    ));
    let body = pending.ciphertext().to_vec();
    // A simulated 412 drops the pending write. No local ACK or ledger change.
    drop(pending);
    assert!(v.get(LEDGER).unwrap().is_none());
    let ExchangeStep::AlreadyCurrent(ack) = exchange
        .accept_read(
            RemoteRead::Present {
                etag: EntityTag::parse("\"after-re-read\"").unwrap(),
                ciphertext: body,
            },
            b"synthetic-sync-key",
            NOW + 1,
            false,
        )
        .unwrap()
    else {
        panic!("verified identical GET must not reupload")
    };
    let another_operation = baseline.capture_local(&v, NOW + 1).unwrap();
    assert!(matches!(
        baseline.prepare_acknowledged(&v, &another_operation, &ack, NOW + 1),
        Err(SyncError::Changed)
    ));
    baseline
        .prepare_acknowledged(&v, &proposal, &ack, NOW + 1)
        .unwrap()
        .commit(&mut v)
        .unwrap();
    assert!(v.get(LEDGER).unwrap().is_some());
    // The original bounded operation can perform at most three GET rounds.
    let _third = exchange
        .accept_read(RemoteRead::Missing, b"synthetic-sync-key", NOW + 2, false)
        .unwrap();
    assert!(matches!(
        exchange.accept_read(RemoteRead::Missing, b"synthetic-sync-key", NOW + 3, false),
        Err(SyncError::Changed)
    ));
}

#[test]
fn legacy_identifier_first_contact_is_distinguished_adopted_or_reported_by_ownership() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "legacy.vault");
    host(&mut v, "Legacy fixture");
    // A dataset the OLD (manual/random collection) era encrypted under a
    // different identifier with the SAME password, stored at this device's
    // endpoint.
    let legacy_collection = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    let legacy = Document::empty(legacy_collection)
        .unwrap()
        .capture(&v, ACTOR_B, NOW)
        .unwrap();
    let ciphertext = legacy
        .encrypt(b"synthetic-independent-sync-passphrase", NOW)
        .unwrap();
    assert_eq!(
        Document::header_collection(&ciphertext).as_deref(),
        Some(legacy_collection)
    );
    let read = || RemoteRead::Present {
        etag: EntityTag::parse("\"legacy-revision\"").unwrap(),
        ciphertext: ciphertext.clone(),
    };
    let proposal_exchange = |adopt: bool| {
        let baseline = Baseline::load(&v, COLLECTION, NOW).unwrap();
        let proposal = baseline.capture_local(&v, NOW).unwrap();
        (
            Exchange::new(&proposal, baseline.document()),
            b"synthetic-independent-sync-passphrase",
            adopt,
        )
    };
    // A device that never synchronized that identifier gets the dedicated
    // state instead of a misleading wrong-password Invalid...
    let (mut exchange, password, _) = proposal_exchange(false);
    assert!(matches!(
        exchange.accept_read(read(), password, NOW, false),
        Err(SyncError::LegacyCollection)
    ));
    // ...a genuinely different password still fails plainly under both
    // identifiers, adopted or not.
    for adopt in [false, true] {
        let (mut exchange, _, _) = proposal_exchange(adopt);
        assert!(matches!(
            exchange.accept_read(read(), b"synthetic-wrong-password", NOW, adopt),
            Err(SyncError::Invalid)
        ));
    }
    // The original device (post target-switch) ADOPTS the legacy dataset: the
    // merge is rebuilt under the derived identifier and the next publication
    // conditionally REPLACES the object in place, never deleting archives.
    let (mut exchange, password, _) = proposal_exchange(true);
    let ExchangeStep::Upload(pending) = exchange.accept_read(read(), password, NOW, true).unwrap()
    else {
        panic!("legacy adoption must publish under the derived identifier")
    };
    assert_eq!(pending.collection(), COLLECTION);
    assert!(matches!(
        pending.condition(),
        PublicationCondition::Match(_)
    ));
    let migrated = Document::decrypt(
        pending.ciphertext(),
        b"synthetic-independent-sync-passphrase",
        COLLECTION,
        NOW,
    )
    .unwrap();
    assert_eq!(migrated.items.len(), legacy.items.len());
}

#[path = "improvements_tests.rs"]
mod improvements;
