//! One bounded ACK-based heartbeat per connected target, independent of PTY IO.
use crate::{Client, SshError};
use russh::client;
use std::{
    future::Future,
    sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    },
    time::Duration,
};
use tokio::{sync::watch, task::JoinHandle};
use tokio_util::sync::CancellationToken;

pub(crate) struct Heartbeat {
    failed: Arc<AtomicU8>,
    stop: CancellationToken,
    worker: Option<JoinHandle<()>>,
    latency: watch::Sender<Option<u64>>,
}
impl Heartbeat {
    pub fn start(
        handle: &Arc<client::Handle<Client>>,
        root: CancellationToken,
        interval: Option<Duration>,
        response: Option<Duration>,
        failures: usize,
    ) -> Self {
        let failed = Arc::new(AtomicU8::new(0));
        let (latency, _) = watch::channel(None);
        let stop = root.child_token();
        let worker = match (interval, response) {
            (Some(interval), Some(response)) => {
                let weak = Arc::downgrade(handle);
                let (root, stop, failed) = (root.clone(), stop.clone(), failed.clone());
                let latency = latency.clone();
                Some(tokio::spawn(async move {
                    // A failed/panicked monitor must not silently leave a live
                    // connection without its explicitly configured heartbeat.
                    let _close_on_exit = MonitorExit {
                        root: root.clone(),
                        cause: failed.clone(),
                    };
                    run(
                        interval,
                        response,
                        failures,
                        Signals {
                            root: &root,
                            stop: &stop,
                            failed: &failed,
                            latency: &latency,
                        },
                        move || {
                            let handle = weak.upgrade();
                            async move {
                                let handle = handle.ok_or(())?;
                                handle.send_ping_checked().await.map_err(|_| ())
                            }
                        },
                    )
                    .await;
                }))
            }
            _ => None,
        };
        Self {
            failed,
            stop,
            worker,
            latency,
        }
    }
    pub fn subscribe_latency(&self) -> watch::Receiver<Option<u64>> {
        self.latency.subscribe()
    }
    pub fn failure_or(&self, otherwise: SshError) -> SshError {
        match self.failed.load(Ordering::Acquire) {
            1 => SshError::HeartbeatTimeout,
            2 => SshError::Disconnected,
            3 => SshError::HeartbeatWorker,
            _ => otherwise,
        }
    }
    pub async fn shutdown(&mut self) -> Result<(), SshError> {
        self.stop.cancel();
        if let Some(worker) = self.worker.take() {
            worker.await.map_err(|_| SshError::HeartbeatWorker)?;
        }
        Ok(())
    }
}
impl Drop for Heartbeat {
    fn drop(&mut self) {
        self.stop.cancel();
        if let Some(worker) = self.worker.take() {
            worker.abort();
        }
    }
}
struct MonitorExit {
    root: CancellationToken,
    cause: Arc<AtomicU8>,
}
impl Drop for MonitorExit {
    fn drop(&mut self) {
        if std::thread::panicking() {
            self.cause.store(3, Ordering::Release);
        }
        self.root.cancel();
    }
}
fn publish_latency(sender: &watch::Sender<Option<u64>>, value: Option<u64>) {
    sender.send_if_modified(|old| {
        if *old == value {
            false
        } else {
            *old = value;
            true
        }
    });
}
struct LatencyReset(watch::Sender<Option<u64>>);
impl Drop for LatencyReset {
    fn drop(&mut self) {
        publish_latency(&self.0, None);
    }
}
struct Signals<'a> {
    root: &'a CancellationToken,
    stop: &'a CancellationToken,
    failed: &'a AtomicU8,
    latency: &'a watch::Sender<Option<u64>>,
}
async fn run<P, F>(
    interval: Duration,
    response: Duration,
    failures: usize,
    signals: Signals<'_>,
    mut probe: P,
) where
    P: FnMut() -> F,
    F: Future<Output = Result<(), ()>>,
{
    let Signals {
        root,
        stop,
        failed,
        latency,
    } = signals;
    let _reset = LatencyReset(latency.clone());
    let mut consecutive = 0usize;
    loop {
        tokio::select! {
            biased;
            _ = root.cancelled() => return,
            _ = stop.cancelled() => return,
            _ = tokio::time::sleep(interval) => {},
        }
        let started = tokio::time::Instant::now();
        let result = tokio::select! {
            biased;
            _ = root.cancelled() => return,
            _ = stop.cancelled() => return,
            result = tokio::time::timeout(response, probe()) => result,
        };
        match result {
            Ok(Ok(())) => {
                consecutive = 0;
                publish_latency(
                    latency,
                    Some(started.elapsed().as_micros().min(u64::MAX as u128) as u64),
                );
            }
            Ok(Err(())) => {
                publish_latency(latency, None);
                failed.store(2, Ordering::Release);
                return;
            }
            Err(_) => {
                publish_latency(latency, None);
                // Timed-out ping receivers can be dropped: the SSH global
                // request FIFO retains their senders and consumes late ACKs.
                // No more than `failures` such requests can accumulate before
                // this original root closes (validated 1..=100 by config).
                consecutive += 1;
                if consecutive >= failures {
                    failed.store(1, Ordering::Release);
                    root.cancel();
                    return;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    #[tokio::test(start_paused = true)]
    async fn response_deadline_is_independent_of_interval_and_only_completed_probes_reset_failures()
    {
        let root = CancellationToken::new();
        let stop = root.child_token();
        let failed = AtomicU8::new(0);
        let calls = AtomicUsize::new(0);
        let (latency, _) = watch::channel(None);
        let work = run(
            Duration::from_secs(30),
            Duration::from_secs(2),
            2,
            Signals {
                root: &root,
                stop: &stop,
                failed: &failed,
                latency: &latency,
            },
            || {
                let number = calls.fetch_add(1, Ordering::Relaxed);
                async move {
                    if number == 1 {
                        Ok(())
                    } else {
                        std::future::pending().await
                    }
                }
            },
        );
        tokio::time::timeout(Duration::from_secs(130), work)
            .await
            .unwrap();
        assert_eq!(calls.load(Ordering::Relaxed), 4);
        assert!(root.is_cancelled());
        assert_eq!(failed.load(Ordering::Acquire), 1);
    }
    #[tokio::test(start_paused = true)]
    async fn explicit_stop_cancels_an_inflight_probe_without_claiming_heartbeat_failure() {
        let root = CancellationToken::new();
        let stop = root.child_token();
        let failed = AtomicU8::new(0);
        let started = tokio::sync::Notify::new();
        let (latency, _) = watch::channel(None);
        let work = run(
            Duration::from_secs(1),
            Duration::from_secs(60),
            3,
            Signals {
                root: &root,
                stop: &stop,
                failed: &failed,
                latency: &latency,
            },
            || async {
                started.notify_one();
                std::future::pending().await
            },
        );
        let cancelling = async {
            started.notified().await;
            stop.cancel();
        };
        tokio::join!(work, cancelling);
        assert_eq!(failed.load(Ordering::Acquire), 0);
        assert!(!root.is_cancelled());
    }
}

#[cfg(test)]
mod latency_tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    #[tokio::test(start_paused = true)]
    async fn exact_ack_duration_is_published_and_normal_stop_retires_the_sample() {
        let root = CancellationToken::new();
        let stop = root.child_token();
        let failed = AtomicU8::new(0);
        let (samples, mut receiver) = watch::channel(None);
        let monitor = run(
            Duration::from_secs(1),
            Duration::from_secs(2),
            3,
            Signals {
                root: &root,
                stop: &stop,
                failed: &failed,
                latency: &samples,
            },
            || async {
                tokio::time::sleep(Duration::from_millis(37)).await;
                Ok(())
            },
        );
        let inspect = async {
            receiver.changed().await.unwrap();
            assert_eq!(*receiver.borrow_and_update(), Some(37000));
            stop.cancel();
        };
        tokio::join!(monitor, inspect);
        assert_eq!(*samples.borrow(), None);
        assert_eq!(failed.load(Ordering::Acquire), 0);
        assert!(!root.is_cancelled());
    }
    #[tokio::test(start_paused = true)]
    async fn first_timeout_clears_old_latency_before_the_disconnect_threshold() {
        let root = CancellationToken::new();
        let stop = root.child_token();
        let failed = AtomicU8::new(0);
        let calls = AtomicUsize::new(0);
        let (samples, mut receiver) = watch::channel(None);
        let monitor = run(
            Duration::from_secs(1),
            Duration::from_millis(100),
            3,
            Signals {
                root: &root,
                stop: &stop,
                failed: &failed,
                latency: &samples,
            },
            || {
                let first = calls.fetch_add(1, Ordering::Relaxed) == 0;
                async move {
                    if first {
                        tokio::time::sleep(Duration::from_millis(10)).await;
                        Ok(())
                    } else {
                        std::future::pending::<Result<(), ()>>().await
                    }
                }
            },
        );
        let inspect = async {
            receiver.changed().await.unwrap();
            assert_eq!(*receiver.borrow_and_update(), Some(10000));
            receiver.changed().await.unwrap();
            assert_eq!(*receiver.borrow_and_update(), None);
            assert!(!root.is_cancelled());
            assert_eq!(failed.load(Ordering::Acquire), 0);
            stop.cancel();
        };
        tokio::join!(monitor, inspect);
        assert_eq!(calls.load(Ordering::Relaxed), 2);
        assert!(!root.is_cancelled());
    }
}
