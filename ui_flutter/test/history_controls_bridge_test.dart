import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('real encrypted history preferences and zero-count clears preserve live SSH; stale and reopened scopes fail', () async {
    final server = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    final path = '${server.directory.path}/history-controls.vault';
    try {
      await rust.unlockVault(
        path: path,
        password: 'synthetic-history-controls-master',
      );
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Synthetic history controls',
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
      model.openHost(host);
      final session = model.focus! as LiveTerminalSession,
          c = session.controller;
      await waitFor(
        () => c.connected || c.phase == 'Failed',
        'history controls SSH',
      );
      expect(c.connected, true, reason: c.error);
      await c.setVisible(true);
      final id = c.id, generation = c.generation;
      final first = await rust.commandHistoryControls();
      expect(first.enabled, true);
      expect(first.total, 0);
      expect(first.hosts.single.id, host.id);
      final disabled = await model.updateCommandHistory(first, enabled: false);
      expect(disabled.enabled, false);
      await expectLater(
        model.updateCommandHistory(first, clearHostId: host.id),
        throwsA(anything),
      );
      final cleared = await model.updateCommandHistory(
        disabled,
        clearHostId: host.id,
      );
      expect(cleared.total, 0);
      expect(cleared.revision, isNot(disabled.revision));
      expect(cleared.enabled, false);
      await expectLater(
        rust.unlockVault(path: path, password: 'synthetic-wrong-password'),
        throwsA(anything),
      );
      final all = await model.updateCommandHistory(cleared);
      expect(all.revision, isNot(cleared.revision));
      await rust.unlockVault(
        path: '${server.directory.path}/other-history.vault',
        password: 'synthetic-other-master',
      );
      await expectLater(
        model.updateCommandHistory(all, enabled: true),
        throwsA(anything),
      );
      await expectLater(
        rust.searchCommandHistory(
          query: '',
          limit: 100,
          expectedVaultScope: first.vaultScope,
        ),
        throwsA(anything),
      );
      await expectLater(
        rust.deleteCommandHistory(
          texts: ['echo fixture'],
          hostId: host.id,
          expectedVaultScope: first.vaultScope,
        ),
        throwsA(anything),
      );
      expect((await rust.commandHistoryControls()).enabled, true);
      await rust.unlockVault(
        path: path,
        password: 'synthetic-history-controls-master',
      );
      await expectLater(
        model.updateCommandHistory(all, enabled: true),
        throwsA(anything),
      );
      expect((await rust.commandHistoryControls()).enabled, false);
      expect(c.id, id);
      expect(c.generation, generation);
      expect(c.connected, true);
      expect(model.sessions.single, same(session));
      await c.text(r"printf '%s%s\n' HISTORY_ ALIVE");
      await c.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(c).contains('HISTORY_ALIVE'),
        'history controls preserve SSH input',
      );
      // No collector is installed: raw input/output above cannot create history.
      expect((await rust.commandHistoryControls()).total, 0);
    } finally {
      await model.shutdown();
      model.dispose();
      await server.close();
    }
  }, skip: !Platform.isLinux);
}
