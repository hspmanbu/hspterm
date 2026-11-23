import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/view.dart';

import 'support/fake_backend.dart';
import 'support/terminal_cleanup.dart';

class DelayedFrame extends FakeBackend {
  final reply = Completer<rust.RenderFrame?>();
  @override
  Future<rust.RenderFrame?> frame(int id) async {
    frames++;
    return shown ? reply.future : null;
  }
}

class DelayedHide extends FakeBackend {
  final hidden = Completer<void>();
  final calls = <bool>[];
  @override
  Future<void> visible(int id, bool visible) async {
    calls.add(visible);
    if (!visible) await hidden.future;
    shown = visible;
  }
}

void main() {
  testWidgets(
    'hidden views release drawing caches and restore the unchanged grid',
    (tester) async {
      final c = TerminalController(FakeBackend());
      final key = GlobalKey<TerminalViewState>();
      await c.start();
      c.applyFrame(fixture());
      final text = c.rows.first.map((cell) => cell.text).join();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalView(key: key, controller: c),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(key.currentState!.debugCacheStats['glyphs'], greaterThan(0));
        key.currentState!.didChangeAppLifecycleState(
          AppLifecycleState.inactive,
        );
        await tester.pumpAndSettle();
        expect(key.currentState!.debugCacheStats['glyphs'], greaterThan(0));
        key.currentState!.didChangeAppLifecycleState(AppLifecycleState.hidden);
        await tester.pumpAndSettle();
        expect(key.currentState!.debugCacheStats['glyphs'], 0);
        expect(key.currentState!.debugCacheStats['row_pictures'], 0);
        expect(c.rows.first.map((cell) => cell.text).join(), text);
        key.currentState!.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(key.currentState!.debugCacheStats['glyphs'], greaterThan(0));
        expect(c.rows.first.map((cell) => cell.text).join(), text);
        expect(
          c.frameCount,
          1,
          reason: 'cache recovery does not require another terminal frame',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await closeTerminal(tester, c);
      }
    },
  );
  test(
    'hiding waits for an in-flight delta without discarding its rows',
    () async {
      final backend = DelayedFrame();
      final c = TerminalController(backend);
      await c.start();
      backend.events.add(
        rust.BridgeEvent(kind: 'frame', generation: 0, requestId: 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(backend.frames, 1);
      var hidden = false;
      final hiding = c.setVisible(false).then((_) => hidden = true);
      await Future<void>.delayed(Duration.zero);
      expect(hidden, false);
      backend.reply.complete(fixture());
      await hiding;
      expect(c.frameCount, 1);
      expect(c.rows, isNotEmpty);
      backend.events.add(
        rust.BridgeEvent(kind: 'frame', generation: 0, requestId: 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.frameCount, 1);
      await c.shutdown();
      c.dispose();
    },
  );
  test(
    'rapid hide/show preserves native request order and shutdown drains it',
    () async {
      final backend = DelayedHide();
      final c = TerminalController(backend);
      await c.start();
      final hiding = c.setVisible(false);
      await Future<void>.delayed(Duration.zero);
      final showing = c.setVisible(true);
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls, [false]);
      backend.hidden.complete();
      await Future.wait([hiding, showing]);
      expect(backend.calls, [false, true]);
      expect(backend.shown, true);
      expect(c.visible, true);
      await c.shutdown();
      c.dispose();
    },
  );
}
