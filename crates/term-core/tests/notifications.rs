use hspterm_term_core::{Size, Terminal, notifications, preferences};

#[test]
fn osc_notice_utf8_fragmentation_and_semicolons_do_not_change_terminal_text() {
    let mut t = Terminal::new(Size::new(20, 4).unwrap(), 100).unwrap();
    let mut settings = preferences::Settings::default();
    settings.notifications.preview = true;
    t.set_preferences(&settings).unwrap();
    let bytes = "before\u{1b}]777;notify;中文标题;正文;分号\u{1b}\\after".as_bytes();
    for b in bytes {
        t.feed(&[*b]).unwrap();
    }
    let notices = t.take_notifications();
    assert_eq!(notices.len(), 1);
    assert_eq!(notices[0].title, "中文标题");
    assert_eq!(notices[0].body, "正文;分号");
    assert_eq!(t.snapshot().text().lines().next().unwrap(), "beforeafter");
    t.begin_new_generation();
    t.feed(b"\x1b]9;4;1;25\x07\x1b]777;unknown;title;body\x07")
        .unwrap();
    assert!(t.take_notifications().is_empty());
    t.feed(b"\x1b]9;complete;with;semicolon\x07").unwrap();
    assert_eq!(t.take_notifications()[0].body, "complete;with;semicolon");
}
#[test]
fn opt_in_rules_cross_wire_chunks_and_visual_wraps_but_skip_alt_and_oversized_fragments() {
    let mut t = Terminal::new(Size::new(4, 2).unwrap(), 100).unwrap();
    let mut settings = preferences::Settings::default();
    settings.notifications.preview = true;
    settings.notifications.rules.push(notifications::Rule {
        text: "1234567890".into(),
        regex: false,
        case_sensitive: true,
    });
    t.set_preferences(&settings).unwrap();
    t.feed(b"12").unwrap();
    t.feed(b"3456").unwrap();
    t.feed(b"7890\r\n").unwrap();
    assert_eq!(t.take_notifications()[0].body, "1234567890");
    t.begin_new_generation();
    t.feed(b"\x1b[?1049h1234567890\r\n\x1b[?1049l").unwrap();
    assert!(t.take_notifications().is_empty());
    let mut large = vec![b'x'; 4097];
    large.extend_from_slice(b"1234567890\r\n");
    t.feed(&large).unwrap();
    assert!(t.take_notifications().is_empty());
    t.feed(b"1234567890\n").unwrap();
    assert_eq!(t.take_notifications().len(), 1);
    t.finish_stream();
    assert!(t.notification_deadline().is_none());
}
