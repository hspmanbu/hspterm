import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/view.dart';
import 'package:hspterm/src/rust/api.dart' as rust;

import 'support/fake_backend.dart';
import 'support/terminal_cleanup.dart';

void main() {
  testWidgets(
    'tmux local drag owns press move release even with mouse capture',
    (tester) async {
      final backend = FakeBackend();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      c.tmuxReadonly = false;
      c.applyFrame(fixture(line: 'hello-world', mouse: true));
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: TerminalView(controller: c)),
          ),
        );
        await tester.pumpAndSettle();
        final drag = await tester.startGesture(
          const Offset(4, 6),
          kind: ui.PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton,
        );
        await drag.moveTo(const Offset(50, 6));
        await tester.pump();
        await drag.up();
        await tester.pump();
        expect(c.selectedText(), isNotEmpty);
        expect(backend.mouseActions, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await closeTerminal(tester, c);
      }
    },
  );
  test('newline compatibility is explicit, per tmux tab and consumes matching release', () async {
    final backend = FakeBackend();
    final c = TerminalController(backend);
    await c.start();
    c.phase = 'Connected';
    c.tmuxReadonly = false;
    const press = rust.KeyboardInput(key: 'Enter', modifiers: 1, kind: 0);
    try {
      await c.key(press);
      expect(backend.keys, [press]);
      expect(backend.texts, isEmpty);
      c.setTmuxShiftEnterLf(true);
      await c.key(press);
      await c.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 1, kind: 2),
      );
      expect(backend.texts, ['\n']);
      expect(backend.keys, [press]);
      c.tmuxReadonly = null;
      await c.key(press);
      expect(backend.keys, [press, press]);
    } finally {
      await c.shutdown();
      c.dispose();
    }
  });
}
