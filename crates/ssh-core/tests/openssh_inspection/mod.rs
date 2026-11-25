use super::*;
mod late;
struct DisposableProcess(Child);
impl Drop for DisposableProcess {
    fn drop(&mut self) {
        if matches!(self.0.try_wait(), Ok(None)) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_inspection_preserves_pty_and_only_signals_the_disposable_original_process() {
    let server = Server::start().await;
    let mut connection = server.connect().await;
    let inspector = connection.inspector().unwrap();
    let sample = inspector.sample(CancellationToken::new()).await.unwrap();
    assert!(sample.memory_total > 0);
    assert!(
        sample
            .cpu_iowait
            .is_some_and(|wait| wait <= sample.cpu_idle)
    );
    let mut child = DisposableProcess(
        Command::new("sleep")
            .arg("60")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let list = inspector.processes(CancellationToken::new()).await.unwrap();
    assert!(
        list.can_signal,
        "fixture requires Linux pidfd and Python signal.pidfd_send_signal"
    );
    let process = list
        .processes
        .iter()
        .find(|row| row.pid == child.0.id())
        .expect("private disposable process must be present in bounded fixture list");
    let mut wrong = process.clone();
    wrong.start += 1;
    assert!(matches!(
        inspector
            .terminate(&wrong, &list.boot, CancellationToken::new())
            .await,
        Err(SshError::Inspection(
            hspterm_ssh_core::inspection::InspectionError::Unavailable
        ))
    ));
    assert!(
        child.0.try_wait().unwrap().is_none(),
        "identity mismatch must not signal the fixture"
    );
    inspector
        .terminate(process, &list.boot, CancellationToken::new())
        .await
        .unwrap();
    timeout(Duration::from_secs(5), async {
        while child.0.try_wait().unwrap().is_none() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    connection
        .write(b"printf '%s%s\\n' inspection- pty-alive\n")
        .await
        .unwrap();
    let mut terminal = Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap();
    until_text(&mut connection, &mut terminal, "inspection-pty-alive").await;
    let cancelled = CancellationToken::new();
    cancelled.cancel();
    assert!(inspector.sample(cancelled).await.is_err());
    connection.close().await.unwrap();
    assert!(
        inspector.sample(CancellationToken::new()).await.is_err(),
        "capability cannot follow a new Transport"
    );
}
