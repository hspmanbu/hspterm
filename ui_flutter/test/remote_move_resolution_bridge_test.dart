import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'remote_transfer_bridge_test.dart' show remoteTask;
import 'support/local_sshd.dart';
import 'support/lost_rename_reply_sftp.dart';

Future<void> exerciseUncertainMove() async {
  await initializeRust();
  final server = await LocalSshd.start(sftpFixture: lostRenameReplySftp);
  final a = TerminalController(const NativeTerminalBackend());
  final b = TerminalController(const NativeTerminalBackend());
  final vault = '${server.directory.path}/unknown move.vault';
  const master = 'synthetic unknown move master';
  try {
    await rust.unlockVault(path: vault, password: master);
    final host = await rust.saveProfile(
      profile: rust.Profile(
        id: '',
        name: 'Lost reply fixture',
        address: '127.0.0.1',
        port: server.port,
        username: server.username,
        privateKey: true,
      ),
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );
    for (final controller in [a, b]) {
      controller.confirmHostKey = (_) async => true;
      await controller.start();
      await controller.connect(host.id);
      await waitFor(() => controller.connected, 'unknown move SSH');
    }
    final source = File('${server.directory.path}/source 中文.bin');
    final target = File('${server.directory.path}/target 中文.bin');
    final original = List.filled(65536, 71), recreated = List.filled(65536, 82);
    await source.writeAsBytes(original);
    final id = await rust.enqueueRemoteMove(
      sourceId: a.id!,
      targetId: b.id!,
      source: source.path,
      destination: target.path,
      expectedSourceGeneration: a.generation,
      expectedTargetGeneration: b.generation,
    );
    final unknown = await remoteTask(id, (t) => !t.busy);
    expect(unknown.state, 'Failed');
    expect(unknown.remoteMovePhase, 'Intent');
    expect(await source.exists(), false);
    expect(await target.readAsBytes(), original);
    final count = File('${server.directory.path}/sftp_fixture.py.rename-count');
    expect(await count.readAsLines(), ['1']);
    final missing = await rust.inspectRemoteMove(
      sourceId: a.id!,
      targetId: b.id!,
      taskId: id,
    );
    expect(missing.sourceKind, 'Missing');
    expect(missing.destinationKind, 'File');
    expect(
      (await remoteTask(id, (_) => true)).state,
      'Failed',
      reason: 'missing source is not an inferred success',
    );
    // Equal-size paths cannot prove the old request's outcome. A subsequent
    // source object must never be renamed by automatic/manual "continue".
    await source.writeAsBytes(recreated);
    await expectLater(
      rust.resumeRemoteCopy(
        sourceId: a.id!,
        targetId: b.id!,
        taskId: id,
        decision: 'continue',
      ),
      throwsA(anything),
    );
    expect(
      () => rust.reserveEditor(
        id: a.id!,
        generation: a.generation,
        path: source.path,
      ),
      throwsA(anything),
    );
    final first = await rust.inspectRemoteMove(
      sourceId: a.id!,
      targetId: b.id!,
      taskId: id,
    );
    expect(first.sourceKind, 'File');
    expect(first.destinationKind, 'File');
    expect(first.sourceSize, 65536);
    expect(first.destinationSize, 65536);
    expect(first.sourcePath, source.path);
    expect(first.destinationPath, target.path);
    await expectLater(
      rust.acknowledgeRemoteMove(
        sourceId: a.id!,
        targetId: b.id!,
        taskId: id,
        ticket: missing.ticket,
      ),
      throwsA(anything),
      reason: 'a new inspection replaces the old ticket',
    );
    await expectLater(
      rust.acknowledgeRemoteMove(
        sourceId: b.id!,
        targetId: a.id!,
        taskId: id,
        ticket: first.ticket,
      ),
      throwsA(anything),
      reason: 'same-account transports cannot exchange a ticket scope',
    );
    final beforeReconnect = a.generation;
    await rust.disconnectTerminal(id: a.id!);
    await waitFor(
      () => a.phase == 'Disconnected',
      'explicit inspection disconnect',
    );
    await a.reconnect();
    await waitFor(
      () => a.connected && a.generation > beforeReconnect,
      'explicit inspection reconnect',
    );
    await expectLater(
      rust.acknowledgeRemoteMove(
        sourceId: a.id!,
        targetId: b.id!,
        taskId: id,
        ticket: first.ticket,
      ),
      throwsA(anything),
      reason: 'old inspection cannot cross SSH generations',
    );
    final beforeRestore = await rust.inspectRemoteMove(
      sourceId: a.id!,
      targetId: b.id!,
      taskId: id,
    );
    await rust.unlockVault(path: vault, password: master);
    await expectLater(
      rust.acknowledgeRemoteMove(
        sourceId: a.id!,
        targetId: b.id!,
        taskId: id,
        ticket: beforeRestore.ticket,
      ),
      throwsA(anything),
      reason: 'vault restore invalidates completed inspections',
    );
    final gatePath = '${server.directory.path}/sftp_fixture.py.inspection-gate';
    final hold = File(
      '${server.directory.path}/sftp_fixture.py.hold-inspection',
    );
    final marker = File(
      '${server.directory.path}/sftp_fixture.py.inspection-started',
    );
    final fifo = await Process.run('mkfifo', [gatePath]);
    expect(fifo.exitCode, 0, reason: fifo.stderr.toString());
    Future<void> heldInspection(
      Future<void> Function() during,
      String? refusal,
    ) async {
      if (await marker.exists()) await marker.delete();
      await hold.writeAsString('synthetic metadata barrier');
      final response = rust.inspectRemoteMove(
        sourceId: a.id!,
        targetId: b.id!,
        taskId: id,
      );
      var acknowledged = false;
      final rejected = refusal == null
          ? response.then<void>((_) => acknowledged = true)
          : expectLater(
              response,
              throwsA(
                predicate<Object>(
                  (error) => error.toString().contains(refusal),
                ),
              ),
            );
      try {
        await waitFor(marker.existsSync, 'controlled metadata barrier');
        await during();
      } finally {
        if (await hold.exists()) await hold.delete();
        final release = await Process.run('python3', [
          '-c',
          'import os,sys,errno\n'
              'try:\n f=os.open(sys.argv[1],os.O_WRONLY|os.O_NONBLOCK)\n os.write(f,b"1")\n os.close(f)\n'
              'except OSError as e:\n if e.errno!=errno.ENXIO: raise\n',
          gatePath,
        ]);
        expect(release.exitCode, 0, reason: release.stderr.toString());
      }
      await rejected;
      if (refusal == null) expect(acknowledged, true);
    }

    await heldInspection(() async {
      await hold.delete(); // A newer channel is allowed through; the old one stays held.
      await rust.inspectRemoteMove(
        sourceId: a.id!,
        targetId: b.id!,
        taskId: id,
      );
    }, '已有更新的检查');
    await heldInspection(() async {
      // A held real metadata channel now correctly prevents replacing its
      // Vault owner. Refusal must preserve that original inspection, not make
      // its successful response look stale or abandon the live IO worker.
      await expectLater(
        rust.unlockVault(path: vault, password: master),
        throwsA(
          predicate<Object>((error) => error.toString().contains('子通道本机收尾')),
        ),
      );
    }, null);
    await rust.unlockVault(path: vault, password: master);
    await rust.listRemoteCopies(); // Reload only after actual IO retirement.
    final current = await rust.inspectRemoteMove(
      sourceId: a.id!,
      targetId: b.id!,
      taskId: id,
    );
    final trigger = await Process.run('python3', [
      '-c',
      'import sqlite3,sys\ndb=sqlite3.connect(sys.argv[1])\n'
          'db.execute("CREATE TRIGGER deny_move_ack BEFORE INSERT ON records WHEN NEW.id=\'local-remote-transfer-"+sys.argv[2]+"\' BEGIN SELECT RAISE(ABORT, \'synthetic manual acknowledgement failure\'); END;")\ndb.commit()\n',
      vault,
      id,
    ]);
    expect(trigger.exitCode, 0, reason: trigger.stderr.toString());
    await expectLater(
      rust.acknowledgeRemoteMove(
        sourceId: a.id!,
        targetId: b.id!,
        taskId: id,
        ticket: current.ticket,
      ),
      throwsA(anything),
    );
    expect((await remoteTask(id, (_) => true)).remoteMovePhase, 'Intent');
    expect(
      () => rust.reserveEditor(
        id: a.id!,
        generation: a.generation,
        path: source.path,
      ),
      throwsA(anything),
    );
    final drop = await Process.run('python3', [
      '-c',
      'import sqlite3,sys\ndb=sqlite3.connect(sys.argv[1])\ndb.execute("DROP TRIGGER deny_move_ack")\ndb.commit()\n',
      vault,
    ]);
    expect(drop.exitCode, 0, reason: drop.stderr.toString());
    await rust.acknowledgeRemoteMove(
      sourceId: a.id!,
      targetId: b.id!,
      taskId: id,
      ticket: current.ticket,
    );
    final ended = await remoteTask(id, (_) => true);
    expect(ended.state, 'Cancelled');
    expect(ended.remoteMovePhase, 'UserEnded');
    expect(
      ended.completed,
      0,
      reason: 'manual ending is not a server acknowledgement of success',
    );
    await expectLater(
      rust.acknowledgeRemoteMove(
        sourceId: a.id!,
        targetId: b.id!,
        taskId: id,
        ticket: current.ticket,
      ),
      throwsA(anything),
    );
    await expectLater(
      rust.resumeRemoteCopy(
        sourceId: a.id!,
        targetId: b.id!,
        taskId: id,
        decision: 'continue',
      ),
      throwsA(anything),
    );
    expect(await source.readAsBytes(), recreated);
    expect(await target.readAsBytes(), original);
    expect(await count.readAsLines(), ['1']);
    final editor = rust.reserveEditor(
      id: a.id!,
      generation: a.generation,
      path: source.path,
    );
    await rust.prepareEditor(
      editorId: editor,
      operation: rust.beginEditorOperation(editorId: editor),
    );
    await rust.closeEditor(editorId: editor, keepDraft: false);
    await rust.clearEndedRemoteCopies();
    expect(await rust.listRemoteCopies(), isEmpty);
    await rust.unlockVault(path: vault, password: master);
    expect(await rust.listRemoteCopies(), isEmpty);
    final audit = await Process.run('python3', [
      '-c',
      'import sqlite3,sys\ndb=sqlite3.connect(sys.argv[1])\n'
          'print(db.execute("SELECT count(*) FROM records WHERE id=?", ("local-remote-transfer-"+sys.argv[2],)).fetchone()[0])\n',
      vault,
      id,
    ]);
    expect(audit.exitCode, 0);
    expect(audit.stdout.toString().trim(), '1');
    expect(
      a.reconnectCount,
      1,
      reason: 'only the one explicit reconnect above',
    );
    expect(b.reconnectCount, 0);
  } finally {
    await a.shutdown();
    a.dispose();
    await b.shutdown();
    b.dispose();
    await server.close();
  }
}

void main() {
  test(
    'real OpenSSH lost RENAME reply cannot move a recreated source or discard its unresolved record',
    exerciseUncertainMove,
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
