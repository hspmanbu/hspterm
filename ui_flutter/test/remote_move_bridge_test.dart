import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/transfers.dart' as jobs;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'remote_transfer_bridge_test.dart' show remoteTask;
import 'support/local_sshd.dart';
import 'transfer_bridge_test.dart' show waitTask;

Future<void> exerciseRemoteMoves() async {
  await initializeRust();
  final server = await LocalSshd.start();
  final different = await LocalSshd.start();
  final a = TerminalController(const NativeTerminalBackend());
  final twin = TerminalController(const NativeTerminalBackend());
  final b = TerminalController(const NativeTerminalBackend());
  final vault = '${server.directory.path}/move.vault';
  try {
    await rust.unlockVault(path: vault, password: 'synthetic move test master');
    Future<String> profile(LocalSshd s) async => (await rust.saveProfile(
      profile: rust.Profile(
        id: '',
        name: 'Move fixture',
        address: '127.0.0.1',
        port: s.port,
        username: s.username,
        privateKey: true,
      ),
      secret: s.privateKey,
      passphrase: 'test-only-passphrase',
    )).id;
    final original = await profile(server), other = await profile(different);
    Future<void> connect(TerminalController c, String id) async {
      c.confirmHostKey = (_) async => true;
      await c.start();
      await c.connect(id);
      await waitFor(() => c.connected, 'move SSH: ${c.error}');
    }

    await connect(a, original);
    await connect(twin, original);
    await connect(b, other);
    expect(a.id, isNot(twin.id));
    final generation = a.generation, twinGeneration = twin.generation;
    final source = Directory('${server.directory.path}/source 中文 \'\$;');
    await Directory('${source.path}/empty/nested').create(recursive: true);
    await File('${source.path}/body.txt').writeAsString('原始移动内容e\u0301');
    await Link('${source.path}/link')
        .create('${server.directory.path}/nonexistent-target');
    final destination = Directory('${server.directory.path}/destination 中文');
    final unrelated = File('${server.directory.path}/unrelated editor.txt');
    await unrelated.writeAsString('unrelated editor content');
    final unrelatedEditor = rust.reserveEditor(
      id: a.id!,
      generation: a.generation,
      path: unrelated.path,
    );
    await rust.prepareEditor(
      editorId: unrelatedEditor,
      operation: rust.beginEditorOperation(editorId: unrelatedEditor),
    );
    await expectLater(
      rust.enqueueRemoteMove(
        sourceId: a.id!,
        targetId: b.id!,
        source: source.path,
        destination: destination.path,
        expectedSourceGeneration: a.generation,
        expectedTargetGeneration: b.generation,
      ),
      throwsA(anything),
    );
    expect(await source.exists(), true);
    expect(await destination.exists(), false);
    final id = await rust.enqueueRemoteMove(
      sourceId: a.id!,
      targetId: twin.id!,
      source: source.path,
      destination: destination.path,
      expectedSourceGeneration: a.generation,
      expectedTargetGeneration: twin.generation,
    );
    final done = await remoteTask(id, (t) => !t.busy);
    expect(done.state, 'Complete', reason: done.error);
    expect(done.remoteOperation, 'move');
    expect(done.folder, true);
    expect(await source.exists(), false);
    expect(await Directory('${destination.path}/empty/nested').exists(), true);
    expect(
      await File('${destination.path}/body.txt').readAsString(),
      '原始移动内容e\u0301',
    );
    expect(
      await Link('${destination.path}/link').target(),
      '${server.directory.path}/nonexistent-target',
    );
    expect(a.generation, generation);
    expect(twin.generation, twinGeneration);
    await rust.clearEndedRemoteCopies();
    await rust.closeEditor(editorId: unrelatedEditor, keepDraft: false);

    final originalFile = File('${server.directory.path}/source.bin');
    final targetFile = File('${server.directory.path}/target.bin');
    await originalFile.writeAsBytes(List.filled(65536, 71));
    await targetFile.writeAsString('existing target retained');
    final editor = rust.reserveEditor(
      id: a.id!,
      generation: a.generation,
      path: originalFile.path,
    );
    await rust.prepareEditor(
      editorId: editor,
      operation: rust.beginEditorOperation(editorId: editor),
    );
    await expectLater(
      rust.enqueueRemoteMove(
        sourceId: a.id!,
        targetId: twin.id!,
        source: originalFile.path,
        destination: '${originalFile.path}.editor-blocked',
        expectedSourceGeneration: a.generation,
        expectedTargetGeneration: twin.generation,
      ),
      throwsA(anything),
    );
    expect(await File('${originalFile.path}.editor-blocked').exists(), false);
    expect(await originalFile.length(), 65536);
    await rust.closeEditor(editorId: editor, keepDraft: false);
    final conflict = await rust.enqueueRemoteMove(
      sourceId: a.id!,
      targetId: twin.id!,
      source: originalFile.path,
      destination: targetFile.path,
      expectedSourceGeneration: a.generation,
      expectedTargetGeneration: twin.generation,
    );
    final failed = await remoteTask(conflict, (t) => !t.busy);
    expect(failed.state, 'Failed');
    expect(failed.error, contains('目标已存在'));
    expect(await originalFile.length(), 65536);
    expect(await targetFile.readAsString(), 'existing target retained');
    await rust.stopRemoteCopy(taskId: conflict, cancel: true);
    await rust.clearEndedRemoteCopies();

    // Force a device checkpoint failure after metadata preparation, before any
    // remote rename. This disposable DB never contains production credentials.
    await rust.saveTransferPreferences(
      value: const jobs.TransferPreferences(
        concurrency: 1,
        uploadBytesPerSecond: 1,
        downloadBytesPerSecond: 1,
      ),
    );
    final held = await rust.enqueueTransfer(
      id: a.id!,
      local: originalFile.path,
      remote: '${server.directory.path}/held.bin',
      upload: true,
    );
    await waitTask(held, (t) => t.busy && t.acknowledged > 0);
    final output = '${server.directory.path}/after checkpoint.bin';
    final guarded = await rust.enqueueRemoteMove(
      sourceId: a.id!,
      targetId: twin.id!,
      source: originalFile.path,
      destination: output,
      expectedSourceGeneration: a.generation,
      expectedTargetGeneration: twin.generation,
    );
    expect((await remoteTask(guarded, (_) => true)).state, 'Waiting');
    await expectLater(
      rust.enqueueRemoteMove(
        sourceId: a.id!,
        targetId: twin.id!,
        source: originalFile.path,
        destination: '$output.duplicate',
        expectedSourceGeneration: a.generation,
        expectedTargetGeneration: twin.generation,
      ),
      throwsA(anything),
    );
    expect(
      () => rust.reserveEditor(
        id: twin.id!,
        generation: twin.generation,
        path: originalFile.path,
      ),
      throwsA(anything),
      reason: 'queued move reserves the source against a new editor',
    );
    expect(RegExp(r'^task-[0-9a-f]{32}$').hasMatch(guarded), true);
    final trigger = await Process.run('python3', [
      '-c',
      'import sqlite3,sys\n'
          'db=sqlite3.connect(sys.argv[1])\n'
          'db.execute("CREATE TRIGGER deny_move_intent BEFORE INSERT ON records WHEN NEW.id=\'local-remote-transfer-"+sys.argv[2]+"\' BEGIN SELECT RAISE(ABORT, \'synthetic move checkpoint failure\'); END;")\n'
          'db.commit()\n',
      vault,
      guarded,
    ]);
    expect(trigger.exitCode, 0, reason: trigger.stderr.toString());
    await rust.stopTransfer(taskId: held, cancel: false);
    final stopped = await remoteTask(guarded, (t) => !t.busy);
    expect(stopped.state, 'Failed');
    expect(await originalFile.length(), 65536);
    expect(await File(output).exists(), false);
    final drop = await Process.run('python3', [
      '-c',
      'import sqlite3,sys\ndb=sqlite3.connect(sys.argv[1])\ndb.execute("DROP TRIGGER deny_move_intent")\ndb.commit()\n',
      vault,
    ]);
    expect(drop.exitCode, 0);
    await rust.resumeRemoteCopy(
      sourceId: a.id!,
      targetId: twin.id!,
      taskId: guarded,
      node: null,
      decision: 'continue',
      rename: null,
    );
    expect((await remoteTask(guarded, (t) => !t.busy)).state, 'Complete');
    expect(await originalFile.exists(), false);
    expect(await File(output).length(), 65536);
    await rust.stopTransfer(taskId: held, cancel: true);
    await rust.clearEndedTransfers();
    await rust.clearEndedRemoteCopies();
  } finally {
    await rust.shutdownEditors();
    await a.shutdown();
    a.dispose();
    await twin.shutdown();
    twin.dispose();
    await b.shutdown();
    b.dispose();
    await server.close();
    await different.close();
  }
}

void main() {
  test(
    'real FRB same-account move preserves objects and gates rename on durable intent',
    exerciseRemoteMoves,
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isLinux,
  );
}
