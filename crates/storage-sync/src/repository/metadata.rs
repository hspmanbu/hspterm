//! One read transaction for non-secret host-list publication. Secrets from
//! encrypted drafts are inspected only for presence and never leave Rust.
use super::*;

pub struct DraftMetadata {
    pub host: HostRecord,
    pub credential_set: bool,
    pub proxy_credential_set: bool,
}
pub struct CatalogMetadata {
    pub hosts: Vec<HostRecord>,
    pub groups: Vec<HostGroup>,
    pub drafts: Vec<DraftMetadata>,
}
impl Repository<'_> {
    pub fn metadata_snapshot(&self) -> Result<CatalogMetadata> {
        let transaction = self
            .vault
            .db
            .unchecked_transaction()
            .map_err(StorageError::from)?;
        let hosts = self.list()?;
        let groups = self.groups()?;
        let catalog = self.catalog()?;
        let mut drafts = Vec::with_capacity(catalog.drafts.len());
        for id in catalog.drafts {
            // Do not materialize every draft credential at once merely to
            // publish a list. Only this bounded record holds secret bodies.
            let raw = self
                .vault
                .get_bounded(&format!("draft-{id}"), MAX_RECORD)?
                .ok_or(RepositoryError::Format)?;
            let draft: HostDraft = decoded(&raw)?;
            let original = self.host(&draft.host.id)?;
            let credential_set = draft.credential.is_some()
                || original.as_ref().is_some_and(|host| {
                    host.auth == draft.host.auth && host.credential_id.is_some()
                });
            let proxy_credential_set = draft.proxy_credential.is_some()
                || (original.is_some() && self.proxy_credential(&draft.host.id)?.is_some());
            drafts.push(DraftMetadata {
                host: draft.host,
                credential_set,
                proxy_credential_set,
            });
        }
        transaction.commit().map_err(StorageError::from)?;
        Ok(CatalogMetadata {
            hosts,
            groups,
            drafts,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn coherent_catalog_metadata_contains_only_records_and_credential_presence() {
        let temp = tempfile::tempdir().unwrap();
        let mut vault = Vault::create(
            &temp.path().join("catalog.vault"),
            b"synthetic-catalog-master",
        )
        .unwrap();
        let mut repo = Repository::new(&mut vault);
        let host = repo
            .save(
                HostRecord::new(
                    "Saved".into(),
                    "example.invalid".into(),
                    "fixture".into(),
                    AuthMethod::Password,
                ),
                Some(Credential {
                    secret: "synthetic-fixture-password".into(),
                    passphrase: None,
                }),
            )
            .unwrap();
        let mut pending = host.clone();
        pending.name = "Draft".into();
        repo.save_draft(&HostDraft {
            host: pending,
            credential: None,
            proxy_credential: None,
        })
        .unwrap();
        let metadata = repo.metadata_snapshot().unwrap();
        assert_eq!(metadata.hosts[0].name, "Saved");
        assert_eq!(metadata.drafts[0].host.name, "Draft");
        assert!(metadata.drafts[0].credential_set);
        assert!(!metadata.drafts[0].proxy_credential_set);
        assert!(
            metadata
                .groups
                .iter()
                .any(|group| group.id == DEFAULT_GROUP)
        );
    }
}
