//! Recursive SFTP deletion engine. Source-only private module: the FRB input
//! is `crate::api` alone, so none of these bounded types become bindings.
//!
//! Per-entry errors accumulate into [RemoveOutcome] instead of aborting
//! siblings; NO_SUCH_FILE at any step counts as achieved (rm -f semantics);
//! SSH_FX_FAILURE on the mutating/listing primitives gets one short back-off
//! retry; budgets produce explicit failure rows, never silent truncation.
use anyhow::{Result, bail};

/// Restricted delete-failure taxonomy crossing the bridge as a stable
/// `reason_code` plus its fixed public phrase. Raw server payloads never do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoveFailureCode {
    PermissionDenied,
    Failure,
    NoSuchFile,
    NameInvalid,
    Timeout,
    Unknown,
}
impl RemoveFailureCode {
    pub fn code(self) -> &'static str {
        match self {
            Self::PermissionDenied => "PermissionDenied",
            Self::Failure => "Failure",
            Self::NoSuchFile => "NoSuchFile",
            Self::NameInvalid => "NameInvalid",
            Self::Timeout => "Timeout",
            Self::Unknown => "Unknown",
        }
    }
    fn text(self) -> &'static str {
        match self {
            Self::PermissionDenied => "权限不足",
            Self::Failure => "被占用或目录非空",
            Self::NoSuchFile => "文件已不存在（建议刷新）",
            // A lossy U+FFFD name can never address the original bytes again.
            Self::NameInvalid => "名称含非UTF-8字节，SFTP协议无法定位该文件",
            Self::Timeout => "服务器响应超时",
            Self::Unknown => "服务器拒绝",
        }
    }
}

/// One refused entry. The phrase normally mirrors the code's fixed text;
/// budget and root-guard anomalies carry their own fixed wording.
pub(crate) struct RemoveFailure {
    pub path: String,
    pub code: RemoveFailureCode,
    pub text: &'static str,
}
impl RemoveFailure {
    pub(crate) fn new(path: impl Into<String>, code: RemoveFailureCode) -> Self {
        Self {
            path: path.into(),
            code,
            text: code.text(),
        }
    }
    fn fixed(path: impl Into<String>, code: RemoveFailureCode, text: &'static str) -> Self {
        Self {
            path: path.into(),
            code,
            text,
        }
    }
    fn classified(path: impl Into<String>, error: &russh_sftp::client::error::Error) -> Self {
        Self::new(path, classify_remove_error(error))
    }
}

/// Internal accumulation mirrored into the public batch outcome.
#[derive(Default)]
pub(crate) struct RemoveOutcome {
    pub succeeded: Vec<String>,
    pub failed: Vec<RemoveFailure>,
}

/// Bounded delete budgets in the Capacity spirit of ssh-core directory.rs: a
/// limit trip becomes explicit failure rows, never silent truncation.
pub(crate) const REMOVE_MAX_ROOTS: usize = 10_000;
pub(crate) const REMOVE_MAX_ENTRIES: usize = 100_000;
const REMOVE_MAX_DEPTH: u32 = 128;
const REMOVE_RETRY_BACKOFF: std::time::Duration = std::time::Duration::from_millis(200);
const REMOVE_CAPACITY_TEXT: &str = "目录内容超过安全容量，未继续删除剩余条目";
const REMOVE_DEPTH_TEXT: &str = "目录层级超过安全深度，未继续删除该子树";
const REMOVE_ROOT_TEXT: &str = "不能删除根目录";

fn remove_no_such_file(error: &russh_sftp::client::error::Error) -> bool {
    matches!(
        error,
        russh_sftp::client::error::Error::Status(status)
            if status.status_code == russh_sftp::protocol::StatusCode::NoSuchFile
    )
}

fn remove_busy_failure(error: &russh_sftp::client::error::Error) -> bool {
    matches!(
        error,
        russh_sftp::client::error::Error::Status(status)
            if status.status_code == russh_sftp::protocol::StatusCode::Failure
    )
}

