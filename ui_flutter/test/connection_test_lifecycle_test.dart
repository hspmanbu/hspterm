import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/connection_test.dart';

import 'support/fake_backend.dart';

class _PendingBackend extends FakeBackend {
  final requested = Completer<void>();
  final created = Completer<int>();
  @override
  Future<int> create() {
    requested.complete();
    return created.future;
  }
}

void main() {
  test('cancelling before native creation completes closes the eventual handle without probing', () async {
    final backend = _PendingBackend();
    var executed = false;
    final probe = HostConnectionTest(
      backend: backend,
      hostId: 'host',
      address: 'fixture.invalid',
      port: 22,
      username: 'fixture',
      confirmHostKey: (_) async => false,
      execute: (_) async {
        executed = true;
      },
    );
    final run = probe.run();
    final rejected = expectLater(run, throwsA(anything));
    await backend.requested.future;
    final cancel = probe.cancel();
    backend.created.complete(17);
    await cancel;
    await rejected;
    expect(executed, false);
    expect(backend.closes, 1);
    expect(backend.connects, 0);
    expect(backend.frames, 0);
  });
  test(
    'successful probe stays hidden and releases its event stream exactly once',
    () async {
      final backend = FakeBackend();
      var executed = 0;
      final probe = HostConnectionTest(
        backend: backend,
        hostId: 'host',
        address: 'fixture.invalid',
        port: 22,
        username: 'fixture',
        confirmHostKey: (_) async => false,
        execute: (_) async {
          executed++;
        },
      );
      await probe.run();
      await probe.run();
      await probe.cancel();
      expect(executed, 1);
      expect(backend.shown, false);
      expect(backend.frames, 0);
      expect(backend.connects, 0);
      expect(backend.closes, 1);
      expect(backend.events.isClosed, true);
    },
  );
}
