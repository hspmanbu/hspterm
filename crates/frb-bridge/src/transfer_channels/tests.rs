//! Owned duplex peers; no SSH credentials, production files or transport resets.
use super::*;
use futures_util::task::AtomicWaker;
use hspterm_ssh_core::task_scheduler::TaskScheduler;
use russh_sftp::{client::Config, protocol::StatusCode};
use std::{
    pin::Pin,
    sync::atomic::{AtomicBool, Ordering},
    task::{Context, Poll},
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    sync::Notify,
    time::{Duration, timeout},
};
#[derive(Default)]
struct Gate {
    entered: Notify,
    released: AtomicBool,
    dropped: AtomicBool,
    waker: AtomicWaker,
}
impl Gate {
    fn release(&self) {
        self.released.store(true, Ordering::Release);
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
        if !this.gate.released.load(Ordering::Acquire) {
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
async fn worker_panic_keeps_fifo_admission_until_both_real_local_io_owners_retire() {
    let channels = Arc::new(Channels::default());
    let gate = Arc::new(Gate::default());
    let scheduler = TaskScheduler::new(1).unwrap();
    let stop = CancellationToken::new();
    let permit = scheduler.enqueue().enter(&stop).await.unwrap();
    let mut next = Box::pin(scheduler.enqueue().enter(&stop));
    let (client, server) = tokio::io::duplex(16384);
    let peer = tokio::spawn(russh_sftp::server::run_owned(server, Peer));
    let owner = channels.clone();
    let stream_gate = gate.clone();
    let worker = tokio::spawn(async move {
        let _permit = permit;
        owner
            .supervise(async {
                let session = SftpSession::new(Gated {
                    inner: client,
                    gate: stream_gate,
                })
                .await?;
                let _session = owner.adopt(session);
                panic!("synthetic private packet must never be printed by the hook");
                #[allow(unreachable_code)]
                Ok::<_, anyhow::Error>(())
            })
            .await
    });
    timeout(Duration::from_secs(2), gate.entered.notified())
        .await
        .unwrap();
    assert!(!worker.is_finished());
    assert!(!gate.dropped.load(Ordering::Acquire));
    assert!(!channels.is_empty());
    assert!(timeout(Duration::from_millis(20), &mut next).await.is_err());
    gate.release();
    let result = timeout(Duration::from_secs(2), worker)
        .await
        .unwrap()
        .unwrap()
        .unwrap_err();
    assert!(!result.to_string().contains("synthetic private packet"));
    assert!(result.to_string().contains("操作结果未确认"));
    assert!(gate.dropped.load(Ordering::Acquire));
    assert!(channels.is_empty());
    drop(
        timeout(Duration::from_secs(2), next)
            .await
            .unwrap()
            .unwrap(),
    );
    peer.await.unwrap();
}

#[tokio::test(start_paused = true)]
async fn failed_retirement_is_retained_and_prevents_new_work_until_the_original_io_ends() {
    let channels = Channels::default();
    let gate = Arc::new(Gate::default());
    let (client, server) = tokio::io::duplex(16384);
    let peer = tokio::spawn(russh_sftp::server::run_owned(server, Peer));
    let result: Result<()> = channels
        .supervise(async {
            let session = SftpSession::new_with_config(
                Gated {
                    inner: client,
                    gate: gate.clone(),
                },
                Config {
                    request_timeout_secs: 1,
                    ..Default::default()
                },
            )
            .await?;
            let _session = channels.adopt(session);
            bail!("synthetic operation failure")
        })
        .await;
    let error = result.unwrap_err();
    assert!(error.to_string().contains("本机收尾未确认"));
    assert!(!channels.is_empty());
    assert_eq!(channels.sessions.lock().len(), 1);
    let ran = AtomicBool::new(false);
    let result = channels
        .supervise(async {
            ran.store(true, Ordering::Release);
            Ok(())
        })
        .await;
    assert!(result.is_err());
    assert!(!ran.load(Ordering::Acquire));
    assert_eq!(channels.sessions.lock().len(), 1);
    gate.release();
    channels
        .supervise(async {
            ran.store(true, Ordering::Release);
            Ok(())
        })
        .await
        .unwrap();
    assert!(ran.load(Ordering::Acquire));
    assert!(channels.is_empty());
    assert!(gate.dropped.load(Ordering::Acquire));
    peer.await.unwrap();
}

#[tokio::test]
async fn dropping_the_cleanup_future_does_not_remove_its_actual_session_owner() {
    let channels = Arc::new(Channels::default());
    let gate = Arc::new(Gate::default());
    let (client, server) = tokio::io::duplex(16384);
    let peer = tokio::spawn(russh_sftp::server::run_owned(server, Peer));
    let owner = channels.clone();
    let stream_gate = gate.clone();
    let worker = tokio::spawn(async move {
        owner
            .supervise(async {
                owner.adopt(
                    SftpSession::new(Gated {
                        inner: client,
                        gate: stream_gate,
                    })
                    .await?,
                );
                Ok(())
            })
            .await
    });
    timeout(Duration::from_secs(2), gate.entered.notified())
        .await
        .unwrap();
    worker.abort();
    assert!(worker.await.unwrap_err().is_cancelled());
    assert_eq!(channels.sessions.lock().len(), 1);
    assert!(!gate.dropped.load(Ordering::Acquire));
    gate.release();
    timeout(Duration::from_secs(2), channels.supervise(async { Ok(()) }))
        .await
        .unwrap()
        .unwrap();
    assert!(channels.is_empty());
    assert!(gate.dropped.load(Ordering::Acquire));
    peer.await.unwrap();
}

#[tokio::test]
async fn independent_metadata_batches_retire_only_their_own_io_and_task_retains_the_other() {
    let task = Channels::default();
    let first = task.batch();
    let second = task.batch();
    let (a, pa) = tokio::io::duplex(16384);
    let (b, pb) = tokio::io::duplex(16384);
    let peer_a = tokio::spawn(russh_sftp::server::run_owned(pa, Peer));
    let peer_b = tokio::spawn(russh_sftp::server::run_owned(pb, Peer));
    let a = task.adopt(SftpSession::new(a).await.unwrap());
    let b = task.adopt(SftpSession::new(b).await.unwrap());
    first.local.record(a.clone());
    second.local.record(b.clone());
    first.supervise(async { Ok(()) }).await.unwrap();
    assert!(a.local_io_closed());
    assert!(!b.local_io_closed());
    assert!(!task.is_empty());
    assert_eq!(task.sessions.lock().len(), 1);
    // A caught query panic must close its own batch without abandoning the
    // task-level owner or printing its synthetic payload.
    let result: Result<()> = second
        .supervise(async {
            panic!("synthetic query payload");
            #[allow(unreachable_code)]
            Ok(())
        })
        .await;
    assert!(result.is_err());
    assert!(
        !result
            .unwrap_err()
            .to_string()
            .contains("synthetic query payload")
    );
    assert!(b.local_io_closed());
    assert!(task.is_empty());
    peer_a.await.unwrap();
    peer_b.await.unwrap();
}
