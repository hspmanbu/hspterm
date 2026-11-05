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
}
