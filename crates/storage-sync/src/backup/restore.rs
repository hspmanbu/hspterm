use super::*;
use crate::repository::{HostDraft, HostGroup};
use serde::Serialize;

#[derive(Clone)]
pub(super) struct Unit {
    label: String,
    category: String,
    pub(super) records: Records,
    summary: String,
    sensitive: bool,
}
#[derive(Clone, Serialize)]
pub struct DiffItem {
    pub id: String,
    pub label: String,
    pub category: String,
    pub state: String,
    pub local_present: bool,
    pub incoming_present: bool,
    pub default_incoming: bool,
    pub local_summary: Option<String>,
    pub incoming_summary: Option<String>,
    pub sensitive_change: bool,
}
#[derive(Clone, Serialize)]
pub struct Preview {
    pub vault_scope: String,
    pub revision: String,
    pub mode: String,
    pub items: Vec<DiffItem>,
    pub local_hosts: usize,
    pub incoming_hosts: usize,
}
fn value<'a>(snapshot: &'a Snapshot, key: &str) -> Option<&'a [u8]> {
    snapshot.records.get(key).map(slice)
}
fn cat(snapshot: &Snapshot) -> Result<Catalog> {
    decode(value(snapshot, CATALOG).ok_or(BackupError::Invalid)?)
}
fn one(key: &str, data: Bytes) -> Records {
    BTreeMap::from([(key.into(), data)])
}
pub(super) fn units(snapshot: &Snapshot) -> Result<BTreeMap<String, Unit>> {
    let catalog = cat(snapshot)?;
    let mut units = BTreeMap::new();
    for group in &catalog.groups {
        units.insert(
            group.id.clone(),
            Unit {
                label: group.name.clone(),
                category: "主机分组".into(),
                records: one("__group", json(group)?),
                summary: group.name.clone(),
                sensitive: false,
            },
        );
    }
    let order = (
        &catalog.hosts,
        catalog.groups.iter().map(|g| &g.id).collect::<Vec<_>>(),
    );
    units.insert(
        "catalog-order".into(),
        Unit {
            label: "主机与分组顺序".into(),
            category: "排序".into(),
            records: one("__order", json(&order)?),
            summary: format!(
                "{} 个主机 / {} 个分组",
                catalog.hosts.len(),
                catalog.groups.len()
            ),
            sensitive: false,
        },
    );
    for id in &catalog.hosts {
        let host: HostRecord = decode(value(snapshot, id).ok_or(BackupError::Invalid)?)?;
        let records = host_keys(&host)
            .into_iter()
            .filter_map(|key| {
                snapshot
                    .records
                    .get(&key)
                    .map(|v| (key.clone(), Arc::clone(v)))
            })
            .collect();
        let summary = format!(
            "{}@{}:{} · {} · {}",
            host.username,
            host.address,
            host.port,
            if host.auth == crate::AuthMethod::PrivateKey {
                "私钥"
            } else {
                "密码"
            },
            if host.credential_id.is_some() {
                "包含加密凭据"
            } else {
                "尚未配置凭据"
            }
        );
        units.insert(
            id.clone(),
            Unit {
                label: host.name,
                category: "SSH 主机及关联配置".into(),
                records,
                summary,
                sensitive: true,
            },
        );
    }
    for key in GLOBALS {
        if let Some(data) = snapshot.records.get(*key) {
            let label = match *key {
                HISTORY => "单行命令历史（含清除标记）",
                "sftp-bookmarks-v1" => "SFTP 书签",
                "config-ssh-network-defaults-v1" => "SSH 默认参数",
                "config-transfer-settings-v1" => "传输设置",
                "config-file-open-settings-v1" => "文件打开设置",
                "config-terminal-decorations-v1" => "终端彩色高亮规则",
                "config-command-palette-shortcut-v1" => "应用命令面板快捷键",
                crate::terminal_preferences::RECORD => "终端颜色、光标与输入偏好",
                crate::appearance::RECORD => "界面深浅主题",
                crate::sftp_view_settings::RECORD => "SFTP目录优先、隐藏文件与列表密度默认值",
                _ => return Err(BackupError::Invalid),
            };
            units.insert(
                (*key).into(),
                Unit {
                    label: label.into(),
                    category: "用户配置".into(),
                    records: one(key, Arc::clone(data)),
                    summary: if *key == HISTORY {
                        "历史正文不会显示在预览或诊断中".into()
                    } else {
                        "版本化配置；按此项目整体选择本机或备份".into()
                    },
                    sensitive: *key == HISTORY,
                },
            );
        }
    }
    for (id, data) in &snapshot.records {
        if trust_key(id) {
            units.insert(
                id.clone(),
                Unit {
                    label: format!("服务器信任 {}", &id[6..18]),
                    category: "主机密钥信任".into(),
                    summary: std::str::from_utf8(slice(data)).map_err(invalid)?.into(),
                    records: one(id, Arc::clone(data)),
                    sensitive: true,
                },
            );
        }
    }
    if snapshot.records.contains_key(TYPOGRAPHY) {
        let records = snapshot
            .records
            .iter()
            .filter(|(key, _)| key.as_str() == TYPOGRAPHY || font_key(key))
            .map(|(key, data)| (key.clone(), Arc::clone(data)))
            .collect::<Records>();
        units.insert(
            "local-fonts".into(),
            Unit {
                label: "本机字体与排版（不云同步）".into(),
                category: "本机字体".into(),
                summary: format!(
                    "{} 份导入字体；只恢复应用副本",
                    records.len().saturating_sub(1)
                ),
                records,
                sensitive: false,
            },
        );
    }
    Ok(units)
}
pub fn preview(vault: &Vault, incoming: &Snapshot, mode: &str) -> Result<Preview> {
    if !["merge", "replace"].contains(&mode) {
        return Err(BackupError::Invalid);
    }
    let current = Snapshot::capture(vault)?;
    let local = units(&current)?;
    let remote = units(incoming)?;
    let ids: BTreeSet<_> = local.keys().chain(remote.keys()).cloned().collect();
    let items = ids
        .into_iter()
        .map(|id| {
            let a = local.get(&id);
            let b = remote.get(&id);
            let equal = a.zip(b).is_some_and(|(a, b)| a.records == b.records);
            let unit = b.or(a).expect("union of existing unit keys");
            DiffItem {
                id,
                label: unit.label.clone(),
                category: unit.category.clone(),
                state: if equal {
                    "same"
                } else if a.is_none() {
                    "added"
                } else if b.is_none() {
                    "local_only"
                } else {
                    "conflict"
                }
                .into(),
                local_present: a.is_some(),
                incoming_present: b.is_some(),
                default_incoming: mode == "replace" || a.is_none(),
                local_summary: a.map(|a| a.summary.clone()),
                incoming_summary: b.map(|b| b.summary.clone()),
                sensitive_change: !equal
                    && (a.is_some_and(|a| a.sensitive) || b.is_some_and(|b| b.sensitive)),
            }
        })
        .collect();
    Ok(Preview {
        vault_scope: vault.instance_id().into(),
        revision: current.revision(vault),
        mode: mode.into(),
        items,
        local_hosts: cat(&current)?.hosts.len(),
        incoming_hosts: cat(incoming)?.hosts.len(),
    })
}

