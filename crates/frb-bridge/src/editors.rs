//! Device-local encrypted editor state and explicit, identity-bound saves.
use anyhow::{Context, Result, bail};
use hspterm_ssh_core::{ManagedSession, SessionPhase, edit};
use hspterm_storage_sync::external_edits::ExternalCopy;
use hspterm_storage_sync::local_edits::{
    self, EditDraft, EditJournal, EditMetadata, EditTarget, Encoding, LineEnding, MAX_TEXT_BYTES,
};
use hspterm_storage_sync::raw_edits::{RawEditJournal, RawEditMetadata};
use parking_lot::Mutex;
use std::{
    collections::HashMap,
    sync::{
        Arc, OnceLock, Weak,
        atomic::{AtomicBool, Ordering},
    },
};
use tokio::runtime::Handle;
use tokio_util::sync::CancellationToken;
mod raw;

#[derive(Clone)]
pub struct EditorSummary {
    pub id: String,
    pub host_id: String,
    pub address: String,
    pub port: u16,
    pub username: String,
    pub path: String,
    pub revision: u64,
    pub saved_revision: u64,
    pub encoding: String,
    pub line_ending: String,
    pub terminal_id: Option<u32>,
    pub active: bool,
    pub external_directory: Option<String>,
    pub raw_bytes: Option<u64>,
}
pub struct ExternalEditorFile {
    pub path: String,
    pub existing: bool,
    pub summary: EditorSummary,
}
pub struct EditorDocument {
    pub summary: EditorSummary,
    pub text: String,
}
/// Small, body-free snapshot. Byte completion is not a save acknowledgement.
#[derive(Clone, PartialEq, Eq)]
pub struct EditorProgress {
    pub operation: u64,
    pub phase: String,
    pub acknowledged: u64,
    pub total: Option<u64>,
}
#[derive(Clone)]
struct EditorBinding {
    terminal: u32,
    generation: u64,
    session: Weak<ManagedSession>,
    closing: Arc<AtomicBool>,
    target: EditTarget,
}
impl From<&crate::transfers::Connection> for EditorBinding {
    fn from(c: &crate::transfers::Connection) -> Self {
        Self {
            terminal: c.terminal_id,
            generation: c.generation,
            session: Arc::downgrade(&c.session),
            closing: c.closing.clone(),
            target: target(c),
        }
    }
}
fn target(c: &crate::transfers::Connection) -> EditTarget {
    EditTarget {
        host_id: c.target.host_id.clone(),
        address: c.target.address.clone(),
        port: c.target.port,
        username: c.target.username.clone(),
        fingerprint: c.target.fingerprint.clone(),
    }
}
struct EditorOperation {
    id: u64,
    stop: CancellationToken,
}
struct EditorRuntime {
    draft: Option<Arc<EditDraft>>,
    raw: Option<RawEditMetadata>,
    binding: Option<EditorBinding>,
    operation: Option<EditorOperation>,
    next_operation: u64,
    progress: Option<EditorProgress>,
    external: Option<ExternalCopy>,
}
struct EditorEntry {
    token: String,
    id: String,
    requested_path: Option<String>,
    raw_mode: bool,
    channels: crate::transfer_channels::Channels,
    state: Mutex<EditorRuntime>,
    gate: tokio::sync::Mutex<()>,
    closed: AtomicBool,
}
#[derive(Default)]
struct EditorRegistry {
    documents: HashMap<String, Arc<EditorEntry>>,
    closing: bool,
    switching: bool,
}
fn registry() -> &'static Mutex<EditorRegistry> {
    static VALUE: OnceLock<Mutex<EditorRegistry>> = OnceLock::new();
    VALUE.get_or_init(Default::default)
}
fn get(id: &str) -> Result<Arc<EditorEntry>> {
    registry()
        .lock()
        .documents
        .get(id)
        .cloned()
        .context("编辑文档已关闭")
}
pub(crate) fn switch_vault<T>(action: impl FnOnce() -> Result<T>) -> Result<T> {
    {
        let mut r = registry().lock();
        if r.switching || !r.documents.is_empty() {
            bail!("请先关闭编辑文档并保留或处理草稿，再切换加密配置库");
        }
        r.switching = true;
    }
    let result = action();
    let mut r = registry().lock();
    r.switching = false;
    if result.is_ok() {
        r.closing = false;
    }
    result
}
pub(crate) fn reserve(connection: crate::transfers::Connection, path: String) -> Result<String> {
    let binding = EditorBinding::from(&connection);
    check_binding(&binding)?;
    insert(
        format!("edit-{:032x}", rand::random::<u128>()),
        Some(path),
        Some(binding),
        false,
    )
}
pub(crate) fn reserve_raw(
    connection: crate::transfers::Connection,
    path: String,
) -> Result<String> {
    let binding = EditorBinding::from(&connection);
    check_binding(&binding)?;
    insert(
        format!("edit-{:032x}", rand::random::<u128>()),
        Some(path),
        Some(binding),
        true,
    )
}
pub(crate) fn reserve_saved(id: String) -> Result<String> {
    if !id
        .strip_prefix("edit-")
        .is_some_and(|v| v.len() == 32 && v.bytes().all(|c| c.is_ascii_hexdigit()))
    {
        bail!("编辑草稿标识无效");
    }
    let raw = crate::api::with_vault(|v| Ok(RawEditJournal::new(v).contains(&id)?))?;
    insert(id, None, None, raw)
}
fn insert(
    id: String,
    path: Option<String>,
    binding: Option<EditorBinding>,
    raw_mode: bool,
) -> Result<String> {
    let mut r = registry().lock();
    if r.closing || r.switching {
        bail!("编辑服务正在关闭或切换配置库");
    }
    if r.documents.values().any(|doc| doc.id == id) {
        bail!("该草稿已在编辑，不能重复恢复");
    }
    if r.documents.len() >= 32 {
        bail!("同时打开的编辑文档过多，请先关闭部分文档");
    }
    if let (Some(binding), Some(path)) = (&binding, &path) {
        crate::remote_transfers::check_editor_path(&binding.target, path)?;
    }
    let token = format!("editor-{:032x}", rand::random::<u128>());
    r.documents.insert(
        token.clone(),
        Arc::new(EditorEntry {
            token: token.clone(),
            id: id.clone(),
            requested_path: path,
            raw_mode,
            channels: Default::default(),
            state: Mutex::new(EditorRuntime {
                draft: None,
                raw: None,
                binding,
                operation: None,
                next_operation: 0,
                progress: None,
                external: None,
            }),
            gate: tokio::sync::Mutex::new(()),
            closed: AtomicBool::new(false),
        }),
    );
    Ok(token)
}
/// Keep the editor registry gate across move reservation/intent publication so
/// an external editor cannot begin auto-uploading to a name being moved away.
/// No body is read and no network work occurs while this guard is held.
pub(crate) fn with_move_source_guard<T>(
    origin: &crate::transfers::Target,
    source: &str,
    action: impl FnOnce() -> Result<T>,
) -> Result<T> {
    let r = registry().lock();
    if r.closing || r.switching {
        bail!("编辑服务正在关闭或切换，暂不移动文件");
    }
    for doc in r.documents.values() {
        let state = doc.state.lock();
        let Some(binding) = &state.binding else {
            continue;
        };
        let target = &binding.target;
        // Equal host keys may be address/port aliases of the same filesystem.
        // Guard known paths conservatively, even across saved host identities.
        if target.fingerprint != origin.fingerprint {
            continue;
        }
        let path = state
            .raw
            .as_ref()
            .map(|m| m.path.as_str())
            .or_else(|| state.draft.as_ref().map(|d| d.metadata.path.as_str()));
        let Some(path) = path else {
            bail!("相关服务器编辑文档尚在准备，请完成后再移动文件");
        };
        if path == source
            || path
                .strip_prefix(source)
                .is_some_and(|suffix| suffix.starts_with('/'))
        {
            bail!("所选对象包含正在编辑的文件；请先保存并关闭相关编辑文档再移动");
        }
    }
    action()
}
fn check_binding(binding: &EditorBinding) -> Result<Arc<ManagedSession>> {
    let session = binding
        .session
        .upgrade()
        .context("原SSH终端已关闭；本机草稿保留，可在正确会话中明确恢复")?;
    let status = session.status();
    if binding.closing.load(Ordering::Acquire)
        || status.phase != SessionPhase::Connected
        || status.generation != binding.generation
    {
        bail!("关联SSH已断开或改变；请手动重连正确服务器后再保存");
    }
    Ok(session)
}
fn encoding(value: Encoding) -> &'static str {
    value.name()
}
fn ending(value: LineEnding) -> &'static str {
    match value {
        LineEnding::Preserve => "preserve",
        LineEnding::Lf => "lf",
        LineEnding::Crlf => "crlf",
        LineEnding::Cr => "cr",
    }
}
fn row(meta: &EditMetadata, terminal: Option<u32>, active: bool) -> EditorSummary {
    EditorSummary {
        id: meta.id.clone(),
        host_id: meta.target.host_id.clone(),
        address: meta.target.address.clone(),
        port: meta.target.port,
        username: meta.target.username.clone(),
        path: meta.path.clone(),
        revision: meta.revision,
        saved_revision: meta.saved_revision,
        encoding: encoding(meta.encoding).into(),
        line_ending: ending(meta.line_ending).into(),
        terminal_id: terminal,
        active,
        external_directory: meta.external_directory.clone(),
        raw_bytes: None,
    }
}
fn loaded(doc: &EditorEntry) -> Result<Arc<EditDraft>> {
    doc.state
        .lock()
        .draft
        .clone()
        .context("编辑正文尚未准备完成")
}
fn summary(doc: &EditorEntry) -> Result<EditorSummary> {
    let state = doc.state.lock();
    if doc.raw_mode {
        return Ok(raw::row(
            state.raw.as_ref().context("大正文尚未准备完成")?,
            state.binding.as_ref().map(|v| v.terminal),
            true,
        ));
    }
    Ok(row(
        &state
            .draft
            .as_ref()
            .context("编辑正文尚未准备完成")?
            .metadata,
        state.binding.as_ref().map(|v| v.terminal),
        true,
    ))
}
pub(crate) fn begin_operation(id: String) -> Result<u64> {
    {
        let r = registry().lock();
        if r.closing || r.switching {
            bail!("编辑服务正在关闭或切换配置库");
        }
    }
    let doc = get(&id)?;
    if doc.closed.load(Ordering::Acquire) {
        bail!("编辑文档正在关闭");
    }
    let mut state = doc.state.lock();
    if state.operation.is_some() {
        bail!("编辑操作尚未结束");
    }
    state.next_operation = state
        .next_operation
        .checked_add(1)
        .context("编辑操作序号已达上限")?;
    let id = state.next_operation;
    state.operation = Some(EditorOperation {
        id,
        stop: CancellationToken::new(),
    });
    state.progress = Some(EditorProgress {
        operation: id,
        phase: "waiting".into(),
        acknowledged: 0,
        total: None,
    });
    Ok(id)
}
pub(crate) fn progress(id: String, operation: u64) -> Result<Option<EditorProgress>> {
    let doc = get(&id)?;
    Ok(doc
        .state
        .lock()
        .progress
        .as_ref()
        .filter(|p| p.operation == operation)
        .cloned())
}
fn report(
    doc: &EditorEntry,
    operation: u64,
    phase: &str,
    bytes: Option<hspterm_ssh_core::transfer::FileProgress>,
) {
    let mut state = doc.state.lock();
    if let Some(p) = state.progress.as_mut().filter(|p| p.operation == operation) {
        if p.phase != phase {
            p.phase = phase.into();
        }
        if let Some(bytes) = bytes {
            p.acknowledged = bytes.acknowledged;
            p.total = Some(bytes.total);
        }
    }
}
struct OperationCleanup {
    doc: Arc<EditorEntry>,
    ticket: Option<u64>,
}
impl Drop for OperationCleanup {
    fn drop(&mut self) {
        if let Some(ticket) = self.ticket {
            let mut state = self.doc.state.lock();
            if state.operation.as_ref().is_some_and(|op| op.id == ticket) {
                let cancelled = state
                    .operation
                    .as_ref()
                    .is_some_and(|op| op.stop.is_cancelled());
                if let Some(p) = state.progress.as_mut().filter(|p| p.operation == ticket) {
                    // Includes early rejection and panicking worker cleanup.
                    if p.phase != "complete" && p.phase != "failed" {
                        p.phase = if cancelled { "cancelled" } else { "failed" }.into();
                    }
                }
                state.operation = None;
            }
        }
    }
}
async fn work<T: Send + 'static>(
    doc: Arc<EditorEntry>,
    ticket: Option<u64>,
    action: impl FnOnce(&EditorEntry, &CancellationToken, &Handle) -> Result<T> + Send + 'static,
) -> Result<T> {
    let handle = Handle::current();
    let stop = if let Some(ticket) = ticket {
        doc.state
            .lock()
            .operation
            .as_ref()
            .filter(|op| op.id == ticket)
            .map(|op| op.stop.clone())
            .context("编辑操作票据已取消或过期")?
    } else {
        CancellationToken::new()
    };
    tokio::task::spawn_blocking(move || {
        let _cleanup = OperationCleanup {
            doc: doc.clone(),
            ticket,
        };
        let _guard = doc.gate.blocking_lock();
        if doc.closed.load(Ordering::Acquire) {
            bail!("编辑文档正在关闭");
        }
        if stop.is_cancelled() {
            bail!("编辑操作已取消；未继续执行");
        }
        // A failed prior retirement retains the document owner and prevents any
        // replacement operation from overlapping its actual local IO.
        handle.block_on(doc.channels.retire())?;
        let result = crate::public_errors::guard_sync(|| action(&doc, &stop, &handle));
        let retired = handle.block_on(doc.channels.retire());
        let result = match (result, retired) {
            (result, Ok(())) => result,
            (Ok(_), Err(_)) => Err(anyhow::anyhow!("编辑SFTP子通道关闭未确认，草稿保留")),
            (Err(error), Err(_)) => Err(error.context("编辑失败且SFTP子通道释放失败")),
        };
        if let Some(ticket) = ticket {
            report(
                &doc,
                ticket,
                if result.is_ok() {
                    "complete"
                } else if stop.is_cancelled() {
                    "cancelled"
                } else {
                    "failed"
                },
                None,
            );
        }
        result
    })
    .await
    .context("编辑工作线程异常；已持久化草稿保留")?
}
/// Own a dedicated channel, observe generation changes, and close even after
/// cooperative cancellation. Never abort a worker and leave detached IO behind.
async fn remote<T>(
    doc: &EditorEntry,
    binding: EditorBinding,
    stop: &CancellationToken,
    upload: bool,
    action: impl AsyncFnOnce(
        &hspterm_ssh_core::SftpSession,
        &hspterm_ssh_core::bandwidth::BandwidthLimiter,
    ) -> Result<T>,
) -> Result<T> {
    let session = check_binding(&binding)?;
    let mut states = session.subscribe();
    let changed = async {
        loop {
            let s = states.borrow_and_update().clone();
            if s.phase != SessionPhase::Connected
                || s.generation != binding.generation
                || binding.closing.load(Ordering::Acquire)
            {
                break;
            }
            if states.changed().await.is_err() {
                break;
            }
        }
    };
    // Permit lives outside the operation/select future and remains held during
    // normal, cancellation and unwind cleanup. The document owns every adopted
    // channel even when cleanup fails; no new operation may silently replace it.
    let mut permit = None;
    doc.channels.supervise(async {
        let operation = async {
            let sftp = doc.channels.open(&session, binding.generation, stop).await
                .context("无法建立编辑SFTP子通道")?;
            check_binding(&binding)?;
            let (admission, budget) = crate::transfers::content_admission(upload)?;
            permit = Some(admission.enter(stop).await?);
            action(&sftp, &budget).await
        };
        tokio::select! { biased;
            _ = stop.cancelled() => Err(anyhow::anyhow!("编辑操作已取消；本机草稿保留，远端可能已有部分写入")),
            _ = changed => Err(anyhow::anyhow!("关联SSH已断开或改变；保存未确认，本机草稿保留")),
            result = operation => result,
        }
    }).await
}
pub(crate) async fn prepare(
    id: String,
    operation: u64,
    input_encoding: Option<String>,
) -> Result<EditorDocument> {
    work(get(&id)?, Some(operation), move |doc, stop, handle| {
        if doc.raw_mode {
            if input_encoding.is_some() {
                bail!("外部大文件按原始字节编辑，不在应用中转换编码");
            }
            return raw::prepare(doc, stop, handle, operation);
        }
        let selected = input_encoding.as_deref().map(Encoding::parse).transpose()?;
        if selected.is_some() && doc.requested_path.is_none() {
            bail!("恢复本机加密草稿不能重新指定输入编码");
        }
        if selected.is_some() && doc.state.lock().draft.is_some() {
            bail!("已有编辑草稿，不能重新解码覆盖；请保留或关闭后重新打开文件");
        }
        report(doc, operation, "preparing", None);
        if doc.state.lock().draft.is_none() {
            let draft = if let Some(path) = &doc.requested_path {
                crate::api::with_vault(|_| Ok(()))?;
                let binding = doc.state.lock().binding.clone().context("编辑源会话缺失")?;
                let origin = binding.target.clone();
                let read =
                    handle.block_on(remote(doc, binding, stop, false, async |sftp, limiter| {
                        let value = edit::read_file(
                            sftp,
                            path,
                            MAX_TEXT_BYTES * 2 + 2,
                            stop,
                            limiter,
                            |p| report(doc, operation, "reading", Some(p)),
                        )
                        .await?;
                        report(doc, operation, "confirming", None);
                        Ok(value)
                    }))?;
                report(doc, operation, "persisting", None);
                let (text, encoding, line_ending) =
                    local_edits::decode_with_encoding(&read.bytes, selected)?;
                if stop.is_cancelled() {
                    bail!("编辑文件读取已取消；未发布正文");
                }
                let draft = EditDraft {
                    metadata: EditMetadata {
                        version: 1,
                        id: doc.id.clone(),
                        target: origin,
                        path: read.path,
                        encoding,
                        line_ending,
                        revision: 1,
                        saved_revision: 1,
                        external_directory: None,
                    },
                    text,
                };
                crate::api::with_vault(|v| Ok(EditJournal::new(v).save(&draft, None)?))?;
                draft
            } else {
                report(doc, operation, "restoring", None);
                crate::api::with_vault(|v| Ok(EditJournal::new(v).load(&doc.id)?))?
            };
            doc.state.lock().draft = Some(Arc::new(draft));
        }
        let draft = loaded(doc)?;
        Ok(EditorDocument {
            summary: summary(doc)?,
            text: draft.text.clone(),
        })
    })
    .await
}
fn pin_external(doc: &EditorEntry, directory: Option<String>) -> Result<()> {
    if doc.raw_mode {
        return raw::pin(doc, directory);
    }
    let old = loaded(doc)?;
    let metadata =
        crate::api::with_vault(|v| {
            Ok(EditJournal::new(v).set_external_directory(
                &doc.id,
                old.metadata.revision,
                directory,
            )?)
        })?;
    doc.state.lock().draft = Some(Arc::new(EditDraft {
        metadata,
        text: old.text.clone(),
    }));
    Ok(())
}
fn open_external_locked(doc: &EditorEntry, base: Option<&str>) -> Result<(String, bool)> {
    if doc.raw_mode {
        return raw::open_external(doc, base, false);
    }
    let old = loaded(doc)?;
    if let Some(copy) = &doc.state.lock().external
        && copy.is_leased()
    {
        return Ok((
            copy.path()
                .to_str()
                .context("工作文件路径编码不支持")?
                .into(),
            true,
        ));
    }
    let previous = doc.state.lock().external.take();
    drop(previous);
    let directory = if let Some(path) = &old.metadata.external_directory {
        let path = std::path::PathBuf::from(path);
        std::fs::symlink_metadata(&path)
            .context("先前外部工作目录已不存在；加密草稿保留，请先确认清理关联")?;
        path
    } else {
        let base = base.context("请先选择外部编辑器并准备工作目录")?;
        let path = ExternalCopy::location(std::path::Path::new(base), &doc.id)?;
        pin_external(
            doc,
            Some(path.to_str().context("工作目录编码不支持")?.into()),
        )?;
        path
    };
    let bytes = local_edits::encode(&old.text, old.metadata.encoding, old.metadata.line_ending)?;
    let (copy, existing) = ExternalCopy::open(&directory, &doc.id, &old.metadata.path, &bytes)
        .context("无法准备外部工作文件；关联和草稿已保留")?;
    let path = copy
        .path()
        .to_str()
        .context("工作文件路径编码不支持")?
        .to_owned();
    doc.state.lock().external = Some(copy);
    Ok((path, existing))
}
pub(crate) async fn open_external(id: String, base: String) -> Result<ExternalEditorFile> {
    work(get(&id)?, None, move |doc, _, _| {
        let (path, existing) = open_external_locked(doc, Some(&base))?;
        Ok(ExternalEditorFile {
            path,
            existing,
            summary: summary(doc)?,
        })
    })
    .await
}
fn capture_external_locked(doc: &EditorEntry, handle: &Handle) -> Result<Option<EditorDocument>> {
    if doc.raw_mode {
        return raw::capture(doc, handle);
    }
    let copy = doc
        .state
        .lock()
        .external
        .take()
        .context("请先打开或恢复外部工作文件")?;
    let result = (|| {
        // Two settled local snapshots catch common in-place and atomic saves.
        // Never compare remote mtime/hash, truncate, or write into this file.
        let mut stable = None;
        for _ in 0..3 {
            let first = match copy.snapshot() {
                Ok(value) => value,
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::NotFound
                    ) =>
                {
                    handle.block_on(async {
                        tokio::time::sleep(std::time::Duration::from_millis(200)).await
                    });
                    continue;
                }
                Err(e) => return Err(e.into()),
            };
            handle.block_on(async {
                tokio::time::sleep(std::time::Duration::from_millis(200)).await
            });
            match copy.snapshot() {
                Ok(second) if first == second => {
                    stable = Some(second);
                    break;
                }
                Ok(_) => {}
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::NotFound
                    ) => {}
                Err(e) => return Err(e.into()),
            }
        }
        let bytes =
            stable.context("外部工作文件仍在变化或暂时不可读；工作文件与原草稿保留，请稍后重试")?;
        let old = loaded(doc)?;
        // Unicode BOM is explicit. Without it, preserve the selected legacy
        // codec rather than guessing whether an editor silently changed it.
        let has_bom = bytes.bytes.starts_with(&[0xff, 0xfe])
            || bytes.bytes.starts_with(&[0xfe, 0xff])
            || bytes.bytes.starts_with(&[0xef, 0xbb, 0xbf]);
        let hint = (!has_bom
            && !matches!(
                old.metadata.encoding,
                Encoding::Utf8 | Encoding::Utf8Bom | Encoding::Utf16Le | Encoding::Utf16Be
            ))
        .then_some(old.metadata.encoding);
        let (text, encoding, line_ending) = local_edits::decode_with_encoding(&bytes.bytes, hint)?;
        if old.text == text
            && old.metadata.encoding == encoding
            && old.metadata.line_ending == line_ending
        {
            return Ok(None);
        }
        let mut next = EditDraft {
            metadata: old.metadata.clone(),
            text,
        };
        next.metadata.revision = next
            .metadata
            .revision
            .checked_add(1)
            .context("编辑修订号达到上限")?;
        next.metadata.encoding = encoding;
        next.metadata.line_ending = line_ending;
        crate::api::with_vault(|v| {
            Ok(EditJournal::new(v).save(&next, Some(old.metadata.revision))?)
        })?;
        let text = next.text.clone();
        doc.state.lock().draft = Some(Arc::new(next));
        Ok(Some(EditorDocument {
            summary: summary(doc)?,
            text,
        }))
    })();
    doc.state.lock().external = Some(copy);
    result
}
pub(crate) async fn capture_external(
    id: String,
    expected_revision: u64,
) -> Result<Option<EditorDocument>> {
    work(get(&id)?, None, move |doc, _, handle| {
        if summary(doc)?.revision != expected_revision {
            bail!("本机草稿版本已改变，未用旧工作文件覆盖新草稿");
        }
        capture_external_locked(doc, handle)
    })
    .await
}
pub(crate) async fn release_external(id: String) -> Result<()> {
    work(get(&id)?, None, |doc, _, _| {
        doc.state.lock().external.take();
        Ok(())
    })
    .await
}
pub(crate) async fn cleanup_external(id: String, editor_closed: bool) -> Result<EditorDocument> {
    if !editor_closed {
        bail!("请先关闭外部编辑器，再确认清理工作文件");
    }
    work(get(&id)?, None, |doc, _, handle| {
        let directory = if doc.raw_mode {
            raw::loaded(doc)?.external_directory
        } else {
            loaded(doc)?.metadata.external_directory.clone()
        };
        let Some(directory) = &directory else {
            return current_document(doc);
        };
        match std::fs::symlink_metadata(directory) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let previous = doc.state.lock().external.take();
                drop(previous);
                pin_external(doc, None)?;
                return current_document(doc);
            }
            Err(e) => return Err(e.into()),
            Ok(_) => {}
        }
        // Reopen even after a failed cleanup released its lock. Never delete
        // while another instance has subsequently acquired the workspace.
        doc.state.lock().external.take();
        if doc.raw_mode {
            raw::open_external(doc, None, true)?;
        } else {
            open_external_locked(doc, None)?;
        }
        let path = doc
            .state
            .lock()
            .external
            .as_ref()
            .context("工作文件租约缺失")?
            .path()
            .to_owned();
        let has_file = path.try_exists()?;
        if has_file {
            capture_external_locked(doc, handle)?;
        }
        let mut copy = doc
            .state
            .lock()
            .external
            .take()
            .context("工作文件租约缺失")?;
        if let Err(error) = copy.remove_confirmed() {
            doc.state.lock().external = Some(copy);
            return Err(error.into());
        }
        pin_external(doc, None)?;
        current_document(doc)
    })
    .await
}
fn current_document(doc: &EditorEntry) -> Result<EditorDocument> {
    Ok(EditorDocument {
        summary: summary(doc)?,
        text: if doc.raw_mode {
            String::new()
        } else {
            loaded(doc)?.text.clone()
        },
    })
}
pub(crate) async fn bind(
    id: String,
    connection: crate::transfers::Connection,
) -> Result<EditorSummary> {
    work(get(&id)?, None, move |doc, _, _| {
        let binding = EditorBinding::from(&connection);
        check_binding(&binding)?;
        let (origin, path) = if doc.raw_mode {
            let m = raw::loaded(doc)?;
            (m.target, m.path)
        } else {
            let m = &loaded(doc)?.metadata;
            (m.target.clone(), m.path.clone())
        };
        if origin != binding.target {
            bail!("SSH实际地址、用户、主机ID或指纹与草稿来源不一致；未上传");
        }
        let r = registry().lock();
        if r.closing || r.switching {
            bail!("编辑服务正在关闭或切换配置库");
        }
        crate::remote_transfers::check_editor_path(&binding.target, &path)?;
        let mut state = doc.state.lock();
        if state
            .binding
            .as_ref()
            .is_some_and(|v| v.terminal != binding.terminal)
        {
            bail!("该文档已绑定原终端；关闭并明确恢复后才能更换会话");
        }
        state.binding = Some(binding);
        drop(state);
        summary(doc)
    })
    .await
}
pub(crate) async fn update(
    id: String,
    expected: u64,
    text: String,
    format: String,
    line: String,
) -> Result<EditorSummary> {
    let text = zeroize::Zeroizing::new(text);
    work(get(&id)?, None, move |doc, _, _| {
        if doc.raw_mode {
            bail!("大正文只从带租约的外部工作文件捕获，不接受内联正文覆盖");
        }
        let old = loaded(doc)?;
        if old.metadata.revision != expected {
            bail!("编辑版本已改变，未覆盖较新草稿");
        }
        let format = Encoding::parse(&format)?;
        let line = match line.as_str() {
            "preserve" => LineEnding::Preserve,
            "lf" => LineEnding::Lf,
            "crlf" => LineEnding::Crlf,
            "cr" => LineEnding::Cr,
            _ => bail!("不支持的换行格式"),
        };
        if old.text == *text && old.metadata.encoding == format && old.metadata.line_ending == line
        {
            return summary(doc);
        }
        let mut next = EditDraft {
            metadata: old.metadata.clone(),
            text: text.to_string(),
        };
        next.metadata.revision = expected.checked_add(1).context("编辑修订号已达上限")?;
        next.metadata.encoding = format;
        next.metadata.line_ending = line;
        crate::api::with_vault(|v| Ok(EditJournal::new(v).save(&next, Some(expected))?))?;
        doc.state.lock().draft = Some(Arc::new(next));
        summary(doc)
    })
    .await
}
pub(crate) async fn save(
    id: String,
    operation: u64,
    expected: u64,
    connection: crate::transfers::Connection,
) -> Result<EditorSummary> {
    work(get(&id)?, Some(operation), move |doc, stop, handle| {
        if doc.raw_mode {
            return raw::save(doc, stop, handle, operation, expected, connection);
        }
        report(doc, operation, "preparing", None);
        let draft = loaded(doc)?;
        if draft.metadata.revision != expected {
            bail!("编辑版本已改变，请先保存最新本机草稿");
        }
        if draft.metadata.external_directory.is_some()
            && !doc
                .state
                .lock()
                .external
                .as_ref()
                .is_some_and(ExternalCopy::is_leased)
        {
            bail!("请先恢复外部工作文件，或确认清理工作文件后再保存内置草稿");
        }
        let binding = EditorBinding::from(&connection);
        let original = doc
            .state
            .lock()
            .binding
            .clone()
            .context("草稿尚未明确关联SSH终端")?;
        if original.terminal != binding.terminal || draft.metadata.target != binding.target {
            bail!("保存目标与原编辑会话或服务器身份不一致；未上传");
        }
        check_binding(&binding)?;
        let bytes = local_edits::encode(
            &draft.text,
            draft.metadata.encoding,
            draft.metadata.line_ending,
        )?;
        handle.block_on(remote(doc, binding, stop, true, async |sftp, limiter| {
            edit::write_file(sftp, &draft.metadata.path, &bytes, stop, limiter, |p| {
                report(doc, operation, "writing", Some(p))
            })
            .await?;
            report(doc, operation, "confirming", None);
            Ok(())
        }))?;
        report(doc, operation, "persisting", None);
        let saved =
            crate::api::with_vault(|v| Ok(EditJournal::new(v).mark_saved(&doc.id, expected)?))
                .context("远端内容已保存，但本机确认状态写入失败；草稿保留，可再次明确保存")?;
        let next = EditDraft {
            metadata: saved,
            text: draft.text.clone(),
        };
        doc.state.lock().draft = Some(Arc::new(next));
        summary(doc)
    })
    .await
}
pub(crate) async fn list() -> Result<Vec<EditorSummary>> {
    tokio::task::spawn_blocking(|| {
        let (rows, raw_rows) = crate::api::with_vault(|v| {
            Ok((EditJournal::new(v).list()?, RawEditJournal::new(v).list()?))
        })?;
        let r = registry().lock();
        let mut result = rows
            .iter()
            .map(|m| {
                row(
                    m,
                    r.documents
                        .values()
                        .find(|doc| doc.id == m.id)
                        .and_then(|d| d.state.lock().binding.as_ref().map(|v| v.terminal)),
                    r.documents.values().any(|doc| doc.id == m.id),
                )
            })
            .collect::<Vec<_>>();
        result.extend(raw_rows.iter().map(|m| {
            raw::row(
                m,
                r.documents
                    .values()
                    .find(|doc| doc.id == m.id)
                    .and_then(|d| d.state.lock().binding.as_ref().map(|v| v.terminal)),
                r.documents.values().any(|doc| doc.id == m.id),
            )
        }));
        Ok(result)
    })
    .await?
}
pub(crate) async fn cancel(id: String, operation: u64) -> Result<()> {
    let doc = get(&id)?;
    if let Some(op) = doc
        .state
        .lock()
        .operation
        .as_ref()
        .filter(|op| op.id == operation)
    {
        op.stop.cancel();
    }
    let _guard = doc.gate.lock().await;
    doc.channels.retire().await?;
    let mut state = doc.state.lock();
    if state
        .operation
        .as_ref()
        .is_some_and(|op| op.id == operation)
    {
        if let Some(p) = state.progress.as_mut().filter(|p| p.operation == operation) {
            p.phase = "cancelled".into();
        }
        state.operation = None;
    }
    Ok(())
}
pub(crate) async fn close(id: String, keep_draft: bool) -> Result<()> {
    let Some(doc) = registry().lock().documents.get(&id).cloned() else {
        return Ok(());
    };
    doc.closed.store(true, Ordering::Release);
    if let Some(op) = &doc.state.lock().operation {
        op.stop.cancel();
    }
    let closing = doc.clone();
    let result = tokio::task::spawn_blocking(move || {
        let _guard = closing.gate.blocking_lock();
        Handle::current().block_on(closing.channels.retire())?;
        crate::public_errors::guard_sync(|| remove_closed(&closing, keep_draft))
    })
    .await
    .map_err(|_| anyhow::anyhow!("编辑文档收尾线程异常，文档和草稿保留"))
    .and_then(|result| result);
    if result.is_err() {
        doc.closed.store(false, Ordering::Release);
    }
    result
}
/// Called while owning the entry's gate, including queued close requests.
fn remove_closed(closing: &Arc<EditorEntry>, keep_draft: bool) -> Result<()> {
    if !closing.channels.is_empty() {
        bail!("编辑SFTP子通道尚未释放，保留文档和本机草稿");
    }
    // A stale close must not delete a draft recovered under a fresh token.
    if !registry()
        .lock()
        .documents
        .get(&closing.token)
        .is_some_and(|current| Arc::ptr_eq(current, closing))
    {
        return Ok(());
    }
    if !keep_draft {
        if closing.raw_mode {
            raw::discard(&closing.id)?;
        } else {
            crate::api::with_vault(|v| Ok(EditJournal::new(v).remove(&closing.id)?))?;
        }
    }
    let copy = closing.state.lock().external.take();
    drop(copy); // Release the lease before a new runtime restores this draft.
    registry().lock().documents.remove(&closing.token);
    Ok(())
}
pub(crate) async fn discard_saved(id: String) -> Result<()> {
    tokio::task::spawn_blocking(move || {
        // Keep reservations excluded until the encrypted deletion completes.
        let r = registry().lock();
        if r.switching {
            bail!("配置库正在切换，请稍后重试");
        }
        if r.documents.values().any(|doc| doc.id == id) {
            bail!("该草稿正在编辑，请先关闭文档");
        }
        let raw = crate::api::with_vault(|v| Ok(RawEditJournal::new(v).contains(&id)?))?;
        if raw {
            raw::discard(&id)
        } else {
            crate::api::with_vault(|v| Ok(EditJournal::new(v).remove(&id)?))
        }
    })
    .await?
}
pub(crate) async fn stop_terminal(id: u32) -> Result<()> {
    let docs: Vec<_> = registry().lock().documents.values().cloned().collect();
    let mut failure = None;
    for doc in docs {
        {
            let state = doc.state.lock();
            if state.binding.as_ref().is_none_or(|b| b.terminal != id) {
                continue;
            }
            if let Some(op) = &state.operation {
                op.stop.cancel();
            }
        }
        let _guard = doc.gate.lock().await;
        if let Err(error) = doc.channels.retire().await {
            failure.get_or_insert(error);
            continue;
        }
        let mut state = doc.state.lock();
        if state
            .operation
            .as_ref()
            .is_some_and(|op| op.stop.is_cancelled())
        {
            if let Some(p) = state.progress.as_mut() {
                p.phase = "cancelled".into();
            }
            state.operation = None;
        }
    }
    if let Some(error) = failure {
        return Err(error);
    }
    Ok(())
}
pub(crate) async fn shutdown() -> Result<()> {
    let ids = {
        let mut r = registry().lock();
        r.closing = true;
        r.documents.keys().cloned().collect::<Vec<_>>()
    };
    let mut first = None;
    for id in ids {
        if let Err(error) = close(id, true).await {
            first.get_or_insert(error);
        }
    }
    if let Some(error) = first {
        return Err(error);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str) -> Arc<EditorEntry> {
        Arc::new(EditorEntry {
            token: format!("editor-{:032x}", rand::random::<u128>()),
            id: id.into(),
            requested_path: None,
            raw_mode: false,
            channels: Default::default(),
            state: Mutex::new(EditorRuntime {
                draft: None,
                raw: None,
                binding: None,
                operation: None,
                next_operation: 0,
                progress: None,
                external: None,
            }),
            gate: tokio::sync::Mutex::new(()),
            closed: AtomicBool::new(true),
        })
    }
    #[tokio::test]
    async fn caught_editor_worker_panic_retires_operation_and_allows_explicit_new_work() {
        let doc = entry("synthetic-panic-only");
        doc.closed.store(false, Ordering::Release);
        doc.state.lock().operation = Some(EditorOperation {
            id: 1,
            stop: CancellationToken::new(),
        });
        doc.state.lock().progress = Some(EditorProgress {
            operation: 1,
            phase: "waiting".into(),
            acknowledged: 0,
            total: None,
        });
        let result: Result<()> = work(doc.clone(), Some(1), |_, _, _| {
            panic!("synthetic private editor content must never escape");
        })
        .await;
        assert!(result.is_err());
        assert!(doc.state.lock().operation.is_none());
        assert_eq!(doc.state.lock().progress.as_ref().unwrap().phase, "failed");
        assert!(doc.channels.is_empty());
        assert_eq!(work(doc.clone(), None, |_, _, _| Ok(42)).await.unwrap(), 42);
        assert!(!format!("{:?}", result.unwrap_err()).contains("synthetic private"));
    }
    #[tokio::test]
    async fn editor_cancel_waits_for_the_real_worker_gate_before_clearing_ticket() {
        use tokio::time::{Duration, timeout};
        let doc = entry("synthetic-cancel-only");
        doc.closed.store(false, Ordering::Release);
        let stop = CancellationToken::new();
        doc.state.lock().operation = Some(EditorOperation {
            id: 1,
            stop: stop.clone(),
        });
        registry()
            .lock()
            .documents
            .insert(doc.token.clone(), doc.clone());
        let entered = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(tokio::sync::Notify::new());
        let worker = {
            let doc = doc.clone();
            let entered = entered.clone();
            let release = release.clone();
            tokio::spawn(async move {
                work::<()>(doc, Some(1), move |_, stop, runtime| {
                    entered.notify_one();
                    runtime.block_on(async {
                        stop.cancelled().await;
                        release.notified().await;
                    });
                    bail!("编辑操作已取消；未继续执行")
                })
                .await
            })
        };
        timeout(Duration::from_secs(2), entered.notified())
            .await
            .unwrap();
        let cancelling = {
            let id = doc.token.clone();
            tokio::spawn(cancel(id, 1))
        };
        timeout(Duration::from_secs(2), stop.cancelled())
            .await
            .unwrap();
        assert!(!cancelling.is_finished());
        assert!(doc.state.lock().operation.is_some());
        release.notify_one();
        assert!(
            timeout(Duration::from_secs(2), worker)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
        timeout(Duration::from_secs(2), cancelling)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(doc.state.lock().operation.is_none());
        close(doc.token.clone(), true).await.unwrap();
    }
    #[test]
    fn queued_stale_close_cannot_discard_a_recovered_draft() {
        let old = entry(&format!("edit-{:032x}", rand::random::<u128>()));
        registry()
            .lock()
            .documents
            .insert(old.token.clone(), old.clone());
        remove_closed(&old, true).unwrap();
        // A queued second close still owns the old Arc while recovery creates
        // a different runtime entry for the same persistent draft identity.
        let recovered = entry(&old.id);
        registry()
            .lock()
            .documents
            .insert(recovered.token.clone(), recovered.clone());
        remove_closed(&old, false).unwrap();
        assert!(Arc::ptr_eq(&get(&recovered.token).unwrap(), &recovered));
        remove_closed(&recovered, true).unwrap();
    }
}
