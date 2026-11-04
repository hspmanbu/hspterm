use super::*;
#[test]
fn integration_is_off_for_legacy_hosts_and_copies_need_fresh_consent() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("integration.vault");
    let mut vault = Vault::create(&path, b"synthetic-integration-master").unwrap();
    let mut host = HostRecord::new(
        "Fixture".into(),
        "example.invalid".into(),
        "fixture".into(),
        AuthMethod::Password,
    );
    assert!(!host.shell_integration);
    let mut legacy = serde_json::to_value(&host).unwrap();
    legacy.as_object_mut().unwrap().remove("shell_integration");
    assert!(
        !serde_json::from_value::<HostRecord>(legacy)
            .unwrap()
            .shell_integration
    );
    host.shell_integration = true;
    let mut repo = Repository::new(&mut vault);
    let host = repo
        .save(
            host,
            Some(Credential {
                secret: "synthetic-fixture".into(),
                passphrase: None,
            }),
        )
        .unwrap();
    let copy = repo.copy_to_draft(&host.id).unwrap();
    assert!(!copy.shell_integration);
    assert!(repo.host(&host.id).unwrap().unwrap().shell_integration);
    assert!(
        !repo
            .drafts()
            .unwrap()
            .iter()
            .find(|d| d.host.id == copy.id)
            .unwrap()
            .host
            .shell_integration
    );
    drop(vault);
    let mut reopened = Vault::open(&path, b"synthetic-integration-master").unwrap();
    assert!(
        Repository::new(&mut reopened)
            .host(&host.id)
            .unwrap()
            .unwrap()
            .shell_integration
    );
}

#[test]
fn qualified_batch_filters_secrets_deduplicates_and_obeys_recording_switch() {
    let dir = tempfile::tempdir().unwrap();
    let mut vault =
        Vault::create(&dir.path().join("batch.vault"), b"synthetic-batch-master").unwrap();
    let host = Repository::new(&mut vault)
        .save(
            HostRecord::new(
                "Fixture".into(),
                "example.invalid".into(),
                "fixture".into(),
                AuthMethod::Password,
            ),
            Some(Credential {
                secret: "synthetic-fixture".into(),
                passphrase: None,
            }),
        )
        .unwrap();
    let mut history = crate::command_history::HistoryRepository::new(&mut vault);
    assert_eq!(
        history
            .record_qualified_batch(
                &host.id,
                &[
                    "git status",
                    "git log",
                    "git status",
                    "tool --token=synthetic-token"
                ]
            )
            .unwrap(),
        3
    );
    assert_eq!(history.candidates(&host.id, "git", 20).unwrap().len(), 2);
    history.set_enabled(false).unwrap();
    assert_eq!(
        history.record_qualified_batch(&host.id, &["pwd"]).unwrap(),
        0
    );
    assert!(history.candidates(&host.id, "git", 20).unwrap().is_empty());
    assert!(
        history
            .record_qualified_batch(&host.id, &["pwd"; 33])
            .is_err()
    );
}
