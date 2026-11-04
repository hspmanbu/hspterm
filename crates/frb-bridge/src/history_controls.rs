//! Explicit metadata-only history controls, not an input recording interface.
use hspterm_storage_sync::command_history::controls as domain;
#[derive(Clone)]
pub struct HistoryHostCount {
    pub id: String,
    pub name: String,
    pub count: u32,
}
#[derive(Clone)]
pub struct HistoryControls {
    pub vault_scope: String,
    pub revision: String,
    pub enabled: bool,
    pub total: u32,
    pub hosts: Vec<HistoryHostCount>,
}
impl From<domain::Controls> for HistoryControls {
    fn from(v: domain::Controls) -> Self {
        Self {
            vault_scope: v.vault_scope,
            revision: v.revision,
            enabled: v.enabled,
            total: v.total,
            hosts: v
                .hosts
                .into_iter()
                .map(|h| HistoryHostCount {
                    id: h.id,
                    name: h.name,
                    count: h.count,
                })
                .collect(),
        }
    }
}
