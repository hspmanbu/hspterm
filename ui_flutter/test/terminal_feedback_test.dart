import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/view.dart';

import 'support/fake_backend.dart';

void main() {
  testWidgets(
    'Ctrl wheel zoom is session-owned, consumes TUI wheel and survives view recreation',
    (tester) async {
      final backend = FakeBackend();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      c.applyFrame(fixture(mouse: true));
      Future<void> mount() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TerminalView(controller: c)),
        ),
      );
      await mount();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(TerminalView)),
          scrollDelta: const Offset(0, -120),
        ),
      );
      await tester.pump();
      expect(c.fontZoom, 1);
      expect(backend.mouseActions, isEmpty);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await mount();
      await tester.pump();
      expect(c.fontZoom, 1);
      await tester.tap(
        find.byType(TerminalView),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      // Shift explicitly overrides remote TUI mouse capture for local menus.
      if (find.text('搜索终端历史').evaluate().isEmpty) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.tap(
          find.byType(TerminalView),
          buttons: kSecondaryMouseButton,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
      }
      expect(find.text('搜索终端历史'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      c.dispose();
    },
  );
  testWidgets(
    'active composition blocks controlled input and late detached IME snapshots are ignored',
    (tester) async {
      final backend = FakeBackend(), key = GlobalKey<TerminalViewState>();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      c.applyFrame(fixture());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(key: key, controller: c),
          ),
        ),
      );
      await tester.tap(find.byType(TerminalView));
      await tester.pump();
      key.currentState!.updateEditingValue(
        const TextEditingValue(
          text: '\u200bni',
          composing: TextRange(start: 1, end: 3),
        ),
      );
      expect(c.composing, true);
      var controlled = 0;
      expect(
        await c.controlledInput((_, _) async {
          controlled++;
          return 'Applied';
        }),
        'Unavailable',
      );
      expect(controlled, 0);
      expect(backend.texts, isEmpty);
      key.currentState!.updateEditingValue(
        const TextEditingValue(text: '\u200b你'),
      );
      await tester.pump();
      expect(c.composing, false);
      expect(backend.texts, ['你']);
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      key.currentState!.updateEditingValue(
        const TextEditingValue(text: '\u200b你重复'),
      );
      await tester.pump();
      expect(backend.texts, ['你']);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      c.dispose();
    },
  );
}
