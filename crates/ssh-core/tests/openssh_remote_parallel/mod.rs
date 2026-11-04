//! Source-only until the project's final unified validation run.
use super::*;
use hspterm_ssh_core::{
    bandwidth::BandwidthLimiter,
    remote_tree::{RemoteTree, RemoteTreeError, StagingPhase},
    tree_transfer::{NodeKind, NodeState, TreeOutcome},
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn parallel_relay_keeps_unique_staging_indices_ack_offsets_and_original_transports() {
    let server = Server::start().await;
    let mut source_ssh = server.connect().await;
    let mut target_ssh = server.connect().await;
    let a = source_ssh.open_sftp().await.unwrap();
    let b = target_ssh.open_sftp().await.unwrap();
    let source = server.dir.path().join("parallel relay source");
    let target = server.dir.path().join("parallel relay destination");
    fs::create_dir_all(source.join("empty/nested")).unwrap();
    let bytes: Vec<_> = (0..512 * 1024).map(|n| (n % 251) as u8).collect();
    fs::write(source.join("00-empty"), b"").unwrap();
    for i in 0..6 {
        fs::write(source.join(format!("file-{i} 中文 e\u{301}.bin")), &bytes).unwrap();
    }
    let stop = CancellationToken::new();
    let budget = BandwidthLimiter::new(128 * 1024);
    let mut plan = RemoteTree::scan(
        &a,
        &b,
        source.to_str().unwrap().into(),
        target.to_str().unwrap().into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    let mut opened = 0;
    let outcome =
        timeout(
            Duration::from_secs(20),
            plan.run_parallel_observed(&a, &b, &stop, &budget, &budget, 3, |p, event, active| {
                assert_eq!(event.stats, p.stats());
                p.validate().unwrap();
                assert!(active.len() <= 3);
                assert!(active.iter().all(|i| p.nodes[*i].kind == NodeKind::File
                    && p.nodes[*i].state == NodeState::Pending));
                let writing = active
                    .iter()
                    .filter(|i| p.stages[**i] == StagingPhase::Writing)
                    .count();
                opened = opened.max(writing);
                if writing == 3 && event.stats.acknowledged >= 65536 {
                    stop.cancel();
                }
                Ok(())
            }),
        )
        .await
        .unwrap()
        .unwrap();
    assert_eq!(outcome, TreeOutcome::Paused);
    assert_eq!(
        opened, 3,
        "three real private file streams must be in progress"
    );
    plan.validate().unwrap();
    let before: Vec<_> = plan
        .nodes
        .iter()
        .enumerate()
        .map(|(i, _)| plan.staging_path(i).unwrap())
        .collect();
    for (i, node) in plan
        .nodes
        .iter()
        .enumerate()
        .filter(|(_, n)| n.kind == NodeKind::File)
    {
        if node.state == NodeState::Complete {
            fs::remove_file(source.join(&node.relative)).unwrap();
        } else if node.started {
            let partial = fs::read(&before[i]).unwrap();
            assert_eq!(
                &partial[..node.acknowledged as usize],
                &bytes[..node.acknowledged as usize]
            );
        }
    }
    let mut restored: RemoteTree =
        serde_json::from_slice(&serde_json::to_vec(&plan).unwrap()).unwrap();
    let no_limit = BandwidthLimiter::default();
    assert_eq!(
        restored
            .run_parallel_observed(
                &a,
                &b,
                &CancellationToken::new(),
                &no_limit,
                &no_limit,
                3,
                |p, event, active| {
                    assert_eq!(event.stats, p.stats());
                    assert!(active.len() <= 3);
                    for (i, expected) in before.iter().enumerate() {
                        assert_eq!(&p.staging_path(i).unwrap(), expected);
                    }
                    Ok(())
                }
            )
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert!(target.join("empty/nested").is_dir());
    assert_eq!(fs::read(target.join("00-empty")).unwrap(), b"");
    for i in 0..6 {
        assert_eq!(
            fs::read(target.join(format!("file-{i} 中文 e\u{301}.bin"))).unwrap(),
            bytes
        );
    }
    assert!(!source_ssh.is_closed() && !target_ssh.is_closed());
    a.close().await.unwrap();
    b.close().await.unwrap();
    source_ssh.close().await.unwrap();
    target_ssh.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_parent_does_not_write_its_children_or_stop_independent_relay_files() {
    let server = Server::start().await;
    let mut ssh = server.connect().await;
    let a = ssh.open_sftp().await.unwrap();
    let b = ssh.open_sftp().await.unwrap();
    let source = server.dir.path().join("relay failed parent source");
    let target = server.dir.path().join("relay failed parent target");
    fs::create_dir_all(source.join("blocked/deep")).unwrap();
    fs::create_dir(&target).unwrap();
    fs::write(target.join("blocked"), b"preserved obstacle").unwrap();
    fs::write(source.join("blocked/deep/never"), b"must not write").unwrap();
    for i in 0..4 {
        fs::write(source.join(format!("ok-{i}")), vec![i as u8; 65536]).unwrap();
    }
    let stop = CancellationToken::new();
    let budget = BandwidthLimiter::default();
    let mut plan = RemoteTree::scan(
        &a,
        &b,
        source.to_str().unwrap().into(),
        target.to_str().unwrap().into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(
        plan.run_parallel_observed(&a, &b, &stop, &budget, &budget, 3, |p, e, _| {
            assert_eq!(e.stats, p.stats());
            Ok(())
        })
        .await
        .unwrap(),
        TreeOutcome::Partial
    );
    assert_eq!(
        fs::read(target.join("blocked")).unwrap(),
        b"preserved obstacle"
    );
    assert_eq!(
        plan.nodes
            .iter()
            .find(|n| n.relative == "blocked/deep/never")
            .unwrap()
            .state,
        NodeState::Failed
    );
    for i in 0..4 {
        assert_eq!(
            fs::read(target.join(format!("ok-{i}"))).unwrap(),
            vec![i as u8; 65536]
        );
    }
    a.close().await.unwrap();
    b.close().await.unwrap();
    ssh.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn failed_parallel_intent_barrier_stops_and_drains_every_worker_before_return() {
    let server = Server::start().await;
    let mut ssh = server.connect().await;
    let a = ssh.open_sftp().await.unwrap();
    let b = ssh.open_sftp().await.unwrap();
    let source = server.dir.path().join("relay checkpoint source");
    let target = server.dir.path().join("relay checkpoint target");
    fs::create_dir(&source).unwrap();
    for i in 0..5 {
        fs::write(source.join(format!("file-{i}")), vec![i as u8; 65536]).unwrap();
    }
    let stop = CancellationToken::new();
    let budget = BandwidthLimiter::default();
    let mut plan = RemoteTree::scan(
        &a,
        &b,
        source.to_str().unwrap().into(),
        target.to_str().unwrap().into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    let mut rejected = false;
    let result = plan
        .run_parallel_observed(&a, &b, &stop, &budget, &budget, 3, |p, e, _| {
            assert!(
                !rejected,
                "failed persistence barrier must not be retried by sibling callbacks"
            );
            if p.stages[e.index] == StagingPhase::Intent {
                rejected = true;
                return Err(RemoteTreeError::Checkpoint);
            }
            Ok(())
        })
        .await;
    assert!(matches!(result, Err(RemoteTreeError::Checkpoint)));
    assert!(rejected);
    plan.validate().unwrap();
    for (i, node) in plan
        .nodes
        .iter()
        .enumerate()
        .filter(|(_, n)| n.kind == NodeKind::File)
    {
        assert!(!target.join(&node.relative).exists());
        assert!(!Path::new(&plan.staging_path(i).unwrap()).exists());
        assert!(!node.started);
    }
    a.close().await.unwrap();
    b.close().await.unwrap();
    ssh.close().await.unwrap();
}
