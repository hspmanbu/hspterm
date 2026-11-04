//! Retry classification uses typed causes and durable staging phases. A lost
//! CREATE/RENAME acknowledgement is never permission to adopt or republish.
use super::*;

fn channel(error: &SftpError) -> bool {
    matches!(error, SftpError::Timeout | SftpError::ConnectionClosed)
}
fn io_channel(error: &std::io::Error) -> bool {
    error
        .get_ref()
        .and_then(|error| error.downcast_ref::<SftpError>())
        .is_some_and(channel)
}
fn transfer(error: &TransferError) -> bool {
    match error {
        TransferError::Remote(error) => channel(error),
        TransferError::Io(error) | TransferError::RemoteClose(error) => io_channel(error),
        _ => false,
    }
}
fn copy(error: &RemoteCopyError) -> bool {
    match error {
        RemoteCopyError::Transfer(error) => transfer(error),
        RemoteCopyError::Sftp(error) => channel(error),
        RemoteCopyError::Io(error) => io_channel(error),
        RemoteCopyError::Path(transfer::RemoteMoveError::Sftp(error)) => channel(error),
        RemoteCopyError::Close {
            operation,
            source_close,
            destination_close,
        } => {
            // Every reported cause must be transient. A permission error,
            // invalid offset or cancellation is not erased by a later IO fault.
            let any = operation.is_some() || source_close.is_some() || destination_close.is_some();
            any && operation.as_deref().is_none_or(copy)
                && source_close.as_ref().is_none_or(io_channel)
                && destination_close.as_ref().is_none_or(io_channel)
        }
        _ => false,
    }
}
pub(super) fn retryable(error: &RemoteTreeError, kind: NodeKind, phase: StagingPhase) -> bool {
    // A directory can be revalidated without truncation; CREATE failure may
    // already have created it, and ensure_directory validates that exact path.
    // Files: Absent has no write intent; Writing has an acknowledged private
    // OPEN and can resume; Ready is a durably complete private snapshot.
    // Intent may contain an unacknowledged OPEN. Publishing/Published involve
    // destructive or cleanup requests and are never automatically replayed.
    if kind != NodeKind::Directory
        && !matches!(
            phase,
            StagingPhase::Absent | StagingPhase::Writing | StagingPhase::Ready
        )
    {
        return false;
    }
    channel_fault(error)
}
pub(super) fn channel_fault(error: &RemoteTreeError) -> bool {
    match error {
        RemoteTreeError::Sftp(error) => channel(error),
        RemoteTreeError::Copy(error) => copy(error),
        _ => false,
    }
}
pub(super) fn cancelled_channel_cleanup(error: &RemoteTreeError) -> bool {
    matches!(error, RemoteTreeError::Copy(RemoteCopyError::Close {
        operation: Some(operation), source_close, destination_close,
    }) if matches!(operation.as_ref(), RemoteCopyError::Transfer(TransferError::Cancelled))
        && (source_close.is_some() || destination_close.is_some())
        && source_close.as_ref().is_none_or(io_channel)
        && destination_close.as_ref().is_none_or(io_channel))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn network() -> std::io::Error {
        std::io::Error::new(
            std::io::ErrorKind::ConnectionAborted,
            SftpError::ConnectionClosed,
        )
    }
    #[test]
    fn lost_create_or_publish_responses_never_qualify_for_automatic_replay() {
        for phase in [
            StagingPhase::Absent,
            StagingPhase::Writing,
            StagingPhase::Ready,
        ] {
            assert!(retryable(
                &RemoteTreeError::Sftp(SftpError::Timeout),
                NodeKind::File,
                phase
            ));
        }
        for phase in [
            StagingPhase::Intent,
            StagingPhase::Publishing,
            StagingPhase::Published,
        ] {
            assert!(!retryable(
                &RemoteTreeError::Sftp(SftpError::Timeout),
                NodeKind::File,
                phase
            ));
        }
        assert!(retryable(
            &RemoteTreeError::Sftp(SftpError::Timeout),
            NodeKind::Directory,
            StagingPhase::Absent
        ));
    }
    #[test]
    fn mixed_close_failures_preserve_permanent_errors_and_plain_io_is_not_a_channel_proof() {
        let close = |operation| {
            RemoteTreeError::Copy(RemoteCopyError::Close {
                operation,
                source_close: Some(network()),
                destination_close: Some(network()),
            })
        };
        assert!(retryable(
            &close(None),
            NodeKind::File,
            StagingPhase::Writing
        ));
        assert!(retryable(
            &close(Some(Box::new(RemoteCopyError::Sftp(SftpError::Timeout)))),
            NodeKind::File,
            StagingPhase::Writing
        ));
        for error in [
            TransferError::Conflict,
            TransferError::InvalidResume,
            TransferError::Cancelled,
        ] {
            assert!(!retryable(
                &close(Some(Box::new(error.into()))),
                NodeKind::File,
                StagingPhase::Writing
            ));
        }
        for error in [
            RemoteTreeError::Sftp(SftpError::UnexpectedPacket),
            RemoteTreeError::Copy(RemoteCopyError::Io(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "synthetic local timeout",
            ))),
            RemoteTreeError::Uncertain,
            RemoteTreeError::Checkpoint,
        ] {
            assert!(!retryable(&error, NodeKind::File, StagingPhase::Writing));
        }
    }
    #[test]
    fn sibling_cancellation_is_distinct_from_failed_file_close_and_unknown_mutation() {
        let cancelled = RemoteTreeError::Copy(RemoteCopyError::Close {
            operation: Some(Box::new(TransferError::Cancelled.into())),
            source_close: Some(network()),
            destination_close: None,
        });
        assert!(cancelled_channel_cleanup(&cancelled));
        assert!(!channel_fault(&cancelled));
        assert!(!retryable(
            &cancelled,
            NodeKind::File,
            StagingPhase::Writing
        ));
        assert!(!cancelled_channel_cleanup(&RemoteTreeError::Copy(
            RemoteCopyError::Close {
                operation: Some(Box::new(TransferError::Cancelled.into())),
                source_close: Some(network()),
                destination_close: Some(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "synthetic CLOSE refusal"
                )),
            }
        )));
    }
}
