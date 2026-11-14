//! SSH transport and remote PTY. No automatic transport reconnection or local shell.
pub use russh_sftp::{
    client::{SftpSession, error::Error as SftpError},
    protocol::{OpenFlags as SftpOpenFlags, StatusCode as SftpStatusCode},
};
pub mod agent_forward;
mod agent_protocol;
mod agent_signer;
pub mod direct_transfer;
pub use agent_forward::{AgentConnector, AgentPhase, AgentStatus};
mod budget;
mod heartbeat;
mod jump;
mod local_path;
pub mod remote_forward;
pub use jump::JumpHost;
pub use remote_forward::{RemoteConnector, RemoteForward};
mod proxy;
pub use proxy::{ProxyConfig, ProxyCredentials, ProxyError, ProxyKind};
mod session;
mod sftp_connector;
pub use session::{
    ConnectionReceipt, InputOutcome, IntegratedEdit, IntegratedOutcome, ManagedSession,
    QualifiedCommandsSink, SessionEvent, SessionPhase, SessionStatus, TerminalInput,
};
pub mod bandwidth;
pub mod directory;
pub mod edit;
pub mod explorer_manifest;
pub mod forwarding;
pub mod identity;
pub mod inspection;
pub mod integration;
pub mod remote_tree;
pub mod search;
pub mod task_scheduler;
mod tcp_channel;
pub mod tmux;
pub mod transfer;
mod transport;
pub use tcp_channel::{TcpChannel, TcpConnector};
pub mod tree_transfer;

use budget::Budget;
use russh::{
    Channel, ChannelMsg, client,
    keys::{HashAlg, PrivateKeyWithHashAlg, PublicKeyOrCertificate},
};
use std::{collections::VecDeque, fmt, sync::Arc, time::Duration};
use thiserror::Error;
use tokio::{
    io::{AsyncRead, AsyncWrite},
    net::TcpStream,
    sync::{mpsc, oneshot, watch},
};
use tokio_util::sync::CancellationToken;
use transport::{CancelStream, Lifetime};
use zeroize::Zeroizing;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Tcp,
    Proxy,
    JumpHandshake,
    JumpAuthentication,
    JumpChannel,
    Handshake,
    Authentication,
    Pty,
    Shell,
    Tmux,
    Agent,
    Sftp,
    Forward,
}

