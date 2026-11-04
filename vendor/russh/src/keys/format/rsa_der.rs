//! Borrowed, bounded PKCS#1 parsing. ring validates and signs; no private RSA
//! arithmetic or RustCrypto RSA dependency is used by this adapter.
use crate::keys::Error;
use der::{Reader, SliceReader, asn1::UintRef};
use ssh_key::{
    Mpint,
    private::{RsaKeypair, RsaPrivateKey},
    public::RsaPublicKey,
};

pub(super) fn decode(secret: &[u8]) -> Result<RsaKeypair, Error> {
    if secret.len() > 16 * 1024 {
        return Err(Error::InvalidParameters);
    }
    let key = ring::rsa::KeyPair::from_der(secret).map_err(|_| Error::KeyIsCorrupt)?;
    // ring defers some CRT consistency checks until signing. Exercise those
    // checks before accepting an imported key, not on its first remote use.
    let mut probe = [0u8; 512];
    key.sign(
        &ring::signature::RSA_PKCS1_SHA256,
        &ring::rand::SystemRandom::new(),
        b"HSPTerm imported RSA component validation v1",
        &mut probe[..key.public().modulus_len()],
    )
    .map_err(|_| Error::KeyIsCorrupt)?;
    let mut reader = SliceReader::new(secret)?;
    let result = reader.sequence(|seq| -> Result<RsaKeypair, Error> {
        let version: u8 = seq.decode()?;
        if version != 0 {
            return Err(Error::InvalidParameters);
        }
        // Borrow all DER integers first, including dP/dQ: allocating ordinary
        // Mpints for those discarded CRT fields would leave secret scratch on
        // error paths because Mpint itself does not zeroize on Drop.
        let values: [UintRef<'_>; 8] = [
            seq.decode()?,
            seq.decode()?,
            seq.decode()?,
            seq.decode()?,
            seq.decode()?,
            seq.decode()?,
            seq.decode()?,
            seq.decode()?,
        ];
        if values.iter().any(|v| v.as_bytes().len() > 512) {
            return Err(Error::InvalidParameters);
        }
        let public = RsaPublicKey::new(
            Mpint::from_positive_bytes(values[1].as_bytes()),
            Mpint::from_positive_bytes(values[0].as_bytes()),
        )?;
        if !(2048..=4096).contains(&public.key_size()) {
            return Err(Error::InvalidParameters);
        }
        // ring already established positivity/consistency. PrivateKey owns and
        // zeroizes these four retained values; no discarded private copies.
        let private = RsaPrivateKey::new(
            Mpint::from_positive_bytes(values[2].as_bytes()),
            Mpint::from_positive_bytes(values[7].as_bytes()),
            Mpint::from_positive_bytes(values[3].as_bytes()),
            Mpint::from_positive_bytes(values[4].as_bytes()),
        )?;
        let result = RsaKeypair::new(public, private)?;
        if !(2048..=4096).contains(&result.key_size()) {
            return Err(Error::InvalidParameters);
        }
        Ok(result)
    })?;
    reader.finish()?;
    Ok(result)
}

pub(super) fn check_public(secret: &[u8], public: &RsaPublicKey) -> Result<(), Error> {
    if secret.len() > 2048 {
        return Err(Error::InvalidParameters);
    }
    let mut reader = SliceReader::new(secret)?;
    let matches = reader.sequence(|seq| -> Result<bool, Error> {
        let n: UintRef<'_> = seq.decode()?;
        let e: UintRef<'_> = seq.decode()?;
        Ok(public.n().as_positive_bytes() == Some(n.as_bytes())
            && public.e().as_positive_bytes() == Some(e.as_bytes()))
    })?;
    reader.finish()?;
    if matches {
        Ok(())
    } else {
        Err(Error::KeyIsCorrupt)
    }
}
