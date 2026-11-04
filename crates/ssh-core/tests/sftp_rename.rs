//! The peer decodes the actual extension payload, independently of its encoder.
use hspterm_ssh_core::SftpSession;
use russh_sftp::{
    client::error::Error,
    protocol::{Handle, Packet, Status, StatusCode, Version},
    server::Handler,
};
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};
use tokio::sync::{Notify, watch};
use tokio::time::{Duration, timeout};

const SOURCE: &str = "/remote/中文 space ' dollar$;\nsource";
const TARGET: &str = "/remote/target # percent%.txt";
#[derive(Clone, Copy)]
enum Response {
    Success,
    Failure,
    Unsupported,
    WrongPacket,
}
struct Gate {
    entered: Notify,
    release: watch::Sender<bool>,
}
struct Peer {
    version: Option<&'static str>,
    calls: Arc<AtomicUsize>,
    response: Response,
    gate: Option<Arc<Gate>>,
}
fn string<'a>(data: &mut &'a [u8]) -> &'a str {
    let len = u32::from_be_bytes(data[..4].try_into().unwrap()) as usize;
    let value = std::str::from_utf8(&data[4..4 + len]).unwrap();
    *data = &data[4 + len..];
    value
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
    async fn extended(
        &mut self,
        id: u32,
        request: String,
        data: Vec<u8>,
    ) -> Result<Packet, Self::Error> {
        assert_eq!(request, "posix-rename@openssh.com");
        let mut data = data.as_slice();
        assert_eq!(string(&mut data), SOURCE);
        assert_eq!(string(&mut data), TARGET);
        assert!(data.is_empty(), "extension has unexpected trailing fields");
        self.calls.fetch_add(1, Ordering::SeqCst);
        if let Some(gate) = &self.gate {
            let mut release = gate.release.subscribe();
            gate.entered.notify_one();
            release.wait_for(|allowed| *allowed).await.unwrap();
        }
        match self.response {
            Response::Failure => Err(StatusCode::PermissionDenied),
            Response::Unsupported => Err(StatusCode::OpUnsupported),
            Response::WrongPacket => Ok(Packet::Handle(Handle {
                id,
                handle: "wrong response".into(),
            })),
            Response::Success => Ok(Packet::Status(Status {
                id,
                status_code: StatusCode::Ok,
                error_message: String::new(),
                language_tag: String::new(),
            })),
        }
    }
    async fn rename(&mut self, _: u32, _: String, _: String) -> Result<Status, Self::Error> {
        panic!("standard rename must never be an implicit replacement fallback");
    }
}
async fn peer(
    version: Option<&'static str>,
    response: Response,
    gate: Option<Arc<Gate>>,
) -> (
    Arc<SftpSession>,
    Arc<AtomicUsize>,
    tokio::task::JoinHandle<()>,
) {
    let (client, server) = tokio::io::duplex(16384);
    let calls = Arc::new(AtomicUsize::new(0));
    let task = tokio::spawn(russh_sftp::server::run(
        server,
        Peer {
            version,
            response,
            gate,
            calls: calls.clone(),
        },
    ));
    (
        Arc::new(SftpSession::new(client).await.unwrap()),
        calls,
        task,
    )
}
#[tokio::test]
async fn only_negotiated_version_one_sends_an_overwriting_rename() {
    for version in [None, Some("0"), Some("2"), Some("01"), Some("")] {
        let (sftp, calls, server) = peer(version, Response::Success, None).await;
        assert!(!sftp.supports_posix_rename());
        assert!(!sftp.posix_rename(SOURCE, TARGET).await.unwrap());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        sftp.close().await.unwrap();
        timeout(Duration::from_secs(2), server)
            .await
            .unwrap()
            .unwrap();
    }
    for response in [
        Response::Success,
        Response::Failure,
        Response::Unsupported,
        Response::WrongPacket,
    ] {
        let (sftp, calls, server) = peer(Some("1"), response, None).await;
        assert!(sftp.supports_posix_rename());
        let result = sftp.posix_rename(SOURCE, TARGET).await;
        // Exactly one extension request: no silent standard-rename fallback.
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        match (response, result) {
            (Response::Success, Ok(true)) => {}
            (Response::Failure, Err(Error::Status(s)))
                if s.status_code == StatusCode::PermissionDenied => {}
            (Response::Unsupported, Err(Error::Status(s)))
                if s.status_code == StatusCode::OpUnsupported => {}
            (Response::WrongPacket, Err(Error::UnexpectedPacket)) => {}
            _ => panic!("unexpected rename result"),
        }
        sftp.close().await.unwrap();
        timeout(Duration::from_secs(2), server)
            .await
            .unwrap()
            .unwrap();
    }
}
#[tokio::test]
async fn posix_rename_does_not_complete_before_the_status_acknowledgement() {
    let gate = Arc::new(Gate {
        entered: Notify::new(),
        release: watch::channel(false).0,
    });
    let (sftp, calls, server) = peer(Some("1"), Response::Success, Some(gate.clone())).await;
    let session = sftp.clone();
    let mut request = tokio::spawn(async move { session.posix_rename(SOURCE, TARGET).await });
    timeout(Duration::from_secs(2), gate.entered.notified())
        .await
        .unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(
        timeout(Duration::from_millis(30), &mut request)
            .await
            .is_err()
    );
    gate.release.send_replace(true);
    assert!(
        timeout(Duration::from_secs(2), request)
            .await
            .unwrap()
            .unwrap()
            .unwrap()
    );
    sftp.close().await.unwrap();
    timeout(Duration::from_secs(2), server)
        .await
        .unwrap()
        .unwrap();
}
