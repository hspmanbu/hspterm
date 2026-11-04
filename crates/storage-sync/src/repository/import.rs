//! A reviewed metadata-only import is the sole creation path without credentials.
//! Normal save still requires credentials. No caller controls IDs or key links.
use super::*;
use crate::openssh_import;
use std::collections::{BTreeMap, BTreeSet};

impl Repository<'_> {
    pub fn import_openssh(
        &mut self,
        source: &str,
        default_username: &str,
        aliases: &[String],
        acknowledge_partial: bool,
        group_id: &str,
    ) -> Result<Vec<HostRecord>> {
        let selected = openssh_import::preview(source, default_username)
            .and_then(|preview| preview.selected(aliases, acknowledge_partial))
            .map_err(|_| RepositoryError::Invalid)?;
        let prior = self.vault.get_bounded(CATALOG, MAX_RECORD)?;
        let mut catalog = self.catalog()?;
        if !catalog.groups.iter().any(|g| g.id == group_id) {
            return Err(RepositoryError::Invalid);
        }
        let mut names = BTreeSet::new();
        for id in &catalog.hosts {
            names.insert(
                self.host(id)?
                    .ok_or(RepositoryError::Format)?
                    .name
                    .to_lowercase(),
            );
        }
        let mut ids = BTreeMap::new();
        let mut hosts = Vec::new();
        for candidate in &selected {
            if !names.insert(candidate.alias.to_lowercase()) {
                return Err(RepositoryError::ImportConflict);
            }
            let mut host = HostRecord::new(
                candidate.alias.clone(),
                candidate.address.clone(),
                candidate.username.clone(),
                if candidate.private_key {
                    AuthMethod::PrivateKey
                } else {
                    AuthMethod::Password
                },
            );
            host.port = candidate.port;
            host.timeout_seconds = candidate.timeout_seconds;
            host.keepalive_seconds = candidate.keepalive_seconds;
            host.keepalive_failures = candidate.keepalive_failures;
            host.group_id = group_id.into();
            // Import is an explicit snapshot, never silently overridden by global defaults.
            host.use_network_defaults = false;
            host.validate()?;
            ids.insert(candidate.alias.to_ascii_lowercase(), host.id.clone());
            hosts.push(host);
        }
        for (host, candidate) in hosts.iter_mut().zip(&selected) {
            if let Some(alias) = &candidate.jump_alias {
                host.jump_host_id = Some(
                    ids.get(&alias.to_ascii_lowercase())
                        .ok_or(RepositoryError::JumpMissing)?
                        .clone(),
                );
            }
            catalog.hosts.push(host.id.clone());
        }
        let cat_raw = catalog.encoded()?;
        let raw_hosts = hosts.iter().map(encoded).collect::<Result<Vec<_>>>()?;
        let mut expected = vec![(CATALOG, prior.as_deref().map(Vec::as_slice))];
        let mut changes = vec![RecordChange::Put(CATALOG, &cat_raw)];
        for (host, raw) in hosts.iter().zip(&raw_hosts) {
            expected.push((&host.id, None));
            changes.push(RecordChange::Put(&host.id, raw));
        }
        if !self.vault.apply_checked(&expected, &changes)? {
            return Err(RepositoryError::ImportConflict);
        }
        Ok(hosts)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn import_is_atomic_encrypted_metadata_and_never_manufactures_credentials() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("import.vault");
        let mut vault = Vault::create(&path, b"synthetic-only").unwrap();
        let scope = vault.instance_id().to_owned();
        let source = "Host target\n HostName target.invalid\n ProxyJump jump\n IdentityFile /secret-never-read\nHost jump\n HostName jump.invalid\nUser fixture";
        let aliases = vec!["target".into(), "jump".into()];
        let mut repo = Repository::new(&mut vault);
        assert!(
            repo.import_openssh(source, "fixture", &aliases, false, DEFAULT_GROUP)
                .is_err()
        );
        assert!(repo.list().unwrap().is_empty());
        let hosts = repo
            .import_openssh(source, "fixture", &aliases, true, DEFAULT_GROUP)
            .unwrap();
        assert_eq!(hosts[0].jump_host_id.as_ref(), Some(&hosts[1].id));
        for host in &hosts {
            assert!(host.credential_id.is_none());
            assert!(repo.credential(&host.id).unwrap().is_none());
            assert!(!host.use_network_defaults);
        }
        assert!(
            repo.import_openssh(source, "fixture", &aliases, true, DEFAULT_GROUP)
                .is_err()
        );
        assert_eq!(repo.list().unwrap().len(), 2);
        let unrelated = HostRecord::new(
            "normal".into(),
            "direct.invalid".into(),
            "fixture".into(),
            AuthMethod::Password,
        );
        assert!(matches!(
            repo.save(unrelated, None),
            Err(RepositoryError::CredentialRequired)
        ));
        // Imported entries become connectable only after explicit credential configuration.
        let saved = repo
            .save(
                hosts[1].clone(),
                Some(Credential {
                    secret: "synthetic-secret".into(),
                    passphrase: None,
                }),
            )
            .unwrap();
        assert!(saved.credential_id.is_some());
        drop(vault);
        let mut reopened = Vault::open(&path, b"synthetic-only").unwrap();
        assert_ne!(reopened.instance_id(), scope);
        assert_eq!(Repository::new(&mut reopened).list().unwrap().len(), 2);
        let bytes = std::fs::read(path).unwrap();
        for secret in [
            b"target.invalid".as_slice(),
            b"synthetic-secret",
            b"secret-never-read",
        ] {
            assert!(!bytes.windows(secret.len()).any(|b| b == secret));
        }
    }
    #[test]
    fn invalid_selection_group_duplicate_name_or_storage_failure_changes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("atomic.vault");
        let mut vault = Vault::create(&path, b"synthetic-only").unwrap();
        let source = "Host a b\n User fixture";
        {
            let mut repo = Repository::new(&mut vault);
            assert!(
                repo.import_openssh(source, "", &["a".into()], true, "absent")
                    .is_err()
            );
            assert!(repo.list().unwrap().is_empty());
        }
        // Force the second host row to fail after the transaction already wrote catalog/first host.
        vault.db.execute_batch("CREATE TRIGGER reject_second BEFORE INSERT ON records WHEN NEW.id LIKE 'host-%' AND (SELECT COUNT(*) FROM records WHERE id LIKE 'host-%') >= 1 BEGIN SELECT RAISE(ABORT,'synthetic rejection'); END;").unwrap();
        assert!(
            Repository::new(&mut vault)
                .import_openssh(source, "", &["a".into(), "b".into()], true, DEFAULT_GROUP)
                .is_err()
        );
        assert!(Repository::new(&mut vault).list().unwrap().is_empty());
        vault
            .db
            .execute_batch("DROP TRIGGER reject_second;")
            .unwrap();
        Repository::new(&mut vault)
            .import_openssh(source, "", &["a".into()], true, DEFAULT_GROUP)
            .unwrap();
        assert!(
            Repository::new(&mut vault)
                .import_openssh(source, "", &["b".into(), "a".into()], true, DEFAULT_GROUP)
                .is_err()
        );
        assert_eq!(Repository::new(&mut vault).list().unwrap().len(), 1);
    }
}