fn classify_remove_error(error: &russh_sftp::client::error::Error) -> RemoveFailureCode {
    use russh_sftp::client::error::Error as RemoteError;
    use russh_sftp::protocol::StatusCode;
    match error {
        RemoteError::Status(status) => match status.status_code {
            StatusCode::NoSuchFile => RemoveFailureCode::NoSuchFile,
            StatusCode::PermissionDenied => RemoveFailureCode::PermissionDenied,
            StatusCode::Failure
            | StatusCode::BadMessage
            | StatusCode::NoConnection
            | StatusCode::ConnectionLost => RemoveFailureCode::Failure,
            _ => RemoveFailureCode::Unknown,
        },
        RemoteError::Timeout => RemoveFailureCode::Timeout,
        _ => RemoveFailureCode::Unknown,
    }
}

pub(crate) fn remove_lossy(path: &str) -> bool {
    // The SFTP codec decodes names with from_utf8_lossy; any U+FFFD means the
    // original server bytes are no longer addressable through this protocol.
    path.contains('\u{FFFD}')
}

/// One short back-off retry on SSH_FX_FAILURE absorbs transient NAS/FUSE
/// "resource busy" moments on the mutating and listing primitives.
async fn remove_file_with_retry(
    remote: &hspterm_ssh_core::SftpSession,
    path: &str,
) -> std::result::Result<(), russh_sftp::client::error::Error> {
    match remote.remove_file(path.to_owned()).await {
        Err(error) if remove_busy_failure(&error) => {
            tokio::time::sleep(REMOVE_RETRY_BACKOFF).await;
            remote.remove_file(path.to_owned()).await
        }
        other => other,
    }
}

async fn remove_dir_with_retry(
    remote: &hspterm_ssh_core::SftpSession,
    path: &str,
) -> std::result::Result<(), russh_sftp::client::error::Error> {
    match remote.remove_dir(path.to_owned()).await {
        Err(error) if remove_busy_failure(&error) => {
            tokio::time::sleep(REMOVE_RETRY_BACKOFF).await;
            remote.remove_dir(path.to_owned()).await
        }
        other => other,
    }
}

async fn open_dir_with_retry(
    remote: &hspterm_ssh_core::SftpSession,
    path: &str,
) -> std::result::Result<russh_sftp::client::fs::ReadDirStream, russh_sftp::client::error::Error> {
    match remote.read_dir_stream(path.to_owned()).await {
        Err(error) if remove_busy_failure(&error) => {
            tokio::time::sleep(REMOVE_RETRY_BACKOFF).await;
            remote.read_dir_stream(path.to_owned()).await
        }
        other => other,
    }
}

/// One stack entry: Probe decides an entry's fate; RemoveDir runs after its
/// children, keeping the previous depth-first order. A precomputed lstat
/// result (used for the user-selected root) saves its extra round trip.
enum RemoveVisit {
    Probe(String, u32, Option<russh_sftp::protocol::FileAttributes>),
    RemoveDir(String),
}

/// Expansion result for one directory listing.
enum RemoveExpansion {
    /// Every child was queued: the caller may attempt RMDIR.
    Complete,
    /// NO_SUCH_FILE while listing: the entry is already gone (rm -f).
    Vanished,
    /// Listing refused or budget tripped: a failure row was recorded.
    Refused,
}

