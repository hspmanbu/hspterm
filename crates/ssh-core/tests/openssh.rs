//! Real OpenSSH interoperability. Runs an isolated loopback sshd using temporary keys.
//! Linux prerequisites: ssh-keygen, /usr/sbin/sshd, /run/sshd and an unlocked current account.
#![cfg(target_os = "linux")]
mod openssh_agent;
mod openssh_direct_probe;
mod openssh_forward;
mod openssh_inspection;
mod openssh_integration;
mod openssh_jump;
mod openssh_probe;
mod openssh_proxy;
mod openssh_ranges;
mod openssh_remote_parallel;
mod openssh_rsa;
mod openssh_session_flow;
mod openssh_sftp_ownership;
mod openssh_tmux;
mod openssh_tree_parallel;
use hspterm_ssh_core::{
    Authentication, ConnectConfig, HostKeyPolicy, PtyEvent, SshConnection, SshError,
};
use hspterm_storage_sync::Vault;
use hspterm_term_core::{Size, Terminal};
use std::{
    fs,
    path::Path,
    process::{Child, Command, Stdio},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::mpsc,
    time::timeout,
};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_failed_directory_rescan_preserves_indices_snapshots_and_completed_siblings() {
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        remote_tree::{RemoteTree, RemoteTreeError, StagingPhase},
        tree_transfer::{ConflictDecision, NodeKind, NodeState, TreeOutcome},
    };
    use std::os::unix::fs::PermissionsExt;
    let server = Server::start().await;
    let connection = server.connect().await;
    let a = connection.open_sftp().await.unwrap();
    let b = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("remote rescan source");
    let target = server.dir.path().join("remote rescan target");
    fs::create_dir_all(source.join("broken/nested")).unwrap();
    fs::create_dir_all(source.join("done")).unwrap();
    fs::create_dir(&target).unwrap();
    fs::write(source.join("done/success"), b"successful sibling").unwrap();
    let body = vec![197; 256 * 1024 + 19];
    fs::write(source.join("broken/old"), &body).unwrap();
    fs::write(source.join("broken/nested/deep"), b"completed later").unwrap();
    fs::write(target.join("broken"), b"obstacle").unwrap();
    let stop = CancellationToken::new();
    let budget = BandwidthLimiter::default();
    let mut plan = RemoteTree::scan(
        &a,
        &b,
        source.to_str().unwrap().into(),
        target.to_str().unwrap().into(),
        true,
        "1234567890abcdef1234567890abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(
        plan.run(&a, &b, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Partial
    );
    let indices: Vec<_> = plan
        .nodes
        .iter()
        .enumerate()
        .filter(|(_, n)| n.kind == NodeKind::Directory && n.state == NodeState::Failed)
        .map(|(i, _)| i)
        .collect();
    assert_eq!(indices.len(), 2);
    fs::remove_dir_all(source.join("done")).unwrap();
    fs::write(target.join("done/success"), b"later target change").unwrap();
    fs::write(source.join("broken/new 中文 e\u{301}"), b"new discovery").unwrap();
    fs::remove_file(target.join("broken")).unwrap();
    let before = serde_json::to_vec(&plan).unwrap();
    let cancelled = CancellationToken::new();
    assert!(matches!(
        plan.rescan_failed(&indices, &a, &cancelled, |_| cancelled.cancel())
            .await,
        Err(RemoteTreeError::Cancelled)
    ));
    assert_eq!(serde_json::to_vec(&plan).unwrap(), before);
    assert!(!target.join("broken").exists());
    let mut candidate = plan
        .rescan_failed(&indices, &a, &stop, |_| {})
        .await
        .unwrap();
    assert_eq!(candidate.nodes.len(), plan.nodes.len() + 1);
    for (i, old) in plan.nodes.iter().enumerate() {
        assert_eq!(old.relative, candidate.nodes[i].relative);
        assert_eq!(plan.stages[i], candidate.stages[i]);
        if old.state == NodeState::Complete {
            assert_eq!(
                serde_json::to_vec(old).unwrap(),
                serde_json::to_vec(&candidate.nodes[i]).unwrap()
            );
        }
    }
    assert!(
        !target.join("broken").exists(),
        "metadata rescan must not create a target"
    );
    assert_eq!(
        candidate
            .run(&a, &b, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(
        fs::read(target.join("done/success")).unwrap(),
        b"later target change"
    );
    assert_eq!(
        fs::read(target.join("broken/new 中文 e\u{301}")).unwrap(),
        b"new discovery"
    );
    let parent = candidate
        .nodes
        .iter()
        .position(|n| n.relative == "broken")
        .unwrap();
    let file = candidate
        .nodes
        .iter()
        .position(|n| n.relative == "broken/old")
        .unwrap();
    // A failed directory may contain a file with an acknowledged private prefix.
    candidate.nodes[parent].state = NodeState::Failed;
    candidate.nodes[file].state = NodeState::Failed;
    candidate.nodes[file].decision = ConflictDecision::Overwrite;
    candidate.nodes[file].acknowledged = 4;
    candidate.stages[file] = StagingPhase::Writing;
    let stage = candidate.staging_path(file).unwrap();
    fs::write(&stage, &body[..4]).unwrap();
    fs::set_permissions(&stage, fs::Permissions::from_mode(0o600)).unwrap();
    fs::remove_dir_all(source.join("broken/nested")).unwrap();
    fs::remove_file(source.join("broken/new 中文 e\u{301}")).unwrap();
    let mut resumed = candidate
        .rescan_failed(&[parent], &a, &stop, |_| {})
        .await
        .unwrap();
    assert_eq!(resumed.nodes[file].acknowledged, 4);
    assert_eq!(resumed.stages[file], StagingPhase::Writing);
    assert_eq!(fs::read(&stage).unwrap(), body[..4]);
    assert_eq!(
        resumed
            .run(&a, &b, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(fs::read(target.join("broken/old")).unwrap(), body);
    // Selecting a failed root must not filter out the root itself.
    resumed.nodes[0].state = NodeState::Failed;
    fs::write(source.join("new root child"), b"root discovered").unwrap();
    let mut root = resumed
        .rescan_failed(&[0], &a, &stop, |_| {})
        .await
        .unwrap();
    assert_eq!(root.nodes.len(), resumed.nodes.len() + 1);
    assert_eq!(
        root.run(&a, &b, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(
        fs::read(target.join("new root child")).unwrap(),
        b"root discovered"
    );
    // A changed source directory cannot be followed or discard its old children.
    root.nodes[parent].state = NodeState::Failed;
    fs::remove_dir_all(source.join("broken")).unwrap();
    std::os::unix::fs::symlink(&target, source.join("broken")).unwrap();
    let guarded = root
        .rescan_failed(&[parent], &a, &stop, |_| {})
        .await
        .unwrap();
    assert_eq!(guarded.nodes[parent].state, NodeState::Failed);
    assert_eq!(guarded.nodes[parent].kind, NodeKind::Directory);
    assert_eq!(guarded.nodes.len(), root.nodes.len());
    assert!(root.rescan_failed(&[], &a, &stop, |_| {}).await.is_err());
    assert!(
        root.rescan_failed(&[file], &a, &stop, |_| {})
            .await
            .is_err()
    );
    a.close().await.unwrap();
    b.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_rescan_rejects_discovery_colliding_with_a_reserved_rename_without_writes() {
    use hspterm_ssh_core::{remote_tree::RemoteTree, tree_transfer::NodeState};
    let server = Server::start().await;
    let connection = server.connect().await;
    let a = connection.open_sftp().await.unwrap();
    let b = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("rescan collision source");
    let target = server.dir.path().join("rescan collision target");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("original"), b"original").unwrap();
    let stop = CancellationToken::new();
    let mut plan = RemoteTree::scan(
        &a,
        &b,
        source.to_str().unwrap().into(),
        target.to_str().unwrap().into(),
        true,
        "1234567890abcdef1234567890abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    plan.nodes[0].state = NodeState::Failed;
    plan.nodes[1].destination_name = Some("reserved".into());
    plan.validate().unwrap();
    fs::write(
        source.join("reserved"),
        b"newly discovered, must not overwrite",
    )
    .unwrap();
    let original = serde_json::to_vec(&plan).unwrap();
    assert!(plan.rescan_failed(&[0], &a, &stop, |_| {}).await.is_err());
    assert_eq!(serde_json::to_vec(&plan).unwrap(), original);
    assert!(!target.exists());
    assert_eq!(
        fs::read(source.join("reserved")).unwrap(),
        b"newly discovered, must not overwrite"
    );
    a.close().await.unwrap();
    b.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_move_preparation_is_metadata_only_and_does_not_reserve_a_target_name() {
    use hspterm_ssh_core::transfer::{
        RemoteMoveError, move_remote_path, object_path, prepare_remote_move,
    };
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let directory = server.dir.path().join("move preparation 中文");
    fs::create_dir(&directory).unwrap();
    let alias = server.dir.path().join("parent alias");
    std::os::unix::fs::symlink(&directory, &alias).unwrap();
    let source = directory.join("source '$;\n");
    let destination = directory.join("destination '$;\n");
    fs::write(&source, b"original move body").unwrap();
    let final_link = directory.join("final source link");
    std::os::unix::fs::symlink(&source, &final_link).unwrap();
    assert_eq!(
        object_path(&sftp, alias.join("final source link").to_str().unwrap())
            .await
            .unwrap(),
        final_link.to_str().unwrap()
    );
    assert!(fs::symlink_metadata(&final_link).unwrap().is_symlink());
    for path in ["/", "/tmp/.", "/tmp/..", "relative", "/tmp/invalid\0"] {
        assert!(object_path(&sftp, path).await.is_err());
    }
    let stop = CancellationToken::new();
    let prepared = prepare_remote_move(
        &sftp,
        alias.join("source '$;\n").to_str().unwrap(),
        alias.join("destination '$;\n").to_str().unwrap(),
        &stop,
    )
    .await
    .unwrap();
    assert_eq!(prepared.source, source.to_str().unwrap());
    assert_eq!(prepared.destination, destination.to_str().unwrap());
    assert_eq!(fs::read(&source).unwrap(), b"original move body");
    assert!(!destination.exists());
    fs::write(&destination, b"concurrent target").unwrap();
    assert!(matches!(
        move_remote_path(&sftp, &prepared.source, &prepared.destination, &stop).await,
        Err(RemoteMoveError::Conflict)
    ));
    assert_eq!(fs::read(&source).unwrap(), b"original move body");
    assert_eq!(fs::read(&destination).unwrap(), b"concurrent target");
    fs::remove_file(&destination).unwrap();
    let moved = move_remote_path(&sftp, &prepared.source, &prepared.destination, &stop)
        .await
        .unwrap();
    assert_eq!(moved.destination, prepared.destination);
    assert!(!source.exists());
    assert_eq!(fs::read(&destination).unwrap(), b"original move body");
    sftp.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_tree_keeps_successes_on_retry_and_refuses_linked_destination_subtrees() {
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        remote_tree::RemoteTree,
        tree_transfer::{ConflictDecision, NodeState, TreeOutcome},
    };
    let server = Server::start().await;
    let connection = server.connect().await;
    let a = connection.open_sftp().await.unwrap();
    let b = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("tree source");
    let target = server.dir.path().join("tree destination");
    let outside = server.dir.path().join("outside tree");
    fs::create_dir_all(source.join("blocked")).unwrap();
    fs::create_dir_all(&target).unwrap();
    fs::create_dir_all(&outside).unwrap();
    fs::write(source.join("blocked/child"), b"must not escape").unwrap();
    fs::write(source.join("good"), b"good original").unwrap();
    fs::write(source.join("conflict"), b"replacement").unwrap();
    fs::write(target.join("conflict"), b"old conflicting target").unwrap();
    std::os::unix::fs::symlink(&outside, target.join("blocked")).unwrap();
    let stop = CancellationToken::new();
    let mut tree = RemoteTree::scan(
        &a,
        &b,
        source.to_str().unwrap().into(),
        target.to_str().unwrap().into(),
        true,
        "1234567890abcdef1234567890abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    let budget = BandwidthLimiter::default();
    assert_eq!(
        tree.run(&a, &b, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Partial
    );
    assert!(!outside.join("child").exists());
    assert_eq!(fs::read(target.join("good")).unwrap(), b"good original");
    assert_eq!(
        fs::read(target.join("conflict")).unwrap(),
        b"old conflicting target"
    );
    let index = tree
        .nodes
        .iter()
        .position(|n| n.relative == "conflict")
        .unwrap();
    assert_eq!(tree.nodes[index].state, NodeState::Conflict);
    fs::remove_file(source.join("good")).unwrap();
    fs::write(target.join("good"), b"later change retained").unwrap();
    tree.retry(index, ConflictDecision::Overwrite).unwrap();
    assert_eq!(
        tree.run(&a, &b, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Partial
    );
    assert_eq!(tree.nodes[index].state, NodeState::Complete);
    assert_eq!(fs::read(target.join("conflict")).unwrap(), b"replacement");
    assert_eq!(
        fs::read(target.join("good")).unwrap(),
        b"later change retained"
    );
    assert!(!outside.join("child").exists());
    a.close().await.unwrap();
    b.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_directory_copy_keeps_one_manifest_and_never_traverses_child_links() {
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        remote_tree::RemoteTree,
        tree_transfer::{NodeState, TreeOutcome},
    };
    let server = Server::start().await;
    let connection = server.connect().await;
    let source_sftp = connection.open_sftp().await.unwrap();
    let target_sftp = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("copy source 中文");
    let destination = server.dir.path().join("copy target '$;\n");
    fs::create_dir_all(source.join("empty/nested")).unwrap();
    fs::write(source.join(".hidden"), b"hidden").unwrap();
    fs::write(source.join("中文 e\u{301}.txt"), "中文\0正文").unwrap();
    std::os::unix::fs::symlink(&source, source.join("loop")).unwrap();
    let stop = CancellationToken::new();
    for target in [&source, &source.join("empty/inside")] {
        assert!(
            RemoteTree::scan(
                &source_sftp,
                &target_sftp,
                source.to_str().unwrap().into(),
                target.to_str().unwrap().into(),
                true,
                "0123456789abcdef0123456789abcdef".into(),
                &stop,
                |_| {}
            )
            .await
            .is_err()
        );
    }
    let mut plan = RemoteTree::scan(
        &source_sftp,
        &target_sftp,
        source.to_str().unwrap().into(),
        destination.to_str().unwrap().into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    assert!(!destination.exists());
    assert_eq!(plan.nodes.len(), 6);
    let link = plan
        .nodes
        .iter()
        .position(|n| n.relative == "loop")
        .unwrap();
    assert_eq!(plan.nodes[link].state, NodeState::Failed);
    let budget = BandwidthLimiter::default();
    let outcome = plan
        .run(
            &source_sftp,
            &target_sftp,
            &stop,
            &budget,
            &budget,
            |p, _| {
                p.validate()?;
                Ok(())
            },
        )
        .await
        .unwrap();
    assert_eq!(outcome, TreeOutcome::Partial);
    assert!(destination.join("empty/nested").is_dir());
    assert!(!destination.join("loop").exists());
    assert_eq!(fs::read(destination.join(".hidden")).unwrap(), b"hidden");
    assert_eq!(
        fs::read(destination.join("中文 e\u{301}.txt")).unwrap(),
        "中文\0正文".as_bytes()
    );
    assert_eq!(plan.stats().files, 2);
    assert_eq!(plan.stats().failed, 1);
    assert!(source.join(".hidden").exists());
    source_sftp.close().await.unwrap();
    target_sftp.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_tree_pauses_with_durable_offsets_and_requires_a_checkpoint_before_publication() {
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        remote_tree::{RemoteTree, RemoteTreeError, StagingPhase},
        tree_transfer::{ConflictDecision, TreeOutcome},
    };
    let server = Server::start().await;
    let connection = server.connect().await;
    let a = connection.open_sftp().await.unwrap();
    let b = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("large source");
    let target = server.dir.path().join("large target");
    let bytes = vec![203; 256 * 1024 + 17];
    fs::write(&source, &bytes).unwrap();
    fs::write(&target, b"old target").unwrap();
    let stop = CancellationToken::new();
    let mut plan = RemoteTree::scan(
        &a,
        &b,
        source.to_str().unwrap().into(),
        target.to_str().unwrap().into(),
        true,
        "abcdef0123456789abcdef0123456789".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    let budget = BandwidthLimiter::default();
    assert_eq!(
        plan.run(&a, &b, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Partial
    );
    plan.retry(0, ConflictDecision::Overwrite).unwrap();
    let mut saved = Vec::new();
    assert_eq!(
        plan.run(&a, &b, &stop, &budget, &budget, |p, _| {
            saved = serde_json::to_vec(p).unwrap();
            if p.nodes[0].acknowledged > 0 {
                stop.cancel();
            }
            Ok(())
        })
        .await
        .unwrap(),
        TreeOutcome::Paused
    );
    assert_eq!(fs::read(&target).unwrap(), b"old target");
    let mut restored: RemoteTree = serde_json::from_slice(&saved).unwrap();
    assert!(
        restored.nodes[0].acknowledged > 0 && restored.nodes[0].acknowledged < bytes.len() as u64
    );
    let resumed = CancellationToken::new();
    let error = restored
        .run(&a, &b, &resumed, &budget, &budget, |p, _| {
            if p.stages[0] == StagingPhase::Publishing {
                return Err(RemoteTreeError::Checkpoint);
            }
            Ok(())
        })
        .await
        .unwrap_err();
    assert!(matches!(error, RemoteTreeError::Checkpoint));
    assert_eq!(fs::read(&target).unwrap(), b"old target");
    let staged = restored.staging_path(0).unwrap();
    assert_eq!(fs::read(&staged).unwrap(), bytes);
    assert_eq!(
        restored
            .run(&a, &b, &resumed, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(fs::read(&target).unwrap(), bytes);
    assert_eq!(fs::read(&source).unwrap(), bytes);
    assert!(!Path::new(&staged).exists());
    a.close().await.unwrap();
    b.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn staged_snapshot_streaming_overwrite_keeps_the_complete_snapshot_after_cancellation() {
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        transfer::{RemoteCopyMode, overwrite_from_staged_remote_file, stage_remote_file_limited},
    };
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("original source");
    let staged = server.dir.path().join(".private snapshot");
    let target = server.dir.path().join("existing target");
    let bytes = vec![177; 128 * 1024 + 11];
    let old = vec![91; bytes.len() + 100];
    fs::write(&source, &bytes).unwrap();
    fs::write(&target, &old).unwrap();
    let budget = BandwidthLimiter::default();
    stage_remote_file_limited(
        &sftp,
        source.to_str().unwrap(),
        &sftp,
        staged.to_str().unwrap(),
        RemoteCopyMode::CreateNew,
        &CancellationToken::new(),
        &budget,
        &budget,
        |_| {},
    )
    .await
    .unwrap();
    assert!(
        overwrite_from_staged_remote_file(
            &sftp,
            staged.to_str().unwrap(),
            target.to_str().unwrap(),
            bytes.len() as u64 + 1,
            &CancellationToken::new(),
            &budget,
            &budget,
            |_| {}
        )
        .await
        .is_err()
    );
    assert_eq!(fs::read(&target).unwrap(), old);
    let stop = CancellationToken::new();
    let mut acknowledged = 0;
    assert!(
        overwrite_from_staged_remote_file(
            &sftp,
            staged.to_str().unwrap(),
            target.to_str().unwrap(),
            bytes.len() as u64,
            &stop,
            &budget,
            &budget,
            |p| {
                acknowledged = p.acknowledged;
                if acknowledged > 0 {
                    stop.cancel();
                }
            }
        )
        .await
        .is_err()
    );
    assert!(acknowledged > 0 && acknowledged < bytes.len() as u64);
    assert_eq!(fs::read(&target).unwrap(), bytes[..acknowledged as usize]);
    assert_eq!(fs::read(&staged).unwrap(), bytes);
    let done = overwrite_from_staged_remote_file(
        &sftp,
        staged.to_str().unwrap(),
        target.to_str().unwrap(),
        bytes.len() as u64,
        &CancellationToken::new(),
        &budget,
        &budget,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(done.acknowledged, bytes.len() as u64);
    assert_eq!(fs::read(&target).unwrap(), bytes);
    assert_eq!(fs::read(&staged).unwrap(), bytes);
    assert_eq!(fs::read(&source).unwrap(), bytes);
    sftp.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn staged_remote_copy_is_private_complete_and_published_only_after_explicit_overwrite() {
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        transfer::{
            RemoteCopyMode, RemotePublishResult, publish_staged_remote_file,
            stage_remote_file_limited,
        },
    };
    use std::os::unix::fs::PermissionsExt;
    let server = Server::start().await;
    let connection = server.connect().await;
    let source_sftp = connection.open_sftp().await.unwrap();
    let target_sftp = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("source snapshot 中文");
    let staged = server.dir.path().join(".owned-staging-fixture");
    let destination = server.dir.path().join("destination 中文");
    let bytes = vec![163; 128 * 1024 + 9];
    fs::write(&source, &bytes).unwrap();
    fs::write(&destination, b"original target").unwrap();
    let budget = BandwidthLimiter::default();
    let stop = CancellationToken::new();
    stage_remote_file_limited(
        &source_sftp,
        source.to_str().unwrap(),
        &target_sftp,
        staged.to_str().unwrap(),
        RemoteCopyMode::CreateNew,
        &stop,
        &budget,
        &budget,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(
        fs::metadata(&staged).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(fs::read(&staged).unwrap(), bytes);
    assert_eq!(fs::read(&destination).unwrap(), b"original target");
    assert!(
        publish_staged_remote_file(
            &target_sftp,
            staged.to_str().unwrap(),
            destination.to_str().unwrap(),
            bytes.len() as u64,
            false,
            &stop
        )
        .await
        .is_err()
    );
    assert!(
        publish_staged_remote_file(
            &target_sftp,
            staged.to_str().unwrap(),
            destination.to_str().unwrap(),
            bytes.len() as u64 + 1,
            true,
            &stop
        )
        .await
        .is_err()
    );
    assert_eq!(fs::read(&destination).unwrap(), b"original target");
    assert_eq!(
        publish_staged_remote_file(
            &target_sftp,
            staged.to_str().unwrap(),
            destination.to_str().unwrap(),
            bytes.len() as u64,
            true,
            &stop
        )
        .await
        .unwrap(),
        RemotePublishResult::Published
    );
    assert!(!staged.exists());
    assert_eq!(fs::read(&destination).unwrap(), bytes);
    assert_eq!(fs::read(&source).unwrap(), bytes);
    source_sftp.close().await.unwrap();
    target_sftp.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_move_preserves_objects_links_and_conflicting_targets_without_shell_commands() {
    use hspterm_ssh_core::transfer::move_remote_path;
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("dir 中文 ' $;\n");
    let destination = server.dir.path().join("moved dir 中文");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("kept.txt"), b"source payload").unwrap();
    assert!(
        move_remote_path(
            &sftp,
            source.to_str().unwrap(),
            source.join("nested").to_str().unwrap(),
            &CancellationToken::new()
        )
        .await
        .is_err()
    );
    assert!(source.join("kept.txt").exists());
    let result = move_remote_path(
        &sftp,
        source.to_str().unwrap(),
        destination.to_str().unwrap(),
        &CancellationToken::new(),
    )
    .await
    .unwrap();
    assert_eq!(result.destination, destination.to_str().unwrap());
    assert!(!source.exists());
    assert_eq!(
        fs::read(destination.join("kept.txt")).unwrap(),
        b"source payload"
    );
    let occupied = server.dir.path().join("occupied");
    fs::write(&occupied, b"never replace this").unwrap();
    assert!(
        move_remote_path(
            &sftp,
            destination.to_str().unwrap(),
            occupied.to_str().unwrap(),
            &CancellationToken::new()
        )
        .await
        .is_err()
    );
    assert_eq!(fs::read(&occupied).unwrap(), b"never replace this");
    assert!(destination.join("kept.txt").exists());
    let alias = server.dir.path().join("link object");
    let moved_alias = server.dir.path().join("moved link");
    std::os::unix::fs::symlink(&occupied, &alias).unwrap();
    move_remote_path(
        &sftp,
        alias.to_str().unwrap(),
        moved_alias.to_str().unwrap(),
        &CancellationToken::new(),
    )
    .await
    .unwrap();
    assert_eq!(fs::read_link(&moved_alias).unwrap(), occupied);
    assert_eq!(fs::read(&occupied).unwrap(), b"never replace this");
    assert!(
        move_remote_path(
            &sftp,
            destination.to_str().unwrap(),
            destination.to_str().unwrap(),
            &CancellationToken::new()
        )
        .await
        .is_err()
    );
    sftp.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_copy_streams_between_servers_resumes_acknowledged_bytes_and_refuses_conflicts() {
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        transfer::{RemoteCopyMode, copy_remote_file_limited},
    };
    let source_server = Server::start().await;
    let target_server = Server::start().await;
    let source_connection = source_server.connect().await;
    let target_connection = target_server.connect().await;
    let source_sftp = source_connection.open_sftp().await.unwrap();
    let target_sftp = target_connection.open_sftp().await.unwrap();
    let source = source_server.dir.path().join("copy 中文 ' $;\n.txt");
    let destination = target_server.dir.path().join("copy target 中文.txt");
    let bytes = vec![137; 256 * 1024 + 19];
    fs::write(&source, &bytes).unwrap();
    let up = BandwidthLimiter::default();
    let down = BandwidthLimiter::default();
    let stop = CancellationToken::new();
    let mut offset = 0;
    let result = copy_remote_file_limited(
        &source_sftp,
        source.to_str().unwrap(),
        &target_sftp,
        destination.to_str().unwrap(),
        RemoteCopyMode::CreateNew,
        &stop,
        &up,
        &down,
        |p| {
            offset = p.acknowledged;
            if offset > 0 {
                stop.cancel();
            }
        },
    )
    .await;
    assert!(result.is_err());
    assert!(offset > 0 && offset < bytes.len() as u64);
    assert_eq!(fs::read(&destination).unwrap(), bytes[..offset as usize]);
    assert_eq!(fs::read(&source).unwrap(), bytes);
    let done = copy_remote_file_limited(
        &source_sftp,
        source.to_str().unwrap(),
        &target_sftp,
        destination.to_str().unwrap(),
        RemoteCopyMode::Resume { offset },
        &CancellationToken::new(),
        &up,
        &down,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(done.acknowledged, bytes.len() as u64);
    assert_eq!(fs::read(&destination).unwrap(), bytes);
    assert!(
        copy_remote_file_limited(
            &source_sftp,
            source.to_str().unwrap(),
            &target_sftp,
            destination.to_str().unwrap(),
            RemoteCopyMode::CreateNew,
            &CancellationToken::new(),
            &up,
            &down,
            |_| {}
        )
        .await
        .is_err()
    );
    assert_eq!(fs::read(&destination).unwrap(), bytes);
    let dangling = target_server.dir.path().join("occupied-link");
    std::os::unix::fs::symlink("missing target", &dangling).unwrap();
    assert!(
        copy_remote_file_limited(
            &source_sftp,
            source.to_str().unwrap(),
            &target_sftp,
            dangling.to_str().unwrap(),
            RemoteCopyMode::CreateNew,
            &CancellationToken::new(),
            &up,
            &down,
            |_| {}
        )
        .await
        .is_err()
    );
    assert!(
        fs::symlink_metadata(&dangling)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    let never = target_server.dir.path().join("never-created");
    let cancelled = CancellationToken::new();
    cancelled.cancel();
    assert!(
        copy_remote_file_limited(
            &source_sftp,
            source.to_str().unwrap(),
            &target_sftp,
            never.to_str().unwrap(),
            RemoteCopyMode::CreateNew,
            &cancelled,
            &up,
            &down,
            |_| {}
        )
        .await
        .is_err()
    );
    assert!(!never.exists());
    source_sftp.close().await.unwrap();
    target_sftp.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn recursive_filename_search_pages_matches_and_never_follows_child_links() {
    use hspterm_ssh_core::search::RecursiveSearch;
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let root = server.dir.path().join("search 中文 root");
    let outside = server.dir.path().join("outside");
    fs::create_dir_all(root.join("nested 深层")).unwrap();
    fs::create_dir_all(&outside).unwrap();
    fs::write(root.join("Needle 中文.txt"), b"not read").unwrap();
    fs::write(root.join("nested 深层/needle other.txt"), b"not read").unwrap();
    fs::write(
        outside.join("needle must not visit.txt"),
        b"private fixture",
    )
    .unwrap();
    std::os::unix::fs::symlink(&outside, root.join("child-link")).unwrap();
    std::os::unix::fs::symlink(&root, root.join("cycle-link")).unwrap();
    let stop = CancellationToken::new();
    let mut cursor = RecursiveSearch::open(&sftp, root.to_str().unwrap(), "needle", false, &stop)
        .await
        .unwrap();
    let mut matches = Vec::new();
    let mut scanned = 0;
    loop {
        let page = cursor.next_page(&sftp, 1, &stop).await.unwrap();
        assert!(page.matches.len() <= 1);
        assert!(page.scanned >= scanned);
        scanned = page.scanned;
        matches.extend(page.matches.into_iter().map(|v| v.path));
        if page.done {
            break;
        }
    }
    assert_eq!(matches.len(), 2);
    assert!(
        matches
            .iter()
            .all(|p| p.starts_with(root.to_str().unwrap()))
    );
    assert_eq!(scanned, 5); // root: file, dir, two links; nested: file
    cursor.close().await.unwrap();
    let root_alias = server.dir.path().join("explicit search root link");
    std::os::unix::fs::symlink(&root, &root_alias).unwrap();
    let mut exact =
        RecursiveSearch::open(&sftp, root_alias.to_str().unwrap(), "Needle", true, &stop)
            .await
            .unwrap();
    let page = exact.next_page(&sftp, 256, &stop).await.unwrap();
    assert!(page.done);
    assert_eq!(page.matches.len(), 1);
    exact.close().await.unwrap();
    let cancelled = CancellationToken::new();
    cancelled.cancel();
    assert!(
        RecursiveSearch::open(&sftp, root.to_str().unwrap(), "needle", false, &cancelled)
            .await
            .is_err()
    );
    let mut cursor = RecursiveSearch::open(&sftp, root.to_str().unwrap(), "needle", false, &stop)
        .await
        .unwrap();
    assert!(cursor.next_page(&sftp, 0, &stop).await.is_err());
    assert!(cursor.next_page(&sftp, 1, &cancelled).await.is_err());
    assert!(cursor.next_page(&sftp, 1, &stop).await.is_err());
    cursor.close().await.unwrap();
    for i in 0..65 {
        fs::create_dir(root.join(format!("empty-{i}"))).unwrap();
    }
    let mut empty = RecursiveSearch::open(
        &sftp,
        root.to_str().unwrap(),
        "no-match-fixture",
        true,
        &stop,
    )
    .await
    .unwrap();
    let mut directories = 1;
    let mut pulls = 0;
    loop {
        let page = empty.next_page(&sftp, 256, &stop).await.unwrap();
        assert!(page.matches.is_empty());
        assert!(page.directories - directories <= 32);
        directories = page.directories;
        pulls += 1;
        if page.done {
            break;
        }
    }
    assert!(pulls >= 3);
    assert_eq!(directories, 67);
    empty.close().await.unwrap();
    sftp.close().await.unwrap();
}

struct PatternSink {
    count: u64,
    largest: usize,
}
impl tokio::io::AsyncWrite for PatternSink {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
        bytes: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        if !bytes.iter().all(|b| *b == 0xa7) {
            return std::task::Poll::Ready(Err(std::io::Error::other(
                "synthetic pattern mismatch",
            )));
        }
        self.count += bytes.len() as u64;
        self.largest = self.largest.max(bytes.len());
        std::task::Poll::Ready(Ok(bytes.len()))
    }
    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        _: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn streaming_editor_round_trips_large_files_without_data_sized_buffers() {
    use hspterm_ssh_core::{bandwidth::BandwidthLimiter, edit};
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let file = server.dir.path().join("large stream 中文 ' $.txt");
    let alias = server.dir.path().join("large alias");
    let total = 17 * 1024 * 1024 + 23;
    let mut source = tokio::io::repeat(0xa7).take(total);
    let stop = CancellationToken::new();
    let budget = BandwidthLimiter::default();
    let mut previous = 0;
    let saved = edit::write_from_reader(
        &sftp,
        file.to_str().unwrap(),
        &mut source,
        total,
        &stop,
        &budget,
        |p| {
            assert!(p.acknowledged >= previous && p.acknowledged - previous <= 65536);
            previous = p.acknowledged;
        },
    )
    .await
    .unwrap();
    assert_eq!(saved.acknowledged, total);
    assert_eq!(fs::metadata(&file).unwrap().len(), total);
    std::os::unix::fs::symlink(&file, &alias).unwrap();
    let mut sink = PatternSink {
        count: 0,
        largest: 0,
    };
    let read = edit::read_to_writer(
        &sftp,
        alias.to_str().unwrap(),
        &mut sink,
        total,
        &stop,
        &budget,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(read.path, file.to_str().unwrap());
    assert_eq!(read.progress.acknowledged, total);
    assert_eq!(sink.count, total);
    assert!(sink.largest <= 65536);
    // Explicit empty replacement is also valid; read must still flush/CLOSE.
    edit::write_from_reader(
        &sftp,
        file.to_str().unwrap(),
        &mut tokio::io::empty(),
        0,
        &stop,
        &budget,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(fs::metadata(&file).unwrap().len(), 0);
    let read = edit::read_to_writer(
        &sftp,
        file.to_str().unwrap(),
        &mut sink,
        0,
        &stop,
        &budget,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(read.progress.acknowledged, 0);
    assert_eq!(sink.count, total);
    sftp.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn editor_read_and_explicit_save_preserve_drafts_and_bind_canonical_paths() {
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        edit::{self, EditFileError},
    };
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("edit 中文 space ' dollar$;.txt");
    let alias = server.dir.path().join("edit-alias");
    let other = server.dir.path().join("other-file");
    let original = "original UTF8 中文 é\r\nlong initial body";
    fs::write(&source, original).unwrap();
    fs::write(&other, b"do not retarget").unwrap();
    std::os::unix::fs::symlink(&source, &alias).unwrap();
    let stop = CancellationToken::new();
    let budget = BandwidthLimiter::default();
    assert!(matches!(
        edit::read_file(&sftp, alias.to_str().unwrap(), 4, &stop, &budget, |_| {}).await,
        Err(EditFileError::Capacity)
    ));
    let read = edit::read_file(&sftp, alias.to_str().unwrap(), 1024, &stop, &budget, |_| {})
        .await
        .unwrap();
    assert_eq!(read.path, source.to_str().unwrap());
    assert_eq!(read.bytes.as_slice(), original.as_bytes());
    fs::remove_file(&alias).unwrap();
    std::os::unix::fs::symlink(&other, &alias).unwrap();
    let modified = b"new body";
    let result = edit::write_file(&sftp, &read.path, modified, &stop, &budget, |_| {})
        .await
        .unwrap();
    assert_eq!(result.acknowledged, modified.len() as u64);
    assert_eq!(fs::read(&source).unwrap(), modified);
    assert_eq!(fs::read(&other).unwrap(), b"do not retarget");
    assert!(matches!(
        edit::write_file(
            &sftp,
            alias.to_str().unwrap(),
            b"reject alias",
            &stop,
            &budget,
            |_| {}
        )
        .await,
        Err(EditFileError::InvalidFile)
    ));
    let cancelled = CancellationToken::new();
    cancelled.cancel();
    assert!(matches!(
        edit::write_file(
            &sftp,
            &read.path,
            b"must not truncate",
            &cancelled,
            &budget,
            |_| {}
        )
        .await,
        Err(EditFileError::Cancelled)
    ));
    assert_eq!(fs::read(&source).unwrap(), modified);
    let partial_stop = CancellationToken::new();
    let bytes = vec![19; 128 * 1024];
    assert!(matches!(
        edit::write_file(&sftp, &read.path, &bytes, &partial_stop, &budget, |p| {
            if p.acknowledged > 0 {
                partial_stop.cancel();
            }
        })
        .await,
        Err(EditFileError::Cancelled)
    ));
    assert_eq!(bytes.len(), 128 * 1024); // caller still owns its complete draft
    let partial = fs::read(&source).unwrap();
    assert!(partial.len() < bytes.len());
    assert_eq!(partial, bytes[..partial.len()]);
    edit::write_file(&sftp, &read.path, &bytes, &stop, &budget, |_| {})
        .await
        .unwrap();
    assert_eq!(fs::read(&source).unwrap(), bytes);
    sftp.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn posix_rename_replaces_only_after_success_and_preserves_standard_rename_rules() {
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    assert!(sftp.supports_posix_rename());
    let original = server.dir.path().join("edited 中文 space' dollar$;.txt");
    let staged = server.dir.path().join("staged \n# percent%.txt");
    fs::write(&original, b"original remote body").unwrap();
    fs::write(&staged, b"confirmed staged body").unwrap();
    // Existing ordinary rename must still refuse an occupied destination.
    assert!(
        sftp.rename(staged.to_str().unwrap(), original.to_str().unwrap())
            .await
            .is_err()
    );
    assert_eq!(fs::read(&original).unwrap(), b"original remote body");
    assert_eq!(fs::read(&staged).unwrap(), b"confirmed staged body");
    assert!(
        sftp.posix_rename(staged.to_str().unwrap(), original.to_str().unwrap())
            .await
            .unwrap()
    );
    assert!(!staged.exists());
    assert_eq!(fs::read(&original).unwrap(), b"confirmed staged body");
    // Missing source and a destination directory do not report success or
    // remove/truncate the current destination.
    assert!(
        sftp.posix_rename(staged.to_str().unwrap(), original.to_str().unwrap())
            .await
            .is_err()
    );
    assert_eq!(fs::read(&original).unwrap(), b"confirmed staged body");
    let folder = server.dir.path().join("existing-directory");
    fs::create_dir(&folder).unwrap();
    fs::write(&staged, b"retain staged after failed commit").unwrap();
    assert!(
        sftp.posix_rename(staged.to_str().unwrap(), folder.to_str().unwrap())
            .await
            .is_err()
    );
    assert!(folder.is_dir());
    assert_eq!(
        fs::read(&staged).unwrap(),
        b"retain staged after failed commit"
    );
    sftp.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn observed_tree_statistics_match_actual_mutations_and_resume() {
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        tree_transfer::{ConflictDecision, Direction, NodeState, TreeOutcome, TreeTransfer},
    };
    let server = Server::start().await;
    let mut connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("observed-source");
    let target = server.dir.path().join("observed-target");
    fs::create_dir_all(source.join("blocked/child")).unwrap();
    fs::create_dir(&target).unwrap();
    for name in ["conflict", "skip", "grow", "gone", "blocked/child/file"] {
        fs::write(source.join(name), b"initial").unwrap();
    }
    fs::write(target.join("conflict"), b"keep old").unwrap();
    fs::write(target.join("blocked"), b"directory obstacle").unwrap();
    let stop = CancellationToken::new();
    let mut plan = TreeTransfer::scan(
        Direction::Upload,
        source.clone(),
        target.to_str().unwrap().into(),
        &sftp,
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    plan.nodes
        .iter_mut()
        .find(|n| n.relative == "skip")
        .unwrap()
        .decision = ConflictDecision::Skip;
    fs::remove_file(source.join("gone")).unwrap();
    let bytes = vec![17u8; 256 * 1024 + 1];
    fs::write(source.join("grow"), &bytes).unwrap();
    let mut observations = 0;
    let mut saw_unknown = false;
    assert_eq!(
        plan.run_observed(
            &sftp,
            &stop,
            |p, event| {
                observations += 1;
                assert_eq!(event.stats, p.stats());
                assert!(event.index < p.nodes.len());
                if let Some(current) = event.current {
                    assert_eq!(event.index, current);
                    assert_eq!(
                        p.nodes[current].kind,
                        hspterm_ssh_core::tree_transfer::NodeKind::File
                    );
                }
                saw_unknown |= !event.stats.total_known;
                if p.nodes[event.index].relative == "grow" && event.stats.acknowledged >= 65536 {
                    stop.cancel();
                }
            },
            &BandwidthLimiter::default()
        )
        .await
        .unwrap(),
        TreeOutcome::Paused
    );
    assert!(observations > 5);
    assert!(saw_unknown);
    let acknowledged = plan
        .nodes
        .iter()
        .find(|n| n.relative == "grow")
        .unwrap()
        .acknowledged;
    assert!(acknowledged >= 65536 && acknowledged < bytes.len() as u64);
    let mut plan: TreeTransfer =
        serde_json::from_slice(&serde_json::to_vec(&plan).unwrap()).unwrap();
    assert_eq!(
        plan.run_observed(
            &sftp,
            &CancellationToken::new(),
            |p, event| {
                assert_eq!(event.stats, p.stats());
            },
            &BandwidthLimiter::default()
        )
        .await
        .unwrap(),
        TreeOutcome::Partial
    );
    assert_eq!(fs::read(target.join("grow")).unwrap(), bytes);
    assert_eq!(fs::read(target.join("conflict")).unwrap(), b"keep old");
    assert!(!target.join("skip").exists());
    assert!(plan.nodes.iter().any(|n| n.state == NodeState::Conflict));
    assert!(plan.stats().failed >= 3);
    assert_eq!(plan.stats().skipped, 1);
    assert!(!plan.stats().total_known);
    sftp.close().await.unwrap();
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn posix_names_are_transferred_exactly_without_windows_sanitization() {
    use hspterm_ssh_core::tree_transfer::{Direction, TreeOutcome, TreeTransfer};
    let server = Server::start().await;
    let mut connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("posix-source");
    let remote = server.dir.path().join("posix-remote");
    let destination = server.dir.path().join("posix-downloaded");
    fs::create_dir(&source).unwrap();
    let names = [
        "NUL.txt",
        "name:stream",
        "trailing.",
        "trailing ",
        "中文 é",
        "shell '$;[x]",
        "line\nfile",
        r"a\b",
    ];
    for name in names {
        fs::write(source.join(name), name.as_bytes()).unwrap();
    }
    let stop = CancellationToken::new();
    let mut upload = TreeTransfer::scan(
        Direction::Upload,
        source.clone(),
        remote.to_str().unwrap().into(),
        &sftp,
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(
        upload.run(&sftp, &stop, |_, _| {}).await.unwrap(),
        TreeOutcome::Complete
    );
    let mut download = TreeTransfer::scan(
        Direction::Download,
        destination.clone(),
        remote.to_str().unwrap().into(),
        &sftp,
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(
        download.run(&sftp, &stop, |_, _| {}).await.unwrap(),
        TreeOutcome::Complete
    );
    for name in names {
        assert_eq!(fs::read(remote.join(name)).unwrap(), name.as_bytes());
        assert_eq!(fs::read(destination.join(name)).unwrap(), name.as_bytes());
    }
    sftp.close().await.unwrap();
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_sftp_jobs_share_a_directional_content_budget() {
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        transfer::{FileDisposition, download_file_limited, upload_file_limited},
    };
    let server = Server::start().await;
    let mut connection = server.connect().await;
    let limiter = BandwidthLimiter::new(65536);
    let mut workers = Vec::new();
    let acknowledged = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let start = std::time::Instant::now();
    for i in 0..3 {
        let source = server.dir.path().join(format!("limited-source-{i}"));
        let target = server.dir.path().join(format!("limited-target-{i}"));
        fs::write(&source, vec![i as u8; 32768]).unwrap();
        let sftp = connection.open_sftp().await.unwrap();
        let limiter = limiter.clone();
        let acknowledged = acknowledged.clone();
        workers.push(tokio::spawn(async move {
            let mut previous = 0;
            upload_file_limited(
                &sftp,
                &source,
                target.to_str().unwrap(),
                FileDisposition::CreateNew,
                &CancellationToken::new(),
                |p| {
                    let sum = acknowledged.fetch_add(
                        p.acknowledged - previous,
                        std::sync::atomic::Ordering::SeqCst,
                    ) + p.acknowledged
                        - previous;
                    previous = p.acknowledged;
                    // Account for the documented bounded idle burst; server
                    // latency only tightens this upper bound on content bytes.
                    assert!(sum as f64 <= start.elapsed().as_secs_f64() * 65536.0 + 6553.0);
                },
                &limiter,
            )
            .await
            .unwrap();
            assert_eq!(fs::read(&source).unwrap(), fs::read(&target).unwrap());
            sftp.close().await.unwrap();
        }));
    }
    for worker in workers {
        worker.await.unwrap();
    }
    assert_eq!(
        acknowledged.load(std::sync::atomic::Ordering::SeqCst),
        3 * 32768
    );
    assert!(start.elapsed() >= Duration::from_millis(1350));
    // The download limiter is independent of upload and controls real reads.
    let sftp = connection.open_sftp().await.unwrap();
    let limiter = BandwidthLimiter::new(32768);
    let destination = server.dir.path().join("limited-download");
    let start = std::time::Instant::now();
    download_file_limited(
        &sftp,
        server.dir.path().join("limited-target-1").to_str().unwrap(),
        &destination,
        FileDisposition::CreateNew,
        &CancellationToken::new(),
        |_| {},
        &limiter,
    )
    .await
    .unwrap();
    assert!(start.elapsed() >= Duration::from_millis(900));
    assert_eq!(fs::read(&destination).unwrap(), vec![1; 32768]);
    sftp.close().await.unwrap();
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn default_scheduler_limits_real_top_level_transfers_to_three() {
    use hspterm_ssh_core::{
        task_scheduler::TaskScheduler,
        tree_transfer::{Direction, TreeOutcome, TreeTransfer},
    };
    let server = Server::start().await;
    let connection = server.connect().await;
    let scheduler = TaskScheduler::default();
    let (started, mut starts) = mpsc::channel(4);
    let mut finish = Vec::new();
    let mut workers = Vec::new();
    for i in 0..4 {
        let source = server.dir.path().join(format!("queue-source-{i}"));
        let target = server.dir.path().join(format!("queue-target-{i}"));
        fs::create_dir(&source).unwrap();
        fs::create_dir(source.join("empty")).unwrap();
        fs::write(source.join("data.txt"), format!("task {i}")).unwrap();
        let sftp = connection.open_sftp().await.unwrap();
        let admission = scheduler.enqueue();
        let started = started.clone();
        let (release, held) = tokio::sync::oneshot::channel();
        finish.push(release);
        workers.push(tokio::spawn(async move {
            let stop = CancellationToken::new();
            let _permit = admission.enter(&stop).await.unwrap();
            started.send(i).await.unwrap();
            let mut task = TreeTransfer::scan(
                Direction::Upload,
                source,
                target.to_str().unwrap().into(),
                &sftp,
                &stop,
                |_| {},
            )
            .await
            .unwrap();
            assert_eq!(
                task.run(&sftp, &stop, |_, _| {}).await.unwrap(),
                TreeOutcome::Complete
            );
            held.await.unwrap();
            sftp.close().await.unwrap();
        }));
    }
    let mut active = Vec::new();
    for _ in 0..3 {
        active.push(
            timeout(Duration::from_secs(5), starts.recv())
                .await
                .unwrap()
                .unwrap(),
        );
    }
    active.sort();
    assert_eq!(active, [0, 1, 2]);
    assert_eq!(scheduler.counts().active, 3);
    assert_eq!(scheduler.counts().waiting, 1);
    assert!(!server.dir.path().join("queue-target-3").exists());
    assert!(
        timeout(Duration::from_millis(30), starts.recv())
            .await
            .is_err()
    );
    finish.remove(0).send(()).unwrap();
    assert_eq!(
        timeout(Duration::from_secs(5), starts.recv())
            .await
            .unwrap(),
        Some(3)
    );
    for release in finish {
        release.send(()).unwrap();
    }
    for worker in workers {
        worker.await.unwrap();
    }
    assert_eq!(scheduler.counts().active, 0);
    assert_eq!(scheduler.counts().waiting, 0);
    for i in 0..4 {
        let target = server.dir.path().join(format!("queue-target-{i}"));
        assert!(target.join("empty").is_dir());
        assert_eq!(
            fs::read_to_string(target.join("data.txt")).unwrap(),
            format!("task {i}")
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn folder_tasks_preserve_empty_directories_and_resume_encrypted_manifests() {
    use hspterm_ssh_core::tree_transfer::{Direction, TreeOutcome, TreeTransfer};
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("tree-source");
    fs::create_dir_all(source.join("nested ' 中文/empty")).unwrap();
    fs::write(source.join("a.txt"), b"already complete").unwrap();
    let bytes: Vec<u8> = (0..2 * 1024 * 1024 + 83).map(|n| (n % 251) as u8).collect();
    fs::write(source.join("b.bin"), &bytes).unwrap();
    fs::write(source.join("nested ' 中文/中文.txt"), "中文 é").unwrap();
    let remote = server.dir.path().join("tree-target");
    let remote_string = remote.to_str().unwrap().to_owned();
    let mut discovered = 0;
    let mut task = TreeTransfer::scan(
        Direction::Upload,
        source.clone(),
        remote_string.clone(),
        &sftp,
        &CancellationToken::new(),
        |n| discovered = n,
    )
    .await
    .unwrap();
    assert_eq!(discovered, 6);
    assert!(!remote.exists(), "scanning must not write destinations");
    assert_eq!(task.stats().files, 3);
    assert_eq!(task.stats().directories, 3);
    let stop = CancellationToken::new();
    assert_eq!(
        task.run(&sftp, &stop, |plan, current| {
            if let Some(i) = current
                && plan.nodes[i].relative == "b.bin"
                && plan.nodes[i].acknowledged >= 65536
            {
                stop.cancel();
            }
        })
        .await
        .unwrap(),
        TreeOutcome::Paused
    );
    let checkpoint = task
        .nodes
        .iter()
        .find(|n| n.relative == "b.bin")
        .unwrap()
        .acknowledged;
    assert!(checkpoint > 0 && checkpoint < bytes.len() as u64);
    let catalog = server.dir.path().join("task-state.vault");
    let mut v = Vault::create(&catalog, b"test-only-task-master").unwrap();
    let task_id = "task-00000000000000000000000000000042";
    hspterm_storage_sync::local_tasks::LocalTaskJournal::new(&mut v)
        .save(task_id, &serde_json::to_vec(&task).unwrap())
        .unwrap();
    drop(v);
    drop(task);
    let mut v = Vault::open(&catalog, b"test-only-task-master").unwrap();
    let mut task: TreeTransfer = serde_json::from_slice(
        &hspterm_storage_sync::local_tasks::LocalTaskJournal::new(&mut v)
            .load(task_id)
            .unwrap()
            .unwrap(),
    )
    .unwrap();
    // A completed sibling must never be reopened by a resumed tree.
    fs::remove_file(source.join("a.txt")).unwrap();
    fs::write(remote.join("a.txt"), b"keep completed sibling").unwrap();
    // A destination shortened outside this task must fail resume without
    // writing, then permit the user's explicit restart/overwrite decision.
    fs::write(remote.join("b.bin"), b"").unwrap();
    assert_eq!(
        task.run(&sftp, &CancellationToken::new(), |_, _| {})
            .await
            .unwrap(),
        TreeOutcome::Partial
    );
    assert_eq!(fs::metadata(remote.join("b.bin")).unwrap().len(), 0);
    let failed = task
        .nodes
        .iter()
        .position(|n| n.relative == "b.bin")
        .unwrap();
    task.retry(
        failed,
        hspterm_ssh_core::tree_transfer::ConflictDecision::Overwrite,
    )
    .unwrap();
    assert_eq!(
        task.run(&sftp, &CancellationToken::new(), |_, _| {})
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(
        fs::read(remote.join("a.txt")).unwrap(),
        b"keep completed sibling"
    );
    assert_eq!(fs::read(remote.join("b.bin")).unwrap(), bytes);
    assert!(remote.join("nested ' 中文/empty").is_dir());
    assert_eq!(
        fs::read_to_string(remote.join("nested ' 中文/中文.txt")).unwrap(),
        "中文 é"
    );
    assert!(task.stats().total_known);
    hspterm_storage_sync::local_tasks::LocalTaskJournal::new(&mut v)
        .remove(&[task_id.into()])
        .unwrap();
    let target = server.dir.path().join("download-tree");
    let mut download = TreeTransfer::scan(
        Direction::Download,
        target.clone(),
        remote_string,
        &sftp,
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    let stop = CancellationToken::new();
    assert_eq!(
        download
            .run(&sftp, &stop, |plan, current| {
                if let Some(i) = current
                    && plan.nodes[i].acknowledged >= 65536
                {
                    stop.cancel();
                }
            })
            .await
            .unwrap(),
        TreeOutcome::Paused
    );
    let mut download: TreeTransfer =
        serde_json::from_slice(&serde_json::to_vec(&download).unwrap()).unwrap();
    assert_eq!(
        download
            .run(&sftp, &CancellationToken::new(), |_, _| {})
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(fs::read(target.join("b.bin")).unwrap(), bytes);
    assert!(target.join("nested ' 中文/empty").is_dir());
    assert_eq!(
        fs::read(target.join("a.txt")).unwrap(),
        b"keep completed sibling"
    );
    // Root single-file tasks use exactly the supplied path, without a trailing '/'.
    let single = server.dir.path().join("single.bin");
    let mut one = TreeTransfer::scan(
        Direction::Upload,
        source.join("b.bin"),
        single.to_str().unwrap().into(),
        &sftp,
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(one.nodes.len(), 1);
    assert_eq!(
        one.run(&sftp, &CancellationToken::new(), |_, _| {})
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(fs::read(&single).unwrap(), bytes);
    let occupied = server.dir.path().join("keep-existing.bin");
    fs::write(&occupied, b"keep original").unwrap();
    let mut renamed = TreeTransfer::scan(
        Direction::Download,
        occupied.clone(),
        single.to_str().unwrap().into(),
        &sftp,
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(
        renamed
            .run(&sftp, &CancellationToken::new(), |_, _| {})
            .await
            .unwrap(),
        TreeOutcome::Partial
    );
    assert!(renamed.rename_destination(0, "../escape").is_err());
    renamed.rename_destination(0, "renamed 中文.bin").unwrap();
    assert_eq!(
        renamed
            .run(&sftp, &CancellationToken::new(), |_, _| {})
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(fs::read(occupied).unwrap(), b"keep original");
    assert_eq!(
        fs::read(server.dir.path().join("renamed 中文.bin")).unwrap(),
        bytes
    );
    let no_scan = CancellationToken::new();
    no_scan.cancel();
    assert!(
        TreeTransfer::scan(
            Direction::Upload,
            source,
            "/unused-fixture-target".into(),
            &sftp,
            &no_scan,
            |_| {}
        )
        .await
        .is_err()
    );
    let raw = fs::read(catalog).unwrap();
    assert!(
        !raw.windows(b"tree-source".len())
            .any(|w| w == b"tree-source")
    );
    sftp.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn folder_tasks_isolate_failures_conflicts_and_symlink_destinations() {
    use hspterm_ssh_core::tree_transfer::{
        ConflictDecision, Direction, NodeState, TreeOutcome, TreeTransfer,
    };
    use std::os::unix::fs::symlink;
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("partial-source");
    let remote = server.dir.path().join("partial-target");
    fs::create_dir(&source).unwrap();
    fs::create_dir(&remote).unwrap();
    for name in ["a.txt", "b.txt", "z.txt"] {
        fs::write(source.join(name), name).unwrap();
    }
    fs::write(remote.join("a.txt"), b"keep conflict").unwrap();
    // A directory cannot be silently overwritten by a file.
    fs::create_dir(remote.join("b.txt")).unwrap();
    let mut task = TreeTransfer::scan(
        Direction::Upload,
        source.clone(),
        remote.to_str().unwrap().into(),
        &sftp,
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(
        task.run(&sftp, &CancellationToken::new(), |_, _| {})
            .await
            .unwrap(),
        TreeOutcome::Partial
    );
    assert_eq!(task.stats().conflicts, 1);
    assert_eq!(task.stats().failed, 1);
    assert_eq!(fs::read(remote.join("a.txt")).unwrap(), b"keep conflict");
    assert_eq!(fs::read(remote.join("z.txt")).unwrap(), b"z.txt");
    // Retry precisely the failed/conflicting nodes, not a successful sibling.
    fs::remove_file(source.join("z.txt")).unwrap();
    let a = task
        .nodes
        .iter()
        .position(|n| n.relative == "a.txt")
        .unwrap();
    let b = task
        .nodes
        .iter()
        .position(|n| n.relative == "b.txt")
        .unwrap();
    task.retry(a, ConflictDecision::Overwrite).unwrap();
    task.retry(b, ConflictDecision::Skip).unwrap();
    assert_eq!(
        task.run(&sftp, &CancellationToken::new(), |_, _| {})
            .await
            .unwrap(),
        TreeOutcome::CompleteWithSkips
    );
    assert_eq!(fs::read(remote.join("a.txt")).unwrap(), b"a.txt");
    assert_eq!(task.stats().skipped, 1);
    assert!(remote.join("b.txt").is_dir());
    assert_eq!(task.nodes[b].state, NodeState::Skipped);
    // Source directory links are reported, never followed.
    symlink(&remote, source.join("do-not-follow")).unwrap();
    let linked_target = server.dir.path().join("linked-copy");
    let mut linked = TreeTransfer::scan(
        Direction::Upload,
        source.clone(),
        linked_target.to_str().unwrap().into(),
        &sftp,
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(linked.stats().failed, 1);
    assert!(
        !linked
            .nodes
            .iter()
            .any(|n| n.relative.starts_with("do-not-follow/"))
    );
    assert_eq!(
        linked
            .run(&sftp, &CancellationToken::new(), |_, _| {})
            .await
            .unwrap(),
        TreeOutcome::Partial
    );
    assert!(!linked_target.join("do-not-follow").exists());
    // An existing destination directory link cannot redirect descendants.
    let nested = source.join("blocked");
    fs::create_dir(&nested).unwrap();
    fs::write(nested.join("must-not-escape.txt"), b"x").unwrap();
    symlink(&remote, linked_target.join("blocked")).unwrap();
    let mut blocked = TreeTransfer::scan(
        Direction::Upload,
        source,
        linked_target.to_str().unwrap().into(),
        &sftp,
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(
        blocked
            .run(&sftp, &CancellationToken::new(), |_, _| {})
            .await
            .unwrap(),
        TreeOutcome::Partial
    );
    assert!(!remote.join("must-not-escape.txt").exists());
    // Equivalent protection on local download directories.
    let local = server.dir.path().join("local-symlink-target");
    symlink(&remote, &local).unwrap();
    let mut download = TreeTransfer::scan(
        Direction::Download,
        local,
        nested.to_str().unwrap().into(),
        &sftp,
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(
        download
            .run(&sftp, &CancellationToken::new(), |_, _| {})
            .await
            .unwrap(),
        TreeOutcome::Partial
    );
    assert!(!remote.join("must-not-escape.txt").exists());
    sftp.close().await.unwrap();
}

struct Server {
    child: Child,
    dir: tempfile::TempDir,
    config: ConnectConfig,
    fingerprint: String,
}
impl Drop for Server {
    fn drop(&mut self) {
        if self.child.try_wait().unwrap().is_none() {
            self.child.kill().unwrap();
        }
        self.child.wait().unwrap();
    }
}
fn generate_key(path: &Path, password: &str) {
    let output = Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", password, "-f"])
        .arg(path)
        .output()
        .expect("ssh-keygen required for OpenSSH integration tests");
    assert!(output.status.success(), "ssh-keygen failed");
}
impl Server {
    async fn start() -> Self {
        Self::start_with_forwarding(true).await
    }
    async fn start_with_forwarding(forwarding: bool) -> Self {
        Self::start_with_options(forwarding, true).await
    }
    async fn start_with_options(forwarding: bool, agent: bool) -> Self {
        Self::start_with_host_key(forwarding, agent, "ed25519", "").await
    }
    async fn start_with_host_key(forwarding: bool, agent: bool, kind: &str, extra: &str) -> Self {
        let mut environment = String::new();
        let mut extra_options = String::new();
        for line in extra.lines() {
            if let Some(vars) = line.strip_prefix("SetEnv ") {
                environment.push(' ');
                environment.push_str(vars);
            } else {
                extra_options.push_str(line);
                extra_options.push('\n');
            }
        }
        let agent = if agent { "yes" } else { "no" };
        let forward = if forwarding { "yes" } else { "no" };
        let dir = tempfile::tempdir().unwrap();
        let host = dir.path().join("host");
        let client = dir.path().join("client");
        if kind == "rsa" {
            openssh_rsa::key(&host, "2048", "");
        } else {
            generate_key(&host, "");
        }
        generate_key(&client, "test-only-key-passphrase");
        fs::copy(
            client.with_extension("pub"),
            dir.path().join("authorized_keys"),
        )
        .unwrap();
        let output = Command::new("ssh-keygen")
            .args(["-l", "-E", "sha256", "-f"])
            .arg(&host)
            .output()
            .unwrap();
        assert!(output.status.success());
        let fingerprint = String::from_utf8(output.stdout)
            .unwrap()
            .split_whitespace()
            .nth(1)
            .unwrap()
            .to_owned();
        let username = String::from_utf8(Command::new("id").arg("-un").output().unwrap().stdout)
            .unwrap()
            .trim()
            .to_owned();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let path = dir.path().join("sshd_config");
        fs::write(&path, format!("ListenAddress 127.0.0.1\nPort {port}\nHostKey {}\nAuthorizedKeysFile {}\nPidFile {}\nStrictModes no\nUsePAM no\nPermitRootLogin yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nLogLevel ERROR\nSubsystem sftp internal-sftp\nAllowUsers {username}\nAllowTcpForwarding {forward}\nAllowAgentForwarding {agent}\nPrintLastLog no\nSetEnv HOME={} HISTFILE=/dev/null{environment}\n", host.display(), dir.path().join("authorized_keys").display(), dir.path().join("sshd.pid").display(), dir.path().display())).unwrap();
        if !extra.is_empty() {
            use std::io::Write;
            fs::OpenOptions::new()
                .append(true)
                .open(&path)
                .unwrap()
                .write_all(extra_options.as_bytes())
                .unwrap();
        }
        drop(listener);
        let mut child = Command::new("/usr/sbin/sshd")
            .args(["-D", "-e", "-f"])
            .arg(path)
            .stdout(Stdio::null())
            .stderr(Stdio::from(
                fs::File::create(dir.path().join("sshd-errors.log")).unwrap(),
            ))
            .spawn()
            .expect("OpenSSH server required");
        let mut ready = false;
        for _ in 0..100 {
            if child.try_wait().unwrap().is_some() {
                panic!("isolated sshd failed to start; check prerequisites");
            }
            if tokio::net::TcpStream::connect(("127.0.0.1", port))
                .await
                .is_ok()
            {
                ready = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        if !ready {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("sshd startup timed out");
        }
        let config = ConnectConfig::new("127.0.0.1".into(), port, username);
        Self {
            child,
            dir,
            config,
            fingerprint,
        }
    }
    fn auth(&self) -> Authentication {
        Authentication::PrivateKey {
            openssh: Zeroizing::new(fs::read_to_string(self.dir.path().join("client")).unwrap()),
            passphrase: Some(Zeroizing::new("test-only-key-passphrase".into())),
        }
    }
    fn pinned(&self) -> HostKeyPolicy {
        HostKeyPolicy::Pinned {
            sha256: self.fingerprint.clone(),
        }
    }
    async fn connect(&self) -> SshConnection {
        let result = SshConnection::connect(
            self.config.clone(),
            self.auth(),
            self.pinned(),
            CancellationToken::new(),
        )
        .await;
        result.unwrap_or_else(|error| {
            use std::io::Read;
            let mut bytes = Vec::new();
            fs::File::open(self.dir.path().join("sshd-errors.log"))
                .unwrap()
                .take(8192)
                .read_to_end(&mut bytes)
                .unwrap();
            panic!(
                "controlled OpenSSH connect failed: {}; disposable server errors: {}",
                error_category(&error),
                String::from_utf8_lossy(&bytes)
            );
        })
    }
}
// Only static variants / I/O kinds, never a credential-bearing debug payload.
fn error_category(error: &SshError) -> String {
    match error {
        SshError::Protocol(e) => match e {
            russh::Error::Disconnect => "Protocol::Disconnect".into(),
            russh::Error::HUP => "Protocol::HUP".into(),
            russh::Error::SendError => "Protocol::SendError".into(),
            russh::Error::IO(e) => format!("Protocol::IO::{:?}", e.kind()),
            _ => format!("Protocol::{:?}", std::mem::discriminant(e)),
        },
        SshError::Io(e) => format!("Io::{:?}", e.kind()),
        _ => format!("{error:?}"),
    }
}
async fn until_text(ssh: &mut SshConnection, terminal: &mut Terminal, expected: &str) {
    timeout(Duration::from_secs(10), async {
        while !terminal.snapshot().text().contains(expected) {
            match ssh.read().await.unwrap() {
                PtyEvent::Data(data) => {
                    terminal.feed(&data).unwrap();
                    // Feed protocol-generated terminal responses back to the associated PTY.
                    for event in terminal.take_events() {
                        if let alacritty_terminal::event::Event::PtyWrite(reply) = event {
                            ssh.write(reply.as_bytes()).await.unwrap();
                        }
                    }
                }
                PtyEvent::ExitStatus(_) => {}
                PtyEvent::End => panic!("PTY ended before expected output"),
            }
        }
    })
    .await
    .expect("remote PTY output timed out");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn posix_rename_replaces_an_existing_file_for_edit_saves() {
    // Round-10: the local-edit save flow renames a temp sibling over the
    // original. Plain SFTP rename refuses existing destinations, so the
    // overwrite path must use posix-rename when the real server offers it.
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let dir = server.dir.path().join("posix rename edit");
    fs::create_dir_all(&dir).unwrap();
    let original = dir.join("notes.txt");
    let temp = dir.join(".hspterm-edit-1");
    fs::write(&original, b"old remote content").unwrap();
    fs::write(&temp, b"new local content").unwrap();
    // Plain rename over an existing file fails (server-dependent message).
    assert!(
        sftp.rename(temp.to_str().unwrap(), original.to_str().unwrap())
            .await
            .is_err()
    );
    assert!(
        sftp.supports_posix_rename(),
        "test sshd must advertise posix-rename@openssh.com"
    );
    assert_eq!(
        sftp.posix_rename(temp.to_str().unwrap(), original.to_str().unwrap())
            .await
            .unwrap(),
        true
    );
    assert_eq!(fs::read(&original).unwrap(), b"new local content");
    assert!(!temp.exists());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn encrypted_private_key_real_pty_resize_and_sftp_share_transport() {
    let server = Server::start().await;
    let mut ssh = server.connect().await;
    let mut term = Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap();
    // Split the marker so echoed command text cannot satisfy output assertions.
    ssh.write(b"printf '\\033[31m%s%s\\033[0m\\n' HSP_ READY\n")
        .await
        .unwrap();
    until_text(&mut ssh, &mut term, "HSP_READY").await;
    ssh.resize(100, 32).await.unwrap();
    term.resize(Size::new(100, 32).unwrap()).unwrap();
    ssh.write(b"stty size\n").await.unwrap();
    until_text(&mut ssh, &mut term, "32 100").await;
    let sftp = ssh.open_sftp().await.unwrap();
    let remote = server
        .dir
        .path()
        .join("sftp-test.bin")
        .to_str()
        .unwrap()
        .to_owned();
    let payload = vec![0x5a; 200_000];
    let mut file = sftp.create(&remote).await.unwrap();
    file.write_all(&payload).await.unwrap();
    file.flush().await.unwrap();
    file.close().await.unwrap();
    assert_eq!(
        sftp.metadata(&remote).await.unwrap().len(),
        payload.len() as u64
    );
    let mut file = sftp.open(&remote).await.unwrap();
    let mut received = Vec::new();
    file.read_to_end(&mut received).await.unwrap();
    file.close().await.unwrap();
    assert_eq!(received, payload);
    assert!(
        sftp.read_dir(server.dir.path().to_str().unwrap())
            .await
            .unwrap()
            .any(|e| e.file_name() == "sftp-test.bin")
    );
    sftp.remove_file(remote).await.unwrap();
    sftp.close().await.unwrap();
    ssh.write(b"printf '%s%s\\n' STILL_ CONNECTED\n")
        .await
        .unwrap();
    until_text(&mut ssh, &mut term, "STILL_CONNECTED").await;
    ssh.close().await.unwrap();
    ssh.close().await.unwrap();
    assert!(ssh.is_closed());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tofu_confirmation_can_persist_before_accepting_and_changed_key_blocks() {
    let server = Server::start().await;
    let (requests, mut receive) = mpsc::channel(1);
    let config = server.config.clone();
    let auth = server.auth();
    let connect = tokio::spawn(async move {
        SshConnection::connect(
            config,
            auth,
            HostKeyPolicy::Confirm { requests },
            CancellationToken::new(),
        )
        .await
    });
    let request = timeout(Duration::from_secs(5), receive.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(request.key.sha256, server.fingerprint);
    let path = server.dir.path().join("trust.sqlite");
    let mut vault = Vault::create(&path, b"test-only-master").unwrap();
    vault
        .put("trusted-test-host", request.key.sha256.as_bytes())
        .unwrap();
    request.decision.send(true).unwrap();
    let mut ssh = connect.await.unwrap().unwrap();
    ssh.close().await.unwrap();
    drop(vault);
    let vault = Vault::open(&path, b"test-only-master").unwrap();
    let fingerprint =
        String::from_utf8(vault.get("trusted-test-host").unwrap().unwrap().to_vec()).unwrap();
    let mut ssh = SshConnection::connect(
        server.config.clone(),
        server.auth(),
        HostKeyPolicy::Pinned {
            sha256: fingerprint,
        },
        CancellationToken::new(),
    )
    .await
    .unwrap();
    ssh.close().await.unwrap();
    let result = SshConnection::connect(
        server.config.clone(),
        server.auth(),
        HostKeyPolicy::Pinned {
            sha256: "SHA256:changed".into(),
        },
        CancellationToken::new(),
    )
    .await;
    assert!(matches!(result, Err(SshError::HostKeyChanged { .. })));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rejected_key_bad_credentials_and_cancel_are_errors() {
    let server = Server::start().await;
    let (requests, mut rx) = mpsc::channel(1);
    let config = server.config.clone();
    let auth = server.auth();
    let attempt = tokio::spawn(async move {
        SshConnection::connect(
            config,
            auth,
            HostKeyPolicy::Confirm { requests },
            CancellationToken::new(),
        )
        .await
    });
    timeout(Duration::from_secs(5), rx.recv())
        .await
        .unwrap()
        .unwrap()
        .decision
        .send(false)
        .unwrap();
    assert!(matches!(
        attempt.await.unwrap(),
        Err(SshError::HostKeyRejected)
    ));
    let wrong = Authentication::Password(Zeroizing::new("test-only-wrong".into()));
    assert!(matches!(
        SshConnection::connect(
            server.config.clone(),
            wrong,
            server.pinned(),
            CancellationToken::new()
        )
        .await,
        Err(SshError::Authentication)
    ));
    let cancel = CancellationToken::new();
    cancel.cancel();
    assert!(matches!(
        SshConnection::connect(
            server.config.clone(),
            server.auth(),
            server.pinned(),
            cancel
        )
        .await,
        Err(SshError::Cancelled)
    ));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancellation_during_host_key_prompt_and_stalled_handshake_release_streams() {
    let server = Server::start().await;
    let (requests, mut rx) = mpsc::channel(1);
    let cancel = CancellationToken::new();
    let token = cancel.clone();
    let config = server.config.clone();
    let auth = server.auth();
    let attempt = tokio::spawn(async move {
        SshConnection::connect(config, auth, HostKeyPolicy::Confirm { requests }, token).await
    });
    let mut request = timeout(Duration::from_secs(5), rx.recv())
        .await
        .unwrap()
        .unwrap();
    cancel.cancel();
    assert!(matches!(
        timeout(Duration::from_secs(2), attempt)
            .await
            .unwrap()
            .unwrap(),
        Err(SshError::Cancelled)
    ));
    timeout(Duration::from_secs(2), request.decision.closed())
        .await
        .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut config = server.config.clone();
    config.port = listener.local_addr().unwrap().port();
    config.timeout = Duration::from_millis(100);
    let auth = server.auth();
    let pinned = server.pinned();
    let attempt = tokio::spawn(async move {
        SshConnection::connect(config, auth, pinned, CancellationToken::new()).await
    });
    let (mut stream, _) = listener.accept().await.unwrap();
    assert!(matches!(attempt.await.unwrap(), Err(SshError::Timeout(_))));
    let mut bytes = Vec::new();
    timeout(Duration::from_secs(2), stream.read_to_end(&mut bytes))
        .await
        .unwrap()
        .unwrap();
}

async fn until_alternate(ssh: &mut SshConnection, terminal: &mut Terminal, alternate: bool) {
    timeout(Duration::from_secs(10), async {
        while terminal.snapshot().alternate_screen != alternate {
            match ssh.read().await.unwrap() {
                PtyEvent::Data(data) => {
                    terminal.feed(&data).unwrap();
                    for event in terminal.take_events() {
                        if let alacritty_terminal::event::Event::PtyWrite(reply) = event {
                            ssh.write(reply.as_bytes()).await.unwrap();
                        }
                    }
                }
                PtyEvent::ExitStatus(_) => {}
                PtyEvent::End => panic!("PTY ended while waiting for alternate screen"),
            }
        }
    })
    .await
    .expect("TUI alternate-screen transition timed out");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_vim_tmux_and_htop_interact_through_terminal_parser() {
    for binary in ["vim", "tmux", "htop"] {
        assert!(
            Command::new(binary).arg("--version").output().is_ok(),
            "required TUI program missing: {binary}"
        );
    }
    let server = Server::start().await;
    let mut ssh = server.connect().await;
    let mut term = Terminal::new(Size::new(80, 24).unwrap(), 1000).unwrap();
    let path = server.dir.path().join("vim.txt");
    ssh.write(format!("vim -Nu NONE -n '{}'\n", path.display()).as_bytes())
        .await
        .unwrap();
    until_alternate(&mut ssh, &mut term, true).await;
    ssh.write("i中文组合e\u{301}\x1b:wq\r".as_bytes())
        .await
        .unwrap();
    until_alternate(&mut ssh, &mut term, false).await;
    assert_eq!(fs::read_to_string(&path).unwrap(), "中文组合e\u{301}\n");
    // Dedicated tmux socket beneath the temporary directory; never attach to a user's server.
    let socket = server.dir.path().join("tmux.sock");
    ssh.write(format!("tmux -S '{}' -f /dev/null new-session\n", socket.display()).as_bytes())
        .await
        .unwrap();
    until_alternate(&mut ssh, &mut term, true).await;
    ssh.resize(96, 28).await.unwrap();
    term.resize(Size::new(96, 28).unwrap()).unwrap();
    ssh.write(b"printf '%s%s\\n' TMUX_ READY\n").await.unwrap();
    until_text(&mut ssh, &mut term, "TMUX_READY").await;
    ssh.write(b"exit\n").await.unwrap();
    until_alternate(&mut ssh, &mut term, false).await;
    ssh.write(b"htop\n").await.unwrap();
    until_alternate(&mut ssh, &mut term, true).await;
    ssh.write(b"q").await.unwrap();
    until_alternate(&mut ssh, &mut term, false).await;
    ssh.write(b"printf '%s%s\\n' TUI_ COMPLETE\n")
        .await
        .unwrap();
    until_text(&mut ssh, &mut term, "TUI_COMPLETE").await;
    ssh.close().await.unwrap();
}

async fn session_text(session: &hspterm_ssh_core::ManagedSession, expected: &str) {
    timeout(Duration::from_secs(10), async {
        while !session.snapshot().unwrap().text().contains(expected) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("managed session did not process remote output");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn managed_session_keeps_disconnected_frame_and_reconnects_only_on_request() {
    use hspterm_ssh_core::{ManagedSession, SessionEvent, SessionPhase};
    let server = Server::start().await;
    let (mut session, mut events) = ManagedSession::new(Size::new(80, 24).unwrap(), 1000).unwrap();
    let markers = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counts = markers.clone();
    let drain = tokio::spawn(async move {
        while let Some(event) = events.recv().await {
            if matches!(event, SessionEvent::Reconnected { .. }) {
                counts.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }
        }
    });
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    assert_eq!(session.status().generation, 1);
    assert!(matches!(
        session
            .connect(server.config.clone(), server.auth(), server.pinned())
            .await,
        Err(SshError::Busy)
    ));
    session
        .write(b"printf '%s%s\\n' KEEP_ FRAME\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "KEEP_FRAME").await;
    session.write(b"exit\n".to_vec()).await.unwrap();
    timeout(Duration::from_secs(5), async {
        while session.status().phase != SessionPhase::Disconnected {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let frame = session.snapshot().unwrap().text();
    assert!(frame.contains("KEEP_FRAME"));
    tokio::time::sleep(Duration::from_millis(250)).await;
    assert_eq!(session.status().phase, SessionPhase::Disconnected);
    assert_eq!(session.status().generation, 1);
    assert_eq!(session.snapshot().unwrap().text(), frame);
    assert!(matches!(
        session.write(b"\r".to_vec()).await,
        Err(SshError::Disconnected)
    ));
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    assert_eq!(session.status().generation, 2);
    session
        .write(b"printf '%s%s\\n' NEW_ GENERATION\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "NEW_GENERATION").await;
    session.scroll(1000).unwrap();
    assert!(session.snapshot().unwrap().text().contains("KEEP_FRAME"));
    session.close().await.unwrap();
    session.close().await.unwrap();
    assert_eq!(session.status().phase, SessionPhase::Closed);
    drain.await.unwrap();
    assert_eq!(markers.load(std::sync::atomic::Ordering::SeqCst), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn managed_session_rejects_duplicate_pending_attempt_and_cancels_prompt() {
    use hspterm_ssh_core::{ManagedSession, SessionPhase};
    let server = Server::start().await;
    let (mut session, _events) = ManagedSession::new(Size::new(80, 24).unwrap(), 100).unwrap();
    let (requests, mut rx) = mpsc::channel(1);
    {
        let pending = session.connect(
            server.config.clone(),
            server.auth(),
            HostKeyPolicy::Confirm { requests },
        );
        tokio::pin!(pending);
        let request = tokio::select! {
            r = &mut pending => panic!("connection completed without host key confirmation: {r:?}"),
            r = timeout(Duration::from_secs(5), rx.recv()) => r.unwrap().unwrap(),
        };
        assert!(matches!(
            session
                .connect(server.config.clone(), server.auth(), server.pinned())
                .await,
            Err(SshError::Busy)
        ));
        session.cancel_connect();
        assert!(matches!(pending.await, Err(SshError::Cancelled)));
        drop(request);
    }
    assert_eq!(session.status().phase, SessionPhase::Failed);
    assert_eq!(session.status().generation, 1);
    // Failed panes remain reusable, but only an explicit connect starts a new transport.
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    session.close().await.unwrap();
}

#[derive(Clone)]
struct PasswordServer;
impl russh::server::Server for PasswordServer {
    type Handler = Self;
    fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Self {
        Self
    }
}
impl russh::server::Handler for PasswordServer {
    type Error = russh::Error;
    async fn auth_password(
        &mut self,
        username: &str,
        password: &str,
    ) -> Result<russh::server::Auth, Self::Error> {
        Ok(
            if username == "test-user" && password == "test-only-password" {
                russh::server::Auth::Accept
            } else {
                russh::server::Auth::Reject {
                    proceed_with_methods: None,
                    partial_success: false,
                }
            },
        )
    }
    async fn channel_open_session(
        &mut self,
        _channel: russh::Channel<russh::server::Msg>,
        reply: russh::server::ChannelOpenHandle,
        _session: &mut russh::server::Session,
    ) -> Result<(), Self::Error> {
        reply.accept().await;
        Ok(())
    }
    async fn pty_request(
        &mut self,
        channel: russh::ChannelId,
        _term: &str,
        _columns: u32,
        _rows: u32,
        _pixels_x: u32,
        _pixels_y: u32,
        _modes: &[(russh::Pty, u32)],
        session: &mut russh::server::Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        Ok(())
    }
    async fn shell_request(
        &mut self,
        channel: russh::ChannelId,
        session: &mut russh::server::Session,
    ) -> Result<(), Self::Error> {
        // Deliberately send data before acknowledgement to cover early-output preservation.
        session.data(channel, b"password-login-ok".to_vec())?;
        session.channel_success(channel)?;
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn password_authentication_success_and_failure_against_controlled_server() {
    use russh::server::Server as _;
    let dir = tempfile::tempdir().unwrap();
    let key_path = dir.path().join("host");
    generate_key(&key_path, "");
    let key = russh::keys::load_secret_key(&key_path, None).unwrap();
    let fingerprint = key
        .public_key()
        .fingerprint(russh::keys::HashAlg::Sha256)
        .to_string();
    let config = std::sync::Arc::new(russh::server::Config {
        keys: vec![key],
        auth_rejection_time: Duration::ZERO,
        auth_rejection_time_initial: Some(Duration::ZERO),
        ..russh::server::Config::default()
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let stop = CancellationToken::new();
    let token = stop.clone();
    let task = tokio::spawn(async move {
        let mut server = PasswordServer;
        let running = server.run_on_socket(config, &listener);
        let handle = running.handle();
        tokio::spawn(async move {
            token.cancelled().await;
            handle.shutdown("test finished".into());
        });
        running.await.unwrap();
    });
    let config = ConnectConfig::new("127.0.0.1".into(), port, "test-user".into());
    let policy = HostKeyPolicy::Pinned {
        sha256: fingerprint,
    };
    let mut connection = SshConnection::connect(
        config.clone(),
        Authentication::Password(Zeroizing::new("test-only-password".into())),
        policy.clone(),
        CancellationToken::new(),
    )
    .await
    .unwrap();
    assert_eq!(
        connection.read().await.unwrap(),
        PtyEvent::Data(b"password-login-ok".to_vec())
    );
    connection.close().await.unwrap();
    let result = SshConnection::connect(
        config,
        Authentication::Password(Zeroizing::new("test-only-wrong".into())),
        policy,
        CancellationToken::new(),
    )
    .await;
    assert!(matches!(result, Err(SshError::Authentication)));
    stop.cancel();
    task.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn managed_session_processes_large_output_without_a_renderer_and_flushes_sync_timeout() {
    use hspterm_ssh_core::ManagedSession;
    let server = Server::start().await;
    let (mut session, mut events) = ManagedSession::new(Size::new(80, 24).unwrap(), 1000).unwrap();
    let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    session.write(b"i=0; while [ $i -lt 10000 ]; do printf 'row-%s\\n' \"$i\"; i=$((i+1)); done; printf '%s%s\\n' OUTPUT_ COMPLETE\n".to_vec()).await.unwrap();
    session_text(&session, "OUTPUT_COMPLETE").await;
    assert_eq!(session.snapshot().unwrap().history_lines, 1000);
    session
        .write(b"printf '\\033[?2026h%s%s' SYNC_ TIMEOUT\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "SYNC_TIMEOUT").await;
    session.close().await.unwrap();
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_connection_test_does_not_require_target_authentication_or_open_a_shell() {
    let server = Server::start().await;
    let mut config = server.config.clone();
    config.username = "hspterm-test-user-that-does-not-exist".into();
    // Success despite having no credentials and an unavailable login account.
    SshConnection::test_connection(config.clone(), server.pinned(), CancellationToken::new())
        .await
        .unwrap();
    let mismatch = HostKeyPolicy::Pinned {
        sha256: "SHA256:changed".into(),
    };
    let rejected = SshConnection::test_connection(config, mismatch, CancellationToken::new()).await;
    assert!(
        matches!(rejected, Err(SshError::HostKeyChanged { .. })),
        "unexpected rejection: {rejected:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn typed_input_updates_frames_without_idle_polling_and_paste_requires_confirmation() {
    use hspterm_ssh_core::{InputOutcome, ManagedSession, TerminalInput};
    use hspterm_term_core::{Key, KeyEvent};
    let server = Server::start().await;
    let (session, mut events) = ManagedSession::new(Size::new(80, 24).unwrap(), 100).unwrap();
    let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
    let mut changes = session.subscribe_frames();
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    session
        .input(TerminalInput::Text("printf '%s%s\\n' TYPED_ READY".into()))
        .await
        .unwrap();
    session
        .input(TerminalInput::Key(KeyEvent::press(Key::Enter)))
        .await
        .unwrap();
    session_text(&session, "TYPED_READY").await;
    // Seeing the command's marker does not mean the following newline/prompt
    // has arrived. Establish quiescence before checking the idle snapshot API;
    // otherwise legitimate remote output races the two separate snapshots.
    timeout(Duration::from_secs(5), async {
        loop {
            changes.borrow_and_update();
            if timeout(Duration::from_millis(100), changes.changed())
                .await
                .is_err()
            {
                break;
            }
        }
    })
    .await
    .expect("remote output did not become idle");
    let frame = session.snapshot().unwrap();
    assert!(
        session
            .snapshot_if_changed(Some(frame.revision))
            .unwrap()
            .is_none()
    );
    assert!(matches!(
        session
            .input(TerminalInput::Paste {
                text: "do-not-send\n".into(),
                confirmed: false
            })
            .await
            .unwrap(),
        InputOutcome::Confirm { .. }
    ));
    tokio::time::sleep(Duration::from_millis(100)).await;
    changes.borrow_and_update();
    assert!(
        timeout(Duration::from_millis(80), changes.changed())
            .await
            .is_err()
    );
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn protocol_query_flood_is_answered_inside_actor_without_ui_round_trip() {
    use hspterm_ssh_core::ManagedSession;
    let server = Server::start().await;
    let script = server.dir.path().join("queries.py");
    fs::write(
        &script,
        r#"import os, tty, termios, select, time
old = termios.tcgetattr(0)
try:
    tty.setraw(0)
    os.write(1, b'\x1b]10;?\x07' * 64)
    data = b''
    end = time.monotonic() + 5
    while data.count(b'\x07') < 64 and time.monotonic() < end:
        if select.select([0], [], [], .1)[0]:
            data += os.read(0, 65536)
    assert data.count(b'\x07') == 64
finally:
    termios.tcsetattr(0, termios.TCSANOW, old)
print('QUERY_' + 'DONE', flush=True)
"#,
    )
    .unwrap();
    let (mut session, mut events) = ManagedSession::new(Size::new(80, 24).unwrap(), 100).unwrap();
    let drain = tokio::spawn(async move {
        while let Some(event) = events.recv().await {
            assert!(!matches!(
                event,
                hspterm_ssh_core::SessionEvent::Terminal {
                    event: alacritty_terminal::event::Event::ColorRequest(..),
                    ..
                }
            ));
        }
    });
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    session
        .write(format!("python3 '{}'\n", script.display()).into_bytes())
        .await
        .unwrap();
    session_text(&session, "QUERY_DONE").await;
    session.close().await.unwrap();
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn managed_sftp_negotiation_does_not_block_pty_and_explicit_disconnect_retains_frame() {
    use hspterm_ssh_core::{ManagedSession, SessionPhase};
    let server = Server::start().await;
    let (session, mut events) = ManagedSession::new(Size::new(90, 30).unwrap(), 1000).unwrap();
    let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    session
        .write(b"python3 -c \"print('SFTP_' + 'PTY'); print('output\\n' * 10000)\"\n".to_vec())
        .await
        .unwrap();
    let sftp = timeout(Duration::from_secs(10), session.open_sftp())
        .await
        .unwrap()
        .unwrap();
    let target = server
        .dir
        .path()
        .join("sftp-同时读写.txt")
        .to_str()
        .unwrap()
        .to_owned();
    let mut remote_file = sftp.create(target.clone()).await.unwrap();
    remote_file
        .write_all("SSH 与 SFTP 同会话\n".as_bytes())
        .await
        .unwrap();
    remote_file.shutdown().await.unwrap();
    assert_eq!(
        sftp.read(target.clone()).await.unwrap(),
        "SSH 与 SFTP 同会话\n".as_bytes()
    );
    session
        .write(b"printf '%s%s\\n' AFTER_ SFTP\n".to_vec())
        .await
        .unwrap();
    session_text(&session, "AFTER_SFTP").await;
    let generation = session.status().generation;
    session.disconnect().await.unwrap();
    assert_eq!(session.status().phase, SessionPhase::Disconnected);
    assert_eq!(session.status().generation, generation);
    assert!(session.snapshot().unwrap().text().contains("AFTER_SFTP"));
    assert!(session.open_sftp().await.is_err());
    assert!(session.write(b"must-not-send".to_vec()).await.is_err());
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    assert_eq!(session.status().generation, generation + 1);
    let resumed = session.open_sftp().await.unwrap();
    assert_eq!(
        resumed.read(target).await.unwrap(),
        "SSH 与 SFTP 同会话\n".as_bytes()
    );
    resumed.close().await.unwrap();
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn passive_osc7_stays_in_its_ssh_session_and_is_lost_on_disconnect() {
    use hspterm_ssh_core::{ManagedSession, SessionEvent};
    let server = Server::start().await;
    let (session, mut events) = ManagedSession::new(Size::new(100, 8).unwrap(), 100).unwrap();
    let (other, mut other_events) = ManagedSession::new(Size::new(100, 8).unwrap(), 100).unwrap();
    let (directory_updates, mut observed_directory) = tokio::sync::watch::channel(None);
    let drain = tokio::spawn(async move {
        while let Some(event) = events.recv().await {
            if let SessionEvent::WorkingDirectory {
                generation,
                directory,
            } = event
            {
                directory_updates.send_replace(Some((generation, directory)));
            }
        }
    });
    let other_drain = tokio::spawn(async move { while other_events.recv().await.is_some() {} });
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    other
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    let other_cwd = other.snapshot().unwrap().working_directory;
    session
        .write(
            b"unset PROMPT_COMMAND; PS1=''; printf '\\033]7;file://127.0.0.1/home/a%%20b\\007'; printf '%s%s\\n' OSC7_ READY\n"
                .to_vec(),
        )
        .await
        .unwrap();
    session_text(&session, "OSC7_READY").await;
    let cwd = session.snapshot().unwrap().working_directory.unwrap();
    timeout(Duration::from_secs(10), async {
        loop {
            if observed_directory
                .borrow_and_update()
                .as_ref()
                .is_some_and(|(generation, cwd)| {
                    *generation == session.status().generation
                        && cwd.as_ref().is_some_and(|cwd| cwd.path == "/home/a b")
                })
            {
                break;
            }
            observed_directory.changed().await.unwrap();
        }
    })
    .await
    .expect("passive metadata must reach the event consumer without a renderer");
    assert_eq!(cwd.path, "/home/a b");
    assert_eq!(
        cwd.resolve("child", "127.0.0.1").unwrap(),
        "/home/a b/child"
    );
    assert!(cwd.resolve("child", "different-server").is_err());
    assert_eq!(other.snapshot().unwrap().working_directory, other_cwd);
    session.disconnect().await.unwrap();
    assert!(session.snapshot().unwrap().working_directory.is_none());
    timeout(Duration::from_secs(10), async {
        loop {
            if observed_directory
                .borrow_and_update()
                .as_ref()
                .is_some_and(|(generation, cwd)| {
                    *generation == session.status().generation && cwd.is_none()
                })
            {
                break;
            }
            observed_directory.changed().await.unwrap();
        }
    })
    .await
    .expect("disconnect must invalidate passive metadata without waiting for a frame");
    assert!(session.snapshot().unwrap().text().contains("OSC7_READY"));
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    assert!(
        session
            .snapshot()
            .unwrap()
            .working_directory
            .is_none_or(|cwd| cwd.path != "/home/a b")
    );
    session.shutdown();
    other.shutdown();
    session.wait_closed().await;
    other.wait_closed().await;
    drain.await.unwrap();
    other_drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn passive_osc133_reports_only_phase_and_status_and_is_reset_on_disconnect() {
    use hspterm_ssh_core::ManagedSession;
    use hspterm_term_core::ShellPhase;
    let server = Server::start().await;
    let (session, mut events) = ManagedSession::new(Size::new(100, 8).unwrap(), 100).unwrap();
    let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    session.write(b"unset PROMPT_COMMAND; PS1=''; printf '\\033[2J\\033[H\\033]133;A\\007prompt> \\033]133;B\\007command\\r\\n\\033]133;C;cmdline=never-collected\\007output\\r\\n\\033]133;D;7\\007'; printf '%s%s\\n' OSC133_ READY\n".to_vec()).await.unwrap();
    session_text(&session, "OSC133_READY").await;
    let context = session.shell_context();
    assert_eq!(context.phase, ShellPhase::Finished);
    assert_eq!(context.exit_status, Some(7));
    assert!(
        !session
            .snapshot()
            .unwrap()
            .text()
            .contains("never-collected")
    );
    let generation = session.status().generation;
    session.disconnect().await.unwrap();
    assert_eq!(session.shell_context().phase, ShellPhase::Unknown);
    assert!(session.snapshot().unwrap().text().contains("OSC133_READY"));
    assert_eq!(session.status().generation, generation);
    session
        .connect(server.config.clone(), server.auth(), server.pinned())
        .await
        .unwrap();
    assert_eq!(session.shell_context().phase, ShellPhase::Unknown);
    assert_eq!(session.status().generation, generation + 1);
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn streaming_files_resume_by_acknowledged_offset_and_keep_partial_data() {
    use hspterm_ssh_core::transfer::{FileDisposition, TransferError, download_file, upload_file};
    use std::io::Write as _;
    let server = Server::start().await;
    let mut connection = SshConnection::connect(
        server.config.clone(),
        server.auth(),
        server.pinned(),
        CancellationToken::new(),
    )
    .await
    .unwrap();
    let sftp = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("source 中文.bin");
    let destination = server.dir.path().join("remote ' 文件.bin");
    let downloaded = server.dir.path().join("downloaded 中文.bin");
    let bytes: Vec<u8> = (0..2 * 1024 * 1024 + 137)
        .map(|n| (n % 251) as u8)
        .collect();
    fs::write(&source, &bytes).unwrap();
    let stop = CancellationToken::new();
    let mut checkpoint = 0;
    let result = upload_file(
        &sftp,
        &source,
        destination.to_str().unwrap(),
        FileDisposition::CreateNew,
        &stop,
        |p| {
            checkpoint = p.acknowledged;
            if checkpoint >= 65536 {
                stop.cancel();
            }
        },
    )
    .await;
    assert!(matches!(result, Err(TransferError::Cancelled)));
    assert!(checkpoint > 0 && checkpoint < bytes.len() as u64);
    let partial = fs::read(&destination).unwrap();
    assert_eq!(partial, bytes[..partial.len()]);
    let fresh = CancellationToken::new();
    let mut last = checkpoint;
    let complete = upload_file(
        &sftp,
        &source,
        destination.to_str().unwrap(),
        FileDisposition::Resume { offset: checkpoint },
        &fresh,
        |p| {
            assert!(p.acknowledged >= last);
            last = p.acknowledged;
        },
    )
    .await
    .unwrap();
    assert_eq!(complete.acknowledged, bytes.len() as u64);
    assert_eq!(fs::read(&destination).unwrap(), bytes);
    assert!(matches!(
        upload_file(
            &sftp,
            &source,
            destination.to_str().unwrap(),
            FileDisposition::CreateNew,
            &fresh,
            |_| {}
        )
        .await,
        Err(TransferError::Conflict)
    ));
    assert!(matches!(
        upload_file(
            &sftp,
            &source,
            destination.to_str().unwrap(),
            FileDisposition::Resume {
                offset: bytes.len() as u64 + 1
            },
            &fresh,
            |_| {}
        )
        .await,
        Err(TransferError::InvalidResume)
    ));
    assert_eq!(fs::read(&destination).unwrap(), bytes);

    let pause_download = CancellationToken::new();
    let mut downloaded_offset = 0;
    assert!(matches!(
        download_file(
            &sftp,
            destination.to_str().unwrap(),
            &downloaded,
            FileDisposition::CreateNew,
            &pause_download,
            |p| {
                downloaded_offset = p.acknowledged;
                if downloaded_offset >= 65536 {
                    pause_download.cancel();
                }
            }
        )
        .await,
        Err(TransferError::Cancelled)
    ));
    assert!(downloaded_offset > 0 && downloaded_offset < bytes.len() as u64);
    // Simulate a write reaching disk just before cancellation/checkpoint persistence.
    // Resume rewrites this unacknowledged suffix rather than truncating the file.
    fs::OpenOptions::new()
        .append(true)
        .open(&downloaded)
        .unwrap()
        .write_all(b"unacknowledged suffix")
        .unwrap();
    download_file(
        &sftp,
        destination.to_str().unwrap(),
        &downloaded,
        FileDisposition::Resume {
            offset: downloaded_offset,
        },
        &fresh,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(fs::read(&downloaded).unwrap(), bytes);
    connection
        .write(b"printf '%s%s\\n' TRANSFER_ 'PTY_ALIVE'\n")
        .await
        .unwrap();
    let mut output = Vec::new();
    timeout(Duration::from_secs(5), async {
        while !String::from_utf8_lossy(&output).contains("TRANSFER_PTY_ALIVE") {
            if let PtyEvent::Data(data) = connection.read().await.unwrap() {
                output.extend(data);
            }
        }
    })
    .await
    .unwrap();
    sftp.close().await.unwrap();
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn streaming_files_reject_links_and_preserve_conflicts_and_cancelled_targets() {
    use hspterm_ssh_core::transfer::{FileDisposition, TransferError, download_file, upload_file};
    let server = Server::start().await;
    let mut connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    let source = server.dir.path().join("source.bin");
    let remote = server.dir.path().join("remote.bin");
    let local = server.dir.path().join("local.bin");
    let remote_path = remote.to_str().unwrap();
    fs::write(&source, []).unwrap();
    let run = CancellationToken::new();
    let empty = upload_file(
        &sftp,
        &source,
        remote_path,
        FileDisposition::CreateNew,
        &run,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(empty.total, 0);
    assert!(remote.exists());
    fs::write(&source, b"binary\0data").unwrap();
    upload_file(
        &sftp,
        &source,
        remote_path,
        FileDisposition::Overwrite,
        &run,
        |_| {},
    )
    .await
    .unwrap();
    fs::write(&local, b"keep existing destination").unwrap();
    assert!(matches!(
        download_file(
            &sftp,
            remote_path,
            &local,
            FileDisposition::CreateNew,
            &run,
            |_| {}
        )
        .await,
        Err(TransferError::Conflict)
    ));
    assert_eq!(fs::read(&local).unwrap(), b"keep existing destination");
    download_file(
        &sftp,
        remote_path,
        &local,
        FileDisposition::Overwrite,
        &run,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(fs::read(&local).unwrap(), b"binary\0data");
    fs::write(&source, []).unwrap();
    upload_file(
        &sftp,
        &source,
        remote_path,
        FileDisposition::Overwrite,
        &run,
        |_| {},
    )
    .await
    .unwrap();
    download_file(
        &sftp,
        remote_path,
        &local,
        FileDisposition::Overwrite,
        &run,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(fs::metadata(&local).unwrap().len(), 0);

    let link = server.dir.path().join("link.bin");
    std::os::unix::fs::symlink(&source, &link).unwrap();
    assert!(matches!(
        upload_file(
            &sftp,
            &source,
            link.to_str().unwrap(),
            FileDisposition::Overwrite,
            &run,
            |_| {}
        )
        .await,
        Err(TransferError::InvalidFile)
    ));
    assert!(matches!(
        upload_file(
            &sftp,
            &link,
            remote_path,
            FileDisposition::Overwrite,
            &run,
            |_| {}
        )
        .await,
        Err(TransferError::InvalidFile)
    ));
    assert!(matches!(
        download_file(
            &sftp,
            remote_path,
            &link,
            FileDisposition::Overwrite,
            &run,
            |_| {}
        )
        .await,
        Err(TransferError::InvalidFile)
    ));
    assert!(matches!(
        download_file(
            &sftp,
            link.to_str().unwrap(),
            &local,
            FileDisposition::Overwrite,
            &run,
            |_| {}
        )
        .await,
        Err(TransferError::InvalidFile)
    ));

    let missing = server.dir.path().join("not-created.bin");
    assert!(matches!(
        download_file(
            &sftp,
            remote_path,
            &missing,
            FileDisposition::Resume { offset: 0 },
            &run,
            |_| {}
        )
        .await,
        Err(TransferError::InvalidResume)
    ));
    assert!(!missing.exists());
    let stopped = CancellationToken::new();
    stopped.cancel();
    assert!(matches!(
        upload_file(
            &sftp,
            &source,
            missing.to_str().unwrap(),
            FileDisposition::CreateNew,
            &stopped,
            |_| {}
        )
        .await,
        Err(TransferError::Cancelled)
    ));
    assert!(!missing.exists());
    sftp.close().await.unwrap();
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_transfer_channel_can_resume_on_the_existing_ssh_transport() {
    use hspterm_ssh_core::transfer::{FileDisposition, upload_file};
    use std::sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    };
    let server = Server::start().await;
    let mut connection = server.connect().await;
    let sftp = Arc::new(connection.open_sftp().await.unwrap());
    let source = server.dir.path().join("recover-source.bin");
    let target = server.dir.path().join("recover-target.bin");
    let data: Vec<u8> = (0..8 * 1024 * 1024).map(|n| (n % 239) as u8).collect();
    fs::write(&source, &data).unwrap();
    let channel = sftp.clone();
    let source_copy = source.clone();
    let target_copy = target.to_str().unwrap().to_owned();
    let acknowledged = Arc::new(AtomicU64::new(0));
    let progress = acknowledged.clone();
    let (ready, started) = tokio::sync::oneshot::channel();
    let mut ready = Some(ready);
    let worker = tokio::spawn(async move {
        upload_file(
            &channel,
            &source_copy,
            &target_copy,
            FileDisposition::CreateNew,
            &CancellationToken::new(),
            |p| {
                progress.store(p.acknowledged, Ordering::SeqCst);
                if p.acknowledged > 0
                    && let Some(ready) = ready.take()
                {
                    ready.send(()).unwrap();
                }
            },
        )
        .await
    });
    timeout(Duration::from_secs(5), started)
        .await
        .unwrap()
        .unwrap();
    sftp.close().await.unwrap();
    assert!(
        timeout(Duration::from_secs(5), worker)
            .await
            .unwrap()
            .unwrap()
            .is_err()
    );
    let offset = acknowledged.load(Ordering::SeqCst);
    assert!(offset > 0 && offset < data.len() as u64);
    // Only open another SFTP channel. There is no call to connect/reconnect SSH.
    let replacement = connection.open_sftp().await.unwrap();
    upload_file(
        &replacement,
        &source,
        target.to_str().unwrap(),
        FileDisposition::Resume { offset },
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(fs::read(&target).unwrap(), data);
    connection
        .write(b"printf '%s%s\\n' SAME_ 'TRANSPORT'\n")
        .await
        .unwrap();
    let mut term = Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap();
    until_text(&mut connection, &mut term, "SAME_TRANSPORT").await;
    replacement.close().await.unwrap();
    connection.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn failed_subtree_rescan_merges_new_files_without_reading_completed_siblings() {
    use hspterm_ssh_core::tree_transfer::{
        Direction, NodeKind, NodeState, TreeOutcome, TreeTransfer,
    };
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    for direction in [Direction::Upload, Direction::Download] {
        let tag = format!("{direction:?}");
        let source = server.dir.path().join(format!("rescan-source-{tag}"));
        let target = server.dir.path().join(format!("rescan-target-{tag}"));
        fs::create_dir_all(source.join("broken/nested")).unwrap();
        fs::create_dir_all(source.join("done")).unwrap();
        fs::create_dir(&target).unwrap();
        fs::write(source.join("done/success"), b"keep completed subtree").unwrap();
        fs::write(source.join("broken/old"), b"old child").unwrap();
        fs::write(source.join("broken/nested/deep"), b"deep child").unwrap();
        fs::write(
            target.join("broken"),
            b"obstacle, keep until explicit fixture repair",
        )
        .unwrap();
        let (local, remote) = if direction == Direction::Upload {
            (source.clone(), target.to_str().unwrap().to_owned())
        } else {
            (target.clone(), source.to_str().unwrap().to_owned())
        };
        let task = TreeTransfer::scan(
            direction,
            local,
            remote,
            &sftp,
            &CancellationToken::new(),
            |_| {},
        )
        .await
        .unwrap();
        let mut task = task;
        assert_eq!(
            task.run(&sftp, &CancellationToken::new(), |_, _| {})
                .await
                .unwrap(),
            TreeOutcome::Partial
        );
        let indices: Vec<_> = task
            .nodes
            .iter()
            .enumerate()
            .filter(|(_, n)| n.kind == NodeKind::Directory && n.state == NodeState::Failed)
            .map(|(i, _)| i)
            .collect();
        assert_eq!(indices.len(), 2); // ancestor and nested failure collapse to one scan
        let before = serde_json::to_vec(&task).unwrap();
        fs::remove_dir_all(source.join("done")).unwrap();
        fs::write(source.join("broken/new 中文 é"), b"new discovery").unwrap();
        fs::remove_file(target.join("broken")).unwrap();
        let stop = CancellationToken::new();
        assert!(matches!(
            task.rescan_failed(&indices, &sftp, &stop, |_| stop.cancel())
                .await,
            Err(hspterm_ssh_core::tree_transfer::TreeError::Cancelled)
        ));
        assert_eq!(serde_json::to_vec(&task).unwrap(), before);
        assert!(!target.join("broken").exists());
        let mut merged = task
            .rescan_failed(&indices, &sftp, &CancellationToken::new(), |_| {})
            .await
            .unwrap();
        assert!(
            !target.join("broken").exists(),
            "rescan must not write targets"
        );
        assert_eq!(merged.nodes.len(), task.nodes.len() + 1);
        for (old, new) in task.nodes.iter().zip(&merged.nodes) {
            assert_eq!(old.relative, new.relative, "existing indices remain stable");
            if old.state == NodeState::Complete {
                assert_eq!(
                    serde_json::to_vec(old).unwrap(),
                    serde_json::to_vec(new).unwrap()
                );
            }
        }
        assert_eq!(
            merged
                .run(&sftp, &CancellationToken::new(), |_, _| {})
                .await
                .unwrap(),
            TreeOutcome::Complete
        );
        for (relative, data) in [
            ("done/success", b"keep completed subtree".as_slice()),
            ("broken/new 中文 é", b"new discovery"),
            ("broken/old", b"old child"),
            ("broken/nested/deep", b"deep child"),
        ] {
            assert_eq!(fs::read(target.join(relative)).unwrap(), data);
        }
        // Simulate a retained acknowledged prefix and a transient parent error.
        // Successful files/subdirectories inside the selected subtree are not read.
        let parent = merged
            .nodes
            .iter()
            .position(|n| n.relative == "broken")
            .unwrap();
        merged.nodes[parent].state = NodeState::Failed;
        let partial = merged
            .nodes
            .iter()
            .position(|n| n.relative == "broken/old")
            .unwrap();
        merged.nodes[partial].state = NodeState::Failed;
        merged.nodes[partial].acknowledged = 4;
        fs::OpenOptions::new()
            .write(true)
            .open(target.join("broken/old"))
            .unwrap()
            .set_len(4)
            .unwrap();
        fs::remove_file(source.join("broken/new 中文 é")).unwrap();
        fs::remove_dir_all(source.join("broken/nested")).unwrap();
        let mut resumed = merged
            .rescan_failed(&[parent], &sftp, &CancellationToken::new(), |_| {})
            .await
            .unwrap();
        assert_eq!(resumed.nodes[partial].acknowledged, 4);
        assert!(resumed.nodes[partial].started);
        assert_eq!(
            resumed
                .run(&sftp, &CancellationToken::new(), |_, _| {})
                .await
                .unwrap(),
            TreeOutcome::Complete
        );
        assert_eq!(fs::read(target.join("broken/old")).unwrap(), b"old child");
        // Changed directory type must not discard children or follow a link.
        resumed.nodes[parent].state = NodeState::Failed;
        fs::remove_dir_all(source.join("broken")).unwrap();
        std::os::unix::fs::symlink(&target, source.join("broken")).unwrap();
        let guarded = resumed
            .rescan_failed(&[parent], &sftp, &CancellationToken::new(), |_| {})
            .await
            .unwrap();
        assert_eq!(guarded.nodes[parent].kind, NodeKind::Directory);
        assert_eq!(guarded.nodes[parent].state, NodeState::Failed);
        assert_eq!(guarded.nodes.len(), resumed.nodes.len());
        guarded.validate().unwrap();
    }
    sftp.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn batch_rename_reserves_task_names_preserves_old_files_and_refuses_late_races() {
    use hspterm_ssh_core::tree_transfer::{
        ConflictDecision, Direction, NodeState, TreeError, TreeOutcome, TreeTransfer,
    };
    let server = Server::start().await;
    let connection = server.connect().await;
    let sftp = connection.open_sftp().await.unwrap();
    for direction in [Direction::Upload, Direction::Download] {
        let source = server
            .dir
            .path()
            .join(format!("rename-source-{direction:?}"));
        let target = server
            .dir
            .path()
            .join(format!("rename-target-{direction:?}"));
        fs::create_dir(&source).unwrap();
        fs::create_dir(&target).unwrap();
        for name in [
            "a.txt",
            "a (1).txt",
            "a (2).txt",
            ".env",
            "z.txt",
            "failure",
        ] {
            fs::write(source.join(name), format!("new {name}")).unwrap();
        }
        for name in ["a.txt", "a (1).txt", "a (3).txt", ".env"] {
            fs::write(target.join(name), format!("old {name}")).unwrap();
        }
        fs::create_dir(target.join("failure")).unwrap();
        let (local, remote) = if direction == Direction::Upload {
            (source.clone(), target.to_str().unwrap().to_owned())
        } else {
            (target.clone(), source.to_str().unwrap().to_owned())
        };
        let mut task = TreeTransfer::scan(
            direction,
            local,
            remote,
            &sftp,
            &CancellationToken::new(),
            |_| {},
        )
        .await
        .unwrap();
        assert_eq!(
            task.run(&sftp, &CancellationToken::new(), |_, _| {})
                .await
                .unwrap(),
            TreeOutcome::Partial
        );
        assert_eq!(task.stats().conflicts, 3);
        assert_eq!(task.stats().failed, 1);
        let original = serde_json::to_vec(&task).unwrap();
        let stop = CancellationToken::new();
        stop.cancel();
        assert!(matches!(
            task.rename_conflicts(&sftp, &stop).await,
            Err(TreeError::Cancelled)
        ));
        let mut renamed = task
            .rename_conflicts(&sftp, &CancellationToken::new())
            .await
            .unwrap();
        assert_eq!(serde_json::to_vec(&task).unwrap(), original);
        let a = renamed
            .nodes
            .iter()
            .position(|n| n.relative == "a.txt")
            .unwrap();
        assert_eq!(
            renamed.nodes[a].destination_name.as_deref(),
            Some("a (4).txt")
        );
        assert!(!target.join("a (4).txt").exists());
        assert_eq!(renamed.stats().failed, 1);
        fs::remove_file(source.join("z.txt")).unwrap();
        fs::remove_file(source.join("a (2).txt")).unwrap();
        // Simulate another writer after metadata selection. Exclusive create
        // refuses the new collision, retaining the selected name for recovery.
        fs::write(target.join("a (4).txt"), b"late competing writer").unwrap();
        assert_eq!(
            renamed
                .run(&sftp, &CancellationToken::new(), |_, _| {})
                .await
                .unwrap(),
            TreeOutcome::Partial
        );
        assert_eq!(renamed.nodes[a].state, NodeState::Conflict);
        assert_eq!(
            fs::read(target.join("a (4).txt")).unwrap(),
            b"late competing writer"
        );
        for (name, data) in [
            ("a.txt", "old a.txt"),
            ("a (1).txt", "old a (1).txt"),
            (".env", "old .env"),
            (".env (1)", "new .env"),
            ("a (1) (1).txt", "new a (1).txt"),
        ] {
            assert_eq!(fs::read(target.join(name)).unwrap(), data.as_bytes());
        }
        fs::remove_file(source.join(".env")).unwrap();
        fs::remove_file(source.join("a (1).txt")).unwrap();
        let mut final_plan = renamed
            .rename_conflicts(&sftp, &CancellationToken::new())
            .await
            .unwrap();
        let failed = final_plan
            .nodes
            .iter()
            .position(|n| n.relative == "failure")
            .unwrap();
        final_plan.retry(failed, ConflictDecision::Skip).unwrap();
        assert_eq!(
            final_plan
                .run(&sftp, &CancellationToken::new(), |_, _| {})
                .await
                .unwrap(),
            TreeOutcome::CompleteWithSkips
        );
        assert_eq!(
            fs::read(target.join("a (4) (1).txt")).unwrap(),
            b"new a.txt"
        );

        // Root-file mappings update the actual target; source identity stays fixed.
        let root_source = source.join("single.txt");
        let root_target = target.join("single.txt");
        fs::write(&root_source, b"single source").unwrap();
        fs::write(&root_target, b"single preserved").unwrap();
        let (local, remote) = if direction == Direction::Upload {
            (
                root_source.clone(),
                root_target.to_str().unwrap().to_owned(),
            )
        } else {
            (
                root_target.clone(),
                root_source.to_str().unwrap().to_owned(),
            )
        };
        let mut root = TreeTransfer::scan(
            direction,
            local,
            remote,
            &sftp,
            &CancellationToken::new(),
            |_| {},
        )
        .await
        .unwrap();
        assert_eq!(
            root.run(&sftp, &CancellationToken::new(), |_, _| {})
                .await
                .unwrap(),
            TreeOutcome::Partial
        );
        let mut renamed = root
            .rename_conflicts(&sftp, &CancellationToken::new())
            .await
            .unwrap();
        assert!(renamed.nodes[0].destination_name.is_none());
        if direction == Direction::Upload {
            assert_eq!(renamed.local, root_source);
            assert!(renamed.remote.ends_with("single (1).txt"));
        } else {
            assert_eq!(renamed.remote, root_source.to_str().unwrap());
            assert_eq!(renamed.local, target.join("single (1).txt"));
        }
        assert_eq!(
            renamed
                .run(&sftp, &CancellationToken::new(), |_, _| {})
                .await
                .unwrap(),
            TreeOutcome::Complete
        );
        assert_eq!(fs::read(root_target).unwrap(), b"single preserved");
        assert_eq!(
            fs::read(target.join("single (1).txt")).unwrap(),
            b"single source"
        );
    }
    sftp.close().await.unwrap();
}
