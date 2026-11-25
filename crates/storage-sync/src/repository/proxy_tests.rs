use super::*;
use crate::ssh_proxy::{ProxyCredential, ProxyKind, ProxySettings};

fn host() -> HostRecord {
    let mut h = HostRecord::new(
        "proxy host".into(),
        "ssh-target.invalid".into(),
        "fixture".into(),
        AuthMethod::Password,
    );
    h.proxy = Some(ProxySettings {
        enabled: true,
        kind: ProxyKind::Socks5,
        address: "proxy.invalid".into(),
        port: 1080,
        authenticate: true,
    });
    h
}
fn ssh_secret() -> Credential {
    Credential {
        secret: "synthetic-ssh-password".into(),
        passphrase: None,
    }
}
fn proxy_secret() -> ProxyCredential {
    ProxyCredential {
        username: "synthetic-proxy-user".into(),
        password: "synthetic-proxy-password".into(),
    }
}

#[test]
fn disabled_proxy_keeps_its_address_port_and_saved_credentials() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault = Vault::create(
        &dir.path().join("proxy-toggle.vault"),
        b"synthetic-proxy-master",
    )
    .unwrap();
    let mut repo = Repository::new(&mut vault);
    let mut saved = repo
        .save_with_proxy(host(), Some(ssh_secret()), Some(proxy_secret()))
        .unwrap();
    saved.proxy.as_mut().unwrap().enabled = false;
    let disabled = repo.save(saved, None).unwrap();
    let mut stored = repo.host(&disabled.id).unwrap().unwrap();
    assert!(stored.active_proxy().is_none());
    let settings = stored.proxy.as_mut().unwrap();
    assert_eq!(settings.address, "proxy.invalid");
    assert_eq!(settings.port, 1080);
    settings.enabled = true;
    assert!(repo.save(stored, None).unwrap().active_proxy().is_some());
}

#[test]
fn proxy_secrets_are_independent_encrypted_and_copy_delete_safe() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("proxy-vault");
    let mut v = Vault::create(&path, b"synthetic-proxy-master").unwrap();
    let original;
    let copy;
    {
        let mut repo = Repository::new(&mut v);
        let h = host();
        assert!(matches!(
            repo.save(h.clone(), Some(ssh_secret())),
            Err(RepositoryError::CredentialRequired)
        ));
        original = repo
            .save_with_proxy(h, Some(ssh_secret()), Some(proxy_secret()))
            .unwrap();
        copy = repo.copy(&original.id).unwrap();
        assert_ne!(original.id, copy.id);
        assert_ne!(original.credential_id, copy.credential_id);
        assert_eq!(
            repo.proxy_credential(&copy.id).unwrap().unwrap().password,
            "synthetic-proxy-password"
        );
        repo.save_with_proxy(
            original.clone(),
            None,
            Some(ProxyCredential {
                username: "replacement-user".into(),
                password: "replacement-password".into(),
            }),
        )
        .unwrap();
        assert_eq!(
            repo.proxy_credential(&copy.id).unwrap().unwrap().username,
            "synthetic-proxy-user"
        );
        repo.delete(std::slice::from_ref(&original.id)).unwrap();
        assert!(repo.host(&original.id).unwrap().is_none());
        assert_eq!(
            repo.proxy_credential(&copy.id).unwrap().unwrap().password,
            "synthetic-proxy-password"
        );
        assert_eq!(
            repo.credential(&copy.id).unwrap().unwrap().secret,
            "synthetic-ssh-password"
        );
    }
    drop(v);
    let bytes = std::fs::read(&path).unwrap();
    for secret in [
        b"synthetic-proxy-password".as_slice(),
        b"synthetic-proxy-user",
        b"replacement-password",
        b"synthetic-ssh-password",
    ] {
        assert!(!bytes.windows(secret.len()).any(|v| v == secret));
    }
    let mut v = Vault::open(&path, b"synthetic-proxy-master").unwrap();
    assert_eq!(
        Repository::new(&mut v)
            .proxy_credential(&copy.id)
            .unwrap()
            .unwrap()
            .password,
        "synthetic-proxy-password"
    );
}

