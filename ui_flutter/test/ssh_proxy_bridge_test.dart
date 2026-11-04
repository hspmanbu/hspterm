import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_proxy.dart';
import 'support/local_sshd.dart';

Future<void> exerciseProxy({
  Future<void> Function(LiveWorkbenchModel)? attach,
  Future<void> Function()? afterReady,
  Future<void> Function()? detach,
}) async {
  await initializeRust();
  final server = await LocalSshd.start();
  final proxies = <LocalProxy>[];
  final model = LiveWorkbenchModel();
  try {
    await rust.unlockVault(
      path: '${server.directory.path}/proxy.vault',
      password: 'synthetic-proxy-master',
    );
    await model.load();
    await attach?.call(model);
    model.confirmHostKey = (host, event) async {
      expect(host.address, 'ssh-via-proxy.invalid');
      return true;
    };
    for (final socks5 in [false, true]) {
      final proxy = await LocalProxy.start(
        server.directory,
        server.port,
        socks5: socks5,
      );
      proxies.add(proxy);
      final host = DemoHost(
        model.nextId(),
        socks5 ? 'SOCKS5 fixture' : 'HTTP CONNECT fixture',
        'ssh-via-proxy.invalid',
        '未分组',
        user: server.username,
        port: server.port,
        auth: '私钥',
        openSftp: false,
        proxy: DemoProxy(
          socks5: socks5,
          address: '127.0.0.1',
          port: proxy.port,
          authenticate: true,
        ),
      );
      await model.persistDraft(
        host,
        secret: server.privateKey,
        passphrase: 'test-only-passphrase',
        proxyUsername: 'fixture-user',
        proxyPassword: 'fixture-password',
      );
      expect(model.recoverableDrafts.single.proxy!.credentialSet, true);
      final saved = await model.persistHost(model.recoverableDrafts.single);
      expect(saved.proxy!.credentialSet, true);
      expect((await rust.listHosts()).last.proxy!.authenticate, true);
      // Reopening the encrypted catalog does not require the authentication UI.
      await rust.unlockVault(
        path: '${server.directory.path}/proxy.vault',
        password: 'synthetic-proxy-master',
      );
      await model.load();
      model.openHost(model.hosts.firstWhere((h) => h.id == saved.id));
      final session = model.focus! as LiveTerminalSession;
      await waitFor(
        () => session.controller.connected || session.controller.error != null,
        'proxied SSH attempt',
      );
      expect(
        session.controller.connected,
        true,
        reason: session.controller.error,
      );
      await session.controller.setVisible(true);
      final id = session.controller.id,
          generation = session.controller.generation;
      await session.controller.text("printf '%s%s\\n' PROXY_ NATIVE");
      await session.controller.key(
        rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(session.controller).contains('PROXY_NATIVE'),
        'proxy PTY output',
      );
      final dir = await Directory(
        '${server.directory.path}/${socks5 ? 'socks' : 'http'} 中文',
      ).create();
      await File('${dir.path}/sftp.txt').writeAsString('synthetic proxy bytes');
      await model.loadDirectory(session, dir.path);
      expect(session.files.single.name, 'sftp.txt');
      final copy = await model.copyHost(saved);
      final savedCopy = await model.persistHost(copy);
      expect(savedCopy.proxy!.credentialSet, true);
      // Metadata edits never reconnect an established Transport.
      final edited = saved.snapshot();
      edited.proxy = DemoProxy(
        socks5: socks5,
        address: '127.0.0.1',
        port: proxy.port,
        authenticate: true,
        credentialSet: true,
      );
      await model.persistHost(edited);
      expect(session.controller.id, id);
      expect(session.controller.generation, generation);
      await rust.disconnectTerminal(id: session.controller.id!);
      await waitFor(
        () => !session.controller.connected,
        "explicit proxy disconnect",
      );
      expect(screen(session.controller).contains('PROXY_NATIVE'), true);
      await session.controller.reconnect();
      await waitFor(
        () => session.controller.connected || session.controller.error != null,
        'explicit proxy reconnect',
      );
      expect(
        session.controller.connected,
        true,
        reason: session.controller.error,
      );
      expect(session.controller.generation, greaterThan(generation));
      await model.deleteHosts({savedCopy.id});
      expect(session.controller.connected, true);
    }
    await afterReady?.call();
  } finally {
    await model.shutdown();
    await detach?.call();
    model.dispose();
    for (final proxy in proxies) {
      await proxy.close();
    }
    await server.close();
  }
}

void main() {
  test(
    'encrypted HTTP/SOCKS proxy settings drive actual FRB PTY SFTP and manual reconnect',
    () => exerciseProxy(),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
