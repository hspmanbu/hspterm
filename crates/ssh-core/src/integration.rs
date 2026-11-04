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

/// Read-only capability probe on an explicitly opted-in, authenticated Root.
/// Unsupported command syntax/version or an explicitly denied exec falls back
/// to its normal request_shell; IO/timeout errors fail startup and retire Root.
pub(crate) async fn available(
    handle: &russh::client::Handle<crate::Client>,
    budget: &mut crate::budget::Budget,
) -> Result<bool, crate::SshError> {
    use crate::{SshError, Stage};
    use russh::ChannelMsg;
    let marker = format!("HSPTERM_BASH_V1_{:032x}", rand::random::<u128>());
    let probe = format!(
        "if [ -r /dev/fd/0 ] && command -v bash >/dev/null 2>&1; then bash --noprofile --norc -c '(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) ))' </dev/null && printf '\\n{marker}\\n'; fi"
    );
    budget
        .run(Stage::Shell, async {
            let mut channel = handle.channel_open_session_flow_controlled().await?;
            channel.exec(true, probe.as_bytes()).await?;
            let mut output = Vec::new();
            let mut count = 0usize;
            let mut accepted = false;
            let mut denied = false;
            let mut status = None;
            loop {
                match channel.wait().await {
                    Some(ChannelMsg::Success) if !accepted && !denied => accepted = true,
                    Some(ChannelMsg::Failure) if !accepted && !denied => {
                        denied = true;
                        channel.close().await?;
                    }
                    Some(ChannelMsg::Data { data }) => {
                        count = count.saturating_add(data.len());
                        if count > 4096 {
                            return Err(SshError::RequestDenied(Stage::Shell));
                        }
                        output.extend_from_slice(&data);
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        count = count.saturating_add(data.len());
                        if count > 4096 {
                            return Err(SshError::RequestDenied(Stage::Shell));
                        }
                        // Never retain/print stderr from the remote login shell.
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
                        // User login banners may precede the capability reply.
                        // Match one fresh, exact framed token, never log banners.
                        let framed = format!("\n{marker}\n");
                        return Ok(status == Some(0) && probe_reply(&output, &framed));
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
fn probe_reply(output: &[u8], framed: &str) -> bool {
    !framed.is_empty() && output.windows(framed.len()).any(|w| w == framed.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn capability_reply_tolerates_banner_but_requires_exact_fresh_frame() {
        let framed = "\nHSPTERM_BASH_V1_synthetic_fresh\n";
        assert!(probe_reply(
            b"synthetic banner\n\nHSPTERM_BASH_V1_synthetic_fresh\n",
            framed
        ));
        assert!(!probe_reply(b"HSPTERM_BASH_V1_old", framed));
        assert!(!probe_reply(
            b"\nHSPTERM_BASH_V1_synthetic_fresh_extra\n",
            framed
        ));
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
