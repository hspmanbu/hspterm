//! Non-secret projection only; ordering never returns or reads credentials.
use hspterm_storage_sync::host_ordering as domain;

#[derive(Clone)]
pub struct OrderingGroup {
    pub id: String,
    pub name: String,
}
#[derive(Clone)]
pub struct OrderingHost {
    pub id: String,
    pub name: String,
    pub detail: String,
    pub group_id: String,
    pub favorite: bool,
}
#[derive(Clone)]
pub struct OrderingView {
    pub vault_scope: String,
    pub revision: String,
    pub groups: Vec<OrderingGroup>,
    pub hosts: Vec<OrderingHost>,
}
pub struct OrderingPlacement {
    pub id: String,
    pub group_id: String,
    pub favorite: bool,
}
impl From<domain::Snapshot> for OrderingView {
    fn from(v: domain::Snapshot) -> Self {
        Self {
            vault_scope: v.vault_scope,
            revision: v.revision,
            groups: v
                .groups
                .into_iter()
                .map(|g| OrderingGroup {
                    id: g.id,
                    name: g.name,
                })
                .collect(),
            hosts: v
                .hosts
                .into_iter()
                .map(|h| OrderingHost {
                    id: h.id,
                    name: h.name,
                    detail: h.detail,
                    group_id: h.group_id,
                    favorite: h.favorite,
                })
                .collect(),
        }
    }
}
impl From<OrderingPlacement> for domain::Placement {
    fn from(p: OrderingPlacement) -> Self {
        Self {
            id: p.id,
            group_id: p.group_id,
            favorite: p.favorite,
        }
    }
}