#[test]
fn proxy_draft_recovery_and_disabling_authentication_do_not_resurrect_secrets() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("vault"), b"synthetic-master").unwrap();
    let mut repo = Repository::new(&mut v);
    let h = host();
    repo.save_draft(&HostDraft {
        host: h.clone(),
        credential: Some(ssh_secret()),
        proxy_credential: Some(proxy_secret()),
    })
    .unwrap();
    // A subsequent metadata-only autosave must retain an earlier secret edit.
    repo.save_draft(&HostDraft {
        host: h.clone(),
        credential: Some(ssh_secret()),
        proxy_credential: None,
    })
    .unwrap();
    let h = repo.save(h, None).unwrap();
    assert_eq!(
        repo.proxy_credential(&h.id).unwrap().unwrap().username,
        "synthetic-proxy-user"
    );
    let mut disabled = h.clone();
    disabled.proxy.as_mut().unwrap().authenticate = false;
    repo.save(disabled.clone(), None).unwrap();
    assert!(repo.proxy_credential(&h.id).unwrap().is_none());
    disabled.proxy.as_mut().unwrap().authenticate = true;
    assert!(matches!(
        repo.save(disabled, None),
        Err(RepositoryError::CredentialRequired)
    ));
    assert!(
        !repo
            .host(&h.id)
            .unwrap()
            .unwrap()
            .proxy
            .unwrap()
            .authenticate
    );
    let mut legacy = serde_json::to_value(&h).unwrap();
    legacy.as_object_mut().unwrap().remove("proxy");
    assert!(
        serde_json::from_value::<HostRecord>(legacy)
            .unwrap()
            .proxy
            .is_none()
    );
}

#[test]
fn proxy_configuration_validation_happens_before_atomic_save() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("vault"), b"synthetic-master").unwrap();
    let mut repo = Repository::new(&mut v);
    let original = repo
        .save_with_proxy(host(), Some(ssh_secret()), Some(proxy_secret()))
        .unwrap();
    let before = encoded(&original).unwrap();
    let mut invalid = original.clone();
    invalid.proxy.as_mut().unwrap().address = "bad\r\nproxy".into();
    assert!(repo.save(invalid, None).is_err());
    assert_eq!(
        *encoded(&repo.host(&original.id).unwrap().unwrap()).unwrap(),
        *before
    );
    let oversized = ProxyCredential {
        username: "用".repeat(86),
        password: "p".into(),
    };
    assert!(
        repo.save_with_proxy(original.clone(), None, Some(oversized))
            .is_err()
    );
    assert_eq!(
        repo.proxy_credential(&original.id)
            .unwrap()
            .unwrap()
            .username,
        "synthetic-proxy-user"
    );
    let mut h = original;
    h.proxy.as_mut().unwrap().kind = ProxyKind::HttpConnect;
    assert!(
        repo.save_with_proxy(
            h,
            None,
            Some(ProxyCredential {
                username: "u:invalid".into(),
                password: "p".into()
            })
        )
        .is_err()
    );
}

#[test]
fn proxy_secret_write_failure_rolls_back_host_and_retains_recoverable_draft() {
    let dir = tempfile::tempdir().unwrap();
    let mut v = Vault::create(&dir.path().join("vault"), b"synthetic-master").unwrap();
    let mut h = Repository::new(&mut v)
        .save_with_proxy(host(), Some(ssh_secret()), Some(proxy_secret()))
        .unwrap();
    h.name = "pending change".into();
    Repository::new(&mut v)
        .save_draft(&HostDraft {
            host: h.clone(),
            credential: None,
            proxy_credential: Some(ProxyCredential {
                username: "new-u".into(),
                password: "new-p".into(),
            }),
        })
        .unwrap();
    v.db.execute_batch("CREATE TRIGGER fail_proxy BEFORE UPDATE ON records WHEN NEW.id LIKE 'host-proxy-credential-%' BEGIN SELECT RAISE(FAIL, 'synthetic proxy write failure'); END;").unwrap();
    assert!(Repository::new(&mut v).save(h.clone(), None).is_err());
    let repo = Repository::new(&mut v);
    assert_eq!(repo.host(&h.id).unwrap().unwrap().name, "proxy host");
    assert_eq!(
        repo.proxy_credential(&h.id).unwrap().unwrap().password,
        "synthetic-proxy-password"
    );
    assert_eq!(repo.drafts().unwrap().len(), 1);
    v.db.execute_batch("DROP TRIGGER fail_proxy;").unwrap();
    Repository::new(&mut v).save(h.clone(), None).unwrap();
    assert_eq!(
        Repository::new(&mut v)
            .proxy_credential(&h.id)
            .unwrap()
            .unwrap()
            .password,
        "new-p"
    );
}
