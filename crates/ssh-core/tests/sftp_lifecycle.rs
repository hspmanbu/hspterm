//! Protocol/IO lifecycle tests, independent of real SSH or account resources.
use bytes::Bytes;
use futures_util::task::AtomicWaker;
use hspterm_ssh_core::SftpSession;
use russh_sftp::{
    client::{Config, error::Error},
    protocol::{Packet, StatusCode, Version},
};
use std::{
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf},
    sync::Notify,
    time::{Duration, timeout},
};

#[derive(Default)]
struct Gate {
    entered: Notify,
    open: AtomicBool,
    waker: AtomicWaker,
    dropped: AtomicBool,
}
impl Gate {
    fn release(&self) {
        self.open.store(true, Ordering::Release);
        self.waker.wake();
    }
}
struct Gated<S> {
    inner: S,
    gate: Arc<Gate>,
}
impl<S> Drop for Gated<S> {
    fn drop(&mut self) {
        self.gate.dropped.store(true, Ordering::Release);
    }
}
impl<S: AsyncRead + Unpin> AsyncRead for Gated<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        b: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_read(cx, b)
    }
}
impl<S: AsyncWrite + Unpin> AsyncWrite for Gated<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        b: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.get_mut().inner).poll_write(cx, b)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        let this = self.get_mut();
        this.gate.waker.register(cx.waker());
        this.gate.entered.notify_one();
        if !this.gate.open.load(Ordering::Acquire) {
            return Poll::Pending;
        }
        Pin::new(&mut this.inner).poll_shutdown(cx)
    }
}
struct Peer;
impl russh_sftp::server::Handler for Peer {
    type Error = StatusCode;
    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }
}
#[tokio::test]
async fn local_close_waits_for_both_actual_local_workers_and_is_idempotent() {
    let (client, server) = tokio::io::duplex(16384);
    let peer = tokio::spawn(russh_sftp::server::run_owned(server, Peer));
    let gate = Arc::new(Gate::default());
    let session = Arc::new(
        SftpSession::new(Gated {
            inner: client,
            gate: gate.clone(),
        })
        .await
        .unwrap(),
    );
    let cap = session.clone();
    let close = tokio::spawn(async move { cap.close().await });
    timeout(Duration::from_secs(2), gate.entered.notified())
        .await
        .unwrap();
    assert!(!close.is_finished());
    assert!(!gate.dropped.load(Ordering::Acquire));
    gate.release();
    timeout(Duration::from_secs(2), close)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(gate.dropped.load(Ordering::Acquire));
    session.close().await.unwrap();
    assert!(matches!(
        session.canonicalize(".").await,
        Err(Error::ConnectionClosed)
    ));
    timeout(Duration::from_secs(2), peer)
        .await
        .unwrap()
        .unwrap();
}
#[tokio::test(start_paused = true)]
async fn close_timeout_never_claims_retirement_and_a_later_explicit_wait_can_finish() {
    let (client, server) = tokio::io::duplex(16384);
    let peer = tokio::spawn(russh_sftp::server::run_owned(server, Peer));
    let gate = Arc::new(Gate::default());
    let session = Arc::new(
        SftpSession::new_with_config(
            Gated {
                inner: client,
                gate: gate.clone(),
            },
            Config {
                request_timeout_secs: 1,
                ..Default::default()
            },
        )
        .await
        .unwrap(),
    );
    let cap = session.clone();
    let close = tokio::spawn(async move { cap.close().await });
    gate.entered.notified().await;
    tokio::time::advance(Duration::from_secs(2)).await;
    assert!(matches!(close.await.unwrap(), Err(Error::Timeout)));
    assert!(!gate.dropped.load(Ordering::Acquire));
    gate.release();
    session.close().await.unwrap();
    assert!(gate.dropped.load(Ordering::Acquire));
    peer.await.unwrap();
}
async fn frame(stream: &mut tokio::io::DuplexStream) -> Vec<u8> {
    let len = stream.read_u32().await.unwrap() as usize;
    assert!(len <= 16384);
    let mut bytes = vec![0; len];
    stream.read_exact(&mut bytes).await.unwrap();
    bytes
}
#[tokio::test]
async fn malformed_packet_classification_survives_local_shutdown_and_late_requests() {
    let (client, mut server) = tokio::io::duplex(16384);
    let peer = tokio::spawn(async move {
        frame(&mut server).await; // INIT
        server
            .write_all(&Bytes::try_from(Packet::Version(Version::new())).unwrap())
            .await
            .unwrap();
        frame(&mut server).await; // LSTAT
        // INIT is a request, not a legal server response; no payload logging.
        server
            .write_all(&Bytes::try_from(Packet::Init(russh_sftp::protocol::Init::new())).unwrap())
            .await
            .unwrap();
        let mut tail = Vec::new();
        server.read_to_end(&mut tail).await.unwrap();
    });
    let session = SftpSession::new(client).await.unwrap();
    assert!(matches!(
        session.symlink_metadata("/fixture").await,
        Err(Error::UnexpectedPacket)
    ));
    session.close().await.unwrap();
    assert!(matches!(
        session.symlink_metadata("/fixture").await,
        Err(Error::UnexpectedPacket)
    ));
    peer.await.unwrap();
}

