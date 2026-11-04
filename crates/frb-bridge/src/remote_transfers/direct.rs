//! Direct-first selection is read-only. Only an already-authorized app Agent
//! and the original destination receipt qualify; relay is explicit task policy.
use super::*;
use hspterm_ssh_core::{
    AgentPhase,
    direct_transfer::{DirectRoute, ProbeStatus},
};

pub(super) async fn select(
    source: &Connection,
    target: &Connection,
    relay_permitted: bool,
    direct_permitted: bool,
    stop: &CancellationToken,
) -> Result<Option<DirectRoute>> {
    check_pair(source, target)?;
    if !direct_permitted {
        if relay_permitted {
            return Ok(None);
        }
        bail!("未允许服务器直传或本机中转，未开始文件写入");
    }
    let candidate = async {
        let agent = source.session.agent_connector().await?;
        let grant = agent.status();
        if grant.phase != AgentPhase::Active {
            bail!("安全直传需要原应用Agent的明确有效授权");
        }
        let peer = target.session.verified_peer(target.generation).await?;
        if peer.address != target.target.address
            || peer.port != target.target.port
            || peer.sha256 != target.target.fingerprint
        {
            bail!("直传目标与原任务已验证身份不一致");
        }
        check_pair(source, target)?;
        let connector = source.session.direct_connector(source.generation).await?;
        if connector
            .probe(&peer, &target.target.username, grant.epoch, stop.clone())
            .await?
            != ProbeStatus::Available
        {
            bail!("安全直传工具、认证或原目标主机校验不可用");
        }
        check_pair(source, target)?;
        Ok::<_, anyhow::Error>(DirectRoute::new(
            connector,
            peer,
            target.target.username.clone(),
            grant.epoch,
            relay_permitted,
        )?)
    }
    .await;
    // A probe writes no files. Fallback is never allowed after a direct file
    // request was issued; that is handled by durable Intent in FileWork.
    check_pair(source, target)?;
    if stop.is_cancelled() {
        bail!("直传准备已取消，未开始文件写入");
    }
    match candidate {
        Ok(route) => Ok(Some(route)),
        Err(_) if relay_permitted => Ok(None),
        Err(_) => bail!("安全直传不可用且未允许内存中转；本次未开始新的目标写入或来源删除"),
    }
}
pub(crate) async fn preflight(
    source: &Connection,
    target: &Connection,
    relay: bool,
    moving: bool,
    direct: bool,
) -> Result<()> {
    if relay || (moving && same_account(&source.target, &target.target)) {
        return Ok(());
    }
    select(source, target, false, direct, &CancellationToken::new()).await?;
    Ok(())
}
