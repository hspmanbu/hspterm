//! Server-side TCP listeners bound to one authenticated target transport.
//! Global requests are drained even after their local deadline or owner drops.
use crate::{Client, SshError, Stage, proxy};
use parking_lot::Mutex;
use russh::{Channel, ChannelOpenFailure, client};
use std::{
    net::{IpAddr, SocketAddr},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::copy_bidirectional,
    net::TcpStream,
    sync::{OwnedSemaphorePermit, Semaphore, mpsc, watch},
    task::JoinSet,
};
use tokio_util::sync::CancellationToken;

const RULES: usize = 32;
const STREAMS: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemotePhase {
    Starting,
    Listening,
    Stopping,
    /// The request may still be pending at the server. Inbound routing is off.
    CleanupPending,
    /// The server refused cancellation. Explicit retry is possible.
    CleanupDenied,
    Stopped,
    Failed,
    Disconnected,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemoteFailure {
    Cancelled,
    Timeout,
    Denied,
    Disconnected,
    Worker,
}
impl RemoteFailure {
    fn error(self) -> SshError {
        match self {
            Self::Cancelled => SshError::Cancelled,
            Self::Timeout => SshError::Timeout(Stage::Forward),
            Self::Denied => SshError::RequestDenied(Stage::Forward),
            Self::Disconnected => SshError::Disconnected,
            Self::Worker => SshError::ForwardWorker,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteStatus {
    pub phase: RemotePhase,
    /// Requested address and allocated port, not a claim about GatewayPorts.
    pub address: Option<SocketAddr>,
    pub started: Option<Result<SocketAddr, RemoteFailure>>,
    pub accepted: u64,
    pub active: u32,
    pub failed: u64,
    pub last_error: Option<String>,
}
struct Incoming {
    channel: Channel<client::Msg>,
    reply: client::ChannelOpenHandle,
    _permit: OwnedSemaphorePermit,
}
struct Route {
    bind: SocketAddr,
    stop: CancellationToken,
    state: watch::Sender<RemoteStatus>,
    incoming: mpsc::Sender<Incoming>,
    retry: mpsc::Sender<()>,
}
pub(crate) struct Router {
    routes: Mutex<Vec<Arc<Route>>>,
    streams: Arc<Semaphore>,
}
impl Router {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            routes: Mutex::new(Vec::new()),
            streams: Arc::new(Semaphore::new(STREAMS)),
        })
    }
    /// No network await in the shared SSH dispatcher. Deferred replies are
    /// rejected automatically if a bounded inbox/stream budget is exhausted.
    pub(crate) fn incoming(
        &self,
        channel: Channel<client::Msg>,
        address: &str,
        port: u32,
        reply: client::ChannelOpenHandle,
    ) {
        let route = {
            let routes = self.routes.lock();
            let mut matches = routes.iter().filter(|r| {
                let state = r.state.borrow();
                !r.stop.is_cancelled()
                    && state.phase == RemotePhase::Listening
                    && state.address.is_some_and(|a| {
                        u32::from(a.port()) == port && matches_address(a.ip(), address)
                    })
            });
            let first = matches.next();
            // A non-literal peer label such as localhost must not choose an
            // arbitrary IPv4/IPv6 rule when more than one could match it.
            if matches.next().is_some() {
                None
            } else {
                first.cloned()
            }
        };
        if let Some(route) = route
            && let Ok(permit) = self.streams.clone().try_acquire_owned()
        {
            // Dropping a failed try_send also drops the original deferred reply.
            drop(route.incoming.try_send(Incoming {
                channel,
                reply,
                _permit: permit,
            }));
        }
    }
}
fn matches_address(bind: IpAddr, received: &str) -> bool {
    if received == "localhost" {
        return bind.is_loopback();
    }
    received
        .parse::<IpAddr>()
        .is_ok_and(|ip| ip == bind || bind.is_unspecified() && ip.is_ipv4() == bind.is_ipv4())
}
fn overlaps(a: SocketAddr, b: SocketAddr) -> bool {
    a.port() == b.port()
        && a.port() != 0
        && a.is_ipv4() == b.is_ipv4()
        && (a.ip() == b.ip() || a.ip().is_unspecified() || b.ip().is_unspecified())
}
#[derive(Clone)]
pub struct RemoteConnector {
    handle: Arc<client::Handle<Client>>,
    transport: CancellationToken,
    router: Arc<Router>,
}
pub struct RemoteForward {
    route: Arc<Route>,
    state: watch::Receiver<RemoteStatus>,
}
impl RemoteConnector {
    pub(crate) fn new(
        handle: Arc<client::Handle<Client>>,
        transport: CancellationToken,
        router: Arc<Router>,
    ) -> Self {
        Self {
            handle,
            transport,
            router,
        }
    }
    /// Synchronously reserves a bounded original-transport rule and returns its
    /// owner before issuing any network request. Use wait_started for the ACK.
    pub fn listen(
        &self,
        bind: SocketAddr,
        target: String,
        port: u16,
        timeout: Duration,
    ) -> Result<RemoteForward, SshError> {
        let target = proxy::host(&target)
            .filter(|_| port != 0 && !timeout.is_zero())
            .ok_or(SshError::InvalidConfig)?
            .to_owned();
        if let SocketAddr::V6(a) = bind
            && (a.scope_id() != 0 || a.flowinfo() != 0)
        {
            return Err(SshError::InvalidConfig);
        }
        if self.transport.is_cancelled() || self.handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        let (incoming, receiver) = mpsc::channel(16);
        let (retry, retries) = mpsc::channel(1);
        let (state, view) = watch::channel(RemoteStatus {
            phase: RemotePhase::Starting,
            address: None,
            started: None,
            accepted: 0,
            active: 0,
            failed: 0,
            last_error: None,
        });
        let route = Arc::new(Route {
            bind,
            stop: self.transport.child_token(),
            state,
            incoming,
            retry,
        });
        {
            let mut routes = self.router.routes.lock();
            routes.retain(|r| {
                !matches!(
                    r.state.borrow().phase,
                    RemotePhase::Stopped | RemotePhase::Failed | RemotePhase::Disconnected
                )
            });
            if routes.len() >= RULES {
                return Err(SshError::Busy);
            }
            if routes
                .iter()
                .any(|r| overlaps(r.state.borrow().address.unwrap_or(r.bind), bind))
            {
                return Err(SshError::Busy);
            }
            routes.push(route.clone());
        }
        let connector = self.clone();
        let task_route = route.clone();
        tokio::spawn(async move {
            run(
                &connector,
                &task_route,
                receiver,
                retries,
                target,
                port,
                timeout,
            )
            .await;
            connector
                .router
                .routes
                .lock()
                .retain(|r| !Arc::ptr_eq(r, &task_route));
        });
        Ok(RemoteForward { route, state: view })
    }
}
impl RemoteForward {
    pub fn status(&self) -> RemoteStatus {
        self.state.borrow().clone()
    }
    pub fn subscribe(&self) -> watch::Receiver<RemoteStatus> {
        self.state.clone()
    }
    pub async fn wait_started(&self) -> Result<SocketAddr, SshError> {
        let mut state = self.state.clone();
        loop {
            if let Some(result) = state.borrow().started {
                return result.map_err(RemoteFailure::error);
            }
            state.changed().await.map_err(|_| SshError::ForwardWorker)?;
        }
    }
    /// Stops local routing immediately. A timeout means remote cleanup is
    /// unknown; the same worker continues consuming the original cancel ACK.
    /// After a definitive denial, calling stop again explicitly retries once.
    /// Dropping this future never loses the original operation's ownership.
    pub async fn stop(&self) -> Result<(), SshError> {
        self.route.stop.cancel();
        let mut state = self.state.clone();
        let retry = state.borrow_and_update().phase == RemotePhase::CleanupDenied;
        if retry {
            self.route.retry.try_send(()).map_err(|_| SshError::Busy)?;
            // Wait until that exact retry leaves the previous denied state.
            state.changed().await.map_err(|_| SshError::ForwardWorker)?;
        }
        loop {
            let phase = state.borrow_and_update().phase;
            match phase {
                RemotePhase::Stopped | RemotePhase::Failed => return Ok(()),
                RemotePhase::Disconnected => return Err(SshError::Disconnected),
                RemotePhase::CleanupPending => return Err(SshError::Timeout(Stage::Forward)),
                RemotePhase::CleanupDenied => return Err(SshError::RequestDenied(Stage::Forward)),
                _ => {}
            }
            state.changed().await.map_err(|_| SshError::ForwardWorker)?;
        }
    }
}
impl Drop for RemoteForward {
    fn drop(&mut self) {
        self.route.stop.cancel();
    }
}
fn phase(route: &Route, value: RemotePhase) {
    route.state.send_modify(|s| s.phase = value);
}
fn fail_start(route: &Route, failure: RemoteFailure, phase: RemotePhase) {
    route.state.send_modify(|s| {
        if s.started.is_none() {
            s.started = Some(Err(failure));
        }
        s.phase = phase;
    });
}
async fn run(
    connector: &RemoteConnector,
    route: &Route,
    mut incoming: mpsc::Receiver<Incoming>,
    mut retries: mpsc::Receiver<()>,
    target: String,
    port: u16,
    deadline: Duration,
) {
    if connector.transport.is_cancelled() {
        disconnected(route);
        return;
    }
    if route.stop.is_cancelled() {
        fail_start(route, RemoteFailure::Cancelled, RemotePhase::Stopped);
        return;
    }
    let address = route.bind.ip().to_string();
    let opening = connector
        .handle
        .tcpip_forward(address.clone(), u32::from(route.bind.port()));
    tokio::pin!(opening);
    let result = tokio::select! {
        biased;
        _ = connector.transport.cancelled() => { disconnected(route); return; }
        result = &mut opening => result,
        _ = route.stop.cancelled() => {
            fail_start(route, RemoteFailure::Cancelled, RemotePhase::Stopping);
            tokio::select! {
                biased;
                _ = connector.transport.cancelled() => { disconnected(route); return; }
                r = &mut opening => r,
                _ = tokio::time::sleep(deadline) => {
                    phase(route, RemotePhase::CleanupPending);
                    tokio::select! { biased; _ = connector.transport.cancelled() => { disconnected(route); return; }, r = &mut opening => r }
                }
            }
        }
        _ = tokio::time::sleep(deadline) => {
            route.stop.cancel();
            fail_start(route, RemoteFailure::Timeout, RemotePhase::CleanupPending);
            tokio::select! { biased; _ = connector.transport.cancelled() => { disconnected(route); return; }, r = &mut opening => r }
        }
    };
    let allocated = match result {
        Ok(value) => {
            let port = if route.bind.port() != 0 {
                route.bind.port()
            } else if let Ok(port) = u16::try_from(value)
                && port != 0
            {
                port
            } else {
                // Invalid allocation cannot be cancelled by guessing a port.
                fail_start(route, RemoteFailure::Worker, RemotePhase::CleanupPending);
                connector.transport.cancelled().await;
                disconnected(route);
                return;
            };
            SocketAddr::new(route.bind.ip(), port)
        }
        Err(russh::Error::RequestDenied) => {
            fail_start(route, RemoteFailure::Denied, RemotePhase::Failed);
            return;
        }
        Err(_) => {
            disconnected(route);
            return;
        }
    };
    let collision = {
        let routes = connector.router.routes.lock();
        let collision = routes.iter().any(|r| {
            let state = r.state.borrow();
            !std::ptr::eq(Arc::as_ptr(r), route)
                && !matches!(
                    state.phase,
                    RemotePhase::Stopped | RemotePhase::Failed | RemotePhase::Disconnected
                )
                && overlaps(state.address.unwrap_or(r.bind), allocated)
        });
        if !collision {
            route.state.send_modify(|s| {
                s.address = Some(allocated);
                if s.started.is_none() {
                    s.started = Some(if route.stop.is_cancelled() {
                        Err(RemoteFailure::Cancelled)
                    } else {
                        Ok(allocated)
                    });
                }
                s.phase = if route.stop.is_cancelled() {
                    RemotePhase::Stopping
                } else {
                    RemotePhase::Listening
                };
            });
        }
        collision
    };
    if collision {
        // An inconsistent allocation must not cancel another original rule.
        route.stop.cancel();
        fail_start(route, RemoteFailure::Worker, RemotePhase::CleanupPending);
        connector.transport.cancelled().await;
        disconnected(route);
        return;
    }
    let mut jobs = JoinSet::new();
    loop {
        tokio::select! {
            biased;
            _ = route.stop.cancelled() => break,
            event = jobs.join_next(), if !jobs.is_empty() => { completed(route, event); }
            event = incoming.recv() => {
                let Some(event) = event else { break; };
                if route.stop.is_cancelled() { drop(event); break; }
                route.state.send_modify(|s| { s.accepted = s.accepted.saturating_add(1); s.active += 1; });
                jobs.spawn(forward(event, target.clone(), port, deadline, route.stop.clone()));
            }
        }
    }
    // Release all local targets/streams before reporting any stop outcome.
    incoming.close();
    while let Ok(event) = incoming.try_recv() {
        drop(event);
    }
    jobs.abort_all();
    while jobs.join_next().await.is_some() {}
    route.state.send_modify(|s| {
        s.active = 0;
        s.phase = RemotePhase::Stopping;
    });
    if connector.transport.is_cancelled() {
        disconnected(route);
        return;
    }
    loop {
        let cancelling = connector
            .handle
            .cancel_tcpip_forward(address.clone(), u32::from(allocated.port()));
        tokio::pin!(cancelling);
        let result = tokio::select! {
            biased;
            _ = connector.transport.cancelled() => { disconnected(route); return; }
            result = &mut cancelling => result,
            _ = tokio::time::sleep(deadline) => {
                phase(route, RemotePhase::CleanupPending);
                tokio::select! { biased; _ = connector.transport.cancelled() => { disconnected(route); return; }, r = &mut cancelling => r }
            }
        };
        match result {
            Ok(()) => {
                phase(route, RemotePhase::Stopped);
                return;
            }
            Err(russh::Error::RequestDenied) => {
                phase(route, RemotePhase::CleanupDenied);
                tokio::select! {
                    biased;
                    _ = connector.transport.cancelled() => { disconnected(route); return; }
                    _ = retries.recv() => phase(route, RemotePhase::Stopping),
                }
            }
            Err(_) => {
                disconnected(route);
                return;
            }
        }
    }
}
fn disconnected(route: &Route) {
    route.stop.cancel();
    fail_start(
        route,
        RemoteFailure::Disconnected,
        RemotePhase::Disconnected,
    );
}
fn completed(route: &Route, event: Option<Result<Result<(), SshError>, tokio::task::JoinError>>) {
    route.state.send_modify(|s| {
        s.active = s.active.saturating_sub(1);
        if !matches!(event, Some(Ok(Ok(())))) {
            s.failed = s.failed.saturating_add(1);
            s.last_error = Some("远端转发目标连接或数据流失败".into());
        }
    });
}
async fn forward(
    event: Incoming,
    target: String,
    port: u16,
    deadline: Duration,
    stop: CancellationToken,
) -> Result<(), SshError> {
    let Incoming {
        channel,
        reply,
        _permit,
    } = event;
    let connected =
        tokio::time::timeout(deadline, TcpStream::connect((target.as_str(), port))).await;
    let mut socket = match connected {
        Ok(Ok(socket)) => socket,
        _ => {
            reply.reject(ChannelOpenFailure::ConnectFailed).await;
            return Err(SshError::RequestDenied(Stage::Forward));
        }
    };
    socket.set_nodelay(true)?;
    if stop.is_cancelled() {
        return Err(SshError::Cancelled);
    }
    reply.accept().await;
    let mut stream = channel.into_stream();
    copy_bidirectional(&mut stream, &mut socket).await?;
    Ok(())
}
