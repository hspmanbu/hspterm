//! Exact vendored writer credit implementation, tested under interleavings
//! between reservations, dispatcher sends and peer acknowledgements.
use russh::Error;
#[path = "../../../vendor/russh/src/channels/send_window.rs"]
mod send_window;
use send_window::WindowSizeRef;

#[tokio::test]
async fn peer_ack_preserves_reservations_which_are_not_yet_on_the_wire() {
    let window = WindowSizeRef::new(100);
    let writer = window.clone();
    let wake = writer.subscribe();
    // Two writers reserve 60 bytes; the session has dispatched only 20 of them.
    // The peer returns those 20. Its wire window is back to 100, while 40 bytes
    // remain queued. Resetting local credit to 100 would allocate 40 twice.
    *writer.value.lock().await -= 60;
    window.grant(20).await.unwrap();
    assert_eq!(*writer.value.lock().await, 60);
    wake.notified().await;
    // Dispatching the remaining reservations consumes no additional local
    // credit. The next peer ACK restores exactly the original full window.
    window.grant(40).await.unwrap();
    assert_eq!(*writer.value.lock().await, 100);
    // Invalid overflow cannot wrap or mutate the original credit.
    assert!(window.grant(u32::MAX).await.is_err());
    assert_eq!(*window.value.lock().await, 100);
    // Default channels retain their existing absolute-update behavior.
    window.update(7).await;
    assert_eq!(*writer.value.lock().await, 7);
}
