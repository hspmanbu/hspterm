//! Immutable encrypted cold rows. Keys exist only for this process/session.
use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{AeadInPlace, Payload},
};
use alacritty_terminal::{
    grid::{Dimensions, Grid, Row, RowBacking},
    index::Line,
    term::cell::Cell,
};
use fs2::FileExt;
use parking_lot::Mutex;
use rand::{RngCore, rngs::OsRng};
use std::{
    fs::{self, File, OpenOptions},
    io,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};
use tempfile::{NamedTempFile, TempDir};
use zeroize::Zeroizing;

const SEGMENT_BYTES: u64 = 4 * 1024 * 1024;
const MAX_ROW_BYTES: usize = 64 * 1024 * 1024;
pub const DEFAULT_RAM_HISTORY_ROWS: usize = 256;
/// Upper bound for the degraded RAM-only history so the fallback can never
/// grow unbounded when the encrypted cold store is unavailable.
const DEGRADED_RAM_ROWS: usize = 8192;

#[derive(Clone, Copy, Debug, Default)]
pub struct HistoryStats {
    pub disk_bytes: u64,
    pub disk_reads: u64,
    pub disk_writes: u64,
    pub resident_history_cells: usize,
    pub retained_rows: usize,
}
// Keep removal in the same registry critical section as discovery/creation.
// Field order closes the owner before deleting the directory, and releases
// the registry last. Windows directory enumeration otherwise races delete-pending
// owner files even though the owner itself remains exclusively locked.
struct RunDirectory {
    _owner: File,
    directory: Option<TempDir>,
    registry: File,
}
impl RunDirectory {
    fn path(&self) -> &Path {
        self.directory
            .as_ref()
            .expect("live history directory")
            .path()
    }
}
impl Drop for RunDirectory {
    fn drop(&mut self) {
        if self.registry.lock_exclusive().is_err() {
            // Leave encrypted remnants for the next successful stale cleanup
            // rather than removing them concurrently with registry discovery.
            if let Some(directory) = self.directory.take() {
                let _ = directory.keep();
            }
        }
    }
}
struct Run {
    directory: RunDirectory,
    key: Zeroizing<[u8; 32]>,
    fault: Mutex<Option<String>>,
    bytes: AtomicU64,
    reads: AtomicU64,
    writes: AtomicU64,
}
impl Run {
    fn check(&self) -> io::Result<()> {
        match self.fault.lock().as_ref() {
            Some(message) => Err(io::Error::other(message.clone())),
            None => Ok(()),
        }
    }
    fn fail(&self, error: &io::Error) {
        let mut fault = self.fault.lock();
        if fault.is_none() {
            *fault = Some(format!("临时终端历史读写失败（{}）", error.kind()));
        }
    }
}
struct Segment {
    file: NamedTempFile,
    #[cfg(not(unix))]
    io_lock: Mutex<()>,
    length: AtomicU64,
    run: Arc<Run>,
}
impl Segment {
    fn new(run: Arc<Run>) -> io::Result<Arc<Self>> {
        let file = tempfile::Builder::new()
            .prefix("segment-")
            .tempfile_in(run.directory.path())?;
        Ok(Arc::new(Self {
            file,
            #[cfg(not(unix))]
            io_lock: Mutex::new(()),
            length: AtomicU64::new(0),
            run,
        }))
    }
    fn read(&self, offset: u64, bytes: &mut [u8]) -> io::Result<()> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::FileExt;
            self.file.as_file().read_exact_at(bytes, offset)
        }
        #[cfg(not(unix))]
        {
            use std::io::{Read, Seek, SeekFrom};
            let _guard = self.io_lock.lock();
            let mut file = self.file.as_file();
            file.seek(SeekFrom::Start(offset))?;
            file.read_exact(bytes)
        }
    }
    fn write(&self, offset: u64, bytes: &[u8]) -> io::Result<()> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::FileExt;
            self.file.as_file().write_all_at(bytes, offset)
        }
        #[cfg(not(unix))]
        {
            use std::io::{Seek, SeekFrom, Write};
            let _guard = self.io_lock.lock();
            let mut file = self.file.as_file();
            file.seek(SeekFrom::Start(offset))?;
            file.write_all(bytes)
        }
    }
}
impl Drop for Segment {
    fn drop(&mut self) {
        self.run
            .bytes
            .fetch_sub(self.length.load(Ordering::Relaxed), Ordering::Relaxed);
    }
}
/// Degraded-mode row backing: keeps paged-out cells in RAM. Used only when
/// the encrypted cold-history store cannot be created (e.g. a locked-down
/// temp directory); history stays bounded by the reduced RAM row budget so
/// memory remains capped instead of failing terminal creation outright.
struct MemoryRow {
    columns: usize,
    cells: Mutex<Vec<Cell>>,
}
impl std::fmt::Debug for MemoryRow {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MemoryRow")
            .field("columns", &self.columns)
            .finish_non_exhaustive()
    }
}
impl RowBacking<Cell> for MemoryRow {
    fn columns(&self) -> usize {
        self.columns
    }
    fn load(&self) -> Vec<Cell> {
        self.cells.lock().clone()
    }
}
struct DiskRow {
    segment: Arc<Segment>,
    offset: u64,
    length: usize,
    columns: usize,
}
impl std::fmt::Debug for DiskRow {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EncryptedRow")
            .field("columns", &self.columns)
            .finish_non_exhaustive()
    }
}
fn aad(offset: u64, columns: usize) -> [u8; 16] {
    let mut value = [0; 16];
    value[..8].copy_from_slice(&offset.to_le_bytes());
    value[8..].copy_from_slice(&(columns as u64).to_le_bytes());
    value
}
impl DiskRow {
    fn read(&self) -> io::Result<Vec<Cell>> {
        self.segment.run.check()?;
        let mut bytes = Zeroizing::new(vec![0; self.length]);
        self.segment.read(self.offset, &mut bytes)?;
        if bytes.len() < 28 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "历史密文截断"));
        }
        let cipher = Aes256Gcm::new_from_slice(self.segment.run.key.as_ref())
            .map_err(|_| io::Error::other("历史密钥长度无效"))?;
        use aes_gcm::aead::Aead;
        let compressed = Zeroizing::new(
            cipher
                .decrypt(
                    Nonce::from_slice(&bytes[..12]),
                    Payload {
                        msg: &bytes[12..],
                        aad: &aad(self.offset, self.columns),
                    },
                )
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "历史密文认证失败"))?,
        );
        let decoded_len = lz4_flex::block::uncompressed_size(&compressed)
            .map_err(io::Error::other)?
            .0;
        if decoded_len > MAX_ROW_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "历史行超出解码限制",
            ));
        }
        let plain = Zeroizing::new(
            lz4_flex::decompress_size_prepended(&compressed).map_err(io::Error::other)?,
        );
        let cells: Vec<Cell> = postcard::from_bytes(&plain).map_err(io::Error::other)?;
        if cells.len() != self.columns {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "历史行宽度不一致",
            ));
        }
        self.segment.run.reads.fetch_add(1, Ordering::Relaxed);
        Ok(cells)
    }
}
impl RowBacking<Cell> for DiskRow {
    fn columns(&self) -> usize {
        self.columns
    }
    fn load(&self) -> Vec<Cell> {
        match self.read() {
            Ok(cells) => cells,
            Err(error) => {
                // Index cannot return Result. Latch the failure; checked snapshots
                // and the actor reject it before a frame or further output is published.
                self.segment.run.fail(&error);
                vec![Cell::default(); self.columns]
            }
        }
    }
}

