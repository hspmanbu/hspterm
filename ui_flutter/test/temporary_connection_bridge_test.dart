import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/temporary_connection.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

Future<DemoHost> save(LiveWorkbenchModel model, LocalSshd server) =>
    model.persistHost(
      DemoHost(
        model.nextId(),
        'Saved source fixture',
        '127.0.0.1',
        '未分组',
        user: server.username,
        port: server.port,
        auth: '私钥',
        openSftp: false,
      ),
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('single-use key really connects to the overridden server, never changes the saved host/key, and reconnect requires new consent', () async {
    final first = await LocalSshd.start(), second = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    try {
      await rust.unlockVault(
        path: '${first.directory.path}/once.vault',
        password: 'synthetic-once-master',
      );
      await model.load();
      final host = await save(model, first);
      final originalKey = (await rust.hostPublicKey(id: host.id)).fingerprint;
      final input = TemporaryConnectionInput(
        TemporaryTarget(
          '127.0.0.1',
          second.port,
          second.username,
          TemporaryAuth.privateKey,
        ),
        keyFile: '${second.directory.path}/client',
        passphrase: 'test-only-passphrase',
      );
      var dialogs = 0;
      model.requestTemporaryParameters = (h, previous) async {
        dialogs++;
        expect(h.port, first.port);
        if (dialogs == 1) {
          expect(previous, isNull);
          return input;
        }
        expect(previous!.port, second.port);
        return null;
      };
      model.confirmHostKey = (h, event) async {
        expect(h.port, second.port);
        return true;
      };
      await model.openTemporaryHost(host);
      expect(model.sessions.length, 1);
      final s = model.sessions.single as LiveTerminalSession;
      final c = s.controller;
      await waitFor(() => c.connected, 'overridden SSH connects: ${c.error}');
      expect(s.host.port, second.port);
      expect(input.keyFile, isNull);
      expect(input.passphrase, isNull);
      expect((await rust.listHosts()).single.port, first.port);
      expect((await rust.hostPublicKey(id: host.id)).fingerprint, originalKey);
      await c.text("printf '%s\\n' \"\$SSH_CONNECTION\"");
      await c.key(
        const rust.KeyboardInput(key: 'Enter', kind: 0, modifiers: 0),
      );
      await c.setVisible(true);
      await waitFor(
        () =>
            RegExp('127[.]0[.]0[.]1 [0-9]+ 127[.]0[.]0[.]1 ${second.port}')
                .hasMatch(screen(c)),
        'actual remote environment proves the second SSH endpoint',
      );
      final id = c.id!, generation = c.generation;
      await rust.disconnectTerminal(id: id);
      await waitFor(() => !c.connected, 'single-use disconnect');
      await c.reconnect();
      expect(dialogs, 2);
      expect(c.connected, false);
      expect(c.generation, generation);
      expect(
        c.id,
        id,
        reason: 'reconfirmation never creates a replacement terminal identity',
      );
      model.requestTemporaryParameters = (_, previous) async {
        dialogs++;
        return TemporaryConnectionInput(
          previous!,
          keyFile: '${second.directory.path}/client',
          passphrase: 'wrong-synthetic-key-passphrase',
        );
      };
      await c.reconnect();
      await waitFor(
        () => c.phase == 'Failed',
        'wrong one-off key fails without saved-credential fallback',
      );
      expect(dialogs, 3);
      expect(c.connected, false);
      expect((await rust.listHosts()).single.port, first.port);
    } finally {
      await model.shutdown();
      model.dispose();
      await first.close();
      await second.close();
    }
  });

  test('cancelled temporary form creates no session, source changes/reopen are rejected before file read or network', () async {
    final server = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    try {
      final path = '${server.directory.path}/source.vault';
      const password = 'synthetic-source-master';
      await rust.unlockVault(path: path, password: password);
      await model.load();
      final host = await save(model, server);
      model.requestTemporaryParameters = (_, _) async => null;
      await model.openTemporaryHost(host);
      expect(model.sessions, isEmpty);
      expect(model.tabs, isEmpty);
      final source = await rust.temporaryConnectionSource(profileId: host.id);
      final changed = host.snapshot()
        ..port = server.port == 65535 ? 65534 : server.port + 1;
      await model.persistHost(changed);
      final id = await rust.createTerminal(
        columns: 80,
        rows: 24,
        historyLines: 0,
      );
      try {
        Future<void> once() => rust.connectTerminalOnce(
          id: id,
          source: source,
          options: rust.TemporaryConnectionOptions(
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            authentication: 2,
          ),
          keyFile: '/nonexistent/explicit-test-key',
        );
        await expectLater(
          once(),
          throwsA(predicate((e) => e.toString().contains('配置已改变'))),
        );
        await rust.unlockVault(path: path, password: password);
        await expectLater(
          once(),
          throwsA(predicate((e) => e.toString().contains('配置库已改变'))),
        );
      } finally {
        await rust.destroyTerminal(id: id);
      }
    } finally {
      await model.shutdown();
      model.dispose();
      await server.close();
    }
  });
}
