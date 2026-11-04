//! Explicit, original-target staging cleanup. No source deletion and no guessing
//! whether an earlier create/publish/remove succeeded. Tickets are process-local.
use super::*;
use hspterm_ssh_core::remote_tree::{StagingCleanup, StagingCleanupState};
use sha2::{Digest, Sha256};

pub(super) struct Review {
    nonce: String,
    revision: u64,
    scope: String,
    signature: [u8; 32],
    target_id: u32,
    generation: u64,
    stage: StagingCleanup,
    uncertain: bool,
}
// A worker-owned finish barrier also covers unwinding outside supervise().
// Channels remain owned by CopyJob even if their close cannot be confirmed.
struct Finish {
    job: Arc<CopyJob>,
    revision: u64,
}
impl Drop for Finish {
    fn drop(&mut self) {
        let mut d = self.job.data.lock();
        if std::thread::panicking() {
            d.header.state = State::Failed;
            d.header.error = Some("暂存清理工作异常，结果未确认；请保留原任务记录".into());
        }
        d.cleaning = false;
        d.busy = false;
        d.requested = None;
        drop(d);
        self.job.finished.send_replace(self.revision);
    }
}
struct Hash(Sha256);
pub(crate) fn prepare_end(id: String) -> Result<String> {
    transfers::with_relay_resources(|_, _, _, _| {
        let mut state = registry().lock();
        restore(&mut state)?;
        let j = job(&state, &id)?;
        let mut d = j.data.lock();
        if d.busy || !j.io_empty() {
            bail!("暂存操作仍在收尾，不能结束等待");
        }
        let (h, p) = load(&id)?;
        let p = p.context("复制清单已不存在")?;
        let stage = h.cleanup.clone().context("没有未确认的暂存删除")?;
        if stage.state != StagingCleanupState::RemoveIntent {
            bail!("没有未确认的暂存删除");
        }
        let nonce = format!("staging-end-{:032x}", rand::random::<u128>());
        let response = serde_json::json!({"ticket": nonce, "path": stage.path}).to_string();
        d.cleanup_review = Some(Arc::new(Review {
            nonce,
            revision: d.revision,
            scope: scope()?,
            signature: signature(&h, &p)?,
            target_id: 0,
            generation: 0,
            stage,
            uncertain: true,
        }));
        Ok(response)
    })
}
pub(crate) fn end_local(id: String, nonce: String) -> Result<()> {
    transfers::with_relay_resources(|_, _, _, _| {
        let state = registry().lock();
        let j = job(&state, &id)?;
        let mut d = j.data.lock();
        if d.busy || !j.io_empty() {
            bail!("暂存操作仍在收尾，不能结束等待");
        }
        let review = d
            .cleanup_review
            .clone()
            .context("请先读取本机结束等待确认")?;
        let (mut h, p) = load(&id)?;
        let p = p.context("复制清单已不存在")?;
        if !nonce.starts_with("staging-end-")
            || nonce != review.nonce
            || review.scope != scope()?
            || d.revision != review.revision
            || signature(&h, &p)? != review.signature
            || h.cleanup
                .as_ref()
                .is_none_or(|c| c.state != StagingCleanupState::RemoveIntent)
        {
            bail!("暂存结束等待确认已过期");
        }
        h.cleanup.as_mut().unwrap().state = StagingCleanupState::ReleasedUnknown;
        h.cleanup_abandoned = true;
        h.state = State::Failed;
        h.error =
            Some("暂存删除结果未判定；旧路径禁止续传，可重新检查清理或创建新的复制任务".into());
        // Keep every original staging reference. A later old REMOVE may still
        // arrive; a new copy must get a NEW random task/staging identity.
        save(&h, Some(&p), None)?;
        d.header = h;
        d.cleanup_review = None;
        Ok(())
    })
}
impl std::io::Write for Hash {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.update(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
fn signature(header: &CopyHeader, plan: &RemoteTree) -> Result<[u8; 32]> {
    let mut hash = Hash(Sha256::new());
    serde_json::to_writer(&mut hash, &(header, plan))?;
    Ok(hash.0.finalize().into())
}
fn scope() -> Result<String> {
    with_vault(|v| Ok(v.instance_id().to_owned()))
}
fn check(h: &CopyHeader, busy: bool, target: &Connection) -> Result<()> {
    transfers::check_connection(target)?;
    if busy || h.operation == CopyOperation::Move || h.destination_target != target.target {
        bail!("暂存清理需要已停止的原复制任务及相同实际目标账户与指纹");
    }
    Ok(())
}
pub(crate) fn tasks(offset: u32, limit: u32) -> Result<String> {
    if limit == 0 || limit > 64 {
        bail!("暂存任务分页应为1至64项");
    }
    transfers::with_relay_resources(|_, _, _, _| {
        let mut state = registry().lock();
        restore(&mut state)?;
        let ids = with_vault(|v| Ok(LocalTaskJournal::remote_copies(v).list()?))?;
        let mut items = Vec::new();
        for id in ids.iter().skip(offset as usize).take(limit as usize) {
            let (h, p) = load(id)?;
            if h.operation == CopyOperation::Move {
                continue;
            }
            let Some(p) = p else {
                continue;
            };
            if !p.stages.iter().enumerate().any(|(i, phase)| {
                *phase != StagingPhase::Absent
                    && !(*phase == StagingPhase::Published
                        && p.nodes[i].state == NodeState::Complete)
            }) {
                continue;
            }
            let j = job(&state, id)?;
            let name: String = h
                .source
                .rsplit('/')
                .next()
                .unwrap_or("远端文件")
                .chars()
                .take(256)
                .collect();
            if h.destination_target.host_id.len() > 4096 {
                bail!("暂存任务元数据超过容量");
            }
            items.push(
                serde_json::json!({"id": id, "host": h.destination_target.host_id,
                "name": name, "busy": j.data.lock().busy}),
            );
        }
        let next = (offset as usize).saturating_add(limit as usize);
        Ok(
            serde_json::json!({"items": items, "next": (next < ids.len()).then_some(next)})
                .to_string(),
        )
    })
}
pub(crate) fn inventory(id: String, offset: u32, limit: u32) -> Result<String> {
    if limit == 0 || limit > 128 {
        bail!("暂存清理分页应为1至128项");
    }
    transfers::with_relay_resources(|_, _, _, _| {
        let mut state = registry().lock();
        restore(&mut state)?;
        let current = job(&state, &id)?;
        let d = current.data.lock();
        if d.busy {
            bail!("复制任务仍在工作，不能清理暂存");
        }
        let (header, plan) = load(&id)?;
        if header.operation == CopyOperation::Move {
            bail!("仅复制任务有暂存清理清单");
        }
        let plan = plan.context("复制任务还没有暂存清单")?;
        let mut items = Vec::new();
        let mut used = 0usize;
        let mut next = None;
        for (ordinal, (i, node)) in plan
            .nodes
            .iter()
            .enumerate()
            .filter(|(i, n)| {
                n.kind == NodeKind::File
                    && plan.stages[*i] != StagingPhase::Absent
                    && !(plan.stages[*i] == StagingPhase::Published
                        && n.state == NodeState::Complete)
            })
            .enumerate()
            .skip(offset as usize)
        {
            let item = serde_json::json!({
                "index": i, "relative": node.relative, "path": plan.staging_path(i)?,
                "phase": format!("{:?}", plan.stages[i]), "bytes": node.acknowledged,
            });
            let bytes = serde_json::to_vec(&item)?.len();
            if items.len() >= limit as usize || used + bytes > 1024 * 1024 {
                if items.is_empty() {
                    bail!("暂存路径超过分页容量");
                }
                next = Some(ordinal);
                break;
            }
            used += bytes;
            items.push(item);
        }
        Ok(serde_json::json!({"items": items, "next": next,
            "unconfirmed": header.cleanup.as_ref().is_some_and(|c| c.state == StagingCleanupState::RemoveIntent)}).to_string())
    })
}
pub(crate) async fn prepare(target: Connection, id: String, index: u32) -> Result<String> {
    let (original, header, plan, revision, epoch, original_scope) =
        transfers::with_relay_resources(|_, _, _, _| {
            let mut state = registry().lock();
            restore(&mut state)?;
            let j = job(&state, &id)?;
            let mut d = j.data.lock();
            check(&d.header, d.busy, &target)?;
            d.cleanup_review = None;
            d.cleanup_inspection_epoch = d
                .cleanup_inspection_epoch
                .checked_add(1)
                .context("暂存检查次数超过容量")?;
            let (h, p) = load(&id)?;
            check(&h, false, &target)?;
            if h.source_retirement.is_some() {
                bail!("来源清理已经开始，不能再修改复制暂存");
            }
            if h.cleanup
                .as_ref()
                .is_some_and(|c| c.state == StagingCleanupState::RemoveIntent)
            {
                bail!("上次删除结果未确认，禁止再次准备删除；请先检查并结束本机等待");
            }
            let p = p.context("复制清单缺失")?;
            let original_scope = scope()?;
            d.revision = d.revision.checked_add(1).context("暂存操作次数超过容量")?;
            d.busy = true;
            d.cleaning = true;
            d.stop = CancellationToken::new();
            d.requested = None;
            d.destination_terminal = Some(target.terminal_id);
            d.destination_generation = Some(target.generation);
            Ok((
                j.clone(),
                h,
                p,
                d.revision,
                d.cleanup_inspection_epoch,
                original_scope,
            ))
        })?;
    let _finish = Finish {
        job: original.clone(),
        revision,
    };
    let stop = original.data.lock().stop.clone();
    let original_signature = signature(&header, &plan)?;
    let channels = &original.channels;
    let stage = channels
        .supervise(async {
            let sftp = channels
                .open(&target.session, target.generation, &stop)
                .await?;
            Ok(plan
                .prepare_staging_cleanup(index as usize, &sftp, &stop)
                .await?)
        })
        .await?;
    let nonce = format!("staging-cleanup-{:032x}", rand::random::<u128>());
    let uncertain = stage.uncertain_operation() || header.cleanup_abandoned;
    let response =
        serde_json::json!({"ticket": nonce, "path": stage.path, "missing": stage.missing(),
        "bytes": stage.bytes(), "uncertain": uncertain, "index": index})
        .to_string();
    transfers::with_relay_resources(|_, _, _, _| {
        let state = registry().lock();
        let current = job(&state, &id)?;
        if !Arc::ptr_eq(&current, &original) || scope()? != original_scope {
            bail!("暂存检查期间配置库或任务已改变");
        }
        let mut d = current.data.lock();
        check(&d.header, false, &target)?;
        if !d.busy || stop.is_cancelled() {
            bail!("暂存检查已停止");
        }
        let (h, p) = load(&id)?;
        if d.revision != revision
            || d.cleanup_inspection_epoch != epoch
            || signature(&h, &p.context("复制清单已不存在")?)? != original_signature
        {
            bail!("暂存检查期间复制记录已变化，请重新检查");
        }
        d.cleanup_review = Some(Arc::new(Review {
            nonce,
            revision,
            scope: original_scope,
            signature: original_signature,
            target_id: target.terminal_id,
            generation: target.generation,
            stage,
            uncertain,
        }));
        Ok(())
    })?;
    Ok(response)
}
pub(crate) async fn apply(
    target: Connection,
    id: String,
    nonce: String,
    allow_uncertain: bool,
) -> Result<()> {
    let (current, review, mut h, mut plan, admission, stop, revision) =
        transfers::with_relay_resources(|scheduler, _, _, _| {
            let state = registry().lock();
            let j = job(&state, &id)?;
            let mut d = j.data.lock();
            check(&d.header, d.busy, &target)?;
            let review = d.cleanup_review.clone().context("请先检查当前暂存路径")?;
            let (h, p) = load(&id)?;
            let p = p.context("复制清单已不存在")?;
            if review.nonce != nonce
                || review.revision != d.revision
                || review.scope != scope()?
                || review.target_id != target.terminal_id
                || review.generation != target.generation
                || review.signature != signature(&h, &p)?
            {
                bail!("暂存清理确认已过期，请重新检查");
            }
            if review.uncertain && !allow_uncertain {
                bail!("未明确确认未知创建或发布状态的清理风险");
            }
            d.revision = d.revision.checked_add(1).context("暂存操作次数超过容量")?;
            d.cleanup_review = None;
            d.busy = true;
            d.cleaning = true;
            d.stop = CancellationToken::new();
            d.requested = None;
            d.destination_terminal = Some(target.terminal_id);
            d.destination_generation = Some(target.generation);
            Ok((
                j.clone(),
                review,
                h,
                p,
                scheduler.enqueue(),
                d.stop.clone(),
                d.revision,
            ))
        })?;
    let handle = tokio::runtime::Handle::current();
    let worker = current.clone();
    // This blocking worker owns cleanup even if the RPC Future is dropped.
    let work = tokio::task::spawn_blocking(move || {
        let _finish = Finish {
            job: worker.clone(),
            revision,
        };
        let mut result = handle.block_on(async {
            let _permit = admission
                .enter(&stop)
                .await
                .context("暂存清理已停止，未删除")?;
            worker
                .channels
                .supervise(async {
                    transfers::check_connection(&target)?;
                    let sftp = worker
                        .channels
                        .open(&target.session, target.generation, &stop)
                        .await?;
                    let mut stage = review.stage.clone();
                    let mut expected = review.signature;
                    plan.cleanup_staging(
                        &mut stage,
                        &sftp,
                        allow_uncertain,
                        &stop,
                        |plan, ledger| {
                            transfers::with_relay_resources(|_, _, _, _| {
                                let state = registry().lock();
                                let j = job(&state, &id)?;
                                if !Arc::ptr_eq(&j, &worker) || scope()? != review.scope {
                                    bail!("暂存清理来源已变化，已停止后续删除");
                                }
                                let d = j.data.lock();
                                transfers::check_connection(&target)?;
                                let (old_h, old_p) = load(&id)?;
                                if d.revision != revision
                                    || !d.cleaning
                                    || signature(&old_h, &old_p.context("原复制清单已不存在")?)?
                                        != expected
                                {
                                    bail!("暂存清理检查点已变化，已停止后续删除");
                                }
                                h.cleanup = Some(ledger.clone());
                                // An older CREATE/publish/REMOVE can still be
                                // outstanding remotely. Retire this task's
                                // random namespace rather than writing it anew.
                                h.cleanup_abandoned |= review.uncertain;
                                save(&h, Some(plan), None)?;
                                expected = signature(&h, plan)?;
                                Ok(())
                            })
                            .map_err(|_| RemoteTreeError::Checkpoint)
                        },
                    )
                    .await?;
                    Ok(())
                })
                .await
        });
        if let Err(error) = &result
            && persist_failure(&worker, error).is_err()
        {
            result = Err(anyhow::anyhow!(
                "暂存清理异常状态未能保存；请保留原任务记录"
            ));
        }
        // Reload the acknowledged journal, never overwrite a durable intent
        // with an older in-memory plan after a cancelled/failed REMOVE.
        let refreshed = load(&id);
        match refreshed {
            Ok((header, p)) => {
                if let Some(p) = p {
                    update(&worker, &p, p.stats(), None);
                }
                worker.data.lock().header = header;
            }
            Err(_) => {
                result = Err(anyhow::anyhow!(
                    "暂存清理检查点未能重新确认；请保留本次运行"
                ));
            }
        }
        let mut d = worker.data.lock();
        if let Err(error) = &result {
            d.header.state = State::Failed;
            d.header.error = Some(crate::public_errors::summary(error));
        }
        drop(d);
        result
    });
    work.await.context("暂存清理工作异常，结果未确认")?
}
