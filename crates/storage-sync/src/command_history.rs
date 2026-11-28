//! Encrypted, bounded history of already-qualified single-line commands.
//! This is a repository, not an input classifier. No public UI/FRB collection
//! endpoint may call record until a reliable ordinary-shell tracker exists.
pub mod controls;

use crate::{RecordChange, Repository, StorageError, Vault};
use serde::{Deserialize, Serialize};
use std::{
    cmp::Reverse,
    collections::{BTreeMap, BTreeSet},
};
use zeroize::{Zeroize, Zeroizing};

const RECORD: &str = "config-command-history-v1";
const WRITER: &str = "device-command-history-writer-v1";
const MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_HOSTS: usize = 1000;
const PER_HOST: usize = 500;
const MAX_ENTRIES: usize = 20_000;
// Deletes are durable knowledge, never an LRU. Fail atomically at capacity.
const MAX_DELETIONS: usize = 20_000;
const MAX_COMMAND: usize = 4096;

#[derive(Debug, thiserror::Error)]
pub enum HistoryError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error(transparent)]
    Repository(#[from] crate::RepositoryError),
    #[error("命令历史格式无效或版本不支持；原数据未修改")]
    Format,
    #[error("命令历史超过安全容量；原数据未修改")]
    Capacity,
    #[error("命令历史已改变，请重新读取后操作")]
    Changed,
    #[error("命令历史仅允许正式保存的原主机")]
    Host,
}
type Result<T> = std::result::Result<T, HistoryError>;
type Raw = Option<Zeroizing<Vec<u8>>>;

/// One decrypted search row (round-12 settings page). Lives only inside the
/// gateway response; never logged, never persisted outside the vault.
#[derive(Clone)]
pub struct CommandSearchHit {
    pub host_id: String,
    pub text: String,
    pub used_counter: u64,
}
impl Drop for CommandSearchHit {
    fn drop(&mut self) {
        self.text.zeroize();
    }
}

/// Logical order, never a wall-clock deadline. Clear operations advance an
/// epoch. A stale device's entire older epoch is suppressed, including entries
/// that the clearing device had not observed. Epoch tombstones do not expire.
#[derive(Clone, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Stamp {
    counter: u64,
    actor: String,
}
fn actor_valid(v: &str) -> bool {
    v.len() == 32
        && v.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
impl Stamp {
    fn valid(&self, clock: u64) -> bool {
        self.counter <= clock
            && if self.counter == 0 {
                self.actor.is_empty()
            } else {
                actor_valid(&self.actor)
            }
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    text: String,
    used: Stamp,
}
impl Drop for Entry {
    fn drop(&mut self) {
        self.text.zeroize();
    }
}
/// Round-12 single-command delete marker. A tombstone suppresses any entry
/// with the same exact text whose `used` stamp is not newer than `at`,
/// across merges, so a stale device cannot resurrect the command. A later
/// real execution of the same text forms a fresh legal record while retaining
/// deletion knowledge against older offline payloads.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Tombstone {
    text: String,
    at: Stamp,
}
impl Drop for Tombstone {
    fn drop(&mut self) {
        self.text.zeroize();
    }
}
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct HostHistory {
    clear: Stamp,
    entries: Vec<Entry>,
    #[serde(default)]
    deleted: Vec<Tombstone>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    version: u32,
    clock: u64,
    enabled: bool,
    enabled_at: Stamp,
    clear_all: Stamp,
    #[serde(deserialize_with = "unique_hosts")]
    hosts: BTreeMap<String, HostHistory>,
}
fn unique_hosts<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<BTreeMap<String, HostHistory>, D::Error> {
    struct Unique;
    impl<'de> serde::de::Visitor<'de> for Unique {
        type Value = BTreeMap<String, HostHistory>;
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            f.write_str("a bounded map with unique host IDs")
        }
        fn visit_map<A: serde::de::MapAccess<'de>>(
            self,
            mut map: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut result = BTreeMap::new();
            while let Some((id, history)) = map.next_entry::<String, HostHistory>()? {
                if result.len() >= MAX_HOSTS || result.insert(id, history).is_some() {
                    return Err(serde::de::Error::custom(
                        "duplicate or excessive history hosts",
                    ));
                }
            }
            Ok(result)
        }
    }
    d.deserialize_map(Unique)
}
impl Default for Document {
    fn default() -> Self {
        Self {
            version: 1,
            clock: 0,
            enabled: true,
            enabled_at: Stamp::default(),
            clear_all: Stamp::default(),
            hosts: BTreeMap::new(),
        }
    }
}

