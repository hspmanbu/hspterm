//! FIFO admission for top-level transfers: one directory consumes one slot.
//! No SSH ownership, reconnection, priorities or per-file task splitting.
use parking_lot::Mutex;
use std::{
    collections::{HashMap, VecDeque},
    sync::Arc,
};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

#[derive(Clone)]
pub struct TaskScheduler(Arc<Mutex<State>>);
struct Ticket {
    granted: bool,
    ready: Option<oneshot::Sender<()>>,
}
struct State {
    limit: usize,
    next: u64,
    active: usize,
    queue: VecDeque<u64>,
    tickets: HashMap<u64, Ticket>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SchedulerCounts {
    pub limit: usize,
    pub active: usize,
    pub waiting: usize,
}
#[derive(thiserror::Error, Debug, PartialEq, Eq)]
pub enum AdmissionError {
    #[error("传输等待已取消")]
    Cancelled,
    #[error("并发任务数必须在1到32之间")]
    InvalidLimit,
}
impl Default for TaskScheduler {
    fn default() -> Self {
        Self::new(3).expect("default concurrency is valid")
    }
}
impl TaskScheduler {
    pub fn new(limit: usize) -> Result<Self, AdmissionError> {
        if !(1..=32).contains(&limit) {
            return Err(AdmissionError::InvalidLimit);
        }
        Ok(Self(Arc::new(Mutex::new(State {
            limit,
            next: 1,
            active: 0,
            queue: VecDeque::new(),
            tickets: HashMap::new(),
        }))))
    }
    /// Assign order before asynchronous workers are polled.
    pub fn enqueue(&self) -> Admission {
        let (sender, ready) = oneshot::channel();
        let mut state = self.0.lock();
        let id = state.next;
        state.next = state
            .next
            .checked_add(1)
            .expect("transfer ticket identifier exhausted");
        state.tickets.insert(
            id,
            Ticket {
                granted: false,
                ready: Some(sender),
            },
        );
        state.queue.push_back(id);
        state.dispatch();
        Admission {
            scheduler: self.clone(),
            id,
            ready,
        }
    }
    /// Lower limits apply to new grants, without interrupting current tasks.
    pub fn set_limit(&self, limit: usize) -> Result<(), AdmissionError> {
        if !(1..=32).contains(&limit) {
            return Err(AdmissionError::InvalidLimit);
        }
        let mut state = self.0.lock();
        state.limit = limit;
        state.dispatch();
        Ok(())
    }
    pub fn counts(&self) -> SchedulerCounts {
        let state = self.0.lock();
        SchedulerCounts {
            limit: state.limit,
            active: state.active,
            waiting: state.tickets.len() - state.active,
        }
    }
}
impl State {
    fn dispatch(&mut self) {
        while self.active < self.limit {
            let Some(id) = self.queue.pop_front() else {
                break;
            };
            let Some(ticket) = self.tickets.get_mut(&id) else {
                continue;
            };
            ticket.granted = true;
            self.active += 1;
            if let Some(ready) = ticket.ready.take() {
                // The channel carries no permit/drop callback; no recursive lock.
                let _receiver_dropped = ready.send(());
            }
        }
    }
    fn release(&mut self, id: u64) {
        if let Some(ticket) = self.tickets.remove(&id)
            && ticket.granted
        {
            self.active -= 1;
        }
        self.dispatch();
        // Bound stale IDs even if all slots belong to long-running transfers.
        if self.queue.len() > self.tickets.len().saturating_mul(2).saturating_add(64) {
            self.queue.retain(|id| self.tickets.contains_key(id));
        }
    }
}
pub struct Admission {
    scheduler: TaskScheduler,
    id: u64,
    ready: oneshot::Receiver<()>,
}
pub struct TaskPermit {
    _admission: Admission,
}
impl Admission {
    pub async fn enter(mut self, stop: &CancellationToken) -> Result<TaskPermit, AdmissionError> {
        tokio::select! { biased;
            _ = stop.cancelled() => Err(AdmissionError::Cancelled),
            result = &mut self.ready => {
                result.map_err(|_| AdmissionError::Cancelled)?;
                Ok(TaskPermit { _admission: self })
            }
        }
    }
}
impl Drop for Admission {
    fn drop(&mut self) {
        self.scheduler.0.lock().release(self.id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::time::{Duration, timeout};
    #[tokio::test]
    async fn fifo_is_independent_of_worker_polling_order() {
        let scheduler = TaskScheduler::new(2).unwrap();
        let stop = CancellationToken::new();
        let a = scheduler.enqueue();
        let b = scheduler.enqueue();
        let c = scheduler.enqueue();
        let d = scheduler.enqueue();
        let mut d = Box::pin(d.enter(&stop));
        assert!(timeout(Duration::from_millis(10), &mut d).await.is_err());
        let a = a.enter(&stop).await.unwrap();
        let b = b.enter(&stop).await.unwrap();
        drop(a);
        let c = c.enter(&stop).await.unwrap();
        assert!(timeout(Duration::from_millis(10), &mut d).await.is_err());
        drop(c);
        let d = d.await.unwrap();
        assert_eq!(scheduler.counts().active, 2);
        drop((b, d));
        assert_eq!(
            scheduler.counts(),
            SchedulerCounts {
                limit: 2,
                active: 0,
                waiting: 0
            }
        );
    }
    #[tokio::test]
    async fn cancellation_drop_and_limit_changes_release_all_slots() {
        let scheduler = TaskScheduler::default();
        let stop = CancellationToken::new();
        let a = scheduler.enqueue().enter(&stop).await.unwrap();
        let b = scheduler.enqueue().enter(&stop).await.unwrap();
        let c = scheduler.enqueue().enter(&stop).await.unwrap();
        let cancelled = scheduler.enqueue();
        let waiting = scheduler.enqueue();
        let cancel = CancellationToken::new();
        cancel.cancel();
        assert!(matches!(
            cancelled.enter(&cancel).await,
            Err(AdmissionError::Cancelled)
        ));
        scheduler.set_limit(1).unwrap();
        drop((a, b));
        let mut waiting = Box::pin(waiting.enter(&stop));
        assert!(
            timeout(Duration::from_millis(10), &mut waiting)
                .await
                .is_err()
        );
        drop(c);
        let last = waiting.await.unwrap();
        assert_eq!(scheduler.counts().active, 1);
        for _ in 0..1000 {
            drop(scheduler.enqueue());
        }
        assert_eq!(scheduler.counts().waiting, 0);
        assert!(scheduler.0.lock().queue.len() <= 64);
        drop(last);
        assert_eq!(scheduler.counts().active, 0);
        assert!(scheduler.enqueue().enter(&cancel).await.is_err());
        assert_eq!(scheduler.counts().active, 0);
        assert!(scheduler.set_limit(0).is_err());
        assert!(TaskScheduler::new(33).is_err());
    }
}
