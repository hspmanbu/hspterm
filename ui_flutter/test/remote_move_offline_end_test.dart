import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/transfers.dart' as jobs;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'remote_transfer_bridge_test.dart' show remoteTask;
import 'support/local_sshd.dart';
import 'support/lost_rename_reply_sftp.dart';
import 'transfer_bridge_test.dart' show waitTask;

void main() {
  test(
    'local move review ends waiting after host deletion and shutdown without weakening any network check',
    () async {
      await initializeRust();
      final server = await LocalSshd.start(sftpFixture: lostRenameReplySftp);
      final a = TerminalController(const NativeTerminalBackend());
      final b = TerminalController(const NativeTerminalBackend());
      final vault = '${server.directory.path}/offline move.vault';
      const master = 'synthetic offline move master';
      try {
        await rust.unlockVault(path: vault, password: master);
        await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Offline end fixture',
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            privateKey: true,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        final host = (await rust.listHosts()).single;
        for (final c in [a, b]) {
          c.confirmHostKey = (_) async => true;
          await c.start();
          await c.connect(host.id);
          await waitFor(() => c.connected, 'offline-end SSH fixture');
        }
        final source = File('${server.directory.path}/source.bin');
        final target = File('${server.directory.path}/target.bin');
        final original = List.filled(65536, 71),
            recreated = List.filled(65536, 82);
        await source.writeAsBytes(original);
        await rust.saveTransferPreferences(
          value: const jobs.TransferPreferences(
            concurrency: 1,
            uploadBytesPerSecond: 1,
            downloadBytesPerSecond: 1,
          ),
        );
        final held = await rust.enqueueTransfer(
          id: a.id!,
          local: source.path,
          remote: '${server.directory.path}/held upload.bin',
          upload: true,
        );
        await waitTask(held, (t) => t.busy && t.acknowledged > 0);
        final pending = await rust.enqueueRemoteMove(
          sourceId: a.id!,
          targetId: b.id!,
          source: source.path,
          destination: '${target.path}.queued',
          expectedSourceGeneration: a.generation,
          expectedTargetGeneration: b.generation,
        );
        await expectLater(
          rust.prepareRemoteMoveEnd(taskId: pending),
          throwsA(anything),
          reason: 'an active/queued task is not an unresolved stopped move',
        );
        await expectLater(
          rust.endRemoteMoveWait(taskId: pending, ticket: 'unprepared'),
          throwsA(anything),
        );
        await rust.stopRemoteCopy(taskId: pending, cancel: true);
        await rust.stopTransfer(taskId: held, cancel: true);
        await rust.clearEndedTransfers();
        await rust.clearEndedRemoteCopies();
        expect(await source.readAsBytes(), original);
        expect(await target.exists(), false);
        await rust.saveTransferPreferences(
          value: const jobs.TransferPreferences(
            concurrency: 3,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
          ),
        );
        final id = await rust.enqueueRemoteMove(
          sourceId: a.id!,
          targetId: b.id!,
          source: source.path,
          destination: target.path,
          expectedSourceGeneration: a.generation,
          expectedTargetGeneration: b.generation,
        );
        expect(
          (await remoteTask(id, (t) => !t.busy)).remoteMovePhase,
          'Intent',
        );
        await source.writeAsBytes(recreated);
        final local = await rust.prepareRemoteMoveEnd(taskId: id);
        expect(local.sourcePath, source.path);
        expect(local.destinationPath, target.path);
        expect(
          local.account,
          contains('${server.username}@127.0.0.1:${server.port}'),
        );
        expect(local.fingerprint, isNotEmpty);
        final network = await rust.inspectRemoteMove(
          sourceId: a.id!,
          targetId: b.id!,
          taskId: id,
        );
        await expectLater(
          rust.endRemoteMoveWait(taskId: id, ticket: network.ticket),
          throwsA(anything),
          reason: 'network and local review capabilities are distinct',
        );
        await expectLater(
          rust.acknowledgeRemoteMove(
            sourceId: a.id!,
            targetId: b.id!,
            taskId: id,
            ticket: local.ticket,
          ),
          throwsA(anything),
        );
        final latest = await rust.prepareRemoteMoveEnd(taskId: id);
        await expectLater(
          rust.endRemoteMoveWait(taskId: id, ticket: local.ticket),
          throwsA(anything),
          reason: 'a newer local review supersedes the old one',
        );
        await rust.deleteHosts(ids: [host.id]);
        expect(await rust.listHosts(), isEmpty);
        expect(
          a.connected,
          true,
          reason: 'deleting configuration must not disconnect running SSH',
        );
        await a.shutdown();
        await b.shutdown();
        server.process.kill();
        await server
            .process
            .exitCode; // Leave the isolated vault/files for verification.
        await rust.unlockVault(
          path: '${server.directory.path}/other.vault',
          password: 'synthetic other vault',
        );
        await expectLater(
          rust.endRemoteMoveWait(taskId: id, ticket: latest.ticket),
          throwsA(anything),
        );
        await rust.unlockVault(path: vault, password: master);
        await expectLater(
          rust.endRemoteMoveWait(taskId: id, ticket: latest.ticket),
          throwsA(anything),
          reason: 'local review cannot cross vault reload',
        );
        final offline = await rust.prepareRemoteMoveEnd(taskId: id);
        expect(offline.sourcePath, source.path);
        final trigger = await Process.run('python3', [
          '-c',
          'import sqlite3,sys\ndb=sqlite3.connect(sys.argv[1])\n'
              'db.execute("CREATE TRIGGER deny_offline_end BEFORE INSERT ON records WHEN NEW.id=\'local-remote-transfer-"+sys.argv[2]+"\' BEGIN SELECT RAISE(ABORT, \'synthetic offline end failure\'); END;")\ndb.commit()\n',
          vault,
          id,
        ]);
        expect(trigger.exitCode, 0, reason: trigger.stderr.toString());
        await expectLater(
          rust.endRemoteMoveWait(taskId: id, ticket: offline.ticket),
          throwsA(anything),
        );
        expect((await remoteTask(id, (_) => true)).remoteMovePhase, 'Intent');
        final drop = await Process.run('python3', [
          '-c',
          'import sqlite3,sys\ndb=sqlite3.connect(sys.argv[1])\ndb.execute("DROP TRIGGER deny_offline_end")\ndb.commit()\n',
          vault,
        ]);
        expect(drop.exitCode, 0, reason: drop.stderr.toString());
        await rust.endRemoteMoveWait(taskId: id, ticket: offline.ticket);
        final ended = await remoteTask(id, (_) => true);
        expect(ended.remoteMovePhase, 'UserEnded');
        expect(ended.state, 'Cancelled');
        expect(ended.completed, 0);
        await expectLater(
          rust.endRemoteMoveWait(taskId: id, ticket: offline.ticket),
          throwsA(anything),
        );
        expect(await source.readAsBytes(), recreated);
        expect(await target.readAsBytes(), original);
        expect(
          await File('${server.directory.path}/sftp_fixture.py.rename-count')
              .readAsLines(),
          ['1'],
        );
        expect(
          await rust.listHosts(),
          isEmpty,
          reason: 'local ending never recreates credentials or hosts',
        );
        await rust.clearEndedRemoteCopies();
        await rust.unlockVault(path: vault, password: master);
        expect(await rust.listRemoteCopies(), isEmpty);
      } finally {
        await a.shutdown();
        a.dispose();
        await b.shutdown();
        b.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
