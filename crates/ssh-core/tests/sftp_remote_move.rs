//! Rename result ambiguity and errors are protocol outcomes, never a reason to
//! silently retry, remove the destination, or claim an operation was not sent.
use hspterm_ssh_core::{
    SftpSession,
    transfer::{RemoteMoveError, move_remote_path},
};
use russh_sftp::{
    protocol::{Attrs, File, FileAttributes, Name, Status, StatusCode},
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
    renames: AtomicUsize,
    removes: AtomicUsize,
    entered: Notify,
    release: Notify,
}
struct Peer {
    observed: Arc<Observed>,
    fail: bool,
}
impl Handler for Peer {
    type Error = StatusCode;
    fn unimplemented(&self) -> Self::Error {
        StatusCode::OpUnsupported
    }
    async fn realpath(&mut self, id: u32, path: String) -> Result<Name, Self::Error> {
        Ok(Name {
            id,
            files: vec![File::new(path, FileAttributes::default())],
        })
    }
    async fn lstat(&mut self, id: u32, path: String) -> Result<Attrs, Self::Error> {
        if !matches!(path.as_str(), "/" | "/source") {
            return Err(StatusCode::NoSuchFile);
        }
        Ok(Attrs {
            id,
            attrs: FileAttributes {
                permissions: Some(if path == "/" { 0o040700 } else { 0o100600 }),
                size: Some(0),
                ..FileAttributes::default()
            },
        })
    }
    async fn rename(
        &mut self,
        id: u32,
        source: String,
        destination: String,
    ) -> Result<Status, Self::Error> {
        assert_eq!(source, "/source");
        assert_eq!(destination, "/target");
        self.observed.renames.fetch_add(1, Ordering::SeqCst);
        if self.fail {
            return Err(StatusCode::PermissionDenied);
        }
        // The server can perform rename before its reply reaches the client.
        self.observed.entered.notify_one();
        self.observed.release.notified().await;
        Ok(Status {
            id,
            status_code: StatusCode::Ok,
            error_message: String::new(),
            language_tag: String::new(),
        })
    }
    async fn remove(&mut self, _: u32, _: String) -> Result<Status, Self::Error> {
        self.observed.removes.fetch_add(1, Ordering::SeqCst);
        Err(StatusCode::Failure)
    }
}
async fn peer(fail: bool) -> (Arc<SftpSession>, Arc<Observed>, tokio::task::JoinHandle<()>) {
    let observed = Arc::new(Observed::default());
    let (client, server) = tokio::io::duplex(4096);
    let task = tokio::spawn(russh_sftp::server::run(
        server,
        Peer {
            observed: observed.clone(),
            fail,
        },
    ));
    (
        Arc::new(SftpSession::new(client).await.unwrap()),
        observed,
        task,
    )
}
#[tokio::test]
async fn rejected_move_does_not_remove_retry_or_report_success() {
    let (sftp, observed, server) = peer(true).await;
    assert!(matches!(
        move_remote_path(&sftp, "/source", "/target", &CancellationToken::new()).await,
        Err(RemoteMoveError::Sftp(_))
    ));
    assert_eq!(observed.renames.load(Ordering::SeqCst), 1);
    assert_eq!(observed.removes.load(Ordering::SeqCst), 0);
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}
#[tokio::test]
async fn cancel_after_a_sent_rename_reports_uncertainty_without_automatic_retry() {
    let (sftp, observed, server) = peer(false).await;
    let stop = CancellationToken::new();
    let owned = sftp.clone();
    let request_stop = stop.clone();
    let work =
        tokio::spawn(
            async move { move_remote_path(&owned, "/source", "/target", &request_stop).await },
        );
    timeout(Duration::from_secs(2), observed.entered.notified())
        .await
        .unwrap();
    stop.cancel();
    assert!(matches!(
        timeout(Duration::from_secs(2), work)
            .await
            .unwrap()
            .unwrap(),
        Err(RemoteMoveError::Cancelled)
    ));
    assert_eq!(observed.renames.load(Ordering::SeqCst), 1);
    assert_eq!(observed.removes.load(Ordering::SeqCst), 0);
    observed.release.notify_one();
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}
