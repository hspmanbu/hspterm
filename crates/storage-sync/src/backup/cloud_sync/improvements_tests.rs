use super::*;
use crate::bookmarks::{Bookmark, BookmarkRepository};
use crate::ssh_proxy::{ProxyKind, ProxySettings};
fn bookmark(v: &mut Vault, host: &str, path: &str) -> Bookmark {
    BookmarkRepository::new(v)
        .save(Bookmark {
            id: String::new(),
            name: path.into(),
            path: path.into(),
            host_id: Some(host.into()),
        })
        .unwrap()
}
#[test]
fn independent_same_endpoint_adopts_cloud_settings_preserves_local_id_and_all_bookmarks() {
    let now = journal::now_millis().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let mut a = vault(dir.path(), "identity-a.vault");
    let mut b = vault(dir.path(), "identity-b.vault");
    let cloud = host(&mut a, "Cloud title");
    let local = host(&mut b, "Old local title");
    bookmark(&mut a, &cloud.id, "/cloud");
    bookmark(&mut b, &local.id, "/local");
    for (vault, path) in [(&mut a, "/global-cloud"), (&mut b, "/global-local")] {
        BookmarkRepository::new(vault)
            .save(Bookmark {
                id: String::new(),
                name: path.into(),
                path: path.into(),
                host_id: None,
            })
            .unwrap();
    }
    journal::enable(&mut b).unwrap();
    let ba = Baseline::load(&a, COLLECTION, now).unwrap();
    let bb = Baseline::load(&b, COLLECTION, now).unwrap();
    let pa = ba.capture_local(&a, now).unwrap();
    let pb = bb.capture_local(&b, now + 1).unwrap();
    let mut exchange = Exchange::new(&pb, bb.document());
    let step = exchange
        .accept_read(
            RemoteRead::Present {
                etag: EntityTag::parse("\"source\"").unwrap(),
                ciphertext: pa.document().encrypt(b"synthetic-sync", now).unwrap(),
            },
            b"synthetic-sync",
            now + 2,
            false,
        )
        .unwrap();
    assert!(step.summary().diverged.is_empty());
    let ExchangeStep::Upload(upload) = step else {
        panic!("new local bookmark must publish");
    };
    let ack = upload.acknowledge(EntityTag::parse("\"merged\"").unwrap());
    bb.prepare_acknowledged(&b, &pb, &ack, now + 3)
        .unwrap()
        .commit(&mut b)
        .unwrap();
    let hosts = Repository::new(&mut b).list().unwrap();
    assert_eq!(hosts.len(), 1);
    assert_eq!(
        hosts[0].id, local.id,
        "active local session identity must stay stable"
    );
    assert_eq!(hosts[0].name, "Cloud title");
    let bookmarks = BookmarkRepository::new(&mut b).list(&local.id).unwrap();
    assert_eq!(bookmarks.len(), 4);
    assert_eq!(bookmarks.iter().filter(|b| b.host_id.is_none()).count(), 2);
    assert!(
        bookmarks
            .iter()
            .all(|b| b.host_id.is_none() || b.host_id.as_ref() == Some(&local.id))
    );
    let baseline = Baseline::load(&b, COLLECTION, now + 4).unwrap();
    let proposal = baseline.capture_local(&b, now + 5).unwrap();
    assert!(
        encoded(proposal.document()).as_slice() == encoded(baseline.document()).as_slice(),
        "local aliases must not cause a perpetual resync"
    );
    let mut renamed = Repository::new(&mut b).host(&local.id).unwrap().unwrap();
    renamed.note = "later local edit".into();
    Repository::new(&mut b).save(renamed, None).unwrap();
    assert!(
        baseline.capture_local(&b, now + 6).is_ok(),
        "mutation journal must use canonical cloud IDs"
    );
}

#[test]
fn partially_overlapping_hosts_match_equivalent_proxy_addresses_but_keep_distinct_routes() {
    let dir = tempfile::tempdir().unwrap();
    let mut a = vault(dir.path(), "proxy-cloud.vault");
    let mut b = vault(dir.path(), "proxy-local.vault");
    let proxy = |address: &str, port| ProxySettings {
        kind: ProxyKind::Socks5,
        address: address.into(),
        port,
        authenticate: false,
    };
    let mut cloud = host(&mut a, "Cloud shared");
    cloud.proxy = Some(proxy("[2001:db8::42]", 1080));
    Repository::new(&mut a).save(cloud.clone(), None).unwrap();
    let mut cloud_only = host(&mut a, "Cloud only");
    cloud_only.address = "other-sync-fixture.invalid".into();
    Repository::new(&mut a).save(cloud_only, None).unwrap();

    let mut local = host(&mut b, "Local shared");
    let empty = Document::empty(COLLECTION).unwrap();
    let remote = empty.capture(&a, ACTOR_A, NOW).unwrap();
    for (port, same_route) in [(1080, true), (1081, false)] {
        local.proxy = Some(proxy("2001:0DB8:0:0:0:0:0:0042", port));
        Repository::new(&mut b).save(local.clone(), None).unwrap();
        let mut proposal = empty.capture(&b, ACTOR_B, NOW + 1).unwrap();
        proposal
            .align_hosts(&mut empty.clone(), &mut remote.clone())
            .unwrap();
        let local_ids: Vec<_> = proposal
            .items
            .iter()
            .filter(|i| crate::repository::valid_id(&i.id, "host"))
            .map(|i| &i.id)
            .collect();
        assert_eq!(local_ids, [if same_route { &cloud.id } else { &local.id }]);
    }
}

