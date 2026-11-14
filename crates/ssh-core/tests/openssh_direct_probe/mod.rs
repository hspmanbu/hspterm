//! Private source/target servers and disposable app-owned keys only.
use super::*;
mod late;
use hspterm_ssh_core::{AgentPhase, direct_transfer::ProbeStatus};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn direct_probe_uses_only_explicit_original_agent_and_pinned_target_without_pty_input() {
    // Unified validation prerequisite: system ssh, rsync and python3. This is
    // not skipped/mapped to success if the environment lacks those tools.
    let first = Server::start().await;
    let second = Server::start().await;
    let mut source_config = first.config.clone();
    source_config.agent_forwarding = true;
    let mut source = SshConnection::connect(
        source_config,
        first.auth(),
        first.pinned(),
        CancellationToken::new(),
    )
    .await
    .unwrap();
    let mut target = second.connect().await;
    let endpoint = target.verified_host_key().clone();
    let connector = source.direct_connector();
    let agent = source.agent_connector();
    assert_eq!(agent.status().phase, AgentPhase::Ready);
    assert!(
        connector
            .probe(
                &endpoint,
                &second.config.username,
                agent.status().epoch,
                CancellationToken::new()
            )
            .await
            .is_err()
    );
    // Explicit copy with source socket opt-in needs no general Agent key
    // grant. Only the saved destination credential is selected for this task.
    let scoped = connector.with_authentication(second.auth()).await.unwrap();
    assert_eq!(agent.status().phase, AgentPhase::Ready);
    assert_eq!(
        scoped
            .probe(
                &endpoint,
                &second.config.username,
                scoped.authentication_epoch(),
                CancellationToken::new()
            )
            .await
            .unwrap(),
        ProbeStatus::Available
    );
    drop(scoped);
    assert_eq!(agent.status().phase, AgentPhase::Ready);
    assert!(
        connector
            .probe(
                &endpoint,
                &second.config.username,
                agent.status().epoch,
                CancellationToken::new()
            )
            .await
            .is_err()
    );
    let private = Zeroizing::new(fs::read_to_string(second.dir.path().join("client")).unwrap());
    let key = russh::keys::decode_secret_key(&private, Some("test-only-key-passphrase")).unwrap();
    let grant = agent
        .authorise(agent.status().epoch, vec![key], Duration::from_secs(300))
        .await
        .unwrap();
    assert_eq!(
        connector
            .probe(
                &endpoint,
                &second.config.username,
                grant.epoch,
                CancellationToken::new()
            )
            .await
            .unwrap(),
        ProbeStatus::Available
    );
    // Exercise the actual direct body path and the existing publish state
    // machine. Only a dedicated fixture payload is copied, never server keys.
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        direct_transfer::DirectRoute,
        remote_tree::{RemoteTree, StagingPhase},
        tree_transfer::TreeOutcome,
    };
    let source_path = first.dir.path().join("payload '$ 中文.bin");
    let final_path = second.dir.path().join("published '$ 中文.bin");
    let body: Vec<u8> = (0..262_147).map(|i| (i % 251) as u8).collect();
    fs::write(&source_path, &body).unwrap();
    let a = source.open_sftp().await.unwrap();
    let b = target.open_sftp().await.unwrap();
    let route = DirectRoute::new(
        connector.clone(),
        endpoint.clone(),
        second.config.username.clone(),
        grant.epoch,
        false,
    )
    .unwrap();
    let mut tree = RemoteTree::scan(
        &a,
        &b,
        source_path.to_str().unwrap().into(),
        final_path.to_str().unwrap().into(),
        false,
        "0123456789abcdef0123456789abcdef".into(),
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    let mut phases = Vec::new();
    let budget = BandwidthLimiter::default();
    let outcome = tree
        .run_parallel_with_direct(
            &a,
            &b,
            &CancellationToken::new(),
            &budget,
            &budget,
            3,
            Some(&route),
            |plan, _, _| {
                phases.push(plan.stages[0]);
                Ok(())
            },
        )
        .await
        .unwrap();
    assert_eq!(outcome, TreeOutcome::Complete);
    assert_eq!(fs::read(&final_path).unwrap(), body);
    assert_eq!(fs::read(&source_path).unwrap(), body);
    assert!(
        phases.contains(&StagingPhase::Intent)
            && phases.contains(&StagingPhase::Ready)
            && phases.contains(&StagingPhase::Published)
    );
    assert!(!route.used_relay());
    route.wait_idle().await;
    assert!(route.is_idle());
    // A pause at the durable pre-write barrier creates no marker/body. Explicit
    // continuation can then start the untouched file with the same task name.
    let paused_target = second.dir.path().join("paused-direct.bin");
    let stop = CancellationToken::new();
    let mut paused = RemoteTree::scan(
        &a,
        &b,
        source_path.to_str().unwrap().into(),
        paused_target.to_str().unwrap().into(),
        false,
        "1123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    let first = paused
        .run_parallel_with_direct(
            &a,
            &b,
            &stop,
            &budget,
            &budget,
            3,
            Some(&route),
            |plan, _, _| {
                if plan.stages[0] == StagingPhase::Intent {
                    stop.cancel();
                }
                Ok(())
            },
        )
        .await
        .unwrap();
    assert_eq!(first, TreeOutcome::Paused);
    assert!(!paused_target.exists());
    assert!(!std::path::Path::new(&paused.staging_path(0).unwrap()).exists());
    assert_eq!(
        paused
            .run_parallel_with_direct(
                &a,
                &b,
                &CancellationToken::new(),
                &budget,
                &budget,
                3,
                Some(&route),
                |_, _, _| Ok(())
            )
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(fs::read(paused_target).unwrap(), body);
    // Lost local Ready persistence: keep the last durable Direct claim, while
    // receiver has really completed and fsynced its authenticated receipt.
    let recovered_target = second.dir.path().join("recover-direct.bin");
    let mut interrupted = RemoteTree::scan(
        &a,
        &b,
        source_path.to_str().unwrap().into(),
        recovered_target.to_str().unwrap().into(),
        false,
        "2123456789abcdef0123456789abcdef".into(),
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    let mut durable_claim = None;
    let result = interrupted
        .run_parallel_with_direct(
            &a,
            &b,
            &CancellationToken::new(),
            &budget,
            &budget,
            3,
            Some(&route),
            |plan, _, _| {
                if matches!(plan.stages[0], StagingPhase::Direct { .. }) {
                    durable_claim = Some(plan.clone());
                }
                if plan.stages[0] == StagingPhase::Ready {
                    return Err(hspterm_ssh_core::remote_tree::RemoteTreeError::Checkpoint);
                }
                Ok(())
            },
        )
        .await;
    assert!(result.is_err());
    let mut recovered = durable_claim.unwrap();
    assert!(!recovered_target.exists());
    // A completed receipt must recover without reading the original again.
    let moved_source = source_path.with_extension("saved-fixture");
    fs::rename(&source_path, &moved_source).unwrap();
    assert_eq!(
        recovered
            .run_parallel_with_direct(
                &a,
                &b,
                &CancellationToken::new(),
                &budget,
                &budget,
                3,
                Some(&route),
                |_, _, _| Ok(())
            )
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(fs::read(&recovered_target).unwrap(), body);
    fs::rename(&moved_source, &source_path).unwrap();
    // Deterministic partial-basis fixture: the original fixed receiver claims
    // with a controlled failed local tool, then this fixture writes a private
    // partial basis. The recovery below uses actual rsync over both OpenSSH
    // servers; this setup is NOT a simulated real network interruption.
    let delta_target = second.dir.path().join("delta-recovered-direct.bin");
    let mut delta = RemoteTree::scan(
        &a,
        &b,
        source_path.to_str().unwrap().into(),
        delta_target.to_str().unwrap().into(),
        false,
        "3123456789abcdef0123456789abcdef".into(),
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    let nonce = [0x71u8; 32];
    let staged = delta.staging_path(0).unwrap();
    fs::write(&staged, nonce).unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&staged, fs::Permissions::from_mode(0o600)).unwrap();
    }
    let fixed = format!(
        "{}\n{}",
        include_str!("../../src/direct_transfer/receipt.py"),
        include_str!("../../src/direct_transfer/receiver.py")
    );
    // Synthetic nonce and fixture-only path/body. No production credentials.
    let setup = r#"import base64,json,sys
code,path,size,nonce=sys.argv[1:]
g={'__name__':'fixture'}
exec(compile(code,'<fixture-receiver>','exec'),g)
g['shutil'].which=lambda *a,**k:'/bin/false'
payload={'staged':path,'bytes':int(size),'nonce':nonce,'attempt':1,'previous':None}
sys.argv=['fixture',base64.b64encode(json.dumps(payload).encode()).decode(),'--server']
assert g['main']()!=0
with open(path,'r+b') as partial:
    partial.write(b'controlled-wrong-basis'*1024)
"#;
    {
        use base64::Engine;
        let prepared = std::process::Command::new("/usr/bin/python3")
            .args([
                "-I",
                "-S",
                "-c",
                setup,
                &fixed,
                &staged,
                &body.len().to_string(),
                &base64::engine::general_purpose::STANDARD.encode(nonce),
            ])
            .status()
            .unwrap();
        assert!(
            prepared.success(),
            "private partial fixture prerequisite failed"
        );
    }
    delta.stages[0] = StagingPhase::Direct { nonce, attempt: 1 };
    delta.validate().unwrap();
    let mut attempts = Vec::new();
    assert_eq!(
        delta
            .run_parallel_with_direct(
                &a,
                &b,
                &CancellationToken::new(),
                &budget,
                &budget,
                3,
                Some(&route),
                |plan, _, _| {
                    if let StagingPhase::Direct { attempt, .. } = plan.stages[0] {
                        attempts.push(attempt);
                    }
                    Ok(())
                },
            )
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert!(attempts.contains(&2));
    assert_eq!(fs::read(&delta_target).unwrap(), body);
    assert_eq!(fs::read(&source_path).unwrap(), body);
    assert!(!route.used_relay());
    a.close().await.unwrap();
    b.close().await.unwrap();
    let mut changed = endpoint.clone();
    changed.sha256 = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".into();
    assert_eq!(
        connector
            .probe(
                &changed,
                &second.config.username,
                grant.epoch,
                CancellationToken::new()
            )
            .await
            .unwrap(),
        ProbeStatus::AuthenticationFailed
    );
    agent.revoke().await.unwrap();
    assert!(
        connector
            .probe(
                &endpoint,
                &second.config.username,
                grant.epoch,
                CancellationToken::new()
            )
            .await
            .is_err()
    );
    source
        .write(b"printf '%s%s\\n' DIRECT_ PTY_ALIVE\n")
        .await
        .unwrap();
    let mut terminal = Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap();
    until_text(&mut source, &mut terminal, "DIRECT_PTY_ALIVE").await;
    source.close().await.unwrap();
    assert!(
        connector
            .probe(
                &endpoint,
                &second.config.username,
                grant.epoch,
                CancellationToken::new()
            )
            .await
            .is_err()
    );
    target.close().await.unwrap();
}
