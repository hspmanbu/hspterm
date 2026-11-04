import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/transfers.dart' as jobs;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'remote_transfer_bridge_test.dart' show remoteTask;
import 'support/local_sshd.dart';

void main() {
  test('one remote folder task exposes concurrent files, persists pause and resumes on the same two transports', () async {
    await initializeRust();
    final sourceServer = await LocalSshd.start();
    final targetServer = await LocalSshd.start();
    final a = TerminalController(const NativeTerminalBackend());
    final b = TerminalController(const NativeTerminalBackend());
    final vault = '${sourceServer.directory.path}/parallel-relay.vault';
    const password = 'synthetic parallel relay fixture';
    try {
      await rust.createConfigurationVault(path: vault, password: password);
      Future<void> connect(
        LocalSshd server,
        TerminalController controller,
      ) async {
        final host = await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Parallel relay fixture',
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            privateKey: true,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        controller.confirmHostKey = (_) async => true;
        await controller.start();
        await controller.connect(host.id);
        await waitFor(() => controller.connected, 'parallel relay SSH');
      }

      await connect(sourceServer, a);
      await connect(targetServer, b);
      final sourceGeneration = a.generation, targetGeneration = b.generation;
      await rust.saveTransferPreferences(
        value: const jobs.TransferPreferences(
          concurrency: 1,
          uploadBytesPerSecond: 128 * 1024,
          downloadBytesPerSecond: 128 * 1024,
        ),
      );
      final source = Directory(
        '${sourceServer.directory.path}/parallel source',
      );
      final target = Directory(
        '${targetServer.directory.path}/parallel target',
      );
      await Directory('${source.path}/empty/nested').create(recursive: true);
      final bytes = List.generate(512 * 1024, (i) => i % 251);
      for (var i = 0; i < 5; i++) {
        await File('${source.path}/file-$i 中文.bin').writeAsBytes(bytes);
      }
      final id = await rust.enqueueRemoteCopy(
        sourceId: a.id!,
        targetId: b.id!,
        source: source.path,
        destination: target.path,
        allowMemoryRelay: true,
      );
      final active = await remoteTask(
        id,
        (t) =>
            t.busy &&
            t.activeFiles?.length == 3 &&
            t.activeFiles!.every((f) => f.acknowledged > 0),
      );
      expect(
        (await rust.listRemoteCopies()).where((t) => t.id == id),
        hasLength(1),
      );
      expect(active.activeFiles!.map((f) => f.path).toSet(), hasLength(3));
      expect(active.activeFiles!.every((f) => f.acknowledged <= f.total), true);
      await rust.stopRemoteCopy(taskId: id, cancel: false);
      final paused = await remoteTask(id, (t) => !t.busy);
      expect(paused.state, 'Paused', reason: paused.error);
      expect(paused.activeFiles, isEmpty);
      expect(paused.acknowledged, greaterThanOrEqualTo(active.acknowledged));
      await rust.unlockVault(path: vault, password: password);
      final restored = (await rust.listRemoteCopies()).singleWhere(
        (t) => t.id == id,
      );
      expect(restored.state, 'Paused');
      expect(restored.activeFiles, isEmpty);
      expect(restored.terminalId, isNull);
      await rust.saveTransferPreferences(
        value: const jobs.TransferPreferences(
          concurrency: 1,
          uploadBytesPerSecond: 0,
          downloadBytesPerSecond: 0,
        ),
      );
      await rust.resumeRemoteCopy(
        sourceId: a.id!,
        targetId: b.id!,
        taskId: id,
        node: null,
        decision: 'continue',
        rename: null,
      );
      final done = await remoteTask(id, (t) => !t.busy);
      expect(done.state, 'Complete', reason: done.error);
      expect(done.activeFiles, isEmpty);
      for (var i = 0; i < 5; i++) {
        expect(
          await File('${target.path}/file-$i 中文.bin').readAsBytes(),
          bytes,
        );
      }
      expect(await Directory('${target.path}/empty/nested').exists(), true);
      expect(a.generation, sourceGeneration);
      expect(b.generation, targetGeneration);
      expect(a.connected && b.connected, true);
    } finally {
      await a.shutdown();
      await b.shutdown();
      a.dispose();
      b.dispose();
      await sourceServer.close();
      await targetServer.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
