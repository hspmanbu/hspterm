import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/forwardings.dart';
import 'package:hspterm/src/rust/forwardings/runtime.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

class Reader {
  Reader(Socket socket) : source = StreamIterator<List<int>>(socket);
  final StreamIterator<List<int>> source;
  final pending = <int>[];
  Future<List<int>> read(int count) async {
    while (pending.length < count) {
      if (!await source.moveNext().timeout(const Duration(seconds: 5))) {
        throw StateError('Unexpected forwarding EOF');
      }
      pending.addAll(source.current);
    }
    final value = pending.sublist(0, count);
    pending.removeRange(0, count);
    return value;
  }
}

Future<void> echo(RunStatus status, int target, {bool socks = false}) async {
  final socket = await Socket.connect(status.bindAddress!, status.bindPort!);
  final reader = Reader(socket);
  try {
    if (socks) {
      socket.add([5, 1, 0]);
      await socket.flush();
      expect(await reader.read(2), [5, 0]);
      socket.add([5, 1, 0, 1, 127, 0, 0, 1, target >> 8, target & 255]);
      await socket.flush();
      expect((await reader.read(10))[1], 0);
    }
    final bytes = List<int>.generate(65536 + 17, (i) => i % 251);
    socket.add(bytes);
    await socket.flush();
    expect(await reader.read(bytes.length), bytes);
  } finally {
    socket.destroy();
    await reader.source.cancel();
  }
}

