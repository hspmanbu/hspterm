//! Unknown rename outcomes are never guessed from equal sizes or path presence.
//! Inspection reads metadata; acknowledgement mutates only a retained local audit.
use super::*;
use hspterm_ssh_core::{SftpError, SftpSession, SftpStatusCode};

pub(super) struct InspectionTicket {
    ready: bool,
    nonce: String,
    revision: u64,
    source_id: u32,
    source_generation: u64,
    target_id: u32,
    target_generation: u64,
}
pub(super) struct LocalEndTicket {
    nonce: String,
    revision: u64,
}
impl InspectionTicket {
    fn current(
        &self,
        nonce: &str,
        revision: u64,
        source: &Connection,
        target: &Connection,
    ) -> bool {
        self.ready
            && self.nonce == nonce
            && self.revision == revision
            && self.source_id == source.terminal_id
            && self.source_generation == source.generation
            && self.target_id == target.terminal_id
            && self.target_generation == target.generation
    }
}
fn check(header: &CopyHeader, busy: bool, source: &Connection, target: &Connection) -> Result<()> {
    check_pair(source, target)?;
    check_stopped(header, busy)?;
    if header.source_target != source.target
        || header.destination_target != target.target
        || !same_account(&source.target, &target.target)
    {
        bail!("当前实际服务器、账户或指纹与原移动任务不同");
    }
    Ok(())
}
fn check_stopped(header: &CopyHeader, busy: bool) -> Result<()> {
    if busy || header.operation != CopyOperation::Move || header.move_phase != MovePhase::Intent {
        bail!("仅已停止且结果未确认的移动可以检查/人工结束");
    }
    Ok(())
}
pub(super) async fn fact(sftp: &SftpSession, path: &str) -> (&'static str, Option<u64>) {
    match sftp.symlink_metadata(path).await {
        Ok(attrs) if attrs.is_symlink() => ("Symlink", attrs.size),
        Ok(attrs) if attrs.is_dir() => ("Directory", attrs.size),
        Ok(attrs) if attrs.is_regular() => ("File", attrs.size),
        Ok(attrs) => ("Other", attrs.size),
        Err(SftpError::Status(status)) if status.status_code == SftpStatusCode::NoSuchFile => {
            ("Missing", None)
        }
        // A denied/unavailable attribute is explicitly unknown. It cannot be
        // reinterpreted as a missing path or proof of a successful operation.
        Err(_) => ("Unavailable", None),
    }
}
pub(super) async fn inspect(
    source: Connection,
    target: Connection,
    id: String,
) -> Result<RemoteMoveInspection> {
    let nonce = format!("move-inspect-{:032x}", rand::random::<u128>());
    let (original, header, revision) = transfers::with_relay_resources(|_, _, _, _| {
        let mut state = registry().lock();
        restore(&mut state)?;
        let j = job(&state, &id)?;
        let mut d = j.data.lock();
        check(&d.header, d.busy, &source, &target)?;
        // Reserve before IO: a newly started check supersedes older results,
        // even when their network replies arrive after this one completes.
        d.inspection = Some(InspectionTicket {
            ready: false,
            nonce: nonce.clone(),
            revision: d.revision,
            source_id: source.terminal_id,
            source_generation: source.generation,
            target_id: target.terminal_id,
            target_generation: target.generation,
        });
        Ok((j.clone(), d.header.clone(), d.revision))
    })?;
    // Independent read-only batches may overlap; one finishing inspection
    // must not close a later query's stream. The task owns both actual IOs.
    let channels = original.channels.batch();
    let stop = CancellationToken::new();
    let (source_fact, target_fact) = channels
        .supervise(async {
            check_pair(&source, &target)?;
            let sftp = channels
                .open(&source.session, source.generation, &stop)
                .await?;
            let source_fact = fact(&sftp, &header.source).await;
            let target_fact = fact(&sftp, &header.destination).await;
            check_pair(&source, &target)?;
            Ok((source_fact, target_fact))
        })
        .await?;
    transfers::with_relay_resources(|_, _, _, _| {
        let state = registry().lock();
        let current = job(&state, &id)?;
        if !Arc::ptr_eq(&current, &original) {
            bail!("检查期间配置库或任务已重载，请重新检查");
        }
        let mut d = current.data.lock();
        check(&d.header, d.busy, &source, &target)?;
        if d.revision != revision {
            bail!("检查期间任务已改变，请重新检查");
        }
        let latest = d
            .inspection
            .as_mut()
            .context("已有更新的检查，旧检查结果未发布")?;
        if latest.nonce != nonce {
            bail!("已有更新的检查，旧检查结果未发布");
        }
        latest.ready = true;
        Ok(())
    })?;
    Ok(RemoteMoveInspection {
        ticket: nonce,
        account: format!(
            "{}@{}:{}",
            header.source_target.username, header.source_target.address, header.source_target.port
        ),
        source_path: header.source,
        destination_path: header.destination,
        source_kind: source_fact.0.into(),
        source_size: source_fact.1,
        destination_kind: target_fact.0.into(),
        destination_size: target_fact.1,
    })
}
pub(super) fn acknowledge(
    source: Connection,
    target: Connection,
    id: String,
    nonce: String,
) -> Result<()> {
    transfers::with_relay_resources(|_, _, _, _| {
        let state = registry().lock();
        let j = job(&state, &id)?;
        let mut d = j.data.lock();
        check(&d.header, d.busy, &source, &target)?;
        let ticket = d
            .inspection
            .as_ref()
            .context("尚无有效检查，请先检查原路径")?;
        if !ticket.current(&nonce, d.revision, &source, &target) {
            bail!("检查票据或SSH代次已改变，请重新检查");
        }
        finish(&mut d)
    })
}

