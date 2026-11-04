use super::*;
use crate::ssh_proxy::{ProxyKind, ProxySettings};

fn host(name: &str) -> HostRecord {
    HostRecord::new(
        name.into(),
        "127.0.0.1".into(),
        "fixture".into(),
        AuthMethod::Password,
    )
}
fn secret() -> Credential {
    Credential {
        secret: "synthetic-jump-secret".into(),
        passphrase: None,
    }
}
fn proxy() -> ProxySettings {
    ProxySettings {
        kind: ProxyKind::Socks5,
        address: "proxy.invalid".into(),
        port: 1080,
        authenticate: false,
    }
}

#[test]
fn jump_reference_survives_encrypted_drafts_copy_and_reopen_without_copying_jump_credentials() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("vault");
    let mut v = Vault::create(&path, b"synthetic-master").unwrap();
    let (jump_id, target_id, copy_id);
    {
        let mut r = Repository::new(&mut v);
        let jump = r.save(host("jump"), Some(secret())).unwrap();
        jump_id = jump.id;
        let mut target = host("target");
        target.jump_host_id = Some(jump_id.clone());
        r.save_draft(&HostDraft {
            host: target.clone(),
            credential: Some(secret()),
            proxy_credential: None,
        })
        .unwrap();
        assert_eq!(
            r.drafts().unwrap()[0].host.jump_host_id.as_ref(),
            Some(&jump_id)
        );
        target = r.save(target, None).unwrap();
        target_id = target.id;
        let draft = r.copy_to_draft(&target_id).unwrap();
        assert_eq!(draft.jump_host_id.as_ref(), Some(&jump_id));
        let copy = r.save(draft, None).unwrap();
        copy_id = copy.id;
        assert_ne!(
            copy.credential_id,
            r.host(&target_id).unwrap().unwrap().credential_id
        );
    }
    drop(v);
    let bytes = std::fs::read(&path).unwrap();
    // Opaque record IDs are intentionally SQLite primary keys; the route
    // association and authentication payload must be encrypted.
    let association = format!("\"jump_host_id\":\"{jump_id}\"");
    for value in [association.as_bytes(), b"synthetic-jump-secret"] {
        assert!(!bytes.windows(value.len()).any(|w| w == value));
    }
    let mut v = Vault::open(&path, b"synthetic-master").unwrap();
    let mut r = Repository::new(&mut v);
    for id in [&target_id, &copy_id] {
        let target = r.host(id).unwrap().unwrap();
        assert_eq!(target.jump_host_id.as_ref(), Some(&jump_id));
        assert_eq!(r.jump_host(&target).unwrap().unwrap().id, jump_id);
    }
    // Deletion does not silently reroute dependent hosts directly. The reference
    // remains visible, and a future connection must refuse the missing route.
    r.delete(std::slice::from_ref(&jump_id)).unwrap();
    let mut target = r.host(&target_id).unwrap().unwrap();
    assert_eq!(target.jump_host_id.as_ref(), Some(&jump_id));
    assert!(matches!(
        r.jump_host(&target),
        Err(RepositoryError::JumpMissing)
    ));
    assert!(matches!(
        r.save(target.clone(), None),
        Err(RepositoryError::JumpMissing)
    ));
    target.jump_host_id = None;
    r.save(target, None).unwrap();
    assert!(r.credential(&copy_id).unwrap().is_some());
}

#[test]
fn jump_graph_rejects_self_drafts_nested_routes_and_reverse_edits() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("vault"), b"synthetic-master").unwrap();
    let mut r = Repository::new(&mut v);
    let mut jump = r.save(host("jump"), Some(secret())).unwrap();
    let outer = r.save(host("outer"), Some(secret())).unwrap();
    let mut target = host("target");
    target.jump_host_id = Some(target.id.clone());
    assert!(matches!(
        r.save(target.clone(), Some(secret())),
        Err(RepositoryError::JumpInvalid)
    ));
    let draft = host("draft only");
    r.save_draft(&HostDraft {
        host: draft.clone(),
        credential: Some(secret()),
        proxy_credential: None,
    })
    .unwrap();
    target.jump_host_id = Some(draft.id);
    assert!(matches!(
        r.save(target.clone(), Some(secret())),
        Err(RepositoryError::JumpMissing)
    ));
    target.jump_host_id = Some(jump.id.clone());
    let target = r.save(target, Some(secret())).unwrap();
    jump.jump_host_id = Some(outer.id.clone());
    assert!(matches!(
        r.save(jump.clone(), None),
        Err(RepositoryError::JumpInvalid)
    ));
    assert!(r.host(&jump.id).unwrap().unwrap().jump_host_id.is_none());
    let mut nested = outer;
    nested.jump_host_id = Some(target.id.clone());
    assert!(matches!(
        r.save(nested, None),
        Err(RepositoryError::JumpInvalid)
    ));
    let mut forged = target;
    forged.jump_host_id = Some("not-a-host-id".into());
    assert!(r.jump_host(&forged).is_err());
}

#[test]
fn a_route_has_exactly_one_proxy_without_silently_ignoring_either_configuration() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("vault"), b"synthetic-master").unwrap();
    let mut r = Repository::new(&mut v);
    let mut jump = r.save(host("jump"), Some(secret())).unwrap();
    let mut target = host("target");
    target.proxy = Some(proxy());
    target.jump_host_id = Some(jump.id.clone());
    let mut target = r.save(target, Some(secret())).unwrap();
    jump.proxy = Some(proxy());
    assert!(matches!(
        r.save(jump.clone(), None),
        Err(RepositoryError::JumpProxyConflict)
    ));
    assert!(r.host(&jump.id).unwrap().unwrap().proxy.is_none());
    target.proxy = None;
    r.save(target.clone(), None).unwrap();
    r.save(jump.clone(), None).unwrap();
    assert!(r.jump_host(&target).unwrap().unwrap().proxy.is_some());
    target.proxy = Some(proxy());
    assert!(matches!(
        r.save(target.clone(), None),
        Err(RepositoryError::JumpProxyConflict)
    ));
    assert!(matches!(
        r.jump_host(&target),
        Err(RepositoryError::JumpProxyConflict)
    ));
}

#[test]
fn rejected_jump_save_preserves_formal_credentials_and_recoverable_draft() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("vault"), b"synthetic-master").unwrap();
    let mut r = Repository::new(&mut v);
    let mut h = r.save(host("original"), Some(secret())).unwrap();
    let original = encoded(&h).unwrap();
    h.jump_host_id = Some(host("missing").id);
    h.name = "not committed".into();
    r.save_draft(&HostDraft {
        host: h.clone(),
        credential: Some(Credential {
            secret: "replacement-secret".into(),
            passphrase: None,
        }),
        proxy_credential: None,
    })
    .unwrap();
    assert!(matches!(
        r.save(h.clone(), None),
        Err(RepositoryError::JumpMissing)
    ));
    assert_eq!(
        *encoded(&r.host(&h.id).unwrap().unwrap()).unwrap(),
        *original
    );
    assert_eq!(
        r.credential(&h.id).unwrap().unwrap().secret,
        "synthetic-jump-secret"
    );
    assert_eq!(r.drafts().unwrap()[0].host.jump_host_id, h.jump_host_id);
}

#[test]
fn old_host_records_remain_direct_routes() {
    let mut value = serde_json::to_value(host("legacy")).unwrap();
    value.as_object_mut().unwrap().remove("jump_host_id");
    let decoded: HostRecord = serde_json::from_value(value).unwrap();
    assert!(decoded.jump_host_id.is_none());
}
