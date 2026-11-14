//! Direct-first selection: source socket opt-in + explicit copy authorize a
//! task-scoped destination credential; the original peer receipt stays pinned.
use super::*;
use hspterm_ssh_core::direct_transfer::{DirectRoute, ProbeStatus};

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
        let _vault_gate = crate::agents::gate().read_owned().await;
        let source_agents = crate::api::transfer_agent_registry(source.terminal_id)?;
        let target_agents = crate::api::transfer_agent_registry(target.terminal_id)?;
        let binding = source_agents.binding(source.generation)?;
        let target_binding = target_agents.binding(target.generation)?;
        let (authentication, credential_tag, private) = with_vault(|v| {
            anyhow::ensure!(
                v.instance_id() == binding.vault_scope
                    && v.instance_id() == target_binding.vault_scope,
                "直传凭据所属加密库已改变，请重新选择原连接"
            );
            let repo = hspterm_storage_sync::Repository::new(v);
            let origin = repo
                .host(&source.target.host_id)?
                .context("来源主机配置已删除")?;
            let destination = repo
                .host(&target.target.host_id)?
                .context("目标主机配置已删除")?;
            anyhow::ensure!(
                origin.agent_forwarding,
                "请在来源主机开启申请应用内Agent socket，并重新连接"
            );
            anyhow::ensure!(
                origin.address == source.target.address
                    && origin.port == source.target.port
                    && origin.username == source.target.username
                    && destination.address == target.target.address
                    && destination.port == target.target.port
                    && destination.username == target.target.username,
                "直传端点已变化，不能使用其他主机或临时覆盖的凭据"
            );
            let credential = repo
                .credential(&destination.id)?
                .context("目标主机没有已保存的认证凭据")?;
            let private = destination.auth == hspterm_storage_sync::AuthMethod::PrivateKey;
            let tag = crate::agents::credential_tag(&credential);
            Ok((
                crate::connections::authentication(credential, private),
                tag,
                private,
            ))
        })?;
        source_agents.note_direct_sources(
            source.generation,
            &[source.target.host_id.clone(), target.target.host_id.clone()],
        )?;
        let peer = target.session.verified_peer(target.generation).await?;
        if peer.address != target.target.address
            || peer.port != target.target.port
            || peer.sha256 != target.target.fingerprint
        {
            bail!("直传目标与原任务已验证身份不一致");
        }
        check_pair(source, target)?;
        let connector = source
            .session
            .direct_connector(source.generation)
            .await?
            .with_authentication(authentication)
            .await?;
        with_vault(|v| {
            anyhow::ensure!(
                v.instance_id() == binding.vault_scope,
                "直传凭据所属加密库已改变，请重新选择原连接"
            );
            let repo = hspterm_storage_sync::Repository::new(v);
            let origin = repo
                .host(&source.target.host_id)?
                .context("来源主机配置已删除")?;
            let destination = repo
                .host(&target.target.host_id)?
                .context("目标主机配置已删除")?;
            let current = repo
                .credential(&destination.id)?
                .context("目标主机没有已保存的认证凭据")?;
            anyhow::ensure!(
                origin.agent_forwarding
                    && crate::agents::credential_tag(&current) == credential_tag
                    && (destination.auth == hspterm_storage_sync::AuthMethod::PrivateKey)
                        == private,
                "直传认证配置已变更，请重新执行复制"
            );
            Ok(())
        })?;
        let epoch = connector.authentication_epoch();
        match connector
            .probe(&peer, &target.target.username, epoch, stop.clone())
            .await?
        {
            ProbeStatus::Available => {}
            ProbeStatus::MissingTools => {
                bail!("直传所需工具缺失：来源需要ssh、rsync与Python 3，目标需要rsync与Python 3")
            }
            ProbeStatus::AgentUnavailable => {
                bail!("来源会话的直传认证通道不可用，请检查Agent socket并重新连接")
            }
            ProbeStatus::AuthenticationFailed => {
                bail!("来源未能连接并验证目标，请检查网络、认证凭据和主机指纹；未改用本机中转")
            }
            ProbeStatus::Timeout => bail!("来源服务器无法及时连接目标SSH地址，未改用本机中转"),
            ProbeStatus::Unsupported => bail!("远端工具版本不支持安全直传，未改用本机中转"),
        }
        check_pair(source, target)?;
        Ok::<_, anyhow::Error>(DirectRoute::new(
            connector,
            peer,
            target.target.username.clone(),
            epoch,
            relay_permitted,
        )?)
    }
    .await;
    // A probe writes no transferred file body (its public authentication helper
    // is temporary). Fallback is never allowed after a direct file
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
