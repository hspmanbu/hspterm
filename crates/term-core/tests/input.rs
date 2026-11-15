use hspterm_term_core::*;
fn term() -> Terminal {
    Terminal::new(Size::new(80, 24).unwrap(), 100).unwrap()
}
fn encoded(t: &Terminal, key: Key, shift: bool, control: bool, alt: bool) -> Vec<u8> {
    let mut event = KeyEvent::press(key);
    event.modifiers = Modifiers {
        shift,
        control,
        alt,
        ..Modifiers::default()
    };
    t.encode_key(&event).unwrap()
}
#[test]
fn legacy_control_function_and_application_cursor_sequences() {
    let mut t = term();
    for (key, expected) in [
        (Key::Enter, b"\r".as_slice()),
        (Key::Tab, b"\t"),
        (Key::Backspace, b"\x7f"),
        (Key::Escape, b"\x1b"),
        (Key::Up, b"\x1b[A"),
        (Key::Home, b"\x1b[H"),
        (Key::PageUp, b"\x1b[5~"),
        (Key::PageDown, b"\x1b[6~"),
        (Key::Function(1), b"\x1bOP"),
        (Key::Function(3), b"\x1bOR"),
        (Key::Function(12), b"\x1b[24~"),
    ] {
        assert_eq!(encoded(&t, key, false, false, false), expected);
    }
    assert_eq!(
        encoded(&t, Key::Character('c'), false, true, false),
        b"\x03"
    );
    assert_eq!(
        encoded(&t, Key::Character('x'), false, false, true),
        b"\x1bx"
    );
    assert_eq!(encoded(&t, Key::Tab, true, false, false), b"\x1b[Z");
    assert_eq!(encoded(&t, Key::Up, true, true, false), b"\x1b[1;6A");
    t.feed(b"\x1b[?1h").unwrap();
    assert_eq!(encoded(&t, Key::Up, false, false, false), b"\x1bOA");
}
#[test]
fn kitty_disambiguates_modifiers_and_resets_after_pop() {
    let mut t = term();
    t.feed(b"\x1b[>1u").unwrap();
    assert_eq!(encoded(&t, Key::Escape, false, false, false), b"\x1b[27u");
    assert_eq!(
        encoded(&t, Key::Character('c'), false, true, false),
        b"\x1b[99;5u"
    );
    assert_eq!(
        encoded(&t, Key::Character('c'), true, true, false),
        b"\x1b[99;6u"
    );
    assert_eq!(encoded(&t, Key::Enter, true, false, false), b"\x1b[13;2u");
    assert_eq!(encoded(&t, Key::Tab, true, false, false), b"\x1b[9;2u");
    assert_eq!(encoded(&t, Key::Enter, false, false, false), b"\r");
    assert_eq!(
        encoded(&t, Key::Function(3), false, false, false),
        b"\x1b[13~"
    );
    t.feed(b"\x1b[<u").unwrap();
    assert_eq!(
        encoded(&t, Key::Character('c'), false, true, false),
        b"\x03"
    );
}
#[test]
fn kitty_all_events_alternatives_and_associated_unicode_text() {
    let mut t = term();
    t.feed(b"\x1b[>31u").unwrap();
    let mut event = KeyEvent::press(Key::Character('a'));
    event.modifiers.shift = true;
    event.shifted_key = Some('A');
    event.base_key = Some('a');
    event.text = Some("中e\u{301}".into());
    assert_eq!(
        t.encode_key(&event).unwrap(),
        b"\x1b[97:65:97;2;20013:101:769u"
    );
    event.kind = KeyKind::Repeat;
    assert_eq!(
        t.encode_key(&event).unwrap(),
        b"\x1b[97:65:97;2:2;20013:101:769u"
    );
    event.kind = KeyKind::Release;
    assert_eq!(t.encode_key(&event).unwrap(), b"\x1b[97:65:97;2:3u");
    let mut enter = KeyEvent::press(Key::Enter);
    enter.kind = KeyKind::Release;
    assert_eq!(t.encode_key(&enter).unwrap(), b"\x1b[13;1:3u");
    t.feed(b"\x1b[<u").unwrap();
    assert!(t.encode_key(&enter).unwrap().is_empty());
    assert!(t.encode_key(&KeyEvent::press(Key::Function(0))).is_err());
}
#[test]
fn sgr_mouse_release_drag_and_local_selection_fallback() {
    let mut t = term();
    let event = MouseEvent {
        column: 3,
        row: 5,
        action: MouseAction::Press(MouseButton::Left),
        modifiers: Modifiers::default(),
    };
    assert!(t.encode_mouse(event).is_empty());
    t.feed(b"\x1b[?1000h\x1b[?1006h").unwrap();
    assert_eq!(t.encode_mouse(event), b"\x1b[<0;4;6M");
    assert_eq!(
        t.encode_mouse(MouseEvent {
            action: MouseAction::Release(MouseButton::Left),
            ..event
        }),
        b"\x1b[<0;4;6m"
    );
    assert!(
        t.encode_mouse(MouseEvent {
            action: MouseAction::Motion(Some(MouseButton::Left)),
            ..event
        })
        .is_empty()
    );
    t.feed(b"\x1b[?1002h").unwrap();
    assert_eq!(
        t.encode_mouse(MouseEvent {
            action: MouseAction::Motion(Some(MouseButton::Left)),
            ..event
        }),
        b"\x1b[<32;4;6M"
    );
    assert!(
        t.encode_mouse(MouseEvent {
            action: MouseAction::Motion(None),
            ..event
        })
        .is_empty()
    );
    assert!(
        t.encode_mouse(MouseEvent {
            column: 80,
            ..event
        })
        .is_empty()
    );
}
#[test]
fn paste_requires_preview_and_wraps_confirmed_content_exactly_once() {
    let mut t = term();
    let text = "first\r\nsecond\n";
    assert!(matches!(
        t.prepare_paste(text, false).unwrap(),
        PastePlan::Confirm {
            lines: 3,
            bracketed: false,
            ..
        }
    ));
    match t.prepare_paste(text, true).unwrap() {
        PastePlan::Ready(bytes) => assert_eq!(bytes, b"first\rsecond\r"),
        _ => panic!("confirmed paste must be ready"),
    }
    t.feed(b"\x1b[?2004h").unwrap();
    assert!(matches!(
        t.prepare_paste(text, false).unwrap(),
        PastePlan::Confirm {
            bracketed: true,
            ..
        }
    ));
    match t.prepare_paste(text, true).unwrap() {
        PastePlan::Ready(bytes) => assert_eq!(bytes, b"\x1b[200~first\nsecond\n\x1b[201~"),
        _ => panic!("confirmed paste must be ready"),
    }
    assert!(matches!(
        t.prepare_paste("payload\x1b[201~", true),
        Err(InputError::PasteDelimiter)
    ));
    assert!(matches!(
        t.prepare_paste(&"a".repeat(4096), false).unwrap(),
        PastePlan::Confirm { .. }
    ));
}

