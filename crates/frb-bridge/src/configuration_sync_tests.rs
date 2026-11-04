use super::*;
fn fixture() -> (Arc<Owner>, Arc<Operation>) {
    let (changes, _) = watch::channel(0);
    let op = Arc::new(Operation {
        id: "fixture-operation".into(),
        cancel: CancellationToken::new(),
        gate: Arc::new(Semaphore::new(1)),
        pending: Mutex::new(None),
        started: AtomicBool::new(false),
        attempting_put: AtomicBool::new(false),
        remote_published: AtomicBool::new(false),
        authorization_unknown: AtomicBool::new(false),
        _permit: Arc::new(Semaphore::new(1)).try_acquire_owned().unwrap(),
    });
    let owner = Arc::new(Owner {
        status: Mutex::new(Status {
            owner: "fixture-owner".into(),
            vault_scope: "fixture-scope".into(),
            sequence: 0,
            eligible: true,
            operation: Some(op.id.clone()),
            phase: "reading",
            error: None,
            review: None,
            commits: 0,
            configuration_updates: 0,
            remote_published: false,
            write_unknown: false,
            authorization_unknown: false,
        }),
        operation: Mutex::new(Some(op.clone())),
        stop: CancellationToken::new(),
        changes,
        initial_versions: Default::default(),
    });
    (owner, op)
}
#[tokio::test]
async fn unresolved_reference_review_cannot_enter_confirm_or_publication() {
    let (root, op) = fixture();
    let id = root.status.lock().owner.clone();
    root.emit(|state| {
        state.phase = "references";
        state.review = Some(Review {
            token: "fixture-reference-review".into(),
            endpoint: "https://fixture.invalid/object".into(),
            collection: "a".repeat(32),
            summary: Default::default(),
            uploads: false,
            references: true,
        });
    });
    assert!(registry().lock().is_none());
    *registry().lock() = Some(root.clone());
    assert!(
        confirm(id.clone(), op.id.clone(), "fixture-reference-review".into())
            .await
            .is_err()
    );
    assert_eq!(root.status.lock().phase, "references");
    assert!(!op.attempting_put.load(Ordering::Acquire));
    assert!(!op.cancel.is_cancelled());
    close(id).await.unwrap();
}
#[tokio::test]
async fn abort_does_not_release_the_rpc_lease_until_a_blocking_worker_really_finishes() {
    let (root, op) = fixture();
    let lease = acquire(&root, &op).unwrap();
    let (release, held) = std::sync::mpsc::channel();
    let worker_lease = lease.clone();
    let worker = tokio::task::spawn_blocking(move || {
        let _lease = worker_lease;
        held.recv_timeout(Duration::from_secs(3)).unwrap();
    });
    drop(lease);
    assert!(op.gate.clone().try_acquire_owned().is_err());
    release.send(()).unwrap();
    worker.await.unwrap();
    assert!(op.gate.clone().try_acquire_owned().is_ok());
}
#[test]
fn late_cancel_after_commit_never_relabels_the_sql_ack_as_failure() {
    let (root, op) = fixture();
    root.operation.lock().take();
    root.emit(|s| {
        s.phase = "committed";
        s.commits = 1;
    });
    finish(&root, &op, "cancelled");
    assert_eq!(root.status.lock().phase, "committed");
    assert_eq!(root.status.lock().commits, 1);
}
#[test]
fn cancelled_put_is_explicitly_unknown_and_never_reports_success() {
    let (root, op) = fixture();
    op.attempting_put.store(true, Ordering::Release);
    op.cancel.cancel();
    finish(&root, &op, "cancelled");
    let state = root.status.lock();
    assert!(state.write_unknown);
    assert_eq!(state.phase, "cancelled");
    assert_eq!(state.commits, 0);
}
#[test]
fn uncertain_refresh_is_distinct_from_configuration_write_and_no_commit_is_fabricated() {
    let (root, op) = fixture();
    op.authorization_unknown.store(true, Ordering::Release);
    op.cancel.cancel();
    finish(&root, &op, "cancelled");
    let state = root.status.lock();
    assert!(state.authorization_unknown);
    assert!(!state.write_unknown);
    assert_eq!(state.commits, 0);
    assert_eq!(state.phase, "cancelled");
}
#[tokio::test]
async fn vault_replacement_keeps_original_worker_discoverable_until_close_drains_it() {
    let (root, op) = fixture();
    let id = root.status.lock().owner.clone();
    let lease = acquire(&root, &op).unwrap();
    assert!(registry().lock().is_none());
    *registry().lock() = Some(root.clone());
    vault_replaced();
    assert!(root.stop.is_cancelled());
    assert!(op.cancel.is_cancelled());
    assert!(owner(&id).is_ok());
    let closing = tokio::spawn(close(id.clone()));
    tokio::task::yield_now().await;
    assert!(!closing.is_finished());
    drop(lease);
    closing.await.unwrap().unwrap();
    assert!(owner(&id).is_err());
    assert!(retiring().lock().is_empty());
}
