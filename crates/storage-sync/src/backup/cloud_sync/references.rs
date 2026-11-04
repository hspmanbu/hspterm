//! Explicit repair of mixed LWW references. Only complete original units can
//! be selected; credentials never leave Rust and history always keeps its CRDT.
use super::*;
use exchange::PendingReferences;
use std::collections::BTreeSet;
#[cfg(test)]
#[path = "references_tests.rs"]
mod tests;

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReferenceSide {
    Local,
    Remote,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReferenceSelection {
    pub id: String,
    pub side: ReferenceSide,
}
#[derive(Serialize)]
pub struct ReferenceChoice {
    pub id: String,
    pub label: String,
    pub local_available: bool,
    pub remote_available: bool,
    pub local_deleted: bool,
    pub remote_deleted: bool,
    pub winner: ReferenceSide,
    pub local_group: Option<String>,
    pub remote_group: Option<String>,
    pub local_jump: Option<String>,
    pub remote_jump: Option<String>,
}
fn host(item: Option<&Item>) -> Option<crate::HostRecord> {
    let item = item?;
    if !crate::repository::valid_id(&item.id, "host") {
        return None;
    }
    serde_json::from_slice(item.value.as_ref()?.records.get(&item.id)?).ok()
}
fn label(id: &str, a: Option<&Item>, b: Option<&Item>) -> String {
    let name = host(a)
        .or_else(|| host(b))
        .map(|h| format!("主机 {}", h.name))
        .or_else(|| {
            a.and_then(|item| item.value.as_ref())
                .or_else(|| b.and_then(|item| item.value.as_ref()))
                .and_then(|value| value.records.get("__group"))
                .and_then(|raw| serde_json::from_slice::<crate::HostGroup>(raw).ok())
                .map(|g| format!("分组 {}", g.name))
        })
        .unwrap_or_else(|| {
            if id == "catalog-order" {
                "主机与分组排序".into()
            } else {
                id.into()
            }
        });
    name.chars().take(80).collect()
}
impl Exchange {
    pub fn reference_choices(&self, step: &ExchangeStep) -> Result<Vec<ReferenceChoice>> {
        let ExchangeStep::References(pending) = step else {
            return Err(SyncError::Changed);
        };
        let a = self.local.by_id();
        let b = pending.remote.by_id();
        let ids: BTreeSet<_> = a.keys().chain(b.keys()).copied().collect();
        let mut choices = Vec::new();
        for id in ids {
            let left = a.get(id).copied();
            let right = b.get(id).copied();
            if id == super::super::HISTORY || left.map(|i| &i.value) == right.map(|i| &i.value) {
                continue;
            }
            let (lh, rh) = (host(left), host(right));
            choices.push(ReferenceChoice {
                id: id.into(),
                label: label(id, left, right),
                local_available: left.is_some(),
                remote_available: right.is_some(),
                local_deleted: left.is_some_and(|i| i.value.is_none()),
                remote_deleted: right.is_some_and(|i| i.value.is_none()),
                winner: match (left, right) {
                    (Some(a), Some(b)) if b.stamp > a.stamp => ReferenceSide::Remote,
                    (None, Some(_)) => ReferenceSide::Remote,
                    _ => ReferenceSide::Local,
                },
                local_group: lh.as_ref().map(|h| h.group_id.clone()),
                remote_group: rh.as_ref().map(|h| h.group_id.clone()),
                local_jump: lh.and_then(|h| h.jump_host_id),
                remote_jump: rh.and_then(|h| h.jump_host_id),
            });
        }
        if choices.is_empty() || choices.len() > MAX_ITEMS {
            return Err(SyncError::References);
        }
        Ok(choices)
    }
    /// No mutation on an invalid proposal. A successful repair becomes the
    /// same frozen local proposal for later 412 re-reads, never a stale override
    /// silently replayed against a different remote or a different local Vault.
    pub fn resolve_references(
        &mut self,
        pending: &PendingReferences,
        selections: &[ReferenceSelection],
        password: &[u8],
        now: u64,
    ) -> Result<ExchangeStep> {
        if selections.is_empty() || selections.len() > MAX_ITEMS {
            return Err(SyncError::Invalid);
        }
        let (mut candidate, old_summary) = self.local.merge_candidate(&pending.remote, now)?;
        let a = self.local.by_id();
        let b = pending.remote.by_id();
        let latest = self
            .local
            .items
            .iter()
            .chain(pending.remote.items.iter())
            .map(|i| &i.stamp)
            .max();
        let stamp = Stamp::next(latest, &self.actor, now)?;
        let mut seen = BTreeSet::new();
        for selection in selections {
            if selection.id == super::super::HISTORY || !seen.insert(&selection.id) {
                return Err(SyncError::Invalid);
            }
            let left = a.get(selection.id.as_str()).copied();
            let right = b.get(selection.id.as_str()).copied();
            if left.map(|i| &i.value) == right.map(|i| &i.value) {
                return Err(SyncError::Invalid);
            }
            let chosen = match selection.side {
                ReferenceSide::Local => left,
                ReferenceSide::Remote => right,
            }
            .ok_or(SyncError::Invalid)?;
            let index = candidate
                .items
                .binary_search_by(|i| i.id.cmp(&selection.id))
                .map_err(|_| SyncError::Invalid)?;
            let item = &mut candidate.items[index];
            if item.value != chosen.value {
                item.value = chosen.value.clone();
                item.stamp = stamp.clone();
            }
        }
        candidate.validate(now)?;
        let summary = summary(&self.original, &candidate, old_summary.conflicts);
        let ciphertext = candidate.encrypt(password, now)?;
        self.local = candidate.clone();
        Ok(ExchangeStep::Upload(PendingUpload::resolved(
            self.operation,
            candidate,
            ciphertext,
            pending.etag.clone(),
            summary,
        )))
    }
}
pub(super) fn summary(original: &Document, candidate: &Document, conflicts: u32) -> MergeSummary {
    let a = original.by_id();
    let mut summary = MergeSummary {
        conflicts,
        ..Default::default()
    };
    for item in &candidate.items {
        let left = a.get(item.id.as_str()).copied();
        let changed = left.map(|i| &i.value) != Some(&item.value);
        if changed {
            summary.incoming_winners += 1;
        }
        if item.value.is_none() {
            summary.deleted += 1;
        }
        if item.value.is_none() && left.is_some_and(|i| i.value.is_some()) {
            summary.incoming_deletions += 1;
        }
        if changed && projection::sensitive(&item.id) {
            summary.sensitive_changes += 1;
            if item.id != super::super::HISTORY
                && (item.value.is_some() || left.is_some_and(|i| i.value.is_some()))
            {
                summary.credential_changes += 1;
            }
        }
    }
    summary
}
