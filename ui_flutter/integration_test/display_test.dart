import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/src/rust/api.dart' as rust;

import '../test/support/local_sshd.dart';
import '../test/native_bridge_test.dart' show waitFor, screen;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK real encrypted display-rule editing, host inheritance and actual SSH painter',
    (tester) async {
      await initializeRust();
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      final server = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/hspterm-$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      }

      try {
        await rust.unlockVault(
          path: '${server.directory.path}/display-gui.vault',
          password: 'synthetic-only-master',
        );
        await model.load();
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            'Display fixture',
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
        model.page = WorkPage.settings;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-彩色高亮')));
        await tester.pumpAndSettle();
        for (final key in [
          'display-enabled',
          'display-semantic',
          'display-rainbow',
          'display-same-word',
        ]) {
          final toggle = find.byKey(ValueKey(key));
          await tester.ensureVisible(toggle);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
        }
        final add = find.byKey(const ValueKey('display-add-rule'));
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('display-rule-name')),
          'ERROR foreground',
        );
        await tester.enterText(
          find.byKey(const ValueKey('display-rule-pattern')),
          'ERROR',
        );
        final color = find.byKey(const ValueKey('display-rule-foreground'));
        await tester.ensureVisible(color);
        await tester.enterText(color, 'EF8B8B');
        final accept = find.byKey(const ValueKey('display-rule-accept'));
        await tester.ensureVisible(accept);
        await tester.tap(accept);
        await tester.pumpAndSettle();
        final save = find.byKey(const ValueKey('display-save'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        final global = await rust.terminalDisplaySettings();
        expect(global.effective.rules.single.foreground, 0xffef8b8b);
        await tester.drag(
          find.byKey(const ValueKey('settings-content-彩色高亮')),
          const Offset(0, 1000),
        );
        await tester.pumpAndSettle();
        await screenshot('display-settings');
        final scope = find.byKey(const ValueKey('display-scope-global'));
        await tester.ensureVisible(scope);
        await tester.pumpAndSettle();
        await tester.tap(scope);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Display fixture').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('display-inherit')),
              )
              .value,
          true,
        );
        expect(
          tester
              .widget<SwitchListTile>(
                find.byKey(const ValueKey('display-rainbow')),
              )
              .onChanged,
          isNull,
        );
        expect(model.sessions, isEmpty);
        await screenshot('display-host-inheritance');
        model.confirmHostKey = (_, _) async => true;
        model.openHost(host);
        model.page = WorkPage.workspace;
        model.changed();
        await tester.pumpAndSettle();
        final session = model.sessions.single as LiveTerminalSession,
            c = session.controller;
        await waitFor(() => c.connected, 'GTK display SSH connects');
        await tester.pumpAndSettle();
        await c.text(
          "PS1='fixture\$ '; printf '\\033[2J\\033[H%s%s 2026-10-26 12:00:00 /var/log/app 127.0.0.1 [value=(42)]\\n\\033[31m%s%s remote ANSI wins\\033[0m\\n中文 é 中文\\n' ER ROR ER ROR",
        );
        await c.key(rust.KeyboardInput(key: 'Enter', kind: 0, modifiers: 0));
        await waitFor(
          () => screen(c).contains('remote ANSI wins'),
          'GTK actual output',
        );
        await tester.pumpAndSettle();
        expect(c.rows.first.first.foreground, 0xffef8b8b);
        c.select(const Point(0, 0), const Point(4, 0));
        await screenshot('display-terminal');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        await server.close();
      }
    },
  );
}
