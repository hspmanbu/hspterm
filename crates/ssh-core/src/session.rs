//! One independently owned pane/session, with explicit connection generations.
use crate::{Authentication, ConnectConfig, HostKeyPolicy, PtyEvent, SshConnection, SshError};
use alacritty_terminal::event::Event;
use hspterm_term_core::{FrameProbe, KeyEvent, MouseEvent, PastePlan, Size, Snapshot, Terminal};
use parking_lot::Mutex;
use std::{sync::Arc, time::Instant};
use tokio::{
    sync::{mpsc, oneshot, watch},
    task::JoinHandle,
};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionPhase {
    Idle,
    Connecting,
    Connected,
    Disconnected,
    Failed,
    Closed,
}
/// Original authenticated Transport identity delivered with its actor generation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionReceipt {
    pub generation: u64,
    pub host_key: crate::HostKey,
    pub username: String,
    pub tmux: Option<crate::tmux::TmuxState>,
    pub tmux_session: Option<crate::tmux::Identity>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionStatus {
    pub generation: u64,
    pub phase: SessionPhase,
    pub error: Option<String>,
    pub rtt_micros: Option<u64>,
}

/// Process platform requests even when the pane is invisible. Payloads must not be logged.
pub enum SessionEvent {
    ShellRestored {
        generation: u64,
    },
    /// No command body crosses the platform event boundary.
    HistoryWarning {
        generation: u64,
    },
    Notification {
        generation: u64,
        notice: hspterm_term_core::notifications::Notice,
    },
    /// Coalesced passive metadata, emitted even when no renderer is attached.
    WorkingDirectory {
        generation: u64,
        directory: Option<hspterm_term_core::WorkingDirectory>,
    },
    Terminal {
        generation: u64,
        event: Event,
    },
    /// UI-only separator, never injected into terminal text or exports.
    Reconnected {
        generation: u64,
    },
}
struct Control {
    status: SessionStatus,
    attempt: Option<CancellationToken>,
    updates: watch::Sender<SessionStatus>,
}
impl Control {
    fn publish(&mut self, phase: SessionPhase, error: Option<String>) {
        if phase != SessionPhase::Connected {
            self.status.rtt_micros = None;
        }
        self.status.phase = phase;
        self.status.error = error;
        self.updates.send_replace(self.status.clone());
    }
    fn latency(&mut self, value: Option<u64>) {
        let value = if self.status.phase == SessionPhase::Connected {
            value
        } else {
            None
        };
        if self.status.rtt_micros != value {
            self.status.rtt_micros = value;
            self.updates.send_replace(self.status.clone());
        }
    }
}
pub enum TerminalInput {
    Key(KeyEvent),
    Mouse(MouseEvent),
    Paste { text: String, confirmed: bool },
    Text(String),
    Focus(bool),
}
#[derive(Debug, PartialEq, Eq)]
pub enum InputOutcome {
    Sent,
    Confirm {
        lines: usize,
        bytes: usize,
        bracketed: bool,
    },
}
#[derive(Clone, Copy, Debug)]
pub enum IntegratedEdit {
    Replace,
    Insert,
    Execute,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IntegratedOutcome {
    Applied,
    Unconfirmed,
}
type Response = oneshot::Sender<Result<(), SshError>>;
enum Command {
    IntegratedEdit {
        generation: u64,
        proof: hspterm_term_core::integration::Proof,
        kind: IntegratedEdit,
        text: zeroize::Zeroizing<String>,
        empty: bool,
        allowed: Option<Arc<dyn Fn() -> bool + Send + Sync>>,
        reply: oneshot::Sender<Result<u64, SshError>>,
    },
    Disconnect {
        generation: u64,
        reply: Response,
    },
    OpenSftp {
        generation: u64,
        reply: oneshot::Sender<Result<russh_sftp::client::SftpSession, SshError>>,
    },
    Inspector {
        generation: u64,
        reply: oneshot::Sender<Result<crate::inspection::Inspector, SshError>>,
    },
    VerifiedPeer {
        generation: u64,
        reply: oneshot::Sender<Result<crate::HostKey, SshError>>,
    },
    DirectConnector {
        generation: u64,
        reply: oneshot::Sender<Result<crate::direct_transfer::DirectConnector, SshError>>,
    },
    AgentConnector {
        generation: u64,
        reply: oneshot::Sender<Result<crate::AgentConnector, SshError>>,
    },
    TcpConnector {
        generation: u64,
        reply: oneshot::Sender<Result<crate::TcpConnector, SshError>>,
    },
    RemoteConnector {
        generation: u64,
        reply: oneshot::Sender<Result<crate::RemoteConnector, SshError>>,
    },
    Input {
        generation: u64,
        input: TerminalInput,
        reply: oneshot::Sender<Result<InputOutcome, SshError>>,
    },
    Connect {
        config: Box<ConnectConfig>,
        auth: Option<Authentication>,
        policy: HostKeyPolicy,
        cancel: CancellationToken,
        generation: u64,
        reply: oneshot::Sender<Result<Option<ConnectionReceipt>, SshError>>,
    },
    Write {
        generation: u64,
        bytes: Vec<u8>,
        reply: Response,
    },
    Resize {
        generation: u64,
        size: Size,
        reply: Response,
    },
}

/// Native-owned encrypted-history sink. It must not call back into actor
/// commands; wait_closed includes its actual future, independent of UI streams.
pub type QualifiedCommandsSink = Arc<
    dyn Fn(
            u64,
            Vec<hspterm_term_core::integration::Submission>,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = bool> + Send>>
        + Send
        + Sync,
>;

/// Network processing continues independently of rendering. The app must drain events.
/// A single handle owns the session; dropping it cancels all network activity.
pub struct ManagedSession {
    commands: mpsc::Sender<Command>,
    control: Arc<Mutex<Control>>,
    terminal: Arc<Mutex<Terminal>>,
    frames: watch::Sender<u64>,
    integration_updates: watch::Sender<(u64, u64)>,
    stop: CancellationToken,
    task: Option<JoinHandle<()>>,
    history_sink: Arc<Mutex<Option<QualifiedCommandsSink>>>,
}
impl ManagedSession {
    /// Must be called within a Tokio runtime. The event receiver must be drained by the app.
    pub fn new(
        size: Size,
        history_lines: usize,
    ) -> Result<(Self, mpsc::Receiver<SessionEvent>), SshError> {
        let terminal = Arc::new(Mutex::new(Terminal::new(size, history_lines)?));
        let status = SessionStatus {
            generation: 0,
            phase: SessionPhase::Idle,
            error: None,
            rtt_micros: None,
        };
        let (updates, _) = watch::channel(status.clone());
        let control = Arc::new(Mutex::new(Control {
            status,
            attempt: None,
            updates,
        }));
        let (commands, receive) = mpsc::channel(32);
        let (frames, _) = watch::channel(0);
        let (integration_updates, _) = watch::channel((0, 0));
        let (events, event_receiver) = mpsc::channel(8);
        let stop = CancellationToken::new();
        let history_sink = Arc::new(Mutex::new(None));
        let task = tokio::spawn(run(
            receive,
            events,
            control.clone(),
            terminal.clone(),
            stop.clone(),
            frames.clone(),
            history_sink.clone(),
            integration_updates.clone(),
        ));
        Ok((
            Self {
                commands,
                control,
                terminal,
                frames,
                integration_updates,
                stop,
                task: Some(task),
                history_sink,
            },
            event_receiver,
        ))
    }

    pub fn set_history_sink(&self, sink: Option<QualifiedCommandsSink>) {
        *self.history_sink.lock() = sink;
    }

    pub fn status(&self) -> SessionStatus {
        self.control.lock().status.clone()
    }
    pub fn subscribe(&self) -> watch::Receiver<SessionStatus> {
        self.control.lock().updates.subscribe()
    }
    pub fn snapshot(&self) -> Result<Snapshot, SshError> {
        Ok(self.terminal.lock().try_snapshot()?)
    }
    pub fn directory_context(&self) -> (u64, Option<hspterm_term_core::WorkingDirectory>) {
        self.terminal.lock().directory_context()
    }
    pub fn integration_proof(&self) -> Option<hspterm_term_core::integration::Proof> {
        self.terminal.lock().integration_proof()
    }
    pub fn integration_status(&self) -> &'static str {
        self.terminal.lock().integration_status()
    }
    pub fn shell_context(&self) -> hspterm_term_core::ShellContext {
        self.terminal.lock().shell_context()
    }
    pub fn command_ranges(&self) -> (u64, Vec<hspterm_term_core::CommandRange>) {
        let terminal = self.terminal.lock();
        (terminal.content_revision(), terminal.command_ranges())
    }
    pub fn command_document(
        &self,
        id: u64,
    ) -> Result<
        (
            hspterm_term_core::SearchDocument,
            hspterm_term_core::CommandRange,
        ),
        SshError,
    > {
        Ok(self.terminal.lock().command_document(id)?)
    }
    pub fn command_seek(&self, id: u64) -> Result<(), SshError> {
        let mut terminal = self.terminal.lock();
        let range = terminal
            .command_ranges()
            .into_iter()
            .find(|r| r.id == id)
            .ok_or_else(|| std::io::Error::other("命令标记已失效，请手动滚动"))?;
        terminal.seek(range.prompt.unwrap_or(range.start).row as usize)?;
        self.frames.send_replace(terminal.revision());
        Ok(())
    }
    pub fn scroll(&self, delta: i32) -> Result<(), SshError> {
        let mut terminal = self.terminal.lock();
        terminal.scroll(delta)?;
        self.frames.send_replace(terminal.revision());
        Ok(())
    }
    pub fn document(&self) -> Result<hspterm_term_core::SearchDocument, SshError> {
        Ok(self.terminal.lock().document()?)
    }
    pub fn content_revision(&self) -> u64 {
        self.terminal.lock().content_revision()
    }
    pub fn history_stats(&self) -> hspterm_term_core::HistoryStats {
        self.terminal.lock().history_stats()
    }
    pub fn invalidate_view(&self) {
        let mut term = self.terminal.lock();
        term.invalidate_view();
        self.frames.send_replace(term.revision());
    }
    pub fn seek(&self, row: usize) -> Result<(), SshError> {
        let mut term = self.terminal.lock();
        term.seek(row)?;
        self.frames.send_replace(term.revision());
        Ok(())
    }
    pub fn lock_size(&self, locked: bool) {
        let mut term = self.terminal.lock();
        term.set_size_locked(locked);
        self.frames.send_replace(term.revision());
    }
    pub fn set_osc52_enabled(&self, enabled: bool) {
        self.terminal.lock().set_osc52_enabled(enabled);
    }
    pub fn apply_terminal_preferences(&self, value: &hspterm_term_core::preferences::Validated) {
        let mut term = self.terminal.lock();
        term.apply_preferences(value);
        self.frames.send_replace(term.revision());
    }
    pub fn notification_policy(&self) -> u64 {
        self.terminal.lock().notification_policy()
    }
    pub fn set_cell_pixels(&self, width: u16, height: u16) {
        self.terminal.lock().set_cell_pixels(width, height);
    }
    pub fn revision(&self) -> u64 {
        self.terminal.lock().revision()
    }
    pub fn subscribe_integration(&self) -> watch::Receiver<(u64, u64)> {
        self.integration_updates.subscribe()
    }
    pub fn integration_input(
        &self,
    ) -> Option<(
        hspterm_term_core::integration::Proof,
        zeroize::Zeroizing<String>,
    )> {
        self.terminal.lock().integration_input()
    }
    /// The actor writes one complete packet, then processes output normally.
    /// Waiting for its actual receipt happens OUTSIDE the actor to avoid a PTY
    /// read deadlock; cancellation never drops an in-progress transport write.
    pub async fn apply_integrated(
        &self,
        generation: u64,
        proof: hspterm_term_core::integration::Proof,
        kind: IntegratedEdit,
        text: zeroize::Zeroizing<String>,
        empty: bool,
        allowed: Option<Arc<dyn Fn() -> bool + Send + Sync>>,
    ) -> Result<IntegratedOutcome, SshError> {
        if self.active_generation()? != generation {
            return Err(SshError::IntegrationUnavailable);
        }
        let mut updates = self.subscribe_integration();
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::IntegratedEdit {
                generation,
                proof,
                kind,
                text,
                empty,
                allowed,
                reply,
            })
            .await
            .map_err(|_| SshError::IntegrationUnavailable)?;
        let request = response
            .await
            .map_err(|_| SshError::IntegrationUnconfirmed)??;
        let wait = async {
            loop {
                if self.status().generation != generation {
                    return IntegratedOutcome::Unconfirmed;
                }
                if let Some(ok) = self.terminal.lock().integration_outcome(request) {
                    return if ok {
                        IntegratedOutcome::Applied
                    } else {
                        IntegratedOutcome::Unconfirmed
                    };
                }
                if updates.changed().await.is_err() {
                    return IntegratedOutcome::Unconfirmed;
                }
            }
        };
        Ok(
            tokio::time::timeout(std::time::Duration::from_secs(3), wait)
                .await
                .unwrap_or(IntegratedOutcome::Unconfirmed),
        )
    }
    pub fn subscribe_frames(&self) -> watch::Receiver<u64> {
        self.frames.subscribe()
    }
    pub fn snapshot_if_changed(&self, revision: Option<u64>) -> Result<Option<Snapshot>, SshError> {
        let terminal = self.terminal.lock();
        if revision == Some(terminal.revision()) {
            Ok(None)
        } else {
            Ok(Some(terminal.try_snapshot()?))
        }
    }
    /// Round-12 frame path: probe the live grid by fingerprint first. When
    /// nothing visible changed since the delivered frame this returns only
    /// the fingerprint (no whole-screen snapshot materialized); otherwise
    /// the caller receives the snapshot together with the fingerprint it
    /// must keep for the next call. `previous` must be the fingerprint
    /// returned last time. The caller always consumes `fingerprint.revision`
    /// as its delivered revision so the pull loop goes quiet.
    pub fn frame_if_changed(
        &self,
        previous: Option<&hspterm_term_core::FrameFingerprint>,
    ) -> Result<FrameProbe, SshError> {
        let terminal = self.terminal.lock();
        let fingerprint = terminal.frame_fingerprint();
        if previous.is_some_and(|prev| *prev == fingerprint) {
            return Ok(FrameProbe {
                fingerprint,
                snapshot: None,
            });
        }
        Ok(FrameProbe {
            snapshot: Some(terminal.try_snapshot()?),
            fingerprint,
        })
    }
    pub fn shutdown(&self) {
        self.stop.cancel();
    }
    pub async fn wait_closed(&self) {
        let mut changes = self.subscribe();
        while changes.borrow_and_update().phase != SessionPhase::Closed {
            if changes.changed().await.is_err() {
                break;
            }
        }
    }
    pub async fn input(&self, input: TerminalInput) -> Result<InputOutcome, SshError> {
        let generation = self.active_generation()?;
        self.input_generation(generation, input).await
    }

