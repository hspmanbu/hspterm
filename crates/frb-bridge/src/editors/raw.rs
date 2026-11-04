//! Raw file bodies never become a Flutter String. These synchronous adapters
//! run only on editors::work's dedicated blocking worker, including block_on.
use super::*;
use hspterm_storage_sync::edit_blobs::{BlobInfo, BlobTicket, CHUNK_BYTES, EditBlobs};
use std::{
    io::{self, Read, Write},
    pin::Pin,
    task::{Context as TaskContext, Poll},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use zeroize::Zeroizing;

pub(super) fn loaded(doc: &EditorEntry) -> Result<RawEditMetadata> {
    doc.state.lock().raw.clone().context("大正文尚未准备完成")
}
pub(super) fn row(meta: &RawEditMetadata, terminal: Option<u32>, active: bool) -> EditorSummary {
    EditorSummary {
        id: meta.id.clone(),
        host_id: meta.target.host_id.clone(),
        address: meta.target.address.clone(),
        port: meta.target.port,
        username: meta.target.username.clone(),
        path: meta.path.clone(),
        revision: meta.revision,
        saved_revision: meta.saved_revision,
        encoding: "raw".into(),
        line_ending: "preserve".into(),
        terminal_id: terminal,
        active,
        external_directory: meta.external_directory.clone(),
        raw_bytes: Some(meta.bytes),
    }
}
fn document(doc: &EditorEntry) -> Result<EditorDocument> {
    super::current_document(doc)
}
fn io_error(error: anyhow::Error) -> io::Error {
    io::Error::other(crate::public_errors::summary(&error))
}
struct BodyWriter {
    ticket: BlobTicket,
    buffer: Zeroizing<Vec<u8>>,
}
impl BodyWriter {
    fn new(ticket: BlobTicket) -> Self {
        Self {
            ticket,
            buffer: Zeroizing::new(Vec::with_capacity(CHUNK_BYTES)),
        }
    }
    fn commit(&mut self) -> Result<()> {
        if !self.buffer.is_empty() {
            crate::api::with_vault(|v| {
                Ok(EditBlobs::new(v).append(&mut self.ticket, &self.buffer)?)
            })?;
            use zeroize::Zeroize;
            self.buffer.zeroize();
            self.buffer.clear();
        }
        Ok(())
    }
}
impl AsyncWrite for BodyWriter {
    fn poll_write(
        mut self: Pin<&mut Self>,
        _: &mut TaskContext<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        let count = bytes.len().min(CHUNK_BYTES - self.buffer.len());
        self.buffer.extend_from_slice(&bytes[..count]);
        if self.buffer.len() == CHUNK_BYTES
            && let Err(error) = self.commit()
        {
            return Poll::Ready(Err(io_error(error)));
        }
        Poll::Ready(Ok(count))
    }
    fn poll_flush(mut self: Pin<&mut Self>, _: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(self.commit().map_err(io_error))
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        self.poll_flush(cx)
    }
}
struct BodyReader {
    info: BlobInfo,
    chunk: u32,
    offset: usize,
    buffer: Zeroizing<Vec<u8>>,
}
impl BodyReader {
    fn new(info: BlobInfo) -> Self {
        Self {
            info,
            chunk: 0,
            offset: 0,
            buffer: Zeroizing::new(Vec::new()),
        }
    }
}
impl AsyncRead for BodyReader {
    fn poll_read(
        mut self: Pin<&mut Self>,
        _: &mut TaskContext<'_>,
        out: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if out.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        if self.offset == self.buffer.len() {
            if self.chunk == self.info.chunks {
                return Poll::Ready(Ok(()));
            }
            let bytes = crate::api::with_vault(|v| {
                Ok(EditBlobs::new(v).read_chunk(&self.info, self.chunk)?)
            });
            self.buffer = match bytes {
                Ok(bytes) => bytes,
                Err(error) => return Poll::Ready(Err(io_error(error))),
            };
            self.offset = 0;
            self.chunk += 1;
        }
        let count = out.remaining().min(self.buffer.len() - self.offset);
        out.put_slice(&self.buffer[self.offset..self.offset + count]);
        self.offset += count;
        Poll::Ready(Ok(()))
    }
}
fn abort(ticket: &BlobTicket) -> Result<()> {
    crate::api::with_vault(|v| {
        let mut blobs = EditBlobs::new(v);
        blobs.abort(ticket)?;
        while !blobs.reclaim_step(ticket.id(), 16)? {}
        Ok(())
    })
}
fn preserve_failure<T>(result: Result<T>, ticket: &BlobTicket) -> Result<T> {
    match result {
        Ok(value) => Ok(value),
        Err(error) => match abort(ticket) {
            Ok(()) => Err(error),
            Err(cleanup) => {
                Err(error.context(format!("未发布正文清理失败，已保留分块供恢复：{cleanup}")))
            }
        },
    }
}
pub(super) fn prepare(
    doc: &EditorEntry,
    stop: &CancellationToken,
    handle: &Handle,
    operation: u64,
) -> Result<EditorDocument> {
    if doc.state.lock().raw.is_some() {
        return document(doc);
    }
    report(doc, operation, "restoring", None);
    let stored = crate::api::with_vault(|v| {
        let journal = RawEditJournal::new(v);
        Ok(if journal.contains(&doc.id)? {
            Some(journal.load(&doc.id)?)
        } else {
            None
        })
    })?;
    let meta = match stored {
        Some(meta) if meta.ready => meta,
        stored => {
            let path = doc
                .requested_path
                .as_ref()
                .context("初次远端读取尚未完成；请重新明确打开原文件，或删除此未完成读取记录")?;
            let binding = doc
                .state
                .lock()
                .binding
                .clone()
                .context("大文件源会话缺失")?;
            check_binding(&binding)?;
            let meta = stored.unwrap_or_else(|| RawEditMetadata {
                version: 2,
                id: doc.id.clone(),
                target: binding.target.clone(),
                path: path.clone(),
                revision: 1,
                saved_revision: 0,
                bytes: 0,
                ready: false,
                external_directory: None,
            });
            if meta.target != binding.target {
                bail!("大正文来源身份已改变，未读取其他服务器");
            }
            crate::api::with_vault(|v| {
                let mut journal = RawEditJournal::new(v);
                if !journal.contains(&doc.id)? {
                    journal.create(&meta)?;
                }
                Ok(())
            })?;
            let ticket = crate::api::with_vault(|v| {
                Ok(RawEditJournal::new(v).begin_capture(&doc.id, meta.revision, None)?)
            })?;
            let mut writer = BodyWriter::new(ticket);
            let result = (|| {
                let read =
                    handle.block_on(remote(doc, binding, stop, false, async |sftp, limiter| {
                        let read = edit::read_to_writer(
                            sftp,
                            path,
                            &mut writer,
                            hspterm_storage_sync::edit_blobs::MAX_BODY_BYTES,
                            stop,
                            limiter,
                            |p| report(doc, operation, "reading", Some(p)),
                        )
                        .await?;
                        report(doc, operation, "confirming", None);
                        Ok(read)
                    }))?;
                if stop.is_cancelled() {
                    bail!("大文件读取已取消；未发布正文");
                }
                report(doc, operation, "persisting", None);
                crate::api::with_vault(|v| {
                    Ok(RawEditJournal::new(v).publish(&writer.ticket, Some(&read.path))?)
                })
            })();
            preserve_failure(result, &writer.ticket)?
        }
    };
    // Body verification happens on use; metadata restoration never decrypts an
    // entire body or implicitly establishes a network connection.
    doc.state.lock().raw = Some(meta);
    document(doc)
}
pub(super) fn pin(doc: &EditorEntry, directory: Option<String>) -> Result<()> {
    let meta = loaded(doc)?;
    let next = crate::api::with_vault(|v| {
        Ok(RawEditJournal::new(v).set_external_directory(&doc.id, meta.revision, directory)?)
    })?;
    doc.state.lock().raw = Some(next);
    Ok(())
}
pub(super) fn open_external(
    doc: &EditorEntry,
    base: Option<&str>,
    confirmed_cleanup: bool,
) -> Result<(String, bool)> {
    let meta = loaded(doc)?;
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
    doc.state.lock().external.take();
    let directory = if let Some(directory) = &meta.external_directory {
        std::fs::symlink_metadata(directory)
            .context("外部工作目录不存在；请确认清理关联，完整加密正文保留")?;
        std::path::PathBuf::from(directory)
    } else {
        let path = ExternalCopy::location(
            std::path::Path::new(base.context("请先选择外部编辑器")?),
            &doc.id,
        )?;
        pin(
            doc,
            Some(path.to_str().context("工作目录编码不支持")?.into()),
        )?;
        path
    };
    let info =
        crate::api::with_vault(|v| Ok(RawEditJournal::new(v).body(&doc.id, meta.revision)?))?;
    let initialize = |file: &mut std::fs::File| {
        for index in 0..info.chunks {
            let bytes = crate::api::with_vault(|v| Ok(EditBlobs::new(v).read_chunk(&info, index)?))
                .map_err(io_error)?;
            file.write_all(&bytes)?;
        }
        Ok(())
    };
    let (copy, existing) = if confirmed_cleanup {
        ExternalCopy::open(&directory, &doc.id, &meta.path, &[])?
    } else {
        ExternalCopy::open_stream(&directory, &doc.id, &meta.path, initialize)?
    };
    let path = copy
        .path()
        .to_str()
        .context("工作文件路径编码不支持")?
        .to_owned();
    doc.state.lock().external = Some(copy);
    Ok((path, existing))
}
fn read_piece(reader: &mut impl Read, buffer: &mut [u8]) -> Result<usize> {
    let mut count = 0;
    while count < buffer.len() {
        match reader.read(&mut buffer[count..]) {
            Ok(0) => break,
            Ok(n) => count += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(count)
}
pub(super) fn capture(doc: &EditorEntry, handle: &Handle) -> Result<Option<EditorDocument>> {
    let copy = doc
        .state
        .lock()
        .external
        .take()
        .context("请先打开或恢复外部工作文件")?;
    let result = (|| {
        let meta = loaded(doc)?;
        let current =
            crate::api::with_vault(|v| Ok(RawEditJournal::new(v).body(&doc.id, meta.revision)?))?;
        // Reclaim while holding the work-file lease, before advancing a revision.
        crate::api::with_vault(|v| {
            let mut blobs = EditBlobs::new(v);
            for info in blobs.list(&doc.id)? {
                if info.id == current.id || (!info.complete && !info.deleting) {
                    continue;
                }
                if info.complete {
                    blobs.retire_with(&info, &[], &[])?;
                }
                while !blobs.reclaim_step(&info.id, 16)? {}
            }
            Ok(())
        })?;
        let mut source = copy.reader()?;
        let length = source.length();
        let mut ticket = crate::api::with_vault(|v| {
            Ok(RawEditJournal::new(v).begin_capture(&doc.id, meta.revision, Some(length))?)
        })?;
        let result = (|| {
            let mut buffer = Zeroizing::new(vec![0; CHUNK_BYTES]);
            let mut equal = length == current.bytes;
            let mut index = 0;
            let mut count = 0u64;
            loop {
                if doc.closed.load(Ordering::Acquire) {
                    bail!("编辑文档正在关闭；原工作文件与加密正文保留");
                }
                let n = read_piece(&mut source, &mut buffer)?;
                if n == 0 {
                    break;
                }
                count = count.checked_add(n as u64).context("工作文件大小溢出")?;
                if count > length {
                    bail!("工作文件仍在变化；未发布正文");
                }
                crate::api::with_vault(|v| {
                    let mut blobs = EditBlobs::new(v);
                    if equal {
                        equal = *blobs.read_chunk(&current, index)? == buffer[..n];
                    }
                    blobs.append(&mut ticket, &buffer[..n])?;
                    Ok(())
                })?;
                index += 1;
            }
            if count != length {
                bail!("工作文件仍在变化；未发布正文");
            }
            source.finish()?;
            handle.block_on(async {
                tokio::time::sleep(std::time::Duration::from_millis(200)).await
            });
            let mut second = copy.reader()?;
            if second.length() != length {
                bail!("工作文件仍在变化；未发布正文");
            }
            // Compare full bytes from a fresh path open against the staged
            // snapshot, not remote mtime/hash or merely a pathname timestamp.
            let staged = crate::api::with_vault(|v| Ok(EditBlobs::new(v).resume(ticket.id())?))?;
            let mut checked = 0;
            for chunk in 0..index {
                let n = read_piece(&mut second, &mut buffer)?;
                let bytes = crate::api::with_vault(|v| {
                    Ok(EditBlobs::new(v).read_staging_chunk(&staged, chunk)?)
                })?;
                if bytes.as_slice() != &buffer[..n] {
                    bail!("工作文件仍在变化；未发布正文");
                }
                checked += n as u64;
            }
            if checked != length || read_piece(&mut second, &mut buffer[..1])? != 0 {
                bail!("工作文件仍在变化；未发布正文");
            }
            second.finish()?;
            if equal {
                return Ok(false);
            }
            let next =
                crate::api::with_vault(|v| Ok(RawEditJournal::new(v).publish(&ticket, None)?))?;
            doc.state.lock().raw = Some(next);
            Ok(true)
        })();
        let changed = match result {
            Ok(false) => {
                abort(&ticket)?;
                false
            }
            value => preserve_failure(value, &ticket)?,
        };
        if changed {
            Ok(Some(document(doc)?))
        } else {
            Ok(None)
        }
    })();
    doc.state.lock().external = Some(copy);
    result
}
pub(super) fn save(
    doc: &EditorEntry,
    stop: &CancellationToken,
    handle: &Handle,
    operation: u64,
    expected: u64,
    connection: crate::transfers::Connection,
) -> Result<EditorSummary> {
    let meta = loaded(doc)?;
    if meta.revision != expected {
        bail!("大正文修订已改变，未覆盖远端");
    }
    if !doc
        .state
        .lock()
        .external
        .as_ref()
        .is_some_and(ExternalCopy::is_leased)
    {
        bail!("请先恢复带租约的外部工作文件再保存");
    }
    let binding = EditorBinding::from(&connection);
    let original = doc
        .state
        .lock()
        .binding
        .clone()
        .context("草稿尚未明确关联SSH终端")?;
    if original.terminal != binding.terminal || meta.target != binding.target {
        bail!("大文件保存目标与原编辑会话身份不一致；未上传");
    }
    check_binding(&binding)?;
    let info = crate::api::with_vault(|v| Ok(RawEditJournal::new(v).body(&doc.id, expected)?))?;
    report(doc, operation, "preparing", None);
    for chunk in 0..info.chunks {
        if stop.is_cancelled() {
            bail!("大文件保存已取消；完整加密正文保留");
        }
        crate::api::with_vault(|v| {
            EditBlobs::new(v).read_chunk(&info, chunk)?;
            Ok(())
        })?;
    }
    let mut reader = BodyReader::new(info);
    handle.block_on(remote(doc, binding, stop, true, async |sftp, limiter| {
        edit::write_from_reader(
            sftp,
            &meta.path,
            &mut reader,
            meta.bytes,
            stop,
            limiter,
            |p| report(doc, operation, "writing", Some(p)),
        )
        .await?;
        report(doc, operation, "confirming", None);
        Ok(())
    }))?;
    report(doc, operation, "persisting", None);
    let saved =
        crate::api::with_vault(|v| Ok(RawEditJournal::new(v).mark_saved(&doc.id, expected)?))?;
    doc.state.lock().raw = Some(saved);
    summary(doc)
}
pub(super) fn discard(id: &str) -> Result<()> {
    crate::api::with_vault(|v| {
        let mut journal = RawEditJournal::new(v);
        if journal.contains(id)? {
            let meta = journal.load(id)?;
            journal.discard(id, meta.revision)?;
        }
        // Reclaim only this explicitly discarded owner, never other processes'
        // active captures or unrelated drafts.
        let mut blobs = EditBlobs::new(v);
        for info in blobs.list(id)? {
            while !blobs.reclaim_step(&info.id, 16)? {}
        }
        Ok(())
    })
}
