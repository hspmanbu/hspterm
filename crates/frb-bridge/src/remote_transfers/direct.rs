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
        match connector
            .probe(&peer, &target.target.username, grant.epoch, stop.clone())
            .await?
        {
            ProbeStatus::Available => {}
            ProbeStatus::MissingTools => {
                bail!("直传所需工具缺失：来源需要ssh、rsync与Python 3，目标需要rsync与Python 3")
            }
            ProbeStatus::AgentUnavailable => {
                bail!("来源会话的直传密钥授权不可用，请配置应用Agent后重试")
            }
            ProbeStatus::AuthenticationFailed => {
                bail!("来源未能连接并验证目标，请检查网络、密钥认证和主机指纹；未改用本机中转")
            }
            ProbeStatus::Timeout => bail!("来源服务器无法及时连接目标SSH地址，未改用本机中转"),
            ProbeStatus::Unsupported => bail!("远端工具版本不支持安全直传，未改用本机中转"),
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
        Err(error) => Err(error),
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
