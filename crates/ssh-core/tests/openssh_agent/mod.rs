use super::*;
mod peer;
use hspterm_ssh_core::{AgentPhase, ManagedSession};
use russh::keys::{HashAlg, PrivateKey};

async fn text(session: &ManagedSession, expected: &str) {
    timeout(Duration::from_secs(10), async {
        let mut frames = session.subscribe_frames();
        while !session.snapshot().unwrap().text().contains(expected) {
            frames.changed().await.unwrap();
        }
    })
    .await
    .unwrap_or_else(|_| panic!("synthetic Agent fixture marker timed out: {expected}"));
}
async fn connect(server: &Server, enabled: bool) -> (ManagedSession, tokio::task::JoinHandle<()>) {
    let (session, mut events) = ManagedSession::new(Size::new(120, 30).unwrap(), 200).unwrap();
    let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
    let mut config = server.config.clone();
    config.agent_forwarding = enabled;
    session
        .connect(config, server.auth(), server.pinned())
        .await
        .unwrap();
    (session, drain)
}
fn selected(server: &Server) -> PrivateKey {
    let source = Zeroizing::new(fs::read_to_string(server.dir.path().join("client")).unwrap());
    russh::keys::decode_secret_key(&source, Some("test-only-key-passphrase")).unwrap()
}
fn python_command(source: &str) -> Vec<u8> {
    format!("python3 -c '{}'\n", source.replace('\'', "'\\''")).into_bytes()
}
async fn finish(session: ManagedSession, drain: tokio::task::JoinHandle<()>) {
    session.shutdown();
    session.wait_closed().await;
    drop(session);
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agent_real_openssh_lists_only_selected_keys_and_authenticates_second_server_then_revokes()
{
    let first = Server::start().await;
    let second = Server::start().await;
    let (session, drain) = connect(&first, true).await;
    let connector = session.agent_connector().await.unwrap();
    assert_eq!(connector.status().phase, AgentPhase::Ready);
    let stale = connector.status().epoch;
    let key = selected(&second);
    let public = key.public_key().to_openssh().unwrap();
    connector
        .authorise(stale, vec![key], Duration::from_secs(60))
        .await
        .unwrap();
    assert!(matches!(
        connector
            .authorise(stale, vec![selected(&first)], Duration::from_secs(60))
            .await,
        Err(SshError::AgentUnavailable)
    ));
    session
        .write(b"ssh-add -L; printf '%s%s\\n' AGENT_ LIST_DONE\n".to_vec())
        .await
        .unwrap();
    text(&session, "AGENT_LIST_DONE").await;
    assert!(
        session
            .snapshot()
            .unwrap()
            .text()
            .contains(public.split_whitespace().nth(1).unwrap())
    );

    let known = first.dir.path().join("synthetic-known-hosts");
    let host_key = fs::read_to_string(second.dir.path().join("host.pub")).unwrap();
    fs::write(
        &known,
        format!("[127.0.0.1]:{} {}", second.config.port, host_key),
    )
    .unwrap();
    // This explicit fixture command uses no IdentityFile, no password prompts,
    // no production host and strict pinned host checking. Only the forwarded
    // in-app key can authenticate the second, independent loopback sshd.
    let command = format!(
        "ssh -F /dev/null -o IdentityFile=none -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile={} -p {} {}@127.0.0.1 \"printf '%s%s\\\\n' AGENT_ SECOND_OK\"\n",
        known.display(),
        second.config.port,
        second.config.username
    );
    session.write(command.into_bytes()).await.unwrap();
    text(&session, "AGENT_SECOND_OK").await;
    let old = connector.status().epoch;
    connector.revoke().await.unwrap();
    assert_eq!(connector.status().phase, AgentPhase::Revoked);
    assert!(matches!(
        connector
            .authorise(old, vec![selected(&second)], Duration::from_secs(60))
            .await,
        Err(SshError::AgentUnavailable)
    ));
    session.write(b"ssh-add -L >/dev/null 2>&1; test $? -ne 0 && printf '%s%s\\n' AGENT_ DENIED; printf '%s%s\\n' PTY_ STILL_ALIVE\n".to_vec()).await.unwrap();
    text(&session, "AGENT_DENIED").await;
    text(&session, "PTY_STILL_ALIVE").await;
    // Explicit reconnect is a new original capability and never reauthorizes.
    session.disconnect().await.unwrap();
    assert_eq!(connector.status().phase, AgentPhase::Closed);
    let mut config = first.config.clone();
    config.agent_forwarding = true;
    session
        .connect(config, first.auth(), first.pinned())
        .await
        .unwrap();
    assert_eq!(
        session.agent_connector().await.unwrap().status().phase,
        AgentPhase::Ready
    );
    assert!(
        connector
            .authorise(
                connector.status().epoch,
                vec![selected(&second)],
                Duration::from_secs(60)
            )
            .await
            .is_err()
    );
    finish(session, drain).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agent_remote_denial_and_default_off_leave_normal_terminal_working() {
    let server = Server::start_with_options(true, false).await;
    for enabled in [false, true] {
        let (session, drain) = connect(&server, enabled).await;
        let connector = session.agent_connector().await.unwrap();
        assert_eq!(
            connector.status().phase,
            if enabled {
                AgentPhase::Denied
            } else {
                AgentPhase::NotRequested
            }
        );
        assert!(
            connector
                .authorise(0, vec![selected(&server)], Duration::from_secs(60))
                .await
                .is_err()
        );
        session
            .write(b"printf '%s%s\\n' NORMAL_ SHELL_OK\n".to_vec())
            .await
            .unwrap();
        text(&session, "NORMAL_SHELL_OK").await;
        finish(session, drain).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agent_rsa_sha2_signatures_interoperate_with_remote_openssh_and_expire() {
    let first = Server::start().await;
    let rsa = first.dir.path().join("rsa-agent");
    assert!(
        Command::new("ssh-keygen")
            .args(["-q", "-t", "rsa", "-b", "2048", "-N", "", "-f"])
            .arg(&rsa)
            .status()
            .unwrap()
            .success()
    );
    let source = Zeroizing::new(fs::read_to_string(&rsa).unwrap());
    let key = russh::keys::decode_secret_key(&source, None).unwrap();
    let fingerprint = key.public_key().fingerprint(HashAlg::Sha256).to_string();
    let (session, drain) = connect(&first, true).await;
    let connector = session.agent_connector().await.unwrap();
    connector
        .authorise(0, vec![key], Duration::from_secs(3))
        .await
        .unwrap();
    // ssh-add -T performs a real sign-and-verify round trip through SSH_AUTH_SOCK.
    session
        .write(
            format!(
                "ssh-add -T {} && printf '%s%s\\n' RSA_AGENT_ VERIFIED\n",
                rsa.with_extension("pub").display()
            )
            .into_bytes(),
        )
        .await
        .unwrap();
    text(&session, "RSA_AGENT_VERIFIED").await;
    assert!(!fingerprint.is_empty());
    let mut changes = connector.watch();
    timeout(Duration::from_secs(5), async {
        while changes.borrow_and_update().phase == AgentPhase::Active {
            changes.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
    assert_eq!(connector.status().phase, AgentPhase::Expired);
    session
        .write(b"printf '%s%s\\n' EXPIRED_ PTY_ALIVE\n".to_vec())
        .await
        .unwrap();
    text(&session, "EXPIRED_PTY_ALIVE").await;
    finish(session, drain).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agent_real_slow_remote_consumers_do_not_stall_pty_or_revocation() {
    let server = Server::start().await;
    let (session, drain) = connect(&server, true).await;
    let connector = session.agent_connector().await.unwrap();
    connector
        .authorise(0, vec![selected(&server)], Duration::from_secs(60))
        .await
        .unwrap();
    // Real OpenSSH, four forwarded Unix sockets, senders which never consume
    // Agent replies. Each stream eventually fills its receive window. A PTY
    // marker must still cross the same SSH dispatcher while they are active.
    let mut command = b"PS1=AGENT_'READY> '; ".to_vec();
    command.extend(python_command(
        r#"import os,socket,threading,time
sockets=[]
def flood(s):
 try:
  while True: s.sendall(b'\0\0\0\1\x0b'*8192)
 except OSError: pass
for _ in range(4):
 s=socket.socket(socket.AF_UNIX);s.connect(os.environ['SSH_AUTH_SOCK']);sockets.append(s)
 threading.Thread(target=flood,args=(s,),daemon=True).start()
time.sleep(1)
print('AGENT_SLOW_'+'PTY_OK',flush=True)
time.sleep(1)
for s in sockets: s.close()
"#,
    ));
    command.pop();
    command.extend_from_slice(b"; printf '%s%s\\n' SLOW_ PROGRAM_DONE\n");
    session.write(command).await.unwrap();
    text(&session, "AGENT_SLOW_PTY_OK").await;
    connector.revoke().await.unwrap();
    assert_eq!(connector.status().phase, AgentPhase::Revoked);
    text(&session, "SLOW_PROGRAM_DONE").await;
    text(&session, "AGENT_READY>").await;
    session
        .write(b"printf '%s%s\\n' AFTER_SLOW_ ALIVE\n".to_vec())
        .await
        .unwrap();
    text(&session, "AFTER_SLOW_ALIVE").await;
    finish(session, drain).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agent_rsa_flag_bitset_signatures_are_verified_independently_by_openssl() {
    use base64::Engine;
    let server = Server::start().await;
    let path = server.dir.path().join("rsa-flags");
    assert!(
        Command::new("ssh-keygen")
            .args(["-q", "-t", "rsa", "-b", "2048", "-N", "", "-f"])
            .arg(&path)
            .status()
            .unwrap()
            .success()
    );
    let source = Zeroizing::new(fs::read_to_string(&path).unwrap());
    let key = russh::keys::decode_secret_key(&source, None).unwrap();
    let public =
        base64::engine::general_purpose::STANDARD.encode(key.public_key().to_bytes().unwrap());
    let exported = Command::new("ssh-keygen")
        .args(["-e", "-m", "PKCS8", "-f"])
        .arg(path.with_extension("pub"))
        .output()
        .unwrap();
    assert!(exported.status.success());
    let pem = server.dir.path().join("rsa-public.pem");
    fs::write(&pem, exported.stdout).unwrap();
    let signature = server.dir.path().join("rsa-signature.bin");
    let (session, drain) = connect(&server, true).await;
    let connector = session.agent_connector().await.unwrap();
    connector
        .authorise(0, vec![key], Duration::from_secs(60))
        .await
        .unwrap();
    let script = format!(
        r#"import os,socket,struct,base64,subprocess
def st(b): return struct.pack('>I',len(b))+b
def exact(s,n):
 b=b''
 while len(b)<n:
  part=s.recv(n-len(b));assert part;b+=part
 return b
def take(b):
 n=struct.unpack('>I',b[:4])[0];return b[4:4+n],b[4+n:]
s=socket.socket(socket.AF_UNIX);s.connect(os.environ['SSH_AUTH_SOCK'])
key=base64.b64decode('{public}');data=b'synthetic flags challenge'
for flags,alg,digest in [(2,b'rsa-sha2-256','-sha256'),(4,b'rsa-sha2-512','-sha512'),(6,b'rsa-sha2-512','-sha512')]:
 body=b'\x0d'+st(key)+st(data)+struct.pack('>I',flags);s.sendall(st(body))
 response=exact(s,struct.unpack('>I',exact(s,4))[0]);assert response[0]==14
 blob,tail=take(response[1:]);assert not tail
 actual,rest=take(blob);sig,tail=take(rest);assert actual==alg and not tail
 open('{signature}','wb').write(sig)
 assert subprocess.run(['openssl','dgst',digest,'-verify','{pem}','-signature','{signature}'],input=data,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
 assert subprocess.run(['openssl','dgst',digest,'-verify','{pem}','-signature','{signature}'],input=b'wrong challenge',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0
for flags in [0,1,8]:
 body=b'\x0d'+st(key)+st(data)+struct.pack('>I',flags);s.sendall(st(body))
 assert exact(s,struct.unpack('>I',exact(s,4))[0])==b'\x05'
print('RSA_FLAGS_'+'VERIFIED',flush=True)
"#,
        signature = signature.display(),
        pem = pem.display()
    );
    session.write(python_command(&script)).await.unwrap();
    text(&session, "RSA_FLAGS_VERIFIED").await;
    connector.revoke().await.unwrap();
    finish(session, drain).await;
}
