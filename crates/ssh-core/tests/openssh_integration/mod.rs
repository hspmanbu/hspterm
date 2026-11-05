//! Isolated loopback SSH + private HOME, no accounts or user startup secrets.
use super::*;
use hspterm_ssh_core::{ManagedSession, TerminalInput, integration::Launch};
use hspterm_term_core::{Key, KeyEvent};
use std::sync::{Arc, Mutex};

async fn until(label: &str, mut condition: impl FnMut() -> bool) {
    timeout(Duration::from_secs(8), async {
        while !condition() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect(label);
}
fn output_line(session: &ManagedSession, text: &str) -> bool {
    session
        .snapshot()
        .unwrap()
        .text()
        .lines()
        .any(|line| line == text)
}
async fn line(session: &ManagedSession, text: &str) {
    session
        .input(TerminalInput::Text(text.into()))
        .await
        .unwrap();
    session
        .input(TerminalInput::Key(KeyEvent::press(Key::Enter)))
        .await
        .unwrap();
}
async fn open(
    server: &Server,
) -> (
    ManagedSession,
    tokio::task::JoinHandle<()>,
    Arc<Mutex<Vec<String>>>,
) {
    fs::write(
        server.dir.path().join(".bashrc"),
        "PS1='isolated> '; PROMPT_COMMAND=()\n",
    )
    .unwrap();
    let (session, mut events) = ManagedSession::new(Size::new(80, 12).unwrap(), 100).unwrap();
    let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
    let recorded = Arc::new(Mutex::new(Vec::new()));
    let target = recorded.clone();
    session.set_history_sink(Some(Arc::new(move |_, submissions| {
        let target = target.clone();
        Box::pin(async move {
            target
                .lock()
                .unwrap()
                .extend(submissions.iter().map(|s| s.text.to_string()));
            true
        })
    })));
    let mut config = server.config.clone();
    config.integration = Some(Launch::fresh());
    session
        .connect(config, server.auth(), server.pinned())
        .await
        .unwrap();
    (session, drain, recorded)
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_bash_integration_qualifies_actual_single_enter_unicode_input() {
    let server = Server::start().await;
    let (session, drain, recorded) = open(&server).await;
    until("initial Unicode prompt", || {
        session.integration_proof().is_some()
    })
    .await;
    let command = "printf '%s\\n' 'HSP_中文_READY'";
    line(&session, command).await;
    until("Unicode submission acknowledgement", || {
        recorded.lock().unwrap().len() == 1
    })
    .await;
    assert_eq!(recorded.lock().unwrap().as_slice(), &[command.to_owned()]);
    until("Unicode command output", || {
        output_line(&session, "HSP_中文_READY")
    })
    .await;
    assert!(!session.snapshot().unwrap().text().contains("HSP1;"));
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn missing_bash_probe_falls_back_to_normal_shell_on_the_same_transport() {
    let server = Server::start_with_host_key(
        true,
        true,
        "ed25519",
        "SetEnv PATH=/hspterm-fixture-missing-bin",
    )
    .await;
    let (session, drain, recorded) = open(&server).await;
    let generation = session.status().generation;
    line(&session, "printf 'HSP_FALLBACK_OK\\n'").await;
    until("ordinary fallback output", || {
        output_line(&session, "HSP_FALLBACK_OK")
    })
    .await;
    assert!(session.integration_proof().is_none());
    assert!(recorded.lock().unwrap().is_empty());
    assert_eq!(session.status().generation, generation);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn hidden_read_input_never_qualifies_or_enters_the_visible_buffer() {
    let server = Server::start().await;
    let (session, drain, recorded) = open(&server).await;
    until("initial hidden-input prompt", || {
        session.integration_proof().is_some()
    })
    .await;
    line(
        &session,
        "stty -echo; printf 'HSP_READING\\n'; IFS= read -r fixture_input; stty echo; printf '\\nHSP_READ_DONE\\n'",
    )
    .await;
    until("hidden read relinquishes proof", || {
        output_line(&session, "HSP_READING") && session.integration_proof().is_none()
    })
    .await;
    line(&session, "synthetic-hidden-input").await;
    until("prompt after hidden read", || {
        session.integration_proof().is_some()
    })
    .await;
    assert!(
        !recorded
            .lock()
            .unwrap()
            .iter()
            .any(|line| line.contains("synthetic-hidden-input"))
    );
    assert!(
        !session
            .snapshot()
            .unwrap()
            .text()
            .contains("synthetic-hidden-input")
    );
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn controlled_fill_is_not_enter_and_explicit_run_is_exactly_once() {
    use hspterm_ssh_core::{IntegratedEdit, IntegratedOutcome};
    let server = Server::start().await;
    let (session, drain, recorded) = open(&server).await;
    until("initial controlled-edit prompt", || {
        session.integration_proof().is_some()
    })
    .await;
    session
        .input(TerminalInput::Text("printf old".into()))
        .await
        .unwrap();
    let proof = session.integration_proof().unwrap();
    let command = "printf '%s\\n' 'HSP_FILLED_ONCE' '中文 é'";
    assert_eq!(
        session
            .apply_integrated(
                session.status().generation,
                proof,
                IntegratedEdit::Replace,
                Zeroizing::new(command.into()),
                false,
                None
            )
            .await
            .unwrap(),
        IntegratedOutcome::Applied
    );
    assert!(!output_line(&session, "HSP_FILLED_ONCE"));
    assert!(recorded.lock().unwrap().is_empty());
    session
        .input(TerminalInput::Key(KeyEvent::press(Key::Enter)))
        .await
        .unwrap();
    until("filled Unicode line accepted once", || {
        output_line(&session, "HSP_FILLED_ONCE") && recorded.lock().unwrap().len() == 1
    })
    .await;
    assert_eq!(recorded.lock().unwrap().as_slice(), &[command.to_owned()]);
    until("prompt after filled line", || {
        session.integration_proof().is_some()
    })
    .await;
    let proof = session.integration_proof().unwrap();
    assert_eq!(
        session
            .apply_integrated(
                session.status().generation,
                proof,
                IntegratedEdit::Execute,
                Zeroizing::new("printf '%s\\n' 'HSP_EXECUTED_ONCE' '中文 é'".into()),
                false,
                None
            )
            .await
            .unwrap(),
        IntegratedOutcome::Applied
    );
    until("explicit Unicode execution output", || {
        output_line(&session, "HSP_EXECUTED_ONCE")
    })
    .await;
    assert!(matches!(
        session
            .apply_integrated(
                session.status().generation,
                proof,
                IntegratedEdit::Execute,
                Zeroizing::new("printf 'HSP_MUST_NOT_RUN\\n'".into()),
                false,
                None
            )
            .await,
        Err(SshError::IntegrationUnavailable)
    ));
    assert!(!output_line(&session, "HSP_MUST_NOT_RUN"));
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cd_on_nonempty_input_and_revoked_permission_never_erase_or_execute() {
    use hspterm_ssh_core::IntegratedEdit;
    let server = Server::start().await;
    let (session, drain, _) = open(&server).await;
    until("initial cd safety prompt", || {
        session.integration_proof().is_some()
    })
    .await;
    session
        .input(TerminalInput::Text("printf ".into()))
        .await
        .unwrap();
    let proof = session.integration_proof().unwrap();
    for (require_empty, permission) in [
        (true, None),
        (
            false,
            Some(Arc::new(|| false) as Arc<dyn Fn() -> bool + Send + Sync>),
        ),
    ] {
        assert!(matches!(
            session
                .apply_integrated(
                    session.status().generation,
                    proof,
                    IntegratedEdit::Execute,
                    Zeroizing::new("cd '/tmp'".into()),
                    require_empty,
                    permission
                )
                .await,
            Err(SshError::IntegrationUnavailable)
        ));
        assert_eq!(session.integration_proof(), Some(proof));
    }
    line(&session, "'HSP_PREFIX_PRESERVED\\n'").await;
    until("original prefix preserved", || {
        output_line(&session, "HSP_PREFIX_PRESERVED")
    })
    .await;
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn actual_readline_mismatch_makes_the_queued_execute_key_a_noop() {
    use hspterm_ssh_core::{IntegratedEdit, IntegratedOutcome};
    let server = Server::start().await;
    fs::write(
        server.dir.path().join(".bashrc"),
        "PS1='isolated> '; PROMPT_COMMAND=(); builtin bind '\"x\":\"xx\"'\n",
    )
    .unwrap();
    let (session, mut events) = ManagedSession::new(Size::new(80, 12).unwrap(), 100).unwrap();
    let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
    let mut config = server.config.clone();
    config.integration = Some(Launch::fresh());
    session
        .connect(config, server.auth(), server.pinned())
        .await
        .unwrap();
    until("initial mismatch prompt", || {
        session.integration_proof().is_some()
    })
    .await;
    session
        .input(TerminalInput::Text("x".into()))
        .await
        .unwrap();
    let proof = session.integration_proof().unwrap();
    assert_eq!(
        session
            .apply_integrated(
                session.status().generation,
                proof,
                IntegratedEdit::Execute,
                Zeroizing::new("printf 'HSP_REJECTED_EXEC\\n'".into()),
                false,
                None
            )
            .await
            .unwrap(),
        IntegratedOutcome::Unconfirmed
    );
    assert!(!output_line(&session, "HSP_REJECTED_EXEC"));
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn unsupported_allexport_keeps_shell_without_private_helper_environment() {
    let server = Server::start().await;
    fs::write(
        server.dir.path().join(".bashrc"),
        "PS1='isolated> '; PROMPT_COMMAND=(); set -a\n",
    )
    .unwrap();
    let (session, mut events) = ManagedSession::new(Size::new(80, 12).unwrap(), 100).unwrap();
    let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
    let mut config = server.config.clone();
    config.integration = Some(Launch::fresh());
    session
        .connect(config, server.auth(), server.pinned())
        .await
        .unwrap();
    until("unsupported shell fallback", || {
        session
            .snapshot()
            .unwrap()
            .text()
            .contains("optional Bash integration unavailable")
    })
    .await;
    assert!(session.integration_proof().is_none());
    line(&session, "if [[ -v __hspterm_nonce ]]; then printf 'HSP_PRIVATE_ENV_LEAK\\n'; else printf 'HSP_FALLBACK_ENV_CLEAR\\n'; fi").await;
    until("fallback leaves no helper environment", || {
        output_line(&session, "HSP_FALLBACK_ENV_CLEAR")
    })
    .await;
    assert!(session.integration_proof().is_none());
    assert!(!output_line(&session, "HSP_PRIVATE_ENV_LEAK"));
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn resized_idle_prompt_accepts_quoted_path_without_execution() {
    use hspterm_ssh_core::{IntegratedEdit, IntegratedOutcome};
    let server = Server::start().await;
    let (session, drain, recorded) = open(&server).await;
    until("ready before resize", || {
        session.integration_proof().is_some()
    })
    .await;
    for (cols, rows) in [(100, 30), (42, 16), (120, 24)] {
        session
            .resize(Size::new(cols, rows).unwrap())
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(
            session.integration_proof().is_some(),
            "resize must not revoke an idle Readline proof"
        );
    }
    let proof = session.integration_proof().unwrap();
    let quoted = "'/tmp/中文 folder/it'\\''s.txt'";
    assert_eq!(
        session
            .apply_integrated(
                session.status().generation,
                proof,
                IntegratedEdit::Insert,
                Zeroizing::new(quoted.into()),
                false,
                None
            )
            .await
            .unwrap(),
        IntegratedOutcome::Applied
    );
    assert!(
        recorded.lock().unwrap().is_empty(),
        "inserting a path must not execute it"
    );
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn opted_in_bash_reports_real_cwd_command_ranges_and_history_with_keypad_enabled() {
    let server = Server::start().await;
    let folder = server.dir.path().join("cwd space 中文");
    fs::create_dir(&folder).unwrap();
    let (session, drain, recorded) = open(&server).await;
    until("ready before keypad mode", || {
        session.integration_proof().is_some()
    })
    .await;
    let initial_prompt = session.integration_proof().unwrap().prompt;
    line(&session, "bind 'set enable-keypad on'").await;
    until("ordinary Readline keypad prompt", || {
        session
            .integration_proof()
            .is_some_and(|proof| proof.prompt > initial_prompt)
    })
    .await;
    line(
        &session,
        &format!(
            "cd -- '{}'",
            folder.to_str().unwrap().replace('\'', "'\\''")
        ),
    )
    .await;
    until("same-stream percent-decoded cwd", || {
        session
            .directory_context()
            .1
            .is_some_and(|cwd| cwd.path == folder.to_str().unwrap())
    })
    .await;
    until("ready after cwd change", || {
        session
            .integration_proof()
            .is_some_and(|proof| proof.prompt > initial_prompt + 1)
    })
    .await;
    line(&session, "printf 'HSP_PUBLIC_MARKERS\\n'").await;
    until("actual command output and persisted submissions", || {
        output_line(&session, "HSP_PUBLIC_MARKERS")
    })
    .await;
    until("all three actual single-line submissions", || {
        recorded.lock().unwrap().len() == 3
    })
    .await;
    until("complete passive command boundaries", || {
        !session.command_ranges().1.is_empty()
    })
    .await;
    assert!(session.integration_proof().is_some());
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}
