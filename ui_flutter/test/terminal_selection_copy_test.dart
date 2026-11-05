import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/view.dart';

import 'support/fake_backend.dart';

Future<Map<String, Object?>> captureClipboard(
  WidgetTester tester,
  Future<void> Function() action,
) async {
  final writes = <Map<String, Object?>>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      writes.add(Map<String, Object?>.from(call.arguments as Map));
    }
    return null;
  });
  try {
    await action();
    await tester.pumpAndSettle();
  } finally {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  }
  return writes.isEmpty ? <String, Object?>{} : writes.first;
}

void main() {
  testWidgets(
    'mouse selection copies real text but never an all-whitespace selection',
    (tester) async {
      final b = FakeBackend();
      final c = TerminalController(b);
      await c.start();
      c.phase = 'Connected';
      c.generation = 1;
      c.copyOnSelection = true;
      c.applyFrame(fixture(line: 'hello-world'));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TerminalView(controller: c))),
      );
      await tester.pumpAndSettle();
      // The two-row fixture grid sits at the very top of the view; drag in
      // absolute coordinates across the first row.
      Future<void> drag(double x1, double x2) async {
        final gesture = await tester.startGesture(
          Offset(x1, 6),
          kind: ui.PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton,
        );
        await tester.pump();
        await gesture.moveTo(Offset(x2, 6));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      final first = await captureClipboard(tester, () => drag(4, 52));
      expect(first['text'] as String, isNotEmpty);
      expect((first['text'] as String).trim(), isNotEmpty);
      // A selection consisting only of whitespace must not touch the
      // clipboard at all.
      c.applyFrame(fixture(line: '     ', revision: 2));
      await tester.pump();
      c.clearSelection();
      final blank = await captureClipboard(tester, () => drag(4, 40));
      expect(blank, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'IME composing rect is anchored one line below the caret rect',
    (tester) async {
      final b = FakeBackend();
      final c = TerminalController(b);
      await c.start();
      c.phase = 'Connected';
      c.generation = 1;
      c.applyFrame(fixture(line: 'input', cursorRow: 1));
      final imeMessages = <List<Object?>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.textInput, (call) {
        imeMessages.add([call.method, call.arguments]);
        return null;
      });
      try {
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TerminalView(controller: c))),
        );
        await tester.pumpAndSettle();
        // Focusing the view attaches the text input client; the frame update
        // then reports the caret and composing geometry.
        final point = tester.getTopLeft(find.byType(TerminalView));
        await tester.tapAt(point + const Offset(8, 8));
        await tester.pumpAndSettle();
        c.applyFrame(fixture(line: 'input', cursorRow: 1, revision: 2));
        await tester.pumpAndSettle();
        Rect? caret, composing;
        for (final message in imeMessages) {
          if (message[0] == 'TextInput.setCaretRect') {
            final args = message[1]! as Map;
            caret = Rect.fromLTWH(
              (args['x'] as num).toDouble(),
              (args['y'] as num).toDouble(),
              (args['width'] as num).toDouble(),
              (args['height'] as num).toDouble(),
            );
          }
          if (message[0] == 'TextInput.setMarkedTextRect') {
            final args = message[1]! as Map;
            composing = Rect.fromLTWH(
              (args['x'] as num).toDouble(),
              (args['y'] as num).toDouble(),
              (args['width'] as num).toDouble(),
              (args['height'] as num).toDouble(),
            );
          }
        }
        expect(caret, isNotNull);
        expect(composing, isNotNull);
        // The candidate window follows the line under the cursor: same
        // column, exactly one cell height lower.
        expect(composing!.left, caret!.left);
        expect(composing.width, caret.width);
        expect(composing.top, caret.bottom);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      } finally {
        messenger.setMockMethodCallHandler(SystemChannels.textInput, null);
      }
    },
  );
}
