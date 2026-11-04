//! Reuse only both already connected original terminal IDs. Never open SSH,
//! resume an unknown move/delete or retry a permanent per-file failure.
use super::*;
use crate::transfers::reconnect::Report;

pub(crate) fn pairs(terminal: u32, scope: &str) -> Result<Vec<(u32, u32)>> {
    transfers::with_relay_resources(|_, _, _, _| {
        let state = registry().lock();
        if !state.loaded {
            return Ok(Vec::new());
        }
        let enabled = with_vault(|v| {
            if v.instance_id() != scope {
                bail!("配置库已改变，未恢复传输");
            }
            Ok(
                hspterm_storage_sync::transfer_settings::TransferSettings::load(v)?
                    .resume_on_reconnect,
            )
        })?;
        let mut pairs = BTreeSet::new();
        for j in &state.jobs {
            let mut d = j.data.lock();
            if !d.reconnect_candidate
                || d.busy
                || d.cleaning
                || d.cleanup_only
                || d.header.operation != CopyOperation::Copy
                || d.header.state.ended()
                || (d.source_terminal != Some(terminal) && d.destination_terminal != Some(terminal))
            {
                continue;
            }
            if !enabled {
                d.reconnect_candidate = false;
                continue;
            }
            if let (Some(source), Some(target)) = (d.source_terminal, d.destination_terminal) {
                pairs.insert((source, target));
            }
        }
        Ok(pairs.into_iter().collect())
    })
}
pub(crate) fn restore(source: Connection, target: Connection, scope: &str) -> Result<Report> {
    transfers::with_relay_resources(|scheduler, upload, download, _| {
        let state = registry().lock();
        let enabled = with_vault(|v| {
            if v.instance_id() != scope {
                bail!("配置库已改变，未恢复传输");
            }
            Ok(
                hspterm_storage_sync::transfer_settings::TransferSettings::load(v)?
                    .resume_on_reconnect,
            )
        })?;
        check_pair(&source, &target)?;
        let mut report = Report::default();
        for j in &state.jobs {
            let id = {
                let mut d = j.data.lock();
                if !d.reconnect_candidate
                    || d.busy
                    || d.cleaning
                    || d.cleanup_only
                    || d.header.operation != CopyOperation::Copy
                    || d.header.state.ended()
                    || d.source_terminal != Some(source.terminal_id)
                    || d.destination_terminal != Some(target.terminal_id)
                    || d.header.source_target != source.target
                    || d.header.destination_target != target.target
                {
                    continue;
                }
                d.reconnect_candidate = false;
                if !enabled {
                    continue;
                }
                d.header.id.clone()
            };
            let result: Result<bool> = (|| {
                let (mut h, p) = load(&id)?;
                check_move_resume(&h, "continue")?;
                if h.source_target != source.target
                    || h.destination_target != target.target
                    || h.state.ended()
                {
                    bail!("原传输检查点身份或状态已变化");
                }
                if p.as_ref().is_some_and(|p| {
                    !p.nodes.iter().enumerate().any(|(i, n)| {
                        n.state == NodeState::Pending
                            && (n.kind != NodeKind::File
                                || matches!(
                                    p.stages[i],
                                    StagingPhase::Absent
                                        | StagingPhase::Writing
                                        | StagingPhase::Ready
                                ))
                    })
                }) {
                    return Ok(false);
                }
                // Safe file phases only. The core still rejects unknown
                // sibling phases; no stage or failed node is reset here.
                h.state = State::Waiting;
                h.error = None;
                save(&h, p.as_ref(), None)?;
                j.data.lock().header = h;
                launch(
                    j.clone(),
                    source.clone(),
                    target.clone(),
                    scheduler.enqueue(),
                    upload.clone(),
                    download.clone(),
                );
                Ok(true)
            })();
            match result {
                Ok(true) => report.started += 1,
                Ok(false) => report.deferred += 1,
                Err(error) => {
                    report.failed += 1;
                    let mut d = j.data.lock();
                    d.header.state = State::Failed;
                    d.header.error = Some(crate::public_errors::summary(&error));
                }
            }
        }
        Ok(report)
    })
}
