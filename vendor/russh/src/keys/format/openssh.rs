use ssh_key::PrivateKey;

use crate::keys::Error;

/// Decode a secret key given in the OpenSSH format, deciphering it if
/// needed using the supplied password.
pub fn decode_openssh(secret: &[u8], password: Option<&str>) -> Result<PrivateKey, Error> {
    let pk = PrivateKey::from_bytes(secret)?;
    if pk.is_encrypted() {
        // Bound non-preemptible password derivation before invoking it. The
        // common OpenSSH default is 16; 256 allows explicit stronger settings
        // without accepting attacker-controlled multi-billion-round workers.
        if let ssh_key::Kdf::Bcrypt { rounds, .. } = pk.kdf()
            && !(1..=256).contains(rounds)
        {
            return Err(Error::InvalidParameters);
        }
        if let Some(password) = password {
            return Ok(pk.decrypt(password)?);
        } else {
            return Err(Error::KeyIsEncrypted);
        }
    }
    Ok(pk)
}
