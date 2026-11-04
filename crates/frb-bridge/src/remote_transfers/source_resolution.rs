//! Unknown cross-server source deletion: optional read-only facts and a local
//! one-use end-waiting audit. Missing/equal-size files never establish success.
use super::*;
use sha2::{Digest, Sha256};

pub(super) struct EndTicket {
    nonce: String,
    revision: u64,
    signature: [u8; 32],
}
fn signature(h: &CopyHeader) -> Result<[u8; 32]> {
    Ok(Sha256::digest(serde_json::to_vec(h)?).into())
}
fn stopped(h: &CopyHeader, busy: bool) -> Result<()> {
    if busy
        || h.operation != CopyOperation::Relocate
        || h.source_retirement
            .as_ref()
            .is_none_or(|s| s.uncertain_index().is_none() || s.ended_unknown())
    {
        bail!("仅已停止且来源删除结果未知的任务可以检查或结束等待");
    }
    Ok(())
}
fn paths(h: &CopyHeader, p: &RemoteTree) -> Result<(String, String)> {
    let index = h
        .source_retirement
        .as_ref()
        .and_then(|s| s.uncertain_index())
        .context("来源删除意图缺失")?;
    let n = p.nodes.get(index).context("来源删除项目缺失")?;
    let source = if n.relative.is_empty() {
        h.source.clone()
    } else {
        format!("{}/{}", h.source, n.relative)
    };
    Ok((source, p.destination_path(index)?))
}
pub(crate) fn prepare(id: String) -> Result<RemoteMoveEndReview> {
    transfers::with_relay_resources(|_, _, _, _| {
        let mut state = registry().lock();
        restore(&mut state)?;
        let j = job(&state, &id)?;
        let mut d = j.data.lock();
        if d.busy || d.header.operation != CopyOperation::Relocate {
            bail!("仅已停止的跨服务器移动可以读取本机来源删除记录");
        }
        let (h, p) = load(&id)?;
        d.header = h.clone();
        stopped(&h, false)?;
        let (source_path, destination_path) = paths(&h, &p.context("来源清理缺少复制清单")?)?;
        let nonce = format!("source-end-{:032x}", rand::random::<u128>());
        d.source_end = Some(EndTicket {
            nonce: nonce.clone(),
            revision: d.revision,
            signature: signature(&h)?,
        });
        Ok(RemoteMoveEndReview {
            ticket: nonce,
            account: format!(
                "{}@{}:{}",
                h.source_target.username, h.source_target.address, h.source_target.port
            ),
            fingerprint: h.source_target.fingerprint,
            source_path,
            destination_path,
        })
    })
}
pub(crate) fn end(id: String, nonce: String) -> Result<()> {
    transfers::with_relay_resources(|_, _, _, _| {
        let state = registry().lock();
        let j = job(&state, &id)?;
        let mut d = j.data.lock();
        stopped(&d.header, d.busy)?;
        let ticket = d
            .source_end
            .as_ref()
            .context("请先读取来源删除的本机确认")?;
        let (mut h, p) = load(&id)?;
        let p = p.context("来源清理缺少复制清单")?;
        if !nonce.starts_with("source-end-")
            || ticket.nonce != nonce
            || ticket.revision != d.revision
            || ticket.signature != signature(&h)?
        {
            bail!("来源删除的本机确认已过期");
        }
        stopped(&h, false)?;
        let mut ledger = h.source_retirement.clone().context("来源清理日志缺失")?;
        ledger.end_waiting(&p, |ledger| {
            h.source_retirement = Some(ledger.clone()); h.state = State::Cancelled;
            h.error = Some("已结束本机等待，来源删除结果仍未判定；不会撤销旧请求或再次删除，目标副本及本机原请求记录保留".into());
            save(&h, Some(&p), Some(&BTreeSet::new())).map_err(|_| RemoteTreeError::Checkpoint)
        })?;
        d.header = h;
        d.source_end = None;
        Ok(())
    })
}
pub(crate) async fn inspect(
    source: Connection,
    target: Connection,
    id: String,
) -> Result<RemoteMoveInspection> {
    let (original, h, a_path, b_path, revision, original_signature) =
        transfers::with_relay_resources(|_, _, _, _| {
            let mut state = registry().lock();
            restore(&mut state)?;
            let j = job(&state, &id)?;
            let d = j.data.lock();
            stopped(&d.header, d.busy)?;
            check_pair(&source, &target)?;
            let (h, p) = load(&id)?;
            stopped(&h, false)?;
            if h.source_target != source.target || h.destination_target != target.target {
                bail!("当前实际端点身份与原跨服务器移动任务不同");
            }
            let (a, b) = paths(&h, &p.context("来源清理缺少复制清单")?)?;
            let sig = signature(&h)?;
            Ok((j.clone(), h, a, b, d.revision, sig))
        })?;
    let channels = original.channels.batch();
    let stop = CancellationToken::new();
    let (a, b) = channels
        .supervise(async {
            let a = channels
                .open(&source.session, source.generation, &stop)
                .await?;
            let b = channels
                .open(&target.session, target.generation, &stop)
                .await?;
            check_pair(&source, &target)?;
            let a_fact = move_resolution::fact(&a, &a_path).await;
            let b_fact = move_resolution::fact(&b, &b_path).await;
            check_pair(&source, &target)?;
            Ok((a_fact, b_fact))
        })
        .await?;
    transfers::with_relay_resources(|_, _, _, _| {
        let state = registry().lock();
        let j = job(&state, &id)?;
        if !Arc::ptr_eq(&j, &original) {
            bail!("检查期间配置库或任务已重载，请重新检查");
        }
        let d = j.data.lock();
        stopped(&d.header, d.busy)?;
        check_pair(&source, &target)?;
        let (current, _) = load(&id)?;
        stopped(&current, false)?;
        if d.revision != revision || signature(&current)? != original_signature {
            bail!("检查期间来源删除记录已改变");
        }
        Ok(())
    })?;
    Ok(RemoteMoveInspection {
        ticket: format!("source-facts-{:032x}", rand::random::<u128>()),
        account: format!(
            "{}@{}:{}",
            h.source_target.username, h.source_target.address, h.source_target.port
        ),
        source_path: a_path,
        destination_path: b_path,
        source_kind: a.0.into(),
        source_size: a.1,
        destination_kind: b.0.into(),
        destination_size: b.1,
    })
}
