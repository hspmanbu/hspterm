use crate::{SshError, Stage};
use std::{
    future::{Future, pending},
    time::Duration,
};
use tokio::{sync::watch, time::Instant};
use tokio_util::sync::CancellationToken;

pub(crate) struct Budget {
    remaining: Duration,
    paused: watch::Receiver<bool>,
    cancel: CancellationToken,
    pause_channel_closed: bool,
}
impl Budget {
    pub fn new(
        remaining: Duration,
        paused: watch::Receiver<bool>,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            remaining,
            paused,
            cancel,
            pause_channel_closed: false,
        }
    }
    pub async fn run<T>(
        &mut self,
        stage: Stage,
        future: impl Future<Output = Result<T, SshError>>,
    ) -> Result<T, SshError> {
        tokio::pin!(future);
        loop {
            let paused = !self.pause_channel_closed && *self.paused.borrow_and_update();
            let start = Instant::now();
            let deadline = async {
                if paused {
                    pending::<()>().await;
                } else {
                    tokio::time::sleep(self.remaining).await;
                }
            };
            let pause_change = async {
                if self.pause_channel_closed {
                    pending().await
                } else {
                    self.paused.changed().await
                }
            };
            tokio::select! {
                biased;
                _ = self.cancel.cancelled() => return Err(SshError::Cancelled),
                _ = deadline => return Err(SshError::Timeout(stage)),
                result = &mut future => {
                    if !paused { self.remaining = self.remaining.saturating_sub(start.elapsed()); }
                    return result;
                }
                changed = pause_change => {
                    if !paused { self.remaining = self.remaining.saturating_sub(start.elapsed()); }
                    // The pause watch is timing metadata, not the transport
                    // result. Its sender may drop before russh publishes a host
                    // key rejection/error through its JoinHandle. Keep awaiting
                    // that concrete result under the original cancel/deadline.
                    if changed.is_err() { self.pause_channel_closed = true; }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn closed_pause_metadata_preserves_concrete_failure_and_does_not_spin() {
        let (tx, rx) = watch::channel(false);
        let mut budget = Budget::new(Duration::from_millis(50), rx, CancellationToken::new());
        let rejected = budget
            .run(Stage::Handshake, async {
                drop(tx);
                // Model handler drop happening before its task publishes the error.
                tokio::task::yield_now().await;
                Err::<(), _>(SshError::HostKeyRejected)
            })
            .await;
        assert!(matches!(rejected, Err(SshError::HostKeyRejected)));
        let timed = tokio::time::timeout(
            Duration::from_secs(1),
            budget.run(Stage::Handshake, pending::<Result<(), SshError>>()),
        )
        .await
        .unwrap();
        assert!(matches!(timed, Err(SshError::Timeout(Stage::Handshake))));
    }
    #[tokio::test]
    async fn user_wait_does_not_consume_timeout_and_cancel_interrupts_it() {
        let (tx, rx) = watch::channel(true);
        let cancel = CancellationToken::new();
        let mut budget = Budget::new(Duration::from_millis(50), rx, cancel.clone());
        budget
            .run(Stage::Handshake, async {
                tokio::time::sleep(Duration::from_millis(120)).await;
                tx.send_replace(false);
                Ok(())
            })
            .await
            .unwrap();
        tx.send_replace(true);
        let other = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            other.cancel();
        });
        assert!(matches!(
            budget
                .run(Stage::Handshake, pending::<Result<(), SshError>>())
                .await,
            Err(SshError::Cancelled)
        ));
    }
}
