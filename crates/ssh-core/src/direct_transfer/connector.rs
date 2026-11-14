//! Original-Root single-slot exec ownership, independent of the terminal PTY.
use super::*;
use crate::{AgentConnector, Client, SshError};
use futures_util::FutureExt;
use russh::{Channel, ChannelMsg, client};
use std::{sync::Arc, time::Duration};
use tokio::sync::{Semaphore, oneshot};
use tokio_util::sync::CancellationToken;
const DEADLINE: Duration = Duration::from_secs(18);
const OUTPUT_LIMIT: usize = 4096;

#[derive(Clone)]
pub struct DirectConnector {
    handle: Arc<client::Handle<Client>>,
    root: CancellationToken,
    agent: AgentConnector,
    standard_agent: Option<bool>,
    slot: Arc<Semaphore>,
    authentication: Option<Arc<super::auth::Lease>>,
}
impl DirectConnector {
    pub(crate) fn new(
        handle: Arc<client::Handle<Client>>,
        root: CancellationToken,
        agent: AgentConnector,
        standard_agent: Option<bool>,
    ) -> Self {
        Self {
            handle,
            root,
            agent,
            standard_agent,
            slot: Arc::new(Semaphore::new(1)),
            authentication: None,
        }
    }
    pub(crate) async fn wait_closed(&self) {
        if let Ok(permit) = self.slot.acquire().await {
            drop(permit);
        }
    }
    pub(super) fn agent_status(&self) -> AgentStatus {
        self.authentication
            .as_ref()
            .map_or_else(|| self.agent.status(), |a| a.status())
    }
    /// The caller has checked the source socket opt-in and captured the
    /// original destination credential. No general Agent grant is changed.
    pub async fn with_authentication(
        &self,
        authentication: crate::Authentication,
    ) -> Result<Self, SshError> {
        if self.standard_agent.is_none() || self.root.is_cancelled() {
            return Err(DirectPreparationError::AgentUnavailable.into());
        }
        let capability = self.agent.direct_authentication(authentication).await?;
        Ok(Self {
            authentication: Some(Arc::new(super::auth::Lease(capability))),
            ..self.clone()
        })
    }
    pub fn authentication_epoch(&self) -> u64 {
        self.agent_status().epoch
    }
    /// Only a fixed read-only probe; cannot accept arbitrary exec or paths.
    /// The target must be an actual peer identity captured by the calling task.
    pub async fn probe(
        &self,
        target: &HostKey,
        username: &str,
        expected_agent_epoch: u64,
        cancel: CancellationToken,
    ) -> Result<ProbeStatus, SshError> {
        let probe =
            DirectProbe::prepare(target, username, &self.agent_status(), expected_agent_epoch)?;
        let raw = self
            .execute(
                probe.command,
                probe.agent_epoch,
                Some(DEADLINE),
                cancel,
                None,
                true,
            )
            .await?;
        Ok(DirectProbe::parse_reply(&raw)?)
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn stage(
        &self,
        target: &HostKey,
        username: &str,
        epoch: u64,
        source: &str,
        staged: &str,
        bytes: u64,
        nonce: &[u8],
        cancel: CancellationToken,
    ) -> Result<(), SshError> {
        self.stage_owned(
            target, username, epoch, source, staged, bytes, nonce, cancel, None,
        )
        .await
    }
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn stage_owned(
        &self,
        target: &HostKey,
        username: &str,
        epoch: u64,
        source: &str,
        staged: &str,
        bytes: u64,
        nonce: &[u8],
        cancel: CancellationToken,
        owner: Option<Arc<Operations>>,
    ) -> Result<(), SshError> {
        self.stage_attempt_owned(
            target, username, epoch, source, staged, bytes, nonce, 1, None, cancel, owner,
        )
        .await
    }
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn stage_attempt_owned(
        &self,
        target: &HostKey,
        username: &str,
        epoch: u64,
        source: &str,
        staged: &str,
        bytes: u64,
        nonce: &[u8],
        attempt: u64,
        previous: Option<u64>,
        cancel: CancellationToken,
        owner: Option<Arc<Operations>>,
    ) -> Result<(), SshError> {
        let write = DirectWrite::prepare_attempt(
            target,
            username,
            &self.agent_status(),
            epoch,
            source,
            staged,
            bytes,
            nonce,
            attempt,
            previous,
        )?;
        let raw = self
            .execute(write.command, write.agent_epoch, None, cancel, owner, false)
            .await?;
        Ok(DirectWrite::parse_reply(&raw)?)
    }
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn inspect_owned(
        &self,
        target: &HostKey,
        username: &str,
        epoch: u64,
        staged: &str,
        bytes: u64,
        nonce: &[u8],
        cancel: CancellationToken,
        owner: Option<Arc<Operations>>,
    ) -> Result<ReceiptReply, SshError> {
        let query = DirectQuery::prepare(
            target,
            username,
            &self.agent_status(),
            epoch,
            staged,
            bytes,
            nonce,
        )?;
        let raw = self
            .execute(
                query.command,
                query.agent_epoch,
                Some(DEADLINE),
                cancel,
                owner,
                true,
            )
            .await?;
        Ok(DirectQuery::parse(&raw, bytes)?)
    }
    async fn execute(
        &self,
        command: String,
        expected_agent_epoch: u64,
        deadline: Option<Duration>,
        cancel: CancellationToken,
        owner: Option<Arc<Operations>>,
        read_only: bool,
    ) -> Result<Vec<u8>, SshError> {
        let standard = self
            .standard_agent
            .ok_or(DirectPreparationError::AgentUnavailable)?;
        if self.root.is_cancelled() || self.handle.is_closed() {
            return Err(SshError::Disconnected);
        }
        if cancel.is_cancelled() {
            return Err(DirectPreparationError::Unconfirmed.into());
        }
        let permit = if read_only {
            self.slot
                .clone()
                .try_acquire_owned()
                .map_err(|_| DirectPreparationError::Busy)?
        } else {
            tokio::select! { biased;
                _ = self.root.cancelled() => return Err(SshError::Disconnected),
                _ = cancel.cancelled() => return Err(DirectPreparationError::Unconfirmed.into()),
                permit = self.slot.clone().acquire_owned() => permit.map_err(|_| DirectPreparationError::Unconfirmed)?,
            }
        };
        let finished = owner.map(|owner| owner.begin());
        let local = cancel.child_token();
        let _lifetime = crate::transport::Lifetime(local.clone());
        let root = self.root.clone();
        let handle = self.handle.clone();
        let agent = self.agent.clone();
        let authentication = self.authentication.clone();
        let worker_cancel = local.clone();
        let (send, receive) = oneshot::channel();
        tokio::spawn(async move {
            let _finished = finished;
            let _permit = permit;
            let result = async {
                // No local deadline abandons an unknown channel-open. The one
                // slot follows it through a late ACK or original Root close.
                let mut channel = tokio::select! {
                    biased;
                    _ = root.cancelled() => return Err(SshError::Disconnected),
                    result = handle.channel_open_session_flow_controlled() => result?,
                };
                let mut peer_closed = false;
                let operation = async {
                    let grant = authentication.as_ref().map_or_else(|| agent.status(), |a| a.status());
                    if grant.epoch != expected_agent_epoch || grant.phase != AgentPhase::Active {
                        return Err(DirectPreparationError::AgentUnavailable.into());
                    }
                    if standard { channel.agent_forward_standard(true).await?; }
                    else { channel.agent_forward(true).await?; }
                    // OpenSSH may reject a duplicate connection-wide request
                    // yet supply this already-authorized Root's socket. The
                    // fixed script also requires a real socket in this session.
                    match channel.wait().await {
                        Some(ChannelMsg::Success | ChannelMsg::Failure) => {},
                        _ => return Err(DirectPreparationError::InvalidReply.into()),
                    }
                    let raw = collect(&mut channel, &command, &mut peer_closed, authentication.as_ref().map(|lease| lease.0.as_ref())).await?;
                    let grant = authentication.as_ref().map_or_else(|| agent.status(), |a| a.status());
                    if read_only && (grant.epoch != expected_agent_epoch || grant.phase != AgentPhase::Active) {
                        return Err(DirectPreparationError::AgentUnavailable.into());
                    }
                    Ok::<_, SshError>(raw)
                };
                let result = std::panic::AssertUnwindSafe(async {
                    tokio::select! {
                        biased;
                        _ = root.cancelled() => Err(SshError::Disconnected),
                        _ = worker_cancel.cancelled() => Err(DirectPreparationError::Unconfirmed.into()),
                        result = async { match deadline {
                            Some(limit) => tokio::time::timeout(limit, operation).await.unwrap_or_else(|_| Err(DirectPreparationError::Unconfirmed.into())),
                            None => operation.await,
                        } } => result,
                    }
                }).catch_unwind().await.unwrap_or_else(|_| Err(DirectPreparationError::Unconfirmed.into()));
                if !root.is_cancelled() {
                    let retired = tokio::select! {
                        _ = root.cancelled() => false,
                        result = tokio::time::timeout(Duration::from_secs(2), close(&mut channel, peer_closed)) => matches!(result, Ok(Ok(()))),
                    };
                    if !retired {
                        drop(channel.into_stream());
                        // Unknown close cannot accumulate unbounded retries.
                        root.cancelled().await;
                        return Err(DirectPreparationError::Unconfirmed.into());
                    }
                }
                result
            }.await;
            // The reply certifies local channel retirement. Release admission
            // before waking a caller that can immediately submit another action.
            drop(_permit);
            drop(send.send(result));
        });
        tokio::select! {
            biased;
            _ = self.root.cancelled() => Err(SshError::Disconnected),
            _ = local.cancelled() => Err(DirectPreparationError::Unconfirmed.into()),
            result = async { match deadline {
                Some(limit) => tokio::time::timeout(limit + Duration::from_secs(2), receive).await.map_err(|_| DirectPreparationError::Unconfirmed)?.map_err(|_| DirectPreparationError::Unconfirmed)?,
                None => receive.await.map_err(|_| DirectPreparationError::Unconfirmed)?,
            } } => result,
        }
    }
}
async fn close(channel: &mut Channel<client::Msg>, mut closed: bool) -> Result<(), ()> {
    channel.close().await.map_err(|_| ())?;
    let mut discarded = 0usize;
    let mut events = 0u32;
    while !closed {
        events = events.wrapping_add(1);
        if events.is_multiple_of(64) {
            tokio::task::yield_now().await;
        }
        match channel.wait().await {
            Some(ChannelMsg::Close) | None => closed = true,
            Some(ChannelMsg::Data { data } | ChannelMsg::ExtendedData { data, .. }) => {
                discarded = discarded.checked_add(data.len()).ok_or(())?;
                if discarded > OUTPUT_LIMIT {
                    return Err(());
                }
            }
            _ => {}
        }
    }
    Ok(())
}
async fn collect(
    channel: &mut Channel<client::Msg>,
    command: &str,
    closed: &mut bool,
    authentication: Option<&super::auth::Capability>,
) -> Result<Vec<u8>, SshError> {
    channel.exec(true, command.as_bytes()).await?;
    if let Some(auth) = authentication {
        if !auth.active() {
            return Err(DirectPreparationError::AgentUnavailable.into());
        }
        channel.data(auth.input().as_slice()).await?;
    }
    channel.eof().await?;
    let mut output = Vec::new();
    let mut consumed = 0usize;
    let mut accepted = false;
    let mut status = None;
    let mut events = 0u32;
    loop {
        events = events.wrapping_add(1);
        if events.is_multiple_of(64) {
            tokio::task::yield_now().await;
        }
        match channel.wait().await {
            Some(ChannelMsg::Success) if !accepted => accepted = true,
            Some(ChannelMsg::Data { data }) => {
                consumed = consumed
                    .checked_add(data.len())
                    .ok_or(DirectPreparationError::InvalidReply)?;
                if consumed > OUTPUT_LIMIT {
                    return Err(DirectPreparationError::InvalidReply.into());
                }
                output.extend_from_slice(&data);
            }
            Some(ChannelMsg::ExtendedData { data, .. }) => {
                consumed = consumed
                    .checked_add(data.len())
                    .ok_or(DirectPreparationError::InvalidReply)?;
                if consumed > OUTPUT_LIMIT {
                    return Err(DirectPreparationError::InvalidReply.into());
                }
            }
            Some(ChannelMsg::ExitStatus { exit_status }) if status.is_none() => {
                status = Some(exit_status)
            }
            Some(ChannelMsg::Eof | ChannelMsg::WindowAdjusted { .. }) => {}
            Some(ChannelMsg::Close) | None => {
                *closed = true;
                if !accepted || status != Some(0) {
                    return Err(DirectPreparationError::InvalidReply.into());
                }
                return Ok(output);
            }
            _ => return Err(DirectPreparationError::InvalidReply.into()),
        }
    }
}
