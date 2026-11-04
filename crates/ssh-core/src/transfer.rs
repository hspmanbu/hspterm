//! Bounded file streaming on an already authenticated SFTP channel.
//! No SSH reconnection, implicit overwrite, metadata preservation or file hashing.
use crate::{SftpSession, bandwidth::BandwidthLimiter};
use russh_sftp::{
    client::error::Error as SftpError,
    protocol::{OpenFlags, StatusCode},
};
use std::{future::Future, io, path::Path};
use thiserror::Error;
use tokio::{
    fs,
    io::{AsyncRead, AsyncReadExt, AsyncSeekExt, AsyncWrite, AsyncWriteExt},
};
use tokio_util::sync::CancellationToken;

const BLOCK: usize = 64 * 1024;
mod remote;
pub use remote::object_path;
pub use remote::{
    RemoteCopyError, RemoteCopyMode, RemoteMoveError, RemoteMoveResult, RemotePublishResult,
    copy_remote_file_limited, move_remote_path, overwrite_from_staged_remote_file,
    prepare_remote_move, publish_staged_remote_file, stage_remote_file_limited,
};

#[derive(Clone, Copy, Debug)]
pub enum FileDisposition {
    /// Refuse any existing destination, including a dangling symbolic link.
    CreateNew,
    /// Caller must have obtained the user's explicit conflict decision.
    Overwrite,
    /// Last acknowledged offset from the task's persisted checkpoint. Bytes
    /// beyond it may be rewritten after cancellation, never silently discarded.
    Resume { offset: u64 },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileProgress {
    pub acknowledged: u64,
    pub total: u64,
}
#[derive(Error)]
pub enum TransferError {
    #[error("传输已暂停或取消；已写入数据保留")]
    Cancelled,
    #[error("文件路径或文件类型不受支持")]
    InvalidFile,
    #[error("本地路径包含不支持的Windows名称、文件数据流或设备路径；未写入目标")]
    InvalidLocalPath,
    #[error("目标已存在，需明确处理同名冲突")]
    Conflict,
    #[error("断点偏移与文件大小不一致，未修改目标文件")]
    InvalidResume,
    #[error("源文件读取提前结束")]
    UnexpectedEnd,
    #[error("传输完成后的文件大小不一致")]
    SizeMismatch,
    #[error("本地文件读写失败")]
    Io(#[from] io::Error),
    #[error("远端文件关闭失败，未确认传输完成")]
    RemoteClose(#[source] io::Error),
    #[error("SFTP文件操作失败")]
    Remote(#[from] SftpError),
}
impl std::fmt::Debug for TransferError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(self, f)
    }
}
type Result<T> = std::result::Result<T, TransferError>;

async fn cancellable<T>(
    stop: &CancellationToken,
    work: impl Future<Output = Result<T>>,
) -> Result<T> {
    tokio::select! {
        biased;
        _ = stop.cancelled() => Err(TransferError::Cancelled),
        result = work => result,
    }
}
fn remote_path(path: &str) -> Result<()> {
    if path.is_empty() || path.contains('\0') || path.len() > 131072 {
        return Err(TransferError::InvalidFile);
    }
    Ok(())
}
fn offset(mode: FileDisposition, total: u64, existing: Option<u64>) -> Result<u64> {
    match mode {
        FileDisposition::CreateNew if existing.is_some() => Err(TransferError::Conflict),
        FileDisposition::Resume { offset }
            if existing.is_none_or(|len| len < offset || len > total) || offset > total =>
        {
            Err(TransferError::InvalidResume)
        }
        FileDisposition::Resume { offset } => Ok(offset),
        _ => Ok(0),
    }
}
async fn remote_size(sftp: &SftpSession, path: &str) -> Result<Option<u64>> {
    match sftp.symlink_metadata(path).await {
        Ok(a) if a.file_type().is_file() && !a.is_symlink() => {
            a.size.map(Some).ok_or(TransferError::InvalidFile)
        }
        Ok(_) => Err(TransferError::InvalidFile),
        Err(SftpError::Status(status)) if status.status_code == StatusCode::NoSuchFile => Ok(None),
        Err(error) => Err(error.into()),
    }
}
async fn local_size(path: &Path) -> Result<Option<u64>> {
    match fs::symlink_metadata(path).await {
        Ok(a) if a.is_file() && !a.is_symlink() => Ok(Some(a.len())),
        Ok(_) => Err(TransferError::InvalidFile),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}
fn no_follow(options: &mut fs::OpenOptions) {
    #[cfg(unix)]
    options.custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
    #[cfg(windows)]
    options.custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT);
}
fn regular_file(metadata: &std::fs::Metadata) -> Result<()> {
    if !metadata.is_file() || metadata.is_symlink() {
        return Err(TransferError::InvalidFile);
    }
    Ok(())
}

/// Callback is bounded, synchronous bookkeeping only; never log payloads.
/// A checkpoint advances only after the destination acknowledges the full block.
async fn stream(
    source: &mut (impl AsyncRead + Unpin),
    target: &mut (impl AsyncWrite + Unpin),
    mut progress: FileProgress,
    stop: &CancellationToken,
    changed: &mut impl FnMut(FileProgress),
    limiter: &BandwidthLimiter,
) -> Result<FileProgress> {
    let mut buffer = vec![0; BLOCK];
    changed(progress);
    while progress.acknowledged < progress.total {
        let length = (progress.total - progress.acknowledged).min(BLOCK as u64) as usize;
        let length = limiter
            .acquire(length, stop)
            .await
            .ok_or(TransferError::Cancelled)?;
        let read = cancellable(stop, async {
            Ok(source.read(&mut buffer[..length]).await?)
        })
        .await?;
        if read == 0 {
            return Err(TransferError::UnexpectedEnd);
        }
        cancellable(stop, async {
            target.write_all(&buffer[..read]).await?;
            target.flush().await?;
            Ok(())
        })
        .await?;
        progress.acknowledged += read as u64;
        changed(progress);
    }
    Ok(progress)
}

pub async fn upload_file(
    sftp: &SftpSession,
    source: &Path,
    destination: &str,
    mode: FileDisposition,
    stop: &CancellationToken,
    changed: impl FnMut(FileProgress),
) -> Result<FileProgress> {
    upload_file_limited(
        sftp,
        source,
        destination,
        mode,
        stop,
        changed,
        &BandwidthLimiter::default(),
    )
    .await
}

pub async fn upload_file_limited(
    sftp: &SftpSession,
    source: &Path,
    destination: &str,
    mode: FileDisposition,
    stop: &CancellationToken,
    mut changed: impl FnMut(FileProgress),
    limiter: &BandwidthLimiter,
) -> Result<FileProgress> {
    remote_path(destination)?;
    if !crate::local_path::supported(source) {
        return Err(TransferError::InvalidLocalPath);
    }
    cancellable(stop, async {
        let total = local_size(source)
            .await?
            .ok_or(TransferError::InvalidFile)?;
        let start = offset(mode, total, remote_size(sftp, destination).await?)?;
        let mut options = fs::OpenOptions::new();
        options.read(true);
        no_follow(&mut options);
        let mut source = options.open(source).await?;
        regular_file(&source.metadata().await?)?;
        let mut flags = OpenFlags::WRITE;
        match mode {
            FileDisposition::CreateNew => flags |= OpenFlags::CREATE | OpenFlags::EXCLUDE,
            FileDisposition::Overwrite => flags |= OpenFlags::CREATE | OpenFlags::TRUNCATE,
            FileDisposition::Resume { .. } => {}
        }
        let mut target = sftp.open_with_flags(destination, flags).await?;
        source.seek(io::SeekFrom::Start(start)).await?;
        target.seek(io::SeekFrom::Start(start)).await?;
        let progress = stream(
            &mut source,
            &mut target,
            FileProgress {
                acknowledged: start,
                total,
            },
            stop,
            &mut changed,
            limiter,
        )
        .await?;
        target.flush().await?;
        if target.metadata().await?.size != Some(total) {
            return Err(TransferError::SizeMismatch);
        }
        // Wait for the actual server CLOSE response before reporting completion.
        target
            .shutdown()
            .await
            .map_err(TransferError::RemoteClose)?;
        Ok(progress)
    })
    .await
}

pub async fn download_file(
    sftp: &SftpSession,
    source: &str,
    destination: &Path,
    mode: FileDisposition,
    stop: &CancellationToken,
    changed: impl FnMut(FileProgress),
) -> Result<FileProgress> {
    download_file_limited(
        sftp,
        source,
        destination,
        mode,
        stop,
        changed,
        &BandwidthLimiter::default(),
    )
    .await
}

pub async fn download_file_limited(
    sftp: &SftpSession,
    source: &str,
    destination: &Path,
    mode: FileDisposition,
    stop: &CancellationToken,
    mut changed: impl FnMut(FileProgress),
    limiter: &BandwidthLimiter,
) -> Result<FileProgress> {
    remote_path(source)?;
    if !crate::local_path::supported(destination) {
        return Err(TransferError::InvalidLocalPath);
    }
    cancellable(stop, async {
        let total = remote_size(sftp, source)
            .await?
            .ok_or(TransferError::InvalidFile)?;
        let start = offset(mode, total, local_size(destination).await?)?;
        let mut source = sftp.open(source).await?;
        // Budget actual SFTP READ requests, not only consumption of prefetched bytes.
        source.set_read_ahead(false);
        let mut options = fs::OpenOptions::new();
        options.write(true);
        no_follow(&mut options);
        match mode {
            FileDisposition::CreateNew => {
                options.create_new(true);
            }
            FileDisposition::Overwrite => {
                options.create(true);
            }
            FileDisposition::Resume { .. } => {}
        }
        let mut target = options.open(destination).await.map_err(|error| {
            if matches!(mode, FileDisposition::CreateNew)
                && error.kind() == io::ErrorKind::AlreadyExists
            {
                TransferError::Conflict
            } else {
                TransferError::Io(error)
            }
        })?;
        // Check the opened handle before truncation, including Windows reparse points.
        regular_file(&target.metadata().await?)?;
        if matches!(mode, FileDisposition::Overwrite) {
            target.set_len(0).await?;
        }
        source.seek(io::SeekFrom::Start(start)).await?;
        target.seek(io::SeekFrom::Start(start)).await?;
        let progress = stream(
            &mut source,
            &mut target,
            FileProgress {
                acknowledged: start,
                total,
            },
            stop,
            &mut changed,
            limiter,
        )
        .await?;
        target.flush().await?;
        target.sync_all().await?;
        if target.metadata().await?.len() != total {
            return Err(TransferError::SizeMismatch);
        }
        source
            .shutdown()
            .await
            .map_err(TransferError::RemoteClose)?;
        Ok(progress)
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        pin::Pin,
        task::{Context, Poll},
    };

    struct FlushFailure;
    impl AsyncWrite for FlushFailure {
        fn poll_write(
            self: Pin<&mut Self>,
            _: &mut Context<'_>,
            bytes: &[u8],
        ) -> Poll<io::Result<usize>> {
            Poll::Ready(Ok(bytes.len()))
        }
        fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Err(io::Error::other("controlled flush failure")))
        }
        fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn failed_flush_never_advances_the_acknowledged_checkpoint() {
        let mut progress = Vec::new();
        let result = stream(
            &mut &b"payload"[..],
            &mut FlushFailure,
            FileProgress {
                acknowledged: 0,
                total: 7,
            },
            &CancellationToken::new(),
            &mut |p| progress.push(p.acknowledged),
            &BandwidthLimiter::default(),
        )
        .await;
        assert!(matches!(result, Err(TransferError::Io(_))));
        assert_eq!(progress, [0]);
    }
    #[tokio::test]
    async fn early_eof_keeps_actual_progress_and_is_not_success() {
        let mut progress = Vec::new();
        let result = stream(
            &mut &b"short"[..],
            &mut tokio::io::sink(),
            FileProgress {
                acknowledged: 0,
                total: 20,
            },
            &CancellationToken::new(),
            &mut |p| progress.push(p.acknowledged),
            &BandwidthLimiter::default(),
        )
        .await;
        assert!(matches!(result, Err(TransferError::UnexpectedEnd)));
        assert_eq!(progress, [0, 5]);
    }
}
