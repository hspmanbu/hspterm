import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/workbench/model.dart';

import '../native_bridge_test.dart' show waitFor, screen;
import 'local_sshd.dart';

/// Never accesses the developer's default tmux socket. The remote namespace is
/// proven through the real SSH PTY before any product tmux command is allowed.
class TmuxFixture {
  TmuxFixture._(this.namespace, this.ssh, this.socket, this.model, this.host);
  final Directory namespace;
  final LocalSshd ssh;
  final String socket;
  final LiveWorkbenchModel model;
  DemoHost host;
  static Future<TmuxFixture> start() async {
    final namespace = await Directory.systemTemp.createTemp(
      'hspterm-native-tmux-',
    );
    LocalSshd? ssh;
    LiveWorkbenchModel? model;
    TmuxFixture? created;
    try {
      ssh = await LocalSshd.start(tmuxDirectory: namespace.path);
      model = LiveWorkbenchModel();
      await rust.unlockVault(
        path: '${ssh.directory.path}/tmux.vault',
        password: 'synthetic-native-tmux-master',
      );
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      var host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Tmux fixture',
          '127.0.0.1',
          '未分组',
          user: ssh.username,
          port: ssh.port,
          auth: '私钥',
          openSftp: false,
        ),
        secret: ssh.privateKey,
        passphrase: 'test-only-passphrase',
      );
      model.openHost(host);
      final preflight = model.focus! as LiveTerminalSession;
      await waitFor(
        () => preflight.controller.connected,
        'tmux environment preflight SSH',
      );
      await preflight.controller.setVisible(true);
      await preflight.controller.text(
        r'''printf '%s%s:%s:%s\n' TBOX_ READY "$TMUX_TMPDIR" "${TMUX-unset}"''',
      );
      await preflight.controller.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () =>
            screen(preflight.controller)
                .contains('TBOX_READY:${namespace.path}:unset'),
        'explicit private remote tmux namespace',
      );
      final closed = preflight.controller.shutdown();
      model.closeTab(model.tabs.single.id);
      await closed;
      final uid = await Process.run('id', ['-u']);
      if (uid.exitCode != 0) throw StateError('fixture uid unavailable');
      final socket =
          '${namespace.path}/tmux-${uid.stdout.toString().trim()}/default';
      final socketParent = File(socket).parent;
      await socketParent.create(recursive: true);
      final permissions = await Process.run('chmod', [
        '700',
        socketParent.path,
      ]);
      if (permissions.exitCode != 0) {
        throw StateError('private tmux socket permissions could not be set');
      }
      final fixture = TmuxFixture._(namespace, ssh, socket, model, host);
      created = fixture;
      await fixture.command([
        'new-session',
        '-d',
        '-s',
        'fixture',
        '/bin/bash',
        '--noprofile',
        '--norc',
      ]);
      await fixture.command([
        'set-window-option',
        '-g',
        'window-size',
        'latest',
      ]);
      await fixture.command(['set-option', '-g', 'status-right', 'fixture']);
      host = host.snapshot()..tmuxEnabled = true;
      fixture.host = await model.persistHost(host);
      return fixture;
    } catch (_) {
      if (created != null) {
        await created.close();
      } else {
        await model?.shutdown();
        model?.dispose();
        await ssh?.close();
        await namespace.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<String> command(
    List<String> args, {
    bool requireSuccess = true,
  }) async {
    final result = await Process.run(
      'tmux',
      ['-S', socket, '-f', '/dev/null', ...args],
      environment: {'HOME': ssh.directory.path},
    );
    if (requireSuccess && result.exitCode != 0) {
      throw StateError('isolated fixture tmux operation failed');
    }
    return result.stdout.toString().trim();
  }

  Future<void>? _closing;
  Future<void> close() => _closing ??= () async {
    try {
      await model.shutdown();
    } finally {
      model.dispose();
      try {
        await command(['kill-server'], requireSuccess: false);
      } finally {
        try {
          await ssh.close();
        } finally {
          await namespace.delete(recursive: true);
        }
      }
    }
  }();
}
