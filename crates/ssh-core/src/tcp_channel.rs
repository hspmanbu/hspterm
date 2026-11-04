//! Transport-bound direct-tcpip capability. It never creates an SSH connection.
use crate::{
    Client, SshError, Stage, proxy,
    transport::{CancelStream, Lifetime},
};
use russh::{ChannelStream, client};
use std::{
    net::SocketAddr,
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

/// Shared by all clones and all acquisitions from this authenticated transport.
/// Pending opens and live TCP channels together are bounded to 64.
#[derive(Clone)]
pub struct TcpConnector {
    handle: Arc<client::Handle<Client>>,
    transport: CancellationToken,
    slots: Arc<Semaphore>,
}
pub struct TcpChannel {
    stream: CancelStream<CancelStream<ChannelStream<client::Msg>>>,
    _lifetime: Lifetime,
    _permit: OwnedSemaphorePermit,
}
impl TcpConnector {
    pub(crate) fn transport_token(&self) -> CancellationToken {
        self.transport.clone()
    }
    pub(crate) fn is_closed(&self) -> bool {
        self.transport.is_cancelled() || self.handle.is_closed()
    }
    pub(crate) fn new(handle: Arc<client::Handle<Client>>, transport: CancellationToken) -> Self {
        Self {
            handle,
            transport,
            slots: Arc::new(Semaphore::new(64)),
        }
    }
    /// The destination is resolved by the SSH server, never locally. Origin is
    /// the accepted socket's peer metadata, not a shell fragment or credential.
    /// Cancelling/dropping an open never cancels the owning SSH session.
    pub async fn open(
        &self,
        address: &str,
        port: u16,
        origin: SocketAddr,
        timeout: Duration,
        cancel: CancellationToken,
    ) -> Result<TcpChannel, SshError> {
        let address = proxy::host(address)
            .filter(|_| port != 0 && !timeout.is_zero())
            .ok_or(SshError::InvalidConfig)?
            .to_owned();
        if self.transport.is_cancelled() {
            return Err(SshError::Cancelled);
        }
        if self.handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        let local = cancel.child_token();
        let lifetime = Lifetime(local.clone());
        let work = async {
            let permit = self
                .slots
                .clone()
                .acquire_owned()
                .await
                .map_err(|_| SshError::Closed)?;
            let (reply, response) = oneshot::channel();
            let handle = self.handle.clone();
            let transport = self.transport.clone();
            // russh's channel-open future cannot safely be abandoned on a local
            // timeout: a late confirmation would have no ChannelCloseOnDrop.
            // Keep consuming that exact request under this shared bound; a late
            // stream sent to a dropped receiver is closed and releases its slot.
            // Only transport cancellation may abandon it (the socket then closes).
            tokio::spawn(async move {
                let result = tokio::select! {
                    biased;
                    _ = transport.cancelled() => Err(SshError::Cancelled),
                    result = handle.channel_open_direct_tcpip_flow_controlled(address, port.into(), origin.ip().to_string(), origin.port().into()) => result.map_err(SshError::from),
                }.map(|channel| (channel.into_stream(), permit));
                drop(reply.send(result));
            });
            response.await.map_err(|_| SshError::Disconnected)?
        };
        let (stream, permit) = tokio::select! {
            biased;
            _ = self.transport.cancelled() => return Err(SshError::Cancelled),
            _ = local.cancelled() => return Err(SshError::Cancelled),
            result = tokio::time::timeout(timeout, work) => result.map_err(|_| SshError::Timeout(Stage::Forward))??,
        };
        Ok(TcpChannel {
            stream: CancelStream::new(CancelStream::new(stream, self.transport.clone()), local),
            _lifetime: lifetime,
            _permit: permit,
        })
    }
}
impl AsyncRead for TcpChannel {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_read(cx, buffer)
    }
}
impl AsyncWrite for TcpChannel {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.get_mut().stream).poll_write(cx, bytes)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_shutdown(cx)
    }
}
