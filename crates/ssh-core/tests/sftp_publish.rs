//! Controlled protocol peers for capability fallback and replacement failures.
use hspterm_ssh_core::{
    SftpSession,
    bandwidth::BandwidthLimiter,
    transfer::{
        RemotePublishResult, overwrite_from_staged_remote_file, publish_staged_remote_file,
    },
};
use russh_sftp::{
    protocol::{
        Attrs, Data, File, FileAttributes, Handle, Name, OpenFlags, Packet, Status, StatusCode,
        Version,
    },
    server::Handler,
};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
};
use tokio::time::{Duration, timeout};
use tokio_util::sync::CancellationToken;

const SNAPSHOT: &[u8] = b"complete staged payload";
#[tokio::test]
async fn explicit_staging_cleanup_retires_only_the_inventoried_private_copy_and_keeps_sources() {
    use hspterm_ssh_core::{
        remote_tree::{RemoteTree, StagingCleanupState, StagingPhase},
        tree_transfer::NodeState,
    };
    let (sftp, seen, server) = peer(None).await;
    let stop = CancellationToken::new();
    let mut plan = RemoteTree::scan(
        &sftp,
        &sftp,
        "/stage".into(),
        "/new".into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    plan.stages[0] = StagingPhase::Writing;
    plan.nodes[0].started = true;
    plan.nodes[0].acknowledged = 4;
    let path = plan.staging_path(0).unwrap();
    seen.files
        .lock()
        .unwrap()
        .insert(path.clone(), SNAPSHOT[..4].to_vec());
    seen.allow_cleanup.store(true, Ordering::SeqCst);
    let mut review = plan.prepare_staging_cleanup(0, &sftp, &stop).await.unwrap();
    assert!(!review.missing());
    let mut barriers = Vec::new();
    plan.cleanup_staging(&mut review, &sftp, false, &stop, |plan, entry| {
        plan.validate().unwrap();
        barriers.push(entry.state);
        Ok(())
    })
    .await
    .unwrap();
    assert_eq!(
        barriers,
        vec![
            StagingCleanupState::RemoveIntent,
            StagingCleanupState::Retired
        ]
    );
    assert_eq!(plan.nodes[0].state, NodeState::Failed);
    assert_eq!(plan.stages[0], StagingPhase::Absent);
    assert!(!plan.nodes[0].started);
    assert_eq!(plan.nodes[0].acknowledged, 0);
    assert!(!seen.files.lock().unwrap().contains_key(&path));
    assert_eq!(seen.files.lock().unwrap()["/stage"], SNAPSHOT);
    assert_eq!(seen.files.lock().unwrap()["/destination"], b"old target");
    assert_eq!(seen.removes.load(Ordering::SeqCst), 1);
    plan.cleanup_staging(&mut review, &sftp, false, &stop, |_, _| Ok(()))
        .await
        .unwrap();
    assert_eq!(seen.removes.load(Ordering::SeqCst), 1);
    sftp.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn uncertain_staging_requires_explicit_consent_and_delete_intent_is_never_automatically_replayed()
 {
    use hspterm_ssh_core::remote_tree::{
        RemoteTree, RemoteTreeError, StagingCleanupState, StagingPhase,
    };
    let (sftp, seen, server) = peer(None).await;
    let stop = CancellationToken::new();
    let mut plan = RemoteTree::scan(
        &sftp,
        &sftp,
        "/stage".into(),
        "/new".into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    plan.stages[0] = StagingPhase::Intent;
    let path = plan.staging_path(0).unwrap();
    seen.files.lock().unwrap().insert(path.clone(), Vec::new());
    let mut review = plan.prepare_staging_cleanup(0, &sftp, &stop).await.unwrap();
    assert!(review.uncertain_operation());
    assert!(matches!(
        plan.cleanup_staging(&mut review, &sftp, false, &stop, |_, _| Ok(()))
            .await,
        Err(RemoteTreeError::Uncertain)
    ));
    assert_eq!(review.state, StagingCleanupState::Prepared);
    assert!(matches!(
        plan.cleanup_staging(&mut review, &sftp, true, &stop, |_, _| Err(
            RemoteTreeError::Checkpoint
        ))
        .await,
        Err(RemoteTreeError::Checkpoint)
    ));
    assert_eq!(review.state, StagingCleanupState::RemoveIntent);
    assert!(matches!(
        plan.cleanup_staging(&mut review, &sftp, true, &stop, |_, _| Ok(()))
            .await,
        Err(RemoteTreeError::Uncertain)
    ));
    assert_eq!(seen.removes.load(Ordering::SeqCst), 0);
    assert!(seen.files.lock().unwrap().contains_key(&path));
    sftp.close().await.unwrap();
    server.await.unwrap();
}
struct Observed {
    files: Mutex<HashMap<String, Vec<u8>>>,
    extended: AtomicUsize,
    renames: AtomicUsize,
    removes: AtomicUsize,
    closes: AtomicUsize,
    writes: AtomicUsize,
    allow_cleanup: AtomicBool,
    fail_close: AtomicBool,
    fail_after_remove: AtomicBool,
}
struct Peer {
    version: Option<&'static str>,
    observed: Arc<Observed>,
}
fn ok(id: u32) -> Status {
    Status {
        id,
        status_code: StatusCode::Ok,
        error_message: String::new(),
        language_tag: String::new(),
    }
}
impl Handler for Peer {
    type Error = StatusCode;
    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }
    async fn init(&mut self, _: u32, _: HashMap<String, String>) -> Result<Version, Self::Error> {
        let mut value = Version::new();
        if let Some(version) = self.version {
            value
                .extensions
                .insert("posix-rename@openssh.com".into(), version.into());
        }
        Ok(value)
    }
    async fn realpath(&mut self, id: u32, path: String) -> Result<Name, Self::Error> {
        Ok(Name {
            id,
            files: vec![File::new(path, FileAttributes::default())],
        })
    }
    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        let directory = matches!(path.as_str(), "/" | "/tree" | "/out");
        let size = if directory {
            0
        } else {
            self.observed
                .files
                .lock()
                .unwrap()
                .get(&path)
                .ok_or(StatusCode::NoSuchFile)?
                .len() as u64
        };
        Ok(Attrs {
            id,
            attrs: FileAttributes {
                permissions: Some(if directory { 0o040700 } else { 0o100600 }),
                size: Some(size),
                ..FileAttributes::default()
            },
        })
    }
    async fn fstat(&mut self, id: u32, handle: String) -> Result<Attrs, Self::Error> {
        self.lstat(id, handle).await
    }
    async fn open(
        &mut self,
        id: u32,
        path: String,
        flags: OpenFlags,
        _: FileAttributes,
    ) -> Result<Handle, Self::Error> {
        let mut files = self.observed.files.lock().unwrap();
        if flags.contains(OpenFlags::EXCLUDE) && files.contains_key(&path) {
            return Err(StatusCode::Failure);
        }
        if flags.contains(OpenFlags::TRUNCATE)
            || (flags.contains(OpenFlags::CREATE) && !files.contains_key(&path))
        {
            files.insert(path.clone(), Vec::new());
        }
        if !files.contains_key(&path) {
            return Err(StatusCode::NoSuchFile);
        }
        Ok(Handle { id, handle: path })
    }
    async fn read(
        &mut self,
        id: u32,
        path: String,
        offset: u64,
        length: u32,
    ) -> Result<Data, Self::Error> {
        let files = self.observed.files.lock().unwrap();
        let bytes = files.get(&path).ok_or(StatusCode::NoSuchFile)?;
        let start = offset as usize;
        if start >= bytes.len() {
            return Err(StatusCode::Eof);
        }
        Ok(Data {
            id,
            data: bytes[start..bytes.len().min(start + length as usize)].to_vec(),
        })
    }
    async fn write(
        &mut self,
        id: u32,
        path: String,
        offset: u64,
        bytes: Vec<u8>,
    ) -> Result<Status, Self::Error> {
        self.observed.writes.fetch_add(1, Ordering::SeqCst);
        let mut files = self.observed.files.lock().unwrap();
        let target = files.get_mut(&path).ok_or(StatusCode::NoSuchFile)?;
        let start = offset as usize;
        target.resize(target.len().max(start + bytes.len()), 0);
        target[start..start + bytes.len()].copy_from_slice(&bytes);
        Ok(ok(id))
    }
    async fn close(&mut self, id: u32, _: String) -> Result<Status, Self::Error> {
        self.observed.closes.fetch_add(1, Ordering::SeqCst);
        if self.observed.fail_close.load(Ordering::SeqCst) {
            return Err(StatusCode::Failure);
        }
        Ok(ok(id))
    }
    async fn extended(
        &mut self,
        _: u32,
        request: String,
        _: Vec<u8>,
    ) -> Result<Packet, Self::Error> {
        assert_eq!(request, "posix-rename@openssh.com");
        self.observed.extended.fetch_add(1, Ordering::SeqCst);
        Err(StatusCode::PermissionDenied)
    }
    async fn rename(
        &mut self,
        id: u32,
        source: String,
        destination: String,
    ) -> Result<Status, Self::Error> {
        self.observed.renames.fetch_add(1, Ordering::SeqCst);
        let mut files = self.observed.files.lock().unwrap();
        if files.contains_key(&destination) {
            return Err(StatusCode::Failure);
        }
        let body = files.remove(&source).ok_or(StatusCode::NoSuchFile)?;
        files.insert(destination, body);
        Ok(ok(id))
    }
    async fn remove(&mut self, id: u32, path: String) -> Result<Status, Self::Error> {
        self.observed.removes.fetch_add(1, Ordering::SeqCst);
        if self.observed.allow_cleanup.load(Ordering::SeqCst) {
            self.observed
                .files
                .lock()
                .unwrap()
                .remove(&path)
                .ok_or(StatusCode::NoSuchFile)?;
            if self.observed.fail_after_remove.load(Ordering::SeqCst) {
                return Err(StatusCode::Failure);
            }
            Ok(ok(id))
        } else {
            Err(StatusCode::Failure)
        }
    }
}
async fn peer(
    version: Option<&'static str>,
) -> (SftpSession, Arc<Observed>, tokio::task::JoinHandle<()>) {
    let observed = Arc::new(Observed {
        files: Mutex::new(HashMap::from([
            ("/stage".into(), SNAPSHOT.to_vec()),
            ("/destination".into(), b"old target".to_vec()),
        ])),
        extended: AtomicUsize::new(0),
        renames: AtomicUsize::new(0),
        removes: AtomicUsize::new(0),
        closes: AtomicUsize::new(0),
        writes: AtomicUsize::new(0),
        allow_cleanup: AtomicBool::new(false),
        fail_close: AtomicBool::new(false),
        fail_after_remove: AtomicBool::new(false),
    });
    let (session, task) = reconnect(version, observed.clone()).await;
    (session, observed, task)
}
async fn reconnect(
    version: Option<&'static str>,
    observed: Arc<Observed>,
) -> (SftpSession, tokio::task::JoinHandle<()>) {
    let (client, server) = tokio::io::duplex(8192);
    let task = tokio::spawn(russh_sftp::server::run_owned(
        server,
        Peer {
            version,
            observed: observed.clone(),
        },
    ));
    (SftpSession::new(client).await.unwrap(), task)
}

#[tokio::test]
async fn relay_channel_loss_preserves_private_ack_prefix_and_recovers_without_recreating_snapshot()
{
    use hspterm_ssh_core::{
        remote_tree::{RemoteTree, RemoteTreeError, StagingPhase},
        tree_transfer::{NodeState, TreeOutcome},
    };
    let (sftp, seen, server) = peer(None).await;
    let body: Vec<_> = (0..512 * 1024).map(|n| (n % 251) as u8).collect();
    seen.files
        .lock()
        .unwrap()
        .insert("/stage".into(), body.clone());
    let stop = CancellationToken::new();
    let budget = BandwidthLimiter::default();
    let mut tree = RemoteTree::scan(
        &sftp,
        &sftp,
        "/stage".into(),
        "/new".into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    let mut injected = false;
    let error = timeout(
        Duration::from_secs(5),
        tree.run(&sftp, &sftp, &stop, &budget, &budget, |p, _| {
            if !injected && p.nodes[0].acknowledged >= 65536 {
                injected = true;
                server.abort();
            }
            Ok(())
        }),
    )
    .await
    .unwrap()
    .unwrap_err();
    assert!(matches!(error, RemoteTreeError::TransientChannel { indices } if indices == vec![0]));
    assert_eq!(tree.stages[0], StagingPhase::Writing);
    assert_eq!(tree.nodes[0].state, NodeState::Failed);
    let prefix = tree.nodes[0].acknowledged as usize;
    assert!(prefix >= 65536 && prefix < body.len());
    let staged = tree.staging_path(0).unwrap();
    assert_eq!(
        &seen.files.lock().unwrap()[&staged][..prefix],
        &body[..prefix]
    );
    assert_eq!(seen.renames.load(Ordering::SeqCst), 0);
    sftp.close().await.unwrap();
    assert!(server.await.unwrap_err().is_cancelled());
    tree.validate().unwrap();
    tree.nodes[0].state = NodeState::Pending;
    tree.nodes[0].error = None;
    // A new protocol channel shares only the fixture filesystem, never an SSH
    // reconnect. Production's owner additionally checks both original Roots.
    let (sftp, server) = reconnect(None, seen.clone()).await;
    assert_eq!(
        tree.run(&sftp, &sftp, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(seen.files.lock().unwrap()["/new"], body);
    assert_eq!(seen.files.lock().unwrap()["/stage"], body);
    assert_eq!(seen.renames.load(Ordering::SeqCst), 1);
    assert!(!seen.files.lock().unwrap().contains_key(&staged));
    sftp.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn lost_channel_at_create_or_publish_intent_is_not_an_automatic_retry_ticket() {
    use hspterm_ssh_core::{
        remote_tree::{RemoteTree, StagingPhase},
        tree_transfer::{NodeState, TreeOutcome},
    };
    for phase in [StagingPhase::Intent, StagingPhase::Publishing] {
        let (sftp, seen, server) = peer(None).await;
        let stop = CancellationToken::new();
        let budget = BandwidthLimiter::default();
        let mut tree = RemoteTree::scan(
            &sftp,
            &sftp,
            "/stage".into(),
            "/new".into(),
            true,
            "0123456789abcdef0123456789abcdef".into(),
            &stop,
            |_| {},
        )
        .await
        .unwrap();
        let mut injected = false;
        let outcome = timeout(
            Duration::from_secs(5),
            tree.run(&sftp, &sftp, &stop, &budget, &budget, |p, _| {
                if !injected && p.stages[0] == phase {
                    injected = true;
                    server.abort();
                }
                Ok(())
            }),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(injected);
        assert_eq!(outcome, TreeOutcome::Partial);
        assert_eq!(tree.nodes[0].state, NodeState::Failed);
        assert_eq!(tree.stages[0], phase);
        assert_eq!(seen.renames.load(Ordering::SeqCst), 0);
        assert_eq!(seen.files.lock().unwrap()["/stage"], SNAPSHOT);
        assert!(!seen.files.lock().unwrap().contains_key("/new"));
        tree.validate().unwrap();
        sftp.close().await.unwrap();
        assert!(server.await.unwrap_err().is_cancelled());
    }
}

#[tokio::test]
async fn a_failed_durable_fault_checkpoint_takes_precedence_over_channel_recovery() {
    use hspterm_ssh_core::{
        remote_tree::{RemoteTree, RemoteTreeError},
        tree_transfer::NodeState,
    };
    let (sftp, seen, server) = peer(None).await;
    seen.files
        .lock()
        .unwrap()
        .insert("/stage".into(), vec![91; 256 * 1024]);
    let stop = CancellationToken::new();
    let budget = BandwidthLimiter::default();
    let mut tree = RemoteTree::scan(
        &sftp,
        &sftp,
        "/stage".into(),
        "/new".into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    let mut injected = false;
    let error = timeout(
        Duration::from_secs(5),
        tree.run(&sftp, &sftp, &stop, &budget, &budget, |p, _| {
            if p.nodes[0].state == NodeState::Failed {
                return Err(RemoteTreeError::Checkpoint);
            }
            if !injected && p.nodes[0].acknowledged >= 65536 {
                injected = true;
                server.abort();
            }
            Ok(())
        }),
    )
    .await
    .unwrap()
    .unwrap_err();
    assert!(matches!(error, RemoteTreeError::Checkpoint));
    assert_eq!(seen.renames.load(Ordering::SeqCst), 0);
    sftp.close().await.unwrap();
    assert!(server.await.unwrap_err().is_cancelled());
}

#[tokio::test]
async fn parallel_channel_failure_drains_siblings_and_keeps_every_acknowledged_snapshot_prefix() {
    use hspterm_ssh_core::{
        remote_tree::{RemoteTree, RemoteTreeError, StagingPhase},
        tree_transfer::{ConflictDecision, NodeKind, NodeState, TransferNode, TreeOutcome},
    };
    let (sftp, seen, server) = peer(None).await;
    let body: Vec<_> = (0..512 * 1024).map(|n| (n % 251) as u8).collect();
    for i in 1..5 {
        seen.files
            .lock()
            .unwrap()
            .insert(format!("/tree/file-{i}"), body.clone());
    }
    let mut tree = RemoteTree {
        version: 1,
        source: "/tree".into(),
        destination: "/out".into(),
        staging_id: "0123456789abcdef0123456789abcdef".into(),
        nodes: (0..5)
            .map(|i| TransferNode {
                relative: if i == 0 {
                    String::new()
                } else {
                    format!("file-{i}")
                },
                kind: if i == 0 {
                    NodeKind::Directory
                } else {
                    NodeKind::File
                },
                state: NodeState::Pending,
                size: if i == 0 { 0 } else { body.len() as u64 },
                acknowledged: 0,
                started: false,
                decision: ConflictDecision::Ask,
                destination_name: None,
                error: None,
                default_policy_pending: false,
            })
            .collect(),
        stages: vec![StagingPhase::Absent; 5],
    };
    let stop = CancellationToken::new();
    let budget = BandwidthLimiter::new(192 * 1024);
    let mut injected = false;
    let error = timeout(
        Duration::from_secs(10),
        tree.run_parallel_observed(&sftp, &sftp, &stop, &budget, &budget, 3, |p, e, active| {
            assert_eq!(p.stats(), e.stats);
            if !injected
                && active.len() == 3
                && active.iter().all(|i| p.stages[*i] == StagingPhase::Writing)
                && e.stats.acknowledged >= 65536
            {
                injected = true;
                server.abort();
            }
            Ok(())
        }),
    )
    .await
    .unwrap()
    .unwrap_err();
    assert!(injected);
    let RemoteTreeError::TransientChannel { indices } = error else {
        panic!("typed channel failure must have a bounded recovery set");
    };
    assert!(!indices.is_empty() && indices.len() <= 3);
    tree.validate().unwrap();
    assert_eq!(seen.renames.load(Ordering::SeqCst), 0);
    let acknowledged = tree.stats().acknowledged;
    assert!(acknowledged >= 65536);
    for (i, node) in tree.nodes.iter().enumerate().filter(|(_, n)| n.started) {
        assert_eq!(tree.stages[i], StagingPhase::Writing);
        assert_eq!(
            &seen.files.lock().unwrap()[&tree.staging_path(i).unwrap()]
                [..node.acknowledged as usize],
            &body[..node.acknowledged as usize]
        );
    }
    sftp.close().await.unwrap();
    assert!(server.await.unwrap_err().is_cancelled());
    for index in indices {
        tree.nodes[index].state = NodeState::Pending;
        tree.nodes[index].error = None;
    }
    let (sftp, server) = reconnect(None, seen.clone()).await;
    let budget = BandwidthLimiter::default();
    assert_eq!(
        tree.run_parallel_observed(&sftp, &sftp, &stop, &budget, &budget, 3, |p, e, active| {
            assert_eq!(p.stats(), e.stats);
            assert!(active.len() <= 3);
            Ok(())
        })
        .await
        .unwrap(),
        TreeOutcome::Complete
    );
    for i in 1..5 {
        assert_eq!(seen.files.lock().unwrap()[&format!("/out/file-{i}")], body);
    }
    sftp.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn remote_tree_fallback_requires_cleanup_ack_and_retry_does_not_recopy_successful_target() {
    use hspterm_ssh_core::{
        remote_tree::{RemoteTree, StagingPhase},
        tree_transfer::{ConflictDecision, NodeState, TreeOutcome},
    };
    let (sftp, seen, server) = peer(None).await;
    let stop = CancellationToken::new();
    let mut tree = RemoteTree::scan(
        &sftp,
        &sftp,
        "/stage".into(),
        "/destination".into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    tree.nodes[0].decision = ConflictDecision::Overwrite;
    let budget = BandwidthLimiter::default();
    assert_eq!(
        tree.run(&sftp, &sftp, &stop, &budget, &budget, |p, _| {
            p.validate()?;
            Ok(())
        })
        .await
        .unwrap(),
        TreeOutcome::Partial
    );
    assert_eq!(tree.stages[0], StagingPhase::Published);
    assert_eq!(tree.nodes[0].state, NodeState::Failed);
    assert_eq!(seen.files.lock().unwrap()["/destination"], SNAPSHOT);
    assert_eq!(seen.files.lock().unwrap()["/stage"], SNAPSHOT);
    let writes = seen.writes.load(Ordering::SeqCst);
    seen.allow_cleanup.store(true, Ordering::SeqCst);
    tree.retry(0, ConflictDecision::Ask).unwrap();
    assert_eq!(
        tree.run(&sftp, &sftp, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(seen.writes.load(Ordering::SeqCst), writes);
    assert!(
        !seen
            .files
            .lock()
            .unwrap()
            .contains_key(&tree.staging_path(0).unwrap())
    );
    assert_eq!(seen.extended.load(Ordering::SeqCst), 0);
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(1), server)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn cancelling_a_tree_does_not_hide_failed_file_closes_as_a_clean_pause() {
    use hspterm_ssh_core::{
        remote_tree::RemoteTree,
        tree_transfer::{NodeState, TreeOutcome},
    };
    let (sftp, seen, server) = peer(None).await;
    let stop = CancellationToken::new();
    let mut tree = RemoteTree::scan(
        &sftp,
        &sftp,
        "/stage".into(),
        "/new".into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    let budget = BandwidthLimiter::default();
    let result = tree
        .run(&sftp, &sftp, &stop, &budget, &budget, |p, _| {
            if p.nodes[0].acknowledged > 0 {
                seen.fail_close.store(true, Ordering::SeqCst);
                stop.cancel();
            }
            Ok(())
        })
        .await
        .unwrap();
    assert_eq!(result, TreeOutcome::Partial);
    assert_eq!(tree.nodes[0].state, NodeState::Failed);
    assert!(tree.nodes[0].error.as_ref().unwrap().contains("关闭"));
    assert!(!seen.files.lock().unwrap().contains_key("/new"));
    assert_eq!(seen.closes.load(Ordering::SeqCst), 2);
    seen.fail_close.store(false, Ordering::SeqCst);
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(1), server)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn remote_tree_never_adopts_an_unacknowledged_staging_object_or_writes_after_checkpoint_failure()
 {
    use hspterm_ssh_core::{
        remote_tree::{RemoteTree, RemoteTreeError, StagingPhase},
        tree_transfer::{NodeState, TreeOutcome},
    };
    let (sftp, seen, server) = peer(None).await;
    let stop = CancellationToken::new();
    let mut tree = RemoteTree::scan(
        &sftp,
        &sftp,
        "/stage".into(),
        "/new".into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    let budget = BandwidthLimiter::default();
    let error = tree
        .run(&sftp, &sftp, &stop, &budget, &budget, |_, _| {
            Err(RemoteTreeError::InvalidPlan)
        })
        .await
        .unwrap_err();
    assert!(matches!(error, RemoteTreeError::Checkpoint));
    assert_eq!(seen.writes.load(Ordering::SeqCst), 0);
    let staged = tree.staging_path(0).unwrap();
    seen.files
        .lock()
        .unwrap()
        .insert(staged.clone(), b"unconfirmed old object".to_vec());
    tree.stages[0] = StagingPhase::Intent;
    assert_eq!(
        tree.run(&sftp, &sftp, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Partial
    );
    assert_eq!(tree.nodes[0].state, NodeState::Failed);
    assert_eq!(
        seen.files.lock().unwrap()[&staged],
        b"unconfirmed old object"
    );
    assert_eq!(seen.writes.load(Ordering::SeqCst), 0);
    assert_eq!(seen.removes.load(Ordering::SeqCst), 0);
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(1), server)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn a_conflict_after_snapshot_can_be_skipped_or_renamed_without_losing_the_snapshot_identity()
{
    use hspterm_ssh_core::{
        remote_tree::{RemoteTree, StagingPhase},
        tree_transfer::{ConflictDecision, TreeOutcome},
    };
    let (sftp, seen, server) = peer(None).await;
    let stop = CancellationToken::new();
    let mut tree = RemoteTree::scan(
        &sftp,
        &sftp,
        "/stage".into(),
        "/new".into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &stop,
        |_| {},
    )
    .await
    .unwrap();
    let budget = BandwidthLimiter::default();
    assert_eq!(
        tree.run(&sftp, &sftp, &stop, &budget, &budget, |p, _| {
            if p.stages[0] == StagingPhase::Ready {
                seen.files
                    .lock()
                    .unwrap()
                    .insert("/new".into(), b"concurrent target".to_vec());
            }
            Ok(())
        })
        .await
        .unwrap(),
        TreeOutcome::Partial
    );
    let staged = tree.staging_path(0).unwrap();
    let writes = seen.writes.load(Ordering::SeqCst);
    let mut skipped = tree.clone();
    skipped.retry(0, ConflictDecision::Skip).unwrap();
    assert_eq!(
        skipped
            .run(&sftp, &sftp, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::CompleteWithSkips
    );
    assert_eq!(seen.files.lock().unwrap()["/new"], b"concurrent target");
    assert!(seen.files.lock().unwrap().contains_key(&staged));
    tree.rename_destination(0, "renamed").unwrap();
    assert_eq!(tree.staging_path(0).unwrap(), staged);
    assert_eq!(
        tree.run(&sftp, &sftp, &stop, &budget, &budget, |_, _| Ok(()))
            .await
            .unwrap(),
        TreeOutcome::Complete
    );
    assert_eq!(seen.writes.load(Ordering::SeqCst), writes);
    assert_eq!(seen.files.lock().unwrap()["/renamed"], SNAPSHOT);
    assert_eq!(seen.files.lock().unwrap()["/new"], b"concurrent target");
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(1), server)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn unsupported_atomic_replace_is_not_success_and_explicit_snapshot_fallback_copies_exact_bytes()
 {
    for version in [None, Some("0"), Some("2")] {
        let (sftp, seen, server) = peer(version).await;
        let result = publish_staged_remote_file(
            &sftp,
            "/stage",
            "/destination",
            SNAPSHOT.len() as u64,
            true,
            &CancellationToken::new(),
        )
        .await
        .unwrap();
        assert_eq!(result, RemotePublishResult::AtomicReplacementUnsupported);
        assert_eq!(seen.extended.load(Ordering::SeqCst), 0);
        assert_eq!(seen.renames.load(Ordering::SeqCst), 0);
        assert_eq!(seen.removes.load(Ordering::SeqCst), 0);
        assert_eq!(seen.files.lock().unwrap()["/destination"], b"old target");
        let budget = BandwidthLimiter::default();
        let done = overwrite_from_staged_remote_file(
            &sftp,
            "/stage",
            "/destination",
            SNAPSHOT.len() as u64,
            &CancellationToken::new(),
            &budget,
            &budget,
            |_| {},
        )
        .await
        .unwrap();
        assert_eq!(done.acknowledged, SNAPSHOT.len() as u64);
        assert_eq!(seen.files.lock().unwrap()["/destination"], SNAPSHOT);
        assert_eq!(seen.files.lock().unwrap()["/stage"], SNAPSHOT);
        assert_eq!(seen.closes.load(Ordering::SeqCst), 2);
        sftp.close().await.unwrap();
        timeout(Duration::from_secs(2), server)
            .await
            .unwrap()
            .unwrap();
    }
}
#[tokio::test]
async fn rejected_atomic_replace_never_falls_back_to_a_destructive_operation() {
    let (sftp, seen, server) = peer(Some("1")).await;
    assert!(
        publish_staged_remote_file(
            &sftp,
            "/stage",
            "/destination",
            SNAPSHOT.len() as u64,
            true,
            &CancellationToken::new()
        )
        .await
        .is_err()
    );
    assert_eq!(seen.extended.load(Ordering::SeqCst), 1);
    assert_eq!(seen.renames.load(Ordering::SeqCst), 0);
    assert_eq!(seen.removes.load(Ordering::SeqCst), 0);
    assert_eq!(seen.files.lock().unwrap()["/destination"], b"old target");
    assert_eq!(seen.files.lock().unwrap()["/stage"], SNAPSHOT);
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}
#[tokio::test]
async fn a_missing_destination_can_publish_with_standard_non_overwriting_rename() {
    let (sftp, seen, server) = peer(None).await;
    assert_eq!(
        publish_staged_remote_file(
            &sftp,
            "/stage",
            "/new",
            SNAPSHOT.len() as u64,
            false,
            &CancellationToken::new()
        )
        .await
        .unwrap(),
        RemotePublishResult::Published
    );
    assert_eq!(seen.renames.load(Ordering::SeqCst), 1);
    assert_eq!(seen.removes.load(Ordering::SeqCst), 0);
    assert_eq!(seen.files.lock().unwrap()["/new"], SNAPSHOT);
    assert!(!seen.files.lock().unwrap().contains_key("/stage"));
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn staging_review_rejects_changed_file_and_missing_snapshot_retirement_never_sends_remove() {
    use hspterm_ssh_core::{
        remote_tree::{RemoteTree, StagingPhase},
        tree_transfer::NodeState,
    };
    for mode in 0..3 {
        let (sftp, seen, server) = peer(None).await;
        let stop = CancellationToken::new();
        let mut plan = RemoteTree::scan(
            &sftp,
            &sftp,
            "/stage".into(),
            "/new".into(),
            true,
            "0123456789abcdef0123456789abcdef".into(),
            &stop,
            |_| {},
        )
        .await
        .unwrap();
        plan.nodes[0].started = true;
        plan.nodes[0].acknowledged = if mode == 2 { SNAPSHOT.len() as u64 } else { 4 };
        plan.stages[0] = if mode == 2 {
            StagingPhase::Published
        } else {
            StagingPhase::Writing
        };
        plan.nodes[0].state = NodeState::Failed;
        let path = plan.staging_path(0).unwrap();
        if mode != 1 {
            seen.files
                .lock()
                .unwrap()
                .insert(path.clone(), SNAPSHOT[..4].to_vec());
        }
        seen.allow_cleanup.store(true, Ordering::SeqCst);
        let mut review = plan.prepare_staging_cleanup(0, &sftp, &stop).await.unwrap();
        if mode == 0 {
            seen.files
                .lock()
                .unwrap()
                .insert(path.clone(), SNAPSHOT.to_vec());
        }
        let mut checkpoints = 0;
        let result = plan
            .cleanup_staging(&mut review, &sftp, false, &stop, |p, _| {
                p.validate().unwrap();
                checkpoints += 1;
                Ok(())
            })
            .await;
        if mode == 0 {
            assert!(result.is_err());
            assert_eq!(checkpoints, 0);
            assert_eq!(seen.removes.load(Ordering::SeqCst), 0);
            assert_eq!(seen.files.lock().unwrap()[&path], SNAPSHOT);
        } else {
            result.unwrap();
            assert_eq!(checkpoints, 2);
            assert_eq!(seen.removes.load(Ordering::SeqCst), usize::from(mode == 2));
            if mode == 2 {
                assert_eq!(plan.nodes[0].state, NodeState::Complete);
                assert!(plan.prepare_staging_cleanup(0, &sftp, &stop).await.is_err());
            } else {
                assert_eq!(plan.stages[0], StagingPhase::Absent);
            }
        }
        assert_eq!(seen.files.lock().unwrap()["/stage"], SNAPSHOT);
        assert_eq!(seen.files.lock().unwrap()["/destination"], b"old target");
        sftp.close().await.unwrap();
        server.await.unwrap();
    }
}

async fn copied_source_plan(
    sftp: &SftpSession,
    seen: &Observed,
) -> hspterm_ssh_core::remote_tree::RemoteTree {
    use hspterm_ssh_core::{
        remote_tree::{RemoteTree, StagingPhase},
        tree_transfer::NodeState,
    };
    let mut plan = RemoteTree::scan(
        sftp,
        sftp,
        "/stage".into(),
        "/new".into(),
        true,
        "0123456789abcdef0123456789abcdef".into(),
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    // Synthesize an acknowledged copy for this controlled source-retirement
    // protocol fixture. This helper is not an actual SSH copy acceptance test.
    plan.nodes[0].state = NodeState::Complete;
    plan.nodes[0].started = true;
    plan.nodes[0].acknowledged = plan.nodes[0].size;
    plan.stages[0] = StagingPhase::Published;
    seen.files
        .lock()
        .unwrap()
        .insert("/new".into(), SNAPSHOT.to_vec());
    seen.allow_cleanup.store(true, Ordering::SeqCst);
    plan
}
#[tokio::test]
async fn acknowledged_source_retirement_does_not_delete_destination_or_a_later_recreated_source() {
    use hspterm_ssh_core::remote_tree::SourceRetirement;
    let (sftp, seen, server) = peer(None).await;
    let plan = copied_source_plan(&sftp, &seen).await;
    let mut ledger = SourceRetirement::new(&plan).unwrap();
    let mut barriers = Vec::new();
    plan.retire_copied_sources(&mut ledger, &sftp, &CancellationToken::new(), |ledger| {
        barriers.push((ledger.confirmed(), ledger.uncertain_index()));
        Ok(())
    })
    .await
    .unwrap();
    assert_eq!(barriers, [(0, Some(0)), (1, None)]);
    assert!(ledger.complete());
    assert!(!seen.files.lock().unwrap().contains_key("/stage"));
    assert_eq!(seen.files.lock().unwrap()["/new"], SNAPSHOT);
    seen.files
        .lock()
        .unwrap()
        .insert("/stage".into(), b"later source".to_vec());
    plan.retire_copied_sources(&mut ledger, &sftp, &CancellationToken::new(), |_| Ok(()))
        .await
        .unwrap();
    assert_eq!(seen.removes.load(Ordering::SeqCst), 1);
    assert_eq!(seen.files.lock().unwrap()["/stage"], b"later source");
    sftp.close().await.unwrap();
    server.await.unwrap();
}
#[tokio::test]
async fn unknown_source_remove_is_never_replayed_even_after_recreation_or_local_end_waiting() {
    use hspterm_ssh_core::remote_tree::{RemoteTreeError, SourceRetirement};
    let (sftp, seen, server) = peer(None).await;
    let plan = copied_source_plan(&sftp, &seen).await;
    let mut ledger = SourceRetirement::new(&plan).unwrap();
    seen.fail_after_remove.store(true, Ordering::SeqCst);
    let mut saved = None;
    let result = plan
        .retire_copied_sources(&mut ledger, &sftp, &CancellationToken::new(), |ledger| {
            saved = Some(serde_json::to_vec(ledger).unwrap());
            Ok(())
        })
        .await;
    assert!(matches!(
        result,
        Err(RemoteTreeError::SourceRetirementUncertain)
    ));
    assert!(!seen.files.lock().unwrap().contains_key("/stage"));
    let mut restored: SourceRetirement = serde_json::from_slice(&saved.unwrap()).unwrap();
    assert_eq!(restored.confirmed(), 0);
    assert_eq!(restored.uncertain_index(), Some(0));
    seen.files
        .lock()
        .unwrap()
        .insert("/stage".into(), vec![9; SNAPSHOT.len()]);
    assert!(matches!(
        plan.retire_copied_sources(&mut restored, &sftp, &CancellationToken::new(), |_| Ok(()))
            .await,
        Err(RemoteTreeError::SourceRetirementUncertain)
    ));
    restored.end_waiting(&plan, |_| Ok(())).unwrap();
    assert!(restored.ended_unknown());
    assert!(!restored.complete());
    assert!(
        plan.retire_copied_sources(&mut restored, &sftp, &CancellationToken::new(), |_| Ok(()))
            .await
            .is_err()
    );
    assert_eq!(seen.removes.load(Ordering::SeqCst), 1);
    assert_eq!(
        seen.files.lock().unwrap()["/stage"],
        vec![9; SNAPSHOT.len()]
    );
    assert_eq!(seen.files.lock().unwrap()["/new"], SNAPSHOT);
    sftp.close().await.unwrap();
    server.await.unwrap();
}
#[tokio::test]
async fn incomplete_copy_changed_source_and_checkpoint_rejection_never_send_source_delete() {
    use hspterm_ssh_core::{
        remote_tree::{RemoteTreeError, SourceRetirement},
        tree_transfer::NodeState,
    };
    let (sftp, seen, server) = peer(None).await;
    let plan = copied_source_plan(&sftp, &seen).await;
    let mut incomplete = plan.clone();
    incomplete.nodes[0].state = NodeState::Failed;
    assert!(SourceRetirement::new(&incomplete).is_err());
    let mut changed = SourceRetirement::new(&plan).unwrap();
    seen.files
        .lock()
        .unwrap()
        .insert("/stage".into(), b"changed".to_vec());
    assert!(matches!(
        plan.retire_copied_sources(&mut changed, &sftp, &CancellationToken::new(), |_| Ok(()))
            .await,
        Err(RemoteTreeError::SourceChanged)
    ));
    assert_eq!(changed.uncertain_index(), None);
    seen.files
        .lock()
        .unwrap()
        .insert("/stage".into(), SNAPSHOT.to_vec());
    let mut ledger = SourceRetirement::new(&plan).unwrap();
    assert!(matches!(
        plan.retire_copied_sources(&mut ledger, &sftp, &CancellationToken::new(), |_| Err(
            RemoteTreeError::Checkpoint
        ))
        .await,
        Err(RemoteTreeError::Checkpoint)
    ));
    assert_eq!(ledger.uncertain_index(), Some(0));
    assert_eq!(seen.removes.load(Ordering::SeqCst), 0);
    assert_eq!(seen.files.lock().unwrap()["/stage"], SNAPSHOT);
    assert_eq!(seen.files.lock().unwrap()["/new"], SNAPSHOT);
    sftp.close().await.unwrap();
    server.await.unwrap();
}
