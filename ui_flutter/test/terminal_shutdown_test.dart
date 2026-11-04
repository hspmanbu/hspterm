import 'support/terminal_cleanup.dart';

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';

import 'support/fake_backend.dart';

class _RetryClose extends FakeBackend {
  final closedIds = <int>[];
  bool fail = true;
  bool closeStream = true;
  @override
  Future<void> close(int id) async {
    closedIds.add(id);
    closes++;
    if (fail) {
      fail = false;
      throw StateError('checkpoint flush failed');
    }
    if (closeStream) await events.close();
  }
}

class _LateCreate extends _RetryClose {
  final created = Completer<int>();
  @override
  Future<int> create() => created.future;
}

void main() {
  test(
    'failed close retains owner and disables interaction until retry',
    () async {
      final backend = _RetryClose();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      c.profileId = 'fixture';
      await expectLater(c.shutdown(), throwsStateError);
      expect(c.id, 1);
      expect(c.isClosing, true);
      expect(c.connected, false);
      expect(c.shutdownComplete, false);
      expect(backend.events.hasListener, true);
      await c.text('must not send');
      await c.reconnect();
      await c.connect('fixture');
      await c.setVisible(false);
      c.applyFrame(fixture());
      backend.events.add(
        rust.BridgeEvent(
          kind: 'status',
          generation: 9,
          requestId: 0,
          text: 'Connected',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.phase, 'Closing');
      expect(c.generation, 0);
      expect(c.frameCount, 0);
      expect(backend.texts, isEmpty);
      expect(backend.connects, 0);
      expect(backend.shown, true);
      await c.shutdown();
      expect(backend.closedIds, [1, 1]);
      expect(c.id, isNull);
      expect(c.shutdownComplete, true);
      await c.shutdown();
      expect(backend.closes, 2);
      c.dispose();
      c.dispose();
    },
  );

  test('concurrent shutdown calls share the same native close', () async {
    final backend = FakeBackend();
    final released = Completer<void>();
    backend.closeWait = released.future;
    final c = TerminalController(backend);
    await c.start();
    final first = c.shutdown(), second = c.shutdown();
    expect(identical(first, second), true);
    await Future<void>.delayed(Duration.zero);
    expect(backend.closes, 1);
    expect(c.id, 1);
    released.complete();
    await Future.wait([first, second]);
    expect(c.shutdownComplete, true);
    c.dispose();
  });

  test('late create close failure retains its id even after dispose', () async {
    final backend = _LateCreate();
    final c = TerminalController(backend);
    final starting = c.start();
    final closing = c.shutdown();
    final failure = expectLater(closing, throwsStateError);
    c.dispose();
    c.dispose();
    backend.created.complete(27);
    await starting;
    await failure;
    expect(c.id, 27);
    expect(c.shutdownComplete, false);
    await c.shutdown();
    expect(backend.closedIds, [27, 27]);
    expect(backend.connects, 0);
    expect(c.id, isNull);
    expect(c.shutdownComplete, true);
  });

  testWidgets(
    'stream timeout retries port retirement without another destroy',
    (tester) async {
      final backend = _RetryClose()
        ..fail = false
        ..closeStream = false;
      final c = TerminalController(backend);
      await c.start();
      final failure = expectLater(
        c.shutdown(),
        throwsA(isA<TimeoutException>()),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await drainAsync(tester, failure);
      expect(c.id, isNull);
      expect(c.shutdownComplete, false);
      expect(backend.events.hasListener, true);
      final retry = c.shutdown();
      final streamClosed = backend.events.close();
      await tester.pump();
      await drainAsync(tester, streamClosed);
      await drainAsync(tester, retry);
      expect(backend.closes, 1);
      expect(c.shutdownComplete, true);
      c.dispose();
    },
  );
}
