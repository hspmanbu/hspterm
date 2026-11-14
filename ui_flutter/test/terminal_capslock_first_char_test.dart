//! Round-8 regression: the first character typed after toggling Caps Lock
//! never reached the terminal on Windows (the platform text path dropped it
//! and the pending key was overwritten by the next press). These tests pin
//! the exactly-once recovery: the fallback timer/stale flush delivers it,
//! late platform duplicates are stripped, and the IME path is never fed
//! twice.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/view.dart';

import 'support/fake_backend.dart';

void main() {
  // Controller construction must stay inside each test's fake-async zone
  // (the same pattern as the other terminal tests) or its input-ordering
  // futures never progress under pump.
  late FakeBackend b;
  late TerminalController c;
  var now = 0;

  Future<void> initSession() async {
    b = FakeBackend();
    c = TerminalController(b);
    await c.start();
    c.id = 1;
    c.phase = 'Connected';
    c.generation = 3;
    now = 0;
    TerminalViewState.debugNowMs = () => now;
  }

  tearDown(() {
    TerminalViewState.debugNowMs = () => DateTime.now().millisecondsSinceEpoch;
  });

  Future<void> mountTerminal(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalView(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    tester.state<TerminalViewState>(find.byType(TerminalView)).focusTerminal();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'SSH terminal');
  }

  /// Press deliveries only (CapsLock toggles and key releases are protocol
  /// events, not typed characters).
  String delivered() =>
      b.texts.join() +
      b.keys
          .where((k) => k.kind != 2 && k.key.length == 1)
          .map((k) => k.key)
          .join();
  int deliveries() =>
      b.texts.length +
      b.keys.where((k) => k.kind != 2 && k.key.length == 1).length;

  testWidgets(
    'Space without WM_CHAR falls back once; late platform echo is stripped',
    (tester) async {
      await initSession();
      await mountTerminal(tester);
      try {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.pump(TerminalViewState.pendingFlushDelay);
        expect(delivered(), ' ');
        expect(deliveries(), 1);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: '\u200b '),
        );
        await tester.pump();
        expect(delivered(), ' ');
        expect(deliveries(), 1);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
      } finally {
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      }
    },
  );

  testWidgets(
    'caps lock on: first character is recovered when the platform never delivers it',
    (tester) async {
      await initSession();
      await mountTerminal(tester);
      // Toggle caps lock on, as the real repro does.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.capsLock);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.capsLock);
      expect(
        HardwareKeyboard.instance.lockModesEnabled,
        contains(KeyboardLockMode.capsLock),
      );

      // First printable key with caps on; the platform text path stays
      // silent (the Windows repro). Nothing may be sent before the delay…
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(deliveries(), 0);

      // …then the fallback timer delivers it exactly once, with the caps
      // lock modifier riding along.
      now = 200;
      await tester.pump(TerminalViewState.pendingFlushDelay);
      final press = b.keys.where((k) => k.kind != 2 && k.key == 'a').single;
      expect(press.modifiers & 64, isNot(0), reason: 'capsLock bit');
      expect(b.texts, isEmpty);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
      // Restore caps off for the following tests.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.capsLock);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.capsLock);
      await tester.pumpAndSettle();
      c.dispose();
    },
  );

  testWidgets('normal typing still goes through the text path once', (
    tester,
  ) async {
    await initSession();
    await mountTerminal(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '\u200bA'),
    );
    await tester.pump();
    // Long past the fallback delay: exactly one delivery.
    await tester.pump(const Duration(seconds: 1));
    expect(delivered(), 'A');
    expect(deliveries(), 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    c.dispose();
  });

  testWidgets('late platform duplicate after a direct flush is stripped', (
    tester,
  ) async {
    await initSession();
    await mountTerminal(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.pump(TerminalViewState.pendingFlushDelay);
    expect(delivered(), 'a');

    // The platform delivers the same character late.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '\u200ba'),
    );
    await tester.pump();
    expect(delivered(), 'a', reason: 'no duplicate');
    expect(deliveries(), 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    c.dispose();
  });

  testWidgets('fast typing: stale flush then bundled update keeps order once', (
    tester,
  ) async {
    await initSession();
    await mountTerminal(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    now += 50; // older than the stale-flush minimum age
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyB);
    await tester.pump();
    // 'a' was never delivered by the platform; 'b' flushes it directly.
    expect(delivered(), 'a');

    // The platform then bundles both characters in one update.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '\u200bab'),
    );
    await tester.pump();
    expect(delivered(), 'ab', reason: 'stripped a, kept b once');
    expect(deliveries(), 2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyB);
    await tester.pumpAndSettle();
    c.dispose();
  });

  testWidgets('IME composition consumes the pending key; no direct flush', (
    tester,
  ) async {
    await initSession();
    await mountTerminal(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    // The IME starts composing with that key.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '\u200ba',
        composing: TextRange(start: 1, end: 2),
      ),
    );
    await tester.pump();
    // Long past the fallback delay: composition owns the key, nothing sent.
    await tester.pump(const Duration(seconds: 1));
    expect(deliveries(), 0);
    // Committing the composition delivers the converted text exactly once.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '\u200b啊'),
    );
    await tester.pump();
    expect(b.texts, ['啊']);
    expect(b.keys.where((k) => k.kind != 2), isEmpty);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    c.dispose();
  });

  testWidgets('focus loss drops the pending key instead of typing blind', (
    tester,
  ) async {
    await initSession();
    await mountTerminal(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(deliveries(), 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    c.dispose();
  });

  testWidgets('mixed case after caps toggle all arrive exactly once', (
    tester,
  ) async {
    await initSession();
    await mountTerminal(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.capsLock);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.capsLock);

    // The first character after the toggle is dropped by the platform and
    // recovered by the fallback timer.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
    now += 100;
    await tester.pump(TerminalViewState.pendingFlushDelay);
    expect(delivered(), 'p');

    // Everything after flows through the normal text path; the platform
    // model accumulates the committed characters.
    var model = '';
    Future<void> type(String text) async {
      for (final rune in text.runes) {
        final key = LogicalKeyboardKey.findKeyByKeyId(
          String.fromCharCode(rune).toLowerCase().codeUnitAt(0),
        )!;
        await tester.sendKeyDownEvent(key);
        model += String.fromCharCode(rune);
        tester.testTextInput.updateEditingValue(
          TextEditingValue(text: '\u200b$model'),
        );
        await tester.pump();
        now += 5;
        await tester.sendKeyUpEvent(key);
        await tester.pump();
      }
    }

    await type('assword');
    expect(delivered(), 'password');
    expect(deliveries(), 'password'.length);
    await tester.pumpAndSettle();
    // Restore caps off for any later tests in this file.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.capsLock);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.capsLock);
    await tester.pumpAndSettle();
    c.dispose();
  });
}