struct FilePeer {
    body: Arc<Vec<u8>>,
}
impl russh_sftp::server::Handler for FilePeer {
    type Error = StatusCode;
    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }
    async fn lstat(
        &mut self,
        id: u32,
        _: String,
    ) -> Result<russh_sftp::protocol::Attrs, Self::Error> {
        Ok(russh_sftp::protocol::Attrs {
            id,
            attrs: russh_sftp::protocol::FileAttributes {
                size: Some(self.body.len() as u64),
                permissions: Some(0o100600),
                ..Default::default()
            },
        })
    }
    async fn open(
        &mut self,
        id: u32,
        path: String,
        _: russh_sftp::protocol::OpenFlags,
        _: russh_sftp::protocol::FileAttributes,
    ) -> Result<russh_sftp::protocol::Handle, Self::Error> {
        Ok(russh_sftp::protocol::Handle { id, handle: path })
    }
    async fn read(
        &mut self,
        id: u32,
        _: String,
        offset: u64,
        len: u32,
    ) -> Result<russh_sftp::protocol::Data, Self::Error> {
        let offset = offset as usize;
        if offset >= self.body.len() {
            return Err(StatusCode::Eof);
        }
        Ok(russh_sftp::protocol::Data {
            id,
            data: self.body[offset..(offset + len as usize).min(self.body.len())].to_vec(),
        })
    }
    async fn close(
        &mut self,
        id: u32,
        _: String,
    ) -> Result<russh_sftp::protocol::Status, Self::Error> {
        Ok(russh_sftp::protocol::Status {
            id,
            status_code: StatusCode::Ok,
            error_message: String::new(),
            language_tag: String::new(),
        })
    }
}
#[tokio::test]
async fn channel_loss_stops_admission_preserves_ack_offsets_and_recovers_only_failed_channel_nodes()
{
    use hspterm_ssh_core::{
        bandwidth::BandwidthLimiter,
        tree_transfer::{
            ConflictDecision, Direction, NodeKind, NodeState, TransferNode, TreeError, TreeOutcome,
            TreeTransfer,
        },
    };
    use tokio_util::sync::CancellationToken;
    let dir = tempfile::tempdir().unwrap();
    let body = Arc::new((0..512 * 1024).map(|n| (n % 251) as u8).collect::<Vec<_>>());
    let mut plan = TreeTransfer {
        version: 1,
        direction: Direction::Download,
        local: dir.path().join("result"),
        remote: "/fixture".into(),
        nodes: (0..6)
            .map(|i| TransferNode {
                relative: if i == 0 {
                    String::new()
                } else {
                    format!("file-{i}.bin")
                },
                kind: if i == 0 {
                    NodeKind::Directory
                } else {
                    NodeKind::File
                },
                size: if i == 0 { 0 } else { body.len() as u64 },
                acknowledged: 0,
                started: false,
                state: NodeState::Pending,
                decision: ConflictDecision::Ask,
                destination_name: None,
                error: None,
                default_policy_pending: false,
            })
            .collect(),
    };
    let (client, server) = tokio::io::duplex(16384);
    let peer = tokio::spawn(russh_sftp::server::run_owned(
        server,
        FilePeer { body: body.clone() },
    ));
    let sftp = SftpSession::new(client).await.unwrap();
    let mut faulted = false;
    let result = timeout(
        Duration::from_secs(5),
        plan.run_parallel_observed(
            &sftp,
            &CancellationToken::new(),
            3,
            |p, event, active| {
                assert_eq!(event.stats, p.stats());
                assert!(active.len() <= 3);
                if !faulted && event.stats.acknowledged >= 65536 {
                    faulted = true;
                    peer.abort();
                }
            },
            &BandwidthLimiter::default(),
        ),
    )
    .await
    .unwrap();
    let Err(TreeError::TransientChannel(indices)) = result else {
        panic!("injected channel loss must be explicitly classified");
    };
    assert!(!indices.is_empty());
    assert!(indices.len() <= 3);
    assert!(plan.stats().acknowledged >= 65536);
    plan.validate().unwrap();
    sftp.close().await.unwrap();
    let Err(error) = peer.await else {
        panic!("fixture peer must have been aborted");
    };
    assert!(error.is_cancelled());
    for index in indices {
        assert_eq!(plan.nodes[index].state, NodeState::Failed);
        plan.nodes[index].state = NodeState::Pending;
        plan.nodes[index].error = None;
    }
    let (client, server) = tokio::io::duplex(16384);
    let peer = tokio::spawn(russh_sftp::server::run_owned(
        server,
        FilePeer { body: body.clone() },
    ));
    let sftp = SftpSession::new(client).await.unwrap();
    assert_eq!(
        plan.run_parallel_observed(
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
    for i in 1..6 {
        assert_eq!(
            std::fs::read(plan.local.join(format!("file-{i}.bin"))).unwrap(),
            *body
        );
    }
    sftp.close().await.unwrap();
    peer.await.unwrap();
}
