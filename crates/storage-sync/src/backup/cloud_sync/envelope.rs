//! Independent wire domain. A backup file cannot be submitted as cloud data.
//! All lengths/version/collection are checked before the fixed Argon2id cost.
use super::*;
use aes_gcm::{
    KeyInit, Nonce,
    aead::{Aead, Payload},
};
use rand::{RngCore, rngs::OsRng};

const MAGIC: &[u8; 8] = b"HSPSYN01";
const HEADER: usize = 76; // magic, random salt16, nonce12, collection32, length8
pub(super) fn seal(plain: &[u8], password: &[u8], collection: &str) -> Result<Vec<u8>> {
    if plain.len() > MAX_PLAIN {
        return Err(SyncError::Capacity);
    }
    if !opaque(collection) || password.is_empty() || password.len() > 4096 {
        return Err(SyncError::Invalid);
    }
    let mut header = [0; HEADER];
    header[..8].copy_from_slice(MAGIC);
    OsRng.fill_bytes(&mut header[8..36]);
    header[36..68].copy_from_slice(collection.as_bytes());
    header[68..].copy_from_slice(&(plain.len() as u64 + 16).to_be_bytes());
    let key = crate::derive(password, &header[8..24]).map_err(|_| SyncError::Invalid)?;
    let cipher =
        crate::VaultCipher::new_from_slice(key.as_ref()).map_err(|_| SyncError::Invalid)?;
    let encrypted = cipher
        .encrypt(
            Nonce::from_slice(&header[24..36]),
            Payload {
                msg: plain,
                aad: &header,
            },
        )
        .map_err(|_| SyncError::Invalid)?;
    let mut output = Vec::with_capacity(HEADER + encrypted.len());
    output.extend_from_slice(&header);
    output.extend_from_slice(&encrypted);
    Ok(output)
}
/// Decrypt accepting the object's OWN header collection instead of a locally
/// expected one. A success proves the sync password (the only secret input to
/// the AEAD key, with the full header as AAD) matches the device that created
/// the dataset, and yields the header's collection identifier: the dataset was
/// written under a different (e.g. pre-derivation, manual) collection. A
/// failure keeps meaning the password itself is wrong.
pub(super) fn open_legacy(bytes: &[u8], password: &[u8]) -> Result<(Zeroizing<Vec<u8>>, String)> {
    if bytes.len() < HEADER + 16 || bytes.len() > HEADER + MAX_PLAIN + 16 {
        return Err(SyncError::Capacity);
    }
    let header = &bytes[..HEADER];
    let stored = std::str::from_utf8(&header[36..68]).map_err(|_| SyncError::Invalid)?;
    if !super::opaque(stored) || password.is_empty() || password.len() > 4096 {
        return Err(SyncError::Invalid);
    }
    let plain = decrypt_with_header(bytes, header, password)?;
    Ok((plain, stored.to_owned()))
}
fn decrypt_with_header(bytes: &[u8], header: &[u8], password: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    if &header[..8] != MAGIC
        || u64::from_be_bytes(header[68..76].try_into().map_err(|_| SyncError::Invalid)?)
            != (bytes.len() - HEADER) as u64
    {
        return Err(SyncError::Invalid);
    }
    let key = crate::derive(password, &header[8..24]).map_err(|_| SyncError::Invalid)?;
    let cipher =
        crate::VaultCipher::new_from_slice(key.as_ref()).map_err(|_| SyncError::Invalid)?;
    cipher
        .decrypt(
            Nonce::from_slice(&header[24..36]),
            Payload {
                msg: &bytes[HEADER..],
                aad: header,
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| SyncError::Invalid)
}
/// The plaintext collection identifier of a stored cloud object, without any
/// key derivation. Lets the driver distinguish a legacy-identifier dataset
/// (and prove prior ownership of that identifier) before the exchange runs.
pub fn header_collection(bytes: &[u8]) -> Option<String> {
    if bytes.len() < HEADER + 16 {
        return None;
    }
    let stored = std::str::from_utf8(&bytes[36..68]).ok()?;
    super::opaque(stored).then(|| stored.to_owned())
}
pub(super) fn open(bytes: &[u8], password: &[u8], collection: &str) -> Result<Zeroizing<Vec<u8>>> {
    if bytes.len() < HEADER + 16 || bytes.len() > HEADER + MAX_PLAIN + 16 {
        return Err(SyncError::Capacity);
    }
    let header = &bytes[..HEADER];
    if !opaque(collection)
        || password.is_empty()
        || password.len() > 4096
        || &header[..8] != MAGIC
        || &header[36..68] != collection.as_bytes()
    {
        return Err(SyncError::Invalid);
    }
    decrypt_with_header(bytes, header, password)
}
