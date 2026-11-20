//! User-initiated PNG upload. No shell command, local shell, or X11 forwarding.
use crate::{
    SftpSession,
    bandwidth::BandwidthLimiter,
    transfer::{self, FileDisposition},
};
use russh_sftp::protocol::{FileAttributes, OpenFlags, StatusCode};
use std::path::Path;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_util::sync::CancellationToken;

pub const MAX_IMAGE_BYTES: u64 = 64 * 1024 * 1024;
#[derive(Debug, thiserror::Error)]
pub enum ImageUploadError {
    #[error("剪贴板图片须为不超过64MiB的普通PNG文件")]
    InvalidImage,
    #[error("剪贴板中没有图片，未上传")]
    EmptyClipboard,
    #[error("远端临时目录不安全，未上传图片")]
    UnsafeDirectory,
    #[error("图片上传已取消")]
    Cancelled,
    #[error("图片上传失败，远端临时文件清理未确认")]
    Cleanup,
    #[error(transparent)]
    Local(#[from] std::io::Error),
    #[error(transparent)]
    Remote(#[from] crate::SftpError),
    #[error(transparent)]
    Transfer(#[from] transfer::TransferError),
}
type Result<T> = std::result::Result<T, ImageUploadError>;
fn cancelled(stop: &CancellationToken) -> Result<()> {
    if stop.is_cancelled() {
        Err(ImageUploadError::Cancelled)
    } else {
        Ok(())
    }
}
fn missing(error: &crate::SftpError) -> bool {
    matches!(error, crate::SftpError::Status(s) if s.status_code == StatusCode::NoSuchFile)
}
/// `nonce` identifies the trusted upload request. Images use sequential,
/// exclusively created clipboardNNN.png names directly in the safe /tmp.
/// Existing files/symlinks are never opened, overwritten or cleaned up.
pub async fn upload(
    sftp: &SftpSession,
    source: &Path,
    nonce: &str,
    stop: &CancellationToken,
    limiter: &BandwidthLimiter,
) -> Result<String> {
    upload_observed(sftp, source, nonce, stop, limiter, |_, _| {}).await
}

pub async fn upload_observed(
    sftp: &SftpSession,
    source: &Path,
    nonce: &str,
    stop: &CancellationToken,
    limiter: &BandwidthLimiter,
    mut progress: impl FnMut(&str, transfer::FileProgress),
) -> Result<String> {
    if nonce.len() != 32 || !nonce.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(ImageUploadError::InvalidImage);
    }
    cancelled(stop)?;
    // A vanished source file is an empty clipboard read, not an IO failure:
    // report it as such so the caller can show the "no image" notice.
    let metadata = match tokio::fs::symlink_metadata(source).await {
        Ok(value) => value,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(ImageUploadError::EmptyClipboard);
        }
        Err(error) => return Err(error.into()),
    };
    if !metadata.is_file()
        || metadata.is_symlink()
        || !(8..=MAX_IMAGE_BYTES).contains(&metadata.len())
    {
        return Err(ImageUploadError::InvalidImage);
    }
    let mut local = tokio::fs::File::open(source).await?;
    let mut signature = [0; 8];
    local.read_exact(&mut signature).await?;
    if signature != *b"\x89PNG\r\n\x1a\n" {
        return Err(ImageUploadError::InvalidImage);
    }
    let parent = sftp.canonicalize("/tmp").await?;
    if !parent.starts_with('/') || parent.chars().any(char::is_control) {
        return Err(ImageUploadError::UnsafeDirectory);
    }
    let attrs = sftp.symlink_metadata(&parent).await?;
    let permissions = attrs.permissions.ok_or(ImageUploadError::UnsafeDirectory)?;
    if !attrs.is_dir()
        || attrs.is_symlink()
        || permissions & 0o022 != 0 && permissions & 0o1000 == 0
    {
        return Err(ImageUploadError::UnsafeDirectory);
    }
    cancelled(stop)?;
    let mut reserved = None;
    for number in 1..=4096 {
        cancelled(stop)?;
        let path = format!("{}/clipboard{number:03}.png", parent.trim_end_matches('/'));
        match sftp
            .open_with_flags_and_attributes(
                &path,
                OpenFlags::CREATE | OpenFlags::EXCLUDE | OpenFlags::WRITE,
                FileAttributes {
                    permissions: Some(0o600),
                    ..Default::default()
                },
            )
            .await
        {
            Ok(remote) => {
                reserved = Some((path, remote));
                break;
            }
            Err(error) => {
                // SFTP v3 may report EEXIST as generic Failure. Confirm a name
                // is occupied, but never follow it and never delete it.
                if sftp.symlink_metadata(&path).await.is_err() {
                    return Err(error.into());
                }
            }
        }
    }
    let (path, remote) = reserved.ok_or(ImageUploadError::UnsafeDirectory)?;
    let result = async {
        let mut remote = remote;
        let attrs = remote.metadata().await?;
        let safe = attrs.is_regular()
            && !attrs.is_symlink()
            && attrs.permissions.is_some_and(|p| p & 0o777 == 0o600);
        remote.shutdown().await?;
        if !safe {
            return Err(ImageUploadError::UnsafeDirectory);
        }
        progress(
            &path,
            transfer::FileProgress {
                acknowledged: 0,
                total: metadata.len(),
            },
        );
        transfer::upload_file_limited(
            sftp,
            source,
            &path,
            FileDisposition::Resume { offset: 0 },
            stop,
            |value| progress(&path, value),
            limiter,
        )
        .await?;
        let current = sftp.symlink_metadata(&path).await?;
        if current.size != Some(metadata.len())
            || current.permissions.is_none_or(|p| p & 0o777 != 0o600)
        {
            return Err(ImageUploadError::InvalidImage);
        }
        cancelled(stop)?;
        Ok(path.clone())
    }
    .await;
    if result.is_err()
        && let Err(error) = sftp.remove_file(&path).await
        && !missing(&error)
    {
        return Err(ImageUploadError::Cleanup);
    }
    result
}