Future<RunStatus> settled(int id, String token, String phase) async {
  RunStatus? result;
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    final values = await rust.terminalForwardings(id: id);
    result = values.where((v) => v.token == token).firstOrNull;
    if (result?.phase == phase) break;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('forward $phase');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return result!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test(
    'real FRB L/R/D runtimes keep original session identity, stop and close independently',
    () async {
      final ssh = await LocalSshd.start();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>{};
      var acceptedSockets = 0;
      final accepting = server.listen((socket) {
        acceptedSockets++;
        sockets.add(socket);
        socket.listen(
          socket.add,
          onDone: () {
            sockets.remove(socket);
            socket.destroy();
          },
          onError: (Object _) {
            sockets.remove(socket);
            socket.destroy();
          },
        );
      });
      final model = LiveWorkbenchModel();
      RunStatus? closeWithActive;
      try {
        await rust.unlockVault(
          path: '${ssh.directory.path}/forwarding.vault',
          password: 'synthetic-forwarding-master',
        );
        await model.load();
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            'Forward fixture',
            '127.0.0.1',
            '未分组',
            port: ssh.port,
            user: ssh.username,
            auth: '私钥',
            openSftp: false,
          ),
          secret: ssh.privateKey,
          passphrase: 'test-only-passphrase',
        );
        final rules = await rust.saveForwardingRules(
          hostId: host.id,
          rules: [
            for (final kind in ['local', 'remote', 'dynamic'])
              RuleConfig(
                id: '',
                name: kind,
                kind: kind,
                bindAddress: '127.0.0.1',
                bindPort: 0,
                targetAddress: kind == 'dynamic' ? null : '127.0.0.1',
                targetPort: kind == 'dynamic' ? null : server.port,
                enabled: true,
                restoreOnReconnect: false,
              ),
          ],
        );
        model.openHost(host);
        final session = model.focus! as LiveTerminalSession;
        await waitFor(
          () =>
              session.controller.connected || session.controller.error != null,
          'real forwarding SSH',
        );
        expect(
          session.controller.connected,
          true,
          reason: session.controller.error,
        );
        await session.controller.setVisible(false);
        final hiddenFrames = session.controller.frameCount;
        final id = session.controller.id!,
            generation = session.controller.generation;
        final live = <RunStatus>[];
        for (final rule in rules) {
          final start = await rust.startForwarding(
            id: id,
            generation: generation,
            ruleId: rule.id,
          );
          final running = await settled(id, start.token, 'listening');
          live.add(running);
          expect(running.bindPort, greaterThan(0));
          expect(running.generation, generation);
          await echo(running, server.port, socks: rule.kind == 'dynamic');
          await expectLater(
            rust.startForwarding(
              id: id,
              generation: generation,
              ruleId: rule.id,
            ),
            throwsA(anything),
          );
        }
        await waitFor(
          () => session.controller.forwardingChanges.value > 0,
          'real forwarding metadata event while hidden',
        );
        expect(
          session.controller.frameCount,
          hiddenFrames,
          reason: 'forwarding metadata must not pull terminal frames',
        );
        final quietDeadline = DateTime.now().add(const Duration(seconds: 5));
        while ((await rust.terminalForwardings(id: id))
            .any((r) => r.active != 0)) {
          if (DateTime.now().isAfter(quietDeadline)) {
            throw TimeoutException('forwarding connections did not finish');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final quietRevision = session.controller.forwardingChanges.value;
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(
          session.controller.forwardingChanges.value,
          quietRevision,
          reason: 'idle listeners must not emit periodic invalidations',
        );
        for (final address in ['192.0.2.1', '0.0.0.0', 'localhost.invalid']) {
          await expectLater(
            rust.startTemporaryForwarding(
              id: id,
              generation: generation,
              targetAddress: address,
              targetPort: server.port,
            ),
            throwsA(anything),
          );
        }
        final acceptedBefore = acceptedSockets;
        final temporary = await rust.startTemporaryForwarding(
          id: id,
          generation: generation,
          targetAddress: '127.0.0.1',
          targetPort: server.port,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          acceptedSockets,
          acceptedBefore,
          reason: 'listener creation must not probe the remote target',
        );
        expect(temporary.bindAddress, '127.0.0.1');
        await echo(temporary, server.port);
        expect(
          (await rust.forwardingRules(hostId: host.id)).length,
          3,
          reason: 'temporary forwarding must not create a saved rule',
        );
        await rust.stopForwarding(
          id: id,
          generation: generation,
          token: temporary.token,
        );
        model.openHost(host);
        final second = model.focus! as LiveTerminalSession;
        await waitFor(
          () => second.controller.connected || second.controller.error != null,
          'independent second SSH',
        );
        expect(
          second.controller.connected,
          true,
          reason: second.controller.error,
        );
        final secondId = second.controller.id!;
        expect(secondId, isNot(id));
        final secondStart = await rust.startForwarding(
          id: secondId,
          generation: second.controller.generation,
          ruleId: rules.first.id,
        );
        final secondLive = await settled(
          secondId,
          secondStart.token,
          'listening',
        );
        await expectLater(
          rust.stopForwarding(
            id: secondId,
            generation: second.controller.generation,
            token: live.first.token,
          ),
          throwsA(anything),
        );
        await echo(secondLive, server.port);
        final secondTab = model.tabs.singleWhere(
          (t) => t.sessionId == second.id,
        );
        model.closeTab(secondTab.id);
        await second.controller.shutdown();
        expect(second.controller.id, isNull);
        await expectLater(
          Socket.connect(secondLive.bindAddress!, secondLive.bindPort!),
          throwsA(anything),
        );
        expect(session.controller.connected, true);
        await session.controller.setVisible(true);
        await session.controller.text("printf '%s%s\\n' NATIVE_FORWARD_ OK");
        await session.controller.key(
          rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => screen(session.controller).contains('NATIVE_FORWARD_OK'),
          'PTY while all forwarding types active',
        );
        expect(session.controller.id, id);
        expect(session.controller.generation, generation);
        await expectLater(
          rust.stopForwarding(
            id: id,
            generation: generation + 1,
            token: live.first.token,
          ),
          throwsA(anything),
        );
        await rust.stopForwarding(
          id: id,
          generation: generation,
          token: live.first.token,
        );
        await settled(id, live.first.token, 'stopped');
        await echo(live.last, server.port, socks: true);
        // Editing configuration is not an implicit runtime stop or restart.
        await rust.saveForwardingRules(hostId: host.id, rules: []);
        await echo(live[1], server.port);
        await rust.disconnectTerminal(id: id);
        await waitFor(
          () => !session.controller.connected,
          'explicit disconnect',
        );
        expect(await rust.terminalForwardings(id: id), isEmpty);
        for (final old in live.skip(1)) {
          await expectLater(
            Socket.connect(old.bindAddress!, old.bindPort!),
            throwsA(anything),
          );
        }
        await session.controller.reconnect();
        await waitFor(
          () =>
              session.controller.connected || session.controller.error != null,
          'explicit reconnect',
        );
        expect(
          session.controller.connected,
          true,
          reason: session.controller.error,
        );
        expect(session.controller.generation, greaterThan(generation));
        expect(
          await rust.terminalForwardings(id: id),
          isEmpty,
          reason: 'no automatic forwarding restoration without configuration',
        );
        await expectLater(
          rust.stopForwarding(
            id: id,
            generation: generation,
            token: live[1].token,
          ),
          throwsA(anything),
        );
        await rust.saveForwardingRules(hostId: host.id, rules: rules);
        final fresh = await rust.startForwarding(
          id: id,
          generation: session.controller.generation,
          ruleId: rules.first.id,
        );
        final running = await settled(id, fresh.token, 'listening');
        final freshRemote = await rust.startForwarding(
          id: id,
          generation: session.controller.generation,
          ruleId: rules[1].id,
        );
        closeWithActive = await settled(id, freshRemote.token, 'listening');
        await rust.deleteHosts(ids: [host.id]);
        await echo(running, server.port);
        await rust.stopForwarding(
          id: id,
          generation: session.controller.generation,
          token: fresh.token,
        );
        await expectLater(
          rust.startForwarding(
            id: id,
            generation: session.controller.generation,
            ruleId: rules.last.id,
          ),
          throwsA(anything),
        );
        // App shutdown must close the remaining remote listener even after
        // its saved host and credentials have been deleted.
        expect(session.controller.connected, true);
      } finally {
        await model.shutdown();
        if (closeWithActive != null) {
          await expectLater(
            Socket.connect(
              closeWithActive.bindAddress!,
              closeWithActive.bindPort!,
            ),
            throwsA(anything),
          );
        }
        model.dispose();
        for (final socket in sockets.toList()) {
          socket.destroy();
        }
        await accepting.cancel();
        await server.close();
        await ssh.close();
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'explicit reconnect restores opted-in rules, isolates bind failure and rejects changed target identity',
    () async {
      final ssh = await LocalSshd.start();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      bool occupiedClosed = false;
      final sockets = <Socket>{};
      final accepting = server.listen((socket) {
        sockets.add(socket);
        socket.listen(
          socket.add,
          onDone: () {
            sockets.remove(socket);
            socket.destroy();
          },
          onError: (Object _) {
            sockets.remove(socket);
            socket.destroy();
          },
        );
      });
      final model = LiveWorkbenchModel();
      try {
        await rust.unlockVault(
          path: '${ssh.directory.path}/restore.vault',
          password: 'synthetic-restore-master',
        );
        await model.load();
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            'Restore fixture',
            '127.0.0.1',
            '未分组',
            port: ssh.port,
            user: ssh.username,
            auth: '私钥',
            openSftp: false,
          ),
          secret: ssh.privateKey,
          passphrase: 'test-only-passphrase',
        );
        RuleConfig rule(
          String name,
          String kind, {
          bool restore = true,
          bool enabled = true,
          int port = 0,
        }) => RuleConfig(
          id: '',
          name: name,
          kind: kind,
          bindAddress: '127.0.0.1',
          bindPort: port,
          targetAddress: kind == 'dynamic' ? null : '127.0.0.1',
          targetPort: kind == 'dynamic' ? null : server.port,
          enabled: enabled,
          restoreOnReconnect: restore,
        );
        final rules = await rust.saveForwardingRules(
          hostId: host.id,
          rules: [
            rule('restore L', 'local'),
            rule('restore R', 'remote'),
            rule('restore D', 'dynamic'),
            rule('occupied L', 'local', port: occupied.port),
            rule('manual only', 'dynamic', restore: false),
            rule('disabled', 'dynamic', enabled: false),
          ],
        );
        model.openHost(host);
        final session = model.focus! as LiveTerminalSession;
        Future<void> connected() async {
          await waitFor(
            () =>
                session.controller.connected ||
                session.controller.error != null,
            'restore SSH',
          );
          expect(
            session.controller.connected,
            true,
            reason: session.controller.error,
          );
        }

        await connected();
        final id = session.controller.id!,
            oldGeneration = session.controller.generation;
        expect(
          await rust.terminalForwardings(id: id),
          isEmpty,
          reason: 'first connection must not implicitly start rules',
        );
        await rust.disconnectTerminal(id: id);
        await waitFor(
          () => !session.controller.connected,
          'restore disconnect',
        );
        await session.controller.reconnect();
        await connected();
        final generation = session.controller.generation;
        expect(generation, greaterThan(oldGeneration));
        final runs = await rust.terminalForwardings(id: id);
        expect(runs, hasLength(4));
        expect(
          runs.map((r) => r.ruleId).toSet(),
          rules.take(4).map((r) => r.id).toSet(),
        );
        for (final configured in rules.take(3)) {
          final started = runs.singleWhere((r) => r.ruleId == configured.id);
          final running = await settled(id, started.token, 'listening');
          expect(running.generation, generation);
          await echo(running, server.port, socks: configured.kind == 'dynamic');
        }
        final failed = runs.singleWhere((r) => r.ruleId == rules[3].id);
        expect(failed.phase, 'failed');
        expect(failed.lastError, isNotEmpty);
        expect(
          failed.bindPort,
          isNull,
          reason: 'a failed bind must never advertise an active listener',
        );
        expect(session.controller.connected, true);
        expect(
          session.controller.error,
          isNull,
          reason: 'forwarding failure is separate from SSH state',
        );
        await occupied.close();
        occupiedClosed = true;
        final retry = await rust.startForwarding(
          id: id,
          generation: generation,
          ruleId: rules[3].id,
        );
        await echo(await settled(id, retry.token, 'listening'), server.port);
        expect(
          (await rust.terminalForwardings(id: id))
              .where((r) => r.ruleId == rules[3].id),
          hasLength(1),
          reason: 'manual retry replaces only the failed restoration report',
        );
        await rust.disconnectTerminal(id: id);
        await waitFor(
          () => !session.controller.connected,
          'identity change disconnect',
        );
        final changed = host.snapshot()..address = 'localhost';
        await model.persistHost(changed);
        await session.controller.reconnect();
        await connected();
        final rejected = await rust.terminalForwardings(id: id);
        expect(rejected, hasLength(1));
        expect(rejected.single.kind, 'configuration');
        expect(rejected.single.phase, 'failed');
        expect(rejected.single.lastError, contains('身份'));
        expect(rejected.single.bindPort, isNull);
        expect(session.controller.id, id);
        expect(session.controller.connected, true);
      } finally {
        await model.shutdown();
        model.dispose();
        for (final socket in sockets.toList()) {
          socket.destroy();
        }
        await accepting.cancel();
        await server.close();
        if (!occupiedClosed) await occupied.close();
        await ssh.close();
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
