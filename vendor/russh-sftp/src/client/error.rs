use std::io;
use thiserror::Error;
use tokio::sync::mpsc::error::SendError as MpscSendError;
use tokio::sync::oneshot::error::RecvError as OneshotRecvError;

use crate::{error, protocol::Status};

/// Enum for client errors
#[derive(Debug, Clone, Error)]
pub enum Error {
    /// Local channel IO has ended; never a new SSH connection request.
    #[error("SFTP channel closed")]
    ConnectionClosed,
    /// Contains an error status packet
    #[error("{}: {}", .0.status_code, .0.error_message)]
    Status(Status),
    /// Any errors related to I/O
    #[error("I/O: {0}")]
    IO(String),
    /// Time limit for receiving response packet exceeded
    #[error("Timeout")]
    Timeout,
    /// Occurs due to exceeding the limits set by the `limits@openssh.com` extension
    #[error("Limit exceeded: {0}")]
    Limited(String),
    /// Occurs when an unexpected packet is sent
    #[error("Unexpected packet")]
    UnexpectedPacket,
    /// Occurs when unexpected server behavior differs from the protocol specifition
    #[error("{0}")]
    UnexpectedBehavior(String),
}

impl From<Status> for Error {
    fn from(status: Status) -> Self {
        Self::Status(status)
    }
}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        match error.kind() {
            io::ErrorKind::TimedOut => Self::Timeout,
            io::ErrorKind::ConnectionReset | io::ErrorKind::ConnectionAborted |
            io::ErrorKind::BrokenPipe | io::ErrorKind::UnexpectedEof |
            io::ErrorKind::NotConnected => Self::ConnectionClosed,
            _ => Self::IO(error.to_string()),
        }
    }
}

impl<T> From<MpscSendError<T>> for Error {
    fn from(_: MpscSendError<T>) -> Self {
        Self::ConnectionClosed
    }
}

impl From<OneshotRecvError> for Error {
    fn from(_: OneshotRecvError) -> Self {
        Self::ConnectionClosed
    }
}

impl From<error::Error> for Error {
    fn from(error: error::Error) -> Self {
        Self::UnexpectedBehavior(error.to_string())
    }
}

impl From<Error> for io::Error {
    fn from(error: Error) -> Self {
        let kind = match error {
            Error::Timeout => io::ErrorKind::TimedOut,
            Error::ConnectionClosed => io::ErrorKind::ConnectionAborted,
            _ => io::ErrorKind::Other,
        };
        Self::new(kind, error)
    }
}
