//! Device-local font bytes and terminal typography. No source paths, terminal
//! text or credentials are stored here. Font binaries must never enter sync.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

const RECORD: &str = "local-terminal-typography-v1";
const DOCUMENT_LIMIT: usize = 2 * 1024 * 1024;
pub const FONT_LIMIT: usize = 32 * 1024 * 1024;
const TOTAL_LIMIT: u64 = 128 * 1024 * 1024;
const COUNT_LIMIT: usize = 8;

#[derive(Debug, thiserror::Error)]
pub enum TypographyError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("字体或排版配置无效、不支持或损坏；原数据未修改")]
    Format,
    #[error("原配置库或字体设置已改变，请重新载入")]
    Changed,
    #[error("字体超过容量：单份32MiB、最多8份、合计128MiB")]
    Capacity,
    #[error("所选导入字体不存在；请选择其他字体或重新导入")]
    Missing,
    #[error("本机排版元数据超过2MiB或10000个主机覆盖；原设置保留")]
    MetadataCapacity,
}
type Result<T> = std::result::Result<T, TypographyError>;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    /// builtin, system or imported. Imported families are content hashes.
    pub kind: String,
    pub family: String,
    pub size: f64,
    pub line_height: f64,
    pub padding: f64,
    pub ligatures: bool,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            kind: "builtin".into(),
            family: "JetBrainsMono".into(),
            size: 15.0,
            line_height: 1.4,
            padding: 8.0,
            ligatures: false,
        }
    }
}
fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
fn valid_id(id: &str) -> bool {
    id.len() == 64
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn label(value: &str) -> bool {
    !value.trim().is_empty()
        && value.len() <= 192
        && !value.chars().any(|c| {
            c.is_control() || matches!(c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
}
impl Settings {
    pub fn validate(&self) -> Result<()> {
        if !self.size.is_finite()
            || !(9.0..=36.0).contains(&self.size)
            || !self.line_height.is_finite()
            || !(1.0..=2.0).contains(&self.line_height)
            || !self.padding.is_finite()
            || !(0.0..=32.0).contains(&self.padding)
        {
            return Err(TypographyError::Format);
        }
        let valid = match self.kind.as_str() {
            "builtin" => matches!(
                self.family.as_str(),
                "JetBrainsMono" | "JetBrainsMonoNerd" | "NotoSansCJK"
            ),
            "system" => label(&self.family) && !self.family.starts_with("HSPImported-"),
            "imported" => valid_id(&self.family),
            _ => false,
        };
        if !valid {
            return Err(TypographyError::Format);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Font {
    pub id: String,
    pub label: String,
    pub bytes: u64,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    version: u32,
    settings: Settings,
    fonts: Vec<Font>,
    #[serde(
        default,
        deserialize_with = "host_settings",
        skip_serializing_if = "BTreeMap::is_empty"
    )]
    hosts: BTreeMap<String, Settings>,
}
fn host_settings<'de, D: serde::Deserializer<'de>>(
    d: D,
) -> std::result::Result<BTreeMap<String, Settings>, D::Error> {
    struct Unique;
    impl<'de> serde::de::Visitor<'de> for Unique {
        type Value = BTreeMap<String, Settings>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("bounded unique host typography")
        }
        fn visit_map<A: serde::de::MapAccess<'de>>(
            self,
            mut m: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut values = BTreeMap::new();
            while let Some(id) = m.next_key::<String>()? {
                if values.len() >= 10000
                    || !crate::repository::valid_id(&id, "host")
                    || values.contains_key(&id)
                {
                    return Err(serde::de::Error::custom("invalid host typography key"));
                }
                values.insert(id, m.next_value()?);
            }
            Ok(values)
        }
    }
    d.deserialize_map(Unique)
}
type LoadedDocument = (
    Document,
    Option<zeroize::Zeroizing<Vec<u8>>>,
    Option<zeroize::Zeroizing<Vec<u8>>>,
);
impl Default for Document {
    fn default() -> Self {
        Self {
            version: 1,
            settings: Settings::default(),
            fonts: Vec::new(),
            hosts: BTreeMap::new(),
        }
    }
}
impl Document {
    fn validate(&self) -> Result<()> {
        self.settings.validate()?;
        if self.hosts.len() > 10000 {
            return Err(TypographyError::MetadataCapacity);
        }
        for (id, settings) in &self.hosts {
            if !crate::repository::valid_id(id, "host") {
                return Err(TypographyError::Format);
            }
            settings.validate()?;
        }
        if self.version != 1 || self.fonts.len() > COUNT_LIMIT {
            return Err(TypographyError::Format);
        }
        let mut ids = std::collections::HashSet::new();
        let mut bytes = 0u64;
        for font in &self.fonts {
            if !valid_id(&font.id)
                || !ids.insert(font.id.as_str())
                || !label(&font.label)
                || font.bytes == 0
                || font.bytes > FONT_LIMIT as u64
            {
                return Err(TypographyError::Format);
            }
            bytes = bytes
                .checked_add(font.bytes)
                .ok_or(TypographyError::Capacity)?;
        }
        if bytes > TOTAL_LIMIT {
            return Err(TypographyError::Capacity);
        }
        if std::iter::once(&self.settings)
            .chain(self.hosts.values())
            .any(|s| s.kind == "imported" && !ids.contains(s.family.as_str()))
        {
            return Err(TypographyError::Missing);
        }
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct View {
    pub vault_scope: String,
    pub revision: String,
    pub settings: Settings,
    pub fonts: Vec<Font>,
    pub hosts: BTreeMap<String, Settings>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Proposal {
    pub vault_scope: String,
    pub revision: String,
    pub settings: Settings,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostProposal {
    pub vault_scope: String,
    pub revision: String,
    pub host_id: String,
    /// None explicitly restores inheritance without deleting the saved host.
    pub settings: Option<Settings>,
}
fn revision(vault: &Vault, raw: Option<&[u8]>, preferences: Option<&[u8]>) -> String {
    let mut token = vault.revision(b"local terminal typography and portable geometry v1");
    token.part(raw);
    token.part(preferences);
    token.finish()
}
fn preferences(raw: Option<&[u8]>) -> Result<crate::terminal_preferences::Settings> {
    let value = match raw {
        Some(bytes) => serde_json::from_slice(bytes).map_err(|_| TypographyError::Format)?,
        None => crate::terminal_preferences::Settings {
            history_lines: crate::terminal_preferences::platform_history_default(),
            ..Default::default()
        },
    };
    value.validate().map_err(|_| TypographyError::Format)?;
    Ok(value)
}
fn document(vault: &Vault) -> Result<LoadedDocument> {
    let raw = vault.get_bounded(RECORD, DOCUMENT_LIMIT)?;
    let mut doc: Document = match &raw {
        None => Document::default(),
        Some(v) => serde_json::from_slice(v).map_err(|_| TypographyError::Format)?,
    };
    doc.validate()?;
    let portable_raw = vault.get_bounded(crate::terminal_preferences::RECORD, 16384)?;
    let portable = preferences(portable_raw.as_deref().map(Vec::as_slice))?;
    if let Some(geometry) = portable.typography {
        if doc.settings.kind == "builtin"
            && let Some(family) = geometry.builtin_family
        {
            doc.settings.family = family;
        }
        doc.settings.size = geometry.size;
        doc.settings.line_height = geometry.line_height;
        doc.settings.padding = geometry.padding;
        doc.settings.ligatures = geometry.ligatures;
    }
    Ok((doc, raw, portable_raw))
}
fn view(vault: &Vault, doc: Document, raw: Option<&[u8]>, preferences: Option<&[u8]>) -> View {
    View {
        vault_scope: vault.instance_id().into(),
        revision: revision(vault, raw, preferences),
        settings: doc.settings,
        fonts: doc.fonts,
        hosts: doc.hosts,
    }
}
pub fn load(vault: &Vault) -> Result<View> {
    let (doc, raw, preferences) = document(vault)?;
    Ok(view(
        vault,
        doc,
        raw.as_deref().map(Vec::as_slice),
        preferences.as_deref().map(Vec::as_slice),
    ))
}
fn checked(vault: &Vault, scope: &str, expected: &str) -> Result<LoadedDocument> {
    if scope != vault.instance_id() {
        return Err(TypographyError::Changed);
    }
    let (doc, raw, preferences) = document(vault)?;
    if revision(
        vault,
        raw.as_deref().map(Vec::as_slice),
        preferences.as_deref().map(Vec::as_slice),
    ) != expected
    {
        return Err(TypographyError::Changed);
    }
    Ok((doc, raw, preferences))
}
fn publish(
    vault: &mut Vault,
    doc: Document,
    prior: Option<&[u8]>,
    preferences_prior: Option<&[u8]>,
    extra: &[RecordChange<'_>],
    checks: &[(&str, Option<&[u8]>)],
) -> Result<View> {
    doc.validate()?;
    let bytes = serde_json::to_vec(&doc).map_err(|_| TypographyError::Format)?;
    if bytes.len() > DOCUMENT_LIMIT {
        return Err(TypographyError::MetadataCapacity);
    }
    let mut changes = vec![RecordChange::Put(RECORD, &bytes)];
    for change in extra {
        changes.push(match change {
            RecordChange::Put(id, data) => RecordChange::Put(id, data),
            RecordChange::Delete(id) => RecordChange::Delete(id),
        });
    }
    let mut expected = vec![
        (RECORD, prior),
        (crate::terminal_preferences::RECORD, preferences_prior),
    ];
    expected.extend_from_slice(checks);
    if !vault.apply_checked(&expected, &changes)? {
        return Err(TypographyError::Changed);
    }
    let next_preferences = extra
        .iter()
        .find_map(|change| match change {
            RecordChange::Put(id, raw) if *id == crate::terminal_preferences::RECORD => Some(*raw),
            _ => None,
        })
        .or(preferences_prior);
    Ok(view(vault, doc, Some(&bytes), next_preferences))
}
pub fn save(vault: &mut Vault, proposal: Proposal) -> Result<View> {
    proposal.settings.validate()?;
    let (mut doc, raw, portable_raw) = checked(vault, &proposal.vault_scope, &proposal.revision)?;
    let body = if proposal.settings.kind == "imported" {
        // Verify the selected binary before committing its reference.
        Some((
            blob_id(&proposal.settings.family),
            font_bytes(
                vault,
                &proposal.vault_scope,
                &proposal.revision,
                &proposal.settings.family,
            )?,
        ))
    } else {
        None
    };
    doc.settings = proposal.settings;
    let mut portable = preferences(portable_raw.as_deref().map(Vec::as_slice))?;
    let builtin_family = if doc.settings.kind == "builtin" {
        Some(doc.settings.family.clone())
    } else {
        portable
            .typography
            .as_ref()
            .and_then(|value| value.builtin_family.clone())
    };
    portable.typography = Some(hspterm_term_core::preferences::Typography {
        size: doc.settings.size,
        line_height: doc.settings.line_height,
        padding: doc.settings.padding,
        ligatures: doc.settings.ligatures,
        builtin_family,
    });
    portable.validate().map_err(|_| TypographyError::Format)?;
    let next_portable = serde_json::to_vec(&portable).map_err(|_| TypographyError::Format)?;
    if next_portable.len() > 16384 {
        return Err(TypographyError::MetadataCapacity);
    }
    let checks = body
        .as_ref()
        .map(|(id, bytes)| (id.as_str(), Some(bytes.as_slice())))
        .into_iter()
        .collect::<Vec<_>>();
    publish(
        vault,
        doc,
        raw.as_deref().map(Vec::as_slice),
        portable_raw.as_deref().map(Vec::as_slice),
        &[RecordChange::Put(
            crate::terminal_preferences::RECORD,
            &next_portable,
        )],
        &checks,
    )
}
pub fn save_host(vault: &mut Vault, proposal: HostProposal) -> Result<View> {
    if !crate::repository::valid_id(&proposal.host_id, "host") {
        return Err(TypographyError::Format);
    }
    let (mut doc, raw, portable_raw) = checked(vault, &proposal.vault_scope, &proposal.revision)?;
    let catalog_raw = vault
        .get_bounded("host-catalog-v1", 2 * 1024 * 1024)?
        .ok_or(TypographyError::Changed)?;
    let catalog: crate::repository::Catalog =
        serde_json::from_slice(&catalog_raw).map_err(|_| TypographyError::Format)?;
    if !catalog.within_limits() || !catalog.hosts.contains(&proposal.host_id) {
        return Err(TypographyError::Changed);
    }
    let host_raw = vault
        .get_bounded(&proposal.host_id, 2 * 1024 * 1024)?
        .ok_or(TypographyError::Changed)?;
    let host: crate::HostRecord =
        serde_json::from_slice(&host_raw).map_err(|_| TypographyError::Format)?;
    host.validate().map_err(|_| TypographyError::Format)?;
    if host.id != proposal.host_id {
        return Err(TypographyError::Changed);
    }
    let body = if let Some(value) = &proposal.settings {
        value.validate()?;
        if value.kind == "imported" {
            Some((
                blob_id(&value.family),
                font_bytes(
                    vault,
                    &proposal.vault_scope,
                    &proposal.revision,
                    &value.family,
                )?,
            ))
        } else {
            None
        }
    } else {
        None
    };
    match proposal.settings {
        Some(value) => {
            doc.hosts.insert(proposal.host_id.clone(), value);
        }
        None => {
            doc.hosts.remove(&proposal.host_id);
        }
    }
    let mut checks = vec![
        ("host-catalog-v1", Some(catalog_raw.as_slice())),
        (proposal.host_id.as_str(), Some(host_raw.as_slice())),
    ];
    if let Some((id, bytes)) = &body {
        checks.push((id.as_str(), Some(bytes.as_slice())));
    }
    publish(
        vault,
        doc,
        raw.as_deref().map(Vec::as_slice),
        portable_raw.as_deref().map(Vec::as_slice),
        &[],
        &checks,
    )
}

/// Structural SFNT bounds checking before storage/engine loading, not a claim
/// that arbitrary third-party outlines are safe or renderable. Flutter's font
/// engine remains responsible for parsing cmap/outlines/shaping.
pub fn validate_font(bytes: &[u8]) -> Result<()> {
    if bytes.len() > FONT_LIMIT {
        return Err(TypographyError::Capacity);
    }
    if bytes.len() < 12 || !(bytes[..4] == [0, 1, 0, 0] || &bytes[..4] == b"OTTO") {
        return Err(TypographyError::Format);
    }
    let n = u16::from_be_bytes([bytes[4], bytes[5]]) as usize;
    if n == 0 || n > 256 || bytes.len() < 12 + n * 16 {
        return Err(TypographyError::Format);
    }
    let mut tags = std::collections::HashSet::new();
    let mut ranges = Vec::new();
    for table in bytes[12..12 + n * 16].as_chunks::<16>().0 {
        let tag: [u8; 4] = table[..4].try_into().map_err(|_| TypographyError::Format)?;
        let offset = u32::from_be_bytes(
            table[8..12]
                .try_into()
                .map_err(|_| TypographyError::Format)?,
        ) as usize;
        let len = u32::from_be_bytes(
            table[12..16]
                .try_into()
                .map_err(|_| TypographyError::Format)?,
        ) as usize;
        let end = offset.checked_add(len).ok_or(TypographyError::Format)?;
        if !tags.insert(tag)
            || !tag.iter().all(|b| (0x20..=0x7e).contains(b))
            || !offset.is_multiple_of(4)
            || offset < 12 + n * 16
            || end > bytes.len()
        {
            return Err(TypographyError::Format);
        }
        if len != 0 {
            ranges.push((offset, end));
        }
    }
    ranges.sort_unstable();
    if ranges.windows(2).any(|w| w[0].1 > w[1].0)
        || [
            *b"head", *b"hhea", *b"maxp", *b"hmtx", *b"cmap", *b"name", *b"OS/2", *b"post",
        ]
        .iter()
        .any(|tag| !tags.contains(tag))
        || if &bytes[..4] == b"OTTO" {
            !tags.contains(b"CFF ") && !tags.contains(b"CFF2")
        } else {
            !tags.contains(b"glyf") || !tags.contains(b"loca")
        }
    {
        return Err(TypographyError::Format);
    }
    Ok(())
}
fn blob_id(id: &str) -> String {
    format!("device-terminal-font-v1-{id}")
}
pub fn import(
    vault: &mut Vault,
    scope: &str,
    expected: &str,
    name: String,
    bytes: &[u8],
) -> Result<View> {
    if !label(&name) {
        return Err(TypographyError::Format);
    }
    validate_font(bytes)?;
    let (mut doc, raw, portable_raw) = checked(vault, scope, expected)?;
    let id = hash(bytes);
    if doc.fonts.iter().any(|font| font.id == id) {
        font_bytes(vault, scope, expected, &id)?;
        return Ok(view(
            vault,
            doc,
            raw.as_deref().map(Vec::as_slice),
            portable_raw.as_deref().map(Vec::as_slice),
        ));
    }
    if doc.fonts.len() >= COUNT_LIMIT
        || doc.fonts.iter().map(|f| f.bytes).sum::<u64>() + bytes.len() as u64 > TOTAL_LIMIT
    {
        return Err(TypographyError::Capacity);
    }
    doc.fonts.push(Font {
        id: id.clone(),
        label: name,
        bytes: bytes.len() as u64,
    });
    let key = blob_id(&id);
    // An orphan from a damaged index is never silently overwritten.
    publish(
        vault,
        doc,
        raw.as_deref().map(Vec::as_slice),
        portable_raw.as_deref().map(Vec::as_slice),
        &[RecordChange::Put(&key, bytes)],
        &[(&key, None)],
    )
}
pub fn font_bytes(vault: &Vault, scope: &str, expected: &str, id: &str) -> Result<Vec<u8>> {
    if !valid_id(id) {
        return Err(TypographyError::Format);
    }
    let (doc, _, _) = checked(vault, scope, expected)?;
    let font = doc
        .fonts
        .iter()
        .find(|font| font.id == id)
        .ok_or(TypographyError::Missing)?;
    let bytes = vault
        .get_bounded(&blob_id(id), FONT_LIMIT)?
        .ok_or(TypographyError::Missing)?;
    if bytes.len() as u64 != font.bytes || hash(&bytes) != id {
        return Err(TypographyError::Format);
    }
    validate_font(&bytes)?;
    Ok(bytes.to_vec())
}
pub fn remove(vault: &mut Vault, scope: &str, expected: &str, id: &str) -> Result<View> {
    if !valid_id(id) {
        return Err(TypographyError::Format);
    }
    let (mut doc, raw, portable_raw) = checked(vault, scope, expected)?;
    let position = doc
        .fonts
        .iter()
        .position(|font| font.id == id)
        .ok_or(TypographyError::Missing)?;
    doc.fonts.remove(position);
    let reset_global = doc.settings.kind == "imported" && doc.settings.family == id;
    if reset_global {
        doc.settings.kind = "builtin".into();
        doc.settings.family = "JetBrainsMono".into();
    }
    for settings in doc.hosts.values_mut() {
        if settings.kind == "imported" && settings.family == id {
            settings.kind = "builtin".into();
            settings.family = "JetBrainsMono".into();
        }
    }
    // The explicit global fallback must agree with the portable preset after
    // reload. Otherwise an older shared Nerd/CJK preset silently wins over the
    // acknowledged JBM fallback. Retire font body/local references/preset in
    // the same transaction, and never update a preset for host-only deletion.
    let next_portable = if reset_global {
        let mut portable = preferences(portable_raw.as_deref().map(Vec::as_slice))?;
        if let Some(style) = portable.typography.as_mut() {
            style.builtin_family = Some("JetBrainsMono".into());
            portable.validate().map_err(|_| TypographyError::Format)?;
            let bytes = zeroize::Zeroizing::new(
                serde_json::to_vec(&portable).map_err(|_| TypographyError::Format)?,
            );
            if bytes.len() > 16384 {
                return Err(TypographyError::MetadataCapacity);
            }
            Some(bytes)
        } else {
            None
        }
    } else {
        None
    };
    let body_id = blob_id(id);
    let mut changes = vec![RecordChange::Delete(&body_id)];
    if let Some(bytes) = &next_portable {
        changes.push(RecordChange::Put(
            crate::terminal_preferences::RECORD,
            bytes,
        ));
    }
    publish(
        vault,
        doc,
        raw.as_deref().map(Vec::as_slice),
        portable_raw.as_deref().map(Vec::as_slice),
        &changes,
        &[],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn global_font_removal_fallback_matches_reload_and_rolls_back_with_shared_preset() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("fallback.vault"), b"synthetic-master").unwrap();
        let source = load(&v).unwrap();
        let preset = save(
            &mut v,
            Proposal {
                vault_scope: source.vault_scope,
                revision: source.revision,
                settings: Settings {
                    family: "JetBrainsMonoNerd".into(),
                    ..Settings::default()
                },
            },
        )
        .unwrap();
        let imported = import(
            &mut v,
            &preset.vault_scope,
            &preset.revision,
            "Synthetic imported".into(),
            &font(),
        )
        .unwrap();
        let id = imported.fonts[0].id.clone();
        let chosen = save(
            &mut v,
            Proposal {
                vault_scope: imported.vault_scope,
                revision: imported.revision,
                settings: Settings {
                    kind: "imported".into(),
                    family: id.clone(),
                    size: 20.,
                    ..Settings::default()
                },
            },
        )
        .unwrap();
        let local = v.get(RECORD).unwrap().unwrap();
        let shared = v.get(crate::terminal_preferences::RECORD).unwrap().unwrap();
        v.db.execute_batch("CREATE TEMP TRIGGER reject_fallback BEFORE INSERT ON records WHEN NEW.id='config-terminal-preferences-v1' BEGIN SELECT RAISE(ABORT,'synthetic fallback failure'); END;").unwrap();
        assert!(remove(&mut v, &chosen.vault_scope, &chosen.revision, &id).is_err());
        assert_eq!(v.get(RECORD).unwrap().unwrap().as_slice(), local.as_slice());
        assert_eq!(
            v.get(crate::terminal_preferences::RECORD)
                .unwrap()
                .unwrap()
                .as_slice(),
            shared.as_slice()
        );
        assert_eq!(
            font_bytes(&v, &chosen.vault_scope, &chosen.revision, &id).unwrap(),
            font()
        );
        v.db.execute_batch("DROP TRIGGER reject_fallback").unwrap();
        let removed = remove(&mut v, &chosen.vault_scope, &chosen.revision, &id).unwrap();
        assert_eq!(removed.settings.family, "JetBrainsMono");
        assert_eq!(removed.settings.size, 20.);
        let fresh = load(&v).unwrap();
        assert_eq!(removed.settings, fresh.settings);
        assert_eq!(removed.revision, fresh.revision);
        assert!(v.get(&blob_id(&id)).unwrap().is_none());

        // A font used only by a host must never change the portable preset.
        let preset = save(
            &mut v,
            Proposal {
                vault_scope: fresh.vault_scope,
                revision: fresh.revision,
                settings: Settings {
                    family: "JetBrainsMonoNerd".into(),
                    ..Settings::default()
                },
            },
        )
        .unwrap();
        let imported = import(
            &mut v,
            &preset.vault_scope,
            &preset.revision,
            "Synthetic host font".into(),
            &font(),
        )
        .unwrap();
        let host = saved_host(&mut v);
        let proposal = host_proposal(
            &v,
            &host,
            Some(Settings {
                kind: "imported".into(),
                family: id.clone(),
                ..Settings::default()
            }),
        );
        let current = save_host(&mut v, proposal).unwrap();
        let shared = v.get(crate::terminal_preferences::RECORD).unwrap().unwrap();
        let removed = remove(
            &mut v,
            &current.vault_scope,
            &current.revision,
            &imported.fonts[0].id,
        )
        .unwrap();
        assert_eq!(removed.settings.family, "JetBrainsMonoNerd");
        assert_eq!(removed.hosts[&host].family, "JetBrainsMono");
        assert_eq!(
            v.get(crate::terminal_preferences::RECORD)
                .unwrap()
                .unwrap()
                .as_slice(),
            shared.as_slice()
        );
        assert_eq!(removed.settings, load(&v).unwrap().settings);
    }
    #[test]
    fn bundled_preset_crosses_devices_but_never_overrides_a_local_system_mapping() {
        let dir = tempfile::tempdir().unwrap();
        let mut source =
            Vault::create(&dir.path().join("source.vault"), b"synthetic-master").unwrap();
        let first = load(&source).unwrap();
        save(
            &mut source,
            Proposal {
                vault_scope: first.vault_scope,
                revision: first.revision,
                settings: Settings {
                    family: "JetBrainsMonoNerd".into(),
                    size: 21.,
                    ..Settings::default()
                },
            },
        )
        .unwrap();
        let raw = source
            .get(crate::terminal_preferences::RECORD)
            .unwrap()
            .unwrap();
        let mut target =
            Vault::create(&dir.path().join("target.vault"), b"synthetic-master").unwrap();
        target
            .put(crate::terminal_preferences::RECORD, &raw)
            .unwrap();
        let shared = load(&target).unwrap();
        assert_eq!(shared.settings.family, "JetBrainsMonoNerd");
        assert_eq!(shared.settings.size, 21.);
        assert!(target.get(RECORD).unwrap().is_none());
        save(
            &mut target,
            Proposal {
                vault_scope: shared.vault_scope,
                revision: shared.revision,
                settings: Settings {
                    kind: "system".into(),
                    family: "Synthetic device mono".into(),
                    size: 17.,
                    ..Settings::default()
                },
            },
        )
        .unwrap();
        assert_eq!(
            crate::terminal_preferences::load(&target)
                .unwrap()
                .value
                .typography
                .unwrap()
                .builtin_family
                .as_deref(),
            Some("JetBrainsMonoNerd")
        );
        // A later remote preference update changes geometry but preserves the
        // explicit device font choice; it also invalidates old font forms.
        target
            .put(crate::terminal_preferences::RECORD, &raw)
            .unwrap();
        let mapped = load(&target).unwrap();
        assert_eq!(mapped.settings.family, "Synthetic device mono");
        assert_eq!(mapped.settings.kind, "system");
        assert_eq!(mapped.settings.size, 21.);
    }
    #[test]
    fn shared_geometry_overlays_local_mapping_and_changes_invalidate_old_font_proposals() {
        let dir = tempfile::tempdir().unwrap();
        let mut v =
            Vault::create(&dir.path().join("portable.vault"), b"synthetic-password").unwrap();
        let first = load(&v).unwrap();
        let local = Settings {
            kind: "system".into(),
            family: "Synthetic local mono".into(),
            size: 18.5,
            line_height: 1.7,
            padding: 6.,
            ligatures: true,
        };
        let saved = save(
            &mut v,
            Proposal {
                vault_scope: first.vault_scope,
                revision: first.revision,
                settings: local.clone(),
            },
        )
        .unwrap();
        let source = crate::terminal_preferences::load(&v).unwrap();
        let geometry = source.value.typography.as_ref().unwrap();
        assert_eq!(geometry.size, local.size);
        assert_eq!(geometry.line_height, local.line_height);
        let raw = v.get(crate::terminal_preferences::RECORD).unwrap().unwrap();
        assert!(
            !std::str::from_utf8(&raw)
                .unwrap()
                .contains("Synthetic local mono")
        );
        let before_local = v.get(RECORD).unwrap().unwrap();
        let mut updated = source.value.clone();
        updated.typography.as_mut().unwrap().size = 22.;
        crate::terminal_preferences::save(&mut v, &source.vault_scope, &source.revision, updated)
            .unwrap();
        let current = load(&v).unwrap();
        assert_eq!(current.settings.family, local.family);
        assert_eq!(current.settings.size, 22.);
        assert_ne!(current.revision, saved.revision);
        assert_eq!(
            v.get(RECORD).unwrap().unwrap().as_slice(),
            before_local.as_slice(),
            "read cannot migrate or overwrite local mapping"
        );
        assert!(
            save(
                &mut v,
                Proposal {
                    vault_scope: saved.vault_scope,
                    revision: saved.revision,
                    settings: local
                }
            )
            .is_err()
        );
        assert_eq!(load(&v).unwrap().settings.size, 22.);
    }
    #[test]
    fn shared_and_local_typography_roll_back_in_one_transaction() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(
            &dir.path().join("atomic-geometry.vault"),
            b"synthetic-password",
        )
        .unwrap();
        let before = load(&v).unwrap();
        v.db.execute_batch("CREATE TEMP TRIGGER reject_portable BEFORE INSERT ON records WHEN NEW.id='config-terminal-preferences-v1' BEGIN SELECT RAISE(ABORT,'synthetic portable failure'); END;").unwrap();
        assert!(
            save(
                &mut v,
                Proposal {
                    vault_scope: before.vault_scope,
                    revision: before.revision.clone(),
                    settings: Settings {
                        size: 19.,
                        ..Settings::default()
                    }
                }
            )
            .is_err()
        );
        assert!(v.get(RECORD).unwrap().is_none());
        assert!(
            v.get(crate::terminal_preferences::RECORD)
                .unwrap()
                .is_none()
        );
        assert_eq!(load(&v).unwrap().revision, before.revision);
        v.db.execute_batch("DROP TRIGGER reject_portable").unwrap();
    }
    #[test]
    fn malformed_or_future_shared_settings_cannot_be_ignored_to_overwrite_fonts() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(
            &dir.path().join("bad-portable.vault"),
            b"synthetic-password",
        )
        .unwrap();
        let original = load(&v).unwrap();
        let malformed = br#"{"version":99,"typography":{"size":22}}"#;
        v.put(crate::terminal_preferences::RECORD, malformed)
            .unwrap();
        assert!(load(&v).is_err());
        assert!(
            save(
                &mut v,
                Proposal {
                    vault_scope: original.vault_scope,
                    revision: original.revision,
                    settings: Settings::default()
                }
            )
            .is_err()
        );
        assert!(v.get(RECORD).unwrap().is_none());
        assert_eq!(
            v.get(crate::terminal_preferences::RECORD)
                .unwrap()
                .unwrap()
                .as_slice(),
            malformed
        );
    }
    fn saved_host(v: &mut Vault) -> String {
        crate::Repository::new(v)
            .save(
                crate::HostRecord::new(
                    "Synthetic typography".into(),
                    "typography.example.test".into(),
                    "tester".into(),
                    crate::AuthMethod::Password,
                ),
                Some(crate::Credential {
                    secret: "synthetic-password".into(),
                    passphrase: None,
                }),
            )
            .unwrap()
            .id
    }
    fn host_proposal(v: &Vault, host_id: &str, settings: Option<Settings>) -> HostProposal {
        let source = load(v).unwrap();
        HostProposal {
            vault_scope: source.vault_scope,
            revision: source.revision,
            host_id: host_id.into(),
            settings,
        }
    }
    #[test]
    fn host_overrides_are_independent_inheritable_and_survive_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("host-font.vault");
        let mut v = Vault::create(&path, b"synthetic-password").unwrap();
        let a = saved_host(&mut v);
        let b = saved_host(&mut v);
        let settings = Settings {
            size: 23.,
            padding: 3.,
            ..Settings::default()
        };
        let proposal = host_proposal(&v, &a, Some(settings.clone()));
        let saved = save_host(&mut v, proposal).unwrap();
        assert_eq!(saved.settings, Settings::default());
        assert_eq!(saved.hosts[&a], settings);
        assert!(!saved.hosts.contains_key(&b));
        let stale = HostProposal {
            vault_scope: saved.vault_scope,
            revision: saved.revision,
            host_id: b.clone(),
            settings: Some(settings.clone()),
        };
        drop(v);
        let mut v = Vault::open(&path, b"synthetic-password").unwrap();
        assert!(save_host(&mut v, stale).is_err());
        assert_eq!(load(&v).unwrap().hosts[&a], settings);
        let proposal = host_proposal(&v, &a, None);
        let inherited = save_host(&mut v, proposal).unwrap();
        assert!(inherited.hosts.is_empty());
        assert!(crate::Repository::new(&mut v).host(&a).unwrap().is_some());
    }
    #[test]
    fn removing_imported_font_resets_all_references_but_preserves_host_geometry() {
        let dir = tempfile::tempdir().unwrap();
        let mut v = Vault::create(&dir.path().join("fonts.vault"), b"synthetic-password").unwrap();
        let a = saved_host(&mut v);
        let b = saved_host(&mut v);
        let original = load(&v).unwrap();
        let source = import(
            &mut v,
            &original.vault_scope,
            &original.revision,
            "synthetic".into(),
            &font(),
        )
        .unwrap();
        let id = source.fonts[0].id.clone();
        let style = Settings {
            kind: "imported".into(),
            family: id.clone(),
            size: 21.,
            line_height: 1.8,
            ligatures: true,
            ..Settings::default()
        };
        for host in [&a, &b] {
            let proposal = host_proposal(&v, host, Some(style.clone()));
            save_host(&mut v, proposal).unwrap();
        }
        let current = load(&v).unwrap();
        let removed = remove(&mut v, &current.vault_scope, &current.revision, &id).unwrap();
        for host in [&a, &b] {
            let s = &removed.hosts[host];
            assert_eq!(s.family, "JetBrainsMono");
            assert_eq!(s.kind, "builtin");
            assert_eq!(s.size, 21.);
            assert_eq!(s.line_height, 1.8);
            assert!(s.ligatures);
        }
        assert_eq!(removed.settings, Settings::default());
    }
    #[test]
    fn invalid_duplicate_or_deleted_host_overrides_never_replace_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let mut v =
            Vault::create(&dir.path().join("invalid.vault"), b"synthetic-password").unwrap();
        let id = saved_host(&mut v);
        let proposal = host_proposal(&v, &id, Some(Settings::default()));
        crate::Repository::new(&mut v)
            .delete(std::slice::from_ref(&id))
            .unwrap();
        assert!(save_host(&mut v, proposal).is_err());
        assert!(v.get(RECORD).unwrap().is_none());
        // serde_json map decoding must not silently accept a duplicate key.
        let settings = serde_json::to_string(&Settings::default()).unwrap();
        let raw = format!(
            r#"{{"version":1,"settings":{settings},"fonts":[],"hosts":{{"{id}":{settings},"{id}":{settings}}}}}"#
        );
        v.put(RECORD, raw.as_bytes()).unwrap();
        assert!(load(&v).is_err());
        assert_eq!(v.get(RECORD).unwrap().unwrap().as_slice(), raw.as_bytes());
    }
    #[test]
    fn bundled_nerd_subset_has_a_valid_sfnt_and_an_explicit_non_default_candidate() {
        let bytes = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../ui_flutter/assets/fonts/HSPNerdSymbols.ttf"
        ))
        .unwrap();
        validate_font(&bytes).unwrap();
        let manifest: serde_json::Value = serde_json::from_slice(include_bytes!(
            "../../../ui_flutter/assets/fonts/HSPNerdSymbols-MANIFEST.json"
        ))
        .unwrap();
        assert_eq!(hash(&bytes), manifest["subset_sha256"].as_str().unwrap());
        assert_eq!(
            bytes.len() as u64,
            manifest["subset_bytes"].as_u64().unwrap()
        );
        assert_eq!(manifest["glyphs"].as_u64(), Some(1111));
        let settings = Settings {
            family: "JetBrainsMonoNerd".into(),
            ..Settings::default()
        };
        settings.validate().unwrap();
        assert_eq!(Settings::default().family, "JetBrainsMono");
    }
    fn font() -> Vec<u8> {
        std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../ui_flutter/assets/fonts/JetBrainsMono-Regular.ttf"
        ))
        .unwrap()
    }
    #[test]
    fn strict_settings_and_structural_font_boundaries() {
        Settings::default().validate().unwrap();
        for bad in [f64::NAN, f64::INFINITY, 0.0, 37.0] {
            let s = Settings {
                size: bad,
                ..Settings::default()
            };
            assert!(s.validate().is_err());
        }
        let good = font();
        validate_font(&good).unwrap();
        for n in [0, 4, 11, 64, good.len() / 2] {
            assert!(validate_font(&good[..n]).is_err());
        }
        let mut bad = good.clone();
        bad[20..24].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(validate_font(&bad).is_err());
        let mut bad = good;
        let duplicate: [u8; 4] = bad[12..16].try_into().unwrap();
        bad[28..32].copy_from_slice(&duplicate);
        assert!(validate_font(&bad).is_err());
        assert!(validate_font(b"ttcf\0\0\0\0\0\0\0\0").is_err());
    }
    #[test]
    fn encrypted_import_selection_removal_and_stale_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("typography.vault");
        let mut vault = Vault::create(&path, b"synthetic-typography-password").unwrap();
        let initial = load(&vault).unwrap();
        let bytes = font();
        let imported = import(
            &mut vault,
            &initial.vault_scope,
            &initial.revision,
            "Synthetic mono".into(),
            &bytes,
        )
        .unwrap();
        assert_eq!(imported.settings, Settings::default());
        let id = imported.fonts[0].id.clone();
        assert_eq!(
            font_bytes(&vault, &imported.vault_scope, &imported.revision, &id).unwrap(),
            bytes
        );
        assert!(
            import(
                &mut vault,
                &initial.vault_scope,
                &initial.revision,
                "Stale".into(),
                &bytes
            )
            .is_err()
        );
        let duplicate = import(
            &mut vault,
            &imported.vault_scope,
            &imported.revision,
            "Duplicate".into(),
            &bytes,
        )
        .unwrap();
        assert_eq!(duplicate.fonts.len(), 1);
        assert_eq!(duplicate.revision, imported.revision);
        let mut settings = imported.settings.clone();
        settings.kind = "imported".into();
        settings.family = id.clone();
        settings.ligatures = true;
        let saved = save(
            &mut vault,
            Proposal {
                vault_scope: imported.vault_scope,
                revision: imported.revision,
                settings,
            },
        )
        .unwrap();
        drop(vault);
        let mut vault = Vault::open(&path, b"synthetic-typography-password").unwrap();
        let current = load(&vault).unwrap();
        assert!(current.settings.ligatures);
        assert!(remove(&mut vault, &saved.vault_scope, &saved.revision, &id).is_err());
        let deleted = remove(&mut vault, &current.vault_scope, &current.revision, &id).unwrap();
        assert_eq!(deleted.settings.family, "JetBrainsMono");
        assert!(deleted.settings.ligatures);
        assert!(vault.get(&blob_id(&id)).unwrap().is_none());
        let raw = std::fs::read(path).unwrap();
        assert!(!raw.windows(14).any(|w| w == b"Synthetic mono"));
    }
    #[test]
    fn future_document_and_dangling_family_cannot_be_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault =
            Vault::create(&dir.path().join("invalid.vault"), b"synthetic-password").unwrap();
        let source = load(&vault).unwrap();
        let mut settings = source.settings.clone();
        settings.kind = "imported".into();
        settings.family = "a".repeat(64);
        assert!(
            save(
                &mut vault,
                Proposal {
                    vault_scope: source.vault_scope,
                    revision: source.revision,
                    settings
                }
            )
            .is_err()
        );
        let future = br#"{"version":99,"settings":{},"fonts":[]}"#;
        vault.put(RECORD, future).unwrap();
        assert!(load(&vault).is_err());
        assert_eq!(vault.get(RECORD).unwrap().unwrap().as_slice(), future);
    }
    #[test]
    fn blob_failure_rolls_back_index_and_other_connection_rejects_old_proposal() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("atomic.vault");
        let mut vault = Vault::create(&path, b"synthetic-atomic-password").unwrap();
        let before = load(&vault).unwrap();
        let bytes = font();
        let id = hash(&bytes);
        vault.db.execute_batch("CREATE TEMP TRIGGER reject_font BEFORE INSERT ON records WHEN NEW.id LIKE 'device-terminal-font-v1-%' BEGIN SELECT RAISE(FAIL, 'synthetic font failure'); END;").unwrap();
        assert!(
            import(
                &mut vault,
                &before.vault_scope,
                &before.revision,
                "Synthetic".into(),
                &bytes
            )
            .is_err()
        );
        assert!(vault.get(RECORD).unwrap().is_none());
        assert!(vault.get(&blob_id(&id)).unwrap().is_none());
        vault.db.execute_batch("DROP TRIGGER reject_font;").unwrap();
        let mut other = Vault::open(&path, b"synthetic-atomic-password").unwrap();
        let other_source = load(&other).unwrap();
        save(
            &mut other,
            Proposal {
                vault_scope: other_source.vault_scope,
                revision: other_source.revision,
                settings: Settings {
                    size: 18.0,
                    ..Settings::default()
                },
            },
        )
        .unwrap();
        assert!(
            save(
                &mut vault,
                Proposal {
                    vault_scope: before.vault_scope,
                    revision: before.revision,
                    settings: Settings::default()
                }
            )
            .is_err()
        );
        assert_eq!(load(&vault).unwrap().settings.size, 18.0);
    }
}
