use super::*;
use crate::{AuthMethod, HostRecord, Repository};
fn vault(root: &std::path::Path) -> Vault {
    Vault::create(&root.join("target.vault"), b"synthetic-target-master").unwrap()
}

#[test]
fn changing_servers_or_proxy_endpoints_never_reuses_the_previous_endpoint_authentication_implicitly()
 {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let source = configure(&mut v);
    let mut t = target();
    t.authenticate = true;
    t.proxy = Some(ProxyTarget {
        address: "http://127.0.0.1:49001".into(),
        authenticate: true,
    });
    let mut p = proposal(&source, t.clone());
    p.secrets.webdav = CredentialChange::Replace {
        username: "fixture".into(),
        password: "synthetic-auth-a".into(),
    };
    p.secrets.proxy = CredentialChange::Replace {
        username: "fixture-proxy".into(),
        password: "synthetic-proxy-a".into(),
    };
    let source = save(&mut v, p).unwrap();
    let before = v.get(SECRET).unwrap().unwrap();
    let mut new_server = t.clone();
    new_server.endpoint = "https://another-fixture.invalid/object".into();
    let mut p = proposal(&source, new_server);
    p.confirm_target_change = true;
    assert!(matches!(save(&mut v, p), Err(SyncError::CredentialTarget)));
    t.proxy.as_mut().unwrap().address = "http://127.0.0.1:49002".into();
    assert!(matches!(
        save(&mut v, proposal(&source, t)),
        Err(SyncError::CredentialTarget)
    ));
    assert!(v.get(SECRET).unwrap().unwrap().as_slice() == before.as_slice());
}
fn target() -> Target {
    Target {
        enabled: true,
        endpoint: "https://sync-target-fixture.invalid/private.hspconfig".into(),
        collection: "0123456789abcdef0123456789abcdef".into(),
        authenticate: false,
        timeout_seconds: 60,
        proxy: None,
        drive: None,
    }
}
fn proposal(view: &View, target: Target) -> Proposal {
    Proposal {
        vault_scope: view.vault_scope.clone(),
        revision: view.revision.clone(),
        target,
        derive_collection: None,
        secrets: SecretChanges {
            sync_password: None,
            webdav: CredentialChange::Keep,
            proxy: CredentialChange::Keep,
        },
        confirm_target_change: false,
    }
}
fn configure(v: &mut Vault) -> View {
    let view = load(v).unwrap();
    let mut p = proposal(&view, target());
    p.secrets.sync_password = Some("synthetic-target-sync-password".into());
    save(v, p).unwrap()
}
fn drive_account(v: &mut Vault) {
    v.put(crate::google_drive_account::RECORD, br#"{"version":1,"authorization_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","client_id":"synthetic-client.apps.googleusercontent.com","client_secret":"synthetic-client-secret","refresh_token":"synthetic-refresh-token"}"#).unwrap();
}
fn drive_target() -> Target {
    Target {
        endpoint: drive_files::DriveFiles::object_endpoint("synthetic-file-id").unwrap(),
        drive: Some(DriveTarget {
            file_id: "synthetic-file-id".into(),
            client_id: "synthetic-client.apps.googleusercontent.com".into(),
            authorization_id: "a".repeat(32),
        }),
        ..target()
    }
}
#[test]
fn drive_target_requires_current_local_authorization_and_strict_fixed_endpoint() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let source = load(&v).unwrap();
    let mut p = proposal(&source, drive_target());
    p.secrets.sync_password = Some("synthetic-sync-password".into());
    assert!(matches!(save(&mut v, p), Err(SyncError::Authorization)));
    drive_account(&mut v);
    let source = load(&v).unwrap();
    let mut p = proposal(&source, drive_target());
    p.secrets.sync_password = Some("synthetic-sync-password".into());
    let saved = save(&mut v, p).unwrap();
    assert!(eligible(&v).unwrap());
    let mut bad = drive_target();
    bad.endpoint = "https://attacker.invalid/object".into();
    assert!(save(&mut v, proposal(&saved, bad)).is_err());
    let mut bad = drive_target();
    bad.authenticate = true;
    assert!(save(&mut v, proposal(&saved, bad)).is_err());
    v.delete(crate::google_drive_account::RECORD).unwrap();
    assert!(!eligible(&v).unwrap());
    assert!(matches!(
        capture(&v, &saved.vault_scope, &saved.revision),
        Err(SyncError::Authorization)
    ));
    let mut disabled = drive_target();
    disabled.enabled = false;
    save(&mut v, proposal(&saved, disabled)).unwrap();
    assert!(!eligible(&v).unwrap());
}
#[test]
fn drive_account_is_part_of_proposal_cas_and_is_preserved_by_successful_cloud_apply() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    drive_account(&mut v);
    let source = load(&v).unwrap();
    let mut p = proposal(&source, drive_target());
    p.secrets.sync_password = Some("synthetic-sync-password".into());
    let saved = save(&mut v, p).unwrap();
    let now = journal::now_millis().unwrap();
    let baseline = Baseline::load(&v, &drive_target().collection, now).unwrap();
    let proposed = baseline.capture_local(&v, now).unwrap();
    let target = capture(&v, &saved.vault_scope, &saved.revision).unwrap();
    target.ensure_proposal(&proposed).unwrap();
    let account = v.get(crate::google_drive_account::RECORD).unwrap().unwrap();
    let plan = baseline
        .prepare_apply(
            &v,
            &proposed,
            proposed.document(),
            Some(EntityTag::parse("\"synthetic-drive-revision\"").unwrap()),
            now,
        )
        .unwrap();
    plan.commit(&mut v).unwrap();
    assert!(
        v.get(crate::google_drive_account::RECORD)
            .unwrap()
            .unwrap()
            .as_slice()
            == account.as_slice()
    );
    let current = Baseline::load(&v, &drive_target().collection, now).unwrap();
    let stale = current.capture_local(&v, now).unwrap();
    v.delete(crate::google_drive_account::RECORD).unwrap();
    assert!(current.ensure_current(&v, &stale, now).is_err());
    assert!(
        current
            .prepare_apply(&v, &stale, stale.document(), None, now)
            .is_err()
    );
}
#[test]
fn webdav_never_reads_or_overwrites_unrelated_corrupt_drive_authorization() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    v.put(crate::google_drive_account::RECORD, b"synthetic-not-json")
        .unwrap();
    let saved = configure(&mut v);
    assert!(eligible(&v).unwrap());
    let checkpoint = checkpoint(&v).unwrap();
    assert!(checkpoint.drive_account.is_none());
    capture(&v, &saved.vault_scope, &saved.revision).unwrap();
    assert!(
        v.get(crate::google_drive_account::RECORD)
            .unwrap()
            .unwrap()
            .as_slice()
            == b"synthetic-not-json"
    );
}
#[test]
fn http_capability_cannot_pair_old_route_or_auth_with_a_new_local_proposal() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let original = configure(&mut v);
    let captured = capture(&v, &original.vault_scope, &original.revision).unwrap();
    let baseline =
        Baseline::load(&v, &target().collection, journal::now_millis().unwrap()).unwrap();
    let proposal_before = baseline
        .capture_local(&v, journal::now_millis().unwrap())
        .unwrap();
    captured.ensure_proposal(&proposal_before).unwrap();
    let mut updated = target();
    updated.timeout_seconds = 90;
    // Same collection and object, no ledger rotation: the race must still fail.
    let changed = save(&mut v, proposal(&original, updated)).unwrap();
    assert!(captured.ensure_current(&v).is_err());
    let proposal_after = baseline
        .capture_local(&v, journal::now_millis().unwrap())
        .unwrap();
    assert!(captured.ensure_proposal(&proposal_after).is_err());
    let current = capture(&v, &changed.vault_scope, &changed.revision).unwrap();
    current.ensure_proposal(&proposal_after).unwrap();
    current.ensure_current(&v).unwrap();
}
fn acknowledge(v: &mut Vault) {
    let view = load(v).unwrap();
    let target = view.target.unwrap();
    let now = journal::now_millis().unwrap();
    let baseline = Baseline::load(v, &target.collection, now).unwrap();
    let proposal = baseline.capture_local(v, now).unwrap();
    baseline
        .prepare_apply(v, &proposal, proposal.document(), None, now)
        .unwrap()
        .commit(v)
        .unwrap();
}
#[test]
fn target_and_separate_secrets_persist_encrypted_but_never_enter_views_or_backup() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    assert!(load(&v).unwrap().target.is_none());
    assert!(v.get(journal::RECORD).unwrap().is_none());
    let saved = configure(&mut v);
    assert!(saved.sync_password_set);
    assert!(!saved.webdav_credential_set);
    let json = serde_json::to_string(&saved).unwrap();
    assert!(!json.contains("synthetic-target-sync-password"));
    let active = capture(&v, &saved.vault_scope, &saved.revision).unwrap();
    assert_eq!(active.password(), b"synthetic-target-sync-password");
    let snapshot = Snapshot::capture(&v).unwrap();
    assert!(!snapshot.records.contains_key(CONFIG));
    assert!(!snapshot.records.contains_key(SECRET));
    assert!(!snapshot.records.contains_key(journal::RECORD));
    drop(active);
    drop(v);
    let disk = std::fs::read(root.path().join("target.vault")).unwrap();
    assert!(
        !disk
            .windows(b"synthetic-target-sync-password".len())
            .any(|w| w == b"synthetic-target-sync-password")
    );
    let reopened = Vault::open(
        &root.path().join("target.vault"),
        b"synthetic-target-master",
    )
    .unwrap();
    let view = load(&reopened).unwrap();
    assert!(view.sync_password_set);
    assert_ne!(view.vault_scope, saved.vault_scope);
}
#[test]
fn failed_setup_rolls_back_target_secret_and_initial_tracking_without_an_ack() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    v.db.execute_batch(&format!("CREATE TRIGGER fail_target BEFORE INSERT ON records WHEN NEW.id='{SECRET}' BEGIN SELECT RAISE(ABORT,'synthetic target failure'); END;")).unwrap();
    let view = load(&v).unwrap();
    let mut p = proposal(&view, target());
    p.secrets.sync_password = Some("synthetic-target-sync-password".into());
    assert!(save(&mut v, p).is_err());
    for id in [CONFIG, SECRET, journal::RECORD] {
        assert!(v.get(id).unwrap().is_none());
    }
}
#[test]
fn keep_replace_disable_and_proxy_credentials_are_explicit_and_the_old_form_never_redirects() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let saved = configure(&mut v);
    let mut t = target();
    t.authenticate = true;
    t.proxy = Some(ProxyTarget {
        address: "socks5h://127.0.0.1:49001".into(),
        authenticate: true,
    });
    let mut p = proposal(&saved, t.clone());
    p.secrets.webdav = CredentialChange::Replace {
        username: "synthetic-webdav-user".into(),
        password: "synthetic-webdav-secret".into(),
    };
    p.secrets.proxy = CredentialChange::Replace {
        username: "synthetic-proxy-user".into(),
        password: "synthetic-proxy-secret".into(),
    };
    let saved = save(&mut v, p).unwrap();
    assert!(saved.webdav_credential_set && saved.proxy_credential_set);
    assert!(save(&mut v, proposal(&saved, t.clone())).is_ok());
    assert!(capture(&v, "wrong-vault", &saved.revision).is_err());
    let original = v.get(SECRET).unwrap().unwrap();
    let mut stale = proposal(&saved, t.clone());
    stale.revision = "00".repeat(32);
    assert!(matches!(save(&mut v, stale), Err(SyncError::Changed)));
    assert!(v.get(SECRET).unwrap().unwrap().as_slice() == original.as_slice());
    t.authenticate = false;
    t.proxy = None;
    t.enabled = false;
    let current = load(&v).unwrap();
    let disabled = save(&mut v, proposal(&current, t)).unwrap();
    assert!(!disabled.webdav_credential_set && !disabled.proxy_credential_set);
    assert!(disabled.sync_password_set);
    assert!(capture(&v, &disabled.vault_scope, &disabled.revision).is_err());
}
#[test]
fn target_switch_requires_consent_archives_the_original_ledger_and_recovers_each_collection() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    configure(&mut v);
    acknowledge(&mut v);
    let alpha = load(&v).unwrap();
    let original = v.get(LEDGER).unwrap().unwrap();
    let mut beta = target();
    beta.collection = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".into();
    assert!(matches!(
        save(&mut v, proposal(&alpha, beta.clone())),
        Err(SyncError::TargetChange)
    ));
    assert!(v.get(LEDGER).unwrap().unwrap().as_slice() == original.as_slice());
    let mut p = proposal(&alpha, beta);
    p.confirm_target_change = true;
    save(&mut v, p).unwrap();
    assert!(v.get(LEDGER).unwrap().is_none());
    assert!(
        v.get(&archive(alpha.target.as_ref().unwrap()))
            .unwrap()
            .unwrap()
            .as_slice()
            == original.as_slice()
    );
    acknowledge(&mut v);
    let beta = load(&v).unwrap();
    let mut p = proposal(&beta, target());
    p.confirm_target_change = true;
    save(&mut v, p).unwrap();
    assert!(v.get(LEDGER).unwrap().unwrap().as_slice() == original.as_slice());
    let now = journal::now_millis().unwrap();
    let baseline = Baseline::load(&v, &target().collection, now).unwrap();
    assert!(baseline.capture_local(&v, now).is_ok());
}
#[test]
fn future_format_or_different_master_scope_never_falls_back_to_writable_defaults() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let saved = configure(&mut v);
    let reopened = Vault::open(
        &root.path().join("target.vault"),
        b"synthetic-target-master",
    )
    .unwrap();
    assert!(capture(&reopened, &saved.vault_scope, &saved.revision).is_err());
    drop(reopened);
    v.put(CONFIG, br#"{"version":99}"#).unwrap();
    assert!(load(&v).is_err());
    assert!(save(&mut v, proposal(&saved, target())).is_err());
}
#[test]
fn validation_and_post_sync_key_changes_do_not_destroy_an_existing_collection() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    configure(&mut v);
    acknowledge(&mut v);
    let saved = load(&v).unwrap();
    let original = v.get(SECRET).unwrap().unwrap();
    let mut p = proposal(&saved, target());
    p.secrets.sync_password = Some("synthetic-incorrect-rekey-attempt".into());
    assert!(matches!(save(&mut v, p), Err(SyncError::KeyChange)));
    assert!(v.get(SECRET).unwrap().unwrap().as_slice() == original.as_slice());
    for endpoint in [
        "ftp://127.0.0.1/object",
        "https://user:secret@fixture.invalid/object",
        "https://fixture.invalid/object?secret=value",
    ] {
        let mut t = target();
        t.endpoint = endpoint.into();
        assert!(save(&mut v, proposal(&saved, t)).is_err());
    }
    let mut t = target();
    t.proxy = Some(ProxyTarget {
        address: "socks5h://127.0.0.1:49001".into(),
        authenticate: true,
    });
    let mut p = proposal(&saved, t);
    p.secrets.proxy = CredentialChange::Replace {
        username: "x".repeat(256),
        password: "synthetic".into(),
    };
    assert!(save(&mut v, p).is_err());
}
#[test]
fn accepted_host_changes_after_disabling_sync_are_still_tracked_without_network_activity() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let saved = configure(&mut v);
    let mut t = target();
    t.enabled = false;
    save(&mut v, proposal(&saved, t)).unwrap();
    let host = Repository::new(&mut v)
        .save(
            HostRecord::new(
                "Saved while sync disabled".into(),
                "fixture.invalid".into(),
                "fixture".into(),
                AuthMethod::Password,
            ),
            Some(crate::Credential {
                secret: "synthetic-host-only".into(),
                passphrase: None,
            }),
        )
        .unwrap();
    let now = journal::now_millis().unwrap();
    assert!(
        journal::load(&v, now)
            .unwrap()
            .1
            .unwrap()
            .stamp(&host.id)
            .is_ok()
    );
}

