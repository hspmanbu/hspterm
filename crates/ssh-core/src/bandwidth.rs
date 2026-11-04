//! A shared, live-adjustable content-byte budget. One instance per direction
//! across all jobs; SSH transport/control traffic is deliberately not throttled.
use parking_lot::Mutex;
use std::{sync::Arc, time::Duration};
use tokio::{sync::watch, time::Instant};
use tokio_util::sync::CancellationToken;

const SECOND: u128 = 1_000_000_000;
const MAX_BLOCK: usize = 64 * 1024;
#[derive(Clone)]
pub struct BandwidthLimiter(Arc<Inner>);
struct Inner {
    state: Mutex<State>,
    changed: watch::Sender<()>,
}
struct State {
    rate: u64,
    // Fixed point byte-nanoseconds: low rates retain sub-byte credit.
    credit: u128,
    updated: Instant,
}
impl State {
    fn quantum(&self) -> usize {
        (self.rate / 10).clamp(1, MAX_BLOCK as u64) as usize
    }
    fn capacity(&self) -> u128 {
        self.quantum() as u128 * SECOND
    }
    fn refill(&mut self) {
        let now = Instant::now();
        self.credit = self
            .credit
            .saturating_add(
                now.duration_since(self.updated)
                    .as_nanos()
                    .saturating_mul(self.rate as u128),
            )
            .min(self.capacity());
        self.updated = now;
    }
}
impl Default for BandwidthLimiter {
    fn default() -> Self {
        Self::new(0)
    }
}
impl BandwidthLimiter {
    /// Zero means unlimited. The burst is at most 100ms (one byte at low
    /// rates), bounded to 64KiB. Idle time never accumulates an unbounded burst.
    pub fn new(bytes_per_second: u64) -> Self {
        let (changed, _) = watch::channel(());
        Self(Arc::new(Inner {
            state: Mutex::new(State {
                rate: bytes_per_second,
                credit: 0,
                updated: Instant::now(),
            }),
            changed,
        }))
    }
    /// Changes wake every blocked job, including when changing to unlimited.
    /// Existing credit is capped; raising a limit does not mint burst credit.
    pub fn set_rate(&self, bytes_per_second: u64) {
        let mut state = self.0.state.lock();
        state.refill();
        state.rate = bytes_per_second;
        state.credit = state.credit.min(state.capacity());
        state.updated = Instant::now();
        self.0.changed.send_replace(());
    }
    /// Grant up to `maximum` bytes before reading content. No future debt is
    /// reserved, so cancelling a waiter cannot stall unrelated tasks. Dropping
    /// after a grant can only waste this one bounded grant, never overspeed.
    /// None means cancelled. The caller must supply a positive maximum.
    pub async fn acquire(&self, maximum: usize, stop: &CancellationToken) -> Option<usize> {
        assert!(maximum > 0);
        let mut changed = self.0.changed.subscribe();
        loop {
            if stop.is_cancelled() {
                return None;
            }
            let wait = {
                let mut state = self.0.state.lock();
                if state.rate == 0 {
                    return Some(maximum.min(MAX_BLOCK));
                }
                state.refill();
                let wanted = maximum.min(state.quantum());
                let cost = wanted as u128 * SECOND;
                if state.credit >= cost {
                    state.credit -= cost;
                    return Some(wanted);
                }
                let nanos = (cost - state.credit).div_ceil(state.rate as u128);
                Duration::from_nanos(nanos.min(u64::MAX as u128) as u64)
            };
            tokio::select! { biased;
                _ = stop.cancelled() => return None,
                _ = changed.changed() => {},
                _ = tokio::time::sleep(wait) => {},
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test(start_paused = true)]
    async fn shared_budget_bounds_aggregate_and_idle_burst() {
        let limiter = BandwidthLimiter::new(1000);
        let stop = CancellationToken::new();
        let start = Instant::now();
        let mut workers = Vec::new();
        for _ in 0..3 {
            let limiter = limiter.clone();
            let stop = stop.clone();
            workers.push(tokio::spawn(async move {
                let mut total = 0;
                while total < 1000 {
                    total += limiter.acquire(1000 - total, &stop).await.unwrap();
                }
                total
            }));
        }
        for worker in workers {
            assert_eq!(worker.await.unwrap(), 1000);
        }
        assert!(start.elapsed() >= Duration::from_secs(3));
        tokio::time::advance(Duration::from_secs(3600)).await;
        assert_eq!(limiter.acquire(64000, &stop).await, Some(100));
        let start = Instant::now();
        assert_eq!(limiter.acquire(100, &stop).await, Some(100));
        assert!(start.elapsed() >= Duration::from_millis(100));
    }
    #[tokio::test(start_paused = true)]
    async fn live_changes_cancellation_low_rates_and_independent_directions() {
        let limiter = BandwidthLimiter::new(1);
        let cancelled = CancellationToken::new();
        let waiting = {
            let limiter = limiter.clone();
            let cancelled = cancelled.clone();
            tokio::spawn(async move { limiter.acquire(65536, &cancelled).await })
        };
        tokio::task::yield_now().await;
        cancelled.cancel();
        assert_eq!(waiting.await.unwrap(), None);
        let stop = CancellationToken::new();
        let start = Instant::now();
        assert_eq!(limiter.acquire(65536, &stop).await, Some(1));
        assert!(start.elapsed() >= Duration::from_secs(1));
        let waiting = {
            let limiter = limiter.clone();
            let stop = stop.clone();
            tokio::spawn(async move { limiter.acquire(65536, &stop).await })
        };
        tokio::task::yield_now().await;
        limiter.set_rate(0);
        assert_eq!(waiting.await.unwrap(), Some(65536));
        let download = BandwidthLimiter::new(2000);
        limiter.set_rate(1);
        let start = Instant::now();
        assert_eq!(download.acquire(200, &stop).await, Some(200));
        assert!(start.elapsed() < Duration::from_secs(1));
        tokio::time::advance(Duration::from_secs(3)).await;
        limiter.set_rate(1000);
        // A raised limit keeps at most the previous one byte of credit.
        let start = Instant::now();
        assert_eq!(limiter.acquire(100, &stop).await, Some(100));
        assert!(start.elapsed() >= Duration::from_millis(99));
    }
}
