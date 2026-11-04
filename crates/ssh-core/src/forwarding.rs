//! Local TCP forwarding on an existing authenticated SSH transport. No shell,
//! implicit reconnect, local DNS resolution of targets or detached local sockets.
use crate::{SshError, TcpConnector, proxy};
use std::{net::SocketAddr, time::Duration};
use tokio::{
    net::TcpListener,
    sync::watch,
    task::{JoinHandle, JoinSet},
};
use tokio_util::sync::CancellationToken;
mod socks5;
pub use socks5::Socks5Error;

#[derive(Clone)]
enum Mode {
    Fixed { target: String, port: u16 },
    Socks5,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ForwardStatus {
    pub accepted: u64,
    pub active: u32,
    pub failed: u64,
    pub last_error: Option<String>,
    pub stopped: bool,
}
pub struct LocalForward {
    address: SocketAddr,
    cancel: CancellationToken,
    state: watch::Receiver<ForwardStatus>,
    task: Option<JoinHandle<Result<(), SshError>>>,
}
impl LocalForward {
    /// Binding is explicit; callers should default to loopback. Port zero asks
    /// the OS for an ephemeral listening port, exposed by local_addr().
    /// A listening socket is not a successful connection to the remote target.
    pub async fn start(
        connector: TcpConnector,
        bind: SocketAddr,
        target: String,
        port: u16,
        open_timeout: Duration,
    ) -> Result<Self, SshError> {
        let target = proxy::host(&target)
            .filter(|_| port != 0 && !open_timeout.is_zero())
            .ok_or(SshError::InvalidConfig)?
            .to_owned();
        Self::listen(connector, bind, Mode::Fixed { target, port }, open_timeout).await
    }
    /// SSH -D style SOCKS5 CONNECT, no-authentication subset. Bind deliberately;
    /// normal application configuration must default to a loopback address.
    pub async fn socks5(
        connector: TcpConnector,
        bind: SocketAddr,
        open_timeout: Duration,
    ) -> Result<Self, SshError> {
        Self::listen(connector, bind, Mode::Socks5, open_timeout).await
    }
    async fn listen(
        connector: TcpConnector,
        bind: SocketAddr,
        mode: Mode,
        open_timeout: Duration,
    ) -> Result<Self, SshError> {
        if open_timeout.is_zero() {
            return Err(SshError::InvalidConfig);
        }
        if connector.is_closed() {
            return Err(SshError::Disconnected);
        }
        let listener = TcpListener::bind(bind).await?;
        let address = listener.local_addr()?;
        if connector.is_closed() {
            return Err(SshError::Disconnected);
        }
        let cancel = connector.transport_token().child_token();
        let (sender, state) = watch::channel(ForwardStatus::default());
        let task = tokio::spawn(run(
            listener,
            connector,
            mode,
            open_timeout,
            cancel.clone(),
            sender,
        ));
        Ok(Self {
            address,
            cancel,
            state,
            task: Some(task),
        })
    }
    pub fn local_addr(&self) -> SocketAddr {
        self.address
    }
    pub fn status(&self) -> ForwardStatus {
        self.state.borrow().clone()
    }
    pub fn subscribe(&self) -> watch::Receiver<ForwardStatus> {
        self.state.clone()
    }
    /// Stop accepting and await release of this listener and all its local
    /// socket/stream owners. Late SSH confirmations still use bounded cleanup.
    pub async fn stop(&mut self) -> Result<(), SshError> {
        self.cancel.cancel();
        if let Some(task) = self.task.as_mut() {
            // Keep the handle owned here across await. If this caller is
            // cancelled, a later stop must still join the same cleanup task.
            let result = task.await;
            self.task.take();
            result.map_err(|_| SshError::ForwardWorker)??;
        }
        Ok(())
    }
}
impl Drop for LocalForward {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}
fn failure(state: &mut ForwardStatus, error: &SshError) {
    state.failed = state.failed.saturating_add(1);
    state.last_error = Some(error.to_string());
}
async fn run(
    listener: TcpListener,
    connector: TcpConnector,
    mode: Mode,
    deadline: Duration,
    cancel: CancellationToken,
    states: watch::Sender<ForwardStatus>,
) -> Result<(), SshError> {
    let mut jobs = JoinSet::new();
    let mut state = ForwardStatus::default();
    let mut result = loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => break Ok(()),
            accepted = listener.accept(), if jobs.len() < 64 => {
                let (mut socket, origin) = match accepted {
                    Ok(pair) => pair,
                    Err(error) => { let error = SshError::Io(error); failure(&mut state, &error); break Err(error); }
                };
                let cap = connector.clone(); let mode = mode.clone(); let token = cancel.clone();
                jobs.spawn(async move {
                    let mut channel = match mode {
                        Mode::Fixed { target, port } => cap.open(&target, port, origin, deadline, token).await?,
                        Mode::Socks5 => socks5::connect(&mut socket, &cap, origin, deadline, token).await?,
                    };
                    tokio::io::copy_bidirectional(&mut socket, &mut channel).await?;
                    Ok::<(), SshError>(())
                });
                state.accepted = state.accepted.saturating_add(1);
            },
            job = jobs.join_next(), if !jobs.is_empty() => {
                match job {
                    Some(Ok(Err(error))) => failure(&mut state, &error),
                    Some(Err(_)) => { failure(&mut state, &SshError::ForwardWorker); break Err(SshError::ForwardWorker); },
                    Some(Ok(Ok(()))) => {},
                    None => unreachable!("join set checked nonempty"),
                }
            },
        }
        state.active = jobs.len() as u32;
        states.send_replace(state.clone());
    };
    // Release the listening address before publishing a stopped state.
    drop(listener);
    jobs.abort_all();
    while let Some(job) = jobs.join_next().await {
        match job {
            Ok(Err(error)) => failure(&mut state, &error),
            Err(error) if !error.is_cancelled() => {
                failure(&mut state, &SshError::ForwardWorker);
                result = Err(SshError::ForwardWorker);
            }
            _ => {} // Successful completion or explicitly aborted owners.
        }
    }
    state.active = 0;
    state.stopped = true;
    states.send_replace(state);
    result
}
