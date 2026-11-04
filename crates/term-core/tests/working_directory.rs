use hspterm_term_core::{
    RemotePathError, Size, Terminal, WorkingDirectory, resolve_remote_reference,
};

#[test]
fn remote_file_uris_decode_once_in_the_original_server_namespace_without_cwd() {
    for (uri, host, expected) in [
        (
            "file:///tmp/a%20b/%E4%B8%AD%20e%CC%81",
            "example.test",
            "/tmp/a b/中 é",
        ),
        (
            "FILE://EXAMPLE.test./a/../b%252Fname;tail",
            "example.test",
            "/a/../b%2Fname;tail",
        ),
        (
            "file://[2001:db8::1]/a%23b%3Fc%27d",
            "2001:db8::1",
            "/a#b?c'd",
        ),
        (
            "file:///C:/Users/fixture",
            "example.test",
            "/C:/Users/fixture",
        ),
    ] {
        assert_eq!(resolve_remote_reference(uri, None, host).unwrap(), expected);
    }
    assert_eq!(
        resolve_remote_reference("/literal%20name", None, "example.test").unwrap(),
        "/literal%20name"
    );
    assert!(matches!(
        resolve_remote_reference("relative", None, "example.test"),
        Err(RemotePathError::UnknownDirectory)
    ));
    assert!(matches!(
        resolve_remote_reference("file://other.test/a", None, "example.test"),
        Err(RemotePathError::ForeignAuthority)
    ));
}

#[test]
fn malformed_or_control_bearing_file_links_are_rejected_before_any_file_access() {
    for uri in [
        "file://user@host/a",
        "file://host:22/a",
        "file:///a?query",
        "file:///a#fragment",
        "file:///a%00b",
        "file:///a%0ab",
        "file:///a%C2%85b",
        "file:///a%E2%80%AEb",
        "file:///a%D8%9Cb",
        "file:///a%FFb",
        "file:///a%2",
        "file://[broken/a",
    ] {
        assert!(resolve_remote_reference(uri, None, "host").is_err());
    }
}

fn terminal() -> Terminal {
    Terminal::new(Size::new(40, 4).unwrap(), 100).unwrap()
}

#[test]
fn directory_context_changes_only_when_metadata_changes_and_needs_no_grid_snapshot() {
    let mut t = terminal();
    assert_eq!(t.directory_context(), (0, None));
    t.feed(b"\x1b]7;file:///one\x07").unwrap();
    let (revision, directory) = t.directory_context();
    assert_eq!(revision, 1);
    assert_eq!(directory.unwrap().path, "/one");
    t.feed(b"ordinary output\x1b]7;file:///one\x07").unwrap();
    assert_eq!(t.directory_context().0, revision);
    t.feed(b"\x1b]7;file:///two\x07\x1b]7;file:///three\x07")
        .unwrap();
    assert_eq!(t.directory_context().1.unwrap().path, "/three");
    let revision = t.directory_context().0;
    t.finish_stream();
    assert_eq!(t.directory_context(), (revision + 1, None));
    t.finish_stream();
    assert_eq!(t.directory_context(), (revision + 1, None));
}

#[test]
fn osc7_is_passive_chunk_independent_and_never_enters_text() {
    let bytes =
        "before\x1b]7;file://example.test/home/a%20b/%E4%B8%AD%E6%96%87;semi\x1b\\after".as_bytes();
    for split in 0..=bytes.len() {
        let mut t = terminal();
        t.feed(&bytes[..split]).unwrap();
        t.feed(&bytes[split..]).unwrap();
        let cwd = t.working_directory().unwrap();
        assert_eq!(cwd.authority, "example.test");
        assert_eq!(cwd.path, "/home/a b/中文;semi");
        assert_eq!(t.snapshot().text().trim(), "beforeafter");
        assert!(t.take_events().is_empty());
    }
}

#[test]
fn invalid_reports_remove_old_context_without_guessing() {
    for bad in [
        "",
        "https://example.test/a",
        "file://user@example.test/a",
        "file://example.test:22/a",
        "file://example.test/a?query",
        "file://example.test/a#fragment",
        "file://example.test/%00",
        "file://example.test/%0a",
        "file://example.test/%1b",
        "file://example.test/%ff",
        "file://example.test/%2",
        "file://example.test/%zz",
        "file://example.test",
    ] {
        let mut t = terminal();
        t.feed(b"\x1b]7;file://example.test/good\x07").unwrap();
        assert!(t.working_directory().is_some());
        t.feed(format!("\x1b]7;{bad}\x07").as_bytes()).unwrap();
        assert!(t.working_directory().is_none(), "{bad}");
    }
    let mut t = terminal();
    t.feed(b"\x1b]7;file:///good\x07").unwrap();
    t.feed(format!("\x1b]7;file:///{}\x07", "x".repeat(16385)).as_bytes())
        .unwrap();
    assert!(t.working_directory().is_none());
}

