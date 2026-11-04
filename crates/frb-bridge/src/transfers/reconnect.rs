//! Only interrupted tasks in this process and this original terminal are
//! eligible. No persisted eligibility, new Transport or failed-node retry.
use super::*;

#[derive(Default, Serialize)]
pub(crate) struct Report {
    pub started: u32,
    pub deferred: u32,
    pub failed: u32,
}
pub(crate) fn restore(connection: Connection, scope: &str) -> Result<Report> {
    let mut state = registry().lock();
    // Do not load/revive cross-startup tasks at this boundary.
    if !state.loaded {
        return Ok(Report::default());
    }
    let settings = with_vault(|v| {
        if v.instance_id() != scope {
            bail!("配置库已改变，未恢复传输");
        }
        Ok(TransferSettings::load(v)?)
    })?;
    apply_settings(&mut state, settings);
    let mut report = Report::default();
    for j in state.jobs.clone() {
        let id = {
            let mut d = j.data.lock();
            if !d.reconnect_candidate
                || d.busy
                || d.header.state.ended()
                || d.terminal_id != Some(connection.terminal_id)
                || d.header.target != connection.target
            {
                continue;
            }
            // One explicit reconnect gets at most one attempt. A disabled
            // preference must not preserve stale permission for later edits.
            d.reconnect_candidate = false;
            if d.header.export_name.is_some() && j.export_readers.load(Ordering::Acquire) != 0 {
                report.deferred += 1;
                continue;
            }
            if !settings.resume_on_reconnect {
                continue;
            }
            d.header.id.clone()
        };
        let result: Result<bool> = (|| {
            check_connection(&connection)?;
            let (mut h, p) = load(&id)?;
            if h.target != connection.target || h.state.ended() {
                bail!("原传输检查点身份或状态已变化");
            }
            // Known permanent failures/conflicts remain untouched. Only
            // pending work continues; all completed bytes/nodes are retained.
            if p.as_ref()
                .is_some_and(|p| !p.nodes.iter().any(|n| n.state == NodeState::Pending))
            {
                return Ok(false);
            }
            h.state = State::Waiting;
            h.error = None;
            save(&h, p.as_ref())?;
            j.data.lock().header = h;
            launch(&state, j.clone(), connection.clone());
            Ok(true)
        })();
        match result {
            Ok(true) => report.started += 1,
            Ok(false) => report.deferred += 1,
            Err(error) => {
                report.failed += 1;
                let mut d = j.data.lock();
                d.header.error = Some(crate::public_errors::summary(&error));
                d.header.state = State::Failed;
            }
        }
    }
    Ok(report)
}
