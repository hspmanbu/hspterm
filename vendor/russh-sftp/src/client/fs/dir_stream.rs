//! Page-at-a-time directory enumeration; no speculative requests or full listing.
use crate::{
    client::{error::Error, rawsession::SftpResult, RawSftpSession},
    protocol::{File, StatusCode},
};
use std::sync::Arc;

pub struct ReadDirStream {
    pub(crate) session: Arc<RawSftpSession>,
    pub(crate) handle: Option<String>,
}
impl ReadDirStream {
    /// One SSH_FXP_READDIR response, bounded by the session's packet limit.
    /// Dot entries are returned as received; callers decide whether to ignore.
    /// EOF closes the handle and awaits acknowledgement. No hidden prefetch.
    pub async fn next_page(&mut self) -> SftpResult<Option<Vec<File>>> {
        let Some(handle) = &self.handle else {
            return Ok(None);
        };
        match self.session.readdir(handle.as_str()).await {
            Ok(name) => Ok(Some(name.files)),
            Err(Error::Status(status)) if status.status_code == StatusCode::Eof => {
                self.close().await?;
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }
    /// Explicit early close, propagating server errors. Once CLOSE is sent the
    /// handle is invalid, even when its acknowledgement is lost.
    pub async fn close(&mut self) -> SftpResult<()> {
        if let Some(handle) = self.handle.take() {
            self.session.close(handle).await?;
        }
        Ok(())
    }
}
impl Drop for ReadDirStream {
    fn drop(&mut self) {
        // Same best-effort fallback as File::drop; explicit close/EOF is needed
        // when the caller needs the server acknowledgement.
        if let Some(handle) = self.handle.take() {
            let _ = self.session.close_nowait(handle);
        }
    }
}
