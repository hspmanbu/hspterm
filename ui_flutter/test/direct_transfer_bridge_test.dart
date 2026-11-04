import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'agent_bridge_test.dart' show save, connected;
import 'native_bridge_test.dart' show waitFor;
import 'remote_transfer_bridge_test.dart' show remoteTask;
import 'support/local_sshd.dart';

// Real private OpenSSH/app-owned Agent/FRB/device journal path. Test source only
// until unified generation/build/test; requires system ssh/rsync/python3.
void main() {
  test(
    'direct-only copy and cross-server move use the original approved app Agent and preserve task policy',
    () async {
      await initializeRust();
      final sourceServer = await LocalSshd.start();
      LocalSshd? destinationServer;
      final model = LiveWorkbenchModel();
      try {
        final targetServer = await LocalSshd.start();
        destinationServer = targetServer;
        await rust.unlockVault(
          path: '${sourceServer.directory.path}/direct.vault',
          password: 'test-only-direct-master',
        );
        await model.load();
        final sourceHost = await save(
          model,
          sourceServer,
          'direct source fixture',
          agent: true,
        );
        final targetHost = await save(
          model,
          targetServer,
          'direct target fixture',
        );
        final source = await connected(model, sourceHost);
        model.openHost(targetHost);
        final target = model.sessions
            .whereType<LiveTerminalSession>()
            .singleWhere((s) => s.host.id == targetHost.id)
            .controller;
        await waitFor(
          () => target.connected,
          'original direct destination Root',
        );
        final input = File("${sourceServer.directory.path}/payload '\$ 中文.bin");
        final output = File("${targetServer.directory.path}/copy '\$ 中文.bin");
        final bytes = List.generate(262147, (i) => i % 251);
        await input.writeAsBytes(bytes);
        // No permission is silently created, even when a source allows Agent requests.
        await expectLater(
          rust.enqueueRemoteCopy(
            sourceId: source.id!,
            targetId: target.id!,
            source: input.path,
            destination: output.path,
            allowMemoryRelay: false,
            allowDirect: true,
            expectedSourceGeneration: source.generation,
            expectedTargetGeneration: target.generation,
          ),
          throwsA(anything),
        );
        expect(await output.exists(), false);
        final preview = await rust.prepareAgentAuthorisation(
          id: source.id!,
          generation: source.generation,
          hostIds: [targetHost.id],
          seconds: 120,
        );
        await rust.approveAgentAuthorisation(
          id: source.id!,
          generation: source.generation,
          ticket: preview.ticket,
        );
        final copied = await rust.enqueueRemoteCopy(
          sourceId: source.id!,
          targetId: target.id!,
          source: input.path,
          destination: output.path,
          allowMemoryRelay: false,
          allowDirect: true,
          expectedSourceGeneration: source.generation,
          expectedTargetGeneration: target.generation,
        );
        final copy = await remoteTask(copied, (t) => !t.busy);
        expect(copy.state, 'Complete');
        expect(copy.remoteTransport, 'direct');
        expect(copy.acknowledged, bytes.length);
        expect(await output.readAsBytes(), bytes);
        expect(await input.readAsBytes(), bytes);
        final movedPath = File('${targetServer.directory.path}/moved.bin');
        final moved = await rust.enqueueRemoteMove(
          sourceId: source.id!,
          targetId: target.id!,
          source: input.path,
          destination: movedPath.path,
          allowMemoryRelay: false,
          allowDirect: true,
          expectedSourceGeneration: source.generation,
          expectedTargetGeneration: target.generation,
        );
        final move = await remoteTask(moved, (t) => !t.busy);
        expect(move.state, 'Complete');
        expect(move.remoteTransport, 'direct');
        expect(move.sourceDeletionsConfirmed, 1);
        expect(await input.exists(), false);
        expect(await movedPath.readAsBytes(), bytes);
        await rust.revokeTerminalAgent(
          id: source.id!,
          generation: source.generation,
        );
        final later = File('${targetServer.directory.path}/later.bin');
        await expectLater(
          rust.enqueueRemoteCopy(
            sourceId: source.id!,
            targetId: target.id!,
            source: output.path,
            destination: later.path,
            allowMemoryRelay: false,
            allowDirect: true,
          ),
          throwsA(anything),
        );
        expect(await later.exists(), false);
        // Explicit relay-only remains available; it never probes or grants Agent.
        final relayed = await rust.enqueueRemoteCopy(
          sourceId: target.id!,
          targetId: source.id!,
          source: output.path,
          destination: input.path,
          allowMemoryRelay: true,
          allowDirect: false,
        );
        final relay = await remoteTask(relayed, (t) => !t.busy);
        expect(relay.state, 'Complete');
        expect(relay.remoteTransport, 'relay');
        expect(await input.readAsBytes(), bytes);
        expect(source.connected && target.connected, true);
        await rust.clearEndedRemoteCopies();
      } finally {
        await model.shutdown();
        model.dispose();
        await destinationServer?.close();
        await sourceServer.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isLinux,
  );
}
