//! Application network defaults only; active SSH configuration is immutable.
use anyhow::Result;
use hspterm_storage_sync::network_defaults::NetworkDefaults;

#[derive(Clone)]
pub struct SshNetworkDefaults {
    pub timeout_seconds: u32,
    pub keepalive_seconds: u32,
    pub keepalive_failures: u32,
    pub response_timeout_seconds: u32,
    pub auto_reconnect: bool,
    pub tmux_local_selection: bool,
    pub tmux_shift_enter_lf: bool,
}
impl From<NetworkDefaults> for SshNetworkDefaults {
    fn from(value: NetworkDefaults) -> Self {
        Self {
            timeout_seconds: value.timeout_seconds,
            keepalive_seconds: value.keepalive_seconds,
            keepalive_failures: value.keepalive_failures,
            response_timeout_seconds: value.response_timeout_seconds,
            auto_reconnect: value.auto_reconnect,
            tmux_local_selection: value.tmux_local_selection,
            tmux_shift_enter_lf: value.tmux_shift_enter_lf,
        }
    }
}
pub(crate) async fn load() -> Result<SshNetworkDefaults> {
    tokio::task::spawn_blocking(|| crate::api::with_vault(|v| Ok(NetworkDefaults::load(v)?.into())))
        .await?
}
pub(crate) async fn save(value: SshNetworkDefaults) -> Result<SshNetworkDefaults> {
    tokio::task::spawn_blocking(move || {
        crate::api::with_vault(|v| {
            let value = NetworkDefaults {
                version: 1,
                timeout_seconds: value.timeout_seconds,
                keepalive_seconds: value.keepalive_seconds,
                keepalive_failures: value.keepalive_failures,
                response_timeout_seconds: value.response_timeout_seconds,
                auto_reconnect: value.auto_reconnect,
                tmux_local_selection: value.tmux_local_selection,
                tmux_shift_enter_lf: value.tmux_shift_enter_lf,
            };
            value.save(v)?;
            Ok(value.into())
        })
    })
    .await?
}
