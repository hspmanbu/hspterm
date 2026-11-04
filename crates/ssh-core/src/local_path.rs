//! Local file paths are not remote POSIX paths. Never normalize a remote name
//! into a different Windows file, stream or device. Unsupported names fail.
use std::path::Path;

pub(crate) fn windows_component_supported(name: &str) -> bool {
    if name.is_empty()
        || name.ends_with(' ')
        || name.ends_with('.')
        || name.bytes().any(|b| b < 32 || b"<>:\"/\\|?*".contains(&b))
    {
        return false;
    }
    // Device aliases apply before extensions, ignoring case and trailing spaces
    // on the stem. Use Unicode uppercase, including the dotless-i console alias.
    let stem = name
        .split('.')
        .next()
        .unwrap_or_default()
        .trim_end_matches(' ')
        .to_uppercase();
    if matches!(
        stem.as_str(),
        "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
    ) {
        return false;
    }
    if let Some(suffix) = stem
        .strip_prefix("COM")
        .or_else(|| stem.strip_prefix("LPT"))
    {
        let mut chars = suffix.chars();
        if matches!(chars.next(), Some('1'..='9' | '¹' | '²' | '³')) && chars.next().is_none() {
            return false;
        }
    }
    true
}

#[cfg(any(windows, test))]
fn volume_guid_prefix(name: &str) -> bool {
    let bytes = name.as_bytes();
    bytes.len() == 44
        && bytes[..7].eq_ignore_ascii_case(b"Volume{")
        && bytes[43] == b'}'
        && bytes[7..43].iter().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                *b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

#[cfg(any(windows, test))]
fn unc_component_supported(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && !name.bytes().any(|b| b < 32 || b"<>:\"/\\|?*".contains(&b))
}

#[cfg(any(windows, test))]
fn windows_relative_supported(relative: &str) -> bool {
    relative.is_empty() || relative.split('/').all(windows_component_supported)
}

/// Check original POSIX components before joining: Windows would otherwise
/// reinterpret a remote backslash or drive prefix and potentially escape root.
pub fn supported_relative(relative: &str) -> bool {
    #[cfg(windows)]
    {
        windows_relative_supported(relative)
    }
    #[cfg(not(windows))]
    {
        let _ = relative;
        true
    }
}

/// Ordinary disk/UNC/volume file paths only on Windows. This is a pre-I/O
/// syntax guard, not a substitute for opened-handle/symlink checks. POSIX names
/// such as `NUL` and `a:b` remain valid on Unix/Android.
pub fn supported(path: &Path) -> bool {
    #[cfg(windows)]
    {
        use std::path::{Component, Prefix};
        if path.as_os_str().is_empty() {
            return false;
        }
        path.components().all(|part| match part {
            Component::Prefix(prefix) => match prefix.kind() {
                Prefix::Disk(_) | Prefix::VerbatimDisk(_) => true,
                Prefix::UNC(server, share) | Prefix::VerbatimUNC(server, share) => {
                    server.to_str().is_some_and(unc_component_supported)
                        && share.to_str().is_some_and(unc_component_supported)
                }
                Prefix::Verbatim(name) => name.to_str().is_some_and(volume_guid_prefix),
                Prefix::DeviceNS(_) => false,
            },
            Component::Normal(name) => name.to_str().is_some_and(windows_component_supported),
            // These are caller-selected root-path navigation, not remote
            // components: the manifest independently rejects relative traversal.
            Component::RootDir | Component::CurDir | Component::ParentDir => true,
        })
    }
    #[cfg(not(windows))]
    {
        let _ = path;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn windows_names_reject_devices_streams_aliases_and_controls_without_sanitizing() {
        for name in [
            "",
            ".",
            "..",
            "CON",
            "nul.txt",
            "NuL .tar.gz",
            "COM1",
            "lpt9.txt",
            "com¹.txt",
            "LPT²",
            "COM³.log",
            "CONIN$",
            "conın$",
            "CONOUT$.log",
            "file:stream",
            "file::$DATA",
            "a/b",
            r"a\b",
            "a?b",
            "a*b",
            "a|b",
            "a<b",
            "a>b",
            "a\"b",
            "name.",
            "name ",
        ] {
            assert!(
                !windows_component_supported(name),
                "unsafe Windows name accepted: {name:?}"
            );
        }
        for c in 0..32u8 {
            assert!(!windows_component_supported(&format!(
                "before{}after",
                c as char
            )));
        }
        for name in [
            "CONtainer",
            "com0",
            "COM10",
            "LPT0",
            "LPT10",
            "foo.NUL",
            ".config",
            "a..b",
            "中文 é 😀.txt",
            "shell '$; [x]",
            "inside space.txt",
        ] {
            assert!(
                windows_component_supported(name),
                "valid name rejected: {name:?}"
            );
        }
    }
    #[test]
    fn volume_guids_do_not_admit_arbitrary_nt_device_namespaces() {
        assert!(volume_guid_prefix(
            "Volume{01234567-89ab-CDEF-0123-456789abcdef}"
        ));
        assert!(volume_guid_prefix(
            "volume{01234567-89ab-cdef-0123-456789abcdef}"
        ));
        for name in [
            "GLOBALROOT",
            "pipe",
            "PhysicalDrive0",
            "Volume{bad}",
            "Volume{01234567-89ab-cdef-0123-456789abcdeg}",
            "Volume{0123456789ab-cdef-0123-456789abcdef0}",
        ] {
            assert!(!volume_guid_prefix(name));
        }
    }
    #[test]
    fn remote_components_are_checked_before_native_path_interpretation() {
        for relative in [
            "C:outside",
            r"safe\..\outside",
            r"\absolute",
            "safe/NUL.txt",
            "safe/a:b",
            "safe/dir./file",
            "../outside",
            "/absolute",
        ] {
            assert!(!windows_relative_supported(relative));
        }
        for relative in ["", "safe/中文 é.txt", "safe/.config", "normal/COM10.txt"] {
            assert!(windows_relative_supported(relative));
        }
        for part in ["", ".", "..", "share:stream", r"server\path", "bad\0host"] {
            assert!(!unc_component_supported(part));
        }
        for part in ["server.example.com.", "127.0.0.1", "C$", "共享目录", "NUL"] {
            assert!(unc_component_supported(part));
        }
    }
    #[cfg(not(windows))]
    #[test]
    fn posix_paths_are_not_restricted_by_windows_file_naming_rules() {
        for path in [
            "/tmp/NUL",
            "/tmp/a:b",
            "/tmp/file.",
            "/tmp/line\nfile",
            "/tmp/中文 é",
        ] {
            assert!(supported(Path::new(path)));
        }
    }
    #[cfg(windows)]
    #[test]
    fn windows_paths_check_every_component_and_preserve_ordinary_roots() {
        for path in [
            r"C:\目录\file.txt",
            r"\\?\C:\directory\file.txt",
            r"\\server\share\file.txt",
            r"\\?\UNC\server\share\file.txt",
            r"\\?\Volume{01234567-89ab-cdef-0123-456789abcdef}\file.txt",
        ] {
            assert!(supported(Path::new(path)));
        }
        for path in [
            r"C:\safe\NUL.txt",
            r"C:\safe\inner.\file",
            r"C:\safe\data:secret",
            r"\\?\GLOBALROOT\Device\HarddiskVolume1\file",
            r"\\.\PhysicalDrive0",
            r"\\.\pipe\test",
            r"\\?\C:\safe\CONOUT$",
        ] {
            assert!(!supported(Path::new(path)));
        }
    }
}
