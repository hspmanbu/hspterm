import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'support/local_sshd.dart';

void main() {
  setUpAll(initializeRust);
  test('saved-host probe verifies SSH identity without trying target credentials or adding a tab', () async {
    final server = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    try {
      await rust.unlockVault(
        path: '${server.directory.path}/probe.vault',
        password: 'synthetic probe master',
      );
      await model.load();
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Probe fixture',
          '127.0.0.1',
          '未分组',
          port: server.port,
          user: 'synthetic-user-that-does-not-exist',
          auth: '密码',
          openSftp: false,
        ),
        secret: 'invalid-synthetic-password',
      );
      var confirmations = 0;
      model.confirmHostKey = (h, event) async {
        confirmations++;
        expect(h.id, host.id);
        expect(h.address, '127.0.0.1');
        return true;
      };
      final first = model.testSavedHost(host);
      await first;
      expect(confirmations, 1);
      expect(model.sessions, isEmpty);
      expect(model.tabs, isEmpty);
      expect(model.recent, isEmpty);
      expect(await rust.listTransferTasks(), isEmpty);
      expect(model.hasActiveSessions, false);
      final second = model.testSavedHost(host);
      await model.cancelHostTest(expected: first);
      await second;
      expect(
        confirmations,
        1,
        reason: 'the accepted original target key was encrypted and reused',
      );
      final testId = await rust.createTerminal(
        columns: 80,
        rows: 24,
        historyLines: 0,
      );
      try {
        await expectLater(
          rust.testHostConnection(
            id: testId,
            hostId: host.id,
            expectedAddress: 'mismatched.invalid',
            expectedPort: host.port,
            expectedUsername: host.user,
          ),
          throwsA(predicate((error) => error.toString().contains('主机目标已变化'))),
        );
      } finally {
        await rust.destroyTerminal(id: testId);
      }
      final changed = host.snapshot()..address = 'another.invalid';
      await expectLater(model.testSavedHost(changed), throwsA(anything));
      expect(model.sessions, isEmpty);
    } finally {
      await model.shutdown();
      model.dispose();
      await server.close();
    }
  });

  test('cancelling a stalled saved-host proxy probe releases its socket and keeps no terminal tab', () async {
    final directory = await Directory.systemTemp.createTemp(
      'hspterm-probe-cancel-',
    );
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var greeting = Completer<void>(), closed = Completer<void>();
    Socket? client;
    final subscription = listener.listen((socket) {
      client = socket;
      socket.listen(
        (bytes) {
          if (!greeting.isCompleted) greeting.complete();
        },
        onDone: () {
          socket.destroy();
          if (!closed.isCompleted) closed.complete();
        },
      );
    });
    final model = LiveWorkbenchModel();
    try {
      await rust.unlockVault(
        path: '${directory.path}/probe.vault',
        password: 'synthetic cancellation master',
      );
      await model.load();
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Stalled probe fixture',
          'target.invalid',
          '未分组',
          user: 'fixture',
          auth: '密码',
          timeoutSeconds: 20,
          openSftp: false,
          proxy: DemoProxy(
            socks5: true,
            address: '127.0.0.1',
            port: listener.port,
          ),
        ),
        secret: 'synthetic-password',
      );
      final attempt = model.testSavedHost(host);
      final rejected = expectLater(attempt, throwsA(anything));
      await greeting.future.timeout(const Duration(seconds: 5));
      expect(model.hasActiveSessions, true);
      await model.cancelHostTest().timeout(const Duration(seconds: 3));
      await rejected;
      await closed.future.timeout(const Duration(seconds: 3));
      expect(model.sessions, isEmpty);
      expect(model.tabs, isEmpty);
      expect(model.hasActiveSessions, false);
      expect(model.operationError, isNull);
      greeting = Completer<void>();
      closed = Completer<void>();
      final duringExit = model.testSavedHost(host);
      final exitRejected = expectLater(duringExit, throwsA(anything));
      await greeting.future.timeout(const Duration(seconds: 5));
      await model.shutdown().timeout(const Duration(seconds: 3));
      await exitRejected;
      await closed.future.timeout(const Duration(seconds: 3));
      expect(model.hasActiveSessions, false);
      expect(model.tabs, isEmpty);
    } finally {
      await model.shutdown();
      model.dispose();
      client?.destroy();
      await subscription.cancel();
      await listener.close();
      await directory.delete(recursive: true);
    }
  });
}
