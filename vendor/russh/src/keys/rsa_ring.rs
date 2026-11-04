//! RSA SHA-2 signing through the existing ring backend, without RustCrypto RSA.
//! Key preparation must run on a blocking worker. No secret modular exponentiation
//! is implemented here: ring validates the components and performs every signature.
use crypto_bigint::{NonZero, U4096};
use ssh_key::{Algorithm, HashAlg, Signature, private::RsaKeypair};
use zeroize::{Zeroize, Zeroizing};

pub struct RingRsaSigner(ring::rsa::KeyPair);

impl std::fmt::Debug for RingRsaSigner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RingRsaSigner([REDACTED])")
    }
}

// EncodedUint does not implement Zeroize. Wipe its backing bytes on every path.
struct WipeBytes<T: AsRef<[u8]> + AsMut<[u8]>>(T);
impl<T: AsRef<[u8]> + AsMut<[u8]>> Drop for WipeBytes<T> {
    fn drop(&mut self) {
        self.0.as_mut().zeroize();
    }
}
fn positive(value: &ssh_key::Mpint) -> ssh_key::Result<&[u8]> {
    value.as_positive_bytes().ok_or(ssh_key::Error::Crypto)
}
fn uint(bytes: &[u8]) -> ssh_key::Result<Zeroizing<U4096>> {
    if bytes.is_empty() || bytes.len() > 512 {
        return Err(ssh_key::Error::Crypto);
    }
    let mut padded = Zeroizing::new([0u8; 512]);
    padded[512 - bytes.len()..].copy_from_slice(bytes);
    Ok(Zeroizing::new(U4096::from_be_slice(padded.as_ref())))
}
fn minimal(bytes: &[u8]) -> &[u8] {
    &bytes[bytes.iter().position(|b| *b != 0).unwrap_or(bytes.len())..]
}
impl RingRsaSigner {
    /// Accept only ring's supported private key range, 2048 through 4096 bits.
    /// Compute missing OpenSSH CRT exponents using constant-time fixed-size
    /// remainder, with private temporaries zeroized even on failed validation.
    pub fn new(key: &RsaKeypair) -> ssh_key::Result<Self> {
        if !(2048..=4096).contains(&key.key_size()) {
            return Err(ssh_key::Error::Crypto);
        }
        let public = key.public();
        let private = key.private();
        let d = positive(private.d())?;
        let p = positive(private.p())?;
        let q = positive(private.q())?;
        let exponent = uint(d)?;
        let p_minus_one = Zeroizing::new(uint(p)?.wrapping_sub(&U4096::ONE));
        let q_minus_one = Zeroizing::new(uint(q)?.wrapping_sub(&U4096::ONE));
        let p_modulus = Zeroizing::new(
            NonZero::new(*p_minus_one)
                .into_option()
                .ok_or(ssh_key::Error::Crypto)?,
        );
        let q_modulus = Zeroizing::new(
            NonZero::new(*q_minus_one)
                .into_option()
                .ok_or(ssh_key::Error::Crypto)?,
        );
        let dp = Zeroizing::new(exponent.rem(&p_modulus));
        let dq = Zeroizing::new(exponent.rem(&q_modulus));
        let dp_bytes = WipeBytes(dp.to_be_bytes());
        let dq_bytes = WipeBytes(dq.to_be_bytes());
        let components = ring::rsa::KeyPairComponents {
            public_key: ring::rsa::PublicKeyComponents {
                n: positive(public.n())?,
                e: positive(public.e())?,
            },
            d,
            p,
            q,
            dP: minimal(dp_bytes.0.as_ref()),
            dQ: minimal(dq_bytes.0.as_ref()),
            qInv: positive(private.iqmp())?,
        };
        ring::rsa::KeyPair::from_components(&components)
            .map(Self)
            .map_err(|_| ssh_key::Error::Crypto)
    }

    /// No SHA-1 fallback: a caller must negotiate an explicit SHA-2 algorithm.
    pub fn sign(&self, hash: Option<HashAlg>, data: &[u8]) -> ssh_key::Result<Signature> {
        let encoding = match hash {
            Some(HashAlg::Sha256) => &ring::signature::RSA_PKCS1_SHA256,
            Some(HashAlg::Sha512) => &ring::signature::RSA_PKCS1_SHA512,
            _ => {
                return Err(ssh_key::Error::AlgorithmUnsupported {
                    algorithm: Algorithm::Rsa { hash },
                });
            }
        };
        let mut output = vec![0; self.0.public().modulus_len()];
        self.0
            .sign(
                encoding,
                &ring::rand::SystemRandom::new(),
                data,
                &mut output,
            )
            .map_err(|_| ssh_key::Error::Crypto)?;
        Signature::new(Algorithm::Rsa { hash }, output)
    }
}
