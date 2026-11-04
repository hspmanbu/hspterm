use super::*;
use russh::keys::{HashAlg, RingRsaSigner, ssh_key::private::KeypairData};

pub(super) fn key(path: &Path, bits: &str, password: &str) {
    assert!(
        Command::new("ssh-keygen")
            .args(["-q", "-t", "rsa", "-b", bits, "-N", password, "-f"])
            .arg(path)
            .status()
            .unwrap()
            .success()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rsa_openssh_private_authentication_uses_sha2_and_preserves_pty_sftp() {
    let server = Server::start().await;
    let path = server.dir.path().join("rsa");
    key(&path, "2048", "fixture-only-rsa-password");
    fs::copy(
        path.with_extension("pub"),
        server.dir.path().join("authorized_keys"),
    )
    .unwrap();
    let secret = Zeroizing::new(fs::read_to_string(&path).unwrap());
    let auth = || Authentication::PrivateKey {
        openssh: secret.clone(),
        passphrase: Some(Zeroizing::new("fixture-only-rsa-password".into())),
    };
    let mut connection = SshConnection::connect(
        server.config.clone(),
        auth(),
        server.pinned(),
        CancellationToken::new(),
    )
    .await
    .unwrap();
    let mut terminal = Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap();
    connection
        .write(b"printf '%s%s\\n' RSA_ SHA2_OK\n")
        .await
        .unwrap();
    until_text(&mut connection, &mut terminal, "RSA_SHA2_OK").await;
    let sftp = connection.open_sftp().await.unwrap();
    assert!(!sftp.canonicalize(".").await.unwrap().is_empty());
    sftp.close().await.unwrap();
    connection.close().await.unwrap();

    // Request each SHA-2 method explicitly against the real server. This catches
    // a signer using SHA-512 bytes under a SHA-256 SSH algorithm identifier.
    let parsed =
        russh::keys::decode_secret_key(&secret, Some("fixture-only-rsa-password")).unwrap();
    let KeypairData::Rsa(rsa) = parsed.key_data() else {
        panic!("fixture must be RSA")
    };
    let signer = RingRsaSigner::new(rsa).unwrap();
    for hash in [HashAlg::Sha256, HashAlg::Sha512] {
        let signature = signer.sign(Some(hash), b"fixture payload").unwrap();
        assert_eq!(
            signature.algorithm(),
            russh::keys::ssh_key::Algorithm::Rsa { hash: Some(hash) }
        );
        assert_eq!(signature.as_bytes().len(), 256);
        let mut client = russh::client::connect(
            std::sync::Arc::new(russh::client::Config::default()),
            ("127.0.0.1", server.config.port),
            Pinned(server.fingerprint.clone()),
        )
        .await
        .unwrap();
        let key = russh::keys::PrivateKeyWithHashAlg::try_new(
            std::sync::Arc::new(parsed.clone()),
            Some(hash),
        )
        .unwrap();
        assert!(
            client
                .authenticate_publickey(&server.config.username, key)
                .await
                .unwrap()
                .success()
        );
        client
            .disconnect(russh::Disconnect::ByApplication, "", "")
            .await
            .unwrap();
    }
    assert!(signer.sign(None, b"no legacy SHA1").is_err());
}

struct Pinned(String);
impl russh::client::Handler for Pinned {
    type Error = russh::Error;
    async fn check_server_key(
        &mut self,
        key: &russh::keys::PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        Ok(key.public_key().fingerprint(HashAlg::Sha256).to_string() == self.0)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rsa_weak_keys_and_wrong_passphrases_fail_without_password_fallback() {
    let server = Server::start().await;
    let path = server.dir.path().join("rsa-weak");
    key(&path, "1024", "fixture-only-rsa-password");
    fs::copy(
        path.with_extension("pub"),
        server.dir.path().join("authorized_keys"),
    )
    .unwrap();
    let secret = Zeroizing::new(fs::read_to_string(path).unwrap());
    for (passphrase, weak) in [("wrong", false), ("fixture-only-rsa-password", true)] {
        let result = SshConnection::connect(
            server.config.clone(),
            Authentication::PrivateKey {
                openssh: secret.clone(),
                passphrase: Some(Zeroizing::new(passphrase.into())),
            },
            server.pinned(),
            CancellationToken::new(),
        )
        .await;
        assert!(if weak {
            matches!(result, Err(SshError::RsaUnsupported))
        } else {
            matches!(result, Err(SshError::PrivateKey))
        });
    }
}

#[test]
fn rsa_ring_validates_4096_bit_components_and_rejects_inconsistent_crt() {
    use russh::keys::ssh_key::{
        Mpint,
        private::{RsaKeypair, RsaPrivateKey},
    };
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("rsa4096");
    key(&path, "4096", "");
    let source = Zeroizing::new(fs::read_to_string(&path).unwrap());
    let parsed = russh::keys::decode_secret_key(&source, None).unwrap();
    let KeypairData::Rsa(rsa) = parsed.key_data() else {
        panic!("fixture must be RSA")
    };
    let signer = RingRsaSigner::new(rsa).unwrap();
    assert_eq!(
        signer
            .sign(Some(HashAlg::Sha512), b"boundary fixture")
            .unwrap()
            .as_bytes()
            .len(),
        512
    );
    hspterm_ssh_core::validate_private_key(&source, None).unwrap();
    let private = rsa.private();
    let invalid = RsaPrivateKey::new(
        private.d().clone(),
        Mpint::from_positive_bytes(&[2]),
        private.p().clone(),
        private.q().clone(),
    )
    .unwrap();
    let invalid = RsaKeypair::new(rsa.public().clone(), invalid).unwrap();
    assert!(RingRsaSigner::new(&invalid).is_err());
}

#[test]
fn imported_openssh_keys_reject_excessive_kdf_work_before_decryption() {
    use base64::Engine;
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("bounded-kdf");
    generate_key(&path, "fixture-only-password");
    let source = Zeroizing::new(fs::read_to_string(path).unwrap());
    let body = source
        .lines()
        .filter(|l| !l.starts_with("-----"))
        .collect::<String>();
    let mut bytes = Zeroizing::new(
        base64::engine::general_purpose::STANDARD
            .decode(body)
            .unwrap(),
    );
    let mut offset = b"openssh-key-v1\0".len();
    for _ in 0..2 {
        let length = u32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize;
        offset += 4 + length;
    }
    let length = u32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize;
    let rounds = offset + 4 + length - 4;
    for value in [0u32, 257, u32::MAX] {
        bytes[rounds..rounds + 4].copy_from_slice(&value.to_be_bytes());
        let encoded = Zeroizing::new(format!(
            "-----BEGIN OPENSSH PRIVATE KEY-----\n{}\n-----END OPENSSH PRIVATE KEY-----\n",
            base64::engine::general_purpose::STANDARD.encode(&bytes)
        ));
        let start = std::time::Instant::now();
        assert!(
            hspterm_ssh_core::validate_private_key(&encoded, Some("fixture-only-password"))
                .is_err()
        );
        assert!(
            start.elapsed() < Duration::from_secs(1),
            "excessive KDF work must not run"
        );
    }
}

mod formats;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rsa_only_host_sha2_tofu_pinning_proofs_and_rekey_interoperate() {
    use russh::{ChannelMsg, keys::PrivateKeyWithHashAlg};
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    struct Observed {
        fingerprint: String,
        checks: Arc<AtomicUsize>,
    }
    impl russh::client::Handler for Observed {
        type Error = russh::Error;
        async fn check_server_key(
            &mut self,
            key: &russh::keys::PublicKeyOrCertificate,
        ) -> Result<bool, Self::Error> {
            self.checks.fetch_add(1, Ordering::SeqCst);
            Ok(key.public_key().fingerprint(HashAlg::Sha256).to_string() == self.fingerprint)
        }
    }
    for algorithm in ["rsa-sha2-256", "rsa-sha2-512"] {
        let server = Server::start_with_host_key(
            true,
            true,
            "rsa",
            &format!("HostKeyAlgorithms {algorithm}\nRekeyLimit 16K\n"),
        )
        .await;
        let (requests, mut receiver) = mpsc::channel(1);
        let config = server.config.clone();
        let auth = server.auth();
        let pending = tokio::spawn(async move {
            SshConnection::connect(
                config,
                auth,
                HostKeyPolicy::Confirm { requests },
                CancellationToken::new(),
            )
            .await
        });
        let request = timeout(Duration::from_secs(5), receiver.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(request.key.algorithm, "ssh-rsa");
        assert_eq!(request.key.sha256, server.fingerprint);
        request.decision.send(true).unwrap();
        let mut connection = pending.await.unwrap().unwrap();
        connection
            .write(b"printf '%s%s\\n' RSA_HOST_ CONFIRMED\n")
            .await
            .unwrap();
        let mut terminal = Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap();
        until_text(&mut connection, &mut terminal, "RSA_HOST_CONFIRMED").await;
        let sftp = connection.open_sftp().await.unwrap();
        assert!(!sftp.canonicalize(".").await.unwrap().is_empty());
        sftp.close().await.unwrap();
        connection.close().await.unwrap();
        assert!(matches!(
            SshConnection::connect(
                server.config.clone(),
                server.auth(),
                HostKeyPolicy::Pinned {
                    sha256: "SHA256:deliberately-different-fixture".into()
                },
                CancellationToken::new()
            )
            .await,
            Err(SshError::HostKeyChanged { .. })
        ));

        let checks = Arc::new(AtomicUsize::new(0));
        let client_key = match server.auth() {
            Authentication::PrivateKey {
                openssh,
                passphrase,
            } => {
                russh::keys::decode_secret_key(&openssh, passphrase.as_deref().map(|s| s.as_str()))
                    .unwrap()
            }
            _ => unreachable!(),
        };
        let mut client = russh::client::connect(
            Arc::new(russh::client::Config::default()),
            ("127.0.0.1", server.config.port),
            Observed {
                fingerprint: server.fingerprint.clone(),
                checks: checks.clone(),
            },
        )
        .await
        .unwrap();
        assert!(
            client
                .authenticate_publickey(
                    &server.config.username,
                    PrivateKeyWithHashAlg::try_new(Arc::new(client_key), None).unwrap()
                )
                .await
                .unwrap()
                .success()
        );
        let public = russh::keys::load_public_key(server.dir.path().join("host.pub")).unwrap();
        client.hostkeys_prove(vec![public]).await.unwrap();
        client.rekey_soon().await.unwrap();
        let mut channel = client.channel_open_session().await.unwrap();
        channel
            .exec(
                true,
                b"printf 'RSA_REKEY_OK'; head -c 65536 /dev/zero".as_slice(),
            )
            .await
            .unwrap();
        let mut output = Vec::new();
        timeout(Duration::from_secs(10), async {
            while let Some(message) = channel.wait().await {
                if let ChannelMsg::Data { data } = message {
                    output.extend_from_slice(&data);
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(output.len(), b"RSA_REKEY_OK".len() + 65536);
        assert!(output.starts_with(b"RSA_REKEY_OK"));
        assert!(output[b"RSA_REKEY_OK".len()..].iter().all(|b| *b == 0));
        assert!(
            checks.load(Ordering::SeqCst) >= 2,
            "explicit rekey must verify the host again"
        );
        client
            .disconnect(russh::Disconnect::ByApplication, "", "")
            .await
            .unwrap();
    }
}

#[test]
fn rsa_ring_public_verification_rejects_bad_messages_flags_keys_and_sizes() {
    use russh::keys::{
        ssh_key::{Algorithm, Signature},
        verify_signature,
    };
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("verify-rsa");
    key(&path, "2048", "");
    let source = Zeroizing::new(fs::read_to_string(path).unwrap());
    let parsed = russh::keys::decode_secret_key(&source, None).unwrap();
    let KeypairData::Rsa(pair) = parsed.key_data() else {
        unreachable!()
    };
    let signer = RingRsaSigner::new(pair).unwrap();
    let public = parsed.public_key();
    for hash in [HashAlg::Sha256, HashAlg::Sha512] {
        let sig = signer.sign(Some(hash), b"verified payload").unwrap();
        verify_signature(public, b"verified payload", &sig).unwrap();
        assert!(verify_signature(public, b"different payload", &sig).is_err());
        let opposite = if hash == HashAlg::Sha256 {
            HashAlg::Sha512
        } else {
            HashAlg::Sha256
        };
        let wrong = Signature::new(
            Algorithm::Rsa {
                hash: Some(opposite),
            },
            sig.as_bytes().to_vec(),
        )
        .unwrap();
        assert!(verify_signature(public, b"verified payload", &wrong).is_err());
        let sha1 = Signature::new(Algorithm::Rsa { hash: None }, sig.as_bytes().to_vec()).unwrap();
        assert!(verify_signature(public, b"verified payload", &sha1).is_err());
        let mut damaged = sig.as_bytes().to_vec();
        damaged[3] ^= 1;
        let bad = Signature::new(sig.algorithm(), damaged).unwrap();
        assert!(verify_signature(public, b"verified payload", &bad).is_err());
        let oversized = Signature::new(sig.algorithm(), vec![1; 257]).unwrap();
        assert!(verify_signature(public, b"verified payload", &oversized).is_err());
    }
    let weak = directory.path().join("weak");
    key(&weak, "1024", "");
    let weak = russh::keys::load_public_key(weak.with_extension("pub")).unwrap();
    let sig = signer
        .sign(Some(HashAlg::Sha256), b"verified payload")
        .unwrap();
    assert!(verify_signature(&weak, b"verified payload", &sig).is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rsa_sha1_only_host_is_not_silently_negotiated() {
    let server =
        Server::start_with_host_key(true, false, "rsa", "HostKeyAlgorithms ssh-rsa\n").await;
    let result = SshConnection::connect(
        server.config.clone(),
        server.auth(),
        server.pinned(),
        CancellationToken::new(),
    )
    .await;
    assert!(matches!(
        result,
        Err(SshError::Protocol(russh::Error::NoCommonAlgo { .. }))
    ));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ring_backed_controlled_server_accepts_real_rsa_user_signatures() {
    use russh::{
        keys::{PrivateKey, PrivateKeyWithHashAlg, PublicKey},
        server,
    };
    use std::sync::Arc;
    struct Peer {
        allowed: PublicKey,
    }
    impl server::Handler for Peer {
        type Error = russh::Error;
        async fn auth_publickey_offered(
            &mut self,
            _: &str,
            key: &PublicKey,
        ) -> Result<server::Auth, Self::Error> {
            Ok(if key.key_data() == self.allowed.key_data() {
                server::Auth::Accept
            } else {
                server::Auth::reject()
            })
        }
        async fn auth_publickey(
            &mut self,
            _: &str,
            key: &PublicKey,
        ) -> Result<server::Auth, Self::Error> {
            Ok(if key.key_data() == self.allowed.key_data() {
                server::Auth::Accept
            } else {
                server::Auth::reject()
            })
        }
    }
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("user-rsa");
    key(&path, "2048", "");
    let source = Zeroizing::new(fs::read_to_string(path).unwrap());
    let parsed = Arc::new(russh::keys::decode_secret_key(&source, None).unwrap());
    for hash in [HashAlg::Sha256, HashAlg::Sha512] {
        let host = PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519).unwrap();
        let fingerprint = host.public_key().fingerprint(HashAlg::Sha256).to_string();
        let config = Arc::new(server::Config {
            keys: vec![host],
            auth_rejection_time: Duration::ZERO,
            ..Default::default()
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let peer = Peer {
            allowed: parsed.public_key().clone(),
        };
        let serving = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            server::run_stream(config, socket, peer)
                .await
                .unwrap()
                .await
        });
        let mut client = russh::client::connect(
            Arc::new(Default::default()),
            ("127.0.0.1", port),
            Pinned(fingerprint),
        )
        .await
        .unwrap();
        assert!(
            client
                .authenticate_publickey(
                    "fixture",
                    PrivateKeyWithHashAlg::try_new(parsed.clone(), Some(hash)).unwrap()
                )
                .await
                .unwrap()
                .success()
        );
        client
            .disconnect(russh::Disconnect::ByApplication, "", "")
            .await
            .unwrap();
        timeout(Duration::from_secs(5), serving)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
    }
}

#[test]
fn rsa_signature_zero_prefix_omission_is_padded_without_changing_value() {
    use russh::keys::{ssh_key::Signature, verify_signature};
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("short-signature");
    key(&path, "2048", "");
    let source = Zeroizing::new(fs::read_to_string(path).unwrap());
    let parsed = russh::keys::decode_secret_key(&source, None).unwrap();
    let KeypairData::Rsa(pair) = parsed.key_data() else {
        unreachable!()
    };
    let signer = RingRsaSigner::new(pair).unwrap();
    // At most 16k independent public messages. Average 256 signatures; no
    // private fixture or external credential is stored in the repository.
    for number in 0u32..16_384 {
        let message = number.to_be_bytes();
        let signature = signer.sign(Some(HashAlg::Sha256), &message).unwrap();
        if signature.as_bytes()[0] == 0 {
            let short =
                Signature::new(signature.algorithm(), signature.as_bytes()[1..].to_vec()).unwrap();
            verify_signature(parsed.public_key(), &message, &short).unwrap();
            return;
        }
    }
    panic!("bounded fixture search did not produce a leading-zero signature");
}
