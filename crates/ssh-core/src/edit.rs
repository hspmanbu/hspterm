//! Bounded editor reads and explicit in-place saves on an authenticated channel.
//! Caller owns the encrypted draft and session identity. No reconnect or exec.
use crate::{SftpSession, bandwidth::BandwidthLimiter, transfer::FileProgress};
use russh_sftp::{
    client::{error::Error as SftpError, fs::File},
    protocol::{OpenFlags, StatusCode},
};
use std::{future::Future, io};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

#[derive(thiserror::Error)]
pub enum EditFileError {
    #[error("编辑传输已取消；远端保存若已开始可能部分写入，本机草稿应保留")]
    Cancelled,
    #[error("远端路径或文件类型不支持编辑")]
    InvalidFile,
    #[error("文件超过内置编辑器容量；未读取或截断文件内容")]
    Capacity,
    #[error("远端文件内容提前结束或写入后大小不一致")]
    Size,
    #[error("远端文件关闭失败，保存或读取未确认完成")]
    Close(#[source] io::Error),
    #[error("编辑传输失败，且远端文件关闭未确认；本机修改应保留")]
    FailedClose {
        #[source]
        operation: Box<EditFileError>,
        close: io::Error,
    },
    #[error("远端编辑文件读写失败")]
    Io(#[from] io::Error),
    #[error("SFTP编辑文件操作失败")]
    Sftp(#[from] SftpError),
}
impl std::fmt::Debug for EditFileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(self, f)
    }
}
type Result<T> = std::result::Result<T, EditFileError>;
pub struct ReadFile {
    pub path: String,
    pub bytes: Zeroizing<Vec<u8>>,
}
fn path(value: &str) -> Result<()> {
    if !value.starts_with('/') || value.contains('\0') || value.len() > 131072 {
        return Err(EditFileError::InvalidFile);
    }
    Ok(())
}
fn check_cancelled(stop: &CancellationToken) -> Result<()> {
    if stop.is_cancelled() {
        Err(EditFileError::Cancelled)
    } else {
        Ok(())
    }
}
async fn cancellable<T>(
    stop: &CancellationToken,
    work: impl Future<Output = Result<T>>,
) -> Result<T> {
    tokio::select! { biased; _ = stop.cancelled() => Err(EditFileError::Cancelled), value = work => value }
}
async fn close<T>(file: Option<File>, result: Result<T>) -> Result<T> {
    if let Some(mut file) = file {
        let closed = file.shutdown().await;
        match (result, closed) {
            (Ok(value), Ok(())) => Ok(value),
            (Ok(_), Err(e)) => Err(EditFileError::Close(e)),
            (Err(error), Ok(())) => Err(error),
            (Err(error), Err(close)) => Err(EditFileError::FailedClose {
                operation: Box::new(error),
                close,
            }),
        }
    } else {
        result
    }
}
/// A stream is complete only after the local writer flush and remote CLOSE.
/// The caller publishes its encrypted snapshot after the enclosing SFTP channel
/// also closes successfully. No data-sized allocation occurs in this function.
pub struct ReadStream {
    pub path: String,
    pub progress: FileProgress,
}
/// Resolve aliases only on explicit open and return the canonical save target.
/// Read-ahead is disabled before the first READ to preserve download limits.
pub async fn read_to_writer<W: AsyncWrite + Unpin>(
    sftp: &SftpSession,
    source: &str,
    writer: &mut W,
    limit: u64,
    stop: &CancellationToken,
    limiter: &BandwidthLimiter,
    progress: impl FnMut(FileProgress),
) -> Result<ReadStream> {
    read_into(
        sftp,
        source,
        writer,
        limit,
        stop,
        limiter,
        progress,
        |_, _| {},
    )
    .await
}
// The inline caller reserves the validated source size once; streaming writers
// do not allocate by file size. Both paths keep exactly the same wire protocol.
#[allow(clippy::too_many_arguments)]
async fn read_into<W: AsyncWrite + Unpin>(
    sftp: &SftpSession,
    source: &str,
    writer: &mut W,
    limit: u64,
    stop: &CancellationToken,
    limiter: &BandwidthLimiter,
    mut progress: impl FnMut(FileProgress),
    prepare: impl FnOnce(&mut W, u64),
) -> Result<ReadStream> {
    path(source)?;
    let mut opened = None;
    let result = cancellable(stop, async {
        let canonical = sftp.canonicalize(source).await?;
        path(&canonical)?;
        let attrs = sftp.symlink_metadata(canonical.clone()).await?;
        if !attrs.is_regular() || attrs.is_symlink() {
            return Err(EditFileError::InvalidFile);
        }
        let total = attrs.size.ok_or(EditFileError::InvalidFile)?;
        if total > limit {
            return Err(EditFileError::Capacity);
        }
        prepare(writer, total);
        let mut file = sftp.open(canonical.clone()).await?;
        file.set_read_ahead(false);
        opened = Some(file);
        let file = opened.as_mut().expect("opened file");
        let mut buffer = Zeroizing::new(vec![0; 64 * 1024]);
        let mut acknowledged = 0u64;
        progress(FileProgress {
            acknowledged,
            total,
        });
        while acknowledged < total {
            // Clamp in u64 before conversion, including on 32-bit Android.
            let maximum = (total - acknowledged).min(buffer.len() as u64) as usize;
            let length = limiter
                .acquire(maximum, stop)
                .await
                .ok_or(EditFileError::Cancelled)?;
            let count = file.read(&mut buffer[..length]).await?;
            if count == 0 {
                return Err(EditFileError::Size);
            }
            writer.write_all(&buffer[..count]).await?;
            acknowledged += count as u64;
            progress(FileProgress {
                acknowledged,
                total,
            });
        }
        check_cancelled(stop)?;
        writer.flush().await?;
        Ok(ReadStream {
            path: canonical,
            progress: FileProgress {
                acknowledged,
                total,
            },
        })
    })
    .await;
    close(opened, result).await
}
/// The inline editor retains its explicit memory limit. Larger files use the
/// streaming API rather than increasing this allocation or the Flutter payload.
pub async fn read_file(
    sftp: &SftpSession,
    source: &str,
    limit: usize,
    stop: &CancellationToken,
    limiter: &BandwidthLimiter,
    progress: impl FnMut(FileProgress),
) -> Result<ReadFile> {
    let mut bytes = Zeroizing::new(Vec::new());
    let read = read_into(
        sftp,
        source,
        &mut *bytes,
        limit as u64,
        stop,
        limiter,
        progress,
        |bytes, total| bytes.reserve_exact(total as usize),
    )
    .await?;
    Ok(ReadFile {
        path: read.path,
        bytes,
    })
}
async fn fill_source<R: AsyncRead + Unpin>(
    reader: &mut R,
    buffer: &mut [u8],
    last: bool,
) -> Result<()> {
    if let Err(error) = reader.read_exact(buffer).await {
        return Err(if error.kind() == io::ErrorKind::UnexpectedEof {
            EditFileError::Size
        } else {
            error.into()
        });
    }
    if last {
        let mut extra = Zeroizing::new([0u8; 1]);
        if reader.read(&mut *extra).await? != 0 {
            return Err(EditFileError::Size);
        }
    }
    Ok(())
}
/// Explicit in-place Save with bounded memory and source backpressure. A local
/// snapshot must be immutable and prevalidated before calling this function.
/// Short/long input is an error, never successful truncation. The first block is
/// read before OPEN/TRUNCATE, protecting the remote file from immediate local
/// failure. Later IO/cancellation can leave a partial remote file: keep the draft.
#[allow(clippy::too_many_arguments)]
pub async fn write_from_reader<R: AsyncRead + Unpin>(
    sftp: &SftpSession,
    destination: &str,
    reader: &mut R,
    total: u64,
    stop: &CancellationToken,
    limiter: &BandwidthLimiter,
    mut progress: impl FnMut(FileProgress),
) -> Result<FileProgress> {
    path(destination)?;
    let mut opened = None;
    let result = cancellable(stop, async {
        let mut buffer = Zeroizing::new(vec![0; 64 * 1024]);
        let first = total.min(buffer.len() as u64) as usize;
        fill_source(reader, &mut buffer[..first], total <= first as u64).await?;
        check_cancelled(stop)?;
        match sftp.symlink_metadata(destination).await {
            Ok(attrs) if attrs.is_regular() && !attrs.is_symlink() => {}
            Err(SftpError::Status(s)) if s.status_code == StatusCode::NoSuchFile => {}
            Ok(_) => return Err(EditFileError::InvalidFile),
            Err(e) => return Err(e.into()),
        }
        check_cancelled(stop)?;
        opened = Some(
            sftp.open_with_flags(
                destination,
                OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE,
            )
            .await?,
        );
        let file = opened.as_mut().expect("opened file");
        let mut acknowledged = 0u64;
        let mut available = first;
        progress(FileProgress {
            acknowledged,
            total,
        });
        while acknowledged < total {
            let mut sent = 0;
            while sent < available {
                let length = limiter
                    .acquire(available - sent, stop)
                    .await
                    .ok_or(EditFileError::Cancelled)?;
                file.write_all(&buffer[sent..sent + length]).await?;
                file.flush().await?;
                sent += length;
                acknowledged += length as u64;
                progress(FileProgress {
                    acknowledged,
                    total,
                });
            }
            let remaining = total - acknowledged;
            available = remaining.min(buffer.len() as u64) as usize;
            if remaining != 0 {
                fill_source(
                    reader,
                    &mut buffer[..available],
                    remaining == available as u64,
                )
                .await?;
            }
        }
        check_cancelled(stop)?;
        file.flush().await?;
        if file.metadata().await?.size != Some(total) {
            return Err(EditFileError::Size);
        }
        Ok(FileProgress {
            acknowledged,
            total,
        })
    })
    .await;
    close(opened, result).await
}
/// The explicit Save action authorizes replacement. No mtime/hash comparison,
/// external-change probe or reconnection. Caller retains the complete draft.
pub async fn write_file(
    sftp: &SftpSession,
    destination: &str,
    bytes: &[u8],
    stop: &CancellationToken,
    limiter: &BandwidthLimiter,
    progress: impl FnMut(FileProgress),
) -> Result<FileProgress> {
    write_from_reader(
        sftp,
        destination,
        &mut std::io::Cursor::new(bytes),
        bytes.len() as u64,
        stop,
        limiter,
        progress,
    )
    .await
}
