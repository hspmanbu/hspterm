//! Local SSH key operations; no subprocess, connection or secret diagnostics.
use crate::SshError;
use russh::keys::{Algorithm, HashAlg, PrivateKey, ssh_key::LineEnding};
use zeroize::Zeroizing;

pub struct KeyMaterial {
    pub private: Zeroizing<String>,
    pub public: String,
    pub fingerprint: String,
    pub algorithm: String,
}
pub struct PublicIdentity {
    pub public: String,
    pub fingerprint: String,
    pub algorithm: String,
}
fn describe(key: &PrivateKey) -> Result<PublicIdentity, SshError> {
    let public = key.public_key();
    Ok(PublicIdentity {
        public: public.to_openssh().map_err(|_| SshError::PrivateKey)?,
        fingerprint: public.fingerprint(HashAlg::Sha256).to_string(),
        algorithm: public.algorithm().as_str().to_owned(),
    })
}
pub fn public_identity(
    private: &str,
    passphrase: Option<&str>,
) -> Result<PublicIdentity, SshError> {
    let key =
        russh::keys::decode_secret_key(private, passphrase).map_err(|_| SshError::PrivateKey)?;
    describe(&key)
}
/// Run on a blocking worker. Private text is zeroized and must stay in Rust.
pub fn generate_ed25519(passphrase: Option<&str>) -> Result<KeyMaterial, SshError> {
    let mut random = rand::rng();
    let key =
        PrivateKey::random(&mut random, Algorithm::Ed25519).map_err(|_| SshError::PrivateKey)?;
    let identity = describe(&key)?;
    let key = match passphrase.filter(|p| !p.is_empty()) {
        Some(password) => key
            .encrypt(&mut random, password)
            .map_err(|_| SshError::PrivateKey)?,
        None => key,
    };
    Ok(KeyMaterial {
        private: key
            .to_openssh(LineEnding::LF)
            .map_err(|_| SshError::PrivateKey)?,
        public: identity.public,
        fingerprint: identity.fingerprint,
        algorithm: identity.algorithm,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn generated_keys_are_independent_and_the_encrypted_key_requires_its_password() {
        let first = generate_ed25519(Some("test-only-key-password")).unwrap();
        let second = generate_ed25519(None).unwrap();
        assert_ne!(first.fingerprint, second.fingerprint);
        assert_eq!(first.algorithm, "ssh-ed25519");
        assert!(public_identity(&first.private, None).is_err());
        assert!(public_identity(&first.private, Some("wrong")).is_err());
        let recovered = public_identity(&first.private, Some("test-only-key-password")).unwrap();
        assert_eq!(recovered.public, first.public);
        assert_eq!(recovered.fingerprint, first.fingerprint);
        assert_eq!(
            public_identity(&second.private, None).unwrap().public,
            second.public
        );
    }
}
