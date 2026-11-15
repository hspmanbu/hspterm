//! One pull cursor per terminal, generation/request scoped. Closing the dedicated
//! SFTP channel also cleans handles whose OPENDIR reply was never received.
use anyhow::{Context, Result, bail};
use hspterm_ssh_core::{
    ManagedSession, SessionPhase, SftpSession,
    directory::{DirectoryPage, DirectoryReader, MAX_PAGE},
    search::{RecursiveSearch, SearchPage},
};
use parking_lot::Mutex;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};
use tokio_util::sync::CancellationToken;

#[derive(Default)]
pub(crate) struct DirectoryListings {
    state: Mutex<State>,
    gate: Arc<AsyncMutex<()>>,
}
#[derive(Default)]
struct State {
    generation: u64,
    latest: u64,
    active: Option<Arc<Cursor>>,
    retired: Vec<Arc<Cursor>>,
}
struct Cursor {
    generation: u64,
    request: u64,
    stop: CancellationToken,
    channels: crate::transfer_channels::Channels,
    opening: AsyncMutex<()>,
    opened: AsyncMutex<Option<Opened>>,
}
struct Opened {
    // Drop the directory handle before closing its channel.
    reader: ListingReader,
    lease: ChannelLease,
}
enum ListingReader {
    Directory(DirectoryReader),
    Search(Box<RecursiveSearch>),
}
impl ListingReader {
    fn path(&self) -> &str {
        match self {
            Self::Directory(r) => r.path(),
            Self::Search(r) => r.root(),
        }
    }
}
enum ListingPage {
    Directory(DirectoryPage),
    Search(SearchPage),
}
impl ListingPage {
    fn done(&self) -> bool {
        match self {
            Self::Directory(p) => p.done,
            Self::Search(p) => p.done,
        }
    }
}
struct ChannelLease {
    sftp: Arc<SftpSession>,
    // Held until the cursor's actual local IO retired successfully. Cancellation
    // never transfers it to an unobserved Drop task.
    _gate: OwnedMutexGuard<()>,
}
impl DirectoryListings {
    fn reserve(&self, generation: u64, request: u64) -> Result<Arc<Cursor>> {
        let mut state = self.state.lock();
        if generation < state.generation || request == 0 {
            bail!("目录请求已过期");
        }
        if generation > state.generation {
            state.generation = generation;
            state.latest = 0;
        }
        if request <= state.latest {
            bail!("目录请求已被更新请求替代");
        }
        if let Some(old) = state.active.take() {
            old.stop.cancel();
            state.retired.push(old);
        }
        Self::prune_retired(&mut state);
        state.latest = request;
        let cursor = Arc::new(Cursor {
            generation,
            request,
            stop: CancellationToken::new(),
            channels: Default::default(),
            opening: AsyncMutex::new(()),
            opened: AsyncMutex::new(None),
        });
        state.active = Some(cursor.clone());
        Ok(cursor)
    }
    fn get(&self, generation: u64, request: u64) -> Result<Arc<Cursor>> {
        self.state
            .lock()
            .active
            .as_ref()
            .filter(|c| c.generation == generation && c.request == request)
            .cloned()
            .context("目录游标已关闭或被更新请求替代")
    }
    fn remove(&self, generation: u64, request: u64) -> Option<Arc<Cursor>> {
        let mut state = self.state.lock();
        if state
            .active
            .as_ref()
            .is_some_and(|c| c.generation == generation && c.request == request)
        {
            let cursor = state.active.take().expect("matched active cursor");
            cursor.stop.cancel();
            state.retired.push(cursor.clone());
            Some(cursor)
        } else {
            None
        }
    }
    fn prune_retired(state: &mut State) {
        state.retired.retain(|cursor| {
            cursor.opening.try_lock().is_err()
                || !cursor.channels.is_empty()
                || cursor
                    .opened
                    .try_lock()
                    .map_or(true, |opened| opened.is_some())
        });
    }
    async fn release(cursor: &Cursor) -> Result<()> {
        cursor.stop.cancel();
        // Same lock as page consumption. stop causes the page select to drop
        // READDIR before this lock is acquired; no stalled protocol CLOSE wait.
        // Opening owns this barrier until its future completes or is dropped.
        // A concurrent replacement cannot prune an as-yet-unadopted channel.
        let _opening = cursor.opening.lock().await;
        let mut opened = cursor.opened.lock().await;
        cursor
            .channels
            .retire()
            .await
            .context("释放目录读取子通道失败")?;
        // Failure leaves the reader/lease and gate in the registered cursor.
        opened.take();
        Ok(())
    }
    async fn retire_pending(&self) -> Result<()> {
        let retired = self.state.lock().retired.clone();
        let mut first = None;
        for cursor in retired {
            if let Err(error) = Self::release(&cursor).await {
                first.get_or_insert(error);
            }
        }
        Self::prune_retired(&mut self.state.lock());
        if let Some(error) = first {
            return Err(error);
        }
        Ok(())
    }
    pub async fn open(
        &self,
        session: Arc<ManagedSession>,
        closing: Arc<AtomicBool>,
        generation: u64,
        request: u64,
        path: String,
    ) -> Result<String> {
        self.open_listing(session, closing, generation, request, path, None)
            .await
    }
    #[allow(clippy::too_many_arguments)]
    pub async fn open_search(
        &self,
        session: Arc<ManagedSession>,
        closing: Arc<AtomicBool>,
        generation: u64,
        request: u64,
        path: String,
        query: String,
        case_sensitive: bool,
    ) -> Result<String> {
        self.open_listing(
            session,
            closing,
            generation,
            request,
            path,
            Some((query, case_sensitive)),
        )
        .await
    }
    #[allow(clippy::too_many_arguments)]
    async fn open_listing(
        &self,
        session: Arc<ManagedSession>,
        closing: Arc<AtomicBool>,
        generation: u64,
        request: u64,
        path: String,
        query: Option<(String, bool)>,
    ) -> Result<String> {
        let cursor = self.reserve(generation, request)?;
        // Old idle/error cursors remain registered until actual IO has retired.
        // Do this before waiting for the gate held by any previous reader.
        if let Err(error) = self.retire_pending().await {
            self.remove(generation, request);
            Self::prune_retired(&mut self.state.lock());
            return Err(error);
        }
        // Independent of Flutter event consumption: an idle cursor must release
        // its metadata/channel as soon as this transport disconnects.
        let weak = Arc::downgrade(&cursor);
        let stop = cursor.stop.clone();
        let mut states = session.subscribe();
        tokio::spawn(async move {
            loop {
                let status = states.borrow_and_update().clone();
                if status.phase != SessionPhase::Connected || status.generation != generation {
                    stop.cancel();
                    if let Some(cursor) = weak.upgrade() {
                        // The transport is already gone. Normal completion and
                        // explicit close report errors to their awaiting caller.
                        let _ = Self::release(&cursor).await;
                    }
                    break;
                }
                tokio::select! { biased;
                    _ = stop.cancelled() => break,
                    result = states.changed() => {
                        if result.is_err() {
                            stop.cancel();
                            if let Some(cursor) = weak.upgrade() { let _ = Self::release(&cursor).await; }
                            break;
                        }
                    }
                }
            }
        });
        let work = async {
            let _opening = cursor.opening.lock().await;
            if cursor.stop.is_cancelled() {
                bail!("目录请求已取消");
            }
            let gate = self.gate.clone().lock_owned().await;
            if cursor.stop.is_cancelled() {
                bail!("目录请求已取消");
            }
            let remote = cursor
                .channels
                .open(&session, generation, &cursor.stop)
                .await?;
            let lease = ChannelLease {
                sftp: remote,
                _gate: gate,
            };
            let reader = match query {
                None => ListingReader::Directory(DirectoryReader::open(&lease.sftp, path).await?),
                Some((text, case_sensitive)) => ListingReader::Search(Box::new(
                    RecursiveSearch::open(&lease.sftp, &path, &text, case_sensitive, &cursor.stop)
                        .await?,
                )),
            };
            let status = session.status();
            if status.phase != SessionPhase::Connected
                || status.generation != generation
                || closing.load(Ordering::Acquire)
            {
                bail!("关联SSH会话已改变或断开");
            }
            let path = reader.path().to_owned();
            let mut opened = cursor.opened.lock().await;
            if cursor.stop.is_cancelled() {
                bail!("目录请求已取消");
            }
            *opened = Some(Opened { reader, lease });
            Ok(path)
        };
        let result = tokio::select! { biased;
            _ = cursor.stop.cancelled() => Err(anyhow::anyhow!("目录请求已取消")),
            result = work => result,
        };
        if result.is_err() {
            self.remove(generation, request);
            let cleanup = Self::release(&cursor).await;
            Self::prune_retired(&mut self.state.lock());
            if let Err(_cleanup) = cleanup {
                return Err(result
                    .expect_err("failed opening")
                    .context("目录打开失败；释放子通道也失败"));
            }
        }
        result
    }
    pub async fn page(&self, generation: u64, request: u64, limit: usize) -> Result<DirectoryPage> {
        match self.page_listing(generation, request, limit).await? {
            ListingPage::Directory(page) => Ok(page),
            ListingPage::Search(_) => bail!("请求类型不是目录列表"),
        }
    }
    pub async fn search_page(
        &self,
        generation: u64,
        request: u64,
        limit: usize,
    ) -> Result<SearchPage> {
        match self.page_listing(generation, request, limit).await? {
            ListingPage::Search(page) => Ok(page),
            ListingPage::Directory(_) => bail!("请求类型不是递归搜索"),
        }
    }
    async fn page_listing(
        &self,
        generation: u64,
        request: u64,
        limit: usize,
    ) -> Result<ListingPage> {
        if !(1..=MAX_PAGE).contains(&limit) {
            bail!("目录分页大小必须为1–256");
        }
        let cursor = self.get(generation, request)?;
        let work = async {
            let mut opened = cursor.opened.lock().await;
            let opened = opened.as_mut().context("目录仍在打开")?;
            match &mut opened.reader {
                ListingReader::Directory(reader) => {
                    let mut page = reader.next_page(limit).await?;
                    // Listing attributes describe the link, not its target.
                    // Resolve type only for UI navigation/icons, never recurse
                    // into it or replace link permissions/size with the target.
                    use futures_util::{StreamExt, stream};
                    let links = page
                        .entries
                        .iter()
                        .enumerate()
                        .filter(|(_, f)| f.symlink)
                        .map(|(i, f)| (i, f.path.clone()))
                        .collect::<Vec<_>>();
                    let sftp = &opened.lease.sftp;
                    let probes = stream::iter(links)
                        .map(|(index, path)| async move { (index, sftp.metadata(path).await) })
                        .buffer_unordered(8);
                    tokio::pin!(probes);
                    // Best-effort classification must not let a broken link
                    // block a directory page. Explicit open resolves again.
                    let deadline = tokio::time::sleep(std::time::Duration::from_secs(2));
                    tokio::pin!(deadline);
                    loop {
                        tokio::select! { biased;
                            _ = cursor.stop.cancelled() => break,
                            _ = &mut deadline => break,
                            next = probes.next() => match next {
                                Some((index, Ok(attrs))) => page.entries[index].directory = attrs.is_dir(),
                                Some((_, Err(_))) => {}, // dangling/inaccessible: retain link metadata
                                None => break,
                            }
                        }
                    }
                    Ok(ListingPage::Directory(page))
                }
                ListingReader::Search(reader) => Ok(ListingPage::Search(
                    reader
                        .next_page(&opened.lease.sftp, limit, &cursor.stop)
                        .await?,
                )),
            }
        };
        let result: Result<ListingPage> = tokio::select! { biased;
            _ = cursor.stop.cancelled() => Err(anyhow::anyhow!("目录请求已取消")),
            result = work => result,
        };
        if !result.as_ref().is_ok_and(|p| !p.done()) {
            self.remove(generation, request);
            let cleanup = Self::release(&cursor).await;
            // Concurrent close_all can prune while this release still holds
            // its barrier. The final releaser must retire the completed node.
            Self::prune_retired(&mut self.state.lock());
            if let Err(cleanup) = cleanup {
                return match result {
                    Ok(_) => Err(cleanup),
                    Err(error) => Err(error.context("目录读取失败；释放子通道也失败")),
                };
            }
        }
        result
    }
    pub async fn close(&self, generation: u64, request: u64) -> Result<()> {
        let cursor = self.remove(generation, request).or_else(|| {
            self.state
                .lock()
                .retired
                .iter()
                .find(|c| c.generation == generation && c.request == request)
                .cloned()
        });
        if let Some(cursor) = cursor {
            Self::release(&cursor).await?;
        }
        Self::prune_retired(&mut self.state.lock());
        Ok(())
    }
    pub async fn close_all(&self) -> Result<()> {
        {
            let mut state = self.state.lock();
            if let Some(cursor) = state.active.take() {
                cursor.stop.cancel();
                state.retired.push(cursor);
            }
        }
        self.retire_pending().await
    }
}
impl Drop for DirectoryListings {
    fn drop(&mut self) {
        let state = self.state.get_mut();
        if let Some(cursor) = state.active.take() {
            cursor.stop.cancel();
        }
        for cursor in &state.retired {
            cursor.stop.cancel();
        }
        // Normal Entry shutdown explicitly awaits close_all. Root SFTP lifetime
        // bounds remain the fallback for destruction of an entire runtime.
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn cancelling_a_stalled_readdir_releases_the_channel_and_gate() {
        use russh_sftp::{
            protocol::{File, FileAttributes, Handle, Name, StatusCode},
            server::Handler,
        };
        use tokio::{
            sync::Notify,
            time::{Duration, timeout},
        };
        struct Peer {
            entered: Arc<Notify>,
            release: Arc<Notify>,
        }
        impl Handler for Peer {
            type Error = StatusCode;
            fn unimplemented(&self) -> Self::Error {
                StatusCode::OpUnsupported
            }
            async fn realpath(&mut self, id: u32, _: String) -> Result<Name, Self::Error> {
                Ok(Name {
                    id,
                    files: vec![File::new("/fixture", FileAttributes::default())],
                })
            }
            async fn opendir(&mut self, id: u32, _: String) -> Result<Handle, Self::Error> {
                Ok(Handle {
                    id,
                    handle: "directory".into(),
                })
            }
            async fn readdir(&mut self, _: u32, _: String) -> Result<Name, Self::Error> {
                self.entered.notify_one();
                self.release.notified().await;
                Err(StatusCode::Eof)
            }
        }
        for (recursive, abort_page) in [(false, false), (true, false), (false, true), (true, true)]
        {
            let entered = Arc::new(Notify::new());
            let release = Arc::new(Notify::new());
            let (client, server) = tokio::io::duplex(4096);
            let server = tokio::spawn(russh_sftp::server::run_owned(
                server,
                Peer {
                    entered: entered.clone(),
                    release: release.clone(),
                },
            ));
            let remote = Arc::new(SftpSession::new(client).await.unwrap());
            let registry = Arc::new(DirectoryListings::default());
            let cursor = registry.reserve(1, 1).unwrap();
            let reader = if recursive {
                ListingReader::Search(Box::new(
                    RecursiveSearch::open(
                        &remote,
                        "/fixture",
                        "match",
                        false,
                        &CancellationToken::new(),
                    )
                    .await
                    .unwrap(),
                ))
            } else {
                ListingReader::Directory(
                    DirectoryReader::open(&remote, "/fixture".into())
                        .await
                        .unwrap(),
                )
            };
            *cursor.opened.lock().await = Some(Opened {
                reader,
                lease: ChannelLease {
                    sftp: cursor.channels.adopt_arc(remote),
                    _gate: registry.gate.clone().lock_owned().await,
                },
            });
            let reading = {
                let registry = registry.clone();
                tokio::spawn(async move { registry.page_listing(1, 1, 256).await })
            };
            timeout(Duration::from_secs(2), entered.notified())
                .await
                .unwrap();
            if abort_page {
                // Simulate loss of a caller future, not remote server shutdown.
                // Cursor ownership survives and explicit close still joins IO.
                reading.abort();
            }
            timeout(Duration::from_secs(1), registry.close_all())
                .await
                .unwrap()
                .unwrap();
            let read_result = timeout(Duration::from_secs(1), reading).await.unwrap();
            if abort_page {
                assert!(matches!(read_result, Err(error) if error.is_cancelled()));
            } else {
                assert!(read_result.unwrap().is_err());
            }
            assert!(cursor.channels.is_empty());
            assert!(registry.state.lock().retired.is_empty());
            assert!(registry.gate.try_lock().is_ok());
            assert!(cursor.opened.lock().await.is_none());
            release.notify_one();
            timeout(Duration::from_secs(2), server)
                .await
                .unwrap()
                .unwrap();
        }
    }
    #[tokio::test]
    async fn replacement_retains_an_open_in_progress_until_its_actual_barrier_ends() {
        use tokio::time::{Duration, timeout};
        let listings = Arc::new(DirectoryListings::default());
        let old = listings.reserve(3, 1).unwrap();
        let opening = old.opening.lock().await;
        let current = listings.reserve(3, 2).unwrap();
        assert!(old.stop.is_cancelled());
        assert_eq!(listings.state.lock().retired.len(), 1);
        let mut retirement = {
            let listings = listings.clone();
            tokio::spawn(async move { listings.retire_pending().await })
        };
        assert!(
            timeout(Duration::from_millis(20), &mut retirement)
                .await
                .is_err()
        );
        assert!(!current.stop.is_cancelled());
        drop(opening);
        timeout(Duration::from_secs(2), retirement)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(listings.state.lock().retired.is_empty());
        assert!(Arc::ptr_eq(&listings.get(3, 2).unwrap(), &current));
        listings.close_all().await.unwrap();
    }
    #[tokio::test]
    async fn old_requests_cleanup_and_generations_cannot_close_a_newer_cursor() {
        let listings = DirectoryListings::default();
        let old = listings.reserve(7, 2).unwrap();
        let new = listings.reserve(7, 3).unwrap();
        assert!(old.stop.is_cancelled());
        assert!(!new.stop.is_cancelled());
        assert!(listings.reserve(7, 2).is_err());
        assert!(listings.reserve(6, 100).is_err());
        listings.close(7, 2).await.unwrap();
        assert!(!new.stop.is_cancelled());
        let reconnected = listings.reserve(8, 1).unwrap();
        assert!(new.stop.is_cancelled());
        listings.close(7, 3).await.unwrap();
        assert!(!reconnected.stop.is_cancelled());
        assert!(listings.get(7, 3).is_err());
        listings.close_all().await.unwrap();
        assert!(reconnected.stop.is_cancelled());
        assert!(listings.get(8, 1).is_err());
    }
}
