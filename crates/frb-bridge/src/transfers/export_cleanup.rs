//! Explicit cleanup of orphaned local Explorer source snapshots. No network,
//! task cancellation, remote file mutation or guessed Explorer target path.
use super::*;
use hspterm_storage_sync::export_cache;
use std::collections::HashMap;

#[derive(Clone)]
pub struct ExportCleanupReview {
    pub ticket: String,
    /// Private cache directory basenames only, not remote or target paths.
    pub names: Vec<String>,
}
#[derive(Clone)]
pub struct ExportCleanupResult {
    pub removed: u32,
    pub retained: u32,
    pub failed: u32,
}
struct Review {
    scope: String,
    owner: String,
    paths: Vec<PathBuf>,
    created: Instant,
}
fn reviews() -> &'static Mutex<HashMap<String, Review>> {
    static REVIEWS: OnceLock<Mutex<HashMap<String, Review>>> = OnceLock::new();
    REVIEWS.get_or_init(Default::default)
}
fn retained(state: &Registry) -> Result<HashSet<PathBuf>> {
    let mut paths = HashSet::new();
    // Include all durable headers, not just loaded/visible tasks. A malformed
    // journal aborts cleanup instead of treating its references as absent.
    let ids = with_vault(|v| Ok(LocalTaskJournal::new(v).list()?))?;
    for id in ids {
        let path = with_vault(|v| checkpoints::protected_local_reference(v, &id))?;
        paths.insert(path);
    }
    for job in &state.jobs {
        paths.insert(job.data.lock().header.local.clone());
    }
    Ok(paths)
}
pub(crate) fn prepare(base: String, scope: String) -> Result<ExportCleanupReview> {
    // Same order as enqueue/switch_vault. No task can be created between
    // journal collection and this review; confirmation rechecks everything.
    let state = registry().lock();
    let owner = with_vault(|v| {
        if v.instance_id() != scope {
            bail!("原配置库已改变，请重新检查导出缓存");
        }
        Ok(export_cache::vault_owner(v, false)?)
    })?;
    let protected = retained(&state)?;
    let paths = match &owner {
        Some(owner) => {
            export_cache::orphan_candidates(std::path::Path::new(&base), owner, &protected)?
        }
        None => Vec::new(),
    };
    let mut reviews = reviews().lock();
    reviews.retain(|_, r| r.created.elapsed() < Duration::from_secs(300));
    if reviews.len() >= 16 {
        bail!("导出缓存检查过多，请关闭旧确认并重试");
    }
    let ticket = format!("export-cleanup-{:032x}", rand::random::<u128>());
    let result = ExportCleanupReview {
        ticket: ticket.clone(),
        names: paths
            .iter()
            .map(|p| {
                p.parent()
                    .and_then(|p| p.file_name())
                    .map(|s| s.to_string_lossy().into_owned())
                    .unwrap_or_default()
            })
            .collect(),
    };
    reviews.insert(
        ticket,
        Review {
            scope,
            owner: owner.unwrap_or_default(),
            paths,
            created: Instant::now(),
        },
    );
    Ok(result)
}
pub(crate) fn release(ticket: String) {
    reviews().lock().remove(&ticket);
}
pub(crate) fn apply(ticket: String) -> Result<ExportCleanupResult> {
    // Consume once before mutation; partial failure always needs a new review.
    let review = reviews()
        .lock()
        .remove(&ticket)
        .context("原导出缓存确认已结束，请重新检查")?;
    let state = registry().lock();
    with_vault(|v| {
        if v.instance_id() != review.scope
            || review.created.elapsed() >= Duration::from_secs(300)
            || (!review.paths.is_empty()
                && export_cache::vault_owner(v, false)?.as_deref() != Some(review.owner.as_str()))
        {
            bail!("原配置库或导出缓存确认已改变，请重新检查");
        }
        Ok(())
    })?;
    let protected = retained(&state)?;
    let mut result = ExportCleanupResult {
        removed: 0,
        retained: 0,
        failed: 0,
    };
    for path in review.paths {
        if protected.contains(&path) {
            result.retained += 1;
            continue;
        }
        match export_cache::retire_orphan(&path, &review.owner) {
            Ok(true) => result.removed += 1,
            Ok(false) => result.retained += 1,
            Err(_) => result.failed += 1,
        }
    }
    Ok(result)
}