#[test]
fn bookmark_three_way_merge_keeps_independent_additions_and_propagates_removals() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "bookmarks.vault");
    let h = host(&mut v, "Bookmarks");
    let original = bookmark(&mut v, &h.id, "/old");
    let base = Document::empty(COLLECTION)
        .unwrap()
        .capture(&v, ACTOR_A, NOW)
        .unwrap();
    let original_raw = v.get("sftp-bookmarks-v1").unwrap().unwrap();
    BookmarkRepository::new(&mut v)
        .remove(&original.id)
        .unwrap();
    bookmark(&mut v, &h.id, "/left");
    let left = base.capture(&v, ACTOR_A, NOW + 1).unwrap();
    v.put("sftp-bookmarks-v1", &original_raw).unwrap();
    bookmark(&mut v, &h.id, "/right");
    let right = base.capture(&v, ACTOR_B, NOW + 2).unwrap();
    let (merged, summary) = left.merge(&base, &right, NOW + 3).unwrap();
    assert!(summary.diverged.is_empty());
    let item = merged
        .items
        .iter()
        .find(|i| i.id == "sftp-bookmarks-v1")
        .unwrap();
    let raw = &item.value.as_ref().unwrap().records["sftp-bookmarks-v1"];
    let data: serde_json::Value = serde_json::from_slice(raw).unwrap();
    let paths = data["items"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| b["path"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(paths.len(), 2);
    assert!(paths.contains(&"/left") && paths.contains(&"/right"));
    assert!(!paths.contains(&"/old"));
}
#[test]
fn cloud_retains_exactly_three_prior_revisions_and_restoration_snapshots_the_head() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = vault(dir.path(), "snapshots.vault");
    let h = host(&mut v, "Snapshot fixture");
    let mut doc = Document::empty(COLLECTION)
        .unwrap()
        .capture(&v, ACTOR_A, NOW)
        .unwrap();
    for revision in 1..=5 {
        let mut host = Repository::new(&mut v).host(&h.id).unwrap().unwrap();
        host.note = format!("revision {revision}");
        Repository::new(&mut v).save(host, None).unwrap();
        let mut next = doc.capture(&v, ACTOR_A, NOW + revision).unwrap();
        next.retain_previous(&doc, NOW + revision).unwrap();
        doc = next;
    }
    assert_eq!(doc.snapshots().len(), 3);
    let snapshot = doc.snapshots()[0].id.clone();
    let b = Baseline::load(&v, COLLECTION, NOW + 10).unwrap();
    let p = b.capture_local(&v, NOW + 10).unwrap();
    let mut e = Exchange::new(&p, b.document());
    e.accept_read(
        RemoteRead::Present {
            etag: EntityTag::parse("\"head\"").unwrap(),
            ciphertext: doc.encrypt(b"synthetic-history", NOW + 10).unwrap(),
        },
        b"synthetic-history",
        NOW + 10,
        false,
    )
    .unwrap();
    let ExchangeStep::Upload(upload) = e
        .restore_snapshot(&snapshot, b"synthetic-history", NOW + 11)
        .unwrap()
    else {
        panic!("rollback requires a new conditional upload");
    };
    let restored = Document::decrypt(
        upload.ciphertext(),
        b"synthetic-history",
        COLLECTION,
        NOW + 11,
    )
    .unwrap();
    assert_eq!(restored.snapshots().len(), 3);
    let row = restored.items.iter().find(|i| i.id == h.id).unwrap();
    let host: HostRecord =
        serde_json::from_slice(&row.value.as_ref().unwrap().records[&h.id]).unwrap();
    assert_eq!(host.note, "revision 4");
    assert_ne!(
        restored.snapshots()[0].id,
        snapshot,
        "previous current version must be recoverable too"
    );
    let mut tampered: serde_json::Value = serde_json::from_slice(&encoded(&doc)).unwrap();
    tampered["snapshots"][0]["id"] = serde_json::Value::String("0".repeat(64));
    assert!(
        Document::decode(
            &serde_json::to_vec(&tampered).unwrap(),
            COLLECTION,
            NOW + 11
        )
        .is_err()
    );
}
