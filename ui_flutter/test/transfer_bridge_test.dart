import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/transfers.dart' as jobs;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

Future<jobs.TransferTaskView> waitTask(
  String id,
  bool Function(jobs.TransferTaskView) condition,
) async {
  final until = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    final task = (await rust.listTransferTasks()).singleWhere(
      (t) => t.id == id,
    );
    if (condition(task)) return task;
    if (DateTime.now().isAfter(until)) {
      throw StateError('transfer timeout: ${task.state} / ${task.error}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> exerciseTransfers() async {
  await initializeRust();
  final server = await LocalSshd.start();
  final c = TerminalController(const NativeTerminalBackend());
  final other = TerminalController(const NativeTerminalBackend());
  final master = 'test-only-transfer-vault-master';
  final vault = '${server.directory.path}/transfers.vault';
  try {
    await rust.unlockVault(path: vault, password: master);
    expect(await rust.listTransferTasks(), isEmpty);
    final defaults = await rust.transferPreferences();
    expect(defaults.concurrency, 3);
    expect(defaults.uploadBytesPerSecond, 0);
    expect(defaults.defaultConflict, 'ask');
    await expectLater(
      rust.saveTransferPreferences(
        value: jobs.TransferPreferences(
          concurrency: 0,
          uploadBytesPerSecond: 0,
          downloadBytesPerSecond: 0,
        ),
      ),
      throwsA(anything),
    );
    expect((await rust.transferPreferences()).concurrency, 3);

    var profile = await rust.saveProfile(
      profile: rust.Profile(
        id: '',
        name: 'Transfer fixture',
        address: '127.0.0.1',
        port: server.port,
        username: server.username,
        privateKey: true,
      ),
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );
    c.confirmHostKey = (_) async => true;
    other.confirmHostKey = (_) async => true;
    await c.start();
    await c.connect(profile.id);
    await waitFor(() => c.connected, 'transfer SSH');

    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 1,
        uploadBytesPerSecond: 1,
        downloadBytesPerSecond: 32768,
      ),
    );
    final limited = File('${server.directory.path}/limited.bin');
    await limited.writeAsBytes(List.filled(65536, 42));
    final limitedIds = <String>[];
    for (var i = 0; i < 3; i++) {
      limitedIds.add(
        await rust.enqueueTransfer(
          id: c.id!,
          local: limited.path,
          remote: '${server.directory.path}/limited-$i.bin',
          upload: true,
        ),
      );
    }
    await waitTask(
      limitedIds.first,
      (t) => t.state == 'Running' && t.acknowledged > 0,
    );
    expect(
      (await rust.listTransferTasks())
          .where((t) => t.state == 'Waiting')
          .length,
      2,
    );
    await c.text("printf '%s%s\\n' LIMIT_ PTY\n");
    await waitFor(
      () => screen(c).contains('LIMIT_PTY'),
      'PTY while limiter waiting',
    );
    // Cancellation must wake a low-rate waiter without waiting one second.
    await rust.stopTransfer(taskId: limitedIds.first, cancel: false);
    expect((await waitTask(limitedIds.first, (t) => !t.busy)).state, 'Paused');
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 2,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 32768,
      ),
    );
    await rust.resumeTransfer(
      id: c.id!,
      taskId: limitedIds.first,
      decision: 'continue',
    );
    for (var i = 0; i < 3; i++) {
      expect((await waitTask(limitedIds[i], (t) => !t.busy)).state, 'Complete');
      expect(
        await File('${server.directory.path}/limited-$i.bin').readAsBytes(),
        await limited.readAsBytes(),
      );
    }
    await rust.clearEndedTransfers();
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 2,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
      ),
    );
    final source = File('${server.directory.path}/source.bin');
    final block = Uint8List.fromList(List.generate(65536, (i) => i % 251));
    final file = await source.open(mode: FileMode.write);
    for (var i = 0; i < 512; i++) {
      await file.writeFrom(block);
    }
    await file.close();
    final remote = File('${server.directory.path}/remote.bin');
    final id = await rust.enqueueTransfer(
      id: c.id!,
      local: source.path,
      remote: remote.path,
      upload: true,
    );
    await waitTask(id, (t) => t.busy && t.acknowledged > 0);
    await rust.stopTransfer(taskId: id, cancel: false);
    var paused = await waitTask(id, (t) => !t.busy);
    expect(paused.state, 'Paused');
    expect(paused.acknowledged, greaterThan(0));
    expect(paused.acknowledged, lessThan(await source.length()));
    expect(await remote.length(), greaterThanOrEqualTo(paused.acknowledged));
    final beforeSwitch = c.generation;
    // Reopening the encrypted store resets only runtime task state. No SSH or
    // transfer is resumed by discovery; attaching requires an explicit action.
    await rust.unlockVault(path: vault, password: master);
    paused = (await rust.listTransferTasks()).single;
    final persisted = await rust.transferPreferences();
    expect(persisted.concurrency, 2);
    expect(persisted.downloadBytesPerSecond, 0);
    expect(paused.terminalId, isNull);
    expect(paused.state, 'Paused');
    expect(c.generation, beforeSwitch);
    final checkpoint = await remote.length();
    profile = await rust.saveProfile(
      profile: rust.Profile(
        id: profile.id,
        name: profile.name,
        address: 'localhost',
        port: profile.port,
        username: profile.username,
        privateKey: true,
      ),
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );
    await other.start();
    await other.connect(profile.id);
    await waitFor(() => other.connected, 'different actual target');
    await expectLater(
      rust.resumeTransfer(id: other.id!, taskId: id, decision: 'continue'),
      throwsA(anything),
    );
    expect(await remote.length(), checkpoint);
    // The original transport still has its original target, independent of the
    // edited host config. Resume never reads that edited target as its identity.
    await expectLater(
      rust.resumeTransfer(
        id: c.id!,
        generation: c.generation + 1,
        taskId: id,
        decision: 'continue',
      ),
      throwsA(anything),
    );
    expect((await waitTask(id, (t) => !t.busy)).state, 'Paused');
    expect(await remote.length(), checkpoint);
    await rust.resumeTransfer(
      id: c.id!,
      generation: c.generation,
      taskId: id,
      decision: 'continue',
    );
    final complete = await waitTask(id, (t) => !t.busy);
    expect(complete.state, 'Complete', reason: complete.error);
    expect(await remote.readAsBytes(), await source.readAsBytes());
    expect(c.generation, beforeSwitch);
    // The same transport's PTY remains responsive during/after transfer work.
    await c.text("printf '%s%s\\n' TRANSFER_ PTY\n");
    await waitFor(
      () => screen(c).contains('TRANSFER_PTY'),
      'PTY after transfer',
    );

    final folder = Directory('${server.directory.path}/folder 中文');
    await Directory('${folder.path}/empty').create(recursive: true);
    await File('${folder.path}/a.txt').writeAsString('new a');
    await File('${folder.path}/z.txt').writeAsString('successful sibling');
    for (final name in ['b-conflict.txt', 'c-conflict.txt', 'd-failure.txt']) {
      await File('${folder.path}/$name').writeAsString('new $name');
    }
    final target = Directory('${server.directory.path}/folder-target');
    await target.create();
    await File('${target.path}/a.txt').writeAsString('keep original');
    for (final name in ['b-conflict.txt', 'c-conflict.txt']) {
      await File('${target.path}/$name').writeAsString('old $name');
    }
    await Directory('${target.path}/d-failure.txt').create();
    final treeId = await rust.enqueueTransfer(
      id: c.id!,
      local: folder.path,
      remote: target.path,
      upload: true,
    );
    final partial = await waitTask(treeId, (t) => !t.busy);
    expect(partial.state, 'Partial', reason: partial.error);
    expect(partial.folder, true);
    expect(partial.conflicts, 3);
    expect(partial.failed, 1);
    final failures = await rust.transferFailures(
      taskId: treeId,
      offset: 0,
      limit: 100,
    );
    final aFailure = failures.singleWhere((f) => f.path == 'a.txt');
    expect(aFailure.conflict, true);
    await expectLater(
      rust.resumeTransfer(
        id: c.id!,
        taskId: treeId,
        node: aFailure.node,
        decision: 'unknown-action',
        rename: 'must-not-be-created',
      ),
      throwsA(anything),
    );
    await expectLater(
      rust.resumeTransfer(
        id: c.id!,
        taskId: treeId,
        decision: 'retry',
        rename: 'ambiguous-batch-name',
      ),
      throwsA(anything),
    );
    expect(await File('${target.path}/must-not-be-created').exists(), false);
    expect(await File('${target.path}/a.txt').readAsString(), 'keep original');
    await File('${folder.path}/z.txt').delete();
    await rust.resumeTransfer(
      id: c.id!,
      taskId: treeId,
      node: aFailure.node,
      decision: 'retry',
      rename: 'renamed 中文.txt',
    );
    expect((await waitTask(treeId, (t) => !t.busy)).state, 'Partial');
    await expectLater(
      rust.resumeTransfer(
        id: c.id!,
        taskId: treeId,
        node: aFailure.node,
        decision: 'overwrite_conflicts',
      ),
      throwsA(anything),
    );
    await rust.resumeTransfer(
      id: c.id!,
      taskId: treeId,
      decision: 'overwrite_conflicts',
    );
    final afterBatch = await waitTask(treeId, (t) => !t.busy);
    expect(afterBatch.state, 'Partial');
    expect(afterBatch.conflicts, 0);
    expect(afterBatch.failed, 1);
    for (final name in ['b-conflict.txt', 'c-conflict.txt']) {
      expect(await File('${target.path}/$name').readAsString(), 'new $name');
    }
    expect(await Directory('${target.path}/d-failure.txt').exists(), true);
    await expectLater(
      rust.resumeTransfer(
        id: c.id!,
        taskId: treeId,
        decision: 'overwrite_conflicts',
      ),
      throwsA(anything),
    );
    final failedFile = (await rust.transferFailures(
      taskId: treeId,
      offset: 0,
      limit: 100,
    )).single;
    expect(failedFile.conflict, false);
    await Directory('${target.path}/d-failure.txt').delete();
    await rust.resumeTransfer(
      id: c.id!,
      taskId: treeId,
      node: failedFile.node,
      decision: 'retry',
    );
    expect((await waitTask(treeId, (t) => !t.busy)).state, 'Complete');
    expect(await File('${target.path}/a.txt').readAsString(), 'keep original');
    expect(await File('${target.path}/renamed 中文.txt').readAsString(), 'new a');
    expect(
      await File('${target.path}/z.txt').readAsString(),
      'successful sibling',
    );
    expect(await Directory('${target.path}/empty').exists(), true);
    final download = Directory('${server.directory.path}/downloaded');
    final downloadId = await rust.enqueueTransfer(
      id: c.id!,
      local: download.path,
      remote: target.path,
      upload: false,
    );
    expect((await waitTask(downloadId, (t) => !t.busy)).state, 'Complete');
    expect(
      await File('${download.path}/renamed 中文.txt').readAsString(),
      'new a',
    );
    expect(await Directory('${download.path}/empty').exists(), true);

    // Single-file renames must report the actual target, retaining the source.
    final singleSource = File('${server.directory.path}/single-source.txt');
    final singleRemote = File('${server.directory.path}/single-target.txt');
    await singleSource.writeAsString('new root contents');
    await singleRemote.writeAsString('keep root target');
    final rootId = await rust.enqueueTransfer(
      id: c.id!,
      local: singleSource.path,
      remote: singleRemote.path,
      upload: true,
    );
    expect((await waitTask(rootId, (t) => !t.busy)).conflicts, 1);
    await rust.resumeTransfer(
      id: c.id!,
      taskId: rootId,
      node: 0,
      decision: 'retry',
      rename: 'renamed-root.txt',
    );
    final renamedRoot = await waitTask(rootId, (t) => !t.busy);
    expect(renamedRoot.state, 'Complete');
    expect(renamedRoot.remote, '${server.directory.path}/renamed-root.txt');
    expect(renamedRoot.local, singleSource.path);
    expect(await singleRemote.readAsString(), 'keep root target');
    final rootDownload = File('${server.directory.path}/root-downloaded.txt');
    await rootDownload.writeAsString('keep local root');
    final rootDownId = await rust.enqueueTransfer(
      id: c.id!,
      local: rootDownload.path,
      remote: renamedRoot.remote,
      upload: false,
    );
    expect((await waitTask(rootDownId, (t) => !t.busy)).conflicts, 1);
    await rust.resumeTransfer(
      id: c.id!,
      taskId: rootDownId,
      node: 0,
      decision: 'retry',
      rename: 'renamed-download.txt',
    );
    final renamedDown = await waitTask(rootDownId, (t) => !t.busy);
    expect(renamedDown.state, 'Complete');
    expect(renamedDown.local, '${server.directory.path}/renamed-download.txt');
    expect(renamedDown.remote, renamedRoot.remote);
    expect(await File(renamedDown.local).readAsString(), 'new root contents');
    expect(await rootDownload.readAsString(), 'keep local root');

    final skipFolder = Directory('${server.directory.path}/skip-source');
    final skipTarget = Directory('${server.directory.path}/skip-target');
    await skipFolder.create();
    await skipTarget.create();
    for (final name in ['one', 'two']) {
      await File('${skipFolder.path}/$name').writeAsString('new $name');
      await File('${skipTarget.path}/$name').writeAsString('keep $name');
    }
    final skipId = await rust.enqueueTransfer(
      id: c.id!,
      local: skipFolder.path,
      remote: skipTarget.path,
      upload: true,
    );
    expect((await waitTask(skipId, (t) => !t.busy)).conflicts, 2);
    await rust.resumeTransfer(
      id: c.id!,
      taskId: skipId,
      decision: 'skip_conflicts',
    );
    final skipped = await waitTask(skipId, (t) => !t.busy);
    expect(skipped.state, 'CompleteWithSkips');
    expect(skipped.skipped, 2);
    for (final name in ['one', 'two']) {
      expect(
        await File('${skipTarget.path}/$name').readAsString(),
        'keep $name',
      );
    }

    // Batch rename is scoped to current conflicts. Its metadata intent also
    // survives a queued pause/reopen, without copying successful siblings.
    final renameSource = Directory('${server.directory.path}/rename-source');
    final renameTarget = Directory('${server.directory.path}/rename-target');
    await renameSource.create();
    await renameTarget.create();
    for (final name in ['a.txt', 'a (1).txt', '.env', 'success', 'failure']) {
      await File('${renameSource.path}/$name').writeAsString('new $name');
    }
    for (final name in ['a.txt', 'a (2).txt', '.env']) {
      await File('${renameTarget.path}/$name').writeAsString('old $name');
    }
    await Directory('${renameTarget.path}/failure').create();
    final renameId = await rust.enqueueTransfer(
      id: c.id!,
      local: renameSource.path,
      remote: renameTarget.path,
      upload: true,
    );
    final renamePartial = await waitTask(renameId, (t) => !t.busy);
    expect(renamePartial.conflicts, 2);
    expect(renamePartial.failed, 1);
    await expectLater(
      rust.resumeTransfer(
        id: c.id!,
        taskId: renameId,
        node: 1,
        decision: 'rename_conflicts',
      ),
      throwsA(anything),
    );
    await File('${renameSource.path}/success').delete();
    await File('${renameSource.path}/a (1).txt').delete();
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 1,
        uploadBytesPerSecond: 1,
        downloadBytesPerSecond: 0,
      ),
    );
    final renameBlocker = await rust.enqueueTransfer(
      id: c.id!,
      local: limited.path,
      remote: '${server.directory.path}/rename-blocker',
      upload: true,
    );
    await waitTask(renameBlocker, (t) => t.state == 'Running');
    await rust.resumeTransfer(
      id: c.id!,
      taskId: renameId,
      decision: 'rename_conflicts',
    );
    await rust.stopTransfer(taskId: renameId, cancel: false);
    await rust.stopTransfer(taskId: renameBlocker, cancel: true);
    await rust.unlockVault(path: vault, password: master);
    final renamedWaiting = (await rust.listTransferTasks()).single;
    expect(renamedWaiting.id, renameId);
    expect(renamedWaiting.state, 'Paused');
    expect(renamedWaiting.total, isNull);
    expect(await File('${renameTarget.path}/a (3).txt').exists(), false);
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 2,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
      ),
    );
    await rust.resumeTransfer(
      id: c.id!,
      taskId: renameId,
      decision: 'continue',
    );
    final renamedBatch = await waitTask(renameId, (t) => !t.busy);
    expect(renamedBatch.state, 'Partial');
    expect(renamedBatch.conflicts, 0);
    expect(renamedBatch.failed, 1);
    expect(
      await File('${renameTarget.path}/a (3).txt').readAsString(),
      'new a.txt',
    );
    expect(
      await File('${renameTarget.path}/a.txt').readAsString(),
      'old a.txt',
    );
    expect(
      await File('${renameTarget.path}/.env (1)').readAsString(),
      'new .env',
    );
    expect(
      await File('${renameTarget.path}/success').readAsString(),
      'new success',
    );
    await Directory('${renameTarget.path}/failure').delete();
    final remainingFailure = (await rust.transferFailures(
      taskId: renameId,
      offset: 0,
      limit: 50,
    )).single;
    await rust.resumeTransfer(
      id: c.id!,
      taskId: renameId,
      node: remainingFailure.node,
      decision: 'retry',
    );
    expect((await waitTask(renameId, (t) => !t.busy)).state, 'Complete');
    // Verify bridge header/root target synchronization for automatic root rename.
    final rootBatchId = await rust.enqueueTransfer(
      id: c.id!,
      local: singleSource.path,
      remote: singleRemote.path,
      upload: true,
    );
    expect((await waitTask(rootBatchId, (t) => !t.busy)).conflicts, 1);
    await rust.resumeTransfer(
      id: c.id!,
      taskId: rootBatchId,
      decision: 'rename_conflicts',
    );
    final rootBatch = await waitTask(rootBatchId, (t) => !t.busy);
    expect(rootBatch.state, 'Complete');
    expect(rootBatch.local, singleSource.path);
    expect(rootBatch.remote, '${server.directory.path}/single-target (1).txt');
    expect(
      await File(rootBatch.remote).readAsString(),
      await singleSource.readAsString(),
    );

    // Directory retry must discover missing children without rereading the
    // successful sibling, and its pending intent must survive a vault reopen.
    final rescanSource = Directory('${server.directory.path}/rescan-source');
    final rescanTarget = Directory('${server.directory.path}/rescan-target');
    await Directory('${rescanSource.path}/broken/nested')
        .create(recursive: true);
    await rescanTarget.create();
    await File('${rescanSource.path}/broken/nested/old').writeAsString('old');
    await File('${rescanSource.path}/success').writeAsString('completed');
    await File('${rescanTarget.path}/broken').writeAsString('blocked');
    final rescanId = await rust.enqueueTransfer(
      id: c.id!,
      local: rescanSource.path,
      remote: rescanTarget.path,
      upload: true,
    );
    final rescanPartial = await waitTask(rescanId, (t) => !t.busy);
    expect(rescanPartial.state, 'Partial');
    final directoryFailure = (await rust.transferFailures(
      taskId: rescanId,
      offset: 0,
      limit: 50,
    )).singleWhere((f) => f.path == 'broken');
    expect(directoryFailure.rescan, true);
    await expectLater(
      rust.resumeTransfer(
        id: c.id!,
        taskId: rescanId,
        node: directoryFailure.node,
        decision: 'overwrite',
      ),
      throwsA(anything),
    );
    await File('${rescanSource.path}/success').delete();
    await File('${rescanSource.path}/broken/new 中文').writeAsString('new');
    await File('${rescanTarget.path}/broken').delete();
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 1,
        uploadBytesPerSecond: 1,
        downloadBytesPerSecond: 0,
      ),
    );
    final blockerId = await rust.enqueueTransfer(
      id: c.id!,
      local: limited.path,
      remote: '${server.directory.path}/rescan-blocker',
      upload: true,
    );
    await waitTask(blockerId, (t) => t.state == 'Running');
    await rust.resumeTransfer(
      id: c.id!,
      taskId: rescanId,
      node: directoryFailure.node,
      decision: 'rescan',
    );
    expect((await waitTask(rescanId, (t) => t.busy)).state, 'Waiting');
    await rust.stopTransfer(taskId: rescanId, cancel: false);
    await rust.stopTransfer(taskId: blockerId, cancel: true);
    await rust.clearEndedTransfers();
    await rust.unlockVault(path: vault, password: master);
    final restoredRescan = (await rust.listTransferTasks()).single;
    expect(restoredRescan.id, rescanId);
    expect(restoredRescan.state, 'Paused');
    expect(restoredRescan.terminalId, isNull);
    expect(await Directory('${rescanTarget.path}/broken').exists(), false);
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 2,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
      ),
    );
    await rust.resumeTransfer(
      id: c.id!,
      taskId: rescanId,
      decision: 'continue',
    );
    final rescanned = await waitTask(rescanId, (t) => !t.busy);
    expect(rescanned.state, 'Complete', reason: rescanned.error);
    expect(
      await File('${rescanTarget.path}/success').readAsString(),
      'completed',
    );
    expect(
      await File('${rescanTarget.path}/broken/new 中文').readAsString(),
      'new',
    );
    expect(
      await File('${rescanTarget.path}/broken/nested/old').readAsString(),
      'old',
    );
    expect(c.generation, beforeSwitch);

    // Defaults are captured per task. Changing configuration cannot make an
    // already-queued Ask task overwrite/skip a target without its own decision.
    final policySource = Directory('${server.directory.path}/policy-source');
    await policySource.create();
    await File('${policySource.path}/same.txt').writeAsString('new same');
    await File('${policySource.path}/fresh.txt').writeAsString('fresh');
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 1,
        uploadBytesPerSecond: 1,
        downloadBytesPerSecond: 0,
        defaultConflict: 'ask',
      ),
    );
    final policyBlocker = await rust.enqueueTransfer(
      id: c.id!,
      local: limited.path,
      remote: '${server.directory.path}/policy-blocker',
      upload: true,
    );
    await waitTask(policyBlocker, (t) => t.state == 'Running');
    final askTarget = Directory('${server.directory.path}/policy-ask');
    await askTarget.create();
    await File('${askTarget.path}/same.txt').writeAsString('keep ask');
    final askId = await rust.enqueueTransfer(
      id: c.id!,
      local: policySource.path,
      remote: askTarget.path,
      upload: true,
    );
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 1,
        uploadBytesPerSecond: 1,
        downloadBytesPerSecond: 0,
        defaultConflict: 'skip',
      ),
    );
    final skipPolicyTarget = Directory('${server.directory.path}/policy-skip');
    await skipPolicyTarget.create();
    await File('${skipPolicyTarget.path}/same.txt').writeAsString('keep skip');
    final skipPolicyId = await rust.enqueueTransfer(
      id: c.id!,
      local: policySource.path,
      remote: skipPolicyTarget.path,
      upload: true,
    );
    // Omitting the new optional field preserves it for older callers.
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 2,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
      ),
    );
    expect((await rust.transferPreferences()).defaultConflict, 'skip');
    await rust.stopTransfer(taskId: policyBlocker, cancel: true);
    final askResult = await waitTask(askId, (t) => !t.busy);
    final skipResult = await waitTask(skipPolicyId, (t) => !t.busy);
    expect(askResult.state, 'Partial');
    expect(askResult.conflicts, 1);
    expect(skipResult.state, 'CompleteWithSkips');
    expect(skipResult.skipped, 1);
    expect(
      await File('${skipPolicyTarget.path}/same.txt').readAsString(),
      'keep skip',
    );
    expect(
      await File('${skipPolicyTarget.path}/fresh.txt').readAsString(),
      'fresh',
    );
    expect(await File('${askTarget.path}/same.txt').readAsString(), 'keep ask');
    await rust.resumeTransfer(
      id: c.id!,
      taskId: askId,
      decision: 'skip_conflicts',
    );
    expect((await waitTask(askId, (t) => !t.busy)).state, 'CompleteWithSkips');
    for (final upload in [true, false]) {
      for (final policy in ['skip', 'overwrite', 'rename']) {
        await rust.saveTransferPreferences(
          value: jobs.TransferPreferences(
            concurrency: 2,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            defaultConflict: policy,
          ),
        );
        final prefix = 'default-$policy-${upload ? 'up' : 'down'}';
        final target = File('${server.directory.path}/$prefix.txt');
        await target.writeAsString('keep $policy');
        final task = await rust.enqueueTransfer(
          id: c.id!,
          local: upload ? singleSource.path : target.path,
          remote: upload ? target.path : singleSource.path,
          upload: upload,
        );
        final result = await waitTask(task, (t) => !t.busy);
        expect(
          result.state,
          policy == 'skip' ? 'CompleteWithSkips' : 'Complete',
          reason: result.error,
        );
        if (policy == 'skip') {
          expect(await target.readAsString(), 'keep skip');
          continue;
        }
        final actual = upload ? result.remote : result.local;
        expect(await File(actual).readAsString(), 'new root contents');
        if (policy == 'rename') {
          expect(actual, '${server.directory.path}/$prefix (1).txt');
          expect(await target.readAsString(), 'keep rename');
        } else {
          expect(actual, target.path);
          expect(await target.readAsString(), 'new root contents');
        }
      }
    }
    // A legal maximum-length POSIX basename cannot accept a numeric suffix.
    // The failed automatic preflight leaves a real conflict to resolve manually.
    // Even with Rename captured by this task, a later explicit name collision
    // must remain a conflict instead of silently applying the default again.
    final longName = '${List.filled(251, 'x').join()}.txt';
    final manualSource = File('${policySource.path}/$longName');
    final manualTargetDir = Directory('${server.directory.path}/manual-policy');
    await manualTargetDir.create();
    await manualSource.writeAsString('manual priority source');
    await File('${manualTargetDir.path}/$longName')
        .writeAsString('preserved long target');
    final manualId = await rust.enqueueTransfer(
      id: c.id!,
      local: manualSource.path,
      remote: '${manualTargetDir.path}/$longName',
      upload: true,
    );
    final defaultFailed = await waitTask(manualId, (t) => !t.busy);
    expect(defaultFailed.state, 'Failed');
    expect(defaultFailed.conflicts, 1);
    await File('${manualTargetDir.path}/manual-existing.txt')
        .writeAsString('keep manual');
    await rust.resumeTransfer(
      id: c.id!,
      taskId: manualId,
      node: 0,
      decision: 'retry',
      rename: 'manual-existing.txt',
    );
    final explicitConflict = await waitTask(manualId, (t) => !t.busy);
    expect(explicitConflict.state, 'Partial');
    expect(explicitConflict.conflicts, 1);
    expect(
      await File('${manualTargetDir.path}/manual-existing.txt').readAsString(),
      'keep manual',
    );
    expect(
      await File('${manualTargetDir.path}/manual-existing (1).txt').exists(),
      false,
    );
    await rust.resumeTransfer(
      id: c.id!,
      taskId: manualId,
      node: 0,
      decision: 'retry',
      rename: 'manual-new.txt',
    );
    final explicitComplete = await waitTask(manualId, (t) => !t.busy);
    expect(explicitComplete.state, 'Complete');
    expect(
      await File(explicitComplete.remote).readAsString(),
      'manual priority source',
    );

    await expectLater(
      rust.saveTransferPreferences(
        value: const jobs.TransferPreferences(
          concurrency: 2,
          uploadBytesPerSecond: 0,
          downloadBytesPerSecond: 0,
          defaultConflict: 'future_unsupported_policy',
        ),
      ),
      throwsA(anything),
    );
    expect((await rust.transferPreferences()).defaultConflict, 'rename');
    await rust.unlockVault(path: vault, password: master);
    expect((await rust.transferPreferences()).defaultConflict, 'rename');
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 2,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
        defaultConflict: 'ask',
      ),
    );

    final cancelPath = File('${server.directory.path}/cancelled.bin');
    final cancelled = await rust.enqueueTransfer(
      id: c.id!,
      local: source.path,
      remote: cancelPath.path,
      upload: true,
    );
    await waitTask(cancelled, (t) => t.busy && t.acknowledged > 0);
    await rust.stopTransfer(taskId: cancelled, cancel: true);
    expect((await waitTask(cancelled, (t) => !t.busy)).state, 'Cancelled');
    expect(await cancelPath.length(), greaterThan(0));
    // Active jobs must stop and checkpoint before explicit disconnect returns.
    final interruptedPath = '${server.directory.path}/disconnected.bin';
    final interrupted = await rust.enqueueTransfer(
      id: c.id!,
      local: source.path,
      remote: interruptedPath,
      upload: true,
    );
    await waitTask(interrupted, (t) => t.busy && t.acknowledged > 0);
    await rust.disconnectTerminal(id: c.id!);
    expect((await waitTask(interrupted, (t) => !t.busy)).state, 'Paused');
    expect(c.generation, beforeSwitch);
    await rust.clearEndedTransfers();
    expect((await rust.listTransferTasks()).single.id, interrupted);
    await rust.unlockVault(path: vault, password: master);
    final restored = (await rust.listTransferTasks()).single;
    expect(restored.id, interrupted);
    expect(restored.state, 'Paused');
    expect(restored.busy, false);
    await rust.stopTransfer(taskId: interrupted, cancel: true);
    await rust.clearEndedTransfers();
    await rust.unlockVault(path: vault, password: master);
    expect(await rust.listTransferTasks(), isEmpty);
    final raw = await File(vault).readAsBytes();
    expect(String.fromCharCodes(raw).contains('source.bin'), false);
  } finally {
    await c.shutdown();
    c.dispose();
    await other.shutdown();
    other.dispose();
    await server.close();
  }
}

void main() {
  test(
    'real FRB transfer queue checkpoints, identity guard, conflicts and disconnect',
    exerciseTransfers,
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isLinux,
  );
}
