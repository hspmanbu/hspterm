//! HSPTerm: explicit local IO retirement. This is NOT a remote SSH CLOSE ACK.
use std::sync::Arc;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;
use super::error::Error;
const READ: u8 = 1;
const WRITE: u8 = 2;
#[derive(Clone)]
pub(crate) struct Completion(watch::Receiver<u8>);
pub(super) struct End {
    state: Arc<watch::Sender<u8>>,
    stop: CancellationToken,
    bit: u8,
}
pub(super) fn halves(stop: CancellationToken) -> (Completion, End, End) {
    let (state, ready) = watch::channel(0);
    let state = Arc::new(state);
    (Completion(ready),
        End { state: state.clone(), stop: stop.clone(), bit: READ },
        End { state, stop, bit: WRITE })
}
impl Drop for End {
    fn drop(&mut self) {
        self.stop.cancel();
        self.state.send_modify(|s| *s |= self.bit);
    }
}
impl Completion {
    pub(crate) fn is_closed(&self) -> bool {
        *self.0.borrow() & (READ | WRITE) == (READ | WRITE)
    }
    pub(crate) async fn wait(mut self) -> Result<(), Error> {
        loop {
            let flags = *self.0.borrow_and_update();
            if flags & (READ | WRITE) == (READ | WRITE) {
                return Ok(());
            }
            self.0.changed().await.map_err(|_| Error::ConnectionClosed)?;
        }
    }
}
