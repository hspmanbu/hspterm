import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/transfers.dart' as jobs;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';
import 'transfer_bridge_test.dart' show waitTask;

Future<jobs.TransferTaskView> remoteTask(
  String id,
  bool Function(jobs.TransferTaskView) ready,
) async {
  final end = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    final task = (await rust.listRemoteCopies()).singleWhere((t) => t.id == id);
    if (ready(task)) return task;
    if (DateTime.now().isAfter(end)) {
      throw StateError('remote copy timeout: ${task.state}: ${task.error}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> exerciseRemoteCopies() async {
  await initializeRust();
  final sourceServer = await LocalSshd.start();
  final targetServer = await LocalSshd.start();
  final a = TerminalController(const NativeTerminalBackend());
  final b = TerminalController(const NativeTerminalBackend());
  final vault = '${sourceServer.directory.path}/remote-copy.vault';
  const master = 'synthetic remote copy test master';
  try {
    await rust.unlockVault(path: vault, password: master);
    Future<String> connect(LocalSshd server, TerminalController c) async {
      final p = await rust.saveProfile(
        profile: rust.Profile(
          id: '',
          name: 'Remote copy fixture',
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
      await c.connect(p.id);
      await waitFor(() => c.connected, 'remote-copy SSH: ${c.error}');
      return p.id;
    }

    await connect(sourceServer, a);
    await connect(targetServer, b);
    final source = Directory('${sourceServer.directory.path}/source 中文');
    await Directory('${source.path}/empty/nested').create(recursive: true);
    await File('${source.path}/中文.txt').writeAsString('中文e\u0301\u0000正文');
    final target = Directory('${targetServer.directory.path}/destination 中文');
    await expectLater(
      rust.enqueueRemoteCopy(
        sourceId: a.id!,
        targetId: b.id!,
        source: source.path,
        destination: target.path,
        allowMemoryRelay: false,
      ),
      throwsA(anything),
    );
    expect(await target.exists(), false);
    expect(await rust.listRemoteCopies(), isEmpty);
    await expectLater(
      rust.enqueueRemoteCopy(
        sourceId: a.id!,
        targetId: b.id!,
        source: source.path,
        destination: target.path,
        allowMemoryRelay: true,
        expectedSourceGeneration: a.generation + 1,
        expectedTargetGeneration: b.generation,
      ),
      throwsA(anything),
    );
    await expectLater(
      rust.enqueueRemoteCopy(
        sourceId: a.id!,
        targetId: b.id!,
        source: source.path,
        destination: target.path,
        allowMemoryRelay: true,
        expectedSourceGeneration: a.generation,
        expectedTargetGeneration: b.generation + 1,
      ),
      throwsA(anything),
    );
    expect(await rust.listRemoteCopies(), isEmpty);
    final id = await rust.enqueueRemoteCopy(
      sourceId: a.id!,
      targetId: b.id!,
      source: source.path,
      destination: target.path,
      allowMemoryRelay: true,
    );
    final done = await remoteTask(id, (t) => !t.busy);
    expect(done.state, 'Complete', reason: done.error);
    expect(done.sourceRemote, source.path);
    expect(done.sourceTerminalId, a.id);
    expect(done.terminalId, b.id);
    expect(await Directory('${target.path}/empty/nested').exists(), true);
    expect(
      await File('${target.path}/中文.txt').readAsString(),
      '中文e\u0301\u0000正文',
    );
    await rust.clearEndedRemoteCopies();

    // Rescan intent survives a failed candidate publication and vault reopen.
    // The trigger affects only this disposable encrypted task record.
    final rescanSource = Directory(
      '${sourceServer.directory.path}/rescan source',
    );
    final rescanTarget = Directory(
      '${targetServer.directory.path}/rescan target',
    );
    await Directory('${rescanSource.path}/broken/nested')
        .create(recursive: true);
    await Directory('${rescanSource.path}/done').create();
    await rescanTarget.create();
    await File('${rescanSource.path}/done/success')
        .writeAsString('completed sibling');
    await File('${rescanSource.path}/broken/old').writeAsString('old child');
    await File('${rescanSource.path}/broken/nested/deep')
        .writeAsString('deep child');
    await File('${rescanTarget.path}/broken')
        .writeAsString('explicit fixture obstacle');
    final rescanId = await rust.enqueueRemoteCopy(
      sourceId: a.id!,
      targetId: b.id!,
      source: rescanSource.path,
      destination: rescanTarget.path,
      allowMemoryRelay: true,
    );
    expect((await remoteTask(rescanId, (t) => !t.busy)).state, 'Partial');
    final rescanFailures = await rust.remoteCopyFailures(
      taskId: rescanId,
      offset: 0,
      limit: 256,
    );
    final broken = rescanFailures.singleWhere((f) => f.path == 'broken');
    expect(
      broken.rescan,
      true,
      reason:
          'a failed directory must offer a metadata rescan, not a file retry',
    );
    final oldNodes = (await remoteTask(rescanId, (_) => true)).discovered;
    await Directory('${rescanSource.path}/done').delete(recursive: true);
    await File('${rescanTarget.path}/done/success')
        .writeAsString('later target change');
    await File('${rescanSource.path}/broken/new 中文 e\u0301')
        .writeAsString('new discovery');
    await File('${rescanTarget.path}/broken').delete();
    final heldSource = File('${sourceServer.directory.path}/rescan held local');
    await heldSource.writeAsBytes(List.filled(65536, 13));
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 1,
        uploadBytesPerSecond: 1,
        downloadBytesPerSecond: 1,
      ),
    );
    final heldScan = await rust.enqueueTransfer(
      id: a.id!,
      local: heldSource.path,
      remote: '${sourceServer.directory.path}/rescan held remote',
      upload: true,
    );
    await waitTask(heldScan, (t) => t.busy && t.acknowledged > 0);
    await rust.resumeRemoteCopy(
      sourceId: a.id!,
      targetId: b.id!,
      taskId: rescanId,
      node: broken.node,
      decision: 'rescan',
    );
    expect((await remoteTask(rescanId, (_) => true)).state, 'Waiting');
    expect(RegExp(r'^task-[0-9a-f]{32}$').hasMatch(rescanId), true);
    final trigger = await Process.run('python3', [
      '-c',
      'import sqlite3,sys\n'
          'db=sqlite3.connect(sys.argv[1])\n'
          'db.execute("CREATE TRIGGER deny_rescan_candidate BEFORE INSERT ON records WHEN NEW.id=\'local-remote-transfer-"+sys.argv[2]+"\' BEGIN SELECT RAISE(ABORT, \'synthetic candidate publication failure\'); END;")\n'
          'db.commit()\n',
      vault,
      rescanId,
    ]);
    expect(trigger.exitCode, 0, reason: trigger.stderr.toString());
    await rust.stopTransfer(taskId: heldScan, cancel: false);
    expect((await remoteTask(rescanId, (t) => !t.busy)).state, 'Failed');
    expect(await Directory('${rescanTarget.path}/broken').exists(), false);
    expect((await remoteTask(rescanId, (_) => true)).discovered, oldNodes);
    final drop = await Process.run('python3', [
      '-c',
      'import sqlite3,sys\ndb=sqlite3.connect(sys.argv[1])\ndb.execute("DROP TRIGGER deny_rescan_candidate")\ndb.commit()\n',
      vault,
    ]);
    expect(drop.exitCode, 0, reason: drop.stderr.toString());
    await rust.unlockVault(path: vault, password: master);
    expect((await remoteTask(rescanId, (_) => true)).state, 'Paused');
    expect(await Directory('${rescanTarget.path}/broken').exists(), false);
    await expectLater(
      rust.resumeRemoteCopy(
        sourceId: a.id!,
        targetId: a.id!,
        taskId: rescanId,
        decision: 'continue',
      ),
      throwsA(anything),
    );
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 3,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
      ),
    );
    for (final mismatchSource in [true, false]) {
      await expectLater(
        rust.resumeRemoteCopy(
          sourceId: a.id!,
          targetId: b.id!,
          sourceGeneration: a.generation + (mismatchSource ? 1 : 0),
          targetGeneration: b.generation + (mismatchSource ? 0 : 1),
          taskId: rescanId,
          decision: 'continue',
        ),
        throwsA(anything),
      );
      expect((await remoteTask(rescanId, (t) => !t.busy)).state, 'Paused');
      expect(await Directory('${rescanTarget.path}/broken').exists(), false);
    }
    await rust.resumeRemoteCopy(
      sourceId: a.id!,
      targetId: b.id!,
      sourceGeneration: a.generation,
      targetGeneration: b.generation,
      taskId: rescanId,
      decision: 'continue',
    );
    final rescanned = await remoteTask(rescanId, (t) => !t.busy);
    expect(rescanned.state, 'Complete', reason: rescanned.error);
    expect(rescanned.discovered, oldNodes + 1);
    expect(
      await File('${rescanTarget.path}/done/success').readAsString(),
      'later target change',
    );
    expect(
      await File('${rescanTarget.path}/broken/new 中文 e\u0301').readAsString(),
      'new discovery',
    );
    expect(
      await File('${rescanTarget.path}/broken/nested/deep').readAsString(),
      'deep child',
    );
    await rust.stopTransfer(taskId: heldScan, cancel: true);
    await rust.clearEndedTransfers();
    await rust.clearEndedRemoteCopies();

    final retryAllTarget = Directory(
      '${targetServer.directory.path}/retry all target',
    );
    await retryAllTarget.create();
    await File('${retryAllTarget.path}/broken')
        .writeAsString('retry-all obstacle');
    final retryAllId = await rust.enqueueRemoteCopy(
      sourceId: a.id!,
      targetId: b.id!,
      source: rescanSource.path,
      destination: retryAllTarget.path,
      allowMemoryRelay: true,
    );
    expect((await remoteTask(retryAllId, (t) => !t.busy)).state, 'Partial');
    final failedFile = (await rust.remoteCopyFailures(
      taskId: retryAllId,
      offset: 0,
      limit: 256,
    )).singleWhere((f) => f.path == 'broken/old');
    expect(failedFile.rescan, false);
    await expectLater(
      rust.resumeRemoteCopy(
        sourceId: a.id!,
        targetId: b.id!,
        taskId: retryAllId,
        node: failedFile.node,
        decision: 'rescan',
      ),
      throwsA(anything),
    );
    expect((await remoteTask(retryAllId, (_) => true)).state, 'Partial');
    expect(
      await File('${retryAllTarget.path}/broken').readAsString(),
      'retry-all obstacle',
    );
    await File('${retryAllTarget.path}/broken').delete();
    await File('${rescanSource.path}/broken/all new')
        .writeAsString('discovered by whole-task retry');
    await rust.resumeRemoteCopy(
      sourceId: a.id!,
      targetId: b.id!,
      taskId: retryAllId,
      decision: 'retry',
    );
    final retriedAll = await remoteTask(retryAllId, (t) => !t.busy);
    expect(retriedAll.state, 'Complete', reason: retriedAll.error);
    expect(
      await File('${retryAllTarget.path}/broken/all new').readAsString(),
      'discovered by whole-task retry',
    );
    expect(
      await File('${retryAllTarget.path}/broken/old').readAsString(),
      'old child',
    );
    await rust.clearEndedRemoteCopies();

    final bytes = List<int>.generate(256 * 1024 + 23, (i) => i % 251);
    final file = File('${sourceServer.directory.path}/large.bin');
    await file.writeAsBytes(bytes);
    final output = File('${targetServer.directory.path}/large.bin');
    // An upload and a remote tree consume the same FIFO, rather than each
    // creating a private concurrency pool. The policy is fixed at enqueue.
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 1,
        uploadBytesPerSecond: 1,
        downloadBytesPerSecond: 1,
        defaultConflict: 'skip',
      ),
    );
    final held = await rust.enqueueTransfer(
      id: b.id!,
      local: file.path,
      remote: '${output.path}.held',
      upload: true,
    );
    await waitTask(held, (t) => t.busy && t.acknowledged > 0);
    final protected = File('${output.path}.protected');
    await protected.writeAsString('keep existing target');
    final queued = await rust.enqueueRemoteCopy(
      sourceId: a.id!,
      targetId: b.id!,
      source: file.path,
      destination: protected.path,
      allowMemoryRelay: true,
    );
    expect((await remoteTask(queued, (_) => true)).state, 'Waiting');
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 1,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
        defaultConflict: 'overwrite',
      ),
    );
    await rust.stopTransfer(taskId: held, cancel: false);
    expect(
      (await remoteTask(queued, (t) => !t.busy)).state,
      'CompleteWithSkips',
    );
    expect(await protected.readAsString(), 'keep existing target');
    await rust.stopTransfer(taskId: held, cancel: true);
    await rust.clearEndedTransfers();
    await rust.clearEndedRemoteCopies();
    // Default rename chooses a free basename and persists the effective root;
    // a later setting change never reinterprets an already queued decision.
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 3,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
        defaultConflict: 'rename',
      ),
    );
    final renamed = await rust.enqueueRemoteCopy(
      sourceId: a.id!,
      targetId: b.id!,
      source: file.path,
      destination: protected.path,
      allowMemoryRelay: true,
    );
    final renamedTask = await remoteTask(renamed, (t) => !t.busy);
    expect(renamedTask.state, 'Complete', reason: renamedTask.error);
    expect(
      renamedTask.remote,
      '${targetServer.directory.path}/large.bin (1).protected',
    );
    expect(await File(renamedTask.remote).readAsBytes(), bytes);
    expect(await protected.readAsString(), 'keep existing target');
    await rust.clearEndedRemoteCopies();
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 1,
        uploadBytesPerSecond: 4096,
        downloadBytesPerSecond: 4096,
        defaultConflict: 'ask',
      ),
    );
    final paused = await rust.enqueueRemoteCopy(
      sourceId: a.id!,
      targetId: b.id!,
      source: file.path,
      destination: output.path,
      allowMemoryRelay: true,
    );
    await remoteTask(paused, (t) => t.busy && t.acknowledged > 0);
    await expectLater(
      rust.unlockVault(path: vault, password: master),
      throwsA(anything),
    );
    await rust.stopRemoteCopy(taskId: paused, cancel: false);
    expect((await remoteTask(paused, (t) => !t.busy)).state, 'Paused');
    expect(await output.exists(), false); // unpublished partial snapshot
    await expectLater(
      rust.resumeRemoteCopy(
        sourceId: b.id!,
        targetId: b.id!,
        taskId: paused,
        node: null,
        decision: 'continue',
        rename: null,
      ),
      throwsA(anything),
    );
    final sourceGeneration = a.generation, targetGeneration = b.generation;
    await rust.unlockVault(path: vault, password: master);
    final restored = (await rust.listRemoteCopies()).single;
    expect(restored.id, paused);
    expect(restored.state, 'Paused');
    expect(restored.busy, false);
    expect(restored.terminalId, isNull);
    expect(restored.sourceTerminalId, isNull);
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 3,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
      ),
    );
    await rust.resumeRemoteCopy(
      sourceId: a.id!,
      targetId: b.id!,
      taskId: paused,
      node: null,
      decision: 'continue',
      rename: null,
    );
    final resumed = await remoteTask(paused, (t) => !t.busy);
    expect(resumed.state, 'Complete', reason: resumed.error);
    expect(await output.readAsBytes(), bytes);
    expect(a.generation, sourceGeneration);
    expect(b.generation, targetGeneration);
    await rust.clearEndedRemoteCopies();

    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 1,
        uploadBytesPerSecond: 1,
        downloadBytesPerSecond: 1,
      ),
    );
    final disconnected = await rust.enqueueRemoteCopy(
      sourceId: a.id!,
      targetId: b.id!,
      source: file.path,
      destination: '${output.path}.disconnect',
      allowMemoryRelay: true,
    );
    await remoteTask(disconnected, (t) => t.busy && t.acknowledged > 0);
    await rust.disconnectTerminal(id: a.id!);
    expect((await remoteTask(disconnected, (t) => !t.busy)).state, 'Paused');
    expect(b.connected, true);
    final raw = String.fromCharCodes(await File(vault).readAsBytes());
    expect(raw.contains('large.bin'), false);
    expect(raw.contains(sourceServer.privateKey), false);
  } finally {
    await a.shutdown();
    a.dispose();
    await b.shutdown();
    b.dispose();
    await sourceServer.close();
    await targetServer.close();
  }
}

void main() {
  test(
    'real FRB remote copies bind two servers and restore private snapshots explicitly',
    exerciseRemoteCopies,
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isLinux,
  );
}
