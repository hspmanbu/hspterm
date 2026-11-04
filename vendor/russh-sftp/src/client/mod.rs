pub mod error;
pub mod fs;
mod handler;
mod lifecycle;
pub mod rawsession;
pub(crate) mod runtime;
mod session;

pub use handler::Handler;
pub use rawsession::RawSftpSession;
pub use session::SftpSession;

use bytes::Bytes;
use tokio::{
    io::{self, AsyncRead, AsyncWrite, AsyncWriteExt},
    select,
    sync::mpsc,
};
use tokio_util::sync::CancellationToken;

use crate::{error::Error, protocol::Packet, utils::read_packet};

macro_rules! into_wrap {
    ($handler:expr) => {
        match $handler.await {
            Err(error) => Err(error.into()),
            Ok(()) => Ok(()),
        }
    };
}

#[derive(Clone, Debug)]
pub struct Config {
    /// Maximum size of a single packet in bytes. Default: 256 KiB.
    pub max_packet_len: u32,
    /// Maximum number of concurrent in-flight read requests. Default: 16.
    pub max_concurrent_reads: usize,
    /// Maximum number of concurrent in-flight write requests. Default: 16.
    pub max_concurrent_writes: usize,
    /// Preferred maximum size of a framed write packet. Default: 32 KiB.
    pub max_write_packet_len: u32,
    /// Timeout in seconds for each request. Default: 10.
    pub request_timeout_secs: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            max_packet_len: 262144,
            max_concurrent_reads: 16,
            max_concurrent_writes: 16,
            max_write_packet_len: 32768,
            request_timeout_secs: 10,
        }
    }
}

async fn execute_handler<H>(bytes: &mut Bytes, handler: &mut H) -> Result<(), error::Error>
where
    H: Handler + Send,
{
    match Packet::try_from(bytes)? {
        Packet::Version(p) => into_wrap!(handler.version(p)),
        Packet::Status(p) => into_wrap!(handler.status(p)),
        Packet::Handle(p) => into_wrap!(handler.handle(p)),
        Packet::Data(p) => into_wrap!(handler.data(p)),
        Packet::Name(p) => into_wrap!(handler.name(p)),
        Packet::Attrs(p) => into_wrap!(handler.attrs(p)),
        Packet::ExtendedReply(p) => into_wrap!(handler.extended_reply(p)),
        _ => Err(error::Error::UnexpectedBehavior(
            "A packet was received that could not be processed.".to_owned(),
        )),
    }
}

async fn process_handler<S, H>(stream: &mut S, handler: &mut H, cfg: &Config) -> Result<(), Error>
where
    S: AsyncRead + Unpin,
    H: Handler + Send,
{
    let mut bytes = read_packet(stream, cfg.max_packet_len).await?;
    Ok(execute_handler(&mut bytes, handler).await?)
}

/// Run processing stream as SFTP client. Is a simple handler of incoming
/// and outgoing packets. Can be used for non-standard implementations
pub fn run<S, H>(stream: S, handler: H) -> mpsc::UnboundedSender<Bytes>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    H: Handler + Send + 'static,
{
    run_with_config(stream, handler, Config::default())
}

/// Run processing stream as SFTP client with custom configuration
pub fn run_with_config<S, H>(stream: S, handler: H, cfg: Config) -> mpsc::UnboundedSender<Bytes>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    H: Handler + Send + 'static,
{
    run_tracked(stream, handler, cfg).0
}

pub(crate) fn run_tracked<S, H>(stream: S, handler: H, cfg: Config) -> (mpsc::UnboundedSender<Bytes>, lifecycle::Completion)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    H: Handler + Send + 'static,
{
    let (tx, mut rx) = mpsc::unbounded_channel::<Bytes>();
    let (rd, wr) = io::split(stream);
    let rc = CancellationToken::new();
    let wc = rc.clone();
    let (completion, reader_end, writer_end) = lifecycle::halves(rc.clone());
    runtime::spawn(async move {
        // Declare owned stream/handler after the guard: reverse local drop
        // order also releases them before publishing retirement on unwind.
        let _ended = reader_end;
        let mut rd = rd;
        let mut handler = handler;
        loop {
            select! {
                result = process_handler(&mut rd, &mut handler, &cfg) => match result {
                    Err(Error::UnexpectedEof | Error::IO(_)) => {
                        handler.transport_error(error::Error::ConnectionClosed);
                        break;
                    }
                    Err(_) => {
                        handler.transport_error(error::Error::UnexpectedPacket);
                        break;
                    }
                    Ok(()) => {},
                },
                _ = rc.cancelled() => break,
            }
        };
        rc.cancel();
        drop(rd);
        drop(handler);
    });
    runtime::spawn(async move {
        let _ended = writer_end;
        let mut wr = wr;
        loop {
            let data = select! {
                data = rx.recv() => data,
                _ = wc.cancelled() => break,
            };
            let Some(data) = data else { break; };
            if data.is_empty() {
                // Either outcome retires local IO; pending protocol requests
                // still get ConnectionClosed. This is never a file CLOSE ACK.
                select! {
                    _ = wr.shutdown() => {},
                    _ = wc.cancelled() => {},
                }
                break;
            }
            // Cancellation also governs a blocked write, not only rx.recv().
            let sent = select! {
                result = wr.write_all(&data[..]) => result.is_ok(),
                _ = wc.cancelled() => false,
            };
            if !sent { break; }
        };
        wc.cancel();
        drop(wr);
    });
    (tx, completion)
}
