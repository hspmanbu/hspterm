//! Fixed, explicitly selected remote Bash startup. Not a generic custom-command
//! facility. No profile files are written and no local shell is created.
use zeroize::Zeroizing;

#[derive(Clone)]
pub struct Launch {
    nonce: Zeroizing<String>,
}
impl Launch {
    pub fn fresh() -> Self {
        let bytes: [u8; 32] = rand::random();
        Self {
            nonce: Zeroizing::new(bytes.iter().map(|b| format!("{b:02x}")).collect()),
        }
    }
    pub fn nonce(&self) -> &str {
        &self.nonce
    }
    pub fn command(&self) -> Zeroizing<String> {
        let script = Zeroizing::new(
            include_str!("integration/bash.bash").replace("@HSPTERM_NONCE@", &self.nonce),
        );
        // Requires a POSIX command entrypoint and Bash with /dev/fd. Unsupported
        // servers fail this explicit startup; never silently downgrade auth or
        // install a different shell/profile. The helper degrades if user Bash
        // settings cannot safely coexist with its scoped Readline hooks.
        Zeroizing::new(format!(
            "exec bash --noprofile --rcfile /dev/fd/3 -i 3<<'HSPTERM_BASH_V1'\n{}\nHSPTERM_BASH_V1\n",
            script.as_str()
        ))
    }
}

/// Read-only capability probe executed on the already-open interactive PTY
/// channel. Debian/Ubuntu attach PAM/MOTD login banners to the first session
/// channel that starts a command, so the probe must run where the banner
/// belongs: every byte the server prints (banner included) is relayed verbatim
/// into `early` for the terminal stream, and the probe script itself prints
/// nothing. The decision uses a distinctive exit status; unlike stdout markers,
/// a fresh process exit code has no replay window. Unsupported syntax/version
/// or an explicitly denied exec falls back to the normal request_shell;
/// IO/timeout errors fail startup and retire Root. The channel is spent either
/// way and the caller must open a fresh one for the real session.
pub(crate) async fn probe_on_pty(
    channel: &mut russh::Channel<crate::client::Msg>,
    budget: &mut crate::budget::Budget,
    early: &mut std::collections::VecDeque<Vec<u8>>,
) -> Result<bool, crate::SshError> {
    use crate::{SshError, Stage};
    use russh::ChannelMsg;
    let probe = PROBE_COMMAND;
    budget
        .run(Stage::Shell, async {
            channel.exec(true, probe.as_bytes()).await?;
            let mut buffered = 0usize;
            let mut accepted = false;
            let mut denied = false;
            let mut status: Option<u32> = None;
            loop {
                match channel.wait().await {
                    Some(ChannelMsg::Success) if !accepted && !denied => accepted = true,
                    Some(ChannelMsg::Failure) if !accepted && !denied => {
                        denied = true;
                        channel.close().await?;
                    }
                    Some(ChannelMsg::Data { data })
                    | Some(ChannelMsg::ExtendedData { data, .. }) => {
                        // Relay the remote login banner verbatim; the probe
                        // prints nothing itself, so this is exactly what a
                        // plain interactive login would have shown.
                        buffered += data.len();
                        if buffered > 1_048_576 {
                            return Err(SshError::RequestDenied(Stage::Shell));
                        }
                        early.push_back(data.to_vec());
                    }
                    Some(ChannelMsg::ExitStatus { exit_status }) if status.is_none() => {
                        status = Some(exit_status)
                    }
                    Some(ChannelMsg::Close) | None => {
                        channel.close().await?;
                        if denied {
                            return Ok(false);
                        }
                        if !accepted || status.is_none() {
                            return Err(SshError::RequestDenied(Stage::Shell));
                        }
                        return Ok(status == Some(CAPABLE_EXIT));
                    }
                    Some(
                        ChannelMsg::ReceiveWindowError
                        | ChannelMsg::OpenFailure(_)
                        | ChannelMsg::Success
                        | ChannelMsg::Failure
                        | ChannelMsg::ExitStatus { .. },
                    ) => {
                        return Err(SshError::RequestDenied(Stage::Shell));
                    }
                    _ => {}
                }
            }
        })
        .await
}
/// Distinctive success exit status; any other outcome means unavailable.
const CAPABLE_EXIT: u32 = 42;
/// The arithmetic check runs with its stderr discarded: the probe executes on
/// the interactive PTY, and anything the inner bash prints (including errors
/// on exotic shells) would land verbatim in the user's terminal.
const PROBE_COMMAND: &str = concat!(
    "if [ -r /dev/fd/0 ] && command -v bash >/dev/null 2>&1 ",
    "&& bash --noprofile --norc -c ",
    "'(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) ))' ",
    "</dev/null 2>/dev/null; then exit 42; fi\nexit 1\n"
);

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn probe_prints_nothing_and_decides_by_distinctive_exit_status_only() {
        // The script must not print: it runs on the interactive PTY channel and
        // its bytes are relayed verbatim into the terminal stream.
        assert!(!PROBE_COMMAND.contains("printf"));
        assert!(!PROBE_COMMAND.contains("echo"));
        assert!(PROBE_COMMAND.contains("exit 42"));
        assert!(PROBE_COMMAND.trim_end().ends_with("exit 1"));
        assert!(PROBE_COMMAND.contains("[ -r /dev/fd/0 ]"));
        assert!(PROBE_COMMAND.contains("BASH_VERSINFO[1] >= 1"));
        // A failing version check must never leak its shell diagnostics into
        // the interactive PTY stream.
        assert!(PROBE_COMMAND.contains("</dev/null 2>/dev/null"));
        // Only the distinctive status means capable; 0/1/127 are unavailable.
        assert_ne!(0, CAPABLE_EXIT);
        assert_ne!(1, CAPABLE_EXIT);
        assert_ne!(127, CAPABLE_EXIT);
        // The embedded arithmetic must stay syntactically balanced: an extra
        // parenthesis once made every probe fail with exit 2, silently
        // disabling the whole integration on all hosts.
        let check = PROBE_COMMAND
            .split("bash --noprofile --norc -c '")
            .nth(1)
            .and_then(|rest| rest.split("' </dev/null").next())
            .expect("probe script shape changed");
        assert!(check.starts_with("((") && check.trim_end().ends_with("))"));
        let opened = check.matches('(').count();
        let closed = check.matches(')').count();
        assert_eq!(opened, closed, "unbalanced probe arithmetic: {check}");
        // Where a local bash exists, syntax-check the entire probe script.
        if let Ok(status) = std::process::Command::new("bash")
            .args(["-n", "-c", PROBE_COMMAND])
            .status()
        {
            assert!(status.success(), "probe script fails bash -n");
        }
    }
    #[test]
    fn fresh_launches_have_distinct_fixed_size_tokens_and_no_custom_command_api() {
        let a = Launch::fresh();
        let b = Launch::fresh();
        assert_ne!(a.nonce(), b.nonce());
        assert_eq!(a.nonce().len(), 64);
        assert!(a.nonce().bytes().all(|byte| byte.is_ascii_hexdigit()));
        let command = a.command();
        assert!(command.starts_with("exec bash --noprofile --rcfile /dev/fd/3 -i"));
        assert!(!command.contains("@HSPTERM_NONCE@"));
        assert_eq!(command.matches(a.nonce()).count(), 1);
        assert!(!command.contains(".bashrc >"));
    }
}
