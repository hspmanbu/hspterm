//! Observe editor READ/WRITE and CLOSE, including failures after all bytes arrived.
use hspterm_ssh_core::{
    SftpSession,
    bandwidth::BandwidthLimiter,
    edit::{self, EditFileError},
    transfer::stage_remote_file_limited,
    transfer::{RemoteCopyError, RemoteCopyMode, copy_remote_file_limited},
};
use russh_sftp::{
    protocol::{
        Attrs, Data, File as RemoteFile, FileAttributes, Handle, Name, OpenFlags, Status,
        StatusCode,
    },
    server::Handler,
};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use std::{
    io,
    pin::Pin,
    task::{Context, Poll},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::{
    sync::{Notify, watch},
    time::{Duration, timeout},
};
use tokio_util::sync::CancellationToken;

#[derive(Default)]
struct Observed {
    body: Mutex<Vec<u8>>,
    opens: AtomicUsize,
    reads: AtomicUsize,
    closes: AtomicUsize,
    permissions: AtomicUsize,
}

#[tokio::test]
async fn remote_relay_preserves_operation_and_both_file_close_failures() {
    for (source_close, target_close, read_failure) in [
        (false, true, false),
        (true, false, false),
        (true, true, true),
    ] {
        let (source, source_seen, source_server) = peer(source_close, read_failure, None).await;
        let (target, target_seen, target_server) = peer(target_close, false, None).await;
        let budget = BandwidthLimiter::default();
        let mut acknowledged = 0;
        let result = copy_remote_file_limited(
            &source,
            "/fixture",
            &target,
            "/fixture",
            RemoteCopyMode::Resume { offset: 0 },
            &CancellationToken::new(),
            &budget,
            &budget,
            |p| acknowledged = p.acknowledged,
        )
        .await;
        match result {
            Err(RemoteCopyError::Close {
                operation,
                source_close: first,
                destination_close: second,
            }) => {
                assert_eq!(operation.is_some(), read_failure);
                assert_eq!(first.is_some(), source_close);
                assert_eq!(second.is_some(), target_close);
            }
            other => panic!("expected combined close failure, got {other:?}"),
        }
        assert_eq!(source_seen.closes.load(Ordering::SeqCst), 1);
        assert_eq!(target_seen.closes.load(Ordering::SeqCst), 1);
        assert_eq!(
            acknowledged,
            if read_failure {
                0
            } else {
                b"complete controlled editor body".len() as u64
            }
        );
        source.close().await.unwrap();
        target.close().await.unwrap();
        timeout(Duration::from_secs(2), source_server)
            .await
            .unwrap()
            .unwrap();
        timeout(Duration::from_secs(2), target_server)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn remote_relay_budgets_actual_read_requests_without_prefetch_after_cancel() {
    let (source, observed, source_server) = peer(false, false, None).await;
    let (target, target_seen, target_server) = peer(false, false, None).await;
    let stop = CancellationToken::new();
    let mut progress = Vec::new();
    let result = copy_remote_file_limited(
        &source,
        "/fixture",
        &target,
        "/fixture",
        RemoteCopyMode::Resume { offset: 0 },
        &stop,
        &BandwidthLimiter::default(),
        &BandwidthLimiter::new(1),
        |p| {
            progress.push(p.acknowledged);
            if p.acknowledged > 0 {
                stop.cancel();
            }
        },
    )
    .await;
    assert!(result.is_err());
    assert_eq!(progress, [0, 1]);
    assert_eq!(observed.reads.load(Ordering::SeqCst), 1);
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    assert_eq!(target_seen.closes.load(Ordering::SeqCst), 1);
    source.close().await.unwrap();
    target.close().await.unwrap();
    timeout(Duration::from_secs(2), source_server)
        .await
        .unwrap()
        .unwrap();
    timeout(Duration::from_secs(2), target_server)
        .await
        .unwrap()
        .unwrap();
}
struct Gate {
    entered: Notify,
    release: watch::Sender<bool>,
}

#[tokio::test]
async fn staging_refuses_insecure_permissions_before_reading_any_source_body() {
    let (source, seen_source, source_server) = peer(false, false, None).await;
    let (target, seen_target, target_server) = peer(false, false, None).await;
    seen_target.permissions.store(0o100644, Ordering::SeqCst);
    let original = seen_target.body.lock().unwrap().clone();
    let budget = BandwidthLimiter::default();
    assert!(matches!(
        stage_remote_file_limited(
            &source,
            "/fixture",
            &target,
            "/fixture",
            RemoteCopyMode::Resume { offset: 0 },
            &CancellationToken::new(),
            &budget,
            &budget,
            |_| {}
        )
        .await,
        Err(RemoteCopyError::InvalidStaging)
    ));
    assert_eq!(seen_source.reads.load(Ordering::SeqCst), 0);
    assert_eq!(*seen_target.body.lock().unwrap(), original);
    assert_eq!(seen_source.closes.load(Ordering::SeqCst), 1);
    assert_eq!(seen_target.closes.load(Ordering::SeqCst), 1);
    source.close().await.unwrap();
    target.close().await.unwrap();
    timeout(Duration::from_secs(2), source_server)
        .await
        .unwrap()
        .unwrap();
    timeout(Duration::from_secs(2), target_server)
        .await
        .unwrap()
        .unwrap();
}
struct Peer {
    observed: Arc<Observed>,
    fail_close: bool,
    fail_read: bool,
    gate: Option<Arc<Gate>>,
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
    async fn realpath(&mut self, id: u32, _: String) -> Result<Name, Self::Error> {
        Ok(Name {
            id,
            files: vec![RemoteFile::new("/fixture", FileAttributes::default())],
        })
    }
    async fn lstat(&mut self, id: u32, _: String) -> Result<Attrs, Self::Error> {
        Ok(Attrs {
            id,
            attrs: FileAttributes {
                size: Some(self.observed.body.lock().unwrap().len() as u64),
                permissions: Some(self.observed.permissions.load(Ordering::SeqCst) as u32),
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
        _: String,
        flags: OpenFlags,
        _: FileAttributes,
    ) -> Result<Handle, Self::Error> {
        self.observed.opens.fetch_add(1, Ordering::SeqCst);
        if flags.contains(OpenFlags::TRUNCATE) {
            self.observed.body.lock().unwrap().clear();
        }
        Ok(Handle {
            id,
            handle: "fixture".into(),
        })
    }
    async fn read(
        &mut self,
        id: u32,
        _: String,
        offset: u64,
        len: u32,
    ) -> Result<Data, Self::Error> {
        self.observed.reads.fetch_add(1, Ordering::SeqCst);
        if self.fail_read {
            return Err(StatusCode::Failure);
        }
        let body = self.observed.body.lock().unwrap();
        let from = offset as usize;
        if from >= body.len() {
            return Err(StatusCode::Eof);
        }
        Ok(Data {
            id,
            data: body[from..body.len().min(from + len as usize)].to_vec(),
        })
    }
    async fn write(
        &mut self,
        id: u32,
        _: String,
        offset: u64,
        data: Vec<u8>,
    ) -> Result<Status, Self::Error> {
        let mut body = self.observed.body.lock().unwrap();
        let from = offset as usize;
        let length = body.len().max(from + data.len());
        body.resize(length, 0);
        body[from..from + data.len()].copy_from_slice(&data);
        Ok(ok(id))
    }
    async fn close(&mut self, id: u32, _: String) -> Result<Status, Self::Error> {
        self.observed.closes.fetch_add(1, Ordering::SeqCst);
        if let Some(gate) = &self.gate {
            let mut release = gate.release.subscribe();
            gate.entered.notify_one();
            release.wait_for(|v| *v).await.unwrap();
        }
        if self.fail_close {
            Err(StatusCode::Failure)
        } else {
            Ok(ok(id))
        }
    }
}
async fn peer(
    fail_close: bool,
    fail_read: bool,
    gate: Option<Arc<Gate>>,
) -> (Arc<SftpSession>, Arc<Observed>, tokio::task::JoinHandle<()>) {
    let observed = Arc::new(Observed::default());
    observed.permissions.store(0o100600, Ordering::SeqCst);
    *observed.body.lock().unwrap() = b"complete controlled editor body".to_vec();
    let (client, server) = tokio::io::duplex(16384);
    let task = tokio::spawn(russh_sftp::server::run(
        server,
        Peer {
            observed: observed.clone(),
            fail_close,
            fail_read,
            gate,
        },
    ));
    (
        Arc::new(SftpSession::new(client).await.unwrap()),
        observed,
        task,
    )
}
#[tokio::test]
async fn complete_editor_bytes_are_not_success_when_read_or_write_close_fails() {
    let (sftp, observed, server) = peer(true, false, None).await;
    let stop = CancellationToken::new();
    let budget = BandwidthLimiter::default();
    let mut read_bytes = 0;
    assert!(matches!(
        edit::read_file(&sftp, "/fixture", 1024, &stop, &budget, |p| read_bytes =
            p.acknowledged)
        .await,
        Err(EditFileError::Close(_))
    ));
    assert_eq!(read_bytes, b"complete controlled editor body".len() as u64);
    let mut written = 0;
    assert!(matches!(
        edit::write_file(
            &sftp,
            "/fixture",
            b"new complete body",
            &stop,
            &budget,
            |p| written = p.acknowledged
        )
        .await,
        Err(EditFileError::Close(_))
    ));
    assert_eq!(written, 17);
    assert_eq!(*observed.body.lock().unwrap(), b"new complete body");
    assert_eq!(observed.closes.load(Ordering::SeqCst), 2);
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}
#[tokio::test]
async fn editor_capacity_rejects_before_open_and_cancel_still_awaits_close() {
    let gate = Arc::new(Gate {
        entered: Notify::new(),
        release: watch::channel(false).0,
    });
    let (sftp, observed, server) = peer(false, false, Some(gate.clone())).await;
    let budget = BandwidthLimiter::default();
    assert!(matches!(
        edit::read_file(
            &sftp,
            "/fixture",
            1,
            &CancellationToken::new(),
            &budget,
            |_| {}
        )
        .await,
        Err(EditFileError::Capacity)
    ));
    assert_eq!(observed.opens.load(Ordering::SeqCst), 0);
    assert_eq!(observed.reads.load(Ordering::SeqCst), 0);
    let session = sftp.clone();
    let stop = CancellationToken::new();
    let mut request = tokio::spawn(async move {
        edit::read_file(&session, "/fixture", 1024, &stop, &budget, |_| {
            stop.cancel()
        })
        .await
    });
    timeout(Duration::from_secs(2), gate.entered.notified())
        .await
        .unwrap();
    assert!(
        timeout(Duration::from_millis(30), &mut request)
            .await
            .is_err()
    );
    assert_eq!(observed.reads.load(Ordering::SeqCst), 0);
    gate.release.send_replace(true);
    assert!(matches!(
        request.await.unwrap(),
        Err(EditFileError::Cancelled)
    ));
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}
#[tokio::test]
async fn editor_reports_both_the_io_failure_and_unconfirmed_cleanup() {
    let (sftp, _, server) = peer(true, true, None).await;
    assert!(matches!(
        edit::read_file(
            &sftp,
            "/fixture",
            1024,
            &CancellationToken::new(),
            &BandwidthLimiter::default(),
            |_| {}
        )
        .await,
        Err(EditFileError::FailedClose { .. })
    ));
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}

struct ShortReader {
    left: usize,
    fail: bool,
}
impl AsyncRead for ShortReader {
    fn poll_read(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if self.fail {
            return Poll::Ready(Err(io::Error::other("synthetic local read failure")));
        }
        let count = self.left.min(buf.remaining()).min(7);
        buf.put_slice(&vec![42; count]);
        self.left -= count;
        Poll::Ready(Ok(()))
    }
}
struct FailedSink;
impl AsyncWrite for FailedSink {
    fn poll_write(self: Pin<&mut Self>, _: &mut Context<'_>, _: &[u8]) -> Poll<io::Result<usize>> {
        Poll::Ready(Err(io::Error::other("synthetic local write failure")))
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}
#[tokio::test]
async fn streaming_rejects_bad_local_sources_before_truncation_and_checks_exact_length() {
    let (sftp, observed, server) = peer(false, false, None).await;
    let initial = observed.body.lock().unwrap().clone();
    let stop = CancellationToken::new();
    let budget = BandwidthLimiter::default();
    for (count, declared, fail) in [(2, 3, false), (4, 3, false), (0, 0, true), (1, 0, false)] {
        let mut source = ShortReader { left: count, fail };
        assert!(
            edit::write_from_reader(
                &sftp,
                "/fixture",
                &mut source,
                declared,
                &stop,
                &budget,
                |_| {}
            )
            .await
            .is_err()
        );
        assert_eq!(*observed.body.lock().unwrap(), initial);
        assert_eq!(observed.opens.load(Ordering::SeqCst), 0);
    }
    let mut source = ShortReader {
        left: 65541,
        fail: false,
    };
    let result = edit::write_from_reader(
        &sftp,
        "/fixture",
        &mut source,
        65541,
        &stop,
        &budget,
        |_| {},
    )
    .await
    .unwrap();
    assert_eq!(result.acknowledged, 65541);
    assert_eq!(*observed.body.lock().unwrap(), vec![42; 65541]);
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}
#[tokio::test]
async fn streaming_sink_errors_and_failed_close_are_both_reported() {
    let (sftp, observed, server) = peer(true, false, None).await;
    let result = edit::read_to_writer(
        &sftp,
        "/fixture",
        &mut FailedSink,
        u64::MAX,
        &CancellationToken::new(),
        &BandwidthLimiter::default(),
        |_| {},
    )
    .await;
    assert!(matches!(result, Err(EditFileError::FailedClose { .. })));
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}

#[tokio::test]
async fn blocked_stream_sink_applies_backpressure_and_cancel_still_closes_remote() {
    let (sftp, observed, server) = peer(false, false, None).await;
    *observed.body.lock().unwrap() = vec![13; 256 * 1024];
    let (mut writer, _blocked_reader) = tokio::io::duplex(1);
    let stop = CancellationToken::new();
    let request_stop = stop.clone();
    let request_sftp = sftp.clone();
    let task = tokio::spawn(async move {
        edit::read_to_writer(
            &request_sftp,
            "/fixture",
            &mut writer,
            u64::MAX,
            &request_stop,
            &BandwidthLimiter::default(),
            |_| {},
        )
        .await
    });
    timeout(Duration::from_secs(2), async {
        while observed.reads.load(Ordering::SeqCst) == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    // With prefetch disabled, blocking the local sink prevents a second READ.
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert_eq!(observed.reads.load(Ordering::SeqCst), 1);
    assert_eq!(observed.closes.load(Ordering::SeqCst), 0);
    stop.cancel();
    assert!(matches!(
        timeout(Duration::from_secs(2), task)
            .await
            .unwrap()
            .unwrap(),
        Err(EditFileError::Cancelled)
    ));
    assert_eq!(observed.closes.load(Ordering::SeqCst), 1);
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}
