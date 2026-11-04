import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/transfers.dart' as jobs;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';
import 'transfer_bridge_test.dart' show waitTask;

// Test-only read-only SQLite inspection. Observe only non-secret encryption
// nonces, never decrypt records, read account credentials or change the store.
Future<Map<String, dynamic>> partNonces(String vault, String task) async {
  final result = await Process.run('python3', [
    '-c',
    'import json,sqlite3,sys\n'
        'db=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True,timeout=5)\n'
        'rows=db.execute("SELECT id,hex(nonce) FROM records WHERE id LIKE ?",'
        '("local-transfer-"+sys.argv[2]+"-part-%",)).fetchall()\n'
        'print(json.dumps(dict(rows)))\n',
    vault,
    task,
  ]);
  expect(result.exitCode, 0, reason: result.stderr.toString());
  return jsonDecode(result.stdout.toString()) as Map<String, dynamic>;
}

void main() {
  test(
    'real multi-chunk transfer patches only dirty parts and reopens safely',
    () async {
      await initializeRust();
      final server = await LocalSshd.start();
      final controller = TerminalController(const NativeTerminalBackend());
      final vault = '${server.directory.path}/partitioned.vault';
      const master = 'test-only-partitioned-transfer';
      try {
        await rust.unlockVault(path: vault, password: master);
        final profile = await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Chunk fixture',
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
        await controller.connect(profile.id);
        await waitFor(() => controller.connected, 'chunk fixture SSH');
        final source = Directory('${server.directory.path}/chunk-source');
        final target = Directory('${server.directory.path}/chunk-target');
        await source.create();
        for (var i = 0; i < 270; i++) {
          await File('${source.path}/f${i.toString().padLeft(4, '0')}.bin')
              .writeAsBytes([i % 251]);
        }
        final large = File('${source.path}/z-large.bin');
        final bytes = List.generate(512 * 1024, (i) => i % 251);
        await large.writeAsBytes(bytes);
        await rust.saveTransferPreferences(
          value: const jobs.TransferPreferences(
            concurrency: 1,
            uploadBytesPerSecond: 65536,
            downloadBytesPerSecond: 0,
          ),
        );
        final task = await rust.enqueueTransfer(
          id: controller.id!,
          local: source.path,
          remote: target.path,
          upload: true,
        );
        await waitTask(
          task,
          (t) => t.busy && t.current == 'z-large.bin' && t.acknowledged > 65536,
        );
        final first = await partNonces(vault, task);
        expect(first, hasLength(2));
        final clean = 'local-transfer-$task-part-0';
        final dirty = 'local-transfer-$task-part-1';
        expect(first[clean], isNotNull);
        expect(first[dirty], isNotNull);
        final until = DateTime.now().add(const Duration(seconds: 5));
        var next = first;
        while (next[dirty] == first[dirty] && DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          next = await partNonces(vault, task);
        }
        expect(
          next[dirty],
          isNot(first[dirty]),
          reason: 'active progress must persist dirty chunks',
        );
        expect(
          next[clean],
          first[clean],
          reason: 'periodic progress must not rewrite completed siblings',
        );
        await rust.stopTransfer(taskId: task, cancel: false);
        final paused = await waitTask(task, (t) => !t.busy);
        expect(paused.state, 'Paused', reason: paused.error);
        expect(paused.acknowledged, greaterThan(65536));
        expect(paused.acknowledged, lessThan(512 * 1024 + 270));
        final generation = controller.generation;
        // A completed sibling need not still exist at the source to resume.
        await File('${source.path}/f0000.bin').delete();
        await File('${target.path}/f0000.bin')
            .writeAsString('keep completed sibling');
        await rust.unlockVault(path: vault, password: master);
        final restored = (await rust.listTransferTasks()).single;
        expect(restored.state, 'Paused');
        expect(restored.terminalId, isNull);
        expect(restored.acknowledged, paused.acknowledged);
        expect(controller.generation, generation);
        await rust.saveTransferPreferences(
          value: const jobs.TransferPreferences(
            concurrency: 1,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
          ),
        );
        await rust.resumeTransfer(
          id: controller.id!,
          taskId: task,
          decision: 'continue',
        );
        final complete = await waitTask(task, (t) => !t.busy);
        expect(complete.state, 'Complete', reason: complete.error);
        expect(await File('${target.path}/z-large.bin').readAsBytes(), bytes);
        expect(
          await File('${target.path}/f0000.bin').readAsString(),
          'keep completed sibling',
        );
        expect(await partNonces(vault, task), isEmpty);
        expect(controller.generation, generation);
      } finally {
        await controller.shutdown();
        controller.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
