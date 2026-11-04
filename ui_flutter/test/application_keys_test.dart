import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/command_palette.dart';
import 'package:hspterm/terminal/application_keys.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/view.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';

import 'support/fake_backend.dart';
import 'support/terminal_cleanup.dart';

Future<void> _close(WidgetTester tester, TerminalController controller) async {
  await tester.pumpWidget(const SizedBox());
  await closeTerminal(tester, controller);
}

// This router-only fixture deliberately has no Native cache or filesystem work.
// Actual cache startup/retirement is covered by Native and GTK lifecycle tests.
class _ShortcutWorkbenchModel extends LiveWorkbenchModel {
  @override
  Future<void> initializePreviewCache() async {}
}

void main() {
  testWidgets(
    'formal saved shortcuts update the existing key router and preserve its navigator',
    (tester) async {
      final model = _ShortcutWorkbenchModel();
      await tester.pumpWidget(WorkbenchApp(model: model));
      await tester.pumpAndSettle();
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      ApplicationKeyScope router() =>
          tester.widget<ApplicationKeyScope>(find.byType(ApplicationKeyScope));
      expect(router().binding.enabled, false);
      model.paletteBinding = const PaletteBinding(
        key: LogicalKeyboardKey.f8,
        modifiers: 5,
        applicationInTerminal: true,
      );
      model.changed();
      await tester.pumpAndSettle();
      expect(router().binding.key, LogicalKeyboardKey.f8);
      expect(router().binding.applicationInTerminal, true);
      expect(
        tester.state<NavigatorState>(find.byType(Navigator).first),
        same(navigator),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(AppCommandPalette), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      model.paletteBinding = const PaletteBinding(enabled: false);
      model.changed();
      await tester.pumpAndSettle();
      expect(router().binding.enabled, false);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(model.shutdown);
      model.dispose();
    },
  );
  for (final application in [false, true]) {
    testWidgets(
      'SSH binding priority=$application preserves key ownership across the Navigator',
      (tester) async {
        final backend = FakeBackend();
        // Use one original backend for both directions; no Native or plaintext persistence.
        final controller = TerminalController(backend);
        await controller.start();
        controller.phase = 'Connected';
        controller.applyFrame(fixture());
        final nav = GlobalKey<NavigatorState>(),
            terminal = GlobalKey<TerminalViewState>();
        var opened = 0, invoked = 0;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: nav,
            builder: (_, child) => ApplicationKeyScope(
              binding: PaletteBinding(applicationInTerminal: application),
              openPalette: () async {
                opened++;
                final selected = await showAppCommandPalette(
                  nav.currentContext!,
                  commands: [AppCommand('action', '应用操作', () => invoked++)],
                  recent: RecentAppCommands(),
                  changes: controller,
                );
                if (selected != null) await selected.run();
              },
              child: child!,
            ),
            home: Scaffold(
              body: TerminalView(key: terminal, controller: controller),
            ),
          ),
        );
        terminal.currentState!.focusTerminal();
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
        await tester.pumpAndSettle();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        if (application) {
          expect(opened, 1);
          expect(find.byType(AppCommandPalette), findsOneWidget);
          expect(backend.keys.where((k) => k.key == 'p'), isEmpty);
          // Modifier presses preceded the local chord. Their real releases
          // must return to the same SSH controller while the dialog is open.
          for (final name in ['ControlLeft', 'ShiftLeft']) {
            expect(
              backend.keys.where((k) => k.key == name).map((k) => k.kind),
              [0, 2],
            );
          }

          await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(invoked, 1);
          expect(find.byType(AppCommandPalette), findsNothing);
          // Release deliberately arrives after the dialog has fully disappeared.
          terminal.currentState!.focusTerminal();
          await tester.pump();
          await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          expect(backend.keys.where((k) => k.key == 'Enter'), isEmpty);
        } else {
          expect(opened, 0);
          expect(find.byType(AppCommandPalette), findsNothing);
          expect(backend.keys.where((k) => k.key == 'p').map((k) => k.kind), [
            0,
            2,
          ]);
        }
        await _close(tester, controller);
      },
    );
  }
  for (final reconnect in [false, true]) {
    testWidgets(
      'modifier release keeps original session; reconnect=$reconnect',
      (tester) async {
        final first = FakeBackend(), second = FakeBackend();
        final a = TerminalController(first), b = TerminalController(second);
        for (final controller in [a, b]) {
          await controller.start();
          controller.phase = 'Connected';
          controller.applyFrame(fixture());
        }
        final left = GlobalKey<TerminalViewState>(),
            right = GlobalKey<TerminalViewState>();
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => ApplicationKeyScope(
              binding: const PaletteBinding(enabled: false),
              openPalette: () async {},
              child: child!,
            ),
            home: Row(
              children: [
                Expanded(
                  child: TerminalView(key: left, controller: a),
                ),
                Expanded(
                  child: TerminalView(key: right, controller: b),
                ),
              ],
            ),
          ),
        );
        left.currentState!.focusTerminal();
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        if (reconnect) a.generation++;
        right.currentState!.focusTerminal();
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(
          first.keys.where((k) => k.key == 'ControlLeft').map((k) => k.kind),
          reconnect ? [0] : [0, 2],
        );
        expect(second.keys, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await closeTerminal(tester, a);
        await closeTerminal(tester, b);
      },
    );
  }
  testWidgets(
    'disabled binding does not swallow terminal key events and custom keys are immutable',
    (tester) async {
      final backend = FakeBackend();
      final controller = TerminalController(backend);
      await controller.start();
      controller.phase = 'Connected';
      controller.applyFrame(fixture());
      final key = GlobalKey<TerminalViewState>();
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => ApplicationKeyScope(
            binding: const PaletteBinding(
              enabled: false,
              applicationInTerminal: true,
            ),
            openPalette: () async {
              opened++;
            },
            child: child!,
          ),
          home: TerminalView(key: key, controller: controller),
        ),
      );
      key.currentState!.focusTerminal();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(opened, 0);
      expect(backend.keys.where((k) => k.key == 'p').map((k) => k.kind), [
        0,
        2,
      ]);
      expect(
        () => PaletteBinding.keys['Injected'] = LogicalKeyboardKey.keyA,
        throwsUnsupportedError,
      );
      await _close(tester, controller);
    },
  );
  testWidgets(
    'an extra Meta modifier never aliases a configured Ctrl Shift chord',
    (tester) async {
      final backend = FakeBackend();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      c.applyFrame(fixture());
      final key = GlobalKey<TerminalViewState>();
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => ApplicationKeyScope(
            binding: const PaletteBinding(applicationInTerminal: true),
            openPalette: () async {
              opened++;
            },
            child: child!,
          ),
          home: TerminalView(key: key, controller: c),
        ),
      );
      key.currentState!.focusTerminal();
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(opened, 0);
      expect(backend.keys.where((k) => k.key == 'p').map((k) => k.kind), [
        0,
        2,
      ]);
      await _close(tester, c);
    },
  );
}
