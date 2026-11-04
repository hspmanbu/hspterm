use super::Encryption;
use crate::keys::Error;
use aes::*;
use ssh_key::PrivateKey;
use zeroize::Zeroizing;

/// Import legacy OpenSSL PEM AES-CBC. This is not used for new key storage.
pub fn decode_pkcs5(
    secret: &[u8],
    password: Option<&str>,
    enc: Encryption,
) -> Result<PrivateKey, Error> {
    use aes::cipher::{BlockModeDecrypt, KeyIvInit, block_padding::Pkcs7};
    let password = password.ok_or(Error::KeyIsEncrypted)?;
    let (iv, length) = match enc {
        Encryption::Aes128Cbc(iv) => (iv, 16),
        Encryption::Aes256Cbc(iv) => (iv, 32),
    };
    // OpenSSL EVP_BytesToKey's legacy single-iteration MD5 derivation. Only
    // explicitly imported legacy ciphertext uses it; HSPTerm never creates it.
    let mut derived = Zeroizing::new([0u8; 32]);
    let mut previous = Zeroizing::new([0u8; 16]);
    for offset in (0..length).step_by(16) {
        let mut context = md5::Context::new();
        if offset != 0 {
            context.consume(previous.as_ref());
        }
        context.consume(password.as_bytes());
        context.consume(&iv[..8]);
        let mut digest = context.finalize();
        previous.copy_from_slice(&digest.0);
        derived[offset..offset + 16].copy_from_slice(&digest.0);
        zeroize::Zeroize::zeroize(&mut digest.0);
    }
    let mut plaintext = Zeroizing::new(secret.to_vec());
    let clear = match enc {
        Encryption::Aes128Cbc(_) => cbc::Decryptor::<Aes128>::new_from_slices(&derived[..16], &iv)
            .map_err(|_| Error::InvalidParameters)?
            .decrypt_padded::<Pkcs7>(&mut plaintext)?,
        Encryption::Aes256Cbc(_) => cbc::Decryptor::<Aes256>::new_from_slices(&derived[..32], &iv)
            .map_err(|_| Error::InvalidParameters)?
            .decrypt_padded::<Pkcs7>(&mut plaintext)?,
    };
    #[cfg(any(feature = "rsa", feature = "ring"))]
    {
        super::decode_rsa_pkcs1_der(clear).map(Into::into)
    }
    #[cfg(not(any(feature = "rsa", feature = "ring")))]
    {
        let _ = clear;
        Err(Error::UnsupportedKeyType {
            key_type_string: "RSA".into(),
            key_type_raw: vec![],
        })
    }
}