/// Queues the children of one verified directory. Returns
/// [RemoveExpansion::Complete] only after a fully consumed page stream, so
/// RMDIR runs exactly when the directory can actually be empty.
async fn expand_remote_directory(
    path: &str,
    depth: u32,
    mut stream: russh_sftp::client::fs::ReadDirStream,
    budget: &mut usize,
    pending: &mut Vec<RemoveVisit>,
    outcome: &mut RemoveOutcome,
) -> Result<RemoveExpansion> {
    let mut refused = None;
    let mut vanished = false;
    let mut exhausted = false;
    loop {
        match stream.next_page().await {
            Ok(Some(files)) => {
                for file in files {
                    let name = file.filename;
                    if name == "." || name == ".." {
                        continue;
                    }
                    if name.contains('/') || name.contains('\0') {
                        bail!("服务器返回无效文件名");
                    }
                    if *budget == 0 {
                        exhausted = true;
                        break;
                    }
                    *budget -= 1;
                    let child = format!("{}/{}", path.trim_end_matches('/'), name);
                    if remove_lossy(&name) {
                        outcome
                            .failed
                            .push(RemoveFailure::new(child, RemoveFailureCode::NameInvalid));
                        continue;
                    }
                    pending.push(RemoveVisit::Probe(child, depth + 1, None));
                }
            }
            Ok(None) => break,
            Err(ref error) if remove_no_such_file(error) => {
                vanished = true;
                break;
            }
            Err(error) => {
                refused = Some(RemoveFailure::classified(path, &error));
                break;
            }
        }
        if exhausted {
            break;
        }
    }
    // An incomplete stream drops with a best-effort close_nowait; the recorded
    // refusal below is what reports the real state, not the handle release.
    if let Some(failure) = refused {
        outcome.failed.push(failure);
        return Ok(RemoveExpansion::Refused);
    }
    if exhausted {
        outcome.failed.push(RemoveFailure::fixed(
            path,
            RemoveFailureCode::Unknown,
            REMOVE_CAPACITY_TEXT,
        ));
        return Ok(RemoveExpansion::Refused);
    }
    if vanished {
        outcome.succeeded.push(path.to_owned());
        return Ok(RemoveExpansion::Vanished);
    }
    Ok(RemoveExpansion::Complete)
}

