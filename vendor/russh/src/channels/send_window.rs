//! Shared writer reservations, independent from dispatcher wire accounting.
use crate::Error;
use std::sync::Arc;
use tokio::sync::{Mutex, Notify};

#[derive(Clone, Debug)]
pub(crate) struct WindowSizeRef {
    pub(super) value: Arc<Mutex<u32>>,
    pub(super) notifier: Arc<Notify>,
}

impl WindowSizeRef {
    pub(crate) fn new(initial: u32) -> Self {
        let notifier = Arc::new(Notify::new());
        Self {
            value: Arc::new(Mutex::new(initial)),
            notifier,
        }
    }

    pub(crate) async fn update(&self, value: u32) {
        *self.value.lock().await = value;
        self.notifier.notify_one();
    }

    /// Flow-controlled writers have already reserved bytes in this shared
    /// credit, including messages still queued before the session dispatcher.
    /// Add only the peer's new credit; resetting to its current wire window
    /// would restore those reservations and over-send into global pending data.
    pub(crate) async fn grant(&self, amount: u32) -> Result<(), Error> {
        let mut value = self.value.lock().await;
        *value = value.checked_add(amount).ok_or(Error::Inconsistent)?;
        drop(value);
        self.notifier.notify_one();
        Ok(())
    }

    pub(crate) fn subscribe(&self) -> Arc<Notify> {
        Arc::clone(&self.notifier)
    }
}
