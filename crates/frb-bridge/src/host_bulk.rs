//! Non-secret preview DTOs. Bulk APIs have no credential/endpoint patch fields.
use hspterm_storage_sync::host_bulk as domain;
#[derive(Clone)]
pub struct HostBulkNetwork {
    pub use_defaults: bool,
    pub timeout_seconds: u32,
    pub keepalive_seconds: u32,
    pub keepalive_response_seconds: Option<u32>,
    pub keepalive_failures: u32,
}
#[derive(Clone)]
pub struct HostBulkHost {
    pub id: String,
    pub name: String,
    pub group_id: String,
    pub favorite: bool,
    pub open_sftp: bool,
    pub follow_osc7: bool,
    pub network: HostBulkNetwork,
}
#[derive(Clone)]
pub struct HostBulkView {
    pub vault_scope: String,
    pub revision: String,
    pub groups: Vec<crate::api::HostGroupConfig>,
    pub hosts: Vec<HostBulkHost>,
}
pub struct HostBulkPatch {
    pub group_id: Option<String>,
    pub favorite: Option<bool>,
    pub open_sftp: Option<bool>,
    pub follow_osc7: Option<bool>,
    pub network: Option<HostBulkNetwork>,
}
impl From<domain::NetworkPatch> for HostBulkNetwork {
    fn from(n: domain::NetworkPatch) -> Self {
        Self {
            use_defaults: n.use_defaults,
            timeout_seconds: n.timeout_seconds,
            keepalive_seconds: n.keepalive_seconds,
            keepalive_response_seconds: n.keepalive_response_seconds,
            keepalive_failures: n.keepalive_failures,
        }
    }
}
impl From<HostBulkNetwork> for domain::NetworkPatch {
    fn from(n: HostBulkNetwork) -> Self {
        Self {
            use_defaults: n.use_defaults,
            timeout_seconds: n.timeout_seconds,
            keepalive_seconds: n.keepalive_seconds,
            keepalive_response_seconds: n.keepalive_response_seconds,
            keepalive_failures: n.keepalive_failures,
        }
    }
}
impl From<HostBulkPatch> for domain::Patch {
    fn from(p: HostBulkPatch) -> Self {
        Self {
            group_id: p.group_id,
            favorite: p.favorite,
            open_sftp: p.open_sftp,
            follow_osc7: p.follow_osc7,
            network: p.network.map(Into::into),
        }
    }
}
impl From<domain::Snapshot> for HostBulkView {
    fn from(s: domain::Snapshot) -> Self {
        Self {
            vault_scope: s.vault_scope,
            revision: s.revision,
            groups: s
                .groups
                .into_iter()
                .map(|g| crate::api::HostGroupConfig {
                    id: g.id,
                    name: g.name,
                })
                .collect(),
            hosts: s
                .hosts
                .into_iter()
                .map(|h| HostBulkHost {
                    id: h.id,
                    name: h.name,
                    group_id: h.group_id,
                    favorite: h.favorite,
                    open_sftp: h.open_sftp,
                    follow_osc7: h.follow_osc7,
                    network: h.network.into(),
                })
                .collect(),
        }
    }
}
