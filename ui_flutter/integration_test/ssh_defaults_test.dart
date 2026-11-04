import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/src/rust/api.dart' as rust;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK global SSH defaults and per-host inheritance save to the actual encrypted repository without opening SSH',
    (tester) async {
      await initializeRust();
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      final directory = await Directory.systemTemp.createTemp(
        'hspterm-ssh-defaults-gui-',
      );
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/hspterm-$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      try {
        await rust.unlockVault(
          path: '${directory.path}/defaults.vault',
          password: 'synthetic-master',
        );
        await model.load();
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            'Global policy fixture',
            'fixture.invalid',
            '未分组',
            user: 'fixture',
            auth: '密码',
            openSftp: false,
          ),
          secret: 'synthetic-password',
        );
        model.page = WorkPage.settings;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('SSH 连接'));
        await tester.pumpAndSettle();
        for (final (key, value) in [
          ('ssh-default-timeout', '17'),
          ('ssh-default-interval', '2'),
          ('ssh-default-response', '1'),
          ('ssh-default-failures', '2'),
        ]) {
          final field = find.byKey(ValueKey(key));
          await tester.ensureVisible(field);
          await tester.enterText(field, value);
        }
        final save = find.text('保存 SSH 默认参数');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        final defaults = await rust.sshNetworkDefaults();
        expect(defaults.timeoutSeconds, 17);
        expect(defaults.responseTimeoutSeconds, 1);
        expect(defaults.keepaliveFailures, 2);
        expect(model.sessions, isEmpty);
        await screenshot('ssh-network-defaults');
        model.page = WorkPage.hosts;
        model.changed();
        await tester.pumpAndSettle();
        final editor = tester.state<HostManagerState>(find.byType(HostManager));
        await editor.choose(null);
        await tester.pumpAndSettle();
        expect(
          editor.useNetworkDefaults,
          true,
          reason: 'new UI hosts inherit defaults',
        );
        await editor.choose(host);
        await tester.pumpAndSettle();
        await tester.tap(find.text('网络'));
        await tester.pumpAndSettle();
        final inherit = find.byKey(const ValueKey('host-use-network-defaults'));
        await tester.ensureVisible(inherit);
        await tester.tap(inherit);
        await tester.pumpAndSettle();
        final response = find.byKey(const ValueKey('host-response-enabled'));
        await tester.ensureVisible(response);
        await tester.tap(response);
        await tester.pumpAndSettle();
        final seconds = find.byKey(const ValueKey('host-keepalive-response'));
        await tester.ensureVisible(seconds);
        await tester.enterText(seconds, '3');
        await screenshot('ssh-network-host-policy');
        final saving = editor.save();
        await tester.pumpAndSettle();
        expect(await saving, true);
        final saved = (await rust.listHosts()).single;
        expect(saved.useNetworkDefaults, true);
        expect(saved.keepaliveResponseSeconds, 3);
        expect(model.sessions, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
