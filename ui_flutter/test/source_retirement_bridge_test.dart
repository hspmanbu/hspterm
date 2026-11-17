import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'remote_transfer_bridge_test.dart' show remoteTask;
import 'support/local_sshd.dart';
import 'support/lost_remove_reply_sftp.dart';

Future<void> connect(
  TerminalController c,
  LocalSshd server,
  String name,
) async {
  final host = await rust.saveProfile(
    profile: rust.Profile(
      id: '',
      name: name,
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
  await c.connect(host.id);
  await waitFor(() => c.connected, 'private cross-server SSH');
}

void main() {
  test(
    'cross-server move requires explicit relay consent and confirms whole copy then source directory retirement',
    () async {
      await initializeRust();
      final left = await LocalSshd.start();
      LocalSshd? right;
      final a = TerminalController(const NativeTerminalBackend()),
          b = TerminalController(const NativeTerminalBackend());
      try {
        right = await LocalSshd.start();
        await rust.unlockVault(
          path: '${left.directory.path}/relocate.vault',
          password: 'test-only-relocate-master',
        );
        await connect(a, left, 'left relocation fixture');
        await connect(b, right, 'right relocation fixture');
        // Only this dedicated payload subtree moves; server keys/config/vault
        // remain outside it and are never copied to the destination.
        final source = await Directory('${left.directory.path}/source tree')
            .create();
        await Directory('${source.path}/empty').create();
        await Directory('${source.path}/中文').create();
        final bytes = List.generate(100000, (i) => i % 251);
        await File("${source.path}/中文/a'b.bin").writeAsBytes(bytes);
        await File('${source.path}/root.txt')
            .writeAsString('synthetic source text');
        final destination = '${right.directory.path}/target tree';
        // Cross-server move without relay or direct consent is admitted as a
        // task and fails at its own select; the source is never touched.
        final deniedMove = await rust.enqueueRemoteMove(
          sourceId: a.id!,
          targetId: b.id!,
          source: source.path,
          destination: destination,
          expectedSourceGeneration: a.generation,
          expectedTargetGeneration: b.generation,
        );
        final deniedMoveTask = await remoteTask(deniedMove, (t) => !t.busy);
        expect(deniedMoveTask.state, 'Failed', reason: deniedMoveTask.error);
        expect(await source.exists(), true);
        expect(await Directory(destination).exists(), false);
        await rust.clearEndedRemoteCopies();
        final id = await rust.enqueueRemoteMove(
          sourceId: a.id!,
          targetId: b.id!,
          source: source.path,
          destination: destination,
          expectedSourceGeneration: a.generation,
          expectedTargetGeneration: b.generation,
          allowMemoryRelay: true,
        );
        final task = await remoteTask(id, (t) => !t.busy);
        expect(task.state, 'Complete');
        expect(task.remoteOperation, 'relocate');
        expect(task.sourceDeletionsConfirmed, task.sourceDeletionsTotal);
        expect(task.sourceDeletionsTotal, 5);
        expect(task.terminalGeneration, b.generation);
        expect(task.sourceTerminalGeneration, a.generation);
        expect(await source.exists(), false);
        expect(await File("$destination/中文/a'b.bin").readAsBytes(), bytes);
        expect(await Directory('$destination/empty').exists(), true);
        expect(
          await File('$destination/root.txt').readAsString(),
          'synthetic source text',
        );
        expect(a.connected, true);
        expect(b.connected, true);
        // A completed task cannot operate again on a later recreated name.
        await source.create();
        await File('${source.path}/later.txt').writeAsString('new source');
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
          await File('${source.path}/later.txt').readAsString(),
          'new source',
        );
        await rust.clearEndedRemoteCopies();
      } finally {
        await a.shutdown();
        a.dispose();
        await b.shutdown();
        b.dispose();
        await right?.close();
        await left.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );

  test(
    'real lost source REMOVE reply keeps intent, never deletes a recreated file, and can end locally offline',
    () async {
      await initializeRust();
      final left = await LocalSshd.start(sftpFixture: lostRemoveReplySftp);
      LocalSshd? right;
      final a = TerminalController(const NativeTerminalBackend()),
          b = TerminalController(const NativeTerminalBackend());
      final vault = '${left.directory.path}/unknown-source.vault';
      const master = 'test-only-unknown-source-master';
      try {
        right = await LocalSshd.start();
        await rust.unlockVault(path: vault, password: master);
        await connect(a, left, 'unknown source fixture');
        await connect(b, right, 'copy fixture');
        final source = File('${left.directory.path}/source 中文.bin');
        final target = File('${right.directory.path}/target 中文.bin');
        final bytes = List.filled(65536, 71), later = List.filled(65536, 82);
        await source.writeAsBytes(bytes);
        final id = await rust.enqueueRemoteMove(
          sourceId: a.id!,
          targetId: b.id!,
          source: source.path,
          destination: target.path,
          expectedSourceGeneration: a.generation,
          expectedTargetGeneration: b.generation,
          allowMemoryRelay: true,
        );
        final unknown = await remoteTask(id, (t) => !t.busy);
        expect(unknown.state, 'Failed');
        expect(unknown.remoteMovePhase, 'Intent');
        expect(unknown.sourceDeletionsConfirmed, 0);
        expect(unknown.sourceDeletionsTotal, 1);
        expect(await source.exists(), false);
        expect(await target.readAsBytes(), bytes);
        final count = File(
          '${left.directory.path}/sftp_fixture.py.remove-count',
        );
        expect(await count.readAsLines(), ['1']);
        await source.writeAsBytes(later);
        await expectLater(
          rust.resumeRemoteCopy(
            sourceId: a.id!,
            targetId: b.id!,
            taskId: id,
            decision: 'continue',
          ),
          throwsA(anything),
        );
        final facts = await rust.inspectSourceRetirement(
          sourceId: a.id!,
          targetId: b.id!,
          taskId: id,
        );
        expect(facts.sourceKind, 'File');
        expect(facts.sourceSize, bytes.length);
        expect(facts.destinationSize, bytes.length);
        expect(
          (await remoteTask(id, (t) => !t.busy)).remoteMovePhase,
          'Intent',
        );
        await a.shutdown();
        await b.shutdown();
        final stale = await rust.prepareSourceRetirementEnd(taskId: id);
        final current = await rust.prepareSourceRetirementEnd(taskId: id);
        await expectLater(
          rust.endSourceRetirementWait(taskId: id, ticket: stale.ticket),
          throwsA(anything),
        );
        await rust.endSourceRetirementWait(taskId: id, ticket: current.ticket);
        final ended = await remoteTask(id, (t) => !t.busy);
        expect(ended.state, 'Cancelled');
        expect(ended.remoteMovePhase, 'UserEnded');
        expect(ended.sourceDeletionsConfirmed, 0);
        expect(await count.readAsLines(), ['1']);
        expect(await source.readAsBytes(), later);
        expect(await target.readAsBytes(), bytes);
        await rust.clearEndedRemoteCopies();
        await rust.unlockVault(path: vault, password: master);
        expect((await rust.listRemoteCopies()).any((t) => t.id == id), false);
        await expectLater(
          rust.endSourceRetirementWait(taskId: id, ticket: current.ticket),
          throwsA(anything),
        );
        expect(await source.readAsBytes(), later);
        expect(await count.readAsLines(), ['1']);
      } finally {
        await a.shutdown();
        a.dispose();
        await b.shutdown();
        b.dispose();
        await right?.close();
        await left.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
