//! RSA SHA-2 verification through the pinned ring backend.
use ssh_key::{Algorithm, HashAlg, PublicKey, Signature, public::KeyData};

pub(super) fn verify_public_key(
    key: &PublicKey,
    data: &[u8],
    signature: &Signature,
) -> Result<(), signature::Error> {
    let KeyData::Rsa(rsa) = key.key_data() else {
        return signature::Verifier::verify(key, data, signature);
    };
    let algorithm = match signature.algorithm() {
        Algorithm::Rsa {
            hash: Some(HashAlg::Sha256),
        } => &ring::signature::RSA_PKCS1_2048_8192_SHA256,
        Algorithm::Rsa {
            hash: Some(HashAlg::Sha512),
        } => &ring::signature::RSA_PKCS1_2048_8192_SHA512,
        _ => return Err(signature::Error::new()),
    };
    if !(2048..=8192).contains(&rsa.key_size()) {
        return Err(signature::Error::new());
    }
    let n = rsa
        .n()
        .as_positive_bytes()
        .ok_or_else(signature::Error::new)?;
    let public = ring::signature::RsaPublicKeyComponents {
        n,
        e: rsa
            .e()
            .as_positive_bytes()
            .ok_or_else(signature::Error::new)?,
    };
    // RFC8332 permits omitted leading zero signature octets. ring expects the
    // exact modulus width; left-pad only, never truncate an oversized signature.
    let raw = signature.as_bytes();
    if raw.is_empty() || raw.len() > n.len() {
        return Err(signature::Error::new());
    }
    let mut padded = [0u8; 1024];
    let output = &mut padded[..n.len()];
    output[n.len() - raw.len()..].copy_from_slice(raw);
    public
        .verify(algorithm, data, output)
        .map_err(|_| signature::Error::new())
}
