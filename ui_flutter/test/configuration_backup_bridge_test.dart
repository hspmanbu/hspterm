import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/configuration_backup.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test(
    'real encrypted backup restore is scoped, reauthenticated and preserves original SSH/PTY',
    () async {
      final server = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final path = '${server.directory.path}/backup.vault',
          exported = '${server.directory.path}/configuration.hspbackup';
      const master = 'synthetic-backup-master',
          backupPassword = 'synthetic-backup-file-password';
      try {
        await rust.unlockVault(path: path, password: master);
        await model.load();
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            'Synthetic backup SSH',
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
        final terminal = (model.focus! as LiveTerminalSession).controller;
        await terminal.setVisible(true);
        await waitFor(
          () => terminal.connected || terminal.phase == 'Failed',
          'backup SSH',
        );
        expect(terminal.connected, true, reason: terminal.error);
        final id = terminal.id, generation = terminal.generation;
        const gateway = NativeConfigurationBackupGateway();
        final summary = await gateway.summary();
        await expectLater(
          gateway.export(
            summary,
            exported,
            'synthetic-wrong-master',
            backupPassword,
          ),
          throwsA(anything),
        );
        expect(await File(exported).exists(), false);
        await gateway.export(summary, exported, master, backupPassword);
        final encrypted = await File(exported).readAsBytes();
        expect(
          utf8.decode(encrypted, allowMalformed: true),
          isNot(contains('BEGIN OPENSSH PRIVATE KEY')),
        );
        final changed = host.snapshot()..name = 'Changed after backup';
        await model.persistHost(changed);
        await expectLater(
          gateway.export(summary, '$exported.stale', master, backupPassword),
          throwsA(anything),
        );
        final restore = await gateway.prepare(
          exported,
          backupPassword,
          'replace',
        );
        final choices = restore.preview.items
            .where((i) => i.useIncoming)
            .map((i) => i.id)
            .toList();
        await expectLater(
          gateway.apply(restore.ticket, choices, 'synthetic-wrong-master'),
          throwsA(anything),
        );
        expect((await rust.listHosts()).single.name, 'Changed after backup');
        await gateway.apply(restore.ticket, choices, master);
        expect((await rust.listHosts()).single.name, 'Synthetic backup SSH');
        await expectLater(
          gateway.apply(restore.ticket, choices, master),
          throwsA(anything),
        );
        expect(terminal.id, id);
        expect(terminal.generation, generation);
        expect(terminal.connected, true);
        await terminal.text("printf 'backup-original-SSH-still-live\\n'");
        await terminal.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => screen(terminal).contains('backup-original-SSH-still-live'),
          'SSH after restore',
        );
        final next = jsonDecode(
          await rust.configurationBackupSummary(),
        ) as Map<String, dynamic>;
        expect(next['vault_scope'], isNot(summary.scope));
      } finally {
        await model.shutdown();
        model.dispose();
        await server.close();
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
