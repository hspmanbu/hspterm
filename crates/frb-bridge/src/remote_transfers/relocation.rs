//! Post-copy source retirement. The immutable tree remains the acknowledged
//! destination inventory; per-source intent/ACK updates only device metadata.
use super::*;
use hspterm_ssh_core::{SftpSession, remote_tree::SourceRetirement};

#[derive(Debug)]
pub(super) struct JournalUnknown;
impl std::fmt::Display for JournalUnknown {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("来源删除日志未能重新读取；保留原记录，禁止以内存状态覆盖")
    }
}
impl std::error::Error for JournalUnknown {}

pub(super) async fn run(
    j: &CopyJob,
    h: &mut CopyHeader,
    plan: &RemoteTree,
    source: &Connection,
    target: &Connection,
    sftp: &SftpSession,
    stop: &CancellationToken,
) -> Result<TreeOutcome> {
    check_pair(source, target)?;
    plan.validate_endpoints(source.target.fingerprint == target.target.fingerprint)?;
    let origin = h.source_target.clone();
    let path = h.source.clone();
    let revision = j.data.lock().revision;
    if h.source_retirement.is_none() {
        let ledger = SourceRetirement::new(plan)?;
        if h.cleanup
            .as_ref()
            .is_some_and(|c| c.state != hspterm_ssh_core::remote_tree::StagingCleanupState::Retired)
        {
            bail!("旧暂存清理结果未确认，不能删除来源");
        }
        // Completed private staging cleanup no longer needs a separate ledger.
        // The immutable copied plan and source-retirement proof remain durable.
        h.cleanup = None;
        h.source_retirement = Some(ledger);
        crate::editors::with_move_source_guard(&origin, &path, || {
            check_pair(source, target)?;
            save(h, Some(plan), Some(&BTreeSet::new()))?;
            let mut d = j.data.lock();
            d.header = h.clone();
            d.retiring_sources = true;
            Ok(())
        })?;
    }
    let mut ledger = h.source_retirement.clone().context("来源清理日志缺失")?;
    j.data.lock().retiring_sources = !ledger.complete();
    let id = h.id.clone();
    let result = plan
        .retire_copied_sources(&mut ledger, sftp, stop, |ledger| {
            let mut publish = || {
                transfers::with_relay_resources(|_, _, _, _| {
                    let state = registry().lock();
                    let current = job(&state, &id)?;
                    if !std::ptr::eq(current.as_ref(), j) {
                        bail!("原移动任务已经改变");
                    }
                    let mut d = current.data.lock();
                    if d.revision != revision || !d.busy {
                        bail!("原移动任务已经改变");
                    }
                    check_pair(source, target)?;
                    h.source_retirement = Some(ledger.clone());
                    // The copied tree was fully validated before this immutable run.
                    // Each ACK/intent publishes only metadata, not every directory chunk.
                    save(h, Some(plan), Some(&BTreeSet::new()))?;
                    d.header = h.clone();
                    Ok(())
                })
            };
            if ledger.complete() {
                // A completed ledger finalizes locally and cannot touch a later
                // recreated source, including a new editor at that old pathname.
                publish()
            } else {
                crate::editors::with_move_source_guard(&origin, &path, publish)
            }
            .map_err(|_| RemoteTreeError::Checkpoint)
        })
        .await;
    if let Err(error) = result {
        // Never let final generic task persistence overwrite the durable intent
        // with a locally advanced cursor after a failed checkpoint.
        let (acknowledged, _) = load(&id).map_err(|_| JournalUnknown)?;
        *h = acknowledged;
        if matches!(error, RemoteTreeError::SourceRetirementStopped) && stop.is_cancelled() {
            h.error = Some("来源清理已停止；目标副本保留，已经确认删除的来源不会恢复".into());
            return Ok(TreeOutcome::Paused);
        }
        return Err(error.into());
    }
    Ok(TreeOutcome::Complete)
}

/// Resolve only the source parent before reserving a move, including address
/// aliases. No final-link following, body reads or target/source mutation.
pub(super) async fn prepare_source(source: &Connection, path: String) -> Result<String> {
    transfers::check_connection(source)?;
    let channels = crate::transfer_channels::Channels::default();
    let stop = CancellationToken::new();
    let path = channels
        .supervise(async {
            let sftp = channels
                .open(&source.session, source.generation, &stop)
                .await?;
            let path = hspterm_ssh_core::transfer::object_path(&sftp, &path).await?;
            transfers::check_connection(source)?;
            Ok(path)
        })
        .await?;
    transfers::check_connection(source)?;
    Ok(path)
}