/// Conservative privacy filter, in addition to (never instead of) a reliable
/// input classifier. Exact text is retained; trimming could change shell meaning.
pub fn eligible_text(text: &str) -> bool {
    if text.is_empty()
        || text.len() > MAX_COMMAND
        || text.starts_with(char::is_whitespace)
        || text.chars().any(|c| {
            c.is_control()
                || matches!(c, '\u{061c}' | '\u{2028}' | '\u{2029}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
    {
        return false;
    }
    let lower = Zeroizing::new(text.to_lowercase());
    if [
        "password",
        "passwd",
        "passphrase",
        "token",
        "secret",
        "private_key",
        "private-key",
        "authorization",
        "api_key",
        "api-key",
        "apikey",
        "sshpass",
        "bearer ",
        "credential",
        "private key",
        "privatekey",
        "pass:",
        "pgpassword",
        "--user",
        "--password",
        "access_key",
        "pwd=",
        "--pass",
    ]
    .iter()
    .any(|s| lower.contains(*s))
    {
        return false;
    }
    // Short flags are context-dependent: ssh -p and sort -u are harmless.
    // Known authentication tools are treated conservatively, including joined
    // flag values. This is not a claim to parse arbitrary shell syntax.
    let password_tool = ["mysql", "mariadb", "redis-cli", "docker login"]
        .iter()
        .any(|s| lower.contains(*s));
    let user_tool = lower.contains("curl") || lower.contains("wget");
    if lower.split_whitespace().any(|s| {
        (password_tool && s.starts_with("-p"))
            || (user_tool && s.starts_with('-') && s.contains('u'))
    }) {
        return false;
    }
    // Userinfo or embedded credentials in URLs. No DNS/network interpretation.
    !lower
        .split_whitespace()
        .any(|s| s.contains("://") && s.contains('@'))
}

impl Document {
    fn decode(raw: &[u8]) -> Result<Self> {
        if raw.len() > MAX_BYTES {
            return Err(HistoryError::Capacity);
        }
        let value: Self = serde_json::from_slice(raw).map_err(|_| HistoryError::Format)?;
        value.validate()?;
        Ok(value)
    }
    fn validate(&self) -> Result<()> {
        if self.version != 1
            || self.clock == u64::MAX
            || !self.clear_all.valid(self.clock)
            || !self.enabled_at.valid(self.clock)
        {
            return Err(HistoryError::Format);
        }
        if self.hosts.len() > MAX_HOSTS {
            return Err(HistoryError::Capacity);
        }
        let mut count = 0;
        let mut deletions = 0;
        for (host, h) in &self.hosts {
            if !crate::repository::valid_id(host, "host") || !h.clear.valid(self.clock) {
                return Err(HistoryError::Format);
            }
            if h.entries.len() > PER_HOST || h.deleted.len() > MAX_DELETIONS {
                return Err(HistoryError::Capacity);
            }
            let mut seen = std::collections::HashSet::new();
            let mut deleted = std::collections::HashSet::new();
            for t in &h.deleted {
                if !eligible_text(&t.text)
                    || !t.at.valid(self.clock)
                    || t.at <= h.clear
                    || t.at <= self.clear_all
                    || !deleted.insert(t.text.as_str())
                {
                    return Err(HistoryError::Format);
                }
            }
            for e in &h.entries {
                if !eligible_text(&e.text)
                    || !e.used.valid(self.clock)
                    || e.used <= h.clear
                    || e.used <= self.clear_all
                    || !seen.insert(e.text.as_str())
                {
                    return Err(HistoryError::Format);
                }
                // A tombstone always outranks its own older entry: if both
                // survive here the merge invariant is broken.
                if h.deleted.iter().any(|t| t.text == e.text && t.at >= e.used) {
                    return Err(HistoryError::Format);
                }
            }
            count += h.entries.len();
            deletions += h.deleted.len();
        }
        if count > MAX_ENTRIES || deletions > MAX_DELETIONS {
            return Err(HistoryError::Capacity);
        }
        Ok(())
    }
    fn encode(&self) -> Result<Zeroizing<Vec<u8>>> {
        self.validate()?;
        let raw = Zeroizing::new(serde_json::to_vec(self).map_err(|_| HistoryError::Format)?);
        if raw.len() > MAX_BYTES {
            return Err(HistoryError::Capacity);
        }
        Ok(raw)
    }
    fn tick(&mut self, actor: &str) -> Result<Stamp> {
        self.clock = self.clock.checked_add(1).ok_or(HistoryError::Capacity)?;
        Ok(Stamp {
            counter: self.clock,
            actor: actor.to_owned(),
        })
    }
    fn compact(h: &mut HostHistory) {
        h.entries
            .sort_by(|a, b| b.used.cmp(&a.used).then_with(|| a.text.cmp(&b.text)));
        h.entries.truncate(PER_HOST);
        // A clear epoch already suppresses everything older; its tombstones
        // are redundant and can never exceed the bounded set below.
        h.deleted.retain(|t| t.at > h.clear);
        h.deleted
            .sort_by(|a, b| b.at.cmp(&a.at).then_with(|| a.text.cmp(&b.text)));
        // Keep every marker newer than the explicit clear epoch.
    }
    fn merged(a: &Self, b: &Self) -> Result<Self> {
        let mut result = Self {
            clock: a.clock.max(b.clock),
            clear_all: a.clear_all.clone().max(b.clear_all.clone()),
            ..Self::default()
        };
        if a.enabled_at == b.enabled_at && a.enabled != b.enabled {
            // Equal operation identity cannot mean two different settings.
            return Err(HistoryError::Format);
        }
        let enabled = if a.enabled_at >= b.enabled_at { a } else { b };
        result.enabled = enabled.enabled;
        result.enabled_at = enabled.enabled_at.clone();
        for source in [a, b] {
            if source.clear_all != result.clear_all {
                continue;
            }
            for (id, history) in &source.hosts {
                let h = result.hosts.entry(id.clone()).or_default();
                if history.clear > h.clear {
                    *h = history.clone();
                } else if history.clear == h.clear {
                    for entry in &history.entries {
                        if let Some(old) = h.entries.iter_mut().find(|e| e.text == entry.text) {
                            old.used = old.used.clone().max(entry.used.clone());
                        } else {
                            h.entries.push(entry.clone());
                        }
                    }
                    // Tombstones merge point-wise: the newer delete wins per
                    // text. Commutative, associative and idempotent.
                    for tombstone in &history.deleted {
                        if let Some(old) = h.deleted.iter_mut().find(|t| t.text == tombstone.text) {
                            old.at = old.at.clone().max(tombstone.at.clone());
                        } else {
                            h.deleted.push(tombstone.clone());
                        }
                    }
                }
            }
        }
        // Resolution: a tombstone suppresses its older entry, a genuinely
        // newer re-execution (used > at) survives alongside retained deletion knowledge.
        for h in result.hosts.values_mut() {
            // A newer execution may coexist with its older deletion. Keep the
            // marker even after that live entry ages out of the bounded LRU.
            h.entries
                .retain(|e| !h.deleted.iter().any(|t| t.text == e.text && t.at >= e.used));
            Self::compact(h);
        }
        // Capacity failure is explicit; never silently discard another host.
        result.validate()?;
        Ok(result)
    }
}

pub struct HistoryRepository<'a> {
    vault: &'a mut Vault,
}
impl<'a> HistoryRepository<'a> {
    pub fn new(vault: &'a mut Vault) -> Self {
        Self { vault }
    }
    fn read(&self) -> Result<(Raw, Document)> {
        let raw = self.vault.get_bounded(RECORD, MAX_BYTES)?;
        let document = raw
            .as_deref()
            .map(|v| Document::decode(v))
            .transpose()?
            .unwrap_or_default();
        Ok((raw, document))
    }
    fn host(&mut self, host: &str) -> Result<()> {
        if Repository::new(self.vault).host(host)?.is_none() {
            return Err(HistoryError::Host);
        }
        Ok(())
    }
    fn actor(&self) -> Result<(Raw, String)> {
        let prior = self.vault.get_bounded(WRITER, 32)?;
        let actor = match &prior {
            None => format!("{:032x}", rand::random::<u128>()),
            Some(raw) => std::str::from_utf8(raw)
                .map_err(|_| HistoryError::Format)?
                .to_owned(),
        };
        if !actor_valid(&actor) {
            return Err(HistoryError::Format);
        }
        Ok((prior, actor))
    }
    fn commit(
        &mut self,
        prior: Option<&[u8]>,
        document: &Document,
        writer: Option<(Option<&[u8]>, &str)>,
    ) -> Result<()> {
        let raw = document.encode()?;
        let mut expected = vec![(RECORD, prior)];
        let mut changes = vec![RecordChange::Put(RECORD, &raw)];
        if let Some((old, actor)) = writer {
            expected.push((WRITER, old));
            changes.push(RecordChange::Put(WRITER, actor.as_bytes()));
        }
        if !self.vault.apply_checked(&expected, &changes)? {
            return Err(HistoryError::Changed);
        }
        Ok(())
    }
    pub fn enabled(&self) -> Result<bool> {
        Ok(self.read()?.1.enabled)
    }
    pub fn set_enabled(&mut self, enabled: bool) -> Result<()> {
        let (prior, mut document) = self.read()?;
        if document.enabled == enabled {
            return Ok(());
        }
        let (old_writer, actor) = self.actor()?;
        document.enabled_at = document.tick(&actor)?;
        document.enabled = enabled;
        self.commit(
            prior.as_deref().map(Vec::as_slice),
            &document,
            Some((old_writer.as_deref().map(Vec::as_slice), &actor)),
        )
    }
    /// Only a previously validated, actually Enter-submitted ordinary-shell
    /// single line is allowed. Never call for temporary targets, hidden input,
    /// TUI, paste previews or an uncertain local editing state.
    pub fn record_qualified(&mut self, host: &str, text: &str) -> Result<bool> {
        self.record_qualified_batch(host, &[text])
            .map(|count| count != 0)
    }
    /// Bounded actor batch, one document read/atomic commit. Every item still
    /// requires the same trusted qualification and conservative secret filter.
    pub fn record_qualified_batch(&mut self, host: &str, texts: &[&str]) -> Result<usize> {
        if texts.len() > 32 {
            return Err(HistoryError::Capacity);
        }
        self.host(host)?;
        let (prior, mut document) = self.read()?;
        if !document.enabled {
            return Ok(0);
        }
        let allowed: Vec<_> = texts
            .iter()
            .copied()
            .filter(|text| eligible_text(text))
            .collect();
        if allowed.is_empty() {
            return Ok(0);
        }
        let (old_writer, actor) = self.actor()?;
        for text in &allowed {
            let used = document.tick(&actor)?;
            let h = document.hosts.entry(host.to_owned()).or_default();
            // A real re-execution outranks, but never erases, a deletion marker.
            if let Some(entry) = h.entries.iter_mut().find(|e| e.text == *text) {
                entry.used = used;
            } else {
                h.entries.push(Entry {
                    text: (*text).to_owned(),
                    used,
                });
            }
            Document::compact(h);
        }
        self.commit(
            prior.as_deref().map(Vec::as_slice),
            &document,
            Some((old_writer.as_deref().map(Vec::as_slice), &actor)),
        )?;
        Ok(allowed.len())
    }
    /// Global clear creates one durable epoch even for unknown/offline hosts.
    /// Host clear preserves a tombstone so a stale payload cannot refill it.
    pub fn clear(&mut self, host: Option<&str>) -> Result<()> {
        if let Some(id) = host {
            self.host(id)?;
        }
        let (prior, mut document) = self.read()?;
        let (old_writer, actor) = self.actor()?;
        let epoch = document.tick(&actor)?;
        if let Some(id) = host {
            document.hosts.insert(
                id.to_owned(),
                HostHistory {
                    clear: epoch,
                    entries: vec![],
                    deleted: vec![],
                },
            );
        } else {
            document.clear_all = epoch;
            document.hosts.clear();
        }
        self.commit(
            prior.as_deref().map(Vec::as_slice),
            &document,
            Some((old_writer.as_deref().map(Vec::as_slice), &actor)),
        )
    }
    /// Round-12 single/batch delete: writes per-text tombstones so older
    /// synced payloads (or an offline device's pre-delete copy) can never
    /// resurrect the command on merge. `host = None` deletes the command on
    /// every host that currently stores it (the suggestion-box delete).
    /// Returns the number of distinct accepted texts. Deleting unknown text
    /// still writes the marker: a device that has not seen the delete yet
    /// must not refill it.
    pub fn delete_commands(&mut self, host: Option<&str>, texts: &[&str]) -> Result<usize> {
        if texts.is_empty() || texts.len() > 32 {
            return Err(HistoryError::Capacity);
        }
        let accepted: Vec<&str> = texts
            .iter()
            .copied()
            .filter(|text| eligible_text(text))
            .collect();
        if accepted.is_empty() {
            return Ok(0);
        }
        let (prior, mut document) = self.read()?;
        if let Some(id) = host {
            // Management must also be able to delete retained history of a
            // removed host, without weakening the recorder's host admission.
            if !document.hosts.contains_key(id) {
                self.host(id)?;
            }
        }
        let (old_writer, actor) = self.actor()?;
        let targets: Vec<String> = match host {
            Some(id) => vec![id.to_owned()],
            None => document.hosts.keys().cloned().collect(),
        };
        let mut touched = false;
        for text in &accepted {
            let at = document.tick(&actor)?;
            for id in &targets {
                let h = document.hosts.entry(id.clone()).or_default();
                // A newer live entry (user re-executed meanwhile) wins over
                // the delete: skip writing a stale marker for it.
                if let Some(entry) = h.entries.iter().find(|e| e.text == *text)
                    && entry.used > at
                {
                    continue;
                }
                if let Some(existing) = h.deleted.iter_mut().find(|t| t.text == *text) {
                    existing.at = existing.at.clone().max(at.clone());
                } else {
                    h.deleted.push(Tombstone {
                        text: (*text).to_owned(),
                        at: at.clone(),
                    });
                }
                h.entries.retain(|e| !(e.text == *text && e.used <= at));
                Document::compact(h);
                touched = true;
            }
        }
        if touched {
            self.commit(
                prior.as_deref().map(Vec::as_slice),
                &document,
                Some((old_writer.as_deref().map(Vec::as_slice), &actor)),
            )?;
        }
        Ok(accepted.len())
    }
    /// One bounded decrypt on the worker: substring, case-insensitive, most
    /// recently used first. Never exposes more than `limit` rows; paging is
    /// the caller's job. Command text never enters diagnostics or errors.
    pub fn search_commands(
        &mut self,
        query: &str,
        host: Option<&str>,
        limit: usize,
    ) -> Result<Vec<CommandSearchHit>> {
        if limit == 0 || limit > 200 {
            return Err(HistoryError::Capacity);
        }
        let document = self.read()?.1;
        let needle = query.to_lowercase();
        let mut hits: Vec<CommandSearchHit> = document
            .hosts
            .iter()
            .filter(|(id, _)| host.is_none_or(|wanted| id.as_str() == wanted))
            .flat_map(|(id, h)| {
                h.entries
                    .iter()
                    .filter(|e| needle.is_empty() || e.text.to_lowercase().contains(&needle))
                    .map(move |e| CommandSearchHit {
                        host_id: id.clone(),
                        text: e.text.clone(),
                        used_counter: e.used.counter,
                    })
            })
            .collect();
        hits.sort_by(|a, b| {
            b.used_counter
                .cmp(&a.used_counter)
                .then_with(|| a.text.cmp(&b.text))
        });
        hits.truncate(limit);
        Ok(hits)
    }
    /// Load once per repository change on a worker. Matching a keystroke uses
    /// this bounded in-memory snapshot, never SQLite, crypto or networking.
    pub fn index(&mut self, host: &str) -> Result<HistoryIndex> {
        self.host(host)?;
        let mut document = self.read()?.1;
        Ok(HistoryIndex {
            vault_scope: self.vault.instance_id().to_owned(),
            host_id: Some(host.to_owned()),
            enabled: document.enabled,
            entries: document.hosts.remove(host).unwrap_or_default().entries,
        })
    }
    /// Shared pool for terminal suggestions: entries from every host, with
    /// identical texts collapsed to their most recent use. Recording keeps the
    /// per-host attribution; only the suggestion pool is global.
    pub fn index_all(&mut self) -> Result<HistoryIndex> {
        let document = self.read()?.1;
        let mut merged: Vec<Entry> = Vec::new();
        for host in document.hosts.values() {
            for entry in &host.entries {
                match merged
                    .iter_mut()
                    .find(|existing| existing.text == entry.text)
                {
                    Some(existing) => {
                        if existing.used < entry.used {
                            existing.used = entry.used.clone();
                        }
                    }
                    None => merged.push(entry.clone()),
                }
            }
        }
        merged.sort_by(|a, b| b.used.cmp(&a.used));
        merged.truncate(MAX_ENTRIES);
        Ok(HistoryIndex {
            vault_scope: self.vault.instance_id().to_owned(),
            host_id: None,
            enabled: document.enabled,
            entries: merged,
        })
    }
    /// Convenience for one-off queries; the terminal must cache index() rather
    /// than decrypting the document for each input update.
    pub fn candidates(
        &mut self,
        host: &str,
        input: &str,
        limit: usize,
    ) -> Result<Vec<Zeroizing<String>>> {
        let index = self.index(host)?;
        index.candidates(self.vault.instance_id(), Some(host), input, limit)
    }
    /// Secret-bearing plaintext payload for a future *encrypted* sync/backup
    /// envelope only. Never log or expose it as a diagnostic/UI text export.
    pub fn export_payload(&self) -> Result<Zeroizing<Vec<u8>>> {
        self.read()?.1.encode()
    }
    /// No network work. A future synchronizer must first authenticate its E2E
    /// envelope, then resolve the formal catalog and history atomically.
    pub fn merge_payload(&mut self, incoming: &[u8]) -> Result<()> {
        let remote = Document::decode(incoming)?;
        let (prior, local) = self.read()?;
        let candidate = Document::merged(&local, &remote)?;
        self.commit(prior.as_deref().map(Vec::as_slice), &candidate, None)
    }
}

/// Backup restore never revives entries hidden by a more recent clear epoch.
/// Explicit removal is a new clear, not deletion of the tombstone document.
pub(crate) fn restore_payload(
    local: Option<&[u8]>,
    incoming: Option<&[u8]>,
) -> Result<Zeroizing<Vec<u8>>> {
    let local = local.map(Document::decode).transpose()?.unwrap_or_default();
    let document = match incoming {
        Some(raw) => Document::merged(&local, &Document::decode(raw)?)?,
        None => {
            let mut document = local;
            document.clear_all = document.tick(&format!("{:032x}", rand::random::<u128>()))?;
            document.hosts.clear();
            document
        }
    };
    document.validate()?;
    let raw = Zeroizing::new(serde_json::to_vec(&document).map_err(|_| HistoryError::Format)?);
    if raw.len() > MAX_BYTES {
        return Err(HistoryError::Capacity);
    }
    Ok(raw)
}

/// The synchronizer only calls this on authenticated allowlisted documents.
/// It is the same clear-epoch CRDT used by the local repository, with no write,
/// logging, remote command collection or unconditional whole-document LWW.
pub(crate) fn remap_sync_hosts(
    raw: &[u8],
    aliases: &BTreeMap<String, String>,
) -> Result<Zeroizing<Vec<u8>>> {
    let mut source = Document::decode(raw)?;
    let original = std::mem::take(&mut source.hosts);
    let mut result = source.clone();
    for (id, history) in original {
        let mut part = source.clone();
        part.hosts
            .insert(aliases.get(&id).cloned().unwrap_or(id), history);
        result = Document::merged(&result, &part)?;
    }
    result.encode()
}

pub(crate) fn merge_sync_payload(a: &[u8], b: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    Document::merged(&Document::decode(a)?, &Document::decode(b)?)?.encode()
}

/// Host IDs that still carry a command-history section. Cloud-sync identity
/// aliases must stay alive for exactly these IDs (plus live hosts) so their
/// sections keep remapping to canonical cloud IDs; any other alias is stale.
pub(crate) fn retained_host_ids(raw: Option<&[u8]>) -> Result<BTreeSet<String>> {
    Ok(match raw {
        None => BTreeSet::new(),
        Some(raw) => Document::decode(raw)?.hosts.into_keys().collect(),
    })
}

/// An immutable, original-Vault snapshot. `host_id: Some(_)` binds the pool to
/// one host; `None` is the shared all-hosts suggestion pool. Its owner must
/// discard it when recording preferences, history or Vault scope changes.
pub struct HistoryIndex {
    vault_scope: String,
    host_id: Option<String>,
    enabled: bool,
    entries: Vec<Entry>,
}
impl HistoryIndex {
    pub fn candidates(
        &self,
        vault_scope: &str,
        host_id: Option<&str>,
        input: &str,
        limit: usize,
    ) -> Result<Vec<Zeroizing<String>>> {
        if vault_scope != self.vault_scope || host_id != self.host_id.as_deref() {
            return Err(HistoryError::Changed);
        }
        if !self.enabled || input.is_empty() || !eligible_text(input) {
            return Ok(vec![]);
        }
        let needle = Zeroizing::new(input.to_lowercase());
        let mut hits: Vec<_> = self
            .entries
            .iter()
            .filter_map(|e| {
                let lower = Zeroizing::new(e.text.to_lowercase());
                let index = lower.find(needle.as_str())?;
                Some((
                    !e.text.starts_with(input),
                    index,
                    Reverse(e.used.clone()),
                    e.text.as_str(),
                ))
            })
            .collect();
        hits.sort();
        Ok(hits
            .into_iter()
            .take(limit.min(20))
            .map(|(_, _, _, text)| Zeroizing::new(text.to_owned()))
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AuthMethod, Credential, HostRecord};
    const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const HOST: &str = "host-11111111111111111111111111111111";
    const OTHER: &str = "host-22222222222222222222222222222222";
    fn add(d: &mut Document, host: &str, text: &str, actor: &str) {
        let used = d.tick(actor).unwrap();
        d.hosts.entry(host.into()).or_default().entries.push(Entry {
            text: text.into(),
            used,
        });
    }
    fn clear_host(d: &mut Document, host: &str, actor: &str) {
        let clear = d.tick(actor).unwrap();
        d.hosts.insert(
            host.into(),
            HostHistory {
                clear,
                entries: vec![],
                deleted: vec![],
            },
        );
    }
    fn names(d: &Document, host: &str) -> Vec<String> {
        d.hosts
            .get(host)
            .map(|h| h.entries.iter().map(|e| e.text.clone()).collect())
            .unwrap_or_default()
    }
    fn host(v: &mut Vault) -> HostRecord {
        Repository::new(v)
            .save(
                HostRecord::new(
                    "Synthetic history".into(),
                    "fixture.invalid".into(),
                    "fixture".into(),
                    AuthMethod::Password,
                ),
                Some(Credential {
                    secret: "synthetic-history-password".into(),
                    passphrase: None,
                }),
            )
            .unwrap()
    }
    #[test]
    fn text_filter_is_conservative_and_never_normalizes_shell_bytes() {
        for valid in [
            "ls",
            "printf '中文 é'",
            "echo 'a  b'  ",
            "git status --short",
            "echo \"$HOME\"",
            "ssh -p 2222 fixture.invalid",
            "sort -u fixture.txt",
        ] {
            assert!(eligible_text(valid));
        }
        for bad in [
            "",
            " leading",
            "\tcommand",
            "echo a\nb",
            "echo a\rb",
            "echo \u{202e}b",
            "echo \u{2028}b",
            "curl -uroot:synthetic-value https://fixture.invalid",
            "mysql -pvalue",
            "tool --api-key=synthetic-value",
            "env PGPASSWORD=synthetic-value psql",
            "curl -H 'Authorization: Bearer synthetic-value' https://fixture.invalid",
            "echo 'BEGIN RSA PRIVATE KEY'",
            "git clone https://user:synthetic-value@fixture.invalid/repo",
        ] {
            assert!(!eligible_text(bad));
        }
        assert!(!eligible_text(&"a".repeat(MAX_COMMAND + 1)));
    }
    #[test]
    fn host_epoch_clear_suppresses_unseen_stale_entries_and_preserves_other_hosts() {
        let mut origin = Document::default();
        add(&mut origin, HOST, "echo observed", A);
        add(&mut origin, OTHER, "echo other", A);
        let mut stale = origin.clone();
        add(&mut stale, HOST, "echo offline unseen", B);
        let mut cleared = origin.clone();
        clear_host(&mut cleared, HOST, A);
        let merged = Document::merged(&cleared, &stale).unwrap();
        assert!(names(&merged, HOST).is_empty());
        assert_eq!(names(&merged, OTHER), ["echo other"]);
        let mut current = merged;
        add(&mut current, HOST, "echo after clear", B);
        let again = Document::merged(&current, &stale).unwrap();
        assert_eq!(names(&again, HOST), ["echo after clear"]);
        assert_eq!(
            current.encode().unwrap().as_slice(),
            again.encode().unwrap().as_slice()
        );
    }
    #[test]
    fn global_epoch_clear_covers_unknown_offline_hosts_without_wall_clocks() {
        let mut local = Document::default();
        add(&mut local, HOST, "echo local", A);
        let mut remote = local.clone();
        add(&mut remote, OTHER, "echo unknown offline host", B);
        local.clear_all = local.tick(A).unwrap();
        local.hosts.clear();
        let mut merged = Document::merged(&local, &remote).unwrap();
        assert!(merged.hosts.is_empty());
        add(&mut merged, HOST, "echo new epoch", A);
        assert_eq!(
            names(&Document::merged(&merged, &remote).unwrap(), HOST),
            ["echo new epoch"]
        );
        assert!(names(&Document::merged(&remote, &merged).unwrap(), OTHER).is_empty());
    }
    #[test]
    fn merge_is_deterministic_idempotent_commutative_and_associative() {
        let mut a = Document::default();
        add(&mut a, HOST, "git status", A);
        let mut b = a.clone();
        add(&mut b, OTHER, "echo other", B);
        let mut c = a.clone();
        clear_host(&mut c, HOST, B);
        add(&mut c, HOST, "git diff", B);
        let ab = Document::merged(&a, &b).unwrap();
        assert_eq!(
            ab.encode().unwrap().as_slice(),
            Document::merged(&b, &a)
                .unwrap()
                .encode()
                .unwrap()
                .as_slice()
        );
        assert_eq!(
            ab.encode().unwrap().as_slice(),
            Document::merged(&ab, &ab)
                .unwrap()
                .encode()
                .unwrap()
                .as_slice()
        );
        let left = Document::merged(&ab, &c).unwrap();
        let right = Document::merged(&a, &Document::merged(&b, &c).unwrap()).unwrap();
        assert_eq!(
            left.encode().unwrap().as_slice(),
            right.encode().unwrap().as_slice()
        );
        assert_eq!(names(&left, HOST), ["git diff"]);
    }
    #[test]
    fn malformed_future_duplicate_and_overflow_payloads_are_rejected() {
        let mut d = Document::default();
        add(&mut d, HOST, "ls", A);
        let mut value = serde_json::to_value(&d).unwrap();
        value["version"] = 2.into();
        assert!(Document::decode(&serde_json::to_vec(&value).unwrap()).is_err());
        value["version"] = 1.into();
        value["unexpected"] = true.into();
        assert!(Document::decode(&serde_json::to_vec(&value).unwrap()).is_err());
        let raw = String::from_utf8(d.encode().unwrap().to_vec()).unwrap();
        let entry = serde_json::to_string(d.hosts.get(HOST).unwrap()).unwrap();
        let duplicate = raw.replace(
            &format!("\"{HOST}\":{entry}"),
            &format!("\"{HOST}\":{entry},\"{HOST}\":{entry}"),
        );
        assert_ne!(duplicate, raw);
        assert!(Document::decode(duplicate.as_bytes()).is_err());
        let mut bad = d.clone();
        bad.hosts
            .get_mut(HOST)
            .unwrap()
            .entries
            .push(d.hosts[HOST].entries[0].clone());
        assert!(bad.validate().is_err());
        bad = d.clone();
        bad.clock = u64::MAX;
        assert!(bad.validate().is_err());
        assert!(bad.tick(A).is_err());
        let mut wrong = d.clone();
        wrong.enabled = false;
        assert!(Document::merged(&d, &wrong).is_err());
        assert!(Document::decode(&vec![0; MAX_BYTES + 1]).is_err());
    }
    #[test]
    fn entries_are_bounded_by_recency_and_merging_never_silently_erases_a_host() {
        let mut d = Document::default();
        for i in 0..PER_HOST + 10 {
            add(&mut d, HOST, &format!("echo {i}"), A);
        }
        Document::compact(d.hosts.get_mut(HOST).unwrap());
        assert_eq!(d.hosts[HOST].entries.len(), PER_HOST);
        assert_eq!(
            d.hosts[HOST].entries[0].text,
            format!("echo {}", PER_HOST + 9)
        );
        assert!(!names(&d, HOST).contains(&"echo 0".to_owned()));
        d.validate().unwrap();
        for i in 0..MAX_HOSTS {
            d.hosts
                .insert(format!("host-{i:032x}"), HostHistory::default());
        }
        assert!(matches!(d.validate(), Err(HistoryError::Capacity)));
    }
    #[test]
    fn encrypted_reopen_disable_dedup_match_and_scoped_clear_preserve_credentials() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.vault");
        let mut v = Vault::create(&path, b"synthetic-history-master").unwrap();
        let a = host(&mut v);
        let b = host(&mut v);
        let credential = v.get(a.credential_id.as_ref().unwrap()).unwrap().unwrap();
        let mut repo = HistoryRepository::new(&mut v);
        assert!(repo.enabled().unwrap());
        for text in [
            "echo synthetic-history-marker",
            "git status",
            "echo git status",
            "git diff",
            "git status",
        ] {
            assert!(repo.record_qualified(&a.id, text).unwrap());
        }
        assert!(
            !repo
                .record_qualified(&a.id, "tool --token=synthetic-value")
                .unwrap()
        );
        let hits = repo.candidates(&a.id, "git", 20).unwrap();
        assert_eq!(
            hits.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
            ["git status", "git diff", "echo git status"]
        );
        assert!(repo.candidates(&b.id, "git", 20).unwrap().is_empty());
        let old = repo.export_payload().unwrap();
        repo.set_enabled(false).unwrap();
        assert!(!repo.record_qualified(&a.id, "echo disabled").unwrap());
        assert!(repo.candidates(&a.id, "git", 20).unwrap().is_empty());
        repo.merge_payload(&old).unwrap();
        assert!(!repo.enabled().unwrap());
        repo.set_enabled(true).unwrap();
        repo.clear(Some(&a.id)).unwrap();
        repo.merge_payload(&old).unwrap();
        assert!(repo.candidates(&a.id, "git", 20).unwrap().is_empty());
        repo.record_qualified(&a.id, "git log").unwrap();
        assert_eq!(
            v.get(a.credential_id.as_ref().unwrap())
                .unwrap()
                .unwrap()
                .as_slice(),
            credential.as_slice()
        );
        drop(v);
        let disk = std::fs::read(&path).unwrap();
        assert!(
            !disk
                .windows(b"synthetic-history-marker".len())
                .any(|s| s == b"synthetic-history-marker")
        );
        let mut v = Vault::open(&path, b"synthetic-history-master").unwrap();
        let mut repo = HistoryRepository::new(&mut v);
        assert_eq!(
            repo.candidates(&a.id, "git", 1).unwrap()[0].as_str(),
            "git log"
        );
        repo.clear(None).unwrap();
        repo.merge_payload(&old).unwrap();
        assert!(repo.candidates(&a.id, "git", 20).unwrap().is_empty());
    }
    #[test]
    fn global_pool_merges_all_hosts_dedupes_by_latest_use_and_keeps_host_binding() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("global-history.vault");
        let mut v = Vault::create(&path, b"synthetic-global-master").unwrap();
        let a = host(&mut v);
        let b = host(&mut v);
        let scope = v.instance_id().to_owned();
        let mut repo = HistoryRepository::new(&mut v);
        repo.record_qualified(&a.id, "git status").unwrap();
        repo.record_qualified(&b.id, "docker ps").unwrap();
        // The same text on two hosts stays one pool entry with the later use.
        repo.record_qualified(&b.id, "git status").unwrap();
        let global = repo.index_all().unwrap();
        let hits = global.candidates(&scope, None, "git", 20).unwrap();
        assert_eq!(
            hits.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
            ["git status",]
        );
        let hits = global.candidates(&scope, None, "d", 20).unwrap();
        assert_eq!(
            hits.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
            ["docker ps"]
        );
        // A host-bound index is not interchangeable with the shared pool.
        let bound = repo.index(&a.id).unwrap();
        assert!(bound.candidates(&scope, Some(&b.id), "git", 20).is_err());
        assert!(global.candidates(&scope, Some(&a.id), "git", 20).is_err());
        // Per-host clear only removes that host's copies; the other host's
        // identical text keeps the shared entry alive.
        repo.clear(Some(&a.id)).unwrap();
        let global = repo.index_all().unwrap();
        assert!(
            !global
                .candidates(&scope, None, "git status", 20)
                .unwrap()
                .is_empty()
        );
        repo.clear(Some(&b.id)).unwrap();
        let global = repo.index_all().unwrap();
        assert!(
            global
                .candidates(&scope, None, "git status", 20)
                .unwrap()
                .is_empty()
        );
        assert!(
            global
                .candidates(&scope, None, "docker", 20)
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn failed_publication_future_format_and_bad_merge_preserve_payload_and_writer() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(
            &dir.path().join("failure.vault"),
            b"synthetic-history-failure",
        )
        .unwrap();
        let h = host(&mut v);
        HistoryRepository::new(&mut v)
            .record_qualified(&h.id, "git status")
            .unwrap();
        let prior = v.get(RECORD).unwrap().unwrap();
        let writer = v.get(WRITER).unwrap().unwrap();
        v.db.execute_batch("CREATE TRIGGER reject_history BEFORE UPDATE ON records WHEN NEW.id='config-command-history-v1' BEGIN SELECT RAISE(ABORT,'synthetic'); END;").unwrap();
        assert!(HistoryRepository::new(&mut v).clear(None).is_err());
        assert_eq!(v.get(RECORD).unwrap().unwrap().as_slice(), prior.as_slice());
        assert_eq!(
            v.get(WRITER).unwrap().unwrap().as_slice(),
            writer.as_slice()
        );
        v.db.execute_batch("DROP TRIGGER reject_history;").unwrap();
        let mut bad: serde_json::Value = serde_json::from_slice(&prior).unwrap();
        bad["version"] = 9.into();
        let bad = serde_json::to_vec(&bad).unwrap();
        assert!(HistoryRepository::new(&mut v).merge_payload(&bad).is_err());
        assert_eq!(v.get(RECORD).unwrap().unwrap().as_slice(), prior.as_slice());
        v.put(RECORD, &bad).unwrap();
        let mut repo = HistoryRepository::new(&mut v);
        assert!(repo.record_qualified(&h.id, "ls").is_err());
        assert!(repo.set_enabled(false).is_err());
        assert!(repo.clear(None).is_err());
        assert_eq!(v.get(RECORD).unwrap().unwrap().as_slice(), bad.as_slice());
    }
    #[test]
    fn stale_writer_cas_and_cached_matches_are_bound_to_original_vault_and_host() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("concurrent.vault");
        let mut v = Vault::create(&path, b"synthetic-concurrent-history").unwrap();
        let h = host(&mut v);
        let scope = v.instance_id().to_owned();
        let mut repo = HistoryRepository::new(&mut v);
        repo.record_qualified(&h.id, "git status").unwrap();
        let index = repo.index(&h.id).unwrap();
        let (prior, stale) = repo.read().unwrap();
        let mut other = Vault::open(&path, b"synthetic-concurrent-history").unwrap();
        HistoryRepository::new(&mut other)
            .record_qualified(&h.id, "git log")
            .unwrap();
        let mut repo = HistoryRepository::new(&mut v);
        assert!(matches!(
            repo.commit(prior.as_deref().map(Vec::as_slice), &stale, None),
            Err(HistoryError::Changed)
        ));
        let current = repo.export_payload().unwrap();
        assert_eq!(
            Document::decode(&current).unwrap().hosts[&h.id]
                .entries
                .len(),
            2
        );
        assert!(
            index
                .candidates(other.instance_id(), Some(&h.id), "git", 20)
                .is_err()
        );
        assert!(index.candidates(&scope, Some(OTHER), "git", 20).is_err());
        drop(v);
        drop(other);
        dir.close().unwrap();
        // Query after the vault/files are gone: no SQLite/crypto/network work.
        assert_eq!(
            index.candidates(&scope, Some(&h.id), "git", 20).unwrap()[0].as_str(),
            "git status"
        );
        assert!(
            index
                .candidates(&scope, Some(&h.id), "", 20)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn tombstone_delete_survives_stale_merge_without_resurrection() {
        let mut origin = Document::default();
        add(&mut origin, HOST, "kubectl delete pod", A);
        let stale = origin.clone();
        // The deleting device removes the entry and writes the marker.
        let mut deleted = origin.clone();
        let at = deleted.tick(A).unwrap();
        let h = deleted.hosts.get_mut(HOST).unwrap();
        h.entries.retain(|e| e.text != "kubectl delete pod");
        h.deleted.push(Tombstone {
            text: "kubectl delete pod".into(),
            at,
        });
        let merged_one = Document::merged(&deleted, &stale).unwrap();
        assert!(
            merged_one.hosts[HOST]
                .entries
                .iter()
                .all(|e| e.text != "kubectl delete pod"),
            "a stale pre-delete payload must not resurrect the command"
        );
        assert!(
            merged_one.hosts[HOST]
                .deleted
                .iter()
                .any(|t| t.text == "kubectl delete pod"),
            "the marker must survive for other stale devices"
        );
        // Commutative: either merge order yields the identical document.
        let merged_two = Document::merged(&stale, &deleted).unwrap();
        assert_eq!(
            serde_json::to_vec(&merged_one).unwrap(),
            serde_json::to_vec(&merged_two).unwrap()
        );
        // Idempotent.
        let again = Document::merged(&merged_one, &merged_two).unwrap();
        assert_eq!(
            serde_json::to_vec(&merged_one).unwrap(),
            serde_json::to_vec(&again).unwrap()
        );
        merged_one.validate().unwrap();
    }

    #[test]
    fn genuinely_newer_execution_survives_without_forgetting_the_tombstone() {
        // Device A deleted the command (marker at=T2). A device whose clock
        // already knows T2 re-executes it (used=T3 > T2): the fresh legal
        // record must survive alongside the older marker. (An offline
        // device whose clock predates the delete is suppressed, consistent
        // with the clear-epoch semantics.)
        let mut deleter = Document::default();
        add(&mut deleter, HOST, "echo again", A);
        let at = deleter.tick(A).unwrap();
        let h = deleter.hosts.get_mut(HOST).unwrap();
        h.entries.retain(|e| e.text != "echo again");
        h.deleted.push(Tombstone {
            text: "echo again".into(),
            at,
        });
        let mut reexecutor = deleter.clone();
        add(&mut reexecutor, HOST, "echo again", B);
        let merged = Document::merged(&deleter, &reexecutor).unwrap();
        assert!(
            merged.hosts[HOST]
                .entries
                .iter()
                .any(|e| e.text == "echo again"),
            "a genuinely newer execution is a fresh legal record"
        );
        assert!(
            merged.hosts[HOST]
                .deleted
                .iter()
                .any(|t| t.text == "echo again"),
            "deletion knowledge remains after the newer execution ages out"
        );
        merged.validate().unwrap();
    }

    #[test]
    fn clear_epoch_still_suppresses_and_prunes_redundant_markers() {
        let mut local = Document::default();
        add(&mut local, HOST, "echo kept", A);
        let at = local.tick(A).unwrap();
        let h = local.hosts.get_mut(HOST).unwrap();
        h.deleted.push(Tombstone {
            text: "echo kept".into(),
            at,
        });
        let clear = local.tick(A).unwrap();
        local.hosts.insert(
            HOST.into(),
            HostHistory {
                clear,
                entries: vec![],
                deleted: vec![],
            },
        );
        let view = local.hosts.get_mut(HOST).unwrap();
        Document::compact(view);
        assert!(
            view.deleted.is_empty(),
            "a clear epoch subsumes older per-text markers"
        );
        local.validate().unwrap();
    }
    #[test]
    fn more_than_one_history_window_of_deletes_never_resurrects_old_commands() {
        let mut stale = Document::default();
        for i in 0..PER_HOST {
            add(&mut stale, HOST, &format!("echo {i}"), A);
        }
        let mut current = stale.clone();
        current.hosts.get_mut(HOST).unwrap().entries.clear();
        for i in 0..PER_HOST + 40 {
            let at = current.tick(B).unwrap();
            current
                .hosts
                .get_mut(HOST)
                .unwrap()
                .deleted
                .push(Tombstone {
                    text: format!("echo {i}"),
                    at,
                });
        }
        Document::compact(current.hosts.get_mut(HOST).unwrap());
        assert_eq!(current.hosts[HOST].deleted.len(), PER_HOST + 40);
        assert!(
            Document::merged(&current, &stale).unwrap().hosts[HOST]
                .entries
                .is_empty()
        );
        let mut executed = current.clone();
        add(&mut executed, HOST, "echo 0", B);
        let mut merged = Document::merged(&executed, &stale).unwrap();
        assert_eq!(names(&merged, HOST), ["echo 0"]);
        for i in 0..PER_HOST {
            add(&mut merged, HOST, &format!("new {i}"), B);
        }
        Document::compact(merged.hosts.get_mut(HOST).unwrap());
        assert!(
            !names(&Document::merged(&merged, &stale).unwrap(), HOST)
                .contains(&"echo 0".to_owned())
        );
    }
    #[test]
    fn disabled_recording_does_not_disable_history_management() {
        let temp = tempfile::tempdir().unwrap();
        let mut v = Vault::create(
            &temp.path().join("manage.vault"),
            b"synthetic-history-manage",
        )
        .unwrap();
        let a = host(&mut v);
        let b = host(&mut v);
        let mut history = HistoryRepository::new(&mut v);
        history.record_qualified(&a.id, "echo shared").unwrap();
        history.record_qualified(&b.id, "echo shared").unwrap();
        history.set_enabled(false).unwrap();
        assert_eq!(
            history.search_commands("shared", None, 100).unwrap().len(),
            2
        );
        assert!(!history.record_qualified(&a.id, "echo ignored").unwrap());
        history
            .delete_commands(Some(&a.id), &["echo shared"])
            .unwrap();
        let hits = history.search_commands("shared", None, 100).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].host_id, b.id);
    }
}
