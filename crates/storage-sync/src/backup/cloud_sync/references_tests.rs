use super::*;
use crate::{AuthMethod, Credential, HostRecord, Repository};
const COLLECTION: &str = "0123456789abcdef0123456789abcdef";
const OTHER: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const NOW: u64 = 1_800_000_000_000;
fn host(v: &mut Vault, name: &str) -> HostRecord {
    Repository::new(v)
        .save(
            HostRecord::new(
                name.into(),
                "fixture.invalid".into(),
                "fixture".into(),
                AuthMethod::Password,
            ),
            Some(Credential {
                secret: "synthetic-host-credential".into(),
                passphrase: None,
            }),
        )
        .unwrap()
}
fn broken(v: &mut Vault) -> (Exchange, LocalProposal, Document, String, String) {
    let a = host(v, "A");
    let mut b = host(v, "B");
    // The shared three-way baseline: both hosts without jump edits, applied
    // to the local ledger so the merge has a real common ancestor.
    let seeded = Baseline::load(v, COLLECTION, NOW).unwrap();
    let initial = seeded.capture_local(v, NOW).unwrap();
    seeded
        .prepare_apply(v, &initial, initial.document(), None, NOW)
        .unwrap()
        .commit(v)
        .unwrap();
    let mut remote = initial.document().clone();
    let item = remote.items.iter_mut().find(|i| i.id == a.id).unwrap();
    let bundle = item.value.as_mut().unwrap();
    let mut wire: HostRecord = serde_json::from_slice(&bundle.records[&a.id]).unwrap();
    wire.jump_host_id = Some(b.id.clone());
    bundle
        .records
        .insert(a.id.clone(), serde_json::to_vec(&wire).unwrap());
    item.stamp = Stamp::next(Some(&item.stamp), OTHER, NOW + 3).unwrap();
    remote.validate(NOW + 10).unwrap();
    b.jump_host_id = Some(a.id.clone());
    v.put(&b.id, &serde_json::to_vec(&b).unwrap()).unwrap();
    let baseline = Baseline::load(v, COLLECTION, NOW + 2).unwrap();
    let proposal = baseline.capture_local(v, NOW + 2).unwrap();
    let exchange = Exchange::new(&proposal, baseline.document());
    (exchange, proposal, remote, a.id, b.id)
}
fn read(remote: &Document, etag: &str) -> RemoteRead {
    RemoteRead::Present {
        etag: EntityTag::parse(etag).unwrap(),
        ciphertext: remote.encrypt(b"synthetic-e2e", NOW + 10).unwrap(),
    }
}
#[test]
fn independently_valid_jump_edits_get_metadata_only_repair_and_full_validation_before_upload() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("refs.vault"), b"synthetic-master").unwrap();
    let (mut exchange, proposal, remote, a, b) = broken(&mut v);
    let base = Baseline::load(&v, COLLECTION, NOW + 2).unwrap();
    assert!(matches!(
        proposal.document.merge(base.document(), &remote, NOW + 10),
        Err(SyncError::References)
    ));
    let step = exchange
        .accept_read(read(&remote, "\"original\""), b"synthetic-e2e", NOW + 10)
        .unwrap();
    assert!(!step.uploads());
    let choices = exchange.reference_choices(&step).unwrap();
    assert_eq!(choices.len(), 2);
    let metadata = serde_json::to_string(&choices).unwrap();
    assert!(!metadata.contains("synthetic-host-credential"));
    assert!(
        choices
            .iter()
            .any(|c| c.id == a && c.remote_jump.as_deref() == Some(b.as_str()))
    );
    let ExchangeStep::References(pending) = step else {
        panic!("expected explicit repair");
    };
    let before = exchange.local.encode(NOW + 10).unwrap();
    assert!(matches!(
        exchange.resolve_references(
            &pending,
            &[ReferenceSelection {
                id: a.clone(),
                side: ReferenceSide::Remote
            }],
            b"synthetic-e2e",
            NOW + 10
        ),
        Err(SyncError::References)
    ));
    assert_eq!(*exchange.local.encode(NOW + 10).unwrap(), *before);
    let repaired = exchange
        .resolve_references(
            &pending,
            &[ReferenceSelection {
                id: b,
                side: ReferenceSide::Remote,
            }],
            b"synthetic-e2e",
            NOW + 10,
        )
        .unwrap();
    let ExchangeStep::Upload(upload) = repaired else {
        panic!("a valid explicit repair needs review/publication");
    };
    assert!(
        matches!(upload.condition(), PublicationCondition::Match(tag) if tag.header_value() == "\"original\"")
    );
    assert_eq!(upload.summary().credential_changes, 2);
    Document::decrypt(upload.ciphertext(), b"synthetic-e2e", COLLECTION, NOW + 10)
        .unwrap()
        .validate(NOW + 10)
        .unwrap();
    Baseline::load(&v, COLLECTION, NOW + 10)
        .unwrap()
        .ensure_current(&v, &proposal, NOW + 10)
        .unwrap();
}
#[test]
fn unavailable_duplicate_unknown_or_history_choices_cannot_mutate_proposal() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("reject.vault"), b"synthetic-master").unwrap();
    let (mut exchange, _, mut remote, a, _) = broken(&mut v);
    let extra_id = format!("group-{}", "c".repeat(32));
    remote.items.push(Item {
        id: extra_id.clone(),
        stamp: Stamp::next(None, OTHER, NOW).unwrap(),
        value: Some(Bundle {
            records: BTreeMap::from([(
                "__group".into(),
                serde_json::to_vec(&crate::HostGroup {
                    id: extra_id.clone(),
                    name: "Only remote".into(),
                })
                .unwrap(),
            )]),
        }),
    });
    remote.items.sort_by(|a, b| a.id.cmp(&b.id));
    remote.validate(NOW + 10).unwrap();
    let ExchangeStep::References(pending) = exchange
        .accept_read(read(&remote, "\"original\""), b"synthetic-e2e", NOW + 10)
        .unwrap()
    else {
        panic!("expected repair");
    };
    let before = exchange.local.encode(NOW + 10).unwrap();
    for choices in [
        vec![ReferenceSelection {
            id: extra_id,
            side: ReferenceSide::Local,
        }],
        vec![ReferenceSelection {
            id: "unknown-unit".into(),
            side: ReferenceSide::Local,
        }],
        vec![ReferenceSelection {
            id: super::super::super::HISTORY.into(),
            side: ReferenceSide::Remote,
        }],
        vec![
            ReferenceSelection {
                id: a.clone(),
                side: ReferenceSide::Local,
            },
            ReferenceSelection {
                id: a.clone(),
                side: ReferenceSide::Remote,
            },
        ],
    ] {
        assert!(
            exchange
                .resolve_references(&pending, &choices, b"synthetic-e2e", NOW + 10)
                .is_err()
        );
        assert_eq!(*exchange.local.encode(NOW + 10).unwrap(), *before);
    }
}
#[test]
fn a_412_reread_keeps_original_local_security_summary_and_requires_new_conditional_publication() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("retry.vault"), b"synthetic-master").unwrap();
    let (mut exchange, _, remote, _, b) = broken(&mut v);
    let ExchangeStep::References(pending) = exchange
        .accept_read(read(&remote, "\"etag-1\""), b"synthetic-e2e", NOW + 10)
        .unwrap()
    else {
        panic!("expected repair");
    };
    let first = exchange
        .resolve_references(
            &pending,
            &[ReferenceSelection {
                id: b,
                side: ReferenceSide::Remote,
            }],
            b"synthetic-e2e",
            NOW + 10,
        )
        .unwrap();
    let retry = exchange
        .accept_read(read(&remote, "\"etag-2\""), b"synthetic-e2e", NOW + 11)
        .unwrap();
    assert_eq!(first.summary().credential_changes, 2);
    assert_eq!(retry.summary().credential_changes, 2);
    let ExchangeStep::Upload(upload) = retry else {
        panic!("must still publish repaired proposal");
    };
    assert!(
        matches!(upload.condition(), PublicationCondition::Match(tag) if tag.header_value() == "\"etag-2\"")
    );
}
