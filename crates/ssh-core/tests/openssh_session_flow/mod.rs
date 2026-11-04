//! Actual OpenSSH: an unread PTY must not stop independent SFTP negotiation.
use super::*;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn unread_pty_output_cannot_block_sftp_and_all_bytes_survive_backpressure() {
    let server = Server::start().await;
    let mut connection = server.connect().await;
    let marker = server.dir.path().join("pty-flood-started");
    let source = format!(
        "import pathlib,sys; print('HSPTERM_'+'FLOW_START',flush=True); sys.stdout.buffer.write(b'F'*1572864); sys.stdout.buffer.flush(); pathlib.Path({}).write_text('ready'); sys.stdout.buffer.write(b'F'*(8388608-1572864)); sys.stdout.buffer.flush(); print('\\nHSPTERM_'+'FLOW_END',flush=True)",
        serde_json::to_string(marker.to_str().unwrap()).unwrap()
    );
    let quoted = format!("'{}'", source.replace('\'', "'\\''"));
    connection
        .write(format!("python3 -c {quoted}\n").as_bytes())
        .await
        .unwrap();
    timeout(Duration::from_secs(5), async {
        while !marker.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    // The producer has flushed 1.5MiB while the local PTY is entirely unread.
    // This barrier is observed via the disposable fixture filesystem, not by
    // draining the queue whose head-of-line blocking this test must expose.
    tokio::time::sleep(Duration::from_millis(100)).await;
    let sftp = timeout(Duration::from_secs(3), connection.open_sftp())
        .await
        .expect("unread PTY blocked independent SSH/SFTP channel negotiation")
        .unwrap();
    assert!(!sftp.canonicalize(".").await.unwrap().is_empty());
    sftp.close().await.unwrap();
    let mut output = Vec::new();
    let end = b"HSPTERM_FLOW_END";
    timeout(Duration::from_secs(15), async {
        loop {
            let previous = output.len();
            match connection.read().await.unwrap() {
                PtyEvent::Data(bytes) => output.extend(bytes),
                _ => panic!("fixture SSH ended before complete PTY output"),
            }
            assert!(output.len() < 9 * 1024 * 1024);
            if output[previous.saturating_sub(end.len())..]
                .windows(end.len())
                .any(|w| w == end)
            {
                break;
            }
        }
    })
    .await
    .unwrap();
    let start = b"HSPTERM_FLOW_START\r\n";
    let offset = output
        .windows(start.len())
        .position(|w| w == start)
        .unwrap()
        + start.len();
    assert!(
        output[offset..offset + 8 * 1024 * 1024]
            .iter()
            .all(|b| *b == b'F'),
        "PTY payload changed or bytes were lost"
    );
    assert!(output[offset + 8 * 1024 * 1024..].starts_with(b"\r\nHSPTERM_FLOW_END"));
    connection.close().await.unwrap();
}