pub(crate) struct HistoryPager {
    run: Option<Arc<Run>>,
    current: Option<Arc<Segment>>,
    ram_rows: usize,
}
impl HistoryPager {
    pub fn new(ram_rows: usize) -> io::Result<Self> {
        match Self::try_new(ram_rows) {
            Ok(pager) => Ok(pager),
            Err(_) => {
                // Degraded RAM-only mode: a terminal without cold history is
                // strictly better than no terminal at all (2026-11-05 second
                // connection failures). Bounded so memory stays capped.
                Ok(Self::ram_only(ram_rows))
            }
        }
    }
    /// Bounded RAM-only fallback; rows page into memory backings.
    pub(crate) fn ram_only(ram_rows: usize) -> Self {
        Self {
            run: None,
            current: None,
            ram_rows: ram_rows.min(DEGRADED_RAM_ROWS),
        }
    }
    fn try_new(ram_rows: usize) -> io::Result<Self> {
        let root = history_root()?;
        // Windows endpoints hit transient create/lock failures under antivirus
        // or indexing scanners; a fresh run directory name dodges them without
        // masking persistent permission errors (which still surface verbatim).
        let mut last = None;
        for attempt in 0..3 {
            match Self::new_in(&root, ram_rows) {
                Ok(pager) => return Ok(pager),
                Err(error) => {
                    last = Some(error);
                    if attempt + 1 < 3 {
                        std::thread::sleep(std::time::Duration::from_millis(
                            120 * (attempt as u64 + 1),
                        ));
                    }
                }
            }
        }
        Err(last.unwrap_or_else(|| io::Error::other("终端临时历史创建失败")))
    }
    pub(crate) fn new_in(root: &Path, ram_rows: usize) -> io::Result<Self> {
        ensure_root(root)?;
        // Serialize discovery + creation across processes. An owner.lock file
        // exists briefly before its exclusive lock is acquired; without this
        // registry lock another new terminal could mistake that run for stale.
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options
                .mode(0o600)
                .custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
        }
        let registry = options.open(root.join("registry.lock"))?;
        registry.lock_exclusive()?;
        cleanup_stale(root)?;
        let directory = tempfile::Builder::new().prefix("run-").tempdir_in(root)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(directory.path().join("owner.lock"))?;
        lock.lock_exclusive()?;
        let cleanup_registry = registry.try_clone()?;
        // The retained descriptor must be unlocked before its drop guard exists.
        FileExt::unlock(&registry)?;
        drop(registry);
        let mut key = Zeroizing::new([0; 32]);
        OsRng.fill_bytes(key.as_mut());
        let run = Arc::new(Run {
            directory: RunDirectory {
                _owner: lock,
                directory: Some(directory),
                registry: cleanup_registry,
            },
            key,
            fault: Mutex::new(None),
            bytes: AtomicU64::new(0),
            reads: AtomicU64::new(0),
            writes: AtomicU64::new(0),
        });
        let current = Segment::new(run.clone())?;
        Ok(Self {
            run: Some(run),
            current: Some(current),
            ram_rows,
        })
    }
    pub fn check(&self) -> io::Result<()> {
        match &self.run {
            Some(run) => run.check(),
            // RAM-only degraded mode has no fault channel.
            None => Ok(()),
        }
    }
    pub fn fault_checker(&self) -> Arc<dyn Fn() -> io::Result<()> + Send + Sync> {
        let run = self.run.clone();
        Arc::new(move || match &run {
            Some(run) => run.check(),
            None => Ok(()),
        })
    }
    fn store(&mut self, row: &Row<Cell>) -> io::Result<Arc<dyn RowBacking<Cell>>> {
        self.check()?;
        if self.run.is_none() {
            // Degraded mode: keep the cells in RAM behind the same bounded
            // interface; the reduced ram_rows budget caps the total.
            return Ok(Arc::new(MemoryRow {
                columns: row.len(),
                cells: Mutex::new(row[..].to_vec()),
            }));
        }
        let plain = Zeroizing::new(postcard::to_allocvec(&row[..]).map_err(io::Error::other)?);
        if plain.len() > MAX_ROW_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::OutOfMemory,
                "终端历史单行过大",
            ));
        }
        let mut compressed = Zeroizing::new(lz4_flex::compress_prepend_size(&plain));
        let run = self.run.as_ref().expect("checked above");
        if self
            .current
            .as_ref()
            .expect("disk mode")
            .length
            .load(Ordering::Relaxed)
            > SEGMENT_BYTES
        {
            let segment = Segment::new(run.clone())?;
            self.current = Some(segment);
        }
        let current = self.current.as_ref().expect("disk mode");
        let offset = current.length.load(Ordering::Relaxed);
        let cipher = Aes256Gcm::new_from_slice(run.key.as_ref())
            .map_err(|_| io::Error::other("历史密钥长度无效"))?;
        let mut nonce = [0; 12];
        OsRng.fill_bytes(&mut nonce);
        cipher
            .encrypt_in_place(
                Nonce::from_slice(&nonce),
                &aad(offset, row.len()),
                &mut *compressed,
            )
            .map_err(|_| io::Error::other("历史加密失败"))?;
        let length = nonce.len() + compressed.len();
        let mut record = Vec::with_capacity(length);
        record.extend_from_slice(&nonce);
        record.extend_from_slice(&compressed);
        current.write(offset, &record)?;
        current.length.fetch_add(length as u64, Ordering::Relaxed);
        run.bytes.fetch_add(length as u64, Ordering::Relaxed);
        run.writes.fetch_add(1, Ordering::Relaxed);
        Ok(Arc::new(DiskRow {
            segment: self.current.clone().expect("disk mode"),
            offset,
            length,
            columns: row.len(),
        }))
    }
    pub fn needs_reflow_paging(&self, rows: usize) -> bool {
        rows > self.ram_rows
    }
    pub fn page_reflow_row(&mut self, row: &mut Row<Cell>) {
        if row.is_paged() || self.check().is_err() {
            return;
        }
        match self.store(row) {
            Ok(page) => row.page_out(page),
            Err(error) => {
                if let Some(run) = &self.run {
                    run.fail(&error);
                }
            }
        }
    }
    pub fn checkpoint(&mut self, grid: &mut Grid<Cell>, full: bool) -> io::Result<()> {
        self.check()?;
        if full {
            grid.evict_history_cache();
        }
        let history = grid.history_size();
        for age in self.ram_rows + 1..=history {
            let row = &mut grid[Line(-(age as i32))];
            if row.is_paged() {
                if !full {
                    break;
                }
                continue;
            }
            let page = match self.store(row) {
                Ok(page) => page,
                Err(error) => {
                    if let Some(run) = &self.run {
                        run.fail(&error);
                    }
                    return Err(error);
                }
            };
            row.page_out(page);
        }
        self.check()
    }
    pub fn stats(&self, grid: &Grid<Cell>) -> HistoryStats {
        HistoryStats {
            disk_bytes: self
                .run
                .as_ref()
                .map_or(0, |run| run.bytes.load(Ordering::Relaxed)),
            disk_reads: self
                .run
                .as_ref()
                .map_or(0, |run| run.reads.load(Ordering::Relaxed)),
            disk_writes: self
                .run
                .as_ref()
                .map_or(0, |run| run.writes.load(Ordering::Relaxed)),
            resident_history_cells: grid.resident_history_cells(),
            retained_rows: grid.history_size(),
        }
    }
    #[cfg(test)]
    pub fn path(&self) -> &Path {
        self.run
            .as_ref()
            .expect("tests exercise the disk-backed pager")
            .directory
            .path()
    }
}
fn history_root() -> io::Result<PathBuf> {
    #[cfg(unix)]
    let name = format!("hspterm-history-v1-{}", rustix::process::geteuid().as_raw());
    #[cfg(not(unix))]
    let name = "hspterm-history-v1".to_owned();
    let root = std::env::temp_dir().join(name);
    ensure_root(&root)?;
    Ok(root)
}
fn ensure_root(root: &Path) -> io::Result<()> {
    let builder = fs::DirBuilder::new();
    #[cfg(unix)]
    let mut builder = builder;
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    if let Err(error) = builder.create(root)
        && error.kind() != io::ErrorKind::AlreadyExists
    {
        return Err(error);
    }
    let metadata = fs::symlink_metadata(root)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "历史缓存路径非安全目录",
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != rustix::process::geteuid().as_raw() || metadata.mode() & 0o077 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "历史目录权限不安全",
            ));
        }
    }
    Ok(())
}
fn cleanup_stale(root: &Path) -> io::Result<()> {
    for item in fs::read_dir(root)? {
        let item = item?;
        if !item.file_name().to_string_lossy().starts_with("run-") || !item.file_type()?.is_dir() {
            continue;
        }
        let mut options = OpenOptions::new();
        options.read(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(rustix::fs::OFlags::NOFOLLOW.bits() as i32);
        }
        let lock = match options.open(item.path().join("owner.lock")) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                // No creator can still be between mkdir and owner.lock while
                // the registry lock is held: this is an interrupted creation.
                match fs::remove_dir_all(item.path()) {
                    Ok(()) => {}
                    Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                    Err(e) => return Err(e),
                }
                continue;
            }
            Err(error) => return Err(error),
        };
        match lock.try_lock_exclusive() {
            Ok(()) => {
                drop(lock);
                if let Err(error) = fs::remove_dir_all(item.path())
                    && error.kind() != io::ErrorKind::NotFound
                {
                    return Err(error);
                }
            }
            // fs2 reports ERROR_LOCK_VIOLATION on Windows, which Rust maps
            // to Uncategorized rather than WouldBlock. This means the run is
            // live, not that creating another terminal's history has failed.
            Err(error)
                if error.kind() == io::ErrorKind::WouldBlock
                    || error.raw_os_error() == fs2::lock_contended_error().raw_os_error() => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn encrypted_round_trip_tamper_fails_closed_and_files_are_removed() {
        let root = tempfile::tempdir().unwrap();
        let mut pager = HistoryPager::new_in(&root.path().join("cache"), 2).unwrap();
        let path = pager.path().to_owned();
        let mut row = Row::<Cell>::new(20);
        row[alacritty_terminal::index::Column(0)].c = '中';
        row[alacritty_terminal::index::Column(0)].push_zerowidth('\u{301}');
        let expected = row.clone();
        let page = pager.store(&row).unwrap();
        row.page_out(page);
        assert_eq!(row, expected);
        row.evict_cached();
        let file = fs::read_dir(&path)
            .unwrap()
            .map(|e| e.unwrap().path())
            .find(|p| {
                p.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("segment-")
            })
            .unwrap();
        let mut bytes = fs::read(&file).unwrap();
        assert!(!bytes.windows("中".len()).any(|v| v == "中".as_bytes()));
        bytes[14] ^= 1;
        fs::write(file, bytes).unwrap();
        let _ = row[alacritty_terminal::index::Column(0)].c;
        assert!(pager.check().is_err());
        drop(row);
        drop(pager);
        assert!(!path.exists());
    }
    #[test]
    fn concurrent_creation_never_cleans_a_live_run() {
        let root = tempfile::tempdir().unwrap();
        let cache = root.path().join("cache");
        let barrier = std::sync::Barrier::new(12);
        std::thread::scope(|scope| {
            for _ in 0..12 {
                let cache = &cache;
                let barrier = &barrier;
                scope.spawn(move || {
                    barrier.wait();
                    let mut active = Vec::new();
                    for _ in 0..30 {
                        let mut pager = HistoryPager::new_in(cache, 1).unwrap();
                        let row = Row::<Cell>::new(40);
                        let page = pager.store(&row).unwrap();
                        assert_eq!(page.load(), row.owned_cells());
                        active.push(pager);
                    }
                    for pager in &active {
                        assert!(pager.path().exists());
                    }
                });
            }
        });
        assert_eq!(fs::read_dir(cache).unwrap().count(), 1); // registry only
    }
    #[test]
    fn stale_cleanup_preserves_active_runs() {
        let root = tempfile::tempdir().unwrap();
        let active = HistoryPager::new_in(&root.path().join("cache"), 2).unwrap();
        let active_path = active.path().to_owned();
        let stale = root.path().join("cache/run-abandoned");
        fs::create_dir(&stale).unwrap();
        File::create(stale.join("owner.lock")).unwrap();
        fs::write(stale.join("encrypted-segment"), b"synthetic").unwrap();
        let next = HistoryPager::new_in(&root.path().join("cache"), 2).unwrap();
        assert!(!stale.exists());
        assert!(active_path.exists());
        drop(next);
        drop(active);
    }
}
