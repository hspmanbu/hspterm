use std::io::Write;

use data_encoding::{BASE64_MIME, HEXLOWER_PERMISSIVE};
use ssh_key::PrivateKey;
use zeroize::Zeroizing;

use super::is_base64_char;
use crate::keys::Error;

pub mod openssh;
#[cfg(feature = "ring")]
mod rsa_der;

#[cfg(test)]
mod tests;

pub use self::openssh::*;

pub mod pkcs5;
pub use self::pkcs5::*;

pub mod pkcs8;

const AES_256_CBC: &str = "DEK-Info: AES-256-CBC,";
const AES_128_CBC: &str = "DEK-Info: AES-128-CBC,";

#[derive(Clone, Copy, Debug)]
/// AES encryption key.
pub enum Encryption {
    /// Key for AES128
    Aes128Cbc([u8; 16]),
    /// Key for AES256
    Aes256Cbc([u8; 16]),
}

#[derive(Clone, Debug)]
enum Format {
    #[cfg(any(feature = "rsa", feature = "ring"))]
    Rsa,
    Openssh,
    Pkcs5Encrypted(Encryption),
    Pkcs8Encrypted,
    Pkcs8,
}

/// Decode a secret key, possibly deciphering it with the supplied
/// password.
pub fn decode_secret_key(secret: &str, password: Option<&str>) -> Result<PrivateKey, Error> {
    if secret.len() > 256 * 1024 {
        return Err(Error::InvalidParameters);
    }
    if secret.trim().starts_with("PuTTY-User-Key-File-") {
        return Ok(PrivateKey::from_ppk(secret, password.map(Into::into))?);
    }
    let mut format = None;
    let secret = {
        let mut started = false;
        let mut sec = Zeroizing::new(String::new());
        for l in secret.lines() {
            if started {
                if l.starts_with("-----END ") {
                    break;
                }
                if l.chars().all(is_base64_char) {
                    sec.push_str(l)
                } else if l.starts_with(AES_128_CBC) || l.starts_with(AES_256_CBC) {
                    let iv_: Vec<u8> =
                        HEXLOWER_PERMISSIVE.decode(l.split_at(AES_128_CBC.len()).1.as_bytes())?;
                    if iv_.len() != 16 {
                        return Err(Error::CouldNotReadKey);
                    }
                    let mut iv = [0; 16];
                    iv.clone_from_slice(&iv_);
                    format = Some(Format::Pkcs5Encrypted(if l.starts_with(AES_256_CBC) {
                        Encryption::Aes256Cbc(iv)
                    } else {
                        Encryption::Aes128Cbc(iv)
                    }))
                } else if l.starts_with("DEK-Info:") {
                    return Err(Error::InvalidParameters);
                }
            }
            if l == "-----BEGIN OPENSSH PRIVATE KEY-----" {
                started = true;
                format = Some(Format::Openssh);
            } else if l == "-----BEGIN RSA PRIVATE KEY-----" {
                #[cfg(any(feature = "rsa", feature = "ring"))]
                {
                    started = true;
                    format = Some(Format::Rsa);
                }
                #[cfg(not(any(feature = "rsa", feature = "ring")))]
                {
                    return Err(Error::UnsupportedKeyType {
                        key_type_string: "RSA".to_string(),
                        key_type_raw: vec![],
                    });
                }
            } else if l == "-----BEGIN ENCRYPTED PRIVATE KEY-----" {
                started = true;
                format = Some(Format::Pkcs8Encrypted);
            } else if l == "-----BEGIN PRIVATE KEY-----" || l == "-----BEGIN EC PRIVATE KEY-----" {
                started = true;
                format = Some(Format::Pkcs8);
            }
        }
        sec
    };

    let secret = Zeroizing::new(BASE64_MIME.decode(secret.as_bytes())?);
    match format {
        Some(Format::Openssh) => decode_openssh(&secret, password),
        #[cfg(any(feature = "rsa", feature = "ring"))]
        Some(Format::Rsa) => Ok(decode_rsa_pkcs1_der(&secret)?.into()),
        Some(Format::Pkcs5Encrypted(enc)) => decode_pkcs5(&secret, password, enc),
        Some(Format::Pkcs8Encrypted) => {
            let password = password.ok_or(Error::KeyIsEncrypted)?;
            self::pkcs8::decode_pkcs8(&secret, Some(password.as_bytes()))
        }
        Some(Format::Pkcs8) => self::pkcs8::decode_pkcs8(&secret, None),
        None => Err(Error::CouldNotReadKey),
    }
}

pub fn encode_pkcs8_pem<W: Write>(key: &PrivateKey, mut w: W) -> Result<(), Error> {
    let x = self::pkcs8::encode_pkcs8(key)?;
    w.write_all(b"-----BEGIN PRIVATE KEY-----\n")?;
    w.write_all(BASE64_MIME.encode(&x).as_bytes())?;
    w.write_all(b"\n-----END PRIVATE KEY-----\n")?;
    Ok(())
}

pub fn encode_pkcs8_pem_encrypted<W: Write>(
    key: &PrivateKey,
    pass: &[u8],
    rounds: u32,
    mut w: W,
) -> Result<(), Error> {
    let x = self::pkcs8::encode_pkcs8_encrypted(pass, rounds, key)?;
    w.write_all(b"-----BEGIN ENCRYPTED PRIVATE KEY-----\n")?;
    w.write_all(BASE64_MIME.encode(&x).as_bytes())?;
    w.write_all(b"\n-----END ENCRYPTED PRIVATE KEY-----\n")?;
    Ok(())
}

#[cfg(feature = "ring")]
fn decode_rsa_pkcs1_der(secret: &[u8]) -> Result<ssh_key::private::RsaKeypair, Error> {
    rsa_der::decode(secret)
}

#[cfg(all(feature = "rsa", not(feature = "ring")))]
fn decode_rsa_pkcs1_der(secret: &[u8]) -> Result<ssh_key::private::RsaKeypair, Error> {
    use std::convert::TryInto;

    use pkcs1::DecodeRsaPrivateKey;

    Ok(rsa::RsaPrivateKey::from_pkcs1_der(secret)?.try_into()?)
}
