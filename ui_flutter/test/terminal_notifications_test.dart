import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/notifications.dart';
import 'package:hspterm/workbench/notification_settings.dart';
import 'package:hspterm/workbench/terminal_notifications.dart';
import 'package:hspterm/workbench/terminal_preferences.dart';

import 'support/fake_backend.dart';

RemoteTerminalNotice notice({
  String policy = '1',
  bool foreground = false,
  bool background = true,
  bool desktop = false,
}) => RemoteTerminalNotice(
  policy: policy,
  kind: 'osc',
  title: '',
  body: '',
  foreground: foreground,
  background: background,
  desktop: desktop,
);

class _Desktop implements TerminalDesktopNotices {
  final attempted = <String>[], delivered = <String>[];
  Completer<void>? pending;
  void Function(String)? activate;
  bool disposed = false;
  @override
  bool get supported => true;
  @override
  Future<void> show(
    RemoteTerminalNotice notice,
    String payload,
    void Function(String) callback,
    bool Function() current,
  ) async {
    attempted.add(payload);
    activate = callback;
    await pending?.future;
    if (current()) delivered.add(payload);
  }

  @override
  void dispose() {
    disposed = true;
  }
}

Future<void> policy(FakeBackend b, String value, {int generation = 7}) async {
  b.events.add(
    rust.BridgeEvent(
      kind: 'notificationPolicy',
      generation: generation,
      requestId: 0,
      text: value,
    ),
  );
  await Future<void>.delayed(Duration.zero);
}

