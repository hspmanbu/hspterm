import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/src/rust/network_settings.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_proxy.dart';
import 'support/local_sshd.dart';

void main() {
  setUpAll(initializeRust);
  test('inherited ACK deadline is captured per connection, copied in drafts and disabled only after explicit reconnect', () async {
    final server = await LocalSshd.start();
    final proxy = await LocalProxy.start(
      server.directory,
      server.port,
      socks5: true,
    );
    final model = LiveWorkbenchModel();
    try {
      await rust.unlockVault(
        path: '${server.directory.path}/defaults.vault',
        password: 'synthetic-defaults-master',
      );
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      await rust.saveSshNetworkDefaults(
        value: const SshNetworkDefaults(
          timeoutSeconds: 10,
          keepaliveSeconds: 2,
          responseTimeoutSeconds: 1,
          autoReconnect: false,
          keepaliveFailures: 1,
        ),
      );
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'ACK fixture',
          'ssh-via-proxy.invalid',
          '未分组',
          user: server.username,
          port: server.port,
          auth: '私钥',
          openSftp: false,
          useNetworkDefaults: true,
          keepaliveSeconds: 0,
          proxy: DemoProxy(
            socks5: true,
            address: '127.0.0.1',
            port: proxy.port,
            authenticate: true,
          ),
        ),
        secret: server.privateKey,
        passphrase: 'test-only-passphrase',
        proxyUsername: 'fixture-user',
        proxyPassword: 'fixture-password',
      );
      final copied = await rust.copyHostToDraft(id: host.id);
      expect(copied.useNetworkDefaults, true);
      await rust.discardHostDraft(id: copied.id);
      await model.persistDraft(
        host.snapshot()
          ..useNetworkDefaults = false
          ..keepaliveResponseSeconds = 3,
      );
      expect((await rust.hostDrafts()).single.keepaliveResponseSeconds, 3);
      expect((await rust.listHosts()).single.useNetworkDefaults, true);
      await rust.discardHostDraft(id: host.id);
      await model.load();
      model.openHost(model.hosts.single);
      final session = model.focus! as LiveTerminalSession;
      await waitFor(
        () => session.controller.connected || session.controller.error != null,
        'ACK heartbeat SSH',
      );
      expect(
        session.controller.connected,
        true,
        reason: session.controller.error,
      );
      // Two genuine OpenSSH keepalive REQUEST_FAILURE replies count as ACKs.
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(session.controller.connected, true);
      await session.controller.setVisible(true);
      await session.controller.text(
        "seq 1 2000; printf '%s%s\\n' ACK_PROTOCOL_ READY",
      );
      await session.controller.key(
        rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(session.controller).contains('ACK_PROTOCOL_READY'),
        'PTY output while ACK heartbeat active',
      );
      expect(session.controller.connected, true);
      await rust.saveSshNetworkDefaults(
        value: const SshNetworkDefaults(
          timeoutSeconds: 10,
          keepaliveSeconds: 0,
          responseTimeoutSeconds: 1,
          autoReconnect: false,
          keepaliveFailures: 1,
        ),
      );
      final id = session.controller.id!,
          generation = session.controller.generation;
      await proxy.holdTraffic();
      await waitFor(
        () => session.controller.phase == 'Disconnected',
        'independent ACK response deadline',
        timeout: const Duration(seconds: 5),
      );
      expect(session.controller.error, contains('心跳等待响应超时'));
      expect(session.controller.id, id);
      expect(session.controller.generation, generation);
      await proxy.resumeTraffic();
      expect(
        session.controller.connected,
        false,
        reason: 'no automatic SSH reconnect',
      );
      await session.controller.reconnect();
      await waitFor(
        () => session.controller.connected || session.controller.error != null,
        'heartbeat-off inherited reconnect',
      );
      expect(
        session.controller.connected,
        true,
        reason: session.controller.error,
      );
      expect(session.controller.generation, greaterThan(generation));
      await proxy.holdTraffic();
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(
        session.controller.connected,
        true,
        reason: 'zero disables the ACK monitor and the legacy heartbeat',
      );
      await rust.disconnectTerminal(id: id);
      await proxy.resumeTraffic();
    } finally {
      await proxy.resumeTraffic();
      await model.shutdown();
      model.dispose();
      await proxy.close();
      await server.close();
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
  test('saved host total timeout applies at proxy stage and cancellation retains failed tab', () async {
    final dir = await Directory.systemTemp.createTemp('hspterm-timing-');
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final requests = StreamController<void>.broadcast();
    final subscription = listener.listen((socket) {
      sockets.add(socket);
      socket.listen((data) {
        requests.add(null);
      });
    });
    final model = LiveWorkbenchModel();
    try {
      await rust.unlockVault(
        path: '${dir.path}/vault',
        password: 'synthetic timing master',
      );
      await model.load();
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Timeout fixture',
          'target.invalid',
          '未分组',
          user: 'fixture',
          auth: '密码',
          openSftp: false,
          timeoutSeconds: 1,
          keepaliveSeconds: 0,
          keepaliveFailures: 5,
          proxy: DemoProxy(
            socks5: true,
            address: '127.0.0.1',
            port: listener.port,
          ),
        ),
        secret: 'synthetic ssh password',
      );
      await rust.unlockVault(
        path: '${dir.path}/vault',
        password: 'synthetic timing master',
      );
      await model.load();
      expect(model.hosts.single.timeoutSeconds, 1);
      expect(model.hosts.single.keepaliveSeconds, 0);
      expect(model.hosts.single.keepaliveFailures, 5);
      final firstRequest = requests.stream.first;
      model.openHost(model.hosts.single);
      await firstRequest.timeout(const Duration(seconds: 3));
      final session = model.focus! as LiveTerminalSession;
      await waitFor(
        () => session.controller.phase == 'Failed',
        'saved one-second total budget',
        timeout: const Duration(seconds: 5),
      );
      expect(session.controller.error, contains('Proxy'));
      expect(model.tabs, hasLength(1));
      expect(sockets, hasLength(1));
      final edited = host.snapshot()..timeoutSeconds = 8;
      await model.persistHost(edited);
      final nextRequest = requests.stream.first;
      final retry = session.controller.reconnect();
      await nextRequest.timeout(const Duration(seconds: 3));
      await rust.cancelConnection(id: session.controller.id!);
      await retry;
      await waitFor(
        () => session.controller.phase != 'Connecting',
        'explicit cancellation',
      );
      expect(session.controller.connected, false);
      expect(model.tabs, hasLength(1));
      expect(session.host.timeoutSeconds, 8);
      expect(sockets, hasLength(2));
    } finally {
      await model.shutdown();
      model.dispose();
      await subscription.cancel();
      await listener.close();
      for (final socket in sockets) {
        socket.destroy();
      }
      await requests.close();
      await dir.delete(recursive: true);
    }
  });

  test('saved heartbeat detects a stalled transport, zero disables it and reconnect stays explicit', () async {
    final server = await LocalSshd.start();
    final proxy = await LocalProxy.start(
      server.directory,
      server.port,
      socks5: true,
    );
    final model = LiveWorkbenchModel();
    try {
      await rust.unlockVault(
        path: '${server.directory.path}/timing.vault',
        password: 'synthetic heartbeat master',
      );
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Heartbeat fixture',
          'ssh-via-proxy.invalid',
          '未分组',
          user: server.username,
          port: server.port,
          auth: '私钥',
          openSftp: false,
          timeoutSeconds: 10,
          keepaliveSeconds: 1,
          keepaliveFailures: 1,
          proxy: DemoProxy(
            socks5: true,
            address: '127.0.0.1',
            port: proxy.port,
            authenticate: true,
          ),
        ),
        secret: server.privateKey,
        passphrase: 'test-only-passphrase',
        proxyUsername: 'fixture-user',
        proxyPassword: 'fixture-password',
      );
      model.openHost(host);
      final session = model.focus! as LiveTerminalSession;
      await waitFor(
        () => session.controller.connected || session.controller.error != null,
        'heartbeat SSH',
      );
      expect(
        session.controller.connected,
        true,
        reason: session.controller.error,
      );
      await session.controller.setVisible(true);
      await session.controller.text("printf '%s%s\\n' HEARTBEAT_ READY");
      await session.controller.key(
        rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(session.controller).contains('HEARTBEAT_READY'),
        'heartbeat output',
      );
      final id = session.controller.id,
          generation = session.controller.generation;
      await proxy.holdTraffic();
      await waitFor(
        () => session.controller.phase == 'Disconnected',
        'configured keepalive failure',
        timeout: const Duration(seconds: 6),
      );
      expect(screen(session.controller), contains('HEARTBEAT_READY'));
      expect(session.controller.id, id);
      expect(session.controller.generation, generation);
      expect(model.tabs, hasLength(1));
      await proxy.resumeTraffic();
      expect(session.controller.connected, false);
      // A zero interval disables only the heartbeat, not user cancellation.
      final off = host.snapshot()..keepaliveSeconds = 0;
      await model.persistHost(off);
      await session.controller.reconnect();
      await waitFor(
        () => session.controller.connected || session.controller.error != null,
        'explicit heartbeat-off reconnect',
      );
      expect(
        session.controller.connected,
        true,
        reason: session.controller.error,
      );
      expect(session.controller.generation, greaterThan(generation));
      await proxy.holdTraffic();
      // Real elapsed time is intentional: exceed the measured enabled deadline
      // against the same stalled transport without a fake clock across FFI.
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(session.controller.connected, true);
      await rust.disconnectTerminal(id: id!);
      await waitFor(
        () => !session.controller.connected,
        'heartbeat-off explicit disconnect',
      );
      await proxy.resumeTraffic();
    } finally {
      await proxy.resumeTraffic();
      await model.shutdown();
      model.dispose();
      await proxy.close();
      await server.close();
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}
