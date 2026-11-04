use rand::rng;
// Copyright 2016 Pierre-Étienne Meunier
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
use ssh_encoding::Decode;
use ssh_key::public::KeyData;
use ssh_key::{Algorithm, EcdsaCurve, PublicKey};

use crate::keys::Error;

pub trait PublicKeyExt {
    fn decode(bytes: &[u8]) -> Result<PublicKey, Error>;
}

impl PublicKeyExt for PublicKey {
    fn decode(mut bytes: &[u8]) -> Result<PublicKey, Error> {
        let key = KeyData::decode(&mut bytes)?;
        Ok(PublicKey::new(key, ""))
    }
}

#[doc(hidden)]
pub trait Verify {
    fn verify_client_auth(&self, buffer: &[u8], sig: &[u8]) -> bool;
    fn verify_server_auth(&self, buffer: &[u8], sig: &[u8]) -> bool;
}

/// Parse a public key from a byte slice.
pub fn parse_public_key(mut p: &[u8]) -> Result<PublicKey, Error> {
    Ok(ssh_key::public::KeyData::decode(&mut p)?.into())
}

/// Obtain a cryptographic-safe random number generator.
pub fn safe_rng() -> impl rand::CryptoRng {
    rng()
}

mod private_key_with_hash_alg {
    use std::ops::Deref;
    use std::sync::Arc;

    use ssh_key::Algorithm;

    use crate::helpers::AlgorithmExt;

    /// Helper structure to correlate a key and (in case of RSA) a hash algorithm.
    /// Only used for authentication, not key storage as RSA keys do not inherently
    /// have a hash algorithm associated with them.
    #[derive(Clone, Debug)]
    pub struct PrivateKeyWithHashAlg {
        key: Arc<crate::keys::PrivateKey>,
        hash_alg: Option<crate::keys::HashAlg>,
        #[cfg(feature = "ring")]
        rsa_signer: Arc<std::sync::OnceLock<Result<crate::keys::RingRsaSigner, ()>>>,
    }

    impl PrivateKeyWithHashAlg {
        /// Direct constructor.
        ///
        /// For RSA, passing `None` is mapped to the legacy `ssh-rsa` (SHA-1).
        /// For other keys, `hash_alg` is ignored.
        pub fn new(
            key: Arc<crate::keys::PrivateKey>,
            mut hash_alg: Option<crate::keys::HashAlg>,
        ) -> Self {
            if !key.algorithm().is_rsa() {
                hash_alg = None;
            }
            Self {
                key,
                hash_alg,
                #[cfg(feature = "ring")]
                rsa_signer: Arc::new(std::sync::OnceLock::new()),
            }
        }

        /// Prepare RSA once on the caller's blocking worker before authentication.
        pub fn try_new(
            key: Arc<crate::keys::PrivateKey>,
            hash_alg: Option<crate::keys::HashAlg>,
        ) -> ssh_key::Result<Self> {
            let result = Self::new(key, hash_alg);
            #[cfg(feature = "ring")]
            if result.key.algorithm().is_rsa() {
                result.ring_rsa_signer()?;
            }
            Ok(result)
        }

        #[cfg(feature = "ring")]
        pub(crate) fn ring_rsa_signer(&self) -> ssh_key::Result<&crate::keys::RingRsaSigner> {
            self.rsa_signer
                .get_or_init(|| match self.key.key_data() {
                    ssh_key::private::KeypairData::Rsa(key) => {
                        crate::keys::RingRsaSigner::new(key).map_err(|_| ())
                    }
                    _ => Err(()),
                })
                .as_ref()
                .map_err(|_| ssh_key::Error::Crypto)
        }

        pub fn algorithm(&self) -> Algorithm {
            self.key.algorithm().with_hash_alg(self.hash_alg)
        }

        pub fn hash_alg(&self) -> Option<crate::keys::HashAlg> {
            self.hash_alg
        }
    }

    impl Deref for PrivateKeyWithHashAlg {
        type Target = crate::keys::PrivateKey;

        fn deref(&self) -> &Self::Target {
            &self.key
        }
    }
}

pub use private_key_with_hash_alg::PrivateKeyWithHashAlg;

pub const ALL_KEY_TYPES: &[Algorithm] = &[
    Algorithm::Dsa,
    Algorithm::Ecdsa {
        curve: EcdsaCurve::NistP256,
    },
    Algorithm::Ecdsa {
        curve: EcdsaCurve::NistP384,
    },
    Algorithm::Ecdsa {
        curve: EcdsaCurve::NistP521,
    },
    Algorithm::Ed25519,
    #[cfg(feature = "rsa")]
    Algorithm::Rsa { hash: None },
    #[cfg(feature = "rsa")]
    Algorithm::Rsa {
        hash: Some(ssh_key::HashAlg::Sha256),
    },
    #[cfg(feature = "rsa")]
    Algorithm::Rsa {
        hash: Some(ssh_key::HashAlg::Sha512),
    },
    Algorithm::SkEcdsaSha2NistP256,
    Algorithm::SkEd25519,
];
