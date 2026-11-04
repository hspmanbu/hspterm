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