/// Deletes one absolute path, recursively when [recursive]. Per-entry errors
/// accumulate in [outcome] instead of aborting siblings; NO_SUCH_FILE at any
/// step counts as achieved (rm -f semantics); the user-selected root is
/// canonicalized exactly once, and only when it is a real directory (an
/// unlinked symlink pointing to "/" stays deletable), for the root guard.
pub(crate) async fn remove_remote_tree(
    remote: &hspterm_ssh_core::SftpSession,
    root: String,
    recursive: bool,
    budget: &mut usize,
    outcome: &mut RemoveOutcome,
) -> Result<()> {
    let root = root.trim_end_matches('/').to_owned();
    if root.is_empty() {
        bail!("不能删除根目录");
    }
    let mut pending = vec![RemoveVisit::Probe(root, 0, None)];
    while let Some(visit) = pending.pop() {
        match visit {
            RemoveVisit::RemoveDir(path) => match remove_dir_with_retry(remote, &path).await {
                Ok(()) => outcome.succeeded.push(path),
                Err(ref error) if remove_no_such_file(error) => {
                    outcome.succeeded.push(path);
                }
                Err(error) => outcome.failed.push(RemoveFailure::classified(path, &error)),
            },
            RemoveVisit::Probe(path, depth, probed_attributes) => {
                if *budget == 0 {
                    outcome.failed.push(RemoveFailure::fixed(
                        path,
                        RemoveFailureCode::Unknown,
                        REMOVE_CAPACITY_TEXT,
                    ));
                    continue;
                }
                *budget -= 1;
                if depth > REMOVE_MAX_DEPTH {
                    outcome.failed.push(RemoveFailure::fixed(
                        path,
                        RemoveFailureCode::Unknown,
                        REMOVE_DEPTH_TEXT,
                    ));
                    continue;
                }
                let attributes = match probed_attributes {
                    Some(attributes) => attributes,
                    None => match remote.symlink_metadata(path.clone()).await {
                        Ok(attributes) => attributes,
                        Err(ref error) if remove_no_such_file(error) => {
                            outcome.succeeded.push(path);
                            continue;
                        }
                        Err(error) => {
                            outcome.failed.push(RemoveFailure::classified(path, &error));
                            continue;
                        }
                    },
                };
                // The user-selected root is canonicalized exactly once, and
                // only when it is a real directory: an unlinked symlink whose
                // target happens to "/" stays deletable, and a refused
                // REALPATH must never mask the delete's own classification.
                if depth == 0 && attributes.is_dir() && !attributes.is_symlink() {
                    match remote.canonicalize(path.clone()).await {
                        Ok(canonical) if canonical == "/" || canonical.is_empty() => {
                            outcome.failed.push(RemoveFailure::fixed(
                                path,
                                RemoveFailureCode::Unknown,
                                REMOVE_ROOT_TEXT,
                            ));
                            continue;
                        }
                        _ => {}
                    }
                }
                // Servers that omit permission flags make is_dir() falsely
                // report a plain file; OPENDIR probes the real type once and
                // its stream doubles as the listing.
                let mut probed = None;
                let directory = if attributes.is_dir() && !attributes.is_symlink() {
                    true
                } else if attributes.permissions.is_none() && !attributes.is_symlink() {
                    match open_dir_with_retry(remote, &path).await {
                        Ok(stream) => {
                            probed = Some(stream);
                            true
                        }
                        Err(ref error) if remove_no_such_file(error) => {
                            outcome.succeeded.push(path);
                            continue;
                        }
                        // A plain file's OPENDIR fails harmlessly: REMOVE
                        // follows and classifies the true condition.
                        Err(_) => false,
                    }
                } else {
                    false
                };
                if !directory {
                    match remove_file_with_retry(remote, &path).await {
                        Ok(()) => outcome.succeeded.push(path),
                        Err(ref error) if remove_no_such_file(error) => {
                            outcome.succeeded.push(path);
                        }
                        Err(error) => {
                            outcome.failed.push(RemoveFailure::classified(path, &error));
                        }
                    }
                    continue;
                }
                if !recursive {
                    // Single-entry mode: RMDIR alone decides emptiness.
                    pending.push(RemoveVisit::RemoveDir(path));
                    continue;
                }
                let stream = match probed {
                    Some(stream) => stream,
                    None => match open_dir_with_retry(remote, &path).await {
                        Ok(stream) => stream,
                        Err(ref error) if remove_no_such_file(error) => {
                            outcome.succeeded.push(path);
                            continue;
                        }
                        Err(error) => {
                            outcome.failed.push(RemoveFailure::classified(path, &error));
                            continue;
                        }
                    },
                };
                let expansion =
                    expand_remote_directory(&path, depth, stream, budget, &mut pending, outcome)
                        .await?;
                if let RemoveExpansion::Complete = expansion {
                    // Even with failed siblings, the root RMDIR is still
                    // attempted: it classifies the final state truthfully.
                    pending.push(RemoveVisit::RemoveDir(path));
                }
            }
        }
    }
    Ok(())
}

/// Deletes every root in order with one shared entry budget, mirroring the
/// result into the public batch outcome.
pub(crate) async fn remove_remote_paths(
    remote: &hspterm_ssh_core::SftpSession,
    roots: Vec<String>,
    recursive: bool,
) -> Result<crate::api::SftpRemoveBatchOutcome> {
    let mut outcome = RemoveOutcome::default();
    let mut budget = REMOVE_MAX_ENTRIES;
    for root in roots {
        // A lossy U+FFFD path can never address the original bytes; classify
        // it without a doomed request.
        if remove_lossy(&root) {
            outcome
                .failed
                .push(RemoveFailure::new(root, RemoveFailureCode::NameInvalid));
            continue;
        }
        remove_remote_tree(remote, root, recursive, &mut budget, &mut outcome).await?;
    }
    Ok(crate::api::SftpRemoveBatchOutcome {
        succeeded: outcome.succeeded,
        failed: outcome
            .failed
            .iter()
            .map(|failure| crate::api::SftpRemoveFailure {
                path: failure.path.clone(),
                reason_code: failure.code.code().to_owned(),
                reason_text: failure.text.to_owned(),
            })
            .collect(),
    })
}
