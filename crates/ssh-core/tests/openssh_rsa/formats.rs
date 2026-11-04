use super::*;
use base64::{Engine, engine::general_purpose::STANDARD};

const PASS: &str = "fixture-only-pem-password";
fn openssl(args: &[&str], input: &Path, output: &Path) {
    let result = Command::new("openssl")
        .args(args)
        .arg("-in")
        .arg(input)
        .arg("-out")
        .arg(output)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(result.success(), "OpenSSL fixture conversion failed");
}
fn legacy_key(server: &Server) -> std::path::PathBuf {
    let path = server.dir.path().join("rsa-legacy");
    key(&path, "2048", "");
    fs::copy(
        path.with_extension("pub"),
        server.dir.path().join("authorized_keys"),
    )
    .unwrap();
    assert!(
        Command::new("ssh-keygen")
            .args(["-p", "-m", "PEM", "-P", "", "-N", "", "-f"])
            .arg(&path)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .success()
    );
    path
}
fn pem(label: &str, bytes: &[u8]) -> Zeroizing<String> {
    Zeroizing::new(format!(
        "-----BEGIN {label}-----\n{}\n-----END {label}-----\n",
        STANDARD.encode(bytes)
    ))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pkcs1_pkcs8_and_legacy_aes_pem_import_really_authenticate() {
    let server = Server::start().await;
    let source = legacy_key(&server);
    let pkcs8 = server.dir.path().join("pkcs8");
    openssl(&["pkcs8", "-topk8", "-nocrypt"], &source, &pkcs8);
    let protected = server.dir.path().join("protected");
    openssl(
        &[
            "pkcs8",
            "-topk8",
            "-v2",
            "aes-256-cbc",
            "-iter",
            "1200",
            "-passout",
            "pass:fixture-only-pem-password",
        ],
        &source,
        &protected,
    );
    let scrypt = server.dir.path().join("scrypt");
    openssl(
        &[
            "pkcs8",
            "-topk8",
            "-scrypt",
            "-passout",
            "pass:fixture-only-pem-password",
        ],
        &source,
        &scrypt,
    );
    let aes128 = server.dir.path().join("legacy128");
    openssl(
        &[
            "rsa",
            "-traditional",
            "-aes128",
            "-passout",
            "pass:fixture-only-pem-password",
        ],
        &source,
        &aes128,
    );
    let aes256 = server.dir.path().join("legacy256");
    openssl(
        &[
            "rsa",
            "-traditional",
            "-aes256",
            "-passout",
            "pass:fixture-only-pem-password",
        ],
        &source,
        &aes256,
    );
    for (path, encrypted) in [
        (&source, false),
        (&pkcs8, false),
        (&protected, true),
        (&scrypt, true),
        (&aes128, true),
        (&aes256, true),
    ] {
        let secret = Zeroizing::new(fs::read_to_string(path).unwrap());
        hspterm_ssh_core::validate_private_key(&secret, encrypted.then_some(PASS)).unwrap();
        // A configured passphrase does not turn an unencrypted PKCS#8 into ciphertext.
        if !encrypted {
            russh::keys::decode_secret_key(&secret, Some(PASS)).unwrap();
        }
        if encrypted {
            assert!(russh::keys::decode_secret_key(&secret, None).is_err());
            assert!(russh::keys::decode_secret_key(&secret, Some("wrong-fixture")).is_err());
        }
        let mut connection = SshConnection::connect(
            server.config.clone(),
            Authentication::PrivateKey {
                openssh: secret,
                passphrase: encrypted.then(|| Zeroizing::new(PASS.into())),
            },
            server.pinned(),
            CancellationToken::new(),
        )
        .await
        .unwrap();
        let mut terminal = Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap();
        connection
            .write(b"printf '%s%s\\n' IMPORTED_RSA_ AUTHENTICATED\n")
            .await
            .unwrap();
        until_text(&mut connection, &mut terminal, "IMPORTED_RSA_AUTHENTICATED").await;
        connection.close().await.unwrap();
    }
}

fn tlv(bytes: &[u8], start: usize) -> (usize, usize) {
    let first = bytes[start + 1];
    if first & 128 == 0 {
        (start + 2, usize::from(first))
    } else {
        let count = usize::from(first & 127);
        let length = bytes[start + 2..start + 2 + count]
            .iter()
            .fold(0usize, |v, b| v * 256 + usize::from(*b));
        (start + 2 + count, length)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rsa_import_rejects_bad_der_crt_versions_and_excessive_pbkdf2_before_work() {
    let server = Server::start().await;
    let source = legacy_key(&server);
    let body = Zeroizing::new(
        fs::read_to_string(&source)
            .unwrap()
            .lines()
            .filter(|s| !s.starts_with("-----"))
            .collect::<String>(),
    );
    let bytes = Zeroizing::new(STANDARD.decode(body.as_bytes()).unwrap());
    let (mut offset, _) = tlv(&bytes, 0);
    let (version, version_len) = tlv(&bytes, offset);
    let mut multi = bytes.clone();
    multi[version] = 1;
    assert!(russh::keys::decode_secret_key(&pem("RSA PRIVATE KEY", &multi), None).is_err());
    offset = version + version_len;
    for component in 0..8 {
        let (start, length) = tlv(&bytes, offset);
        if component >= 5 {
            // dP, dQ and qInv must all be validated.
            let mut changed = bytes.clone();
            changed[start + length - 1] ^= 2;
            assert!(
                russh::keys::decode_secret_key(&pem("RSA PRIVATE KEY", &changed), None).is_err()
            );
        }
        offset = start + length;
    }
    let mut trailing = bytes.clone();
    trailing.push(0);
    assert!(russh::keys::decode_secret_key(&pem("RSA PRIVATE KEY", &trailing), None).is_err());
    assert!(
        russh::keys::decode_secret_key(&pem("RSA PRIVATE KEY", &bytes[..bytes.len() - 1]), None)
            .is_err()
    );
    let protected = server.dir.path().join("bounded-pbkdf");
    openssl(
        &[
            "pkcs8",
            "-topk8",
            "-v2",
            "aes-256-cbc",
            "-iter",
            "65537",
            "-passout",
            "pass:fixture-only-pem-password",
        ],
        &source,
        &protected,
    );
    let body = Zeroizing::new(
        fs::read_to_string(protected)
            .unwrap()
            .lines()
            .filter(|s| !s.starts_with("-----"))
            .collect::<String>(),
    );
    let mut encrypted = Zeroizing::new(STANDARD.decode(body.as_bytes()).unwrap());
    let pattern = [2, 3, 1, 0, 1]; // DER INTEGER 65537, produced by the controlled fixture.
    let positions: Vec<_> = encrypted
        .windows(5)
        .enumerate()
        .filter(|(_, b)| *b == pattern)
        .map(|(i, _)| i)
        .collect();
    assert_eq!(positions.len(), 1);
    encrypted[positions[0] + 2..positions[0] + 5].copy_from_slice(&[0x10, 0, 1]); // 1048577
    let before = std::time::Instant::now();
    assert!(matches!(
        russh::keys::decode_secret_key(&pem("ENCRYPTED PRIVATE KEY", &encrypted), Some(PASS)),
        Err(russh::keys::Error::InvalidParameters)
    ));
    assert!(
        before.elapsed() < Duration::from_secs(1),
        "invalid KDF must be rejected before deriving"
    );
    assert!(russh::keys::decode_secret_key(&"x".repeat(256 * 1024 + 1), None).is_err());
}

// Re-encode lengths through all parent SEQUENCEs, allowing valid malicious KDF
// parameters rather than only malformed ASN.1 that never reaches the work gate.
fn replace_integer(input: &[u8], old: &[u8], new: &[u8]) -> Vec<u8> {
    let (start, length) = tlv(input, 0);
    let content = &input[start..start + length];
    let body = if input[0] == 0x30 {
        let mut output = Vec::new();
        let mut offset = 0;
        while offset < content.len() {
            let (inner, count) = tlv(content, offset);
            output.extend(replace_integer(&content[offset..inner + count], old, new));
            offset = inner + count;
        }
        output
    } else if input[0] == 2 && content == old {
        new.to_vec()
    } else {
        content.to_vec()
    };
    let mut output = vec![input[0]];
    if body.len() < 128 {
        output.push(body.len() as u8);
    } else if body.len() < 256 {
        output.extend([0x81, body.len() as u8]);
    } else {
        output.extend([0x82, (body.len() >> 8) as u8, body.len() as u8]);
    }
    output.extend(body);
    output
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pkcs8_valid_der_zero_huge_pbkdf2_and_scrypt_costs_are_rejected_immediately() {
    let server = Server::start().await;
    let source = legacy_key(&server);
    for scrypt in [false, true] {
        let path = server
            .dir
            .path()
            .join(if scrypt { "scrypt-cost" } else { "pbkdf-cost" });
        let extra: &[&str] = if scrypt {
            &[
                "pkcs8",
                "-topk8",
                "-scrypt",
                "-passout",
                "pass:fixture-only-pem-password",
            ]
        } else {
            &[
                "pkcs8",
                "-topk8",
                "-v2",
                "aes-256-cbc",
                "-iter",
                "65537",
                "-passout",
                "pass:fixture-only-pem-password",
            ]
        };
        openssl(extra, &source, &path);
        let body = Zeroizing::new(
            fs::read_to_string(path)
                .unwrap()
                .lines()
                .filter(|s| !s.starts_with("-----"))
                .collect::<String>(),
        );
        let original = Zeroizing::new(STANDARD.decode(body.as_bytes()).unwrap());
        let old: &[u8] = if scrypt { &[0x40, 0] } else { &[1, 0, 1] };
        for cost in [
            &[0][..],
            &[3][..],
            &[0x40, 0, 0, 0][..],
            &[0, 0xff, 0xff, 0xff, 0xff][..],
        ] {
            if !scrypt && cost == [3] {
                continue;
            } // PBKDF2=3 is valid.
            let changed = Zeroizing::new(replace_integer(&original, old, cost));
            assert_ne!(changed.as_slice(), original.as_slice());
            let before = std::time::Instant::now();
            assert!(matches!(
                russh::keys::decode_secret_key(&pem("ENCRYPTED PRIVATE KEY", &changed), Some(PASS)),
                Err(russh::keys::Error::InvalidParameters)
            ));
            assert!(before.elapsed() < Duration::from_secs(1));
        }
    }
}
