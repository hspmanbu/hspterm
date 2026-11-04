//! Compile the exact vendored queue against the actual russh message type;
//! no copied queue/stub protocol. This avoids importing unrelated upstream
//! private-key fixtures/dev suites into the HSPTerm workspace test target.
use russh::ChannelMsg;
#[path = "../../../vendor/russh/src/channels/flow_control.rs"]
mod flow_control;
use bytes::Bytes;
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
};

fn next(receiver: &mut flow_control::FlowReceiver) -> Poll<Option<ChannelMsg>> {
    receiver.poll_recv(&mut Context::from_waker(Waker::noop()))
}
#[test]
fn tiny_packets_are_coalesced_within_the_byte_window_and_credit_only_tracks_consumption() {
    let (tx, mut rx) = flow_control::channel(128 * 1024);
    let credit = Arc::new(AtomicUsize::new(0));
    let count = credit.clone();
    rx.set_credit(move |n| {
        count.fetch_add(n, Ordering::Relaxed);
    });
    for _ in 0..128 * 1024 {
        assert!(
            tx.send(ChannelMsg::Data {
                data: Bytes::from_static(b"x")
            })
            .is_ok()
        );
    }
    let mut total = 0;
    let mut chunks = 0;
    while total < 128 * 1024 {
        let Poll::Ready(Some(ChannelMsg::Data { data })) = next(&mut rx) else {
            panic!("missing coalesced data")
        };
        assert!(data.iter().all(|b| *b == b'x'));
        total += data.len();
        chunks += 1;
        assert_eq!(credit.load(Ordering::Relaxed), total - data.len());
        rx.consumed(data.len());
    }
    assert!(
        chunks < 10,
        "one-byte packets must not create an unbounded message queue"
    );
    assert_eq!(credit.load(Ordering::Relaxed), total);
    assert!(next(&mut rx).is_pending());
}
#[test]
fn exceeding_byte_or_control_limits_is_an_explicit_error_instead_of_truncated_success() {
    let (tx, mut rx) = flow_control::channel(1024);
    assert!(
        tx.send(ChannelMsg::Data {
            data: Bytes::from(vec![7; 1025])
        })
        .is_err()
    );
    assert!(matches!(
        next(&mut rx),
        Poll::Ready(Some(ChannelMsg::ReceiveWindowError))
    ));
    assert!(matches!(next(&mut rx), Poll::Ready(None)));
    let (tx, mut rx) = flow_control::channel(1024);
    let mut rejected = false;
    for _ in 0..1024 {
        if tx.send(ChannelMsg::Success).is_err() {
            rejected = true;
            break;
        }
    }
    assert!(
        rejected,
        "control-only flooding must also have a finite bound"
    );
    assert!(matches!(
        next(&mut rx),
        Poll::Ready(Some(ChannelMsg::ReceiveWindowError))
    ));
}
#[test]
fn eof_close_and_sender_drop_preserve_all_preceding_bytes_and_reader_drop_rejects_new_data() {
    let (tx, mut rx) = flow_control::channel(1024);
    assert!(
        tx.send(ChannelMsg::Data {
            data: Bytes::from_static(b"payload")
        })
        .is_ok()
    );
    assert!(tx.send(ChannelMsg::Eof).is_ok());
    assert!(tx.send(ChannelMsg::Close).is_ok());
    drop(tx);
    let Poll::Ready(Some(ChannelMsg::Data { data })) = next(&mut rx) else {
        panic!()
    };
    assert_eq!(&data[..], b"payload");
    assert!(matches!(next(&mut rx), Poll::Ready(Some(ChannelMsg::Eof))));
    assert!(matches!(
        next(&mut rx),
        Poll::Ready(Some(ChannelMsg::Close))
    ));
    assert!(matches!(next(&mut rx), Poll::Ready(None)));
    let (tx, rx) = flow_control::channel(1024);
    drop(rx);
    assert!(
        tx.send(ChannelMsg::Data {
            data: Bytes::from_static(b"late")
        })
        .is_err()
    );
}
struct CountWake(AtomicUsize);
impl Wake for CountWake {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::Relaxed);
    }
}
#[test]
fn data_and_close_wake_an_idle_reader_without_polling() {
    let (tx, mut rx) = flow_control::channel(1024);
    let wake = Arc::new(CountWake(AtomicUsize::new(0)));
    let waker = Waker::from(wake.clone());
    assert!(rx.poll_recv(&mut Context::from_waker(&waker)).is_pending());
    assert!(
        tx.send(ChannelMsg::Data {
            data: Bytes::from_static(b"x")
        })
        .is_ok()
    );
    assert_eq!(wake.0.load(Ordering::Relaxed), 1);
    assert!(matches!(
        next(&mut rx),
        Poll::Ready(Some(ChannelMsg::Data { .. }))
    ));
    assert!(rx.poll_recv(&mut Context::from_waker(&waker)).is_pending());
    drop(tx);
    assert_eq!(wake.0.load(Ordering::Relaxed), 2);
    assert!(matches!(next(&mut rx), Poll::Ready(None)));
}