const unfocused = ViewFocusEvent(
  viewId: 0,
  state: ViewFocusState.unfocused,
  direction: ViewFocusDirection.undefined,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('strict notice parsing redacts malformed source; legacy preferences retain safe notification defaults', () {
    expect(
      () => RemoteTerminalNotice.decode('synthetic-secret-must-not-appear'),
      throwsA(predicate((e) => !'$e'.contains('synthetic-secret'))),
    );
    final v = {
      'policy': '1',
      'kind': 'osc',
      'title': '中文',
      'body': 'plain output',
      'foreground': false,
      'background': true,
      'desktop': true,
    };
    expect(RemoteTerminalNotice.decode(jsonEncode(v)).body, 'plain output');
    expect(
      () =>
          RemoteTerminalNotice.decode(jsonEncode({...v, 'body': '\u001b[31m'})),
      throwsFormatException,
    );
    expect(const TerminalNotificationSettings().preview, false);
    expect(const TerminalNotificationSettings().desktop, false);
    expect(
      () => TerminalNotificationSettings.parse({
        ...const TerminalNotificationSettings().toJson(),
        'quiet_seconds': 4,
      }),
      throwsFormatException,
    );
    final original = TerminalPreferencesValue(
      historyLines: 10,
      shape: 'block',
      blink: false,
      osc52: true,
      rightPaste: false,
      foreground: 0,
      background: 0,
      cursor: 0,
      ansi: List.filled(16, 0),
    ).toJson()..remove('notifications');
    expect(
      TerminalPreferencesValue.parse(original).notifications.rules,
      isEmpty,
    );
  });
  test('controller accepts only original generation and policy without pulling frames or sending input', () async {
    final b = FakeBackend();
    // The active backend must be the same stream that supplies the policy.
    final target = TerminalController(b);
    await target.start();
    target.generation = 7;
    target.phase = 'Connected';
    var changes = 0, frames = 0;
    target.notices.addListener(() => changes++);
    target.addListener(() => frames++);
    try {
      await policy(b, '2');
      String payload(String p) => jsonEncode({
        'policy': p,
        'kind': 'bell',
        'title': '',
        'body': '',
        'foreground': true,
        'background': true,
        'desktop': false,
      });
      b.events.add(
        rust.BridgeEvent(
          kind: 'notification',
          generation: 6,
          requestId: 0,
          text: payload('2'),
        ),
      );
      b.events.add(
        rust.BridgeEvent(
          kind: 'notification',
          generation: 7,
          requestId: 0,
          text: payload('1'),
        ),
      );
      b.events.add(
        rust.BridgeEvent(
          kind: 'notification',
          generation: 7,
          requestId: 0,
          text: payload('2'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);
      expect(frames, 0);
      expect(b.frames, 0);
      expect(b.keys, isEmpty);
      expect(b.texts, isEmpty);
    } finally {
      await target.shutdown();
      target.dispose();
    }
  });
  test('focus policy, hidden sessions and stable activation never create or duplicate an SSH session', () async {
    final b = FakeBackend();
    final target = TerminalController(b);
    await target.start();
    target.generation = 7;
    target.phase = 'Connected';
    await policy(b, '1');
    var focused = true, activated = 0, messages = 0;
    var now = Duration.zero;
    final identity = Object(), desktop = _Desktop();
    final hub = TerminalNoticeHub(
      inline: (_, _) => messages++,
      desktop: desktop,
      elapsed: () => now,
    );
    final subject = TerminalNoticeSubject(
      identity,
      target,
      () => focused,
      () => activated++,
    );
    try {
      hub.reconcile([subject]);
      target.notices.value = notice();
      expect(messages, 0);
      focused = false;
      target.notices.value = notice(desktop: true);
      expect(messages, 1);
      expect(
        desktop.attempted,
        isEmpty,
        reason: 'visible app uses local notice even for a background tab',
      );
      now += const Duration(seconds: 2);
      hub.didChangeViewFocus(unfocused);
      target.notices.value = notice(desktop: true);
      await Future<void>.delayed(Duration.zero);
      expect(desktop.delivered, hasLength(1));
      desktop.activate!(desktop.delivered.single);
      expect(activated, 1);
      hub.reconcile([]);
      desktop.activate!(desktop.delivered.single);
      expect(activated, 1);
      expect(b.connects, 0);
      expect(b.frames, 0);
    } finally {
      await hub.dispose();
      await target.shutdown();
      target.dispose();
    }
  });
  test('retired notification policy suppresses delayed OS delivery and shutdown awaits the actual delivery worker', () async {
    final b = FakeBackend();
    final c = TerminalController(b);
    await c.start();
    c.generation = 7;
    c.phase = 'Connected';
    await policy(b, '1');
    final desktop = _Desktop()..pending = Completer<void>();
    final hub = TerminalNoticeHub(inline: (_, _) {}, desktop: desktop);
    hub.reconcile([TerminalNoticeSubject(Object(), c, () => true, () {})]);
    hub.didChangeViewFocus(unfocused);
    try {
      c.notices.value = notice(desktop: true);
      expect(desktop.attempted, hasLength(1));
      await policy(b, '2');
      var ended = false;
      final shutdown = hub.shutdown().then((_) => ended = true);
      await Future<void>.delayed(Duration.zero);
      expect(ended, false);
      desktop.pending!.complete();
      await shutdown;
      expect(desktop.delivered, isEmpty);
      hub.resume();
      expect(c.connected, true);
    } finally {
      await hub.dispose();
      await c.shutdown();
      c.dispose();
    }
  });
  testWidgets(
    'notification settings remain a draft, preserve regex/case, and respect explicit source reload',
    (tester) async {
      final key = GlobalKey<TerminalNotificationEditorState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TerminalNotificationEditor(
                key: key,
                source: const TerminalNotificationSettings(),
                revision: 'r1',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final preview = find.byKey(const ValueKey('terminal-notify-preview'));
      await tester.ensureVisible(preview);
      await tester.tap(preview);
      await tester.pumpAndSettle();
      expect(key.currentState!.read().preview, true);
      await tester.enterText(
        find.byKey(const ValueKey('terminal-notify-quiet')),
        '1',
      );
      expect(() => key.currentState!.read(), throwsFormatException);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TerminalNotificationEditor(
                key: key,
                source: const TerminalNotificationSettings(
                  quietSeconds: 15,
                  rules: [
                    TerminalNotificationRule(
                      'ERROR.*',
                      regex: true,
                      caseSensitive: false,
                    ),
                  ],
                ),
                revision: 'r2',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final restored = key.currentState!.read();
      expect(restored.preview, false);
      expect(restored.quietSeconds, 15);
      expect(restored.rules.single.regex, true);
      expect(restored.rules.single.caseSensitive, false);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
