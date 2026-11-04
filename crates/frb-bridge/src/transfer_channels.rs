//! A task, not its fallible worker Future, owns each actual SFTP session. A
//! retry must retire previous local IO first. This does NOT prove a peer CLOSE.
use anyhow::{Result, bail};
use futures_util::future::join_all;
use hspterm_ssh_core::{ManagedSession, SftpSession};
use parking_lot::Mutex;
use std::{future::Future, sync::Arc};
use tokio_util::sync::CancellationToken;

#[derive(Default)]
pub(crate) struct Channels {
    sessions: Mutex<Vec<Arc<SftpSession>>>,
}
impl Channels {
    fn adopt(&self, session: SftpSession) -> Arc<SftpSession> {
        let session = Arc::new(session);
        self.record(session.clone());
        session
    }
    #[cfg(test)]
    pub(crate) fn adopt_arc(&self, session: Arc<SftpSession>) -> Arc<SftpSession> {
        self.record(session.clone());
        session
    }
    fn record(&self, session: Arc<SftpSession>) {
        let mut sessions = self.sessions.lock();
        sessions.retain(|old| !old.local_io_closed());
        sessions.push(session);
    }
    /// Independent read-only queries close only their own subset. The task
    /// still retains every session until its actual local IO has retired.
    pub fn batch(&self) -> ChannelBatch<'_> {
        ChannelBatch {
            task: self,
            local: Channels::default(),
        }
    }
    pub async fn open(
        &self,
        session: &ManagedSession,
        generation: u64,
        stop: &CancellationToken,
    ) -> Result<Arc<SftpSession>> {
        Ok(self.adopt(session.open_sftp_with_retry(generation, stop).await?))
    }
    pub fn is_empty(&self) -> bool {
        let mut sessions = self.sessions.lock();
        sessions.retain(|session| !session.local_io_closed());
        sessions.is_empty()
    }
    async fn close_all(&self) -> Result<()> {
        if self.is_empty() {
            return Ok(());
        }
        // Clone only a bounded set of Arc handles, never remove an owner before
        // its real IO end. Cancellation/panic during a close retains the owner.
        let snapshot = self.sessions.lock().clone();
        let results = join_all(snapshot.into_iter().map(|session| async move {
            let closed = session.close().await;
            (session, closed)
        }))
        .await;
        let mut sessions = self.sessions.lock();
        for (session, closed) in results {
            if closed.is_ok() && session.local_io_closed() {
                sessions.retain(|old| !Arc::ptr_eq(old, &session));
            }
        }
        if !sessions.is_empty() {
            bail!("传输子通道本机收尾未确认；保留确认偏移，继续前必须先完成收尾");
        }
        Ok(())
    }
    pub async fn retire(&self) -> Result<()> {
        crate::public_errors::guard(self.close_all()).await
    }
    pub async fn supervise<T>(&self, work: impl Future<Output = Result<T>>) -> Result<T> {
        let result = crate::public_errors::guard(async {
            self.close_all().await?;
            work.await
        })
        .await;
        // Run cleanup on normal errors AND a caught worker panic, before FIFO
        // admission and the task's busy/finished barrier can be released.
        crate::public_errors::guard(self.close_all()).await?;
        result
    }
}

pub(crate) struct ChannelBatch<'a> {
    task: &'a Channels,
    local: Channels,
}
impl ChannelBatch<'_> {
    pub async fn open(
        &self,
        session: &ManagedSession,
        generation: u64,
        stop: &CancellationToken,
    ) -> Result<Arc<SftpSession>> {
        let opened = self.task.open(session, generation, stop).await?;
        self.local.record(opened.clone());
        Ok(opened)
    }
    pub async fn supervise<T>(&self, work: impl Future<Output = Result<T>>) -> Result<T> {
        self.local.supervise(work).await
    }
}

#[cfg(test)]
mod tests;
