import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;

import '../test/support/local_sshd.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK actual terminal preferences confirmation updates original SSH rendering without a reconnect',
    (tester) async {
      await initializeRust();
      final ssh = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> until(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('terminal preferences GTK fixture timed out');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump();
      }

      Future<void> tap(Finder target) async {
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      Future<void> snapshot(String name) async {
        await tester.pumpAndSettle();
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/hspterm-terminal-preferences-$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      }

      try {
        await rust.createConfigurationVault(
          path: '${ssh.directory.path}/preferences.vault',
          password: 'synthetic-preferences-gtk-master',
        );
        await model.load();
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            '终端偏好夹具',
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
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        model.openHost(host);
        await tester.pump();
        final session = model.focus! as LiveTerminalSession;
        final c = session.controller;
        final trust = find.widgetWithText(FilledButton, '信任并保存');
        await until(
          () =>
              trust.evaluate().isNotEmpty || c.connected || c.phase == 'Failed',
        );
        if (trust.evaluate().isNotEmpty) {
          await tester.tap(trust);
          await tester.pump();
        }
        await until(() => c.connected || c.phase == 'Failed');
        expect(c.connected, true, reason: c.error);
        final id = c.id, generation = c.generation;
        model.show(WorkPage.settings);
        await tester.pumpAndSettle();
        await tap(find.text('终端与输入'));
        await until(
          () =>
              tester
                  .widget<FilledButton>(
                    find.byKey(const ValueKey('terminal-preferences-save')),
                  )
                  .onPressed !=
              null,
        );
        await tap(find.text('浅色配色预设'));
        await tap(find.byKey(const ValueKey('terminal-osc52')));
        final color = find.byKey(const ValueKey('terminal-color-2'));
        await tester.ensureVisible(color);
        await tester.enterText(color, '123456');
        await tap(find.byKey(const ValueKey('terminal-preferences-save')));
        await snapshot('confirmation');
        await tap(find.byKey(const ValueKey('terminal-preferences-confirm')));
        await until(() => find.textContaining('已加密保存').evaluate().isNotEmpty);
        model.show(WorkPage.workspace);
        await tester.pump();
        await until(() => c.metadata?.background == 0xfff6f8fb);
        await snapshot('terminal');
        expect(c.metadata!.cursorColor, 0xff123456);
        expect(c.osc52Enabled, false);
        expect(c.id, id);
        expect(c.generation, generation);
        expect(model.sessions.single, same(session));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        await ssh.close();
      }
    },
  );
}