fn finish(d: &mut CopyRuntime) -> Result<()> {
    let mut ended = d.header.clone();
    ended.move_phase = MovePhase::UserEnded;
    ended.state = State::Cancelled;
    ended.error = Some("已人工结束本机等待，移动结果仍未判定；不会撤销已发出的服务器请求。本动作未重发更名、写入或删除，原请求记录保留于本机加密日志。".into());
    // Do not consume either capability or release the reservation before this
    // transaction succeeds. There is no network mutation, even on retry.
    save(&ended, None, None)?;
    d.header = ended;
    d.stats = Some(move_stats(&d.header));
    d.inspection = None;
    d.local_end = None;
    Ok(())
}

pub(super) fn prepare_local(id: String) -> Result<RemoteMoveEndReview> {
    transfers::with_relay_resources(|_, _, _, _| {
        let mut state = registry().lock();
        restore(&mut state)?;
        let j = job(&state, &id)?;
        let mut d = j.data.lock();
        check_stopped(&d.header, d.busy)?;
        let nonce = format!("move-end-{:032x}", rand::random::<u128>());
        d.local_end = Some(LocalEndTicket {
            nonce: nonce.clone(),
            revision: d.revision,
        });
        let h = &d.header;
        Ok(RemoteMoveEndReview {
            ticket: nonce,
            account: format!(
                "{}@{}:{}",
                h.source_target.username, h.source_target.address, h.source_target.port
            ),
            fingerprint: h.source_target.fingerprint.clone(),
            source_path: h.source.clone(),
            destination_path: h.destination.clone(),
        })
    })
}

pub(super) fn end_local(id: String, nonce: String) -> Result<()> {
    transfers::with_relay_resources(|_, _, _, _| {
        let state = registry().lock();
        let j = job(&state, &id)?;
        let mut d = j.data.lock();
        check_stopped(&d.header, d.busy)?;
        let ticket = d.local_end.as_ref().context("请先读取本机原任务信息")?;
        if ticket.nonce != nonce || ticket.revision != d.revision {
            bail!("本机任务审阅票据已失效，请重新读取");
        }
        // No Connection object is accepted. This capability cannot authorize a
        // remote query, reconnect, host reassociation or any transfer retry.
        finish(&mut d)
    })
}