#[test]
fn target_disable_and_auth_changes_retire_captured_cloud_results_even_without_a_configuration_edit()
{
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let saved = configure(&mut v);
    let now = journal::now_millis().unwrap();
    let baseline = Baseline::load(&v, &target().collection, now).unwrap();
    let captured = baseline.capture_local(&v, now).unwrap();
    let mut disabled = target();
    disabled.enabled = false;
    save(&mut v, proposal(&saved, disabled)).unwrap();
    assert!(matches!(
        baseline.prepare_apply(&v, &captured, captured.document(), None, now),
        Err(SyncError::Changed)
    ));
}

#[test]
fn webdav_http_targets_remain_valid_without_relaxing_drive_endpoint_binding() {
    let mut webdav = target();
    webdav.endpoint = "http://dav.internal/config.enc".into();
    assert!(webdav.checked().is_ok());
    let mut drive = drive_target();
    drive.endpoint = drive.endpoint.replacen("https://", "http://", 1);
    assert!(drive.checked().is_err());
}

#[test]
fn derived_collections_are_deterministic_password_bound_and_replace_explicit_ids() {
    let root = tempfile::tempdir().unwrap();
    let mut v = vault(root.path());
    let first = derived_collection("https://dav.invalid/dav/", b"synthetic-first").unwrap();
    let normalized = derived_collection("https://dav.invalid/dav", b"synthetic-first").unwrap();
    assert_eq!(first, normalized);
    assert!(opaque(&first));
    assert_ne!(
        first,
        derived_collection("https://dav.invalid/dav/", b"synthetic-second").unwrap()
    );
    assert_ne!(
        first,
        derived_collection("https://other.invalid/", b"synthetic-first").unwrap()
    );
    for bad in [
        "ftp://dav.invalid",
        "https://user:pass@dav.invalid",
        "not a url",
    ] {
        assert!(derived_collection(bad, b"synthetic-first").is_err());
    }
    // A derived proposal must carry the endpoint derived from the same root;
    // the stored collection becomes the derived dataset id. A mismatched
    // endpoint/root pair is rejected without touching stored state.
    let source = load(&v).unwrap();
    let mut derived_target = target();
    derived_target.endpoint = webdav::derive_object("https://dav.invalid/dav/").unwrap();
    let mut p = proposal(&source, derived_target);
    p.derive_collection = Some("https://dav.invalid/dav/".into());
    p.secrets.sync_password = Some("synthetic-derived-password".into());
    p.confirm_target_change = true;
    let saved = save(&mut v, p).unwrap();
    assert_eq!(
        saved.target.as_ref().unwrap().collection,
        derived_collection("https://dav.invalid/dav/", b"synthetic-derived-password").unwrap()
    );
    let fresh = load(&v).unwrap();
    let mut mismatch = target();
    mismatch.endpoint = webdav::derive_object("https://dav.invalid/dav/").unwrap();
    mismatch.collection = saved.target.as_ref().unwrap().collection.clone();
    let mut p = proposal(&fresh, mismatch);
    p.derive_collection = Some("https://different.invalid/root".into());
    p.secrets.sync_password = None;
    assert!(matches!(save(&mut v, p), Err(SyncError::Invalid)));
}
