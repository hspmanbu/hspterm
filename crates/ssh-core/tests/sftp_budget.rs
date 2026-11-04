//! Synthetic SFTP peer observes READ packets themselves, not only local progress.
use hspterm_ssh_core::{
    SftpSession,
    bandwidth::BandwidthLimiter,
    transfer::{FileDisposition, download_file_limited},
};
use russh_sftp::{
    protocol::{Attrs, Data, FileAttributes, Handle, OpenFlags, Status, StatusCode},
    server::Handler,
};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};
use tokio::sync::{Notify, watch};
use tokio::time::{Duration, Instant};
use tokio_util::sync::CancellationToken;
struct Peer {
    start: Instant,
    bytes: Arc<AtomicU64>,
    close: Option<Arc<CloseGate>>,
}
struct CloseGate {
    entered: Notify,
    release: watch::Sender<bool>,
    fail: bool,
}
impl Handler for Peer {
    type Error = StatusCode;
    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }
    async fn lstat(&mut self, id: u32, _: String) -> Result<Attrs, Self::Error> {
        Ok(Attrs {
            id,
            attrs: FileAttributes {
                size: Some(2048),
                permissions: Some(0o100600),
                ..FileAttributes::default()
            },
        })
    }
    async fn open(
        &mut self,
        id: u32,
        _: String,
        _: OpenFlags,
        _: FileAttributes,
    ) -> Result<Handle, Self::Error> {
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
        assert!(
            len <= 819,
            "READ bypassed shared budget via upstream prefetch"
        );
        assert!(offset < 2048);
        let sum = self.bytes.fetch_add(len as u64, Ordering::SeqCst) + len as u64;
        assert!(sum as f64 <= self.start.elapsed().as_secs_f64() * 8192.0 + 819.0);
        Ok(Data {
            id,
            data: vec![42; (len as u64).min(2048 - offset) as usize],
        })
    }
    async fn close(&mut self, id: u32, _: String) -> Result<Status, Self::Error> {
        if let Some(gate) = &self.close {
            let mut release = gate.release.subscribe();
            gate.entered.notify_one();
            release.wait_for(|allowed| *allowed).await.unwrap();
            if gate.fail {
                return Err(StatusCode::Failure);
            }
        }
        Ok(Status {
            id,
            status_code: StatusCode::Ok,
            error_message: String::new(),
            language_tag: String::new(),
        })
    }
}
#[tokio::test]
async fn downloads_budget_wire_read_lengths_and_disable_speculative_prefetch() {
    let temp = tempfile::tempdir().unwrap();
    let bytes = Arc::new(AtomicU64::new(0));
    let limiter = BandwidthLimiter::new(8192);
    let start = Instant::now();
    let mut workers = Vec::new();
    let mut peers = Vec::new();
    for i in 0..2 {
        let (client, server) = tokio::io::duplex(16384);
        peers.push(tokio::spawn(russh_sftp::server::run(
            server,
            Peer {
                start,
                bytes: bytes.clone(),
                close: None,
            },
        )));
        let sftp = SftpSession::new(client).await.unwrap();
        let limiter = limiter.clone();
        let local = temp.path().join(format!("file-{i}"));
        workers.push(tokio::spawn(async move {
            download_file_limited(
                &sftp,
                "/fixture",
                &local,
                FileDisposition::CreateNew,
                &CancellationToken::new(),
                |_| {},
                &limiter,
            )
            .await
            .unwrap();
            assert_eq!(std::fs::read(&local).unwrap(), vec![42; 2048]);
            sftp.close().await.unwrap();
        }));
    }
    for worker in workers {
        worker.await.unwrap();
    }
    for peer in peers {
        peer.await.unwrap();
    }
    assert_eq!(bytes.load(Ordering::SeqCst), 4096);
    assert!(start.elapsed() >= Duration::from_millis(400));
}

#[tokio::test]
async fn full_download_is_not_success_until_server_close_is_acknowledged() {
    let directory = tempfile::tempdir().unwrap();
    for fail in [false, true] {
        let (release, _) = watch::channel(false);
        let gate = Arc::new(CloseGate {
            entered: Notify::new(),
            release,
            fail,
        });
        let (client, server) = tokio::io::duplex(16384);
        let server = tokio::spawn(russh_sftp::server::run(
            server,
            Peer {
                start: Instant::now(),
                bytes: Arc::new(AtomicU64::new(0)),
                close: Some(gate.clone()),
            },
        ));
        let remote = Arc::new(SftpSession::new(client).await.unwrap());
        let reader = remote.clone();
        let path = directory.path().join(if fail {
            "close-failure"
        } else {
            "close-success"
        });
        let destination = path.clone();
        let work = tokio::spawn(async move {
            download_file_limited(
                &reader,
                "/fixture",
                &destination,
                FileDisposition::CreateNew,
                &CancellationToken::new(),
                |_| {},
                &BandwidthLimiter::new(8192),
            )
            .await
        });
        tokio::time::timeout(Duration::from_secs(3), gate.entered.notified())
            .await
            .unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), vec![42; 2048]);
        assert!(
            !work.is_finished(),
            "full bytes cannot bypass pending CLOSE"
        );
        gate.release.send_replace(true);
        let result = tokio::time::timeout(Duration::from_secs(3), work)
            .await
            .unwrap()
            .unwrap();
        if fail {
            assert!(result.is_err(), "CLOSE failure cannot become success");
        } else {
            assert_eq!(result.unwrap().acknowledged, 2048);
        }
        remote.close().await.unwrap();
        drop(remote);
        tokio::time::timeout(Duration::from_secs(3), server)
            .await
            .unwrap()
            .unwrap();
    }
}
