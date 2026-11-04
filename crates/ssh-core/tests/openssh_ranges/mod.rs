//! Real isolated SSH stream: distinguish local reflow from later shell redraw.
use super::*;

async fn drain(ssh: &mut SshConnection, terminal: &mut Terminal) {
    let deadline = tokio::time::Instant::now() + Duration::from_millis(250);
    loop {
        match tokio::time::timeout_at(deadline, ssh.read()).await {
            Ok(Ok(PtyEvent::Data(data))) => {
                terminal.feed(&data).unwrap();
                for event in terminal.take_events() {
                    if let alacritty_terminal::event::Event::PtyWrite(reply) = event {
                        ssh.write(reply.as_bytes()).await.unwrap();
                    }
                }
            }
            Ok(Ok(PtyEvent::ExitStatus(_))) => {}
            Err(_) => break,
            _ => panic!("disposable SSH ended during range fixture"),
        }
    }
}
async fn exercise(hold_output: bool) {
    let server = Server::start().await;
    let mut ssh = server.connect().await;
    let mut terminal = Terminal::new(Size::new(80, 24).unwrap(), 1000).unwrap();
    let command = r"printf '\033]133;A\007SYNTHETIC> \033]133;B\007fixture\r\n\033]133;C\007%s%s\r\n\033]133;D;7\007' RANGE_ 'READY中文é'";
    let ending = if hold_output {
        "; IFS= read -r hspterm_fixture_resume; exit\n"
    } else {
        "\n"
    };
    ssh.write(format!("{command}{ending}").as_bytes())
        .await
        .unwrap();
    until_text(&mut ssh, &mut terminal, "RANGE_READY中文é").await;
    drain(&mut ssh, &mut terminal).await;
    let id = terminal
        .command_ranges()
        .iter()
        .find(|r| r.exit_status == Some(7))
        .unwrap()
        .id;
    for columns in [23, 65, 17] {
        assert!(
            terminal.command_document(id).is_ok(),
            "before resize {columns}"
        );
        terminal.resize(Size::new(columns, 24).unwrap()).unwrap();
        assert!(
            terminal.command_document(id).is_ok(),
            "local reflow {columns}"
        );
        let range = terminal
            .command_ranges()
            .into_iter()
            .find(|range| range.id == id)
            .unwrap();
        ssh.resize(columns, 24).await.unwrap();
        drain(&mut ssh, &mut terminal).await;
        if terminal.command_document(id).is_err() {
            assert!(
                !hold_output,
                "quiescent output lost proof after resize {columns}"
            );
            let mut current = Vec::new();
            terminal
                .document()
                .unwrap()
                .export_range(range.start, range.end, &mut current)
                .unwrap();
            assert!(
                current != "RANGE_READY中文é\n".as_bytes(),
                "shell redraw revoked a proof while the same region was unchanged"
            );
            ssh.close().await.unwrap();
            return;
        }
    }
    ssh.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn command_ranges_survive_reflow_of_quiescent_real_ssh_output() {
    exercise(true).await;
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn actual_bash_redraw_retains_proof_or_rejects_an_overwritten_region() {
    // Bash versions/prompts differ: retention is valid only if output survived.
    // When proof is revoked, verify actual bytes in that region changed; never
    // weaken the terminal's row proofs to retain stale command-copy actions.
    exercise(false).await;
}
