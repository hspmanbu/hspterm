import 'support/terminal_cleanup.dart';

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/view.dart';
import 'package:hspterm/terminal/controller.dart';

import 'support/fake_backend.dart';

void main() {
  testWidgets(
    'right paste keeps remote mouse priority and Shift opens the local menu',
    (tester) async {
      final b = FakeBackend();
      final c = TerminalController(b);
      await c.start();
      c.phase = 'Connected';
      c.generation = 1;
      c.rightClickPaste = true;
      c.applyFrame(fixture(mouse: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async => call.method == 'Clipboard.getData'
                ? {'text': 'synthetic single line'}
                : null,
          );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: TerminalView(controller: c)),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> right() async {
          final point =
              tester.getTopLeft(find.byType(TerminalView)) + const Offset(8, 8);
          final gesture = await tester.startGesture(
            point,
            kind: ui.PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pump();
          await gesture.up();
          await tester.pumpAndSettle();
        }

        await right();
        expect(b.mouseActions, isNotEmpty);
        expect(b.pastes, isEmpty);
        c.applyFrame(fixture(mouse: false));
        await tester.pump();
        await right();
        expect(b.pastes, [('synthetic single line', false)]);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await right();
        expect(find.text('复制'), findsOneWidget);
        expect(b.pastes.length, 1);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.tapAt(const Offset(1, 1));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
        await tester.pumpWidget(const SizedBox());
        await closeTerminal(tester, c);
      }
    },
  );

  testWidgets(
    'clipboard data arriving after a reconnect is not pasted into the new generation',
    (tester) async {
      final b = FakeBackend();
      // Each case owns one controller/backend pair, with no native or OS access.
      final actual = TerminalController(b);
      await actual.start();
      actual.phase = 'Connected';
      actual.generation = 1;
      final key = GlobalKey<TerminalViewState>();
      final read = Completer<Map<String, String>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async =>
                call.method == 'Clipboard.getData' ? read.future : null,
          );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalView(key: key, controller: actual),
            ),
          ),
        );
        await tester.pump();
        final pending = key.currentState!.paste();
        await tester.pump();
        actual.generation = 2;
        read.complete({'text': 'synthetic late clipboard'});
        await pending;
        await tester.pump();
        expect(b.pastes, isEmpty);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
        await tester.pumpWidget(const SizedBox());
        await closeTerminal(tester, actual);
      }
    },
  );
  testWidgets(
    'edited preview sends only the confirmed version and its controller outlives the exit animation',
    (tester) async {
      final b = FakeBackend();
      final c = TerminalController(b);
      await c.start();
      c.phase = 'Connected';
      c.generation = 1;
      final key = GlobalKey<TerminalViewState>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async => call.method == 'Clipboard.getData'
                ? {'text': 'original\nline'}
                : null,
          );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalView(key: key, controller: c),
            ),
          ),
        );
        await tester.pump();
        final pending = key.currentState!.paste();
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('terminal-paste-editor')),
          'edited\n中文',
        );
        await tester.tap(find.byKey(const ValueKey('terminal-paste-confirm')));
        await tester.pump();
        await pending;
        await tester.pumpAndSettle();
        expect(b.pastes, [('original\nline', false), ('edited\n中文', true)]);
        expect(tester.takeException(), isNull);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
        await tester.pumpWidget(const SizedBox());
        await closeTerminal(tester, c);
      }
    },
  );
}
