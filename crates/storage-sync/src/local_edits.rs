//! Device-local encrypted editor drafts. Never configuration/cloud/backup data.
use crate::{RecordChange, StorageError, Vault};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use zeroize::{Zeroize, Zeroizing};

const INDEX: &str = "local-edit-index-v1";
pub const MAX_TEXT_BYTES: usize = 16 * 1024 * 1024;
const MAX_DOCUMENTS: usize = 256;
#[derive(thiserror::Error, Debug)]
pub enum EditError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("本机编辑草稿格式无效或版本不受支持；原数据未覆盖")]
    Format,
    #[error("编辑内容超过内置编辑器16MiB或草稿容量限制；未截断内容")]
    Capacity,
    #[error("草稿版本已改变，请重新读取；未覆盖较新内容")]
    Revision,
    #[error("编码无效或无法无损往返；请选择正确编码，不会替换字符或截断原文件")]
    Encoding,
    #[error("编辑草稿已不存在")]
    Missing,
    #[error("草稿仍关联外部工作文件；请先恢复并确认结束外部编辑、清理工作文件")]
    ExternalCopy,
}
type Result<T> = std::result::Result<T, EditError>;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditTarget {
    pub host_id: String,
    pub address: String,
    pub port: u16,
    pub username: String,
    pub fingerprint: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Encoding {
    Utf8,
    Utf8Bom,
    Utf16Le,
    Utf16Be,
    Utf16LeNoBom,
    Utf16BeNoBom,
    Gb18030,
    Gbk,
    Big5,
    ShiftJis,
    Windows1252,
}
impl Encoding {
    pub fn name(self) -> &'static str {
        match self {
            Self::Utf8 => "utf8",
            Self::Utf8Bom => "utf8_bom",
            Self::Utf16Le => "utf16_le",
            Self::Utf16Be => "utf16_be",
            Self::Utf16LeNoBom => "utf16_le_no_bom",
            Self::Utf16BeNoBom => "utf16_be_no_bom",
            Self::Gb18030 => "gb18030",
            Self::Gbk => "gbk",
            Self::Big5 => "big5",
            Self::ShiftJis => "shift_jis",
            Self::Windows1252 => "windows1252",
        }
    }
    pub fn parse(value: &str) -> Result<Self> {
        Ok(match value {
            "utf8" => Self::Utf8,
            "utf8_bom" => Self::Utf8Bom,
            "utf16_le" => Self::Utf16Le,
            "utf16_be" => Self::Utf16Be,
            "utf16_le_no_bom" => Self::Utf16LeNoBom,
            "utf16_be_no_bom" => Self::Utf16BeNoBom,
            "gb18030" => Self::Gb18030,
            "gbk" => Self::Gbk,
            "big5" => Self::Big5,
            "shift_jis" => Self::ShiftJis,
            "windows1252" => Self::Windows1252,
            _ => return Err(EditError::Encoding),
        })
    }
    fn legacy(self) -> Option<&'static encoding_rs::Encoding> {
        Some(match self {
            Self::Gb18030 => encoding_rs::GB18030,
            Self::Gbk => encoding_rs::GBK,
            Self::Big5 => encoding_rs::BIG5,
            Self::ShiftJis => encoding_rs::SHIFT_JIS,
            Self::Windows1252 => encoding_rs::WINDOWS_1252,
            _ => return None,
        })
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LineEnding {
    Preserve,
    Lf,
    Crlf,
    Cr,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditMetadata {
    pub version: u32,
    pub id: String,
    pub target: EditTarget,
    /// Canonical absolute path resolved only when explicitly opening the file.
    pub path: String,
    pub encoding: Encoding,
    pub line_ending: LineEnding,
    pub revision: u64,
    pub saved_revision: u64,
    /// Device-local path; excluded with this journal from config sync/backup.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_directory: Option<String>,
}
pub struct EditDraft {
    pub metadata: EditMetadata,
    pub text: String,
}
impl Drop for EditDraft {
    fn drop(&mut self) {
        self.text.zeroize();
    }
}
impl EditMetadata {
    pub fn dirty(&self) -> bool {
        self.revision != self.saved_revision
    }
    pub(crate) fn validate(&self) -> Result<()> {
        if self.version != 1
            || !valid_id(&self.id)
            || self.revision == 0
            || self.saved_revision > self.revision
            || !self.path.starts_with('/')
            || self.path.contains('\0')
            || self.path.len() > 131072
            || self.target.host_id.is_empty()
            || self.target.host_id.len() > 256
            || self.target.address.is_empty()
            || self.target.address.len() > 1024
            || self.target.port == 0
            || self.target.username.is_empty()
            || self.target.username.len() > 1024
            || self.target.fingerprint.is_empty()
            || self.target.fingerprint.len() > 1024
            || self.external_directory.as_ref().is_some_and(|v| {
                v.len() > 32768
                    || v.contains('\0')
                    || !crate::external_edits::valid_location(std::path::Path::new(v), &self.id)
            })
        {
            return Err(EditError::Format);
        }
        Ok(())
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Inventory {
    version: u32,
    ids: Vec<String>,
}
fn valid_id(id: &str) -> bool {
    id.strip_prefix("edit-")
        .is_some_and(|v| v.len() == 32 && v.bytes().all(|c| c.is_ascii_hexdigit()))
}
fn keys(id: &str) -> Result<(String, String)> {
    if !valid_id(id) {
        return Err(EditError::Format);
    }
    Ok((
        format!("local-edit-meta-{id}"),
        format!("local-edit-body-{id}"),
    ))
}
pub struct EditJournal<'a> {
    vault: &'a mut Vault,
}
impl<'a> EditJournal<'a> {
    pub fn new(vault: &'a mut Vault) -> Self {
        Self { vault }
    }
    fn inventory(&self) -> Result<Inventory> {
        let Some(raw) = self.vault.get(INDEX)? else {
            return Ok(Inventory {
                version: 1,
                ids: vec![],
            });
        };
        if raw.len() > 64 * 1024 {
            return Err(EditError::Capacity);
        }
        let index: Inventory = serde_json::from_slice(&raw).map_err(|_| EditError::Format)?;
        let mut seen = HashSet::new();
        if index.version != 1
            || index.ids.len() > MAX_DOCUMENTS
            || index.ids.iter().any(|id| !valid_id(id) || !seen.insert(id))
        {
            return Err(EditError::Format);
        }
        Ok(index)
    }
    fn metadata(&self, id: &str) -> Result<EditMetadata> {
        let (key, _) = keys(id)?;
        let raw = self.vault.get(&key)?.ok_or(EditError::Format)?;
        if raw.len() > 256 * 1024 {
            return Err(EditError::Capacity);
        }
        let meta: EditMetadata = serde_json::from_slice(&raw).map_err(|_| EditError::Format)?;
        meta.validate()?;
        if meta.id != id {
            return Err(EditError::Format);
        }
        Ok(meta)
    }
    /// List metadata only; never decrypt every file body to populate the UI.
    pub fn list(&self) -> Result<Vec<EditMetadata>> {
        self.inventory()?
            .ids
            .iter()
            .map(|id| self.metadata(id))
            .collect()
    }
    pub fn load(&self, id: &str) -> Result<EditDraft> {
        let (_, body) = keys(id)?;
        if !self.inventory()?.ids.iter().any(|v| v == id) {
            return Err(EditError::Missing);
        }
        let meta = self.metadata(id)?;
        let raw = self.vault.get(&body)?.ok_or(EditError::Format)?;
        if raw.len() > MAX_TEXT_BYTES {
            return Err(EditError::Capacity);
        }
        let text = std::str::from_utf8(&raw)
            .map_err(|_| EditError::Format)?
            .to_owned();
        Ok(EditDraft {
            metadata: meta,
            text,
        })
    }
    /// CAS on the previous revision. Index, metadata and body change atomically.
    pub fn save(&mut self, draft: &EditDraft, expected: Option<u64>) -> Result<()> {
        draft.metadata.validate()?;
        if draft.text.len() > MAX_TEXT_BYTES {
            return Err(EditError::Capacity);
        }
        let (meta_key, body_key) = keys(&draft.metadata.id)?;
        let mut index = self.inventory()?;
        let exists = index.ids.iter().any(|v| v == &draft.metadata.id);
        if exists {
            let old = self.metadata(&draft.metadata.id)?;
            if expected != Some(old.revision)
                || old.revision.checked_add(1) != Some(draft.metadata.revision)
                || draft.metadata.saved_revision != old.saved_revision
            {
                return Err(EditError::Revision);
            }
            if old.target != draft.metadata.target
                || old.path != draft.metadata.path
                || old.external_directory != draft.metadata.external_directory
            {
                return Err(EditError::Format);
            }
        } else {
            if expected.is_some() {
                return Err(EditError::Missing);
            }
            if draft.metadata.revision != 1 || draft.metadata.saved_revision != 1 {
                return Err(EditError::Revision);
            }
            if index.ids.len() >= MAX_DOCUMENTS {
                return Err(EditError::Capacity);
            }
            index.ids.push(draft.metadata.id.clone());
        }
        let inventory = Zeroizing::new(serde_json::to_vec(&index).map_err(|_| EditError::Format)?);
        let meta =
            Zeroizing::new(serde_json::to_vec(&draft.metadata).map_err(|_| EditError::Format)?);
        self.vault.apply(&[
            RecordChange::Put(INDEX, &inventory),
            RecordChange::Put(&meta_key, &meta),
            RecordChange::Put(&body_key, draft.text.as_bytes()),
        ])?;
        Ok(())
    }
    /// Only after the remote content and CLOSE/commit response succeeded.
    /// Updating this marker does not re-encrypt/rewrite the whole file body.
    pub fn mark_saved(&mut self, id: &str, expected: u64) -> Result<EditMetadata> {
        if !self.inventory()?.ids.iter().any(|v| v == id) {
            return Err(EditError::Missing);
        }
        let mut meta = self.metadata(id)?;
        if meta.revision != expected {
            return Err(EditError::Revision);
        }
        meta.saved_revision = expected;
        let raw = Zeroizing::new(serde_json::to_vec(&meta).map_err(|_| EditError::Format)?);
        self.vault.put(&keys(id)?.0, &raw)?;
        Ok(meta)
    }
    /// Pin BEFORE publishing plaintext. Clear only after confirmed cache cleanup.
    /// This metadata-only change does not mark content saved or rewrite its body.
    pub fn set_external_directory(
        &mut self,
        id: &str,
        expected: u64,
        directory: Option<String>,
    ) -> Result<EditMetadata> {
        if !self.inventory()?.ids.iter().any(|v| v == id) {
            return Err(EditError::Missing);
        }
        let mut meta = self.metadata(id)?;
        if meta.revision != expected {
            return Err(EditError::Revision);
        }
        if meta.external_directory.is_some()
            && directory.is_some()
            && meta.external_directory != directory
        {
            return Err(EditError::Format);
        }
        meta.external_directory = directory;
        meta.validate()?;
        let raw = Zeroizing::new(serde_json::to_vec(&meta).map_err(|_| EditError::Format)?);
        self.vault.put(&keys(id)?.0, &raw)?;
        Ok(meta)
    }
    /// Only an explicit close/discard or confirmed-clean shutdown may call this.
    pub fn remove(&mut self, id: &str) -> Result<()> {
        let (meta, body) = keys(id)?;
        let mut index = self.inventory()?;
        if !index.ids.iter().any(|v| v == id) {
            return Ok(());
        }
        // Validate before deleting so a future format is never silently erased.
        if self.metadata(id)?.external_directory.is_some() {
            return Err(EditError::ExternalCopy);
        }
        index.ids.retain(|v| v != id);
        let raw = Zeroizing::new(serde_json::to_vec(&index).map_err(|_| EditError::Format)?);
        self.vault.apply(&[
            RecordChange::Put(INDEX, &raw),
            RecordChange::Delete(&meta),
            RecordChange::Delete(&body),
        ])?;
        Ok(())
    }
}

pub fn decode(bytes: &[u8]) -> Result<(String, Encoding, LineEnding)> {
    decode_with_encoding(bytes, None)
}
/// Automatic mode accepts Unicode only. Legacy encodings require a user choice.
pub fn decode_with_encoding(
    bytes: &[u8],
    selected: Option<Encoding>,
) -> Result<(String, Encoding, LineEnding)> {
    if bytes.len() > MAX_TEXT_BYTES * 2 + 2 {
        return Err(EditError::Capacity);
    }
    let bom = if bytes.starts_with(&[0xff, 0xfe]) {
        Some(Encoding::Utf16Le)
    } else if bytes.starts_with(&[0xfe, 0xff]) {
        Some(Encoding::Utf16Be)
    } else if bytes.starts_with(&[0xef, 0xbb, 0xbf]) {
        Some(Encoding::Utf8Bom)
    } else {
        None
    };
    if let Some(hint) = selected {
        if bom.is_some_and(|actual| {
            actual != hint && !(hint == Encoding::Utf8 && actual == Encoding::Utf8Bom)
        }) {
            return Err(EditError::Encoding);
        }
        if let Some(codec) = hint.legacy() {
            let decoded = codec
                .decode_without_bom_handling_and_without_replacement(bytes)
                .ok_or(EditError::Encoding)?;
            let mut text = Zeroizing::new(decoded.into_owned());
            // Several legacy byte sequences map to the same Unicode value.
            // Refuse an edit that would silently change the original bytes.
            if *encode(&text, hint, LineEnding::Preserve)? != bytes {
                return Err(EditError::Encoding);
            }
            return finish_decode(std::mem::take(&mut *text), hint);
        }
        if matches!(hint, Encoding::Utf16LeNoBom | Encoding::Utf16BeNoBom) {
            return finish_decode(decode_utf16(bytes, hint == Encoding::Utf16LeNoBom)?, hint);
        }
        if matches!(
            hint,
            Encoding::Utf16Le | Encoding::Utf16Be | Encoding::Utf8Bom
        ) && bom.is_none()
        {
            return Err(EditError::Encoding);
        }
    }
    let (text, encoding) = if bytes.starts_with(&[0xff, 0xfe]) || bytes.starts_with(&[0xfe, 0xff]) {
        let little = bytes[0] == 0xff;
        (
            decode_utf16(&bytes[2..], little)?,
            if little {
                Encoding::Utf16Le
            } else {
                Encoding::Utf16Be
            },
        )
    } else {
        let (body, encoding) = bytes
            .strip_prefix(&[0xef, 0xbb, 0xbf])
            .map_or((bytes, Encoding::Utf8), |v| (v, Encoding::Utf8Bom));
        if body.len() > MAX_TEXT_BYTES {
            return Err(EditError::Capacity);
        }
        (
            std::str::from_utf8(body)
                .map_err(|_| EditError::Encoding)?
                .to_owned(),
            encoding,
        )
    };
    finish_decode(text, encoding)
}
fn decode_utf16(bytes: &[u8], little: bool) -> Result<String> {
    if !bytes.len().is_multiple_of(2) {
        return Err(EditError::Encoding);
    }
    let units = bytes.as_chunks::<2>().0.iter().map(|b| {
        if little {
            u16::from_le_bytes(*b)
        } else {
            u16::from_be_bytes(*b)
        }
    });
    let mut text = Zeroizing::new(String::new());
    for c in char::decode_utf16(units) {
        text.push(c.map_err(|_| EditError::Encoding)?);
        if text.len() > MAX_TEXT_BYTES {
            return Err(EditError::Capacity);
        }
    }
    Ok(std::mem::take(&mut *text))
}
fn finish_decode(text: String, encoding: Encoding) -> Result<(String, Encoding, LineEnding)> {
    let text = Zeroizing::new(text);
    if text.len() > MAX_TEXT_BYTES {
        return Err(EditError::Capacity);
    }
    if text.contains('\0') {
        return Err(EditError::Encoding);
    }
    let mut kinds = HashSet::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\r' {
            if chars.next_if_eq(&'\n').is_some() {
                kinds.insert(2);
            } else {
                kinds.insert(3);
            }
        } else if c == '\n' {
            kinds.insert(1);
        }
    }
    let ending = if kinds.len() > 1 {
        LineEnding::Preserve
    } else if kinds.contains(&2) {
        LineEnding::Crlf
    } else if kinds.contains(&3) {
        LineEnding::Cr
    } else {
        LineEnding::Lf
    };
    let mut text = text;
    Ok((std::mem::take(&mut *text), encoding, ending))
}
pub fn encode(text: &str, encoding: Encoding, ending: LineEnding) -> Result<Zeroizing<Vec<u8>>> {
    if text.len() > MAX_TEXT_BYTES {
        return Err(EditError::Capacity);
    }
    let newline = match ending {
        LineEnding::Preserve => None,
        LineEnding::Lf => Some("\n"),
        LineEnding::Crlf => Some("\r\n"),
        LineEnding::Cr => Some("\r"),
    };
    let normalized = newline.map(|newline| {
        let mut result = Zeroizing::new(String::with_capacity(text.len()));
        let mut chars = text.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\r' {
                chars.next_if_eq(&'\n');
                result.push_str(newline);
            } else if c == '\n' {
                result.push_str(newline);
            } else {
                result.push(c);
            }
        }
        result
    });
    let text = normalized.as_deref().map_or(text, String::as_str);
    let mut bytes = Zeroizing::new(Vec::new());
    match encoding {
        Encoding::Utf8 => bytes.extend_from_slice(text.as_bytes()),
        Encoding::Utf8Bom => {
            bytes.extend_from_slice(&[0xef, 0xbb, 0xbf]);
            bytes.extend_from_slice(text.as_bytes());
        }
        Encoding::Utf16Le | Encoding::Utf16Be | Encoding::Utf16LeNoBom | Encoding::Utf16BeNoBom => {
            let little = matches!(encoding, Encoding::Utf16Le | Encoding::Utf16LeNoBom);
            if matches!(encoding, Encoding::Utf16Le | Encoding::Utf16Be) {
                bytes.extend_from_slice(if little { &[0xff, 0xfe] } else { &[0xfe, 0xff] });
            }
            for unit in text.encode_utf16() {
                bytes.extend_from_slice(&if little {
                    unit.to_le_bytes()
                } else {
                    unit.to_be_bytes()
                });
            }
        }
        legacy => {
            let codec = legacy.legacy().ok_or(EditError::Encoding)?;
            let (encoded, _, errors) = codec.encode(text);
            let encoded = Zeroizing::new(encoded.into_owned());
            if errors {
                return Err(EditError::Encoding);
            }
            let check = codec
                .decode_without_bom_handling_and_without_replacement(&encoded)
                .ok_or(EditError::Encoding)?;
            let check = Zeroizing::new(check.into_owned());
            if check.as_str() != text {
                return Err(EditError::Encoding);
            }
            bytes.extend_from_slice(&encoded);
        }
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bomless_utf16_requires_explicit_order_preserves_bytes_and_rejects_bad_units() {
        for codec in [Encoding::Utf16LeNoBom, Encoding::Utf16BeNoBom] {
            let bytes = encode("中文 é 😀\r\n", codec, LineEnding::Preserve).unwrap();
            assert!(decode(&bytes).is_err());
            let (text, format, _) = decode_with_encoding(&bytes, Some(codec)).unwrap();
            assert_eq!(text, "中文 é 😀\r\n");
            assert_eq!(format, codec);
            assert_eq!(
                *encode(&text, format, LineEnding::Preserve).unwrap(),
                *bytes
            );
            assert!(decode_with_encoding(&[1], Some(codec)).is_err());
        }
        assert!(decode_with_encoding(&[0, 0xd8], Some(Encoding::Utf16LeNoBom)).is_err());
        assert!(decode_with_encoding(&[0xd8, 0], Some(Encoding::Utf16BeNoBom)).is_err());
        assert!(
            decode_with_encoding(&[0xff, 0xfe, 0x2d, 0x4e], Some(Encoding::Utf16LeNoBom)).is_err()
        );
    }
    #[test]
    fn explicit_legacy_codecs_round_trip_known_bytes_and_never_guess() {
        for (codec, raw, text) in [
            (Encoding::Gbk, b"\xd6\xd0\xce\xc4".as_slice(), "中文"),
            (Encoding::Gb18030, b"\x94\x39\xfc\x36".as_slice(), "😀"),
            (Encoding::Big5, b"\xa4\xa4\xa4\xe5".as_slice(), "中文"),
            (Encoding::ShiftJis, b"\x93\xfa\x96\x7b".as_slice(), "日本"),
            (Encoding::Windows1252, b"caf\xe9 \x80".as_slice(), "café €"),
        ] {
            let (decoded, encoding, _) = decode_with_encoding(raw, Some(codec)).unwrap();
            assert_eq!(decoded, text);
            assert_eq!(encoding, codec);
            assert_eq!(*encode(text, codec, LineEnding::Preserve).unwrap(), raw);
            assert_eq!(Encoding::parse(codec.name()).unwrap(), codec);
            assert!(decode(raw).is_err(), "legacy bytes must never be guessed");
        }
    }
    #[test]
    fn legacy_codecs_reject_corruption_unmappable_text_and_best_fit_changes() {
        for (codec, raw) in [
            (Encoding::Gbk, b"\x81".as_slice()),
            (Encoding::Gb18030, b"\x81\x30\x81".as_slice()),
            (Encoding::Big5, b"\xa4".as_slice()),
            (Encoding::ShiftJis, b"\x93".as_slice()),
        ] {
            assert!(decode_with_encoding(raw, Some(codec)).is_err());
        }
        assert!(encode("😀", Encoding::Gbk, LineEnding::Preserve).is_err());
        assert!(encode("中文", Encoding::Windows1252, LineEnding::Preserve).is_err());
        assert!(encode("¥", Encoding::ShiftJis, LineEnding::Preserve).is_err());
        assert!(decode_with_encoding(b"\xef\xbb\xbfhello", Some(Encoding::Gbk)).is_err());
        assert!(decode_with_encoding(b"abc\0def", Some(Encoding::Gbk)).is_err());
        assert_eq!(
            *encode("中\n文", Encoding::Gbk, LineEnding::Crlf).unwrap(),
            b"\xd6\xd0\r\n\xce\xc4"
        );
    }
    const ID: &str = "edit-00000000000000000000000000000001";
    fn draft() -> EditDraft {
        EditDraft {
            metadata: EditMetadata {
                version: 1,
                id: ID.into(),
                target: EditTarget {
                    host_id: "host-fixture".into(),
                    address: "fixture.invalid".into(),
                    port: 22,
                    username: "fixture".into(),
                    fingerprint: "SHA256:fixture".into(),
                },
                path: "/remote/中文 space.txt".into(),
                encoding: Encoding::Utf8,
                line_ending: LineEnding::Lf,
                revision: 1,
                saved_revision: 1,
                external_directory: None,
            },
            text: "editor private fixture body 中文 é\n".into(),
        }
    }
    #[test]
    fn encrypted_external_intent_pins_work_files_without_rewriting_or_dropping_the_draft() {
        let base = tempfile::tempdir().unwrap();
        let database = base.path().join("local.vault");
        let mut vault = Vault::create(&database, b"test-only-editor-master").unwrap();
        let original = draft();
        assert!(
            serde_json::to_value(&original.metadata)
                .unwrap()
                .get("external_directory")
                .is_none(),
            "ordinary drafts retain the previous serialized format"
        );
        EditJournal::new(&mut vault).save(&original, None).unwrap();
        let body_key = keys(ID).unwrap().1;
        let before: Vec<u8> = vault
            .db
            .query_row(
                "SELECT ciphertext FROM records WHERE id=?1",
                [&body_key],
                |r| r.get(0),
            )
            .unwrap();
        let directory = crate::external_edits::ExternalCopy::location(base.path(), ID)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let meta = EditJournal::new(&mut vault)
            .set_external_directory(ID, 1, Some(directory.clone()))
            .unwrap();
        assert_eq!(meta.revision, 1);
        assert_eq!(meta.saved_revision, 1);
        let other = base
            .path()
            .join("other")
            .join(crate::external_edits::DIRECTORY)
            .join(ID)
            .to_string_lossy()
            .into_owned();
        assert!(
            EditJournal::new(&mut vault)
                .set_external_directory(ID, 1, Some(other))
                .is_err()
        );
        let mut invalid = draft();
        invalid.metadata.revision = 2;
        assert!(
            EditJournal::new(&mut vault)
                .save(&invalid, Some(1))
                .is_err(),
            "content writes cannot clear an external file pin"
        );
        let after: Vec<u8> = vault
            .db
            .query_row(
                "SELECT ciphertext FROM records WHERE id=?1",
                [&body_key],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(before, after);
        assert!(matches!(
            EditJournal::new(&mut vault).remove(ID),
            Err(EditError::ExternalCopy)
        ));
        drop(vault);
        let disk = std::fs::read(&database).unwrap();
        assert!(
            !disk
                .windows(directory.len())
                .any(|b| b == directory.as_bytes())
        );
        let mut vault = Vault::open(&database, b"test-only-editor-master").unwrap();
        let restored = EditJournal::new(&mut vault).load(ID).unwrap();
        assert_eq!(
            restored.metadata.external_directory.as_deref(),
            Some(directory.as_str())
        );
        assert_eq!(restored.text, original.text);
        assert!(
            EditJournal::new(&mut vault)
                .set_external_directory(ID, 0, None)
                .is_err()
        );
        EditJournal::new(&mut vault)
            .set_external_directory(ID, 1, None)
            .unwrap();
        EditJournal::new(&mut vault).remove(ID).unwrap();
        assert!(EditJournal::new(&mut vault).list().unwrap().is_empty());
    }
    #[test]
    fn codecs_preserve_bom_unicode_and_mixed_line_endings_without_lossy_decoding() {
        for text in [
            "",
            "中文 é 😀\nnext\n",
            "first\r\n中文\r\n",
            "one\rtwo\r",
            "one\r\ntwo\nthree\r",
        ] {
            for encoding in [
                Encoding::Utf8,
                Encoding::Utf8Bom,
                Encoding::Utf16Le,
                Encoding::Utf16Be,
            ] {
                let bytes = encode(text, encoding, LineEnding::Preserve).unwrap();
                let (decoded, format, ending) = decode(&bytes).unwrap();
                assert_eq!(decoded, text);
                assert_eq!(format, encoding);
                assert_eq!(*encode(&decoded, format, ending).unwrap(), *bytes);
            }
        }
        for invalid in [
            b"bad\0binary".as_slice(),
            &[0xff],
            &[0xff, 0xfe, 0x00],
            &[0xff, 0xfe, 0x00, 0xd8],
            &[0xfe, 0xff, 0xdc, 0x00],
        ] {
            assert!(decode(invalid).is_err());
        }
        assert_eq!(
            *encode("a\r\nb\nc\r", Encoding::Utf8, LineEnding::Crlf).unwrap(),
            b"a\r\nb\r\nc\r\n"
        );
    }
    #[test]
    fn journal_reopens_encrypted_dirty_data_and_rejects_old_writers_or_target_changes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("editor.vault");
        let mut vault = Vault::create(&path, b"test-only-editor-journal").unwrap();
        let mut data = draft();
        let mut journal = EditJournal::new(&mut vault);
        journal.save(&data, None).unwrap();
        data.metadata.revision = 2;
        data.text.push_str("unsaved local modification");
        journal.save(&data, Some(1)).unwrap();
        assert!(matches!(
            journal.save(&draft(), Some(1)),
            Err(EditError::Revision)
        ));
        data.metadata.revision = 3;
        data.metadata.target.address = "another.invalid".into();
        assert!(matches!(
            journal.save(&data, Some(2)),
            Err(EditError::Format)
        ));
        drop(vault);
        let raw = std::fs::read(&path).unwrap();
        for value in [
            "unsaved local modification",
            "editor private fixture",
            "fixture.invalid",
            "/remote/",
        ] {
            assert!(!String::from_utf8_lossy(&raw).contains(value));
        }
        let mut vault = Vault::open(&path, b"test-only-editor-journal").unwrap();
        let mut journal = EditJournal::new(&mut vault);
        let data = journal.load(ID).unwrap();
        assert!(data.metadata.dirty());
        assert_eq!(data.metadata.revision, 2);
        assert!(data.text.ends_with("unsaved local modification"));
        journal.remove(ID).unwrap();
        assert!(journal.list().unwrap().is_empty());
        let (meta, body) = keys(ID).unwrap();
        assert!(vault.get(&meta).unwrap().is_none());
        assert!(vault.get(&body).unwrap().is_none());
    }
    #[test]
    fn save_ack_changes_only_metadata_and_old_ack_cannot_mark_new_text_clean() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault =
            Vault::create(&dir.path().join("ack.vault"), b"test-only-edit-ack").unwrap();
        let mut data = draft();
        EditJournal::new(&mut vault).save(&data, None).unwrap();
        data.metadata.revision = 2;
        data.text.push_str(" changed");
        EditJournal::new(&mut vault).save(&data, Some(1)).unwrap();
        let cipher = |v: &Vault| -> Vec<u8> {
            v.db.query_row(
                "SELECT ciphertext FROM records WHERE id=?1",
                [keys(ID).unwrap().1],
                |r| r.get(0),
            )
            .unwrap()
        };
        let body = cipher(&vault);
        assert!(matches!(
            EditJournal::new(&mut vault).mark_saved(ID, 1),
            Err(EditError::Revision)
        ));
        let saved = EditJournal::new(&mut vault).mark_saved(ID, 2).unwrap();
        assert!(!saved.dirty());
        assert_eq!(cipher(&vault), body);
        assert!(matches!(
            EditJournal::new(&mut vault).save(&data, Some(2)),
            Err(EditError::Revision)
        ));
        data.metadata.revision = 3;
        data.metadata.saved_revision = 2;
        data.text.push_str(" again");
        EditJournal::new(&mut vault).save(&data, Some(2)).unwrap();
        assert!(matches!(
            EditJournal::new(&mut vault).mark_saved(ID, 2),
            Err(EditError::Revision)
        ));
        assert!(
            EditJournal::new(&mut vault)
                .load(ID)
                .unwrap()
                .metadata
                .dirty()
        );
    }
    #[test]
    fn future_formats_and_oversized_updates_do_not_destroy_recoverable_drafts() {
        let dir = tempfile::tempdir().unwrap();
        let mut vault =
            Vault::create(&dir.path().join("editor.vault"), b"test-only-future-edit").unwrap();
        let mut data = draft();
        EditJournal::new(&mut vault).save(&data, None).unwrap();
        data.text = "x".repeat(MAX_TEXT_BYTES + 1);
        assert!(matches!(
            EditJournal::new(&mut vault).save(&data, Some(1)),
            Err(EditError::Capacity)
        ));
        assert_eq!(
            EditJournal::new(&mut vault).load(ID).unwrap().text,
            draft().text
        );
        let key = keys(ID).unwrap().0;
        let mut meta = data.metadata.clone();
        meta.version = 2;
        let raw = serde_json::to_vec(&meta).unwrap();
        vault.put(&key, &raw).unwrap();
        assert!(
            EditJournal::new(&mut vault)
                .save(&draft(), Some(1))
                .is_err()
        );
        assert!(EditJournal::new(&mut vault).remove(ID).is_err());
        assert_eq!(vault.get(&key).unwrap().unwrap().as_slice(), raw);
    }
}
