//! Memory relay for explicitly authorised remote-to-remote copies. The business
//! layer owns both session identities, policy, FIFO admission and checkpoints.
use super::*;
use russh_sftp::{client::fs::File, protocol::FileAttributes};
use zeroize::Zeroizing;

#[derive(Clone, Copy, Debug)]
pub enum RemoteCopyMode {
    CreateNew,
    Resume { offset: u64 },
}
/// Deliberately no truncating Overwrite mode: the owning task must stage an
/// explicitly authorised replacement before publishing it. Never erase a source
/// reached through another pathname/session on the same server.
#[derive(Error)]
pub enum RemoteCopyError {
    #[error(transparent)]
    Transfer(#[from] TransferError),
    #[error("远端复制文件读写失败；源文件及已写入的数据保留")]
    Io(#[from] io::Error),
    #[error("远端暂存副本的权限、类型或大小不满足安全发布要求")]
    InvalidStaging,
    #[error("发布已取消，服务器可能已替换目标；原始来源保留，请刷新确认")]
    PublishCancelled,
    #[error("无法确认远端复制或暂存路径")]
    Path(#[from] RemoteMoveError),
    #[error("SFTP远端复制操作失败")]
    Sftp(#[from] SftpError),
    #[error("远端复制文件关闭未确认；源文件及已写入数据保留，未报告完成")]
    Close {
        #[source]
        operation: Option<Box<RemoteCopyError>>,
        source_close: Option<io::Error>,
        destination_close: Option<io::Error>,
    },
}
impl std::fmt::Debug for RemoteCopyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(self, f)
    }
}
type CopyResult<T> = std::result::Result<T, RemoteCopyError>;
enum TargetPolicy {
    Ordinary(RemoteCopyMode),
    PrivateStaging(RemoteCopyMode),
    VerifiedSnapshotOverwrite { expected_bytes: u64 },
}

#[derive(Error)]
pub enum RemoteMoveError {
    #[error("移动路径无效；不能移动根目录或使用相对路径")]
    InvalidPath,
    #[error("目标已存在，未替换原有对象")]
    Conflict,
    #[error("不能将对象移动到自身，或将目录移动到其内部")]
    SelfMove,
    #[error("移动已取消，服务器可能已执行；请刷新源目录与目标目录确认")]
    Cancelled,
    #[error("SFTP移动失败，服务器未确认成功")]
    Sftp(#[from] SftpError),
}
impl std::fmt::Debug for RemoteMoveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(self, f)
    }
}
pub struct RemoteMoveResult {
    pub source: String,
    pub destination: String,
}
fn parts(value: &str) -> std::result::Result<(&str, &str), RemoteMoveError> {
    if !value.starts_with('/') || value.contains('\0') || value.len() > 131072 {
        return Err(RemoteMoveError::InvalidPath);
    }
    let (parent, name) = value.rsplit_once('/').ok_or(RemoteMoveError::InvalidPath)?;
    if name.is_empty() || name == "." || name == ".." {
        return Err(RemoteMoveError::InvalidPath);
    }
    Ok((if parent.is_empty() { "/" } else { parent }, name))
}
/// Canonicalize only an absolute object's parent and preserve its final name.
/// This read-only operation does not follow the final symlink or reserve/mutate
/// a path. Task owners must revalidate before any later destructive operation.
pub async fn object_path(
    sftp: &SftpSession,
    value: &str,
) -> std::result::Result<String, RemoteMoveError> {
    let (parent, name) = parts(value)?;
    let parent = sftp.canonicalize(parent).await?;
    if !parent.starts_with('/') || parent.contains('\0') || parent.len() > 131072 {
        return Err(RemoteMoveError::InvalidPath);
    }
    let attributes = sftp.symlink_metadata(&parent).await?;
    if !attributes.is_dir() || attributes.is_symlink() {
        return Err(RemoteMoveError::InvalidPath);
    }
    let path = format!("{}/{name}", parent.trim_end_matches('/'));
    if path.len() > 131072 {
        return Err(RemoteMoveError::InvalidPath);
    }
    Ok(path)
}
/// Resolve and check paths without renaming, removing or reserving any object.
/// The task persists these canonical parents and its mutation intent before
/// invoking move_remote_path, which still checks for a later target conflict.
pub async fn prepare_remote_move(
    sftp: &SftpSession,
    source: &str,
    destination: &str,
    stop: &CancellationToken,
) -> std::result::Result<RemoteMoveResult, RemoteMoveError> {
    parts(source)?;
    parts(destination)?;
    let work = async {
        let source = object_path(sftp, source).await?;
        let destination = object_path(sftp, destination).await?;
        let attributes = sftp.symlink_metadata(&source).await?;
        if source == destination
            || (attributes.is_dir()
                && !attributes.is_symlink()
                && destination
                    .strip_prefix(&source)
                    .is_some_and(|suffix| suffix.starts_with('/')))
        {
            return Err(RemoteMoveError::SelfMove);
        }
        match sftp.symlink_metadata(&destination).await {
            Ok(_) => return Err(RemoteMoveError::Conflict),
            Err(SftpError::Status(status)) if status.status_code == StatusCode::NoSuchFile => {}
            Err(error) => return Err(error.into()),
        }
        Ok(RemoteMoveResult {
            source,
            destination,
        })
    };
    tokio::select! { biased; _ = stop.cancelled() => Err(RemoteMoveError::Cancelled), result = work => result }
}

/// Rename the selected object on one existing SFTP session. Resolve parents,
/// never the final link itself. Ordinary rename preserves conflicts; no remove,
/// POSIX overwrite extension, shell command, chmod or automatic retry is used.
pub async fn move_remote_path(
    sftp: &SftpSession,
    source: &str,
    destination: &str,
    stop: &CancellationToken,
) -> std::result::Result<RemoteMoveResult, RemoteMoveError> {
    let prepared = prepare_remote_move(sftp, source, destination, stop).await?;
    tokio::select! { biased;
        _ = stop.cancelled() => Err(RemoteMoveError::Cancelled),
        result = sftp.rename(&prepared.source, &prepared.destination) => {
            result?;
            Ok(prepared)
        }
    }
}

async fn close(mut file: Option<File>) -> Option<io::Error> {
    match file.as_mut() {
        Some(file) => file.shutdown().await.err(),
        None => None,
    }
}
/// At most 64KiB of payload is held. READ prefetch is disabled and directional
/// budgets apply before actual reads/writes. A checkpoint advances only after
/// WRITE/flush ACK; both file CLOSE responses are required for completion.
#[allow(clippy::too_many_arguments)]
pub async fn copy_remote_file_limited(
    source_sftp: &SftpSession,
    source: &str,
    target_sftp: &SftpSession,
    destination: &str,
    mode: RemoteCopyMode,
    stop: &CancellationToken,
    upload: &BandwidthLimiter,
    download: &BandwidthLimiter,
    changed: impl FnMut(FileProgress),
) -> CopyResult<FileProgress> {
    copy_remote_file_inner(
        source_sftp,
        source,
        target_sftp,
        destination,
        TargetPolicy::Ordinary(mode),
        stop,
        upload,
        download,
        changed,
    )
    .await
}
/// The owning task persists the unique staging path before this call. Its new
/// file is requested as 0600 and verified before any source bytes are read.
#[allow(clippy::too_many_arguments)]
pub async fn stage_remote_file_limited(
    source_sftp: &SftpSession,
    source: &str,
    target_sftp: &SftpSession,
    destination: &str,
    mode: RemoteCopyMode,
    stop: &CancellationToken,
    upload: &BandwidthLimiter,
    download: &BandwidthLimiter,
    changed: impl FnMut(FileProgress),
) -> CopyResult<FileProgress> {
    copy_remote_file_inner(
        source_sftp,
        source,
        target_sftp,
        destination,
        TargetPolicy::PrivateStaging(mode),
        stop,
        upload,
        download,
        changed,
    )
    .await
}
#[allow(clippy::too_many_arguments)]
async fn copy_remote_file_inner(
    source_sftp: &SftpSession,
    source: &str,
    target_sftp: &SftpSession,
    destination: &str,
    policy: TargetPolicy,
    stop: &CancellationToken,
    upload: &BandwidthLimiter,
    download: &BandwidthLimiter,
    mut changed: impl FnMut(FileProgress),
) -> CopyResult<FileProgress> {
    let (mode, private, snapshot_overwrite, expected_snapshot) = match policy {
        TargetPolicy::Ordinary(mode) => (mode, false, false, None),
        TargetPolicy::PrivateStaging(mode) => (mode, true, false, None),
        TargetPolicy::VerifiedSnapshotOverwrite { expected_bytes } => (
            RemoteCopyMode::Resume { offset: 0 },
            false,
            true,
            Some(expected_bytes),
        ),
    };
    remote_path(source)?;
    remote_path(destination)?;
    if !source.starts_with('/') || !destination.starts_with('/') {
        return Err(TransferError::InvalidFile.into());
    }
    let mut source_file = None;
    let mut target_file = None;
    let work = async {
        let total = remote_size(source_sftp, source)
            .await?
            .ok_or(TransferError::InvalidFile)?;
        if expected_snapshot.is_some_and(|expected| expected != total) {
            return Err(RemoteCopyError::InvalidStaging);
        }
        let disposition = match mode {
            RemoteCopyMode::CreateNew => FileDisposition::CreateNew,
            RemoteCopyMode::Resume { offset } => FileDisposition::Resume { offset },
        };
        let existing = match target_sftp.symlink_metadata(destination).await {
            Ok(_) if !snapshot_overwrite && matches!(mode, RemoteCopyMode::CreateNew) => {
                return Err(TransferError::Conflict.into());
            }
            Ok(attrs) if attrs.is_regular() && !attrs.is_symlink() => {
                Some(attrs.size.ok_or(TransferError::InvalidFile)?)
            }
            Ok(_) => return Err(TransferError::InvalidFile.into()),
            Err(SftpError::Status(status)) if status.status_code == StatusCode::NoSuchFile => None,
            Err(error) => return Err(error.into()),
        };
        let start = if snapshot_overwrite {
            0
        } else {
            offset(disposition, total, existing)?
        };
        let mut reader = source_sftp.open(source).await?;
        reader.set_read_ahead(false);
        source_file = Some(reader);
        let flags = if snapshot_overwrite {
            OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE
        } else {
            match mode {
                RemoteCopyMode::CreateNew => {
                    OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::EXCLUDE
                }
                RemoteCopyMode::Resume { .. } => OpenFlags::WRITE,
            }
        };
        let attributes = if private {
            FileAttributes {
                permissions: Some(0o600),
                ..FileAttributes::default()
            }
        } else {
            FileAttributes::default()
        };
        target_file = Some(
            target_sftp
                .open_with_flags_and_attributes(destination, flags, attributes)
                .await?,
        );
        let reader = source_file.as_mut().expect("opened source");
        let writer = target_file.as_mut().expect("opened destination");
        if private {
            let attrs = writer.metadata().await?;
            if !attrs.is_regular()
                || attrs
                    .permissions
                    .is_none_or(|p| p & 0o077 != 0 || p & 0o600 != 0o600)
            {
                return Err(RemoteCopyError::InvalidStaging);
            }
        }
        if !snapshot_overwrite && matches!(mode, RemoteCopyMode::Resume { .. }) {
            let opened_size = writer.metadata().await?.size;
            if opened_size.is_none_or(|n| n < start || n > total) {
                return Err(TransferError::InvalidResume.into());
            }
        }
        reader.seek(io::SeekFrom::Start(start)).await?;
        writer.seek(io::SeekFrom::Start(start)).await?;
        let mut progress = FileProgress {
            acknowledged: start,
            total,
        };
        let mut buffer = Zeroizing::new(vec![0u8; BLOCK]);
        changed(progress);
        while progress.acknowledged < total {
            let maximum = (total - progress.acknowledged).min(BLOCK as u64) as usize;
            let length = download
                .acquire(maximum, stop)
                .await
                .ok_or(TransferError::Cancelled)?;
            let count = reader.read(&mut buffer[..length]).await?;
            if count == 0 {
                return Err(TransferError::UnexpectedEnd.into());
            }
            let mut written = 0;
            while written < count {
                let length = upload
                    .acquire(count - written, stop)
                    .await
                    .ok_or(TransferError::Cancelled)?;
                writer.write_all(&buffer[written..written + length]).await?;
                writer.flush().await?;
                written += length;
                progress.acknowledged += length as u64;
                changed(progress);
            }
        }
        if stop.is_cancelled() {
            return Err(TransferError::Cancelled.into());
        }
        writer.flush().await?;
        if writer.metadata().await?.size != Some(total) {
            return Err(TransferError::SizeMismatch.into());
        }
        Ok(progress)
    };
    let result: CopyResult<FileProgress> = tokio::select! { biased; _ = stop.cancelled() => Err(TransferError::Cancelled.into()), result = work => result };
    // Do not abandon CLOSE or remove partial files on cancellation. An owning
    // task also closes its two dedicated channels before confirming completion.
    let destination_close = close(target_file).await;
    let source_close = close(source_file).await;
    if source_close.is_some() || destination_close.is_some() {
        return Err(RemoteCopyError::Close {
            operation: result.err().map(Box::new),
            source_close,
            destination_close,
        });
    }
    if result.is_ok() && stop.is_cancelled() {
        return Err(TransferError::Cancelled.into());
    }
    result
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RemotePublishResult {
    Published,
    /// Existing target and no negotiated atomic replacement. Nothing renamed
    /// or removed. The task must choose an explicit snapshot-stream fallback.
    AtomicReplacementUnsupported,
}
/// Publish an owned, complete staging snapshot. The caller has persisted its
/// path and explicit overwrite choice; false capability is never success.
pub async fn publish_staged_remote_file(
    sftp: &SftpSession,
    staged: &str,
    destination: &str,
    expected_bytes: u64,
    overwrite: bool,
    stop: &CancellationToken,
) -> CopyResult<RemotePublishResult> {
    let work = async {
        let staged = object_path(sftp, staged).await?;
        let destination = object_path(sftp, destination).await?;
        if staged == destination {
            return Err(RemoteCopyError::InvalidStaging);
        }
        let attrs = sftp.symlink_metadata(&staged).await?;
        if !attrs.is_regular()
            || attrs.is_symlink()
            || attrs.size != Some(expected_bytes)
            || attrs
                .permissions
                .is_none_or(|p| p & 0o077 != 0 || p & 0o600 != 0o600)
        {
            return Err(RemoteCopyError::InvalidStaging);
        }
        let exists = match sftp.symlink_metadata(&destination).await {
            Ok(_) if !overwrite => return Err(TransferError::Conflict.into()),
            Ok(attrs) if attrs.is_regular() || attrs.is_symlink() => true,
            Ok(_) => return Err(TransferError::InvalidFile.into()),
            Err(SftpError::Status(status)) if status.status_code == StatusCode::NoSuchFile => false,
            Err(error) => return Err(error.into()),
        };
        if exists {
            if !sftp.posix_rename(&staged, &destination).await? {
                return Ok(RemotePublishResult::AtomicReplacementUnsupported);
            }
        } else {
            sftp.rename(&staged, &destination).await?;
        }
        let saved = sftp.symlink_metadata(&destination).await?;
        if !saved.is_regular() || saved.is_symlink() || saved.size != Some(expected_bytes) {
            return Err(TransferError::SizeMismatch.into());
        }
        Ok(RemotePublishResult::Published)
    };
    tokio::select! { biased; _ = stop.cancelled() => Err(RemoteCopyError::PublishCancelled), result = work => result }
}

/// Compatibility replacement from a complete, private snapshot on the target
/// server. The task invokes this only after an explicit overwrite choice and
/// capability fallback. The original source was captured before truncation;
/// errors/cancellation retain the complete staging snapshot for a manual retry.
/// This does not follow destination symlinks and does not delete the snapshot.
#[allow(clippy::too_many_arguments)]
pub async fn overwrite_from_staged_remote_file(
    sftp: &SftpSession,
    staged: &str,
    destination: &str,
    expected_bytes: u64,
    stop: &CancellationToken,
    upload: &BandwidthLimiter,
    download: &BandwidthLimiter,
    changed: impl FnMut(FileProgress),
) -> CopyResult<FileProgress> {
    let check = async {
        let staged = object_path(sftp, staged).await?;
        let destination = object_path(sftp, destination).await?;
        if staged == destination {
            return Err(RemoteCopyError::InvalidStaging);
        }
        let attrs = sftp.symlink_metadata(&staged).await?;
        if !attrs.is_regular()
            || attrs.is_symlink()
            || attrs.size != Some(expected_bytes)
            || attrs
                .permissions
                .is_none_or(|p| p & 0o077 != 0 || p & 0o600 != 0o600)
        {
            return Err(RemoteCopyError::InvalidStaging);
        }
        Ok((staged, destination))
    };
    let (staged, destination) = tokio::select! { biased; _ = stop.cancelled() => return Err(TransferError::Cancelled.into()), value = check => value }?;
    copy_remote_file_inner(
        sftp,
        &staged,
        sftp,
        &destination,
        TargetPolicy::VerifiedSnapshotOverwrite { expected_bytes },
        stop,
        upload,
        download,
        changed,
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn moving_requires_an_absolute_named_object_and_never_a_root_or_parent_entry() {
        for invalid in [
            "",
            "/",
            "relative",
            "/dir/",
            "/dir/.",
            "/dir/..",
            "/bad\0path",
        ] {
            assert!(parts(invalid).is_err());
        }
        let path = "/directory 中文/a ' $;\n\\literal.txt";
        let (parent, name) = parts(path).unwrap();
        assert_eq!(format!("{parent}/{name}"), path);
    }
}
