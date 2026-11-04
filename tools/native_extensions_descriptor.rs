// HSPTerm patch for super_native_extensions 0.9.1. Directory identity and
// file size are explicit metadata, never inferred from a trailing slash.
fn file_descriptor_for_item(
    file_name: &str,
    metadata: Option<(bool, u64)>,
) -> Option<FILEDESCRIPTORW> {
    let name: Vec<_> = file_name.encode_utf16().collect();
    if name.is_empty() || name.len() >= 260 || file_name.contains('\0') {
        return None;
    }
    for component in file_name.split('\\') {
        if component.is_empty()
            || component == "."
            || component == ".."
            || component.ends_with(' ')
            || component.ends_with('.')
            || component.encode_utf16().count() > 255
            || component
                .chars()
                .any(|c| c < ' ' || c == '\u{7f}' || "<>:\"/|?*".contains(c))
        {
            return None;
        }
        let stem = component
            .split('.')
            .next()?
            .trim_end_matches(' ')
            .to_uppercase();
        if matches!(
            stem.as_str(),
            "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
        ) {
            return None;
        }
        if let Some(suffix) = stem
            .strip_prefix("COM")
            .or_else(|| stem.strip_prefix("LPT"))
        {
            let mut chars = suffix.chars();
            if matches!(chars.next(), Some('1'..='9' | '¹' | '²' | '³')) && chars.next().is_none()
            {
                return None;
            }
        }
    }
    let mut name_buf = [0u16; 260];
    name_buf[..name.len()].copy_from_slice(&name);
    let (directory, bytes) = metadata.unwrap_or((false, 0));
    let mut descriptor = FILEDESCRIPTORW {
        dwFlags: (FD_ATTRIBUTES.0 | FD_PROGRESSUI.0) as u32,
        dwFileAttributes: if directory {
            FILE_ATTRIBUTE_DIRECTORY.0
        } else {
            FILE_ATTRIBUTE_NORMAL.0
        },
        cFileName: name_buf,
        ..FILEDESCRIPTORW::default()
    };
    if metadata.is_some() && !directory {
        descriptor.dwFlags |= FD_FILESIZE.0 as u32;
        descriptor.nFileSizeHigh = (bytes >> 32) as u32;
        descriptor.nFileSizeLow = bytes as u32;
    }
    Some(descriptor)
}

fn data_for_file_group_descritor(&self) -> Option<Vec<u8>> {
    let mut descriptors = Vec::<FILEDESCRIPTORW>::new();
    let mut names = std::collections::HashSet::new();
    for provider in &self.providers {
        let data = &provider.provider.data;
        if data.representations.iter().any(|a| a.is_virtual_file()) {
            if descriptors.len() >= 32_768 {
                return None;
            }
            let mut metadata = None;
            for representation in &data.representations {
                if let DataRepresentation::Simple { format, data } = representation {
                    if format == "HSPTerm.VirtualDescriptor.v1" {
                        if metadata.is_some() {
                            return None;
                        }
                        let value = data.coerce_to_data(StringFormat::Utf16NullTerminated)?;
                        if value.len() != 10 || value[0] != 1 || value[1] > 1 {
                            return None;
                        }
                        let mut size = [0u8; 8];
                        size.copy_from_slice(&value[2..10]);
                        let bytes = u64::from_le_bytes(size);
                        if value[1] == 1 && bytes != 0 {
                            return None;
                        }
                        metadata = Some((value[1] == 1, bytes));
                    }
                }
            }
            let name = data
                .suggested_name
                .clone()
                .unwrap_or_else(|| format!("File {}", descriptors.len() + 1));
            if !names.insert(name.to_uppercase()) {
                return None;
            }
            descriptors.push(Self::file_descriptor_for_item(&name, metadata)?);
        }
    }
    if descriptors.is_empty() {
        return None;
    }
    let mut result = Vec::new();
    let count = descriptors.len() as u32;
    result.extend_from_slice(unsafe { as_u8_slice(&count) });
    for descriptor in &descriptors {
        result.extend_from_slice(unsafe { as_u8_slice(descriptor) });
    }
    Some(result)
}

// HSPTERM_OUTSIDE_IMPL
#[cfg(test)]
mod hspterm_descriptor_tests {
    use super::*;

    #[test]
    fn directories_and_empty_files_have_distinct_explicit_attributes() {
        let directory =
            DataObject::file_descriptor_for_item("root\\空目录", Some((true, 0))).unwrap();
        assert_eq!(directory.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY.0);
        assert_eq!(directory.dwFlags & FD_FILESIZE.0 as u32, 0);
        let empty = DataObject::file_descriptor_for_item("root\\empty", Some((false, 0))).unwrap();
        assert_eq!(empty.dwFileAttributes, FILE_ATTRIBUTE_NORMAL.0);
        assert_ne!(empty.dwFlags & FD_FILESIZE.0 as u32, 0);
        assert_eq!((empty.nFileSizeHigh, empty.nFileSizeLow), (0, 0));
        let large =
            DataObject::file_descriptor_for_item("root\\large", Some((false, (7 << 32) + 19)))
                .unwrap();
        assert_eq!((large.nFileSizeHigh, large.nFileSizeLow), (7, 19));
    }

    #[test]
    fn never_truncates_a_name_or_splits_a_surrogate_pair() {
        let exact = format!("root\\{}", "😀".repeat(127));
        let descriptor = DataObject::file_descriptor_for_item(&exact, Some((false, 0))).unwrap();
        assert_eq!(
            String::from_utf16(&descriptor.cFileName[..259]).unwrap(),
            exact
        );
        assert_eq!(descriptor.cFileName[259], 0);
        assert!(DataObject::file_descriptor_for_item(&(exact + "x"), None).is_none());
        for name in [
            "CONIN$", "conın$", "a:b", "a\\..\\b", "\\root", "root\\", "a\0b", "NUL .txt",
        ] {
            assert!(DataObject::file_descriptor_for_item(name, None).is_none());
        }
    }
}
