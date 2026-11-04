import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  setUpAll(initializeRust);
  test('real encrypted import, old-vault rejection, missing credential safety and explicit key configuration then original SSH', () async {
    final server = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    final path = '${server.directory.path}/import.vault';
    const master = 'synthetic-import-master';
    final source =
        'Host importer\n HostName 127.0.0.1\n Port ${server.port}\n User ${server.username}\n IdentityFile /never-read-a-private-key\n ServerAliveInterval 0\nHost blocked\n User fixture\n ProxyCommand never-executed';
    try {
      await rust.unlockVault(path: path, password: master);
      await model.load();
      var preview = await rust.previewOpensshImport(
        source: source,
        defaultUsername: '',
      );
      expect(preview.hosts.length, 2);
      expect(preview.hosts.last.blocked, true);
      expect(await rust.listHosts(), isEmpty);
      expect(model.sessions, isEmpty);
      final scope = preview.vaultScope;
      await rust.unlockVault(path: path, password: master);
      await expectLater(
        rust.commitOpensshImport(
          source: source,
          defaultUsername: '',
          aliases: ['importer'],
          acknowledgePartial: true,
          groupId: 'group-default',
          vaultScope: scope,
        ),
        throwsA(anything),
      );
      expect(await rust.listHosts(), isEmpty);
      preview = await rust.previewOpensshImport(
        source: source,
        defaultUsername: '',
      );
      Future<List<rust.HostConfig>> commit(
        List<String> aliases, {
        bool ack = true,
      }) => rust.commitOpensshImport(
        source: source,
        defaultUsername: '',
        aliases: aliases,
        acknowledgePartial: ack,
        groupId: 'group-default',
        vaultScope: preview.vaultScope,
      );
      await expectLater(commit(['importer'], ack: false), throwsA(anything));
      await expectLater(commit(['importer', 'blocked']), throwsA(anything));
      expect(await rust.listHosts(), isEmpty);
      final imported = (await commit(['importer'])).single;
      expect(imported.credentialSet, false);
      expect(imported.privateKey, true);
      await model.load();
      expect(model.sessions, isEmpty);
      final terminal = await rust.createTerminal(
        columns: 80,
        rows: 24,
        historyLines: 1000,
      );
      try {
        await expectLater(
          rust.connectTerminal(id: terminal, profileId: imported.id),
          throwsA(anything),
        );
      } finally {
        await rust.destroyTerminal(id: terminal);
      }
      await expectLater(commit(['importer']), throwsA(anything));
      expect((await rust.listHosts()).length, 1);
      await model.persistHost(
        model.hosts.single,
        secret: server.privateKey,
        passphrase: 'test-only-passphrase',
      );
      model.confirmHostKey = (_, _) async => true;
      model.openHost(model.hosts.single);
      final session = model.sessions.single as LiveTerminalSession;
      await waitFor(
        () => session.controller.connected,
        'configured imported host connects',
      );
      await session.controller.setVisible(true);
      await session.controller.text(
        "printf '\\033[2J\\033[H%s%s\\n' IMPORT_ REAL_SSH_中文",
      );
      await session.controller.key(
        rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(session.controller).contains('IMPORT_REAL_SSH_中文'),
        'real PTY from imported metadata',
      );
      final disk = await File(path).readAsBytes();
      expect(
        String.fromCharCodes(disk).contains('never-read-a-private-key'),
        false,
      );
      expect(String.fromCharCodes(disk).contains('IMPORT_REAL_SSH'), false);
    } finally {
      await model.shutdown();
      model.dispose();
      await server.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
