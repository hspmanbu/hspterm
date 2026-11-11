//! Explicit remote tmux startup. No PTY text injection or saved custom command.
//! Runs before PTY startup on the authenticated original SSH connection.
//! Dedicated metadata commands and typed choices never edit a live shell/TUI.
use crate::{Client, SshError, Stage, budget::Budget};
use base64::{Engine, engine::general_purpose::STANDARD};
use russh::{ChannelMsg, client};
use std::collections::HashSet;
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

const MAX_OUTPUT: usize = 64 * 1024;
const MAX_SESSIONS: usize = 256;
const LIST: &str = r#"LC_ALL=C; export LC_ALL
command -v base64 >/dev/null 2>&1 && command -v tr >/dev/null 2>&1 || exit 126
rows=$(tmux -u list-sessions -F '#{pid} #{session_id} #{session_created} #{session_attached}') || exit 1
[ -n "$rows" ] || exit 1
printf '%s\n' "$rows" | while IFS=' ' read -r server id created attached extra; do
  [ -z "$extra" ] || exit 65
  printf '%s\t%s\t%s\t%s\t' "$server" "$id" "$created" "$attached"
  tmux -u display-message -p -t "$id:" '#{session_name}' | base64 | tr -d '\n'
  printf '\n'
done"#;

#[derive(Debug, thiserror::Error)]
pub enum TmuxError {
    #[error("tmux探测响应格式无效或超过容量；未附着")]
    Metadata,
    #[error("tmux会话选择无效或来自过期列表；未附着")]
    Selection,
    #[error("接管tmux控制端需要明确确认会分离其他客户端")]
    TakeoverConsent,
    #[error("tmux操作未收到完整成功响应")]
    Response,
    #[error(
        "服务器未向tmux新建通道提供已启用的Agent环境；未新建会话，可改用现有会话或关闭本次新建恢复"
    )]
    AgentEnvironment,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListingIssue {
    NotAvailable,
    UnsupportedVersion,
    ListUnavailable,
}
/// Metadata only. Names never become shell/tmux command arguments.
#[derive(Clone)]
pub struct Session {
    pub id: String,
    pub name: String,
    pub attached: u32,
    server_pid: u32,
    created: u64,
}
impl Session {
    /// IDs can be reused by a restarted server. A remembered attachment must
    /// match the authenticated server's fresh list, PID and creation time.
    pub fn same_identity(&self, other: &Self) -> bool {
        self.id == other.id && self.server_pid == other.server_pid && self.created == other.created
    }
    pub fn identity(&self) -> Identity {
        Identity {
            id: self.id.clone(),
            server_pid: self.server_pid,
            created: self.created,
        }
    }
    pub fn matches_identity(&self, identity: &Identity) -> bool {
        self.id == identity.id
            && self.server_pid == identity.server_pid
            && self.created == identity.created
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    id: String,
    server_pid: u32,
    created: u64,
}
#[derive(Clone)]
pub struct Listing {
    pub version: Option<String>,
    pub issue: Option<ListingIssue>,
    pub sessions: Vec<Session>,
}
#[derive(Clone)]
pub enum Choice {
    Cancel,
    /// An explicit alternative, never a fallback after a tmux failure.
    Shell,
    Create {
        name: String,
        lock_size: bool,
    },
    /// Explicitly create with a dedicated ACK carrying the new identity before
    /// PTY attachment. Cancellation after that ACK leaves the new session.
    CreateRemembered {
        name: String,
        lock_size: bool,
    },
    Attach {
        id: String,
        readonly: bool,
        takeover_confirmed: bool,
        lock_size: bool,
    },
}
pub struct Request {
    pub verified_host: crate::HostKey,
    pub username: String,
    pub columns: u16,
    pub rows: u16,
    pub listing: Listing,
    pub reply: oneshot::Sender<Choice>,
}
#[derive(Clone)]
pub struct Policy {
    pub requests: mpsc::Sender<Request>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TmuxState {
    pub readonly: bool,
    pub size_locked: bool,
}
pub(crate) struct Startup {
    /// None is the ordinary shell explicitly chosen, not failed tmux.
    pub command: Option<String>,
    pub lock_size: bool,
    pub readonly: bool,
    pub session: Option<Identity>,
    pub deferred_create: Option<String>,
}
struct Reply {
    output: Vec<u8>,
    status: u32,
}

/// Dedicated flow-controlled exec, bounded across stdout and stderr. Its owner
/// is connection startup: every error cancels the not-yet-published Root.
async fn exec(
    handle: &client::Handle<Client>,
    budget: &mut Budget,
    command: &str,
) -> Result<Reply, SshError> {
    exec_routed(handle, budget, command, None).await
}
async fn exec_routed(
    handle: &client::Handle<Client>,
    budget: &mut Budget,
    command: &str,
    agent_request: Option<bool>,
) -> Result<Reply, SshError> {
    budget
        .run(Stage::Tmux, async {
            let mut channel = handle.channel_open_session_flow_controlled().await?;
            if let Some(standard) = agent_request {
                if standard {
                    channel.agent_forward_standard(true).await?;
                } else {
                    channel.agent_forward(true).await?;
                }
                // OpenSSH can deny a duplicate connection-wide request while
                // still providing the existing socket. Other servers accept
                // forwarding per session. The command checks its own actual
                // socket environment before creating anything in either case.
                match channel.wait().await {
                    Some(ChannelMsg::Success | ChannelMsg::Failure) => {}
                    _ => return Err(TmuxError::Response.into()),
                }
            }
            channel.exec(true, command.as_bytes()).await?;
            let mut bytes = 0usize;
            let mut output = Vec::new();
            let mut status = None;
            let mut accepted = false;
            let mut events = 0u64;
            loop {
                events = events.wrapping_add(1);
                if events.is_multiple_of(64) {
                    tokio::task::yield_now().await;
                }
                match channel.wait().await {
                    Some(ChannelMsg::Success) => accepted = true,
                    Some(ChannelMsg::Failure | ChannelMsg::OpenFailure(_)) => {
                        return Err(TmuxError::Response.into());
                    }
                    Some(ChannelMsg::Data { data }) => {
                        bytes = bytes.checked_add(data.len()).ok_or(TmuxError::Metadata)?;
                        if bytes > MAX_OUTPUT {
                            return Err(TmuxError::Metadata.into());
                        }
                        output.extend_from_slice(&data);
                    }
                    Some(ChannelMsg::ExtendedData { data, .. }) => {
                        bytes = bytes.checked_add(data.len()).ok_or(TmuxError::Metadata)?;
                        if bytes > MAX_OUTPUT {
                            return Err(TmuxError::Metadata.into());
                        }
                        // Never expose/log remote stderr as connection diagnostics.
                    }
                    Some(ChannelMsg::ExitStatus { exit_status }) if status.is_none() => {
                        status = Some(exit_status)
                    }
                    Some(ChannelMsg::ExitStatus { .. } | ChannelMsg::ReceiveWindowError) => {
                        return Err(TmuxError::Response.into());
                    }
                    Some(ChannelMsg::Close) | None => {
                        if !accepted {
                            return Err(TmuxError::Response.into());
                        }
                        let status = status.ok_or(TmuxError::Response)?;
                        channel.close().await?;
                        return Ok(Reply { output, status });
                    }
                    _ => {}
                }
            }
        })
        .await
}

fn version(bytes: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(bytes).ok()?.trim();
    if text.len() > 64 || text.chars().any(char::is_control) {
        return None;
    }
    let number = text.strip_prefix("tmux ")?;
    let (major, minor) = number.split_once('.')?;
    let minor = minor.trim_end_matches(|c: char| c.is_ascii_alphabetic());
    let major: u32 = major.parse().ok()?;
    let minor: u32 = minor.parse().ok()?;
    if major < 3 || (major == 3 && minor < 2) {
        return None;
    }
    Some(text.to_owned())
}
fn valid_id(id: &str) -> bool {
    let Some(value) = id.strip_prefix('$') else {
        return false;
    };
    !value.is_empty()
        && value.len() <= 20
        && value.bytes().all(|b| b.is_ascii_digit())
        && value.parse::<u64>().is_ok()
}
/// Parse bounded discovery stdout. This validates metadata, not its SSH origin;
/// callers must still bind the result to the authenticated original Transport.
pub fn parse_sessions(bytes: &[u8]) -> Result<Vec<Session>, TmuxError> {
    if bytes.len() > MAX_OUTPUT {
        return Err(TmuxError::Metadata);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| TmuxError::Metadata)?;
    let mut sessions = Vec::new();
    let mut seen = HashSet::new();
    let mut server = None;
    for line in text.lines() {
        if sessions.len() >= MAX_SESSIONS {
            return Err(TmuxError::Metadata);
        }
        let fields: Vec<_> = line.split('\t').collect();
        if fields.len() != 5 || !valid_id(fields[1]) || !seen.insert(fields[1]) {
            return Err(TmuxError::Metadata);
        }
        let pid: u32 = fields[0].parse().map_err(|_| TmuxError::Metadata)?;
        if pid == 0 || server.is_some_and(|old| old != pid) {
            return Err(TmuxError::Metadata);
        }
        server = Some(pid);
        let created = fields[2].parse().map_err(|_| TmuxError::Metadata)?;
        let attached = fields[3].parse().map_err(|_| TmuxError::Metadata)?;
        if fields[4].len() > 2048 {
            return Err(TmuxError::Metadata);
        }
        let mut name = STANDARD
            .decode(fields[4])
            .map_err(|_| TmuxError::Metadata)?;
        if name.pop() != Some(b'\n') || name.is_empty() || name.len() > 1024 {
            return Err(TmuxError::Metadata);
        }
        let name = std::str::from_utf8(&name).map_err(|_| TmuxError::Metadata)?;
        // A literal rendering, never a command token or bidi-active UI label.
        let mut label = String::new();
        for c in name.chars() {
            if c.is_control()
                || matches!(c, '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
            {
                label.extend(c.escape_default());
            } else {
                label.push(c);
            }
        }
        sessions.push(Session {
            id: fields[1].to_owned(),
            name: label,
            attached,
            server_pid: pid,
            created,
        });
    }
    if sessions.is_empty() {
        return Err(TmuxError::Metadata);
    }
    Ok(sessions)
}
fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}
fn select(listing: &Listing, choice: Choice) -> Result<Startup, SshError> {
    let (command, lock_size, readonly, session) = match choice {
        Choice::Cancel => return Err(SshError::Cancelled),
        Choice::Shell => (None, false, false, None),
        Choice::Create { name, lock_size } | Choice::CreateRemembered { name, lock_size } => {
            if listing.version.is_none()
                || name.is_empty()
                || name.len() > 64
                || !name
                    .chars()
                    .all(|c| c.is_alphanumeric() || "_- ".contains(c))
                || name.trim() != name
            {
                return Err(TmuxError::Selection.into());
            }
            // Deliberately no -A: a concurrent same-name creation must fail,
            // never attach to an unselected existing session.
            (
                Some(format!("exec tmux -u new-session -s {}", quote(&name))),
                lock_size,
                false,
                None,
            )
        }
        Choice::Attach {
            id,
            readonly,
            takeover_confirmed,
            lock_size,
        } => {
            let session = listing
                .sessions
                .iter()
                .find(|s| s.id == id)
                .ok_or(TmuxError::Selection)?;
            if listing.issue.is_some() || !valid_id(&id) {
                return Err(TmuxError::Selection.into());
            }
            if !readonly && !takeover_confirmed {
                return Err(TmuxError::TakeoverConsent.into());
            }
            let action = format!(
                "attach-session {} -t {}",
                if readonly { "-r" } else { "-d" },
                quote(&id)
            );
            // Validate server PID and session creation timestamp inside tmux's
            // command queue before attach; do not check then blindly attach via
            // a second independent shell command. IDs/numbers are validated.
            let identity = session.identity();
            let command = guarded_attach_options(&identity, &action, readonly);
            (Some(command), lock_size, readonly, Some(identity))
        }
    };
    Ok(Startup {
        command,
        lock_size,
        readonly,
        session,
        deferred_create: None,
    })
}
fn guarded_attach(identity: &Identity, action: &str) -> String {
    guarded_attach_options(identity, action, false)
}
fn guarded_attach_options(identity: &Identity, action: &str, readonly: bool) -> String {
    let target = quote(&format!("{}:", identity.id));
    // Capability probe, not a version guess. Unknown options leave the original
    // attach untouched. Never change server defaults or a read-only session.
    let compatible = if readonly {
        action.to_owned()
    } else {
        let probe = format!("tmux show-window-options -t {target} pane-scrollbars >/dev/null 2>&1");
        let enabled = format!(
            "set-window-option -t {target} pane-scrollbars on ; set-window-option -t {target} pane-scrollbars-position right ; set-option -t {} mouse on ; {action}",
            quote(&identity.id)
        );
        format!(
            "if-shell {} {} {}",
            quote(&probe),
            quote(&enabled),
            quote(action)
        )
    };
    let condition = format!(
        "#{{&&:#{{==:#{{pid}},{}}},#{{==:#{{session_created}},{}}}}}",
        identity.server_pid, identity.created
    );
    format!(
        "exec tmux -u if-shell -F -t {} {} {} {}",
        quote(&format!("{}:", identity.id)),
        quote(&condition),
        quote(&compatible),
        quote(
            "display-message -p 'HSPTERM_TMUX_SELECTION_CHANGED: tmux会话已改变，请重新连接并选择。'"
        )
    )
}
fn parse_created(bytes: &[u8]) -> Result<Identity, TmuxError> {
    if bytes.len() > 512 {
        return Err(TmuxError::Metadata);
    }
    let text = std::str::from_utf8(bytes).map_err(|_| TmuxError::Metadata)?;
    let text = text.strip_suffix('\n').ok_or(TmuxError::Metadata)?;
    let fields: Vec<_> = text.split('\t').collect();
    if fields.len() != 3
        || !valid_id(fields[1])
        || fields[0].is_empty()
        || fields[2].is_empty()
        || !fields[0].bytes().all(|b| b.is_ascii_digit())
        || !fields[2].bytes().all(|b| b.is_ascii_digit())
    {
        return Err(TmuxError::Metadata);
    }
    let server_pid = fields[0].parse::<u32>().map_err(|_| TmuxError::Metadata)?;
    let created = fields[2].parse::<u64>().map_err(|_| TmuxError::Metadata)?;
    if server_pid == 0 || created == 0 {
        return Err(TmuxError::Metadata);
    }
    Ok(Identity {
        id: fields[1].into(),
        server_pid,
        created,
    })
}
fn create_command(name: &str, size: (u16, u16), needs_agent: bool) -> String {
    let create = format!(
        "TERM=xterm-256color LC_ALL=C tmux -u new-session -d -P -F {} -x {} -y {} -s {}",
        quote("#{pid}\t#{session_id}\t#{session_created}"),
        size.0,
        size.1,
        quote(name)
    );
    if needs_agent {
        format!(
            "if [ -z \"$SSH_AUTH_SOCK\" ] || [ ! -S \"$SSH_AUTH_SOCK\" ]; then printf '%s\\n' HSPTERM_TMUX_NO_AGENT_ENV_V1; exit 73; fi; {create}"
        )
    } else {
        create
    }
}

pub(crate) async fn prepare(
    handle: &mut client::Handle<Client>,
    budget: &mut Budget,
    policy: Policy,
    cancel: &CancellationToken,
    size: (u16, u16),
    verified_host: &crate::HostKey,
    username: &str,
) -> Result<Startup, SshError> {
    let probe = exec(handle, budget, "LC_ALL=C tmux -V").await?;
    let mut listing = Listing {
        version: None,
        issue: None,
        sessions: Vec::new(),
    };
    if probe.status != 0 {
        listing.issue = Some(ListingIssue::NotAvailable);
    } else if let Some(v) = version(&probe.output) {
        listing.version = Some(v);
        let list = exec(handle, budget, LIST).await?;
        if list.status != 0 {
            listing.issue = Some(ListingIssue::ListUnavailable);
        } else {
            listing.sessions = parse_sessions(&list.output)?;
        }
    } else {
        listing.issue = Some(ListingIssue::UnsupportedVersion);
    }
    let (reply, response) = oneshot::channel();
    let request = Request {
        verified_host: verified_host.clone(),
        username: username.to_owned(),
        columns: size.0,
        rows: size.1,
        listing: listing.clone(),
        reply,
    };
    // Budget only charges run() calls. Human selection happens outside run(),
    // remains cancellable, and never consumes the remaining network deadline.
    tokio::select! { biased;
        _ = cancel.cancelled() => return Err(SshError::Cancelled),
        _ = &mut *handle => return Err(SshError::Disconnected),
        sent = policy.requests.send(request) => sent.map_err(|_| SshError::Cancelled)?,
    }
    let choice = tokio::select! { biased;
        _ = cancel.cancelled() => return Err(SshError::Cancelled),
        _ = &mut *handle => return Err(SshError::Disconnected),
        value = response => value.map_err(|_| SshError::Cancelled)?,
    };
    let mut startup = select(&listing, choice.clone())?;
    if let Choice::CreateRemembered { name, .. } | Choice::Create { name, .. } = choice {
        // Wait until the original PTY's Agent setup has completed before
        // creating a pane, so remembering cannot silently lose Agent support.
        startup.deferred_create = Some(name);
    }
    Ok(startup)
}
pub(crate) async fn complete_creation(
    startup: &mut Startup,
    handle: &client::Handle<Client>,
    budget: &mut Budget,
    size: (u16, u16),
    agent_request: Option<bool>,
) -> Result<(), SshError> {
    if let Some(name) = startup.deferred_create.take() {
        // The actual create ACK, not an earlier list or a name lookup, proves
        // which session belongs to this confirmed creation. No -A or retry.
        let reply = exec_routed(
            handle,
            budget,
            &create_command(&name, size, agent_request.is_some()),
            agent_request,
        )
        .await?;
        if reply.status == 73 && reply.output == b"HSPTERM_TMUX_NO_AGENT_ENV_V1\n" {
            return Err(TmuxError::AgentEnvironment.into());
        }
        if reply.status != 0 {
            return Err(TmuxError::Response.into());
        }
        let identity = parse_created(&reply.output)?;
        // This is our newly created session. Do not detach a client which
        // raced to attach after create; future takeover is separate consent.
        startup.command = Some(guarded_attach(
            &identity,
            &format!("attach-session -t {}", quote(&identity.id)),
        ));
        startup.session = Some(identity);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn listing() -> Listing {
        Listing {
            version: Some("tmux 3.4".into()),
            issue: None,
            sessions: vec![Session {
                id: "$12".into(),
                name: "name never a command".into(),
                attached: 2,
                server_pid: 123,
                created: 456,
            }],
        }
    }
    #[test]
    fn compatibility_is_capability_gated_scoped_and_never_changes_readonly() {
        let id = Identity {
            id: "$12".into(),
            server_pid: 123,
            created: 456,
        };
        let command = guarded_attach_options(&id, "attach-session -t '$12'", false);
        assert!(command.contains("show-window-options"));
        assert!(command.contains("pane-scrollbars on"));
        assert!(!command.contains("set-option -g"));
        let readonly = guarded_attach_options(&id, "attach-session -r -t '$12'", true);
        assert!(!readonly.contains("pane-scrollbars"));
        assert!(readonly.contains("attach-session -r"));
    }
    #[test]
    fn remembered_identity_ignores_rename_but_rejects_reused_session_id_or_restarted_server() {
        let original = listing().sessions.remove(0);
        let mut changed = original.clone();
        changed.name = "renamed".into();
        changed.attached = 9;
        assert!(original.same_identity(&changed));
        changed.server_pid += 1;
        assert!(!original.same_identity(&changed));
        changed = original.clone();
        changed.created += 1;
        assert!(!original.same_identity(&changed));
        changed = original.clone();
        changed.id = "$13".into();
        assert!(!original.same_identity(&changed));
    }
    #[test]
    fn creation_ack_is_exact_and_guarded_attachment_never_uses_a_name_or_detaches_a_racing_client()
    {
        let identity = parse_created(b"123\t$12\t456\n").unwrap();
        assert!(listing().sessions[0].matches_identity(&identity));
        for bad in [
            b"123 $12 456\n".as_slice(),
            b"0\t$12\t456\n",
            b"123\t$12;bad\t456\n",
            b"123\t$12\t0\n",
            b"+123\t$12\t456\n",
            b"123\t$12\t456\nextra\n",
            b"123\t$12\t456",
        ] {
            assert!(parse_created(bad).is_err());
        }
        let command = create_command("开发 session", (101, 37), false);
        assert!(command.contains("new-session -d -P -F"));
        assert!(command.contains("-x 101 -y 37"));
        assert!(!command.contains(" -A"));
        let with_agent = create_command("fixture", (80, 24), true);
        assert!(with_agent.contains("[ ! -S \"$SSH_AUTH_SOCK\" ]"));
        assert!(with_agent.find("exit 73").unwrap() < with_agent.find("new-session").unwrap());
        let attach = guarded_attach(&identity, "attach-session -t '$12'");
        assert!(attach.contains("#{pid},123"));
        assert!(attach.contains("#{session_created},456"));
        assert!(!attach.contains(" -d"));
        assert!(!attach.contains("开发"));
    }
    #[test]
    fn strict_metadata_uses_encoded_names_without_line_or_bidi_injection() {
        let name = STANDARD.encode("中文\n$99\t'\u{202e}\n");
        let rows = parse_sessions(format!("123\t$12\t456\t2\t{name}\n").as_bytes()).unwrap();
        assert_eq!(rows[0].id, "$12");
        assert!(!rows[0].name.chars().any(char::is_control));
        assert!(!rows[0].name.contains('\u{202e}'));
        for bad in [
            "",
            "123\t$12\t0\t1\t!\n",
            "0\t$12\t0\t1\tYQo=\n",
            "123\t$12;bad\t0\t1\tYQo=\n",
            "123\t$12\t0\t1\tYQo=\n124\t$13\t0\t1\tYgo=\n",
            "123\t$12\t0\t1\tYQo=\n123\t$12\t0\t1\tYgo=\n",
        ] {
            assert!(parse_sessions(bad.as_bytes()).is_err());
        }
    }
    #[test]
    fn typed_choices_cannot_inject_commands_or_silently_take_control() {
        let l = listing();
        assert!(
            select(
                &l,
                Choice::Attach {
                    id: "$12".into(),
                    readonly: false,
                    takeover_confirmed: false,
                    lock_size: false
                }
            )
            .is_err()
        );
        assert!(
            select(
                &l,
                Choice::Attach {
                    id: "$13".into(),
                    readonly: true,
                    takeover_confirmed: false,
                    lock_size: false
                }
            )
            .is_err()
        );
        let viewer = select(
            &l,
            Choice::Attach {
                id: "$12".into(),
                readonly: true,
                takeover_confirmed: false,
                lock_size: true,
            },
        )
        .unwrap();
        assert!(viewer.readonly && viewer.lock_size);
        assert!(
            viewer
                .command
                .as_ref()
                .unwrap()
                .contains("attach-session -r")
        );
        assert!(viewer.command.as_ref().unwrap().contains("session_created"));
        for name in ["", ";x", "a:b", "$(bad)", "quote'", "line\nnext"] {
            assert!(
                select(
                    &l,
                    Choice::Create {
                        name: name.into(),
                        lock_size: false
                    }
                )
                .is_err()
            );
        }
        let new = select(
            &l,
            Choice::Create {
                name: "hspterm_test-1".into(),
                lock_size: false,
            },
        )
        .unwrap();
        assert!(!new.command.unwrap().contains(" -A"));
        assert!(select(&l, Choice::Cancel).is_err());
        assert!(select(&l, Choice::Shell).unwrap().command.is_none());
    }
    #[test]
    fn version_and_capacity_are_bounded_instead_of_optimistically_parsed() {
        assert_eq!(version(b"tmux 3.4\n").as_deref(), Some("tmux 3.4"));
        assert!(version(b"tmux 3.2a").is_some());
        for bad in [
            b"tmux 3.1".as_slice(),
            b"unknown",
            b"tmux next-3.4",
            b"tmux 3.4\nextra",
        ] {
            assert!(version(bad).is_none());
        }
        let rows = (0..257)
            .map(|i| format!("123\t${i}\t0\t0\tYQo=\n"))
            .collect::<String>();
        let first_256 = rows.lines().take(256).collect::<Vec<_>>().join("\n");
        assert_eq!(parse_sessions(first_256.as_bytes()).unwrap().len(), 256);
        assert!(parse_sessions(rows.as_bytes()).is_err());
    }
}
