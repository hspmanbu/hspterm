import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';

import 'support/fake_backend.dart';

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
