//! HSPTerm opt-in per-channel receive window. See HSPTERM_PATCH.md.
//! Data is bounded by the advertised byte window and coalesced into 64KiB
//! pieces; an unread stream never blocks the shared SSH packet dispatcher.
#![deny(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic
)]
use super::ChannelMsg;
use bytes::BytesMut;
use futures::task::AtomicWaker;
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
    task::{Context, Poll},
};

const PIECE: usize = 64 * 1024;
const ITEMS: usize = 128;
enum Item {
    Data { bytes: BytesMut, ext: Option<u32> },
    Control(ChannelMsg),
}
struct State {
    queue: VecDeque<Item>,
    bytes: usize,
    reader_closed: bool,
    sender_closed: bool,
    failed: bool,
    error_sent: bool,
}
struct Shared {
    state: Mutex<State>,
    wake: AtomicWaker,
    limit: usize,
}
impl Shared {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poison| {
            // A poisoned invariant must fail the stream explicitly, not resume
            // with potentially corrupt byte accounting or panic the dispatcher.
            let mut state = poison.into_inner();
            state.failed = true;
            state.queue.clear();
            state.bytes = 0;
            state
        })
    }
}
pub(crate) struct FlowSender(Arc<Shared>);
pub(crate) struct FlowReceiver {
    shared: Arc<Shared>,
    credit: Option<Box<dyn Fn(usize) + Send + Sync>>,
}
impl std::fmt::Debug for FlowSender {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("FlowSender(<bounded>)")
    }
}
pub(crate) fn channel(limit: usize) -> (FlowSender, FlowReceiver) {
    let shared = Arc::new(Shared {
        limit,
        wake: AtomicWaker::new(),
        state: Mutex::new(State {
            queue: VecDeque::new(),
            bytes: 0,
            reader_closed: false,
            sender_closed: false,
            failed: false,
            error_sent: false,
        }),
    });
    (
        FlowSender(shared.clone()),
        FlowReceiver {
            shared,
            credit: None,
        },
    )
}
impl FlowSender {
    pub fn send(&self, message: ChannelMsg) -> Result<(), ChannelMsg> {
        let mut state = self.0.lock();
        if state.reader_closed || state.failed {
            drop(state);
            self.0.wake.wake();
            return Err(message);
        }
        // Informational only; WindowSizeRef has already been updated separately.
        if matches!(message, ChannelMsg::WindowAdjusted { .. }) {
            return Ok(());
        }
        let (data, ext) = match &message {
            ChannelMsg::Data { data } => (Some(data.clone()), None),
            ChannelMsg::ExtendedData { data, ext } => (Some(data.clone()), Some(*ext)),
            _ => (None, None),
        };
        if let Some(mut data) = data {
            if data.len() > self.0.limit.saturating_sub(state.bytes) {
                state.failed = true;
            } else {
                state.bytes += data.len();
                while !data.is_empty() {
                    if let Some(Item::Data {
                        bytes,
                        ext: old_ext,
                    }) = state.queue.back_mut()
                        && *old_ext == ext
                        && bytes.len() < PIECE
                    {
                        let count = (PIECE - bytes.len()).min(data.len());
                        bytes.extend_from_slice(&data.split_to(count));
                    } else {
                        if state.queue.len() >= ITEMS {
                            state.failed = true;
                            break;
                        }
                        let count = data.len().min(PIECE);
                        let mut bytes = BytesMut::with_capacity(count.max(1024));
                        bytes.extend_from_slice(&data.split_to(count));
                        state.queue.push_back(Item::Data { bytes, ext });
                    }
                }
            }
            if state.failed {
                state.queue.clear();
                state.bytes = 0;
                drop(state);
                self.0.wake.wake();
                return Err(message);
            }
        } else {
            if state.queue.len() >= ITEMS {
                state.failed = true;
                state.queue.clear();
                state.bytes = 0;
                drop(state);
                self.0.wake.wake();
                return Err(message);
            }
            state.queue.push_back(Item::Control(message));
        }
        drop(state);
        self.0.wake.wake();
        Ok(())
    }
}
impl Drop for FlowSender {
    fn drop(&mut self) {
        self.0.lock().sender_closed = true;
        self.0.wake.wake();
    }
}
impl FlowReceiver {
    pub fn set_credit(&mut self, credit: impl Fn(usize) + Send + Sync + 'static) {
        self.credit = Some(Box::new(credit));
    }
    pub fn consumed(&self, count: usize) {
        if count != 0
            && let Some(credit) = &self.credit
        {
            credit(count);
        }
    }
    pub fn close(&mut self) {
        let mut state = self.shared.lock();
        state.reader_closed = true;
        state.queue.clear();
        state.bytes = 0;
    }
    pub fn poll_recv(&mut self, cx: &mut Context<'_>) -> Poll<Option<ChannelMsg>> {
        self.shared.wake.register(cx.waker());
        let mut state = self.shared.lock();
        if state.failed && !state.error_sent {
            state.error_sent = true;
            return Poll::Ready(Some(ChannelMsg::ReceiveWindowError));
        }
        if state.failed || state.reader_closed {
            return Poll::Ready(None);
        }
        if let Some(item) = state.queue.pop_front() {
            return Poll::Ready(Some(match item {
                Item::Control(message) => message,
                Item::Data { bytes, ext } => {
                    state.bytes -= bytes.len();
                    match ext {
                        Some(ext) => ChannelMsg::ExtendedData {
                            data: bytes.freeze(),
                            ext,
                        },
                        None => ChannelMsg::Data {
                            data: bytes.freeze(),
                        },
                    }
                }
            }));
        }
        if state.sender_closed {
            Poll::Ready(None)
        } else {
            Poll::Pending
        }
    }
}
impl Drop for FlowReceiver {
    fn drop(&mut self) {
        self.close();
    }
}