#[test]
fn committed_ime_text_respects_negotiated_kitty_mode() {
    let mut t = term();
    assert_eq!(t.encode_text("中文é").unwrap(), "中文é".as_bytes());
    t.feed(b"\x1b[>8u").unwrap();
    assert_eq!(t.encode_text("中").unwrap(), b"\x1b[20013u");
}

#[test]
fn kitty_modifier_and_lock_keys_are_silent_unless_all_keys_negotiated() {
    let mut t = term();
    let shift = KeyEvent::press(Key::Functional(57441));
    let lock = KeyEvent::press(Key::Functional(57358));
    assert!(t.encode_key(&shift).unwrap().is_empty());
    assert!(t.encode_key(&lock).unwrap().is_empty());
    t.feed(b"\x1b[>8u").unwrap();
    assert_eq!(t.encode_key(&shift).unwrap(), b"\x1b[57441u");
    assert_eq!(t.encode_key(&lock).unwrap(), b"\x1b[57358u");
}

#[test]
fn modify_other_keys_levels_queries_reset_and_kitty_priority() {
    use alacritty_terminal::event::Event;
    let mut t = term();
    t.feed(b"\x1b[>4;1m\x1b[?4m").unwrap();
    assert!(
        t.take_events()
            .iter()
            .any(|e| matches!(e, Event::PtyWrite(s) if s == "\x1b[>4;1m"))
    );
    assert_eq!(
        encoded(&t, Key::Character('c'), false, true, false),
        b"\x03"
    );
    assert_eq!(encoded(&t, Key::Tab, true, false, false), b"\x1b[27;2;9~");
    assert_eq!(encoded(&t, Key::Tab, false, false, true), b"\x1b[27;3;9~");
    t.feed(b"\x1b[>4;2m").unwrap();
    assert_eq!(
        encoded(&t, Key::Character('c'), false, true, false),
        b"\x1b[27;5;99~"
    );
    assert_eq!(
        encoded(&t, Key::Enter, true, false, false),
        b"\x1b[27;2;13~"
    );
    assert_eq!(encoded(&t, Key::Up, false, false, false), b"\x1b[A");
    assert_eq!(t.encode_text("中文").unwrap(), "中文".as_bytes());
    t.feed(b"\x1b[>1u").unwrap();
    assert_eq!(
        encoded(&t, Key::Character('c'), false, true, false),
        b"\x1b[99;5u"
    );
    t.feed(b"\x1b[<u\x1b[>4n\x1b[?4m").unwrap();
    assert_eq!(
        encoded(&t, Key::Character('c'), false, true, false),
        b"\x03"
    );
    assert!(
        t.take_events()
            .iter()
            .any(|e| matches!(e, Event::PtyWrite(s) if s == "\x1b[>4;0m"))
    );
    t.feed(b"\x1b[>4;2m").unwrap();
    t.begin_new_generation();
    assert_eq!(
        encoded(&t, Key::Character('c'), false, true, false),
        b"\x03"
    );
    // An untrusted peer cannot panic the process by overflowing the Kitty stack.
    for _ in 0..1000 {
        t.feed(b"\x1b[>1u").unwrap();
    }
    t.feed(b"\x1b[<1000u").unwrap();
    assert_eq!(
        encoded(&t, Key::Character('c'), false, true, false),
        b"\x03"
    );
}

#[test]
fn paste_preserves_empty_lines_without_doubling_windows_line_endings() {
    let mut t = term();
    for bracketed in [false, true] {
        if bracketed {
            t.feed(b"\x1b[?2004h").unwrap();
        }
        for source in [
            "one\r\ntwo\r\n\r\nthree",
            "one\ntwo\n\nthree",
            "one\rtwo\r\rthree",
        ] {
            let PastePlan::Ready(bytes) = t.prepare_paste(source, true).unwrap() else {
                panic!("ready")
            };
            let expected = if bracketed {
                b"\x1b[200~one\ntwo\n\nthree\x1b[201~".as_slice()
            } else {
                b"one\rtwo\r\rthree".as_slice()
            };
            assert_eq!(bytes, expected);
        }
    }
}
