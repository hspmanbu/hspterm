import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/transfers.dart' as jobs;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/fake_backend.dart';
import 'support/local_sshd.dart';
import 'transfer_bridge_test.dart' show waitTask;

class NoticeBackend extends FakeBackend
    implements TerminalReconnectNoticeBackend {
  String? message = '恢复报告';
  bool fail = false;
  Completer<String?>? delayed;
  @override
  Future<String?> reconnectNotice(int id) async {
    if (fail) throw StateError('controlled notice failure');
    return delayed?.future ?? message;
  }
}

void main() {
  test(
    'restore notices are separate from transport failure and can be dismissed',
    () async {
      final backend = NoticeBackend();
      final c = TerminalController(backend);
      try {
        await c.start();
        await c.connect('synthetic-host');
        expect(c.reconnectNotice, '恢复报告');
        expect(c.error, isNull);
        c.dismissReconnectNotice();
        expect(c.reconnectNotice, isNull);
        c.phase = 'Disconnected';
        backend.fail = true;
        await c.connect('synthetic-host');
        expect(c.error, isNull);
        expect(c.phase, isNot('Failed'));
        expect(c.reconnectNotice, contains('未取得传输恢复报告'));
      } finally {
        await c.shutdown();
        c.dispose();
      }
    },
  );
  test('a late notice cannot update a closed controller', () async {
    final backend = NoticeBackend()..delayed = Completer<String?>();
    final c = TerminalController(backend);
    await c.start();
    final connecting = c.connect('synthetic-host');
    await Future<void>.delayed(Duration.zero);
    await c.shutdown();
    c.dispose();
    backend.delayed!.complete('late-report');
    await connecting;
    expect(c.reconnectNotice, isNull);
  });
  test(
    'private SSH explicit reconnect restores interrupted tasks, preserves user pause and restart boundary',
    () async {
      await initializeRust();
      final server = await LocalSshd.start();
      final c = TerminalController(const NativeTerminalBackend());
      final vault = '${server.directory.path}/reconnect.vault';
      const master = 'test-only-reconnect-master';
      try {
        await rust.unlockVault(path: vault, password: master);
        final profile = await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'reconnect fixture',
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            privateKey: true,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        c.confirmHostKey = (_) async => true;
        await c.start();
        await c.connect(profile.id);
        await waitFor(() => c.connected, 'fixture SSH');
        final file = File('${server.directory.path}/source.bin');
        await file.writeAsBytes(List.generate(65536, (i) => i % 251));
        await rust.saveTransferPreferences(
          value: const jobs.TransferPreferences(
            concurrency: 1,
            uploadBytesPerSecond: 1,
            downloadBytesPerSecond: 0,
            resumeOnReconnect: true,
          ),
        );
        final ids = <String>[];
        for (var i = 0; i < 3; i++) {
          ids.add(
            await rust.enqueueTransfer(
              id: c.id!,
              local: file.path,
              remote: '${server.directory.path}/target-$i.bin',
              upload: true,
            ),
          );
        }
        await waitTask(ids.first, (t) => t.busy && t.acknowledged > 0);
        await rust.stopTransfer(taskId: ids.last, cancel: false);
        await rust.disconnectTerminal(id: c.id!);
        await waitFor(
          () => !c.connected && c.phase != 'Connecting',
          'disconnected fixture',
        );
        // An older caller saving rates must preserve the new opt-in field.
        await rust.saveTransferPreferences(
          value: const jobs.TransferPreferences(
            concurrency: 1,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
          ),
        );
        expect((await rust.transferPreferences()).resumeOnReconnect, true);
        await c.connect(profile.id);
        await waitFor(() => c.connected, 'manual reconnect');
        for (var i = 0; i < 2; i++) {
          final task = await waitTask(ids[i], (t) => !t.busy);
          expect(task.state, 'Complete');
          expect(
            await File('${server.directory.path}/target-$i.bin').readAsBytes(),
            await file.readAsBytes(),
          );
        }
        expect((await waitTask(ids.last, (t) => !t.busy)).state, 'Paused');
        expect(c.reconnectNotice, contains('已入队2项'));
        // A same-vault reopen uses a fresh instance and must not reconstruct
        // ephemeral reconnect permission from the durable paused task.
        await rust.unlockVault(path: vault, password: master);
        await rust.disconnectTerminal(id: c.id!);
        await waitFor(() => !c.connected, 'second disconnect');
        await c.connect(profile.id);
        await waitFor(() => c.connected, 'after local restore');
        expect((await waitTask(ids.last, (t) => !t.busy)).state, 'Paused');
        await rust.stopTransfer(taskId: ids.last, cancel: true);
      } finally {
        await c.shutdown();
        c.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