#[derive(Error)]
pub enum SshError {
    #[error(transparent)]
    DirectPreparation(#[from] direct_transfer::DirectPreparationError),
    #[error(transparent)]
    Inspection(#[from] inspection::InspectionError),
    #[error(transparent)]
    Tmux(#[from] tmux::TmuxError),
    #[error("SSH心跳等待响应超时，已关闭原连接；请手动重新连接")]
    HeartbeatTimeout,
    #[error("SSH心跳任务异常退出")]
    HeartbeatWorker,
    #[error("连接已取消")]
    Cancelled,
    #[error("连接阶段超时：{0:?}")]
    Timeout(Stage),
    #[error("远端连接已断开")]
    Disconnected,
    #[error("主机密钥已变化，连接已阻止")]
    HostKeyChanged { expected: String, received: String },
    #[error("未确认主机密钥，连接已取消")]
    HostKeyRejected,
    #[error("认证失败，请检查所选认证方式及凭据")]
    Authentication,
    #[error("RSA 私钥或签名算法不受支持；需要 2048–4096 位密钥及 SHA-2")]
    RsaUnsupported,
    #[error("无法解析私钥或私钥口令错误")]
    PrivateKey,
    #[error("远端拒绝了请求：{0:?}")]
    RequestDenied(Stage),
    #[error("普通Shell输入证明已失效；未发送受控输入")]
    IntegrationUnavailable,
    #[error("受控输入结果未确认；请检查终端，不要重复提交")]
    IntegrationUnconfirmed,
    #[error("当前会话正在连接或已连接")]
    Busy,
    #[error("会话已关闭")]
    Closed,
    #[error("本会话的SFTP开通或活动通道已达安全上限，请等待原操作结束")]
    SftpCapacity,
    #[error("Agent 授权不可用或已失效")]
    AgentUnavailable,
    #[error("Agent 工作任务异常退出，已撤销授权")]
    AgentWorker,
    #[error("转发处理任务异常退出")]
    ForwardWorker,
    #[error(transparent)]
    Socks5(#[from] forwarding::Socks5Error),
    #[error(transparent)]
    Input(#[from] hspterm_term_core::InputError),
    #[error("终端尺寸无效")]
    Terminal(#[from] hspterm_term_core::TerminalError),
    #[error("连接参数无效")]
    InvalidConfig,
    #[error("网络连接失败")]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Proxy(#[from] ProxyError),
    #[error("跳板机连接失败：{0}")]
    Jump(#[source] Box<SshError>),
    #[error("SSH 协议操作失败")]
    Protocol(#[from] russh::Error),
    #[error("SFTP 操作失败")]
    Sftp(#[from] russh_sftp::client::error::Error),
}
// Do not leak server-provided error text, paths or authentication material in Debug.
impl fmt::Debug for SshError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

/// Authentication is exactly one selected method; no implicit fallback.
#[derive(Clone)]
pub enum Authentication {
    Password(Zeroizing<String>),
    PrivateKey {
        openssh: Zeroizing<String>,
        passphrase: Option<Zeroizing<String>>,
    },
}
impl fmt::Debug for Authentication {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Password(_) => "Password([REDACTED])",
            Self::PrivateKey { .. } => "PrivateKey([REDACTED])",
        })
    }
}

/// Validate imported material on a blocking worker before saving a formal host.
/// Parsing failures deliberately omit key contents and upstream diagnostics.
pub fn validate_private_key(openssh: &str, passphrase: Option<&str>) -> Result<(), SshError> {
    let key =
        russh::keys::decode_secret_key(openssh, passphrase).map_err(|_| SshError::PrivateKey)?;
    if let russh::keys::ssh_key::private::KeypairData::Rsa(key) = key.key_data() {
        russh::keys::RingRsaSigner::new(key).map_err(|_| SshError::RsaUnsupported)?;
    }
    Ok(())
}

#[derive(Clone)]
pub struct ConnectConfig {
    pub address: String,
    pub port: u16,
    pub username: String,
    pub columns: u16,
    pub rows: u16,
    pub timeout: Duration,
    pub keepalive_interval: Option<Duration>,
    pub keepalive_failures: usize,
    /// None retains the legacy idle/traffic-based policy for existing callers.
    pub keepalive_response_timeout: Option<Duration>,
    pub proxy: Option<ProxyConfig>,
    pub jump: Option<JumpHost>,
    /// Request a remote Agent socket before shell startup. Grants always require
    /// a separate explicit, per-connection, time-limited authorization.
    pub agent_forwarding: bool,
    /// Explicit discovery/selection after authentication, before starting any PTY program.
    pub tmux: Option<tmux::Policy>,
    /// Fixed optional Bash integration, only on an explicitly enabled host.
    pub integration: Option<integration::Launch>,
}
impl ConnectConfig {
    pub fn new(address: String, port: u16, username: String) -> Self {
        Self {
            address,
            port,
            username,
            columns: 80,
            rows: 24,
            timeout: Duration::from_secs(30),
            keepalive_interval: Some(Duration::from_secs(30)),
            keepalive_failures: 3,
            keepalive_response_timeout: None,
            proxy: None,
            jump: None,
            agent_forwarding: false,
            tmux: None,
            integration: None,
        }
    }
    fn validate(&self) -> Result<(), SshError> {
        if self.address.is_empty()
            || self.username.is_empty()
            || self.port == 0
            || self.rows < 2
            || self.columns < 2
            || self.timeout.is_zero()
            || self.keepalive_interval.is_some_and(|d| d.is_zero())
            || self.keepalive_response_timeout.is_some_and(|d| d.is_zero())
            || (self.keepalive_response_timeout.is_some()
                && !(1..=100).contains(&self.keepalive_failures))
        {
            Err(SshError::InvalidConfig)
        } else {
            if let Some(jump) = &self.jump
                && (jump.port == 0
                    || jump.username.is_empty()
                    || jump.username.chars().any(char::is_control)
                    || proxy::host(&jump.address).is_none()
                    || proxy::host(&self.address).is_none())
            {
                return Err(SshError::InvalidConfig);
            }
            if let Some(proxy) = &self.proxy {
                let (address, port) = self
                    .jump
                    .as_ref()
                    .map(|j| (j.address.as_str(), j.port))
                    .unwrap_or((&self.address, self.port));
                proxy.validate(address, port)?;
            }
            Ok(())
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostKey {
    pub address: String,
    pub port: u16,
    pub algorithm: String,
    pub sha256: String,
}

/// The application must persist an accepted key in the encrypted trust repository
/// BEFORE sending true. Dropping the responder means reject. There is no accept-all mode.
pub struct HostKeyRequest {
    pub key: HostKey,
    /// Opaque application-owned route/attempt tag. Never provided by the peer.
    pub context: Option<u64>,
    pub decision: oneshot::Sender<bool>,
}
#[derive(Clone)]
pub enum HostKeyPolicy {
    Pinned {
        sha256: String,
    },
    Confirm {
        requests: mpsc::Sender<HostKeyRequest>,
    },
    ConfirmTagged {
        requests: mpsc::Sender<HostKeyRequest>,
        context: u64,
    },
}
struct Client {
    address: String,
    port: u16,
    policy: HostKeyPolicy,
    verified: Arc<parking_lot::Mutex<Option<HostKey>>>,
    waiting: watch::Sender<bool>,
    cancel: CancellationToken,
    remote: Arc<remote_forward::Router>,
    agent: Arc<agent_forward::AgentRouter>,
}
impl client::Handler for Client {
    type Error = SshError;
    // russh defaults accept these. Authorization must precede any future
    // forwarding/agent feature; unsupported unsolicited opens are denied.
    fn flow_control_forwarded_tcpip(&self) -> bool {
        true
    }
    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: Channel<client::Msg>,
        address: &str,
        port: u32,
        _: &str,
        _: u32,
        reply: client::ChannelOpenHandle,
        _: &mut client::Session,
    ) -> Result<(), Self::Error> {
        self.remote.incoming(channel, address, port, reply);
        Ok(())
    }
    fn flow_control_agent_forward(&self) -> bool {
        true
    }
    async fn server_channel_open_agent_forward(
        &mut self,
        channel: Channel<client::Msg>,
        reply: client::ChannelOpenHandle,
        _: &mut client::Session,
    ) -> Result<(), Self::Error> {
        self.agent.incoming(channel, reply).await;
        Ok(())
    }
    async fn server_channel_open_session(
        &mut self,
        _: Channel<client::Msg>,

        reply: client::ChannelOpenHandle,
        _: &mut client::Session,
    ) -> Result<(), Self::Error> {
        reply
            .reject(russh::ChannelOpenFailure::AdministrativelyProhibited)
            .await;
        Ok(())
    }
    async fn server_channel_open_direct_tcpip(
        &mut self,
        _: Channel<client::Msg>,
        _: &str,
        _: u32,
        _: &str,
        _: u32,
        reply: client::ChannelOpenHandle,
        _: &mut client::Session,
    ) -> Result<(), Self::Error> {
        reply
            .reject(russh::ChannelOpenFailure::AdministrativelyProhibited)
            .await;
        Ok(())
    }
    async fn server_channel_open_forwarded_streamlocal(
        &mut self,
        _: Channel<client::Msg>,
        _: &str,
        reply: client::ChannelOpenHandle,
        _: &mut client::Session,
    ) -> Result<(), Self::Error> {
        reply
            .reject(russh::ChannelOpenFailure::AdministrativelyProhibited)
            .await;
        Ok(())
    }
    async fn server_channel_open_direct_streamlocal(
        &mut self,
        _: Channel<client::Msg>,
        _: &str,
        reply: client::ChannelOpenHandle,
        _: &mut client::Session,
    ) -> Result<(), Self::Error> {
        reply
            .reject(russh::ChannelOpenFailure::AdministrativelyProhibited)
            .await;
        Ok(())
    }
    async fn server_channel_open_x11(
        &mut self,
        _: Channel<client::Msg>,
        _: &str,
        _: u32,
        reply: client::ChannelOpenHandle,
        _: &mut client::Session,
    ) -> Result<(), Self::Error> {
        reply
            .reject(russh::ChannelOpenFailure::AdministrativelyProhibited)
            .await;
        Ok(())
    }
    async fn check_server_key(
        &mut self,
        key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let public = key.public_key();
        let fingerprint = public.fingerprint(HashAlg::Sha256).to_string();
        let identity = HostKey {
            address: self.address.clone(),
            port: self.port,
            algorithm: public.algorithm().to_string(),
            sha256: fingerprint.clone(),
        };
        if let Some(previous) = self.verified.lock().as_ref() {
            return if previous == &identity {
                Ok(true)
            } else {
                Err(SshError::HostKeyChanged {
                    expected: previous.sha256.clone(),
                    received: fingerprint,
                })
            };
        }
        let result = match &self.policy {
            HostKeyPolicy::Pinned { sha256 } => {
                if *sha256 == fingerprint {
                    Ok(true)
                } else {
                    Err(SshError::HostKeyChanged {
                        expected: sha256.clone(),
                        received: fingerprint,
                    })
                }
            }
            HostKeyPolicy::Confirm { requests } | HostKeyPolicy::ConfirmTagged { requests, .. } => {
                self.waiting.send_replace(true);
                let (decision, response) = oneshot::channel();
                let request = HostKeyRequest {
                    context: match &self.policy {
                        HostKeyPolicy::ConfirmTagged { context, .. } => Some(*context),
                        _ => None,
                    },
                    key: HostKey {
                        address: self.address.clone(),
                        port: self.port,
                        algorithm: public.algorithm().to_string(),
                        sha256: fingerprint,
                    },
                    decision,
                };
                let result = tokio::select! {
                    biased;
                    _ = self.cancel.cancelled() => Err(SshError::Cancelled),
                    r = async {
                        requests.send(request).await.map_err(|_| SshError::HostKeyRejected)?;
                        if response.await.unwrap_or(false) { Ok(true) } else { Err(SshError::HostKeyRejected) }
                    } => r,
                };
                self.waiting.send_replace(false);
                result
            }
        };
        if matches!(result, Ok(true)) {
            *self.verified.lock() = Some(identity);
        }
        result
    }
}

/// Owns one transport, its PTY and future associated SFTP/forwarding channels.
/// Drop cancels the underlying network stream; no reconnect is performed.
pub struct SshConnection {
    handle: Arc<client::Handle<Client>>,
    tcp: TcpConnector,
    inspector: inspection::Inspector,
    direct: direct_transfer::DirectConnector,
    sftp: sftp_connector::SftpConnector,
    remote: RemoteConnector,
    pty: Channel<client::Msg>,
    early_output: VecDeque<Vec<u8>>,
    lifetime: Lifetime,
    closed: bool,
    heartbeat: heartbeat::Heartbeat,
    agent: Arc<agent_forward::AgentRouter>,
    verified_host: HostKey,
    tmux: Option<tmux::TmuxState>,
    tmux_session: Option<tmux::Identity>,
    integration_nonce: Option<Zeroizing<String>>,
    fallback_integration: Option<integration::Launch>,
    fallback_agent: bool,
    fallback_timeout: Duration,
    pty_exit_status: Option<u32>,
    pending_pty: VecDeque<Result<PtyEvent, SshError>>,
}
#[derive(Debug, PartialEq, Eq)]
pub enum PtyEvent {
    Data(Vec<u8>),
    ExitStatus(u32),
    End,
}

impl SshConnection {
    /// Passive samples from this original target's existing ACK heartbeat.
    pub fn subscribe_latency(&self) -> tokio::sync::watch::Receiver<Option<u64>> {
        self.heartbeat.subscribe_latency()
    }
    /// Explicit TCP/proxy, optional jump login, and target SSH identity test.
    /// Target credentials/authentication/PTY requests are never sent. A configured
    /// jump is authenticated only to open the target's direct-tcpip channel.
    pub async fn test_connection(
        config: ConnectConfig,
        policy: HostKeyPolicy,
        cancel: CancellationToken,
    ) -> Result<(), SshError> {
        let (handle, mut budget, _lifetime, _remote, _agent, _verified_host) =
            open_transport(&config, policy, cancel).await?;
        budget
            .run(Stage::Handshake, async {
                handle
                    .disconnect(russh::Disconnect::ByApplication, "", "")
                    .await?;
                Ok(())
            })
            .await
    }

    pub async fn connect(
        mut config: ConnectConfig,
        auth: Authentication,
        policy: HostKeyPolicy,
        cancel: CancellationToken,
    ) -> Result<Self, SshError> {
        let (mut handle, mut budget, lifetime, router, agent, verified_host) =
            open_transport(&config, policy, cancel).await?;
        authenticate(
            &mut handle,
            &config.username,
            auth,
            &mut budget,
            Stage::Authentication,
        )
        .await?;
        // Authentication has consumed/zeroized the selected target secret.
        // Release completed jump/proxy credentials before an unbounded human choice.
        config.jump = None;
        config.proxy = None;
        let mut startup = if let Some(policy) = config.tmux.take() {
            tmux::prepare(
                &mut handle,
                &mut budget,
                policy,
                &lifetime.0,
                (config.columns, config.rows),
                &verified_host,
                &config.username,
            )
            .await?
        } else {
            tmux::Startup {
                command: None,
                lock_size: false,
                readonly: false,
                session: None,
                deferred_create: None,
            }
        };
        // Verified against a real Ubuntu sshd (2026-11-06): only a
        // `request_shell` session prints the PAM/MOTD banner and last-login
        // line; exec sessions never do, PTY or not. The main channel therefore
        // always starts as the user's default shell so the banner lands in the
        // terminal stream. When the optional Bash integration is enabled, its
        // capability probe runs on a *separate* exec channel; only when the
        // probe succeeds is the default shell channel replaced by a fresh
        // channel running the fixed integration Bash (the banner already
        // shown is never repeated — PAM opens one session per connection).
        let mut early_output = VecDeque::new();
        let (mut pty, mut creation_agent) = open_interactive_channel(
            &handle,
            &mut budget,
            config.columns,
            config.rows,
            &mut early_output,
            config.agent_forwarding.then(|| (agent.as_ref(), true)),
        )
        .await?;
        tmux::complete_creation(
            &mut startup,
            &handle,
            &mut budget,
            (config.columns, config.rows),
            creation_agent,
        )
        .await?;
        let tmux = startup.command.as_ref().map(|_| tmux::TmuxState {
            readonly: startup.readonly,
            size_locked: startup.lock_size,
        });
        let tmux_session = startup.session.clone();
        let fallback_integration = if tmux.is_some() {
            config.integration.clone()
        } else {
            None
        };
        let mut integration = config
            .integration
            .take()
            .filter(|_| startup.command.is_none());
        let stage = if startup.command.is_some() {
            Stage::Tmux
        } else {
            Stage::Shell
        };
        budget
            .run(stage, async {
                if let Some(command) = startup.command.as_ref() {
                    pty.exec(true, command.as_bytes()).await?;
                } else {
                    // Default shell first: banner + last-login arrive here and
                    // are preserved verbatim in `early_output`.
                    pty.request_shell(true).await?;
                }
                expect_success(&mut pty, &mut early_output, stage).await
            })
            .await?;
        if integration.is_some() {
            // The probe runs beside the (now running) default shell on its own
            // exec channel; the shell's banner stream stays uninterrupted.
            if !integration::probe_on_exec_channel(&handle, &mut budget).await? {
                // Unavailable: keep the default shell channel as-is.
                integration = None;
            } else {
                // Capable: swap channels. The default shell is closed (its
                // prompt may have shown briefly) and the fixed integration
                // Bash starts on a fresh interactive channel without a second
                // banner. The banner/prompt bytes the shell already printed
                // are drained first: closing the channel earlier would
                // truncate them.
                let drain = async {
                    let mut seen = false;
                    loop {
                        // Be patient for the first bytes (update-motd scripts
                        // can take a second), then stop after a short silent
                        // window: that is where the banner stream settles.
                        let patience = if seen { 350 } else { 3000 };
                        match tokio::time::timeout(
                            std::time::Duration::from_millis(patience),
                            pty.wait(),
                        )
                        .await
                        {
                            Ok(Some(russh::ChannelMsg::Data { data }))
                            | Ok(Some(russh::ChannelMsg::ExtendedData { data, .. })) => {
                                seen = true;
                                early_output.push_back(data.to_vec());
                            }
                            Ok(Some(_)) => {}
                            Ok(None) | Err(_) => break,
                        }
                    }
                };
                budget
                    .run(Stage::Shell, async {
                        drain.await;
                        Ok::<(), crate::SshError>(())
                    })
                    .await?;
                let _ = pty.close().await;
                let (next, forwarded) = open_interactive_channel(
                    &handle,
                    &mut budget,
                    config.columns,
                    config.rows,
                    &mut early_output,
                    config.agent_forwarding.then(|| (agent.as_ref(), false)),
                )
                .await?;
                // OpenSSH keeps agent forwarding at connection scope. It may
                // reject the new channel's duplicate request while continuing
                // to expose the already-accepted socket to exec sessions.
                // Preserve its negotiated request dialect for direct copies;
                // the fixed remote helper still verifies its actual socket.
                creation_agent = forwarded.or(creation_agent);
                pty = next;
                let command = integration
                    .as_ref()
                    .map(integration::Launch::command)
                    .expect("checked above");
                budget
                    .run(Stage::Shell, async {
                        pty.exec(true, command.as_bytes()).await?;
                        expect_success(&mut pty, &mut early_output, Stage::Shell).await
                    })
                    .await?;
            }
        }
        let integration_nonce = integration
            .as_ref()
            .map(|launch| Zeroizing::new(launch.nonce().to_owned()));
        let handle = Arc::new(handle);
        let heartbeat = heartbeat::Heartbeat::start(
            &handle,
            lifetime.0.clone(),
            config.keepalive_interval,
            config.keepalive_response_timeout,
            config.keepalive_failures,
        );
        let tcp = TcpConnector::new(handle.clone(), lifetime.0.clone());
        let remote = RemoteConnector::new(handle.clone(), lifetime.0.clone(), router);
        let inspector = inspection::Inspector::new(
            handle.clone(),
            lifetime.0.clone(),
            tmux_session.clone(),
            startup.readonly,
        );
        let sftp = sftp_connector::SftpConnector::new(handle.clone(), lifetime.0.clone());
        let direct = direct_transfer::DirectConnector::new(
            handle.clone(),
            lifetime.0.clone(),
            AgentConnector::new(agent.clone()),
            creation_agent,
        );
        Ok(Self {
            handle,
            tcp,
            inspector,
            direct,
            sftp,
            remote,
            pty,
            early_output,
            lifetime,
            closed: false,
            heartbeat,
            agent,
            verified_host,
            tmux,
            tmux_session,
            integration_nonce,
            fallback_integration,
            fallback_agent: config.agent_forwarding,
            fallback_timeout: config.timeout,
            pty_exit_status: None,
            pending_pty: VecDeque::new(),
        })
    }

    pub(crate) fn integration_nonce(&self) -> Option<&str> {
        self.integration_nonce.as_deref().map(String::as_str)
    }

    pub fn tmux_state(&self) -> Option<tmux::TmuxState> {
        self.tmux
    }
    pub fn tmux_session(&self) -> Option<&tmux::Identity> {
        self.tmux_session.as_ref()
    }

    /// Identity proven by this original Transport, not a later trust-store read.
    pub fn verified_host_key(&self) -> &HostKey {
        &self.verified_host
    }

    /// Original-connection capability, never follows a reconnect.
    pub fn direct_connector(&self) -> direct_transfer::DirectConnector {
        self.direct.clone()
    }

    pub fn agent_connector(&self) -> AgentConnector {
        AgentConnector::new(self.agent.clone())
    }

    pub fn is_closed(&self) -> bool {
        self.closed || self.lifetime.0.is_cancelled() || self.handle.is_closed()
    }

    pub async fn write(&self, data: &[u8]) -> Result<(), SshError> {
        if self.is_closed() {
            return Err(self.heartbeat.failure_or(SshError::Disconnected));
        }
        tokio::select! {
            biased;
            _ = self.lifetime.0.cancelled() => Err(self.heartbeat.failure_or(SshError::Cancelled)),
            r = self.pty.data(data) => Ok(r?),
        }
    }

    pub async fn resize(&self, columns: u16, rows: u16) -> Result<(), SshError> {
        if columns < 2 || rows < 2 {
            return Err(SshError::InvalidConfig);
        }
        if self.is_closed() {
            return Err(self.heartbeat.failure_or(SshError::Disconnected));
        }
        tokio::select! {
            biased;
            _ = self.lifetime.0.cancelled() => Err(self.heartbeat.failure_or(SshError::Cancelled)),
            r = self.pty.window_change(columns.into(), rows.into(), 0, 0) => Ok(r?),
        }
    }

    pub async fn read(&mut self) -> Result<PtyEvent, SshError> {
        if let Some(event) = self.pending_pty.pop_front() {
            match &event {
                Ok(PtyEvent::ExitStatus(status)) => self.pty_exit_status = Some(*status),
                Ok(PtyEvent::End) => self.closed = true,
                _ => {}
            }
            return event;
        }
        if let Some(bytes) = self.early_output.pop_front() {
            return Ok(PtyEvent::Data(bytes));
        }
        if self.closed {
            return Ok(PtyEvent::End);
        }
        loop {
            let event = tokio::select! {
                biased;
                _ = self.lifetime.0.cancelled() => return Err(self.heartbeat.failure_or(SshError::Cancelled)),
                msg = self.pty.wait() => msg,
            };
            match event {
                Some(ChannelMsg::Data { data }) | Some(ChannelMsg::ExtendedData { data, .. }) => {
                    // Drain only packets already queued in this dispatch turn.
                    // One TUI redraw often spans several SSH packets; publishing
                    // its clear packet alone creates a visible empty frame.
                    // No sleep/quiet-window or lower frame-rate limit is added.
                    use futures_util::FutureExt;
                    let mut bytes = data.to_vec();
                    let started = std::time::Instant::now();
                    while bytes.len() < 256 * 1024 && started.elapsed() < Duration::from_millis(2) {
                        match self.pty.wait().now_or_never() {
                            Some(Some(
                                ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. },
                            )) => {
                                if bytes.len() + data.len() > 256 * 1024 {
                                    self.pending_pty
                                        .push_back(Ok(PtyEvent::Data(data.to_vec())));
                                    break;
                                }
                                bytes.extend_from_slice(&data);
                            }
                            Some(Some(ChannelMsg::ExitStatus { exit_status })) => {
                                self.pending_pty
                                    .push_back(Ok(PtyEvent::ExitStatus(exit_status)));
                                break;
                            }
                            Some(Some(ChannelMsg::Close) | None) => {
                                self.pending_pty.push_back(Ok(PtyEvent::End));
                                break;
                            }
                            Some(Some(ChannelMsg::ReceiveWindowError)) => {
                                self.pending_pty
                                    .push_back(Err(russh::Error::Inconsistent.into()));
                                break;
                            }
                            Some(Some(_)) => {}
                            None => break,
                        }
                    }
                    return Ok(PtyEvent::Data(bytes));
                }
                Some(ChannelMsg::ReceiveWindowError) => {
                    return Err(russh::Error::Inconsistent.into());
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => {
                    self.pty_exit_status = Some(exit_status);
                    return Ok(PtyEvent::ExitStatus(exit_status));
                }
                Some(ChannelMsg::Close) | None => {
                    self.closed = true;
                    return Ok(PtyEvent::End);
                }
                _ => {}
            }
        }
    }

    /// A clean tmux client exit replaces only the interactive channel. This is
    /// not a Transport reconnect; SFTP/forwardings keep their original owners.
    /// Called outside the actor's cancelable read select, so a key/resize cannot
    /// drop a half-open PTY while it is being installed.
    pub(crate) async fn restore_shell(
        &mut self,
        columns: u16,
        rows: u16,
        cancel: CancellationToken,
    ) -> Result<bool, SshError> {
        if self.tmux.is_none()
            || self.pty_exit_status != Some(0)
            || self.lifetime.0.is_cancelled()
            || self.handle.is_closed()
        {
            return Ok(false);
        }
        let (_pause, paused) = tokio::sync::watch::channel(false);
        let mut budget = crate::budget::Budget::new(self.fallback_timeout, paused, cancel);
        // Prior PTY has ended. Do not re-authenticate, reconnect or touch files.
        budget
            .run(Stage::Shell, async {
                self.pty.close().await?;
                Ok(())
            })
            .await?;
        let launch = self.fallback_integration.take();
        let launch = if launch.is_some()
            && integration::probe_on_exec_channel(&self.handle, &mut budget).await?
        {
            launch
        } else {
            None
        };
        let (mut next, _) = open_interactive_channel(
            &self.handle,
            &mut budget,
            columns,
            rows,
            &mut self.early_output,
            self.fallback_agent.then(|| (self.agent.as_ref(), false)),
        )
        .await?;
        // Install the owner before awaiting startup. Failure still leaves the
        // channel owned by this connection and its explicit close path.
        std::mem::swap(&mut self.pty, &mut next);
        budget
            .run(Stage::Shell, async {
                if let Some(ref launch) = launch {
                    self.pty.exec(true, launch.command().as_bytes()).await?;
                } else {
                    self.pty.request_shell(true).await?;
                }
                expect_success(&mut self.pty, &mut self.early_output, Stage::Shell).await
            })
            .await?;
        self.integration_nonce = launch
            .as_ref()
            .map(|v| Zeroizing::new(v.nonce().to_owned()));
        self.tmux = None;
        self.tmux_session = None;
        self.inspector.clear_tmux();
        self.pty_exit_status = None;
        self.closed = false;
        Ok(true)
    }

    /// Opens an SFTP channel on this transport. Caller must close the returned session.
    pub async fn open_sftp(&self) -> Result<russh_sftp::client::SftpSession, SshError> {
        self.sftp_opener().await
    }

    pub fn inspector(&self) -> Result<inspection::Inspector, SshError> {
        if self.is_closed() {
            return Err(self.heartbeat.failure_or(SshError::Disconnected));
        }
        Ok(self.inspector.clone())
    }

    pub fn tcp_connector(&self) -> Result<TcpConnector, SshError> {
        if self.is_closed() {
            return Err(self.heartbeat.failure_or(SshError::Disconnected));
        }
        Ok(self.tcp.clone())
    }

    pub fn remote_connector(&self) -> Result<RemoteConnector, SshError> {
        if self.is_closed() {
            return Err(self.heartbeat.failure_or(SshError::Disconnected));
        }
        Ok(self.remote.clone())
    }

    /// A transport capability that can open a channel while the owning actor
    /// continues draining PTY output. The lifetime token still cancels on drop.
    pub(crate) fn sftp_opener(
        &self,
    ) -> impl std::future::Future<Output = Result<russh_sftp::client::SftpSession, SshError>>
    + Send
    + 'static {
        let connector = self.sftp.clone();
        async move { connector.open().await }
    }

    pub async fn close(&mut self) -> Result<(), SshError> {
        self.agent.stop();
        if self.lifetime.0.is_cancelled() {
            self.closed = true;
            self.direct.wait_closed().await;
            self.inspector.wait_closed().await;
            self.sftp.wait_closed().await;
            let heartbeat = self.heartbeat.shutdown().await;
            let agent = self.agent.shutdown().await;
            heartbeat?;
            return agent;
        }
        let result = tokio::time::timeout(Duration::from_secs(2), async {
            self.handle
                .disconnect(russh::Disconnect::ByApplication, "", "")
                .await?;
            Ok::<_, SshError>(())
        })
        .await;
        self.closed = true;
        self.lifetime.0.cancel();
        self.direct.wait_closed().await;
        self.inspector.wait_closed().await;
        self.sftp.wait_closed().await;
        let heartbeat = self.heartbeat.shutdown().await;
        let agent = self.agent.shutdown().await;
        heartbeat?;
        agent?;
        match result {
            Ok(r) => r,
            Err(_) => Err(SshError::Timeout(Stage::Shell)),
        }
    }
}

async fn authenticate(
    handle: &mut client::Handle<Client>,
    username: &str,
    auth: Authentication,
    budget: &mut Budget,
    stage: Stage,
) -> Result<(), SshError> {
    budget
        .run(stage, async {
            let result = match auth {
                Authentication::Password(password) => {
                    handle
                        .authenticate_password(username, password.as_str())
                        .await?
                }
                Authentication::PrivateKey {
                    openssh,
                    passphrase,
                } => {
                    let key = tokio::task::spawn_blocking(move || {
                        russh::keys::decode_secret_key(
                            &openssh,
                            passphrase.as_deref().map(|s| s.as_str()),
                        )
                    })
                    .await
                    .map_err(|_| SshError::PrivateKey)?
                    .map_err(|_| SshError::PrivateKey)?;
                    let is_rsa = key.algorithm().is_rsa();
                    let algorithm = if is_rsa {
                        match handle.best_supported_rsa_hash().await? {
                            Some(Some(hash)) => Some(hash),
                            // Old servers without EXT_INFO may still accept RFC8332.
                            // Never silently downgrade to legacy SHA-1.
                            None => Some(HashAlg::Sha256),
                            Some(None) => return Err(SshError::RsaUnsupported),
                        }
                    } else {
                        None
                    };
                    let key = tokio::task::spawn_blocking(move || {
                        PrivateKeyWithHashAlg::try_new(Arc::new(key), algorithm)
                    })
                    .await
                    .map_err(|_| SshError::PrivateKey)?
                    .map_err(|_| {
                        if is_rsa {
                            SshError::RsaUnsupported
                        } else {
                            SshError::PrivateKey
                        }
                    })?;
                    handle.authenticate_publickey(username, key).await?
                }
            };
            if result.success() {
                Ok(())
            } else {
                Err(SshError::Authentication)
            }
        })
        .await
}

async fn open_transport(
    config: &ConnectConfig,
    policy: HostKeyPolicy,
    cancel: CancellationToken,
) -> Result<
    (
        client::Handle<Client>,
        Budget,
        Lifetime,
        Arc<remote_forward::Router>,
        Arc<agent_forward::AgentRouter>,
        HostKey,
    ),
    SshError,
> {
    config.validate()?;
    let lifetime = Lifetime(cancel.child_token());
    let (waiting, paused) = watch::channel(false);
    let mut budget = Budget::new(config.timeout, paused, lifetime.0.clone());
    let (endpoint, endpoint_port) = match &config.jump {
        Some(jump) => (
            proxy::host(&jump.address).ok_or(SshError::InvalidConfig)?,
            jump.port,
        ),
        None => (config.address.as_str(), config.port),
    };
    let route_error = |error| {
        if config.jump.is_some() {
            jump::error(error)
        } else {
            error
        }
    };
    let mut stream = budget
        .run(Stage::Tcp, async {
            let (address, port) = match &config.proxy {
                Some(proxy) => (
                    proxy::host(&proxy.address).ok_or(SshError::InvalidConfig)?,
                    proxy.port,
                ),
                None => (endpoint, endpoint_port),
            };
            Ok(TcpStream::connect((address, port)).await?)
        })
        .await
        .map_err(route_error)?;
    stream.set_nodelay(true)?;
    if let Some(proxy) = &config.proxy {
        budget
            .run(
                Stage::Proxy,
                proxy::negotiate(&mut stream, proxy, endpoint, endpoint_port),
            )
            .await
            .map_err(route_error)?;
    }
    let handler = |address: String, port, policy| Client {
        address,
        port,
        policy,
        verified: Arc::new(parking_lot::Mutex::new(None)),
        waiting: waiting.clone(),
        cancel: lifetime.0.clone(),
        remote: remote_forward::Router::new(),
        agent: agent_forward::AgentRouter::new(lifetime.0.clone()),
    };
    let mut preferred = russh::Preferred::default();
    preferred.key = preferred
        .key
        .iter()
        .filter(|a| !matches!(a, russh::keys::Algorithm::Rsa { hash: None }))
        .cloned()
        .collect::<Vec<_>>()
        .into();
    let client_config = Arc::new(client::Config {
        preferred,
        keepalive_interval: if config.keepalive_response_timeout.is_some() {
            None
        } else {
            config.keepalive_interval
        },
        keepalive_max: config.keepalive_failures,
        channel_buffer_size: 32,
        ..client::Config::default()
    });
    let target_handler = handler(config.address.clone(), config.port, policy);
    let verified = target_handler.verified.clone();
    let router = target_handler.remote.clone();
    let agent = target_handler.agent.clone();
    let handle = if let Some(jump) = &config.jump {
        let mut jump_handle = handshake(
            stream,
            handler(jump.address.clone(), jump.port, jump.host_key.clone()),
            client_config.clone(),
            &mut budget,
            Stage::JumpHandshake,
        )
        .await
        .map_err(jump::error)?;
        authenticate(
            &mut jump_handle,
            &jump.username,
            jump.authentication.clone(),
            &mut budget,
            Stage::JumpAuthentication,
        )
        .await
        .map_err(jump::error)?;
        let channel = budget
            .run(Stage::JumpChannel, async {
                Ok(jump_handle
                    .channel_open_direct_tcpip(
                        proxy::host(&config.address).ok_or(SshError::InvalidConfig)?,
                        config.port.into(),
                        "127.0.0.1",
                        0,
                    )
                    .await?)
            })
            .await
            .map_err(jump::error)?;
        handshake(
            jump::JumpStream::new(channel, jump_handle),
            target_handler,
            client_config,
            &mut budget,
            Stage::Handshake,
        )
        .await?
    } else {
        handshake(
            stream,
            target_handler,
            client_config,
            &mut budget,
            Stage::Handshake,
        )
        .await?
    };
    let verified_host = verified.lock().clone().ok_or(SshError::HostKeyRejected)?;
    Ok((handle, budget, lifetime, router, agent, verified_host))
}

async fn handshake<S: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
    stream: S,
    handler: Client,
    config: Arc<client::Config>,
    budget: &mut Budget,
    stage: Stage,
) -> Result<client::Handle<Client>, SshError> {
    let cancel = handler.cancel.clone();
    budget
        .run(stage, async {
            client::connect_stream(config, CancelStream::new(stream, cancel), handler).await
        })
        .await
}

/// One interactive PTY channel with the fixed terminal mode and an optional
/// agent-forwarding request. Output printed while requests are pending is
/// preserved in `early`; only the first channel of a connection reports the
/// agent endpoint result to the router.
async fn open_interactive_channel(
    handle: &client::Handle<Client>,
    budget: &mut crate::budget::Budget,
    columns: u16,
    rows: u16,
    early: &mut VecDeque<Vec<u8>>,
    agent: Option<(&agent_forward::AgentRouter, bool)>,
) -> Result<(Channel<client::Msg>, Option<bool>), SshError> {
    let mut channel = budget
        .run(Stage::Pty, async {
            Ok(handle.channel_open_session_flow_controlled().await?)
        })
        .await?;
    budget
        .run(Stage::Pty, async {
            channel
                .request_pty(
                    true,
                    "xterm-256color",
                    columns.into(),
                    rows.into(),
                    0,
                    0,
                    &[],
                )
                .await?;
            expect_success(&mut channel, early, Stage::Pty).await
        })
        .await?;
    let mut creation_agent = None;
    if let Some((router, report)) = agent {
        budget
            .run(Stage::Agent, async {
                let standard = handle.supports_agent_forwarding_v0().await?;
                if standard {
                    channel.agent_forward_standard(true).await?;
                } else {
                    channel.agent_forward(true).await?;
                }
                match expect_success(&mut channel, early, Stage::Agent).await {
                    Ok(()) => {
                        if report {
                            router.endpoint_result(true);
                        }
                        creation_agent = Some(standard);
                    }
                    Err(SshError::RequestDenied(Stage::Agent)) => {
                        if report {
                            router.endpoint_result(false);
                        }
                    }
                    Err(error) => return Err(error),
                }
                Ok(())
            })
            .await?;
    }
    Ok((channel, creation_agent))
}

async fn expect_success(
    channel: &mut Channel<client::Msg>,
    early: &mut VecDeque<Vec<u8>>,
    stage: Stage,
) -> Result<(), SshError> {
    let mut buffered = 0;
    loop {
        match channel.wait().await {
            Some(ChannelMsg::Success) => return Ok(()),
            Some(ChannelMsg::Failure) => return Err(SshError::RequestDenied(stage)),
            Some(ChannelMsg::ReceiveWindowError) => return Err(russh::Error::Inconsistent.into()),
            Some(ChannelMsg::Data { data }) | Some(ChannelMsg::ExtendedData { data, .. }) => {
                buffered += data.len();
                // Reject a peer flooding data before acknowledging, without silently dropping bytes.
                if buffered > 1_048_576 {
                    return Err(SshError::RequestDenied(stage));
                }
                early.push_back(data.to_vec());
            }
            Some(ChannelMsg::Close) | Some(ChannelMsg::Eof) | None => {
                return Err(SshError::Disconnected);
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod peer_identity_tests {
    use super::*;
    #[tokio::test]
    async fn accepted_identity_is_cached_per_client_and_changed_keys_cannot_reprompt_or_replace_it()
    {
        use russh::{
            client::Handler,
            keys::{Algorithm, PrivateKey},
        };
        let key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
        let changed = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519).unwrap();
        let (waiting, _) = watch::channel(false);
        let (requests, mut receive) = mpsc::channel(1);
        let cancel = CancellationToken::new();
        let verified = Arc::new(parking_lot::Mutex::new(None));
        let mut client = Client {
            address: "fixture.invalid".into(),
            port: 22,
            policy: HostKeyPolicy::Confirm { requests },
            verified: verified.clone(),
            waiting,
            cancel: cancel.clone(),
            remote: remote_forward::Router::new(),
            agent: agent_forward::AgentRouter::new(cancel),
        };
        let task = tokio::spawn(async move {
            let public: PublicKeyOrCertificate = key.public_key().clone().into();
            assert!(matches!(
                client.check_server_key(&public).await,
                Err(SshError::HostKeyRejected)
            ));
            assert!(client.check_server_key(&public).await.unwrap());
            for _ in 0..3 {
                assert!(client.check_server_key(&public).await.unwrap());
            }
            assert!(matches!(
                client
                    .check_server_key(&changed.public_key().clone().into())
                    .await,
                Err(SshError::HostKeyChanged { .. })
            ));
        });
        let rejected = receive.recv().await.unwrap();
        assert!(verified.lock().is_none());
        rejected.decision.send(false).unwrap();
        let request = receive.recv().await.unwrap();
        assert!(verified.lock().is_none());
        let original = request.key.clone();
        request.decision.send(true).unwrap();
        task.await.unwrap();
        assert_eq!(verified.lock().as_ref(), Some(&original));
        assert!(receive.try_recv().is_err());
    }
}

pub mod clipboard_image;
