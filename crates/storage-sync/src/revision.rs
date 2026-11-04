//! Opaque local proposal identifiers. A fast unkeyed digest of credentials
//! must never become an offline password-guessing oracle across FFI.
use crate::Vault;
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;
use zeroize::Zeroizing;

type HmacSha256 = Hmac<Sha256>;
pub(crate) struct Revision(HmacSha256);
impl Vault {
    pub(crate) fn revision(&self, domain: &[u8]) -> Revision {
        // Separate the MAC key from AES-GCM, and keep it private to this Vault.
        let mut derive = HmacSha256::new_from_slice(self.key.as_ref())
            .expect("HMAC accepts the fixed-size Vault key");
        derive.update(b"HSPTerm local revision key v1\0");
        let key = Zeroizing::new(<[u8; 32]>::from(derive.finalize().into_bytes()));
        let mac = HmacSha256::new_from_slice(key.as_ref())
            .expect("HMAC accepts the fixed-size revision key");
        let mut revision = Revision(mac);
        revision.part(Some(b"HSPTerm scoped local revision v1\0"));
        revision.part(Some(domain));
        revision.part(Some(self.instance_id().as_bytes()));
        revision
    }
}
impl Revision {
    pub(crate) fn part(&mut self, bytes: Option<&[u8]>) {
        match bytes {
            Some(bytes) => {
                self.0.update(&[1]);
                self.0.update(&(bytes.len() as u64).to_be_bytes());
                self.0.update(bytes);
            }
            None => self.0.update(&[0]),
        }
    }
    pub(crate) fn finish(self) -> String {
        self.0
            .finalize()
            .into_bytes()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn tag(vault: &Vault, domain: &[u8], parts: &[Option<&[u8]>]) -> String {
        let mut tag = vault.revision(domain);
        for part in parts {
            tag.part(*part);
        }
        tag.finish()
    }
    #[test]
    fn tags_are_keyed_scoped_domain_separated_and_unambiguously_framed() {
        let dir = tempfile::tempdir().unwrap();
        let mut a = Vault::create(&dir.path().join("a.vault"), b"synthetic-master").unwrap();
        let mut b = Vault::create(&dir.path().join("b.vault"), b"synthetic-master").unwrap();
        // Equal public scope/input still cannot produce equal tags with
        // separately salted Vault keys. Nothing persists or exports the tag key.
        b.instance_id = a.instance_id.clone();
        let value = tag(&a, b"credentials", &[Some(b"synthetic-low-entropy")]);
        assert_eq!(
            value,
            tag(&a, b"credentials", &[Some(b"synthetic-low-entropy")])
        );
        assert_ne!(
            value,
            tag(&b, b"credentials", &[Some(b"synthetic-low-entropy")])
        );
        assert_ne!(
            value,
            tag(&a, b"other-domain", &[Some(b"synthetic-low-entropy")])
        );
        assert_ne!(tag(&a, b"test", &[None]), tag(&a, b"test", &[Some(b"")]));
        assert_ne!(
            tag(&a, b"test", &[Some(b"a"), Some(b"bc")]),
            tag(&a, b"test", &[Some(b"ab"), Some(b"c")])
        );
        a.instance_id = "synthetic-next-scope".into();
        assert_ne!(
            value,
            tag(&a, b"credentials", &[Some(b"synthetic-low-entropy")])
        );
    }
}