    /// A deferred local action must never target a later reconnected PTY.
    pub async fn input_generation(
        &self,
        generation: u64,
        input: TerminalInput,
    ) -> Result<InputOutcome, SshError> {
        if self.active_generation()? != generation {
            return Err(SshError::Disconnected);
        }
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::Input {
                generation,
                input,
                reply,
            })
            .await
            .map_err(|_| SshError::Closed)?;
        response.await.map_err(|_| SshError::Closed)?
    }

    /// Used for both initial connect and one user-requested reconnect. Credentials
    /// are not retained for automatic attempts. Concurrent requests are rejected.
    pub async fn connect(
        &self,
        config: ConnectConfig,
        auth: Authentication,
        policy: HostKeyPolicy,
    ) -> Result<(), SshError> {
        self.begin_connection(config, Some(auth), policy)
            .await
            .map(|_| ())
    }

    /// Return this attempt's actual identity, never a subsequent status snapshot.
    pub async fn connect_verified(
        &self,
        config: ConnectConfig,
        auth: Authentication,
        policy: HostKeyPolicy,
    ) -> Result<ConnectionReceipt, SshError> {
        self.begin_connection(config, Some(auth), policy)
            .await?
            .ok_or(SshError::Disconnected)
    }

    /// Explicit TCP/proxy/SSH/host-key test only. No target authentication or
    /// channel is opened; a successful test does not make terminal input usable.
    /// Dropping the caller cancels this exact test, including confirmation wait.
    pub async fn test_connection(
        &self,
        config: ConnectConfig,
        policy: HostKeyPolicy,
    ) -> Result<(), SshError> {
        self.begin_connection(config, None, policy)
            .await
            .map(|_| ())
    }

    async fn begin_connection(
        &self,
        config: ConnectConfig,
        auth: Option<Authentication>,
        policy: HostKeyPolicy,
    ) -> Result<Option<ConnectionReceipt>, SshError> {
        config.validate()?;
        let permit = self
            .commands
            .reserve()
            .await
            .map_err(|_| SshError::Closed)?;
        let (reply, response) = oneshot::channel();
        let (command, _probe_guard) = {
            let mut control = self.control.lock();
            match control.status.phase {
                SessionPhase::Connecting | SessionPhase::Connected => return Err(SshError::Busy),
                SessionPhase::Closed => return Err(SshError::Closed),
                SessionPhase::Idle | SessionPhase::Disconnected | SessionPhase::Failed => {}
            }
            control.status.generation += 1;
            let cancel = self.stop.child_token();
            let guard = auth.is_none().then(|| cancel.clone().drop_guard());
            control.attempt = Some(cancel.clone());
            control.publish(SessionPhase::Connecting, None);
            (
                Command::Connect {
                    config: Box::new(config),
                    auth,
                    policy,
                    cancel,
                    generation: control.status.generation,
                    reply,
                },
                guard,
            )
        };
        permit.send(command);
        response.await.map_err(|_| SshError::Closed)?
    }

    /// Explicitly disconnect a transport while retaining terminal/history state.
    pub async fn disconnect(&self) -> Result<(), SshError> {
        let generation = self.active_generation()?;
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::Disconnect { generation, reply })
            .await
            .map_err(|_| SshError::Closed)?;
        response.await.map_err(|_| SshError::Closed)?
    }
    pub async fn open_sftp(&self) -> Result<russh_sftp::client::SftpSession, SshError> {
        let generation = self.active_generation()?;
        self.open_sftp_generation(generation).await
    }
    async fn open_sftp_generation(
        &self,
        generation: u64,
    ) -> Result<russh_sftp::client::SftpSession, SshError> {
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::OpenSftp { generation, reply })
            .await
            .map_err(|_| SshError::Closed)?;
        response.await.map_err(|_| SshError::Closed)?
    }

    /// At most two channel-only retries on the captured original generation.
    /// This never creates/authenticates a new SSH Transport or follows a user
    /// reconnect. Only typed transient SFTP/negotiation timeouts qualify.
    pub async fn open_sftp_with_retry(
        &self,
        generation: u64,
        stop: &CancellationToken,
    ) -> Result<russh_sftp::client::SftpSession, SshError> {
        for attempt in 0..3 {
            if stop.is_cancelled() {
                return Err(SshError::Cancelled);
            }
            if self.active_generation()? != generation {
                return Err(SshError::Disconnected);
            }
            let result = tokio::select! {
                biased;
                _ = stop.cancelled() => return Err(SshError::Cancelled),
                result = self.open_sftp_generation(generation) => result,
            };
            match result {
                Ok(session) => {
                    if self.active_generation().ok() == Some(generation) && !stop.is_cancelled() {
                        return Ok(session);
                    }
                    session.close().await?;
                    return Err(SshError::Cancelled);
                }
                Err(error) => {
                    let transient = matches!(
                        &error,
                        SshError::Timeout(crate::Stage::Sftp)
                            | SshError::Sftp(
                                crate::SftpError::Timeout | crate::SftpError::ConnectionClosed
                            )
                    );
                    if attempt == 2 || !transient {
                        return Err(error);
                    }
                    tokio::select! {
                        biased;
                        _ = stop.cancelled() => return Err(SshError::Cancelled),
                        _ = tokio::time::sleep(std::time::Duration::from_millis(if attempt == 0 { 150 } else { 400 })) => {},
                    }
                }
            }
        }
        Err(SshError::Disconnected)
    }

    /// Acquires only the original transport capability; channel negotiation is
    /// performed by the caller, so a slow forward cannot block the PTY actor.
    pub async fn tcp_connector(&self) -> Result<crate::TcpConnector, SshError> {
        let generation = self.active_generation()?;
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::TcpConnector { generation, reply })
            .await
            .map_err(|_| SshError::Closed)?;
        response.await.map_err(|_| SshError::Closed)?
    }

    pub async fn remote_connector(&self) -> Result<crate::RemoteConnector, SshError> {
        let generation = self.active_generation()?;
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::RemoteConnector { generation, reply })
            .await
            .map_err(|_| SshError::Closed)?;
        response.await.map_err(|_| SshError::Closed)?
    }

    pub async fn inspector(&self) -> Result<crate::inspection::Inspector, SshError> {
        self.inspector_for(self.active_generation()?).await
    }
    pub async fn inspector_for(
        &self,
        generation: u64,
    ) -> Result<crate::inspection::Inspector, SshError> {
        if self.active_generation()? != generation {
            return Err(SshError::Disconnected);
        }
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::Inspector { generation, reply })
            .await
            .map_err(|_| SshError::Closed)?;
        response.await.map_err(|_| SshError::Closed)?
    }

    pub async fn verified_peer(&self, generation: u64) -> Result<crate::HostKey, SshError> {
        if self.active_generation()? != generation {
            return Err(SshError::Disconnected);
        }
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::VerifiedPeer { generation, reply })
            .await
            .map_err(|_| SshError::Closed)?;
        response.await.map_err(|_| SshError::Closed)?
    }
    pub async fn direct_connector(
        &self,
        generation: u64,
    ) -> Result<crate::direct_transfer::DirectConnector, SshError> {
        if self.active_generation()? != generation {
            return Err(SshError::Disconnected);
        }
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::DirectConnector { generation, reply })
            .await
            .map_err(|_| SshError::Closed)?;
        response.await.map_err(|_| SshError::Closed)?
    }

    pub async fn agent_connector(&self) -> Result<crate::AgentConnector, SshError> {
        let generation = self.active_generation()?;
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::AgentConnector { generation, reply })
            .await
            .map_err(|_| SshError::Closed)?;
        response.await.map_err(|_| SshError::Closed)?
    }

    pub fn cancel_connect(&self) {
        let control = self.control.lock();
        if control.status.phase == SessionPhase::Connecting
            && let Some(token) = &control.attempt
        {
            token.cancel();
        }
    }
    fn active_generation(&self) -> Result<u64, SshError> {
        let control = self.control.lock();
        if control.status.phase == SessionPhase::Connected {
            Ok(control.status.generation)
        } else if control.status.phase == SessionPhase::Closed {
            Err(SshError::Closed)
        } else {
            Err(SshError::Disconnected)
        }
    }
    pub async fn write(&self, bytes: Vec<u8>) -> Result<(), SshError> {
        let generation = self.active_generation()?;
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::Write {
                generation,
                bytes,
                reply,
            })
            .await
            .map_err(|_| SshError::Closed)?;
        response.await.map_err(|_| SshError::Closed)?
    }
    pub async fn resize(&self, size: Size) -> Result<(), SshError> {
        let size = Size::new(size.columns, size.rows)?;
        if self.status().phase != SessionPhase::Connected {
            let mut terminal = self.terminal.lock();
            terminal.resize(size)?;
            self.frames.send_replace(terminal.revision());
            return Ok(());
        }
        let generation = self.active_generation()?;
        let (reply, response) = oneshot::channel();
        self.commands
            .send(Command::Resize {
                generation,
                size,
                reply,
            })
            .await
            .map_err(|_| SshError::Closed)?;
        response.await.map_err(|_| SshError::Closed)?
    }
    pub async fn close(&mut self) -> Result<(), SshError> {
        self.stop.cancel();
        if let Some(task) = self.task.take() {
            task.await.map_err(|_| SshError::Closed)?;
        }
        Ok(())
    }
}
impl Drop for ManagedSession {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

enum Action {
    Stop,
    Command(Option<Command>),
    Output(Result<PtyEvent, SshError>),
    Tick,
    Latency(Result<Option<u64>, watch::error::RecvError>),
}
#[allow(
    clippy::too_many_arguments,
    reason = "The single actor explicitly owns its input, output watches and lifecycle roots."
)]
async fn run(
    mut commands: mpsc::Receiver<Command>,
    events: mpsc::Sender<SessionEvent>,
    control: Arc<Mutex<Control>>,
    terminal: Arc<Mutex<Terminal>>,
    stop: CancellationToken,
    frames: watch::Sender<u64>,
    history_sink: Arc<Mutex<Option<QualifiedCommandsSink>>>,
    integration_updates: watch::Sender<(u64, u64)>,
) {
    let mut connection: Option<SshConnection> = None;
    let mut latency: Option<watch::Receiver<Option<u64>>> = None;
    let mut had_connection = false;
    let mut directory_revision = 0;
    loop {
        if connection.is_none() {
            latency = None;
        }
        let sync_deadline = {
            let t = terminal.lock();
            [
                t.sync_deadline(),
                t.notification_deadline(),
                t.integration_deadline(),
            ]
            .into_iter()
            .flatten()
            .min()
        };
        let action = tokio::select! {
            _ = stop.cancelled() => Action::Stop,
            command = commands.recv() => Action::Command(command),
            output = async { match connection.as_mut() {
                Some(conn) => conn.read().await, None => std::future::pending().await,
            }} => Action::Output(output),
            sample = async { match latency.as_mut() {
                Some(receiver) => { receiver.changed().await?; Ok(*receiver.borrow_and_update()) },
                None => std::future::pending::<Result<Option<u64>, watch::error::RecvError>>().await,
            }} => Action::Latency(sample),
            // A missing end-synchronized-output marker must flush even without more bytes.
            _ = async { if let Some(deadline) = sync_deadline {
                tokio::time::sleep_until(deadline.into()).await;
            } else { std::future::pending::<()>().await; } } => Action::Tick,
        };
        match action {
            Action::Stop | Action::Command(None) => break,
            Action::Command(Some(Command::Connect {
                config,
                auth,
                policy,
                cancel,
                generation,
                reply,
            })) => {
                let config = *config;
                let Some(auth) = auth else {
                    let result = SshConnection::test_connection(config, policy, cancel).await;
                    {
                        let mut c = control.lock();
                        c.attempt = None;
                        match &result {
                            Ok(()) => c.publish(
                                if had_connection {
                                    SessionPhase::Disconnected
                                } else {
                                    SessionPhase::Idle
                                },
                                None,
                            ),
                            Err(error) => c.publish(SessionPhase::Failed, Some(error.to_string())),
                        }
                    }
                    drop(reply.send(result.map(|_| None)));
                    // A handshake-only test has no terminal stream and must not
                    // resize, reset or add a reconnect separator to old history.
                    continue;
                };
                let username = config.username.clone();
                let size = Size::new(config.columns, config.rows);
                let result = match size {
                    Ok(size) => match SshConnection::connect(config, auth, policy, cancel).await {
                        Ok(mut conn) => {
                            let receipt = ConnectionReceipt {
                                generation,
                                host_key: conn.verified_host_key().clone(),
                                username,
                                tmux: conn.tmux_state(),
                                tmux_session: conn.tmux_session().cloned(),
                            };
                            let resized = {
                                let mut term = terminal.lock();
                                if had_connection {
                                    term.begin_new_generation();
                                }
                                // An explicit tmux choice owns the initial lock
                                // for this new PTY; ordinary Shell preserves the
                                // existing user size-lock behavior.
                                if receipt.tmux.is_some() {
                                    term.set_size_locked(false);
                                }
                                let result = term.resize(size);
                                term.configure_integration(conn.integration_nonce().and_then(
                                    |nonce| {
                                        hspterm_term_core::integration::Nonce::parse(
                                            nonce.to_owned(),
                                        )
                                    },
                                ));
                                if let Some(state) = receipt.tmux {
                                    term.set_size_locked(state.size_locked);
                                }
                                result
                            };
                            if let Err(error) = resized {
                                // Even a terminal allocation/history error must
                                // await this newly authenticated Root's owners.
                                let closed = conn.close().await;
                                let detail = match closed {
                                    Ok(()) => error.to_string(),
                                    Err(close) => format!("{error}；SSH收尾失败：{close}"),
                                };
                                let mut c = control.lock();
                                c.attempt = None;
                                c.publish(SessionPhase::Failed, Some(detail));
                                drop(reply.send(Err(error.into())));
                                continue;
                            }
                            latency = Some(conn.subscribe_latency());
                            connection = Some(conn);
                            if had_connection {
                                let event = SessionEvent::Reconnected { generation };
                                if !send_event(&events, &stop, event).await {
                                    break;
                                }
                            }
                            had_connection = true;
                            Ok(Some(receipt))
                        }
                        Err(error) => Err(error),
                    },
                    Err(error) => Err(error.into()),
                };
                {
                    let mut c = control.lock();
                    c.attempt = None;
                    match &result {
                        Ok(_) => {
                            c.publish(SessionPhase::Connected, None);
                            c.latency(latency.as_ref().and_then(|r| *r.borrow()));
                        }
                        Err(error) => c.publish(SessionPhase::Failed, Some(error.to_string())),
                    }
                }
                drop(reply.send(result)); // The caller may legitimately stop awaiting a result.
            }
            Action::Command(Some(command)) => {
                let generation = control.lock().status.generation;
                match command {
                    Command::Disconnect {
                        generation: expected,
                        reply,
                    } => {
                        if expected != generation || connection.is_none() {
                            drop(reply.send(Err(SshError::Disconnected)));
                            continue;
                        }
                        terminal.lock().finish_stream();
                        let result = retire_connection(&mut connection).await;
                        control.lock().publish(
                            SessionPhase::Disconnected,
                            result.as_ref().err().map(ToString::to_string),
                        );
                        drop(reply.send(result));
                    }
                    Command::OpenSftp {
                        generation: expected,
                        reply,
                    } => {
                        if let Some(conn) = connection.as_ref().filter(|_| expected == generation) {
                            let open = conn.sftp_opener();
                            // Never wait for SFTP negotiation inside the PTY actor.
                            tokio::spawn(negotiate_sftp(reply, open));
                        } else {
                            drop(reply.send(Err(SshError::Disconnected)));
                        }
                    }
                    Command::Inspector {
                        generation: expected,
                        reply,
                    } => {
                        let result = connection
                            .as_ref()
                            .filter(|_| expected == generation)
                            .ok_or(SshError::Disconnected)
                            .and_then(SshConnection::inspector);
                        drop(reply.send(result));
                    }
                    Command::VerifiedPeer {
                        generation: expected,
                        reply,
                    } => {
                        let result = connection
                            .as_ref()
                            .filter(|_| expected == generation)
                            .ok_or(SshError::Disconnected)
                            .map(|c| c.verified_host_key().clone());
                        drop(reply.send(result));
                    }
                    Command::DirectConnector {
                        generation: expected,
                        reply,
                    } => {
                        let result = connection
                            .as_ref()
                            .filter(|_| expected == generation)
                            .ok_or(SshError::Disconnected)
                            .map(SshConnection::direct_connector);
                        drop(reply.send(result));
                    }
                    Command::AgentConnector {
                        generation: expected,
                        reply,
                    } => {
                        let result = connection
                            .as_ref()
                            .filter(|_| expected == generation)
                            .ok_or(SshError::Disconnected)
                            .map(SshConnection::agent_connector);
                        drop(reply.send(result));
                    }
                    Command::TcpConnector {
                        generation: expected,
                        reply,
                    } => {
                        let result = connection
                            .as_ref()
                            .filter(|_| expected == generation)
                            .ok_or(SshError::Disconnected)
                            .and_then(SshConnection::tcp_connector);
                        drop(reply.send(result));
                    }
                    Command::RemoteConnector {
                        generation: expected,
                        reply,
                    } => {
                        let result = connection
                            .as_ref()
                            .filter(|_| expected == generation)
                            .ok_or(SshError::Disconnected)
                            .and_then(SshConnection::remote_connector);
                        drop(reply.send(result));
                    }
                    Command::IntegratedEdit {
                        generation: expected,
                        proof,
                        kind,
                        text,
                        empty,
                        allowed,
                        reply,
                    } => {
                        if reply.is_closed() {
                            continue;
                        }
                        let phase = control.lock().status.phase;
                        if expected != generation
                            || connection.is_none()
                            || phase != SessionPhase::Connected
                            || allowed.as_ref().is_some_and(|permit| !permit())
                        {
                            drop(reply.send(Err(SshError::IntegrationUnavailable)));
                            continue;
                        }
                        let plan = {
                            use hspterm_term_core::integration::Edit;
                            let edit = match kind {
                                IntegratedEdit::Replace => Edit::Replace(&text),
                                IntegratedEdit::Insert => Edit::Insert(&text),
                                IntegratedEdit::Execute => Edit::Execute(&text),
                            };
                            terminal.lock().plan_integration(proof, edit, empty)
                        };
                        match plan {
                            Err(_) => {
                                drop(reply.send(Err(SshError::IntegrationUnavailable)));
                            }
                            Ok(plan) => {
                                let result = connection.as_ref().unwrap().write(&plan.bytes).await;
                                if result.is_err() {
                                    terminal.lock().invalidate_integration();
                                }
                                drop(
                                    reply.send(
                                        result
                                            .map(|_| plan.request)
                                            .map_err(|_| SshError::IntegrationUnconfirmed),
                                    ),
                                );
                            }
                        }
                    }
                    Command::Input {
                        generation: expected,
                        input,
                        reply,
                    } => {
                        if expected != generation || connection.is_none() {
                            drop(reply.send(Err(SshError::Disconnected)));
                            continue;
                        }
                        let encoded = {
                            let terminal = terminal.lock();
                            match input {
                                TerminalInput::Key(event) => {
                                    terminal.encode_key(&event).map(|bytes| {
                                        terminal.observe_integration_key(&event, &bytes);
                                        PastePlan::Ready(bytes)
                                    })
                                }
                                TerminalInput::Mouse(event) => {
                                    Ok(PastePlan::Ready(terminal.encode_mouse(event)))
                                }
                                TerminalInput::Paste { text, confirmed } => {
                                    terminal.invalidate_integration();
                                    terminal.prepare_paste(&text, confirmed)
                                }
                                TerminalInput::Text(text) => {
                                    terminal.encode_text(&text).map(|bytes| {
                                        terminal.observe_integration_text(&bytes);
                                        PastePlan::Ready(bytes)
                                    })
                                }
                                TerminalInput::Focus(focus) => {
                                    Ok(PastePlan::Ready(terminal.focus_bytes(focus)))
                                }
                            }
                        };
                        let result = match encoded {
                            Ok(PastePlan::Confirm {
                                lines,
                                bytes,
                                bracketed,
                            }) => Ok(InputOutcome::Confirm {
                                lines,
                                bytes,
                                bracketed,
                            }),
                            Ok(PastePlan::Ready(bytes)) => match connection.as_ref() {
                                Some(conn) => conn.write(&bytes).await.map(|_| InputOutcome::Sent),
                                None => Err(SshError::Disconnected),
                            },
                            Err(error) => Err(error.into()),
                        };
                        if result.is_err() {
                            terminal.lock().invalidate_integration();
                        }
                        drop(reply.send(result));
                    }
                    Command::Write {
                        generation: expected,
                        bytes,
                        reply,
                    } => {
                        if expected == generation {
                            terminal.lock().invalidate_integration();
                        }
                        let result = match connection.as_ref() {
                            Some(conn) if expected == generation => conn.write(&bytes).await,
                            _ => Err(SshError::Disconnected),
                        };
                        if expected == generation
                            && let Err(error) = &result
                        {
                            let cleanup_error = retire_connection(&mut connection).await.err();
                            if let Some(error) = cleanup_error {
                                control
                                    .lock()
                                    .publish(SessionPhase::Disconnected, Some(error.to_string()));
                            }
                            control
                                .lock()
                                .publish(SessionPhase::Disconnected, Some(error.to_string()));
                        }
                        drop(reply.send(result));
                    }
                    Command::Resize {
                        generation: expected,
                        size,
                        reply,
                    } => {
                        if terminal.lock().size_locked() {
                            drop(reply.send(Ok(())));
                            continue;
                        }

                        let result = match connection.as_ref() {
                            Some(conn) if expected == generation => {
                                match conn.resize(size.columns, size.rows).await {
                                    Ok(()) => terminal.lock().resize(size).map_err(SshError::from),
                                    Err(error) => Err(error),
                                }
                            }
                            _ => Err(SshError::Disconnected),
                        };
                        drop(reply.send(result));
                    }
                    Command::Connect { .. } => unreachable!("connect handled above"),
                }
            }
            Action::Output(Ok(PtyEvent::Data(bytes))) => {
                let result = terminal.lock().feed(&bytes);
                if let Err(error) = result {
                    let cleanup_error = retire_connection(&mut connection).await.err();
                    if let Some(error) = cleanup_error {
                        control
                            .lock()
                            .publish(SessionPhase::Disconnected, Some(error.to_string()));
                    }
                    control
                        .lock()
                        .publish(SessionPhase::Disconnected, Some(error.to_string()));
                }
            }
            Action::Output(Ok(PtyEvent::ExitStatus(_))) => {}
            Action::Output(Ok(PtyEvent::End)) | Action::Output(Err(_)) => {
                let mut error = match action {
                    Action::Output(Err(error)) => Some(error.to_string()),
                    _ => None,
                };
                if error.is_none()
                    && let Some(conn) = connection.as_mut()
                {
                    let size = terminal.lock().size();
                    match conn
                        .restore_shell(size.columns, size.rows, stop.child_token())
                        .await
                    {
                        Ok(true) => {
                            {
                                let mut term = terminal.lock();
                                term.begin_new_generation();
                                term.set_size_locked(false);
                                term.configure_integration(conn.integration_nonce().and_then(
                                    |n| hspterm_term_core::integration::Nonce::parse(n.to_owned()),
                                ));
                            }
                            let generation = control.lock().status.generation;
                            if !send_event(
                                &events,
                                &stop,
                                SessionEvent::ShellRestored { generation },
                            )
                            .await
                            {
                                break;
                            }
                            frames.send_replace(terminal.lock().revision());
                            integration_updates
                                .send_replace((generation, terminal.lock().integration_revision()));
                            continue;
                        }
                        Ok(false) => {}
                        Err(failure) => error = Some(failure.to_string()),
                    }
                }
                terminal.lock().finish_stream();
                let cleanup_error = retire_connection(&mut connection)
                    .await
                    .err()
                    .map(|e| e.to_string());
                control
                    .lock()
                    .publish(SessionPhase::Disconnected, error.or(cleanup_error));
            }
            Action::Tick => {
                terminal.lock().expire_integration(Instant::now());
                terminal.lock().flush_expired_sync(Instant::now());
            }
            Action::Latency(sample) => {
                match sample {
                    Ok(value) => control.lock().latency(value),
                    Err(_) => {
                        latency = None;
                        control.lock().latency(None);
                    }
                }
                // Telemetry does not checkpoint history, fetch grids or emit a
                // terminal frame. Only the independent status watch changed.
                continue;
            }
        }
        let history_result = terminal.lock().maintain_history();
        if let Err(error) = history_result {
            let cleanup_error = retire_connection(&mut connection).await.err();
            if let Some(error) = cleanup_error {
                control
                    .lock()
                    .publish(SessionPhase::Disconnected, Some(error.to_string()));
            }
            control
                .lock()
                .publish(SessionPhase::Disconnected, Some(error.to_string()));
        }
        let revision = terminal.lock().revision();
        if *frames.borrow() != revision {
            frames.send_replace(revision);
        }
        let generation = control.lock().status.generation;
        let stamp = (generation, terminal.lock().integration_revision());
        if *integration_updates.borrow() != stamp {
            integration_updates.send_replace(stamp);
        }
        let submissions = terminal.lock().take_integration_submissions();
        if !submissions.is_empty() {
            let sink = history_sink.lock().clone();
            if let Some(sink) = sink
                && !sink(generation, submissions).await
                && !send_event(&events, &stop, SessionEvent::HistoryWarning { generation }).await
            {
                stop.cancel();
                break;
            }
        }
        let notices = {
            let mut t = terminal.lock();
            t.flush_notifications(Instant::now());
            t.take_notifications()
        };
        for notice in notices {
            if !send_event(
                &events,
                &stop,
                SessionEvent::Notification { generation, notice },
            )
            .await
            {
                stop.cancel();
                break;
            }
        }
        if terminal.lock().directory_revision() != directory_revision {
            let (revision, directory) = terminal.lock().directory_context();
            directory_revision = revision;
            if !send_event(
                &events,
                &stop,
                SessionEvent::WorkingDirectory {
                    generation,
                    directory,
                },
            )
            .await
            {
                stop.cancel();
                break;
            }
        }
        let output_events = terminal.lock().take_events();
        for event in output_events {
            let protocol_reply = terminal.lock().protocol_reply(&event);
            if let Some(reply) = protocol_reply {
                if let Some(conn) = connection.as_ref()
                    && let Err(error) = conn.write(reply.as_bytes()).await
                {
                    terminal.lock().finish_stream();
                    let cleanup_error = retire_connection(&mut connection).await.err();
                    if let Some(error) = cleanup_error {
                        control
                            .lock()
                            .publish(SessionPhase::Disconnected, Some(error.to_string()));
                    }
                    control
                        .lock()
                        .publish(SessionPhase::Disconnected, Some(error.to_string()));
                    break;
                }
            } else if !send_event(&events, &stop, SessionEvent::Terminal { generation, event })
                .await
            {
                stop.cancel();
                break;
            }
        }
    }
    let error = retire_connection(&mut connection)
        .await
        .err()
        .map(|e| e.to_string());
    control.lock().publish(SessionPhase::Closed, error);
}
async fn retire_connection(connection: &mut Option<SshConnection>) -> Result<(), SshError> {
    if let Some(mut connection) = connection.take() {
        connection.close().await
    } else {
        Ok(())
    }
}
async fn send_event(
    events: &mpsc::Sender<SessionEvent>,
    stop: &CancellationToken,
    event: SessionEvent,
) -> bool {
    tokio::select! { biased; _ = stop.cancelled() => false, r = events.send(event) => r.is_ok() }
}

