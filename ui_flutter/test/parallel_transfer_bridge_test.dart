import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/transfers.dart' as jobs;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';
import 'transfer_bridge_test.dart' show waitTask;

void main() {
  test('real folder keeps one queue task, publishes per-file progress and clears activity after pause/resume', () async {
    await initializeRust();
    final server = await LocalSshd.start();
    final controller = TerminalController(const NativeTerminalBackend());
    try {
      await rust.createConfigurationVault(
        path: '${server.directory.path}/parallel.vault',
        password: 'synthetic-parallel-master',
      );
      final host = await rust.saveProfile(
        profile: rust.Profile(
          id: '',
          name: 'Parallel fixture',
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
      await waitFor(() => controller.connected, 'parallel fixture SSH');
      await expectLater(
        rust.enqueueTransfer(
          id: controller.id!,
          local: server.directory.path,
          remote: '${server.directory.path}/wrong-generation-target',
          upload: true,
          expectedGeneration: controller.generation + 1,
        ),
        throwsA(anything),
      );
      expect(await rust.listTransferTasks(), isEmpty);
      await rust.saveTransferPreferences(
        value: const jobs.TransferPreferences(
          concurrency: 1,
          uploadBytesPerSecond: 128 * 1024,
          downloadBytesPerSecond: 0,
        ),
      );
      final source = Directory('${server.directory.path}/parallel-source');
      final target = Directory('${server.directory.path}/parallel-target');
      await Directory('${source.path}/empty').create(recursive: true);
      final bytes = List.generate(256 * 1024, (i) => i % 251);
      for (var i = 0; i < 4; i++) {
        await File('${source.path}/file-$i.bin').writeAsBytes(bytes);
      }
      final id = await rust.enqueueTransfer(
        id: controller.id!,
        local: source.path,
        remote: target.path,
        upload: true,
      );
      final active = await waitTask(
        id,
        (t) =>
            t.busy &&
            (t.activeFiles?.length ?? 0) >= 2 &&
            t.acknowledged >= 32768,
      );
      expect(
        (await rust.listTransferTasks()).where((t) => t.id == id),
        hasLength(1),
      );
      expect(active.activeFiles!.length, lessThanOrEqualTo(3));
      expect(
        active.activeFiles!.map((f) => f.path).toSet().length,
        active.activeFiles!.length,
      );
      expect(active.activeFiles!.every((f) => f.acknowledged <= f.total), true);
      await rust.stopTransfer(taskId: id, cancel: false);
      final paused = await waitTask(id, (t) => !t.busy);
      expect(paused.state, 'Paused', reason: paused.error);
      expect(paused.activeFiles, isNull);
      expect(paused.acknowledged, greaterThanOrEqualTo(active.acknowledged));
      await rust.saveTransferPreferences(
        value: const jobs.TransferPreferences(
          concurrency: 1,
          uploadBytesPerSecond: 0,
          downloadBytesPerSecond: 0,
        ),
      );
      expect(RegExp(r'^task-[0-9a-f]{32}$').hasMatch(id), true);
      final denyRemoval = await Process.run('python3', [
        '-c',
        'import sqlite3,sys\ndb=sqlite3.connect(sys.argv[1])\n'
            'db.execute("CREATE TRIGGER deny_final_transfer_removal BEFORE DELETE ON records WHEN OLD.id=\'local-transfer-"+sys.argv[2]+"\' BEGIN SELECT RAISE(ABORT, \'synthetic final inventory removal failure\'); END;")\n'
            'db.commit()\n',
        '${server.directory.path}/parallel.vault',
        id,
      ]);
      expect(denyRemoval.exitCode, 0, reason: denyRemoval.stderr.toString());
      await rust.resumeTransfer(
        id: controller.id!,
        taskId: id,
        decision: 'continue',
      );
      final done = await waitTask(id, (t) => !t.busy);
      expect(
        done.state,
        'Failed',
        reason: 'the last journal deletion is intentionally rejected',
      );
      expect(done.activeFiles, isNull);
      for (var i = 0; i < 4; i++) {
        expect(await File('${target.path}/file-$i.bin').readAsBytes(), bytes);
      }
      expect(await Directory('${target.path}/empty').exists(), true);
      final allowRemoval = await Process.run('python3', [
        '-c',
        'import sqlite3,sys\ndb=sqlite3.connect(sys.argv[1])\ndb.execute("DROP TRIGGER deny_final_transfer_removal")\ndb.commit()\n',
        '${server.directory.path}/parallel.vault',
      ]);
      expect(allowRemoval.exitCode, 0, reason: allowRemoval.stderr.toString());
      await source.delete(recursive: true);
      for (var i = 0; i < 4; i++) {
        await File('${target.path}/file-$i.bin')
            .writeAsString('later independent target $i');
      }
      await rust.resumeTransfer(
        id: controller.id!,
        taskId: id,
        decision: 'continue',
      );
      final recovered = await waitTask(id, (t) => !t.busy);
      expect(recovered.state, 'Complete', reason: recovered.error);
      for (var i = 0; i < 4; i++) {
        expect(
          await File('${target.path}/file-$i.bin').readAsString(),
          'later independent target $i',
        );
      }
      expect(controller.connected, true);
    } finally {
      await controller.shutdown();
      controller.dispose();
      await server.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
