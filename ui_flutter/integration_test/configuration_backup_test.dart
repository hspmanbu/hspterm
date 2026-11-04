import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/configuration_backup_panel.dart';

import '../test/native_bridge_test.dart' show waitFor, screen;
import '../test/support/local_sshd.dart';

// Only the system picker is replaced by a fixed private fixture path. Crypto,
// preview controls, confirmation, password dialog and apply remain real.
class _Files implements ConfigurationBackupFiles {
  _Files(this.path);
  final String path;
  @override
  Future<String?> open() async => path;
  @override
  Future<String?> save() async => path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK real backup preview, conflict choice and authenticated apply preserve SSH',
    (tester) async {
      await initializeRust();
      final server = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      const master = 'synthetic-backup-GTK-master',
          backupPassword = 'synthetic-backup-GTK-file-password';
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/backup.vault',
          password: master,
        );
        await model.load();
        await model.typography.load();
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            '合成备份 SSH',
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
        await waitFor(
          () => terminal.connected || terminal.phase == 'Failed',
          'backup GTK SSH',
        );
        expect(terminal.connected, true, reason: terminal.error);
        final id = terminal.id, generation = terminal.generation;
        final path = '${server.directory.path}/configuration.hspbackup';
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model, backupFiles: _Files(path)),
          ),
        );
        await tester.pumpAndSettle();
        await terminal.text(
          "printf '\\033[2J\\033[HHSPTerm backup - synthetic SSH\\n'",
        );
        await terminal.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => screen(terminal).contains('HSPTerm backup'),
          'backup banner',
        );
        final c = model.configurationBackups;
        await c.load();
        await c.export(path, master, backupPassword);
        expect(c.error, isNull);
        final changed = host.snapshot()..name = '备份后修改的合成主机';
        await model.persistHost(changed);
        await tester.tap(find.byKey(const ValueKey('app-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('加密备份 / 恢复与同步'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('backup-open')));
        await tester.tap(find.byKey(const ValueKey('backup-open')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('backup-file-password')),
          backupPassword,
        );
        await tester.tap(find.byKey(const ValueKey('backup-password-submit')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('backup-differences')),
          findsOneWidget,
        );
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/hspterm-backup-preview.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
        final source = c.preview!;
        final incomingHost = source.preview.items.singleWhere(
          (i) => i.id == host.id,
        );
        await tester.ensureVisible(
          find.byKey(ValueKey('backup-item-${incomingHost.id}')),
        );
        await tester.tap(
          find.byKey(ValueKey('backup-item-${incomingHost.id}')),
        );
        await tester.pumpAndSettle();
        expect(c.selectedIncoming, contains(host.id));
        await tester.ensureVisible(find.byKey(const ValueKey('backup-apply')));
        await tester.tap(find.byKey(const ValueKey('backup-apply')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('backup-confirm-restore')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('backup-current-password')),
          master,
        );
        await tester.tap(find.byKey(const ValueKey('backup-password-submit')));
        await tester.pumpAndSettle();
        expect(c.committed, true);
        expect(c.error, isNull);
        expect((await rust.listHosts()).single.name, '合成备份 SSH');
        model.show(WorkPage.workspace);
        await tester.pumpAndSettle();
        expect(terminal.id, id);
        expect(terminal.generation, generation);
        expect(terminal.connected, true);
        await terminal.text("printf 'backup-gtk-identity-preserved\\n'");
        await terminal.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => screen(terminal).contains('backup-gtk-identity-preserved'),
          'backup GTK input after restore',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