// Opening a channel is cancellable resource acquisition. Dropping the caller's
// reply receiver must not leave negotiation running until its 30s timeout.
async fn negotiate_sftp(
    mut reply: oneshot::Sender<Result<russh_sftp::client::SftpSession, SshError>>,
    open: impl std::future::Future<Output = Result<russh_sftp::client::SftpSession, SshError>>,
) {
    tokio::select! { biased;
        _ = reply.closed() => {},
        result = open => { drop(reply.send(result)); },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    #[tokio::test]
    async fn cancelled_sftp_receiver_drops_negotiation_and_never_polls_queued_opening() {
        use tokio::{
            sync::Notify,
            time::{Duration, timeout},
        };
        struct Probe(Arc<AtomicBool>);
        impl Drop for Probe {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        let started = Arc::new(Notify::new());
        let dropped = Arc::new(AtomicBool::new(false));
        let (reply, response) = oneshot::channel();
        let open = {
            let started = started.clone();
            let dropped = dropped.clone();
            async move {
                let _probe = Probe(dropped);
                started.notify_one();
                std::future::pending::<Result<russh_sftp::client::SftpSession, SshError>>().await
            }
        };
        let task = tokio::spawn(negotiate_sftp(reply, open));
        timeout(Duration::from_secs(1), started.notified())
            .await
            .unwrap();
        drop(response);
        timeout(Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap();
        assert!(dropped.load(Ordering::SeqCst));
        let polled = Arc::new(AtomicBool::new(false));
        let (reply, response) = oneshot::channel();
        drop(response);
        let flag = polled.clone();
        negotiate_sftp(reply, async move {
            flag.store(true, Ordering::SeqCst);
            Err(SshError::Disconnected)
        })
        .await;
        assert!(!polled.load(Ordering::SeqCst));
    }
}

#[cfg(test)]
mod latency_state_tests {
    use super::*;
    #[test]
    fn samples_are_only_for_the_current_connected_generation_and_duplicate_samples_do_not_notify() {
        let status = SessionStatus {
            generation: 1,
            phase: SessionPhase::Connected,
            error: None,
            rtt_micros: None,
        };
        let (updates, mut receiver) = watch::channel(status.clone());
        let mut control = Control {
            status,
            attempt: None,
            updates,
        };
        control.latency(Some(900));
        assert_eq!(control.status.rtt_micros, Some(900));
        drop(receiver.borrow_and_update());
        control.latency(Some(900));
        assert!(!receiver.has_changed().unwrap());
        control.publish(SessionPhase::Disconnected, None);
        assert_eq!(control.status.rtt_micros, None);
        control.latency(Some(700));
        assert_eq!(control.status.rtt_micros, None);
        control.status.generation = 2;
        control.publish(SessionPhase::Connecting, None);
        control.publish(SessionPhase::Connected, None);
        assert_eq!(control.status.rtt_micros, None);
    }
}

#[cfg(test)]
mod integration_sink_tests {
    use super::*;
    #[tokio::test]
    async fn shutdown_awaits_the_original_history_sink_without_a_renderer() {
        let (session, _events) = ManagedSession::new(Size::new(40, 5).unwrap(), 0).unwrap();
        let entered = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(tokio::sync::Notify::new());
        let (started, pending) = (entered.clone(), release.clone());
        session.set_history_sink(Some(Arc::new(move |_, commands| {
            let (started, pending) = (started.clone(), pending.clone());
            Box::pin(async move {
                assert_eq!(commands.len(), 1);
                started.notify_one();
                pending.notified().await;
                true
            })
        })));
        {
            // Synthetic owner-lifetime fixture, not an SSH or secret classifier
            // test. The true protocol path is covered separately via Terminal.
            let mut terminal = session.terminal.lock();
            terminal.configure_integration(hspterm_term_core::integration::Nonce::parse(
                "a".repeat(64),
            ));
            terminal
                .feed(format!("\x1b]777;hspterm;HSP1;{};1;R;0;0;\x1b\\", "a".repeat(64)).as_bytes())
                .unwrap();
            terminal.observe_integration_text(b"pwd");
            terminal
                .observe_integration_key(&KeyEvent::press(hspterm_term_core::Key::Enter), b"\r");
            terminal
                .feed(
                    format!(
                        "\x1b]777;hspterm;HSP1;{};1;S;0;3;707764\x1b\\",
                        "a".repeat(64)
                    )
                    .as_bytes(),
                )
                .unwrap();
        }
        // Wake the actor without a Transport or a renderer. The empty raw
        // write is refused normally but lets its owned post-batch sink drain.
        let (reply, _response) = oneshot::channel();
        assert!(
            session
                .commands
                .send(Command::Write {
                    generation: 0,
                    bytes: Vec::new(),
                    reply,
                })
                .await
                .is_ok()
        );
        tokio::time::timeout(std::time::Duration::from_secs(2), entered.notified())
            .await
            .unwrap();
        session.shutdown();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), session.wait_closed())
                .await
                .is_err()
        );
        release.notify_one();
        tokio::time::timeout(std::time::Duration::from_secs(2), session.wait_closed())
            .await
            .unwrap();
    }
}
