//! Protocol peer for page boundaries, close acknowledgement and cancellation.
use hspterm_ssh_core::{
    SftpSession,
    tree_transfer::{Direction, TreeError, TreeTransfer},
};
use russh_sftp::{
    protocol::{Attrs, File, FileAttributes, Handle, Name, Status, StatusCode},
    server::Handler,
};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tokio::{
    sync::Notify,
    time::{Duration, timeout},
};
use tokio_util::sync::CancellationToken;
#[derive(Default)]
struct Observed {
    reads: AtomicUsize,
    closes: AtomicUsize,
    entered: Notify,
    release: Notify,
}
struct Peer {
    observed: Arc<Observed>,
    pages: usize,
    stall: bool,
    fail_close: bool,
    canonical: String,
}
impl Handler for Peer {
    type Error = StatusCode;
    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }
    async fn realpath(&mut self, id: u32, _: String) -> Result<Name, Self::Error> {
        Ok(Name {
            id,
            files: vec![File::new(self.canonical.clone(), FileAttributes::default())],
        })
    }
    async fn opendir(&mut self, id: u32, _: String) -> Result<Handle, Self::Error> {
        Ok(Handle {
            id,
            handle: "directory".into(),
        })
    }
    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        Ok(Attrs {
            id,
            attrs: FileAttributes {
                size: Some(0),
                permissions: Some(if path == self.canonical {
                    0o040700
                } else {
                    0o100600
                }),
                ..FileAttributes::default()
            },
        })
    }
    async fn readdir(&mut self, id: u32, _: String) -> Result<Name, Self::Error> {
        let page = self.observed.reads.fetch_add(1, Ordering::SeqCst);
        if self.stall && page == 1 {
            self.observed.entered.notify_one();
            self.observed.release.notified().await;
        }
        if page >= self.pages {
            return Err(StatusCode::Eof);
        }
        let mut files: Vec<_> = (0..64)
            .map(|n| {
                File::new(
                    format!("item-{:06}", page * 64 + n),
                    FileAttributes::default(),
                )
            })
            .collect();
        files.push(File::new(".", FileAttributes::default()));
        files.push(File::new("..", FileAttributes::default()));
        Ok(Name { id, files })
    }
    async fn close(&mut self, id: u32, _: String) -> Result<Status, Self::Error> {
        self.observed.closes.fetch_add(1, Ordering::SeqCst);
        if self.fail_close {
            return Err(StatusCode::Failure);
        }
        Ok(Status {
            id,
            status_code: StatusCode::Ok,
            error_message: String::new(),
            language_tag: String::new(),
        })
    }
}
async fn connect(pages: usize, stall: bool, fail_close: bool) -> (SftpSession, Arc<Observed>) {
    connect_path(pages, stall, fail_close, "/fixture".into()).await
}
#[tokio::test]
async fn recursive_search_does_not_publish_completion_after_a_failed_directory_close() {
    let (sftp, observed) = connect(1, false, true).await;
    let stop = CancellationToken::new();
    let mut cursor =
        hspterm_ssh_core::search::RecursiveSearch::open(&sftp, "/fixture", "item", false, &stop)
            .await
            .unwrap();
    assert!(cursor.next_page(&sftp, 256, &stop).await.is_err());
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    assert!(matches!(
        cursor.next_page(&sftp, 256, &stop).await,
        Err(hspterm_ssh_core::search::SearchError::Interrupted)
    ));
    // Shutdown the dedicated channel after the explicitly asserted CLOSE error.
    sftp.close().await.unwrap();
}
async fn connect_path(
    pages: usize,
    stall: bool,
    fail_close: bool,
    canonical: String,
) -> (SftpSession, Arc<Observed>) {
    let observed = Arc::new(Observed::default());
    let (client, server) = tokio::io::duplex(16384);
    tokio::spawn(russh_sftp::server::run(
        server,
        Peer {
            observed: observed.clone(),
            pages,
            stall,
            fail_close,
            canonical,
        },
    ));
    (SftpSession::new(client).await.unwrap(), observed)
}
async fn closed(observed: &Observed) {
    timeout(Duration::from_secs(2), async {
        while observed.closes.load(Ordering::SeqCst) != 1 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
}
#[tokio::test]
async fn collecting_api_preserves_reverse_page_order_and_propagates_close_errors() {
    let (sftp, observed) = connect(32, false, false).await;
    let names: Vec<_> = sftp
        .read_dir("/fixture")
        .await
        .unwrap()
        .map(|entry| {
            assert_eq!(entry.path(), format!("/fixture/{}", entry.file_name()));
            entry.file_name()
        })
        .collect();
    assert_eq!(names.len(), 2048);
    assert_eq!(names.first().unwrap(), "item-001984");
    assert_eq!(names.last().unwrap(), "item-000063");
    assert_eq!(observed.reads.load(Ordering::SeqCst), 33);
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    sftp.close().await.unwrap();
    let (sftp, observed) = connect(1, false, true).await;
    assert!(sftp.read_dir("/fixture").await.is_err());
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    sftp.close().await.unwrap();
}

#[tokio::test]
async fn directory_stream_has_no_prefetch_and_closes_once_on_eof_or_early_drop() {
    for early in [false, true] {
        let (sftp, observed) = connect(32, false, false).await;
        let mut stream = sftp.read_dir_stream("/fixture").await.unwrap();
        assert_eq!(observed.reads.load(Ordering::SeqCst), 0);
        assert_eq!(stream.next_page().await.unwrap().unwrap().len(), 66);
        for _ in 0..10 {
            tokio::task::yield_now().await;
        }
        assert_eq!(observed.reads.load(Ordering::SeqCst), 1);
        if early {
            drop(stream);
            closed(&observed).await;
            assert_eq!(observed.reads.load(Ordering::SeqCst), 1);
        } else {
            let mut count = 1;
            while stream.next_page().await.unwrap().is_some() {
                count += 1;
            }
            assert_eq!(count, 32);
            assert!(stream.next_page().await.unwrap().is_none());
            stream.close().await.unwrap();
            drop(stream);
            closed(&observed).await;
            assert_eq!(observed.reads.load(Ordering::SeqCst), 33);
        }
        assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
        sftp.close().await.unwrap();
    }
    let (sftp, observed) = connect(0, false, true).await;
    let mut stream = sftp.read_dir_stream("/fixture").await.unwrap();
    assert!(
        stream.next_page().await.is_err(),
        "CLOSE failure must not be EOF success"
    );
    drop(stream);
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    sftp.close().await.unwrap();
}
#[tokio::test]
async fn tree_scan_consumes_pages_skips_dot_entries_and_closes_on_cancel() {
    let temp = tempfile::tempdir().unwrap();
    let (sftp, observed) = connect(32, false, false).await;
    let plan = TreeTransfer::scan(
        Direction::Download,
        temp.path().join("target"),
        "/fixture".into(),
        &sftp,
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(plan.nodes.len(), 32 * 64 + 1);
    assert_eq!(plan.stats().files, 32 * 64);
    assert_eq!(plan.nodes[1].relative, "item-000000");
    assert_eq!(plan.nodes.last().unwrap().relative, "item-002047");
    assert!(!temp.path().join("target").exists());
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    sftp.close().await.unwrap();

    let (sftp, observed) = connect(32, true, false).await;
    let sftp = Arc::new(sftp);
    let stop = CancellationToken::new();
    let task = {
        let sftp = sftp.clone();
        let stop = stop.clone();
        let local = temp.path().join("cancelled");
        tokio::spawn(async move {
            TreeTransfer::scan(
                Direction::Download,
                local,
                "/fixture".into(),
                &sftp,
                &stop,
                |_| {},
            )
            .await
        })
    };
    timeout(Duration::from_secs(2), observed.entered.notified())
        .await
        .unwrap();
    stop.cancel();
    assert!(matches!(
        timeout(Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap(),
        Err(TreeError::Cancelled)
    ));
    observed.release.notify_one();
    closed(&observed).await;
    assert_eq!(observed.reads.load(Ordering::SeqCst), 2);
    assert!(!temp.path().join("cancelled").exists());
    sftp.close().await.unwrap();
}

#[tokio::test]
async fn rescan_cancel_during_readdir_retains_the_original_manifest_and_closes_handle() {
    use hspterm_ssh_core::tree_transfer::NodeState;
    let temp = tempfile::tempdir().unwrap();
    let (initial, _) = connect(1, false, false).await;
    let mut plan = TreeTransfer::scan(
        Direction::Download,
        temp.path().join("target"),
        "/fixture".into(),
        &initial,
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .unwrap();
    initial.close().await.unwrap();
    plan.nodes[0].state = NodeState::Failed;
    let plan = Arc::new(plan);
    let before = serde_json::to_vec(&*plan).unwrap();
    let (sftp, observed) = connect(32, true, false).await;
    let sftp = Arc::new(sftp);
    let stop = CancellationToken::new();
    let task = {
        let plan = plan.clone();
        let sftp = sftp.clone();
        let stop = stop.clone();
        tokio::spawn(async move { plan.rescan_failed(&[0], &sftp, &stop, |_| {}).await })
    };
    timeout(Duration::from_secs(2), observed.entered.notified())
        .await
        .unwrap();
    stop.cancel();
    assert!(matches!(
        timeout(Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap(),
        Err(TreeError::Cancelled)
    ));
    assert_eq!(serde_json::to_vec(&*plan).unwrap(), before);
    assert!(!temp.path().join("target").exists());
    observed.release.notify_one();
    closed(&observed).await;
    sftp.close().await.unwrap();
}

#[tokio::test]
async fn batch_rename_metadata_cancel_and_errors_never_publish_a_partial_candidate() {
    use hspterm_ssh_core::tree_transfer::{ConflictDecision, NodeKind, NodeState, TransferNode};
    struct RenamePeer {
        observed: Arc<Observed>,
        stall: bool,
    }
    impl Handler for RenamePeer {
        type Error = StatusCode;
        fn unimplemented(&self) -> Self::Error {
            StatusCode::OpUnsupported
        }
        async fn lstat(&mut self, _: u32, path: String) -> Result<Attrs, Self::Error> {
            assert_eq!(path, "/destination (1).txt");
            self.observed.reads.fetch_add(1, Ordering::SeqCst);
            if self.stall {
                self.observed.entered.notify_one();
                self.observed.release.notified().await;
            }
            Err(StatusCode::PermissionDenied)
        }
    }
    let temp = tempfile::tempdir().unwrap();
    let plan = Arc::new(TreeTransfer {
        version: 1,
        direction: Direction::Upload,
        local: temp.path().join("source.txt"),
        remote: "/destination.txt".into(),
        nodes: vec![TransferNode {
            relative: String::new(),
            kind: NodeKind::File,
            size: 5,
            acknowledged: 0,
            started: false,
            state: NodeState::Conflict,
            decision: ConflictDecision::Ask,
            destination_name: None,
            error: Some("fixture conflict".into()),
            default_policy_pending: true,
        }],
    });
    let before = serde_json::to_vec(&*plan).unwrap();
    for stall in [true, false] {
        let observed = Arc::new(Observed::default());
        let (client, server) = tokio::io::duplex(4096);
        tokio::spawn(russh_sftp::server::run(
            server,
            RenamePeer {
                observed: observed.clone(),
                stall,
            },
        ));
        let sftp = Arc::new(SftpSession::new(client).await.unwrap());
        let stop = CancellationToken::new();
        let task = {
            let plan = plan.clone();
            let sftp = sftp.clone();
            let stop = stop.clone();
            tokio::spawn(async move { plan.rename_conflicts(&sftp, &stop).await })
        };
        if stall {
            timeout(Duration::from_secs(2), observed.entered.notified())
                .await
                .unwrap();
            stop.cancel();
        }
        let result = timeout(Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap();
        if stall {
            assert!(matches!(result, Err(TreeError::Cancelled)));
        } else {
            assert!(matches!(result, Err(TreeError::Remote(_))));
        }
        assert_eq!(observed.reads.load(Ordering::SeqCst), 1);
        assert_eq!(serde_json::to_vec(&*plan).unwrap(), before);
        assert!(!temp.path().join("source.txt").exists());
        if stall {
            observed.release.notify_one();
        }
        sftp.close().await.unwrap();
    }
}

#[tokio::test]
async fn browser_reader_pulls_bounded_pages_and_never_reuses_failed_or_cancelled_reads() {
    use hspterm_ssh_core::directory::{DirectoryError, DirectoryReader};
    let (sftp, observed) = connect(32, false, false).await;
    let mut reader = DirectoryReader::open(&sftp, "/fixture".into())
        .await
        .unwrap();
    assert_eq!(observed.reads.load(Ordering::SeqCst), 0);
    for invalid in [0, 257] {
        assert!(matches!(
            reader.next_page(invalid).await,
            Err(DirectoryError::InvalidPage)
        ));
    }
    let first = reader.next_page(17).await.unwrap();
    assert_eq!(first.entries.len(), 17);
    assert_eq!(first.entries[0].path, "/fixture/item-000000");
    assert!(!first.done);
    assert_eq!(observed.reads.load(Ordering::SeqCst), 1);
    let second = reader.next_page(17).await.unwrap();
    assert_eq!(second.entries.len(), 17);
    assert_eq!(observed.reads.load(Ordering::SeqCst), 1);
    let mut count = 34;
    loop {
        let page = reader.next_page(17).await.unwrap();
        assert!(page.entries.len() <= 17);
        count += page.entries.len();
        if page.done {
            break;
        }
    }
    assert_eq!(count, 2048);
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    assert!(reader.next_page(17).await.unwrap().done);
    reader.close().await.unwrap();
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    sftp.close().await.unwrap();

    let (sftp, observed) = connect(0, false, true).await;
    let mut reader = DirectoryReader::open(&sftp, "/fixture".into())
        .await
        .unwrap();
    assert!(matches!(
        reader.next_page(17).await,
        Err(DirectoryError::Remote(_))
    ));
    assert!(matches!(
        reader.next_page(17).await,
        Err(DirectoryError::Interrupted)
    ));
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    sftp.close().await.unwrap();

    let (sftp, observed) = connect(32, true, false).await;
    let mut reader = DirectoryReader::open(&sftp, "/fixture".into())
        .await
        .unwrap();
    let reading = reader.next_page(256);
    assert!(timeout(Duration::from_millis(100), reading).await.is_err());
    assert_eq!(observed.reads.load(Ordering::SeqCst), 2);
    assert!(matches!(
        reader.next_page(17).await,
        Err(DirectoryError::Interrupted)
    ));
    observed.release.notify_one();
    reader.close().await.unwrap();
    sftp.close().await.unwrap();
}

#[tokio::test]
async fn browser_reader_validates_canonical_paths_and_bounds_expanded_metadata_bytes() {
    use hspterm_ssh_core::directory::{DirectoryError, DirectoryReader, MAX_PAGE_BYTES};
    for path in ["relative", "/invalid\0path"] {
        let (sftp, observed) = connect_path(1, false, false, path.into()).await;
        assert!(matches!(
            DirectoryReader::open(&sftp, "/fixture".into()).await,
            Err(DirectoryError::InvalidPath)
        ));
        assert_eq!(observed.reads.load(Ordering::SeqCst), 0);
        sftp.close().await.unwrap();
    }
    let root = format!("/{}", "p".repeat(131000));
    let (sftp, _) = connect_path(5, false, false, root.clone()).await;
    let mut reader = DirectoryReader::open(&sftp, "/fixture".into())
        .await
        .unwrap();
    // A long canonical prefix may expand a small server NAME packet manyfold.
    // Enforce both a per-bridge-page budget and the whole-listing path budget.
    let mut count = 0;
    loop {
        match reader.next_page(256).await {
            Ok(page) => {
                assert!(
                    page.entries
                        .iter()
                        .map(|e| e.name.len() + e.path.len() + 128)
                        .sum::<usize>()
                        <= MAX_PAGE_BYTES
                );
                count += page.entries.len();
                assert!(!page.done, "capacity must fail, never silently truncate");
            }
            Err(DirectoryError::Capacity) => break,
            Err(error) => panic!("unexpected fixture error: {error}"),
        }
    }
    assert!(count > 0);
    assert!(matches!(
        reader.next_page(1).await,
        Err(DirectoryError::Interrupted)
    ));
    reader.close().await.unwrap();
    sftp.close().await.unwrap();
}
