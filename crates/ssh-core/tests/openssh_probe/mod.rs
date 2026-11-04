use super::*;
use hspterm_ssh_core::{ManagedSession, SessionPhase};
use std::sync::Arc;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn managed_probe_never_authenticates_or_creates_pty_and_retains_disconnected_history() {
    let server = Server::start().await;
    let (session, _events) = ManagedSession::new(Size::new(80, 24).unwrap(), 100).unwrap();
    let mut config = server.config.clone();
    config.username = "synthetic-account-that-does-not-exist".into();
    let before = session.snapshot().unwrap();
    session
        .test_connection(config.clone(), server.pinned())
        .await
        .unwrap();
    assert_eq!(session.status().phase, SessionPhase::Idle);
    assert_eq!(session.status().generation, 1);
    let after = session.snapshot().unwrap();
    assert_eq!(before.text(), after.text());
    assert_eq!(before.revision, after.revision);
    assert!(matches!(
        session.write(b"must-not-send".to_vec()).await,
        Err(SshError::Disconnected)
    ));
    assert!(matches!(
        session.open_sftp().await,
        Err(SshError::Disconnected)
    ));

    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    assert!(matches!(
        session
            .test_connection(config.clone(), server.pinned())
            .await,
        Err(SshError::Busy)
    ));
    session
        .write(b"printf '%s%s\\n' PROBE_ HISTORY\n".to_vec())
        .await
        .unwrap();
    timeout(Duration::from_secs(5), async {
        let mut frames = session.subscribe_frames();
        while !session.snapshot().unwrap().text().contains("PROBE_HISTORY") {
            frames.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
    session.disconnect().await.unwrap();
    let before = session.snapshot().unwrap();
    session
        .test_connection(config.clone(), server.pinned())
        .await
        .unwrap();
    assert_eq!(session.status().phase, SessionPhase::Disconnected);
    assert_eq!(session.snapshot().unwrap().text(), before.text());
    assert_eq!(session.snapshot().unwrap().revision, before.revision);
    let result = session
        .test_connection(
            config,
            HostKeyPolicy::Pinned {
                sha256: "SHA256:changed".into(),
            },
        )
        .await;
    assert!(matches!(result, Err(SshError::HostKeyChanged { .. })));
    assert_eq!(session.status().phase, SessionPhase::Failed);
    assert_eq!(session.snapshot().unwrap().text(), before.text());
    session.shutdown();
    session.wait_closed().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn managed_probe_prompt_can_be_cancelled_dropped_or_closed_without_retaining_a_transport() {
    let server = Server::start().await;
    let (session, _events) = ManagedSession::new(Size::new(80, 24).unwrap(), 0).unwrap();
    let session = Arc::new(session);
    for action in 0..3 {
        let (requests, mut receiver) = mpsc::channel(1);
        let s = session.clone();
        let config = server.config.clone();
        let attempt = tokio::spawn(async move {
            s.test_connection(config, HostKeyPolicy::Confirm { requests })
                .await
        });
        let request = timeout(Duration::from_secs(5), receiver.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(session.status().phase, SessionPhase::Connecting);
        match action {
            0 => {
                session.cancel_connect();
                assert!(matches!(attempt.await.unwrap(), Err(SshError::Cancelled)));
            }
            1 => {
                // Aborting this caller must cancel its exact probe, not the
                // next attempt belonging to the same ManagedSession.
                attempt.abort();
                assert!(attempt.await.unwrap_err().is_cancelled());
            }
            _ => {
                session.shutdown();
                assert!(matches!(attempt.await.unwrap(), Err(SshError::Cancelled)));
            }
        }
        drop(request);
        timeout(Duration::from_secs(2), async {
            let mut changes = session.subscribe();
            while changes.borrow_and_update().phase == SessionPhase::Connecting {
                changes.changed().await.unwrap();
            }
        })
        .await
        .unwrap();
        assert_ne!(session.status().phase, SessionPhase::Connected);
    }
    session.wait_closed().await;
    assert_eq!(session.status().phase, SessionPhase::Closed);
}

mod receipt;
