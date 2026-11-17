//! All tmux operations are isolated from the developer's default socket.
use super::*;
use hspterm_ssh_core::tmux::{Choice, Policy, Request};
use std::path::PathBuf;

struct Fixture {
    server: Server,
    namespace: tempfile::TempDir,
    socket: PathBuf,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remembered_creation_receipts_prove_the_new_session_and_name_collision_never_attaches_existing()
 {
    let f = Fixture::new().await;
    // Seed the explicitly private socket with -f /dev/null BEFORE the product
    // create path, so it cannot load the developer's default tmux config.
    f.seed();
    async fn create(f: &Fixture, name: &str) -> Result<SshConnection, hspterm_ssh_core::SshError> {
        let (tx, mut rx) = mpsc::channel(1);
        let mut config = f.server.config.clone();
        config.columns = 101;
        config.rows = 37;
        config.agent_forwarding = true;
        config.tmux = Some(Policy { requests: tx });
        let future = SshConnection::connect(
            config,
            f.server.auth(),
            f.server.pinned(),
            CancellationToken::new(),
        );
        tokio::pin!(future);
        let request = tokio::select! {
            result = &mut future => panic!("creation ended before explicit choice: {}", result.err().map(|e| e.to_string()).unwrap_or_default()),
            request = rx.recv() => request.unwrap(),
        };
        request
            .reply
            .send(Choice::CreateRemembered {
                name: name.into(),
                lock_size: true,
                ensure_locale: false,
            })
            .ok()
            .unwrap();
        future.await
    }
    let mut first = create(&f, "remember-new").await.unwrap();
    let identity = first
        .tmux_session()
        .cloned()
        .expect("actual creation identity");
    assert!(first.tmux_state().unwrap().size_locked);
    first
        .write(b"printf '%s%s\\n' CREATED_ CONFIRMED\n")
        .await
        .unwrap();
    output_until(&mut first, b"CREATED_CONFIRMED").await;
    first
        .write(
            b"if [ -S \"$SSH_AUTH_SOCK\" ]; then printf '%s%s\\n' CREATED_AGENT_ ENV_READY; fi\n",
        )
        .await
        .unwrap();
    output_until(&mut first, b"CREATED_AGENT_ENV_READY").await;
    first.close().await.unwrap();
    assert!(
        f.command(&["has-session", "-t", "remember-new"])
            .status
            .success()
    );

    let (tx, mut rx) = mpsc::channel(1);
    let mut config = f.server.config.clone();
    config.tmux = Some(Policy { requests: tx });
    let future = SshConnection::connect(
        config,
        f.server.auth(),
        f.server.pinned(),
        CancellationToken::new(),
    );
    tokio::pin!(future);
    let request = tokio::select! {
        result = &mut future => panic!("restore ended before choice: {}", result.err().map(|e| e.to_string()).unwrap_or_default()),
        request = rx.recv() => request.unwrap(),
    };
    let target = request
        .listing
        .sessions
        .iter()
        .find(|s| s.matches_identity(&identity))
        .unwrap()
        .id
        .clone();
    request
        .reply
        .send(Choice::Attach {
            id: target,
            readonly: false,
            takeover_confirmed: true,
            lock_size: false,
            ensure_locale: false,
        })
        .ok()
        .unwrap();
    let mut restored = future.await.unwrap();
    assert_eq!(restored.tmux_session(), Some(&identity));
    restored
        .write(b"printf '%s%s\\n' RESTORED_ CONFIRMED\n")
        .await
        .unwrap();
    output_until(&mut restored, b"RESTORED_CONFIRMED").await;
    restored.close().await.unwrap();

    assert!(create(&f, "fixture").await.is_err());
    assert!(
        f.command(&["has-session", "-t", "fixture"])
            .status
            .success()
    );
    assert!(
        f.command(&["has-session", "-t", "remember-new"])
            .status
            .success()
    );
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn clean_tmux_exit_restores_shell_on_original_transport_and_keeps_sftp() {
    use hspterm_ssh_core::{ManagedSession, SessionEvent, SessionPhase};
    let f = Fixture::new().await;
    let (mut session, mut events) = ManagedSession::new(Size::new(80, 24).unwrap(), 1000).unwrap();
    let (send, mut choices) = mpsc::channel(1);
    let mut config = f.server.config.clone();
    config.tmux = Some(Policy { requests: send });
    config.integration = Some(hspterm_ssh_core::integration::Launch::fresh());
    let receipt = {
        let connect = session.connect_verified(config, f.server.auth(), f.server.pinned());
        tokio::pin!(connect);
        let request = tokio::select! {
            result = &mut connect => panic!("tmux choice was not requested: {:?}", result),
            request = choices.recv() => request.unwrap(),
        };
        request
            .reply
            .send(Choice::Create {
                name: "hspterm1".into(),
                lock_size: true,
                ensure_locale: false,
            })
            .ok()
            .unwrap();
        connect.await.unwrap()
    };
    session
        .write(b"printf '%s%s\\n' BEFORE_ EXIT\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "BEFORE_EXIT").await;
    let sftp = session.open_sftp().await.unwrap();
    let before = sftp.canonicalize(".").await.unwrap();
    session.write(b"exit\n".to_vec()).await.unwrap();
    timeout(Duration::from_secs(15), async {
        loop {
            if let Some(SessionEvent::ShellRestored { generation }) = events.recv().await {
                assert_eq!(generation, receipt.generation);
                break;
            }
        }
    })
    .await
    .unwrap();
    assert_eq!(session.status().phase, SessionPhase::Connected);
    assert_eq!(session.status().generation, receipt.generation);
    assert!(!session.snapshot().unwrap().size_locked);
    assert!(!session.snapshot().unwrap().alternate_screen);
    assert_eq!(sftp.canonicalize(".").await.unwrap(), before);
    session
        .write(b"printf '%s%s\\n' AFTER_ EXIT\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "AFTER_EXIT").await;
    sftp.close().await.unwrap();
    session.close().await.unwrap();
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // Only the explicitly owned absolute socket, never plain kill-server.
        let _ = Command::new("tmux")
            .arg("-S")
            .arg(&self.socket)
            .arg("kill-server")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}
impl Fixture {
    async fn new() -> Self {
        let namespace = tempfile::Builder::new()
            .prefix("hspterm-tmux-fixture-")
            .tempdir()
            .unwrap();
        let extra = format!("SetEnv TMUX_TMPDIR={}\n", namespace.path().display());
        let server = Server::start_with_host_key(true, true, "ed25519", &extra).await;
        let uid = Command::new("id").arg("-u").output().unwrap();
        assert!(uid.status.success());
        let uid = String::from_utf8(uid.stdout).unwrap();
        let socket = namespace
            .path()
            .join(format!("tmux-{}", uid.trim()))
            .join("default");
        use std::os::unix::fs::PermissionsExt;
        fs::create_dir_all(socket.parent().unwrap()).unwrap();
        fs::set_permissions(socket.parent().unwrap(), fs::Permissions::from_mode(0o700)).unwrap();
        let effective = Command::new("/usr/sbin/sshd")
            .args(["-T", "-f"])
            .arg(server.dir.path().join("sshd_config"))
            .output()
            .unwrap();
        assert!(effective.status.success());
        assert!(
            String::from_utf8_lossy(&effective.stdout)
                .contains(&format!("TMUX_TMPDIR={}", namespace.path().display())),
            "isolated sshd did not accept its explicit tmux namespace"
        );
        let fixture = Self {
            server,
            namespace,
            socket,
        };
        // Prove the remote environment first. The expected path never appears
        // in the command, so echoed input cannot make this check pass.
        let mut check = fixture.server.connect().await;
        check.write(b"printf '%s%s:%s:%s:%s%s\\n' TBOX_ READY \"$TMUX_TMPDIR\" \"${TMUX-unset}\" END_ BOX\n").await.unwrap();
        let observed = output_until(&mut check, b":END_BOX").await;
        let expected = format!(
            "TBOX_READY:{}:unset:END_BOX",
            fixture.namespace.path().display()
        );
        assert!(
            observed
                .windows(expected.len())
                .any(|v| v == expected.as_bytes()),
            "private namespace proof failed: has_marker={}, path_matches={}, tmux_unset={}",
            observed.windows(11).any(|v| v == b"TBOX_READY:"),
            observed
                .windows(fixture.namespace.path().as_os_str().len())
                .any(|v| v == fixture.namespace.path().as_os_str().as_encoded_bytes()),
            observed.windows(6).any(|v| v == b":unset")
        );
        check.close().await.unwrap();
        fixture
    }
    fn command(&self, args: &[&str]) -> std::process::Output {
        Command::new("tmux")
            .arg("-S")
            .arg(&self.socket)
            .arg("-f")
            .arg("/dev/null")
            .args(args)
            .env("HOME", self.server.dir.path())
            .output()
            .unwrap()
    }
    fn seed(&self) {
        assert!(
            self.command(&[
                "new-session",
                "-d",
                "-s",
                "fixture",
                "/bin/bash",
                "--noprofile",
                "--norc"
            ])
            .status
            .success()
        );
        assert!(
            self.command(&["set-window-option", "-g", "window-size", "latest"])
                .status
                .success()
        );
    }
    fn window_size(&self) -> String {
        let output = self.command(&[
            "display-message",
            "-p",
            "-t",
            "fixture:",
            "#{window_width}x#{window_height}",
        ]);
        assert!(output.status.success());
        String::from_utf8(output.stdout).unwrap().trim().to_owned()
    }
    async fn connect(&self, readonly: bool, columns: u16, rows: u16) -> SshConnection {
        let (tx, mut rx) = mpsc::channel(1);
        let mut config = self.server.config.clone();
        config.columns = columns;
        config.rows = rows;
        config.tmux = Some(Policy { requests: tx });
        let future = SshConnection::connect(
            config,
            self.server.auth(),
            self.server.pinned(),
            CancellationToken::new(),
        );
        tokio::pin!(future);
        let request = tokio::select! {
            value=&mut future=>panic!("tmux connection ended before choice: {}", value.err().map(|e|e.to_string()).unwrap_or_default()),
            value=rx.recv()=>value.unwrap(),
        };
        let target = request
            .listing
            .sessions
            .iter()
            .find(|s| s.name == "fixture")
            .expect("isolated fixture session")
            .id
            .clone();
        request
            .reply
            .send(Choice::Attach {
                id: target,
                readonly,
                takeover_confirmed: !readonly,
                lock_size: false,
                ensure_locale: false,
            })
            .ok()
            .unwrap();
        future.await.unwrap()
    }
}
async fn output_until(connection: &mut SshConnection, marker: &[u8]) -> Vec<u8> {
    timeout(Duration::from_secs(8), async {
        let mut output = Vec::new();
        loop {
            match connection.read().await.unwrap() {
                PtyEvent::Data(bytes) => {
                    output.extend(bytes);
                    assert!(output.len() < 2 * 1024 * 1024);
                    if output.windows(marker.len()).any(|s| s == marker) {
                        break output;
                    }
                }
                PtyEvent::End => panic!("fixture PTY ended before its marker"),
                _ => {}
            }
        }
    })
    .await
    .unwrap()
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_control_and_readonly_attach_share_one_session_but_only_control_sets_size_and_input()
 {
    let f = Fixture::new().await;
    f.seed();
    let mut control = f.connect(false, 90, 28).await;
    control
        .write(b"printf '%s%s\\n' CONTROL_ READY\n")
        .await
        .unwrap();
    output_until(&mut control, b"CONTROL_READY").await;
    let before = f.window_size();
    assert!(before.starts_with("90x"));
    let mut viewer = f.connect(true, 150, 50).await;
    assert!(viewer.tmux_state().unwrap().readonly);
    viewer.resize(200, 60).await.unwrap();
    let forbidden = f.namespace.path().join("viewer-must-not-write");
    viewer
        .write(format!("touch '{}'\n", forbidden.display()).as_bytes())
        .await
        .unwrap();
    control
        .write(b"printf '%s%s\\n' BOTH_ SEE\n")
        .await
        .unwrap();
    output_until(&mut control, b"BOTH_SEE").await;
    output_until(&mut viewer, b"BOTH_SEE").await;
    assert!(!forbidden.exists());
    assert_eq!(f.window_size(), before);
    // An explicit new control attachment takes over without executing a shell
    // command in either old PTY, and preserves the tmux session itself.
    let mut next = f.connect(false, 100, 30).await;
    next.write(b"printf '%s%s\\n' TAKEOVER_ READY\n")
        .await
        .unwrap();
    output_until(&mut next, b"TAKEOVER_READY").await;
    assert!(f.window_size().starts_with("100x"));
    control.close().await.unwrap();
    viewer.close().await.unwrap();
    next.close().await.unwrap();
    assert!(
        f.command(&["has-session", "-t", "fixture"])
            .status
            .success()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancel_and_unconfirmed_takeover_never_fall_back_to_shell_and_user_wait_excludes_network_budget()
 {
    let f = Fixture::new().await;
    f.seed();
    for kind in [0, 1, 2] {
        let (tx, mut rx) = mpsc::channel::<Request>(1);
        let mut config = f.server.config.clone();
        config.timeout = Duration::from_secs(2);
        config.tmux = Some(Policy { requests: tx });
        let stop = CancellationToken::new();
        let future =
            SshConnection::connect(config, f.server.auth(), f.server.pinned(), stop.clone());
        tokio::pin!(future);
        let request = tokio::select! {
            value=&mut future=>panic!("connection ended before fixture choice: {}",value.err().map(|e|e.to_string()).unwrap_or_default()),
            value=rx.recv()=>value.unwrap(),
        };
        if kind == 0 {
            stop.cancel();
            assert!(matches!(
                timeout(Duration::from_secs(1), future).await.unwrap(),
                Err(SshError::Cancelled)
            ));
        } else if kind == 1 {
            let id = request.listing.sessions[0].id.clone();
            request
                .reply
                .send(Choice::Attach {
                    id,
                    readonly: false,
                    takeover_confirmed: false,
                    lock_size: false,
                    ensure_locale: false,
                })
                .ok()
                .unwrap();
            assert!(matches!(future.await, Err(SshError::Tmux(_))));
        } else {
            tokio::time::sleep(Duration::from_secs(3)).await;
            request.reply.send(Choice::Shell).ok().unwrap();
            let mut shell = future.await.unwrap();
            assert!(shell.tmux_state().is_none());
            shell
                .write(b"printf '%s%s\\n' EXPLICIT_ SHELL\n")
                .await
                .unwrap();
            output_until(&mut shell, b"EXPLICIT_SHELL").await;
            shell.close().await.unwrap();
        }
        assert!(
            f.command(&["has-session", "-t", "fixture"])
                .status
                .success()
        );
    }
}
