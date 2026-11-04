//! Exactly one explicit SSH jump. Its channel carries the target SSH protocol;
//! no remote command, agent forwarding or locally executed ssh process is used.
use crate::{Authentication, Client, HostKeyPolicy, SshError};
use russh::{Channel, ChannelStream, client};
use std::{
    fmt,
    pin::Pin,
    task::{Context, Poll},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// No nested route/proxy field: the outer ConnectConfig owns the sole proxy,
/// timeout and keepalive policy. Authentication stays separate from the target.
#[derive(Clone)]
pub struct JumpHost {
    pub address: String,
    pub port: u16,
    pub username: String,
    pub authentication: Authentication,
    pub host_key: HostKeyPolicy,
}
impl fmt::Debug for JumpHost {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("JumpHost(<redacted>)")
    }
}

pub(crate) fn error(error: SshError) -> SshError {
    match error {
        SshError::Cancelled => SshError::Cancelled,
        other => SshError::Jump(Box::new(other)),
    }
}

/// The target's detached russh task owns the jump handle and channel together.
/// Both TCP and nested channel I/O also share the outer lifetime cancellation.
pub(crate) struct JumpStream {
    stream: ChannelStream<client::Msg>,
    _jump: client::Handle<Client>,
}
impl JumpStream {
    pub(crate) fn new(channel: Channel<client::Msg>, handle: client::Handle<Client>) -> Self {
        Self {
            stream: channel.into_stream(),
            _jump: handle,
        }
    }
}
impl AsyncRead for JumpStream {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_read(cx, buffer)
    }
}
impl AsyncWrite for JumpStream {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ConnectConfig;
    use zeroize::Zeroizing;
    fn host() -> JumpHost {
        JumpHost {
            address: "127.0.0.1".into(),
            port: 22,
            username: "synthetic-user".into(),
            authentication: Authentication::Password(Zeroizing::new("synthetic-secret".into())),
            host_key: HostKeyPolicy::Pinned {
                sha256: "synthetic-key".into(),
            },
        }
    }
    #[test]
    fn jump_debug_never_exposes_authentication_or_endpoint() {
        let h = host();
        let debug = format!("{h:?}");
        for value in [
            "synthetic-user",
            "synthetic-secret",
            "synthetic-key",
            "127.0.0.1",
        ] {
            assert!(!debug.contains(value));
        }
    }
    #[test]
    fn invalid_jump_or_forwarded_target_is_rejected_before_connecting() {
        for field in 0..4 {
            let mut config = ConnectConfig::new("target.invalid".into(), 22, "user".into());
            let mut jump = host();
            match field {
                0 => jump.port = 0,
                1 => jump.address = "https://proxy.invalid/path".into(),
                2 => jump.username = "invalid\nuser".into(),
                _ => config.address = "target\0.invalid".into(),
            }
            config.jump = Some(jump);
            assert!(matches!(config.validate(), Err(SshError::InvalidConfig)));
        }
        let mut config = ConnectConfig::new("[::1]".into(), 22, "user".into());
        let mut jump = host();
        jump.address = "[::1]".into();
        config.jump = Some(jump);
        assert!(config.validate().is_ok());
    }
}