#[test]
fn context_is_invalidated_on_alt_reset_stream_end_and_new_pty() {
    for transition in [b"\x1b[?1049h".as_slice(), b"\x1bc"] {
        let mut t = terminal();
        t.feed(b"\x1b]7;file:///good\x07").unwrap();
        t.feed(transition).unwrap();
        assert!(t.working_directory().is_none());
    }
    let mut t = terminal();
    t.feed(b"\x1b[?1049h\x1b]7;file:///inner\x07\x1b[?1049l")
        .unwrap();
    assert!(t.working_directory().is_none());
    t.feed(b"\x1b]7;file:///good\x07").unwrap();
    t.finish_stream();
    assert!(t.working_directory().is_none());
    t.feed(b"\x1b]7;file:///next\x07").unwrap();
    t.begin_new_generation();
    assert!(t.working_directory().is_none());
}

#[test]
fn path_resolution_checks_authority_and_preserves_posix_symlink_semantics() {
    let cwd = WorkingDirectory::parse("file://EXAMPLE.test/home/link/a%2520b").unwrap();
    assert_eq!(
        cwd.resolve("../中文 #.rs", "example.test").unwrap(),
        "/home/link/a%20b/../中文 #.rs"
    );
    assert!(cwd.resolve("relative", "different.test").is_err());
    assert_eq!(
        cwd.resolve("/absolute '$;file", "different.test").unwrap(),
        "/absolute '$;file"
    );
    for bad in ["", "line\nnext", "\0", "relative\r", "\x1b[31m/a"] {
        assert!(cwd.resolve(bad, "example.test").is_err());
    }
    let ipv6 = WorkingDirectory::parse("file://[::1]/tmp").unwrap();
    assert_eq!(ipv6.resolve("x", "::1").unwrap(), "/tmp/x");
    let empty = WorkingDirectory::parse("file:///tmp").unwrap();
    assert_eq!(empty.resolve("x", "example.test").unwrap(), "/tmp/x");
}

#[test]
fn synchronized_output_updates_cwd_only_when_committed() {
    let mut t = terminal();
    t.feed(b"\x1b[?2026h\x1b]7;file:///delayed\x07").unwrap();
    assert!(t.working_directory().is_none());
    t.feed(b"\x1b[?2026l").unwrap();
    assert_eq!(t.working_directory().unwrap().path, "/delayed");
    t.feed(b"\x1b[?2026h\x1b]7;file:///old-pty\x07").unwrap();
    t.begin_new_generation();
    assert!(t.snapshot().working_directory.is_none());
}

#[test]
fn aborted_osc7_and_incomplete_string_terminator_are_not_a_cwd_report() {
    for suffix in [b"\x18".as_slice(), b"\x1a", b"\x1b[31m"] {
        let mut t = terminal();
        t.feed(b"\x1b]7;file:///old\x07").unwrap();
        t.feed(b"\x1b]7;file:///cancelled").unwrap();
        t.feed(suffix).unwrap();
        assert!(t.working_directory().is_none());
    }
    let mut t = terminal();
    t.feed(b"\x1b]7;file:///pending\x1b").unwrap();
    assert!(t.working_directory().is_none());
    t.feed(b"\\").unwrap();
    assert_eq!(t.working_directory().unwrap().path, "/pending");
}

#[test]
fn discarded_or_truncated_osc_cannot_leave_a_stale_cwd() {
    {
        let report = format!("\x1b]7;file:///{}\x07", "s".repeat(14 * 1024 * 1024 + 1));
        let mut t = terminal();
        t.feed(b"\x1b]7;file:///old\x07").unwrap();
        t.feed(report.as_bytes()).unwrap();
        assert!(t.working_directory().is_none());
        t.feed(b"\x1b]7;file:///recovered\x07ok").unwrap();
        assert_eq!(t.working_directory().unwrap().path, "/recovered");
        assert_eq!(t.snapshot().text().trim(), "ok");
    }
    assert_eq!(
        format!("{:?}", WorkingDirectory::parse("file:///secret").unwrap()),
        "WorkingDirectory(<redacted>)"
    );
    let mut t = terminal();
    let path = format!("/{}", "s;".repeat(50));
    t.feed(format!("\x1b]7;file://{path}\x07").as_bytes())
        .unwrap();
    assert_eq!(t.working_directory().unwrap().path, path);
}