pub struct PreparedRestore {
    scope: String,
    revision: String,
    next_scope: String,
    expected: BTreeMap<String, Option<Bytes>>,
    candidate: Records,
    data_version: i64,
    pub changed_hosts: Vec<String>,
}
impl PreparedRestore {
    /// The cloud ledger and its acknowledged projection must publish with the
    /// configuration. This private hook cannot select an arbitrary local key.
    pub(super) fn with_cloud_checkpoint(
        mut self,
        prior: Option<Bytes>,
        next: Bytes,
        journal: Option<(Option<Bytes>, Bytes)>,
        settings: Vec<(String, Option<Bytes>)>,
        identities: (Option<Bytes>, Bytes),
    ) -> Self {
        // Ordinary synchronization has per-record and ledger CAS. Keep the
        // running Vault scope so a metadata-only ACK does not invalidate every
        // unrelated host-key prompt, Agent consent or open settings form.
        self.next_scope = self.scope.clone();
        let id = cloud_sync::reconciliation::IDENTITIES.to_owned();
        self.expected.insert(id.clone(), identities.0);
        self.candidate.insert(id, identities.1);
        let key = cloud_sync::LEDGER.to_owned();
        self.expected.insert(key.clone(), prior);
        self.candidate.insert(key, next);
        if let Some((prior, next)) = journal {
            let key = cloud_sync::journal::RECORD.to_owned();
            self.expected.insert(key.clone(), prior);
            self.candidate.insert(key, next);
        }
        // Existing device-local target rows are preconditions, not removals.
        // Preserve their exact plaintext while binding the transaction to them.
        for (id, raw) in settings {
            self.expected.insert(id.clone(), raw.clone());
            if let Some(raw) = raw {
                self.candidate.insert(id, raw);
            }
        }
        self
    }
    pub fn next_scope(&self) -> &str {
        &self.next_scope
    }
    /// Compile dependent in-memory display policies before the real database
    /// transaction. No candidate Vault or secret payload is sent over FFI.
    pub fn inspect_candidate<T>(&self, f: impl FnOnce(&mut Vault) -> Result<T>) -> Result<T> {
        let mut vault = Snapshot {
            records: self.candidate.clone(),
            data_version: None,
        }
        .sandbox()?;
        f(&mut vault)
    }
    /// Caller serializes with active Agent consent and final source checks.
    /// No network awaits are allowed while holding the Vault operation gate.
    pub fn commit(self, vault: &mut Vault) -> Result<()> {
        if vault.instance_id() != self.scope
            || Snapshot::capture(vault)?.revision(vault) != self.revision
        {
            return Err(BackupError::Changed);
        }
        let expected: Vec<_> = self
            .expected
            .iter()
            .map(|(id, raw)| (id.as_str(), raw.as_ref().map(slice)))
            .collect();
        let mut changes: Vec<_> = self
            .candidate
            .iter()
            .map(|(id, raw)| RecordChange::Put(id, slice(raw)))
            .collect();
        changes.extend(
            self.expected
                .keys()
                .filter(|id| !self.candidate.contains_key(*id))
                .map(|id| RecordChange::Delete(id)),
        );
        if !vault.apply_checked_data_version(&expected, &changes, self.data_version)? {
            return Err(BackupError::Changed);
        }
        // Same database/key, new proposal scope: all old settings/history/key
        // previews become stale even when a restored value equals older bytes.
        vault.instance_id = self.next_scope;
        Ok(())
    }
}
pub fn prepare_restore(
    vault: &Vault,
    incoming: &Snapshot,
    scope: &str,
    revision: &str,
    use_incoming: &[String],
) -> Result<PreparedRestore> {
    if vault.instance_id() != scope {
        return Err(BackupError::Changed);
    }
    let current = Snapshot::capture(vault)?;
    if current.revision(vault) != revision {
        return Err(BackupError::Changed);
    }
    let local = units(&current)?;
    let remote = units(incoming)?;
    let all: BTreeSet<_> = local.keys().chain(remote.keys()).cloned().collect();
    let selected: BTreeSet<_> = use_incoming.iter().cloned().collect();
    if selected.len() != use_incoming.len() || !selected.is_subset(&all) {
        return Err(BackupError::Invalid);
    }
    let mut records = Records::new();
    let mut groups = BTreeMap::<String, HostGroup>::new();
    let mut hosts = BTreeSet::new();
    let mut preferred_hosts = Vec::<String>::new();
    let mut preferred_groups = Vec::<String>::new();
    for id in &all {
        let chosen = if selected.contains(id) {
            remote.get(id)
        } else {
            local.get(id)
        };
        let Some(unit) = chosen else {
            continue;
        };
        if id.starts_with("group-") {
            let group: HostGroup = decode(slice(
                unit.records.get("__group").ok_or(BackupError::Invalid)?,
            ))?;
            groups.insert(group.id.clone(), group);
            continue;
        }
        if id == "catalog-order" {
            (preferred_hosts, preferred_groups) = decode(slice(
                unit.records.get("__order").ok_or(BackupError::Invalid)?,
            ))?;
            continue;
        }
        let mut rows = unit.records.clone();
        if valid_id(id, "host") {
            hosts.insert(id.clone());
            if selected.contains(id) {
                let mut host: HostRecord =
                    decode(slice(rows.get(id).ok_or(BackupError::Invalid)?))?;
                if let Some(old) = &host.credential_id {
                    let body = rows.remove(old).ok_or(BackupError::Invalid)?;
                    let fresh = format!("credential-{:032x}", rand::random::<u128>());
                    if read_record(vault, &fresh)?.is_some() {
                        return Err(BackupError::Changed);
                    }
                    rows.insert(fresh.clone(), body);
                    host.credential_id = Some(fresh);
                    rows.insert(id.clone(), json(&host)?);
                }
            }
        }
        for (key, body) in rows {
            if records.insert(key, body).is_some() {
                return Err(BackupError::Invalid);
            }
        }
    }
    if selected.contains(HISTORY) {
        let merged = crate::command_history::restore_payload(
            value(&current, HISTORY),
            records.get(HISTORY).map(slice),
        )
        .map_err(invalid)?;
        records.insert(HISTORY.into(), Arc::new(merged));
    }
    fn ordered(order: &[String], remaining: &BTreeSet<String>) -> Vec<String> {
        let mut result = Vec::new();
        let mut seen = BTreeSet::new();
        for id in order.iter().chain(remaining.iter()) {
            if remaining.contains(id) && seen.insert(id.clone()) {
                result.push(id.clone());
            }
        }
        result
    }
    let ordered_hosts = ordered(&preferred_hosts, &hosts);
    let ordered_groups = ordered(&preferred_groups, &groups.keys().cloned().collect());
    let mut next = Catalog {
        version: 1,
        hosts: ordered_hosts,
        groups: ordered_groups
            .into_iter()
            .filter_map(|id| groups.remove(&id))
            .collect(),
        drafts: vec![],
    };
    records.insert(CATALOG.into(), json(&next)?);
    for id in &next.hosts {
        let host: HostRecord = decode(slice(records.get(id).ok_or(BackupError::Invalid)?))?;
        if !next.groups.iter().any(|g| g.id == host.group_id) {
            return Err(BackupError::Selection(host.name));
        }
        if let Some(jump) = &host.jump_host_id {
            let Some(raw) = records.get(jump) else {
                return Err(BackupError::Selection(host.name));
            };
            let target: HostRecord = decode(slice(raw))?;
            if jump == id
                || target.jump_host_id.is_some()
                || (host.proxy.is_some() && target.proxy.is_some())
            {
                return Err(BackupError::Selection(host.name));
            }
        }
    }
    let candidate = Snapshot {
        records,
        data_version: None,
    };
    candidate.validate()?;
    let mut records = candidate.records;
    // Preserve device-only drafts without exporting or overwriting them. Their
    // groups may need to survive a formal configuration replacement as well.
    let original_catalog = read_record(vault, CATALOG)?;
    let original: Catalog = original_catalog
        .as_ref()
        .map(|raw| decode(slice(raw)))
        .transpose()?
        .unwrap_or_default();
    for id in &original.drafts {
        let raw = vault
            .get_bounded(&format!("draft-{id}"), 2 * 1024 * 1024)?
            .ok_or(BackupError::Invalid)?;
        let draft: HostDraft = decode(&raw)?;
        if !next.groups.iter().any(|g| g.id == draft.host.group_id) {
            let group = original
                .groups
                .iter()
                .find(|g| g.id == draft.host.group_id)
                .ok_or(BackupError::Invalid)?;
            next.groups.push(group.clone());
        }
    }
    next.drafts = original.drafts;
    check_catalog(&next)?;
    records.insert(CATALOG.into(), json(&next)?);
    let mut expected: BTreeMap<_, _> = current
        .records
        .iter()
        .map(|(id, raw)| (id.clone(), Some(Arc::clone(raw))))
        .collect();
    expected.insert(CATALOG.into(), original_catalog);
    let identity_key = cloud_sync::reconciliation::IDENTITIES;
    expected.insert(identity_key.into(), read_record(vault, identity_key)?);
    for key in GLOBALS.iter().copied().chain(std::iter::once(TYPOGRAPHY)) {
        expected.entry(key.into()).or_insert(None);
    }
    for key in records.keys() {
        if !expected.contains_key(key) {
            expected.insert(key.clone(), read_record(vault, key)?);
        }
    }
    let changed_hosts = all
        .into_iter()
        .filter(|id| valid_id(id, "host") && selected.contains(id))
        .collect();
    Ok(PreparedRestore {
        scope: scope.into(),
        revision: revision.into(),
        next_scope: format!("vault-{:032x}", rand::random::<u128>()),
        expected,
        candidate: records,
        data_version: current.data_version.ok_or(BackupError::Invalid)?,
        changed_hosts,
    })
}
