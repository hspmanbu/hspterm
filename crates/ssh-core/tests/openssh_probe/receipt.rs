use super::*;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn connection_receipts_keep_original_verified_key_and_generation_across_reconnect() {
    let first = Server::start().await;
    let second =
        Server::start_with_host_key(true, false, "rsa", "HostKeyAlgorithms rsa-sha2-512\n").await;
    let (session, mut events) = ManagedSession::new(Size::new(80, 24).unwrap(), 100).unwrap();
    let drain = tokio::spawn(async move { while events.recv().await.is_some() {} });
    let receipt = session
        .connect_verified(first.config.clone(), first.auth(), first.pinned())
        .await
        .unwrap();
    assert_eq!(receipt.generation, session.status().generation);
    assert_eq!(receipt.host_key.address, "127.0.0.1");
    assert_eq!(receipt.host_key.port, first.config.port);
    assert_eq!(receipt.host_key.sha256, first.fingerprint);
    assert_eq!(receipt.host_key.algorithm, "ssh-ed25519");
    assert_eq!(receipt.username, first.config.username);
    session.disconnect().await.unwrap();
    let next = session
        .connect_verified(second.config.clone(), second.auth(), second.pinned())
        .await
        .unwrap();
    assert!(next.generation > receipt.generation);
    assert_eq!(next.host_key.sha256, second.fingerprint);
    assert_eq!(next.host_key.algorithm, "ssh-rsa");
    assert_eq!(next.host_key.port, second.config.port);
    assert_eq!(receipt.host_key.sha256, first.fingerprint);
    assert_eq!(receipt.host_key.port, first.config.port);
    session
        .write(b"printf '%s%s\\n' RECEIPT_ CURRENT\n".to_vec())
        .await
        .unwrap();
    timeout(Duration::from_secs(5), async {
        let mut changes = session.subscribe_frames();
        while !session
            .snapshot()
            .unwrap()
            .text()
            .contains("RECEIPT_CURRENT")
        {
            changes.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
    session.shutdown();
    session.wait_closed().await;
    drain.await.unwrap();
}
