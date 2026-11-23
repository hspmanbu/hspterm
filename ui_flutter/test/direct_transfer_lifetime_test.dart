import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'agent_bridge_test.dart' show connected, save;
import 'native_bridge_test.dart' show waitFor;
import 'remote_transfer_bridge_test.dart' show remoteTask;
import 'support/local_sshd.dart';

void main() {
  test(
    'finished direct queue rows release task authentication before the 64-capability ceiling',
    () async {
      await initializeRust();
      final a = await LocalSshd.start();
      LocalSshd? b;
      final model = LiveWorkbenchModel();
      try {
        b = await LocalSshd.start();
        await rust.unlockVault(
          path: '${a.directory.path}/lifetime.vault',
          password: 'synthetic-lifetime-master',
        );
        await model.load();
        final sourceHost = await save(model, a, 'lifetime source', agent: true);
        final targetHost = await save(model, b, 'lifetime target');
        final source = await connected(model, sourceHost);
        model.openHost(targetHost);
        final target = model.sessions
            .whereType<LiveTerminalSession>()
            .singleWhere((s) => s.host.id == targetHost.id)
            .controller;
        await waitFor(() => target.connected, 'lifetime target connects');
        final input = File('${a.directory.path}/payload.bin');
        await input.writeAsBytes([0, 127, 255]);
        final ids = <String>[];
        for (var i = 0; i < 66; i++) {
          final output = File('${b.directory.path}/copy-$i.bin');
          final id = await rust.enqueueRemoteCopy(
            sourceId: source.id!,
            targetId: target.id!,
            source: input.path,
            destination: output.path,
            allowMemoryRelay: false,
            allowDirect: true,
            expectedSourceGeneration: source.generation,
            expectedTargetGeneration: target.generation,
          );
          ids.add(id);
          final task = await remoteTask(id, (t) => !t.busy);
          expect(task.state, 'Complete', reason: 'copy $i: ${task.error}');
          expect(task.remoteTransport, 'direct');
          expect(await output.readAsBytes(), [0, 127, 255]);
        }
        // Finished display records are deliberately retained throughout the
        // regression, so clearing the UI queue cannot mask an authentication leak.
        final tasks = await rust.listRemoteCopies();
        expect(tasks.map((t) => t.id), containsAll(ids));
        expect(
          tasks.where((t) => ids.contains(t.id) && t.state == 'Complete'),
          hasLength(66),
        );
        expect(source.connected && target.connected, true);
        await rust.clearEndedRemoteCopies();
      } finally {
        await model.shutdown();
        model.dispose();
        await b?.close();
        await a.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 7)),
    skip: !Platform.isLinux,
  );
}
