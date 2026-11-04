//! Original-Transport SFTP channel/IO ownership. A local timeout cannot abandon
//! an unknown channel-open; live IO streams and pending opens share one bound.
use crate::{
    Client, SftpSession, SshError, Stage,
    transport::{CancelStream, Lifetime},
};
use russh::{Channel, ChannelMsg, ChannelStream, client};
use std::{
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    sync::{OwnedSemaphorePermit, Semaphore, oneshot},
};
use tokio_util::sync::CancellationToken;
const CHANNELS: u32 = 64;
const TIMEOUT: Duration = Duration::from_secs(30);
#[derive(Clone)]
pub(crate) struct SftpConnector {
    handle: Arc<client::Handle<Client>>,
    root: CancellationToken,
    slots: Arc<Semaphore>,
}
// The permit follows the actual duplex stream through SFTP's two IO workers,
// not the API request, Session wrapper or a detached handshake future.
struct OwnedStream {
    stream: CancelStream<ChannelStream<client::Msg>>,
    _permit: OwnedSemaphorePermit,
}
impl AsyncRead for OwnedStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        b: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_read(cx, b)
    }
}
impl AsyncWrite for OwnedStream {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        b: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.get_mut().stream).poll_write(cx, b)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_shutdown(cx)
    }
}
impl SftpConnector {
    pub fn new(handle: Arc<client::Handle<Client>>, root: CancellationToken) -> Self {
        Self {
            handle,
            root,
            slots: Arc::new(Semaphore::new(CHANNELS as usize)),
        }
    }
    pub async fn wait_closed(&self) {
        // Only called after original Root cancellation. Closing is about actual
        // local stream retirement, not an assertion about a remote CLOSE ACK.
        if let Ok(permit) = self.slots.acquire_many(CHANNELS).await {
            drop(permit);
        }
    }
    pub async fn open(&self) -> Result<SftpSession, SshError> {
        if self.root.is_cancelled() || self.handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        let permit = self
            .slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| SshError::SftpCapacity)?;
        let local = CancellationToken::new();
        let _cancel_on_return = Lifetime(local.clone());
        let worker_cancel = local.clone();
        let root = self.root.clone();
        let handle = self.handle.clone();
        let (reply, receive) = oneshot::channel();
        tokio::spawn(async move {
            let mut reply = Some(reply);
            let result = async {
                let mut channel = tokio::select! {
                    biased;
                    _ = root.cancelled() => return Err(SshError::Disconnected),
                    result = handle.channel_open_session_flow_controlled() => result?,
                };
                let negotiation = tokio::select! {
                    biased;
                    _ = root.cancelled() => Err(SshError::Disconnected),
                    _ = worker_cancel.cancelled() => Err(SshError::Cancelled),
                    result = tokio::time::timeout(TIMEOUT, subsystem(&mut channel)) => result.unwrap_or_else(|_| Err(SshError::Timeout(Stage::Sftp))),
                };
                if let Err(error) = negotiation {
                    // Channel ID is known now. Keep its bound until the late
                    // close is retired or Root ends; never send another request.
                    // A definite refusal is already known. Report it promptly,
                    // while the worker retains the channel/permit until CLOSE
                    // acknowledgement or root retirement. A peer withholding
                    // CLOSE must not turn a refusal into a retryable timeout.
                    if let Some(reply) = reply.take() {
                        let _ = reply.send(Err(error));
                    }
                    retire(channel, &root).await;
                    drop(permit);
                    return Err(SshError::Cancelled);
                }
                let stream = OwnedStream { stream: CancelStream::new(channel.into_stream(), root.clone()), _permit: permit };
                // If this future is cancelled, RawSftpSession Drop requests
                // shutdown. The permit still follows its actual IO workers.
                tokio::select! {
                    biased;
                    _ = root.cancelled() => Err(SshError::Disconnected),
                    _ = worker_cancel.cancelled() => Err(SshError::Cancelled),
                    result = SftpSession::new(stream) => result.map_err(SshError::from),
                }
            }.await;
            if let Some(reply) = reply
                && let Err(Ok(session)) = reply.send(result)
            {
                // Receiver disappeared just as init completed; wait for actual
                // local IO retirement rather than leaving a live subsystem.
                let _ = session.close().await;
            }
        });
        tokio::select! {
            biased;
            _ = self.root.cancelled() => Err(SshError::Disconnected),
            result = tokio::time::timeout(TIMEOUT, receive) => result.map_err(|_| SshError::Timeout(Stage::Sftp))?.map_err(|_| SshError::Disconnected)?,
        }
    }
}
async fn subsystem(channel: &mut Channel<client::Msg>) -> Result<(), SshError> {
    channel.request_subsystem(true, "sftp").await?;
    let mut events = 0u32;
    loop {
        events = events.wrapping_add(1);
        if events.is_multiple_of(64) {
            tokio::task::yield_now().await;
        }
        match channel.wait().await {
            Some(ChannelMsg::Success) => return Ok(()),
            Some(ChannelMsg::WindowAdjusted { .. } | ChannelMsg::XonXoff { .. }) => {}
            Some(ChannelMsg::Close | ChannelMsg::Eof) | None => return Err(SshError::Disconnected),
            Some(ChannelMsg::ReceiveWindowError) => return Err(russh::Error::Inconsistent.into()),
            // No VERSION/data is legal before we have sent SFTP INIT. Never
            // silently discard premature bytes or collect an unbounded banner.
            _ => return Err(SshError::RequestDenied(Stage::Sftp)),
        }
    }
}
async fn retire(mut channel: Channel<client::Msg>, root: &CancellationToken) {
    if root.is_cancelled() {
        return;
    }
    let closed = tokio::select! {
        _ = root.cancelled() => true,
        result = tokio::time::timeout(Duration::from_secs(2), async {
            channel.close().await.map_err(|_| ())?;
            let mut bytes = 0usize;
            let mut events = 0u32;
            loop {
                events = events.wrapping_add(1);
                if events.is_multiple_of(64) { tokio::task::yield_now().await; }
                match channel.wait().await {
                    Some(ChannelMsg::Close) | None => return Ok::<_, ()>(()),
                    Some(ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. }) => {
                        bytes = bytes.checked_add(data.len()).ok_or(())?;
                        if bytes > 64 * 1024 { return Err(()); }
                    }
                    _ => {},
                }
            }
        }) => matches!(result, Ok(Ok(()))),
    };
    if !closed {
        drop(channel.into_stream());
        root.cancelled().await;
    }
}
