import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_proxy.dart';
import 'support/local_sshd.dart';

Future<void> exerciseJump({
  Future<void> Function(LiveWorkbenchModel)? attach,
  Future<void> Function(LiveWorkbenchModel, DemoHost, DemoHost)? afterReady,
  Future<void> Function()? detach,
  Future<bool> Function(DemoHost, rust.BridgeEvent)? confirm,
}) async {
  await initializeRust();
  final jump = await LocalSshd.start();
  final target = await LocalSshd.start();
  final otherJump = await LocalSshd.start();
  final proxy = await LocalProxy.start(jump.directory, jump.port, socks5: true);
  final model = LiveWorkbenchModel();
  try {
    final path = '${target.directory.path}/jump.vault';
    await rust.unlockVault(path: path, password: 'synthetic-jump-master');
    await model.load();
    await attach?.call(model);
    final events = <(String, String)>[];
    model.confirmHostKey = (host, event) async {
      events.add((event.kind, event.detail!));
      return await confirm?.call(host, event) ?? true;
    };
    final savedJump = await model.persistHost(
      DemoHost(
        model.nextId(),
        'Jump fixture',
        'ssh-via-proxy.invalid',
        '未分组',
        port: jump.port,
        user: jump.username,
        auth: '私钥',
        openSftp: false,
        proxy: DemoProxy(
          socks5: true,
          address: '127.0.0.1',
          port: proxy.port,
          authenticate: true,
        ),
      ),
      secret: jump.privateKey,
      passphrase: 'test-only-passphrase',
      proxyUsername: 'fixture-user',
      proxyPassword: 'fixture-password',
    );
    final direct = await model.persistHost(
      DemoHost(
        model.nextId(),
        'Direct identity control',
        '127.0.0.1',
        '未分组',
        port: target.port,
        user: 'synthetic-nonexistent-user',
        auth: '密码',
        openSftp: false,
      ),
      secret: 'invalid-synthetic-password',
    );
    await model.testSavedHost(direct);
    expect(events.single.$1, 'hostKey');
    events.clear();
    var host = direct.copy(model.nextId())
      ..name = 'Target through jump'
      ..jumpHostId = savedJump.id;
    await model.persistDraft(host, secret: 'invalid-synthetic-password');
    expect(model.recoverableDrafts.single.jumpHostId, savedJump.id);
    host = await model.persistHost(model.recoverableDrafts.single);
    await rust.unlockVault(path: path, password: 'synthetic-jump-master');
    await model.load();
    host = model.hosts.firstWhere((h) => h.id == host.id);
    await model.testSavedHost(host);
    expect(events.map((e) => e.$1).toList(), ['jumpHostKey', 'hostKey']);
    expect(events[0].$2, contains('ssh-via-proxy.invalid:${jump.port}'));
    expect(events[1].$2, contains('127.0.0.1:${target.port}'));
    // Even though the direct target key is already trusted, this route must
    // receive its own explicit target confirmation. No target login was tried.
    expect(model.tabs, isEmpty);
    expect(model.recent, isEmpty);
    events.clear();
    await model.testSavedHost(host);
    expect(events, isEmpty);
    final copy = await model.copyHost(host);
    expect(copy.jumpHostId, savedJump.id);
    final savedCopy = await model.persistHost(copy);
    expect(savedCopy.jumpHostId, savedJump.id);
    model.openHost(host);
    final session = model.focus! as LiveTerminalSession;
    await waitFor(
      () => session.controller.error != null,
      'target selected authentication must fail',
    );
    expect(session.controller.connected, false);
    final id = session.controller.id;
    host = host.snapshot()
      ..user = target.username
      ..auth = '私钥';
    host = await model.persistHost(
      host,
      secret: target.privateKey,
      passphrase: 'test-only-passphrase',
    );
    await session.controller.reconnect();
    await waitFor(
      () => session.controller.connected || session.controller.error != null,
      'jump manual reconnect',
    );
    expect(
      session.controller.connected,
      true,
      reason: session.controller.error,
    );
    expect(session.controller.id, id);
    expect(events, isEmpty);
    await session.controller.setVisible(true);
    await session.controller.text("printf '%s%s\\n' JUMP_ NATIVE");
    await session.controller.key(
      rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
    );
    await waitFor(
      () => screen(session.controller).contains('JUMP_NATIVE'),
      'jump PTY output',
    );
    final file = File('${target.directory.path}/jump 中文.txt');
    await file.writeAsString('synthetic jump bytes');
    await model.loadDirectory(session, target.directory.path);
    expect(session.files.any((f) => f.name == 'jump 中文.txt'), true);
    final generation = session.controller.generation;
    await afterReady?.call(model, host, savedJump);
    expect(session.controller.id, id);
    expect(session.controller.generation, generation);
    final secondJump = await model.persistHost(
      DemoHost(
        model.nextId(),
        'Other jump fixture',
        '127.0.0.1',
        '未分组',
        port: otherJump.port,
        user: otherJump.username,
        auth: '私钥',
        openSftp: false,
      ),
      secret: otherJump.privateKey,
      passphrase: 'test-only-passphrase',
    );
    host = model.hosts.firstWhere((h) => h.id == host.id).snapshot()
      ..jumpHostId = secondJump.id;
    await model.persistHost(host);
    expect(session.controller.connected, true);
    expect(session.controller.generation, generation);
    await rust.disconnectTerminal(id: id!);
    await waitFor(
      () => !session.controller.connected,
      'disconnect original jump route',
    );
    await session.controller.reconnect();
    await waitFor(
      () => session.controller.connected || session.controller.error != null,
      'second explicit jump route',
    );
    expect(
      session.controller.connected,
      true,
      reason: session.controller.error,
    );
    expect(events.map((e) => e.$1).toList(), ['jumpHostKey', 'hostKey']);
    expect(events[0].$2, contains('127.0.0.1:${otherJump.port}'));
    events.clear();
    await session.controller.text("printf '%s%s\\n' JUMP_ NATIVE");
    await session.controller.key(
      rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
    );
    await waitFor(
      () => screen(session.controller).contains('JUMP_NATIVE'),
      'new PTY output before failed reconnect',
    );
    // Removing saved credentials/config does not disconnect existing transport.
    await model.deleteHosts({secondJump.id});
    expect(session.controller.connected, true);
    await model.loadDirectory(session, target.directory.path);
    expect(session.files.any((f) => f.name == 'jump 中文.txt'), true);
    await rust.disconnectTerminal(id: id);
    await waitFor(
      () => !session.controller.connected,
      'explicit disconnect after deleting jump',
    );
    await session.controller.reconnect();
    await waitFor(
      () => session.controller.error != null,
      'deleted jump reference rejected',
    );
    expect(session.controller.connected, false);
    expect(session.controller.error, contains('跳板主机已删除'));
    expect(events, isEmpty);
    expect(screen(session.controller), contains('JUMP_NATIVE'));
    expect(
      (await rust.listHosts()).firstWhere((h) => h.id == host.id).jumpHostId,
      secondJump.id,
    );
  } finally {
    await model.shutdown();
    await detach?.call();
    model.dispose();
    await proxy.close();
    await otherJump.close();
    await target.close();
    await jump.close();
  }
}

void main() {
  test(
    'encrypted one-jump route uses independent identities, inherited proxy, PTY SFTP and explicit reconnect',
    () => exerciseJump(),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
