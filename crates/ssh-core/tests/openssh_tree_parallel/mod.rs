use super::*;
use hspterm_ssh_core::{
    bandwidth::BandwidthLimiter,
    tree_transfer::{ConflictDecision, Direction, NodeKind, NodeState, TreeOutcome, TreeTransfer},
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn parallel_upload_preserves_actual_acknowledged_prefixes_and_completed_siblings_on_resume() {
    let server = Server::start().await;
    let mut ssh = server.connect().await;
    let sftp = ssh.open_sftp().await.unwrap();
    let source = server.dir.path().join("parallel-source");
    let target = server.dir.path().join("parallel-target");
    fs::create_dir_all(source.join("empty directory")).unwrap();
    fs::write(source.join("00-zero"), b"").unwrap();
    let bytes: Vec<_> = (0..512 * 1024).map(|i| (i % 251) as u8).collect();
    for i in 0..5 {
        fs::write(source.join(format!("file-{i} 中文.bin")), &bytes).unwrap();
    }
    let stop = CancellationToken::new();
    let mut tree = TreeTransfer::scan(
        Direction::Upload,
        source.clone(),
        target.to_str().unwrap().into(),
        &sftp,
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    let limiter = BandwidthLimiter::new(128 * 1024);
    let mut opened = 0usize;
    let result = timeout(
        Duration::from_secs(20),
        tree.run_parallel_observed(
            &sftp,
            &stop,
            3,
            |p, event, active| {
                assert_eq!(event.stats, p.stats());
                assert!(active.len() <= 3);
                assert!(active.iter().all(|i| p.nodes[*i].kind == NodeKind::File
                    && p.nodes[*i].state == NodeState::Pending));
                opened = opened.max(active.iter().filter(|i| p.nodes[**i].started).count());
                if opened >= 2 && event.stats.acknowledged >= 65536 {
                    stop.cancel();
                }
            },
            &limiter,
        ),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(result, TreeOutcome::Paused);
    assert!(
        opened >= 2,
        "multiple destination handles must have actually entered their streams"
    );
    tree.validate().unwrap();
    for n in tree.nodes.iter().filter(|n| n.started) {
        let actual = fs::metadata(target.join(&n.relative)).unwrap().len();
        assert!(actual >= n.acknowledged);
        if n.state == NodeState::Complete {
            assert_eq!(actual, n.size);
        }
    }
    let done: Vec<_> = tree
        .nodes
        .iter()
        .filter(|n| n.kind == NodeKind::File && n.state == NodeState::Complete)
        .map(|n| n.relative.clone())
        .collect();
    for path in &done {
        fs::remove_file(source.join(path)).unwrap();
    }
    let mut restored: TreeTransfer =
        serde_json::from_slice(&serde_json::to_vec(&tree).unwrap()).unwrap();
    assert_eq!(
        restored
            .run_parallel_observed(
                &sftp,
                &CancellationToken::new(),
                3,
                |p, e, _| assert_eq!(e.stats, p.stats()),
                &BandwidthLimiter::default()
            )
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert!(target.join("empty directory").is_dir());
    for i in 0..5 {
        assert_eq!(
            fs::read(target.join(format!("file-{i} 中文.bin"))).unwrap(),
            bytes
        );
    }
    assert_eq!(fs::metadata(target.join("00-zero")).unwrap().len(), 0);
    assert_eq!(
        restored
            .nodes
            .iter()
            .filter(|n| n.kind == NodeKind::File && n.state == NodeState::Complete)
            .count(),
        6
    );
    sftp.close().await.unwrap();
    ssh.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn parallel_download_keeps_parent_failures_local_and_serializes_aliased_destinations() {
    let server = Server::start().await;
    let mut ssh = server.connect().await;
    let sftp = ssh.open_sftp().await.unwrap();
    let source = server.dir.path().join("parallel remote");
    let target = server.dir.path().join("parallel local");
    fs::create_dir_all(source.join("blocked/nested")).unwrap();
    fs::create_dir_all(source.join("empty")).unwrap();
    fs::create_dir(&target).unwrap();
    fs::write(source.join("a"), b"first source wins").unwrap();
    fs::write(source.join("b"), b"second source stays conflict").unwrap();
    fs::write(source.join("c ' 中文"), b"unrelated success").unwrap();
    fs::write(source.join("blocked/nested/file"), b"must not escape").unwrap();
    fs::write(target.join("blocked"), b"directory obstacle").unwrap();
    let mut tree = TreeTransfer::scan(
        Direction::Download,
        target.clone(),
        source.to_str().unwrap().into(),
        &sftp,
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    for node in tree
        .nodes
        .iter_mut()
        .filter(|n| matches!(n.relative.as_str(), "a" | "b"))
    {
        node.destination_name = Some("shared target".into());
    }
    let outcome = tree
        .run_parallel_observed(
            &sftp,
            &CancellationToken::new(),
            3,
            |p, e, _| assert_eq!(e.stats, p.stats()),
            &BandwidthLimiter::default(),
        )
        .await
        .unwrap();
    assert_eq!(outcome, TreeOutcome::Partial);
    assert_eq!(
        fs::read(target.join("shared target")).unwrap(),
        b"first source wins"
    );
    assert_eq!(
        tree.nodes.iter().find(|n| n.relative == "b").unwrap().state,
        NodeState::Conflict
    );
    assert_eq!(
        tree.nodes
            .iter()
            .find(|n| n.relative == "blocked/nested/file")
            .unwrap()
            .state,
        NodeState::Failed
    );
    assert_eq!(
        fs::read(target.join("blocked")).unwrap(),
        b"directory obstacle"
    );
    assert_eq!(
        fs::read(target.join("c ' 中文")).unwrap(),
        b"unrelated success"
    );
    assert!(target.join("empty").is_dir());
    tree.validate().unwrap();
    sftp.close().await.unwrap();
    ssh.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn invalid_parallel_width_and_already_cancelled_run_cannot_create_targets() {
    let server = Server::start().await;
    let mut ssh = server.connect().await;
    let sftp = ssh.open_sftp().await.unwrap();
    let source = server.dir.path().join("parallel-width-source");
    let target = server.dir.path().join("parallel-width-target");
    fs::write(&source, b"synthetic source").unwrap();
    let mut tree = TreeTransfer::scan(
        Direction::Upload,
        source,
        target.to_str().unwrap().into(),
        &sftp,
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    for width in [0, 9] {
        assert!(
            tree.run_parallel_observed(
                &sftp,
                &CancellationToken::new(),
                width,
                |_, _, _| panic!("invalid width cannot publish progress"),
                &BandwidthLimiter::default()
            )
            .await
            .is_err()
        );
    }
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert_eq!(
        tree.run_parallel_observed(
            &sftp,
            &cancel,
            3,
            |_, _, _| panic!("cancelled start cannot publish progress"),
            &BandwidthLimiter::default()
        )
        .await
        .unwrap(),
        TreeOutcome::Paused
    );
    assert!(!target.exists());
    // Preserve the original conflict policy; setup must not change it either.
    assert_eq!(tree.nodes[0].decision, ConflictDecision::Ask);
    sftp.close().await.unwrap();
    ssh.close().await.unwrap();
}
