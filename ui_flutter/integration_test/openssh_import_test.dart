import 'dart:io';
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK explicit source preview, selected metadata import and no automatic SSH or private-key read',
    (tester) async {
      await initializeRust();
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      final directory = await Directory.systemTemp.createTemp(
        'hspterm-config-import-',
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
          path: '${directory.path}/config.vault',
          password: 'synthetic-only-master',
        );
        await model.load();
        model.page = WorkPage.hosts;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('import-openssh-config')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('ssh-import-user')),
          'fixture',
        );
        await tester.enterText(
          find.byKey(const ValueKey('ssh-import-source')),
          'Host production staging\n HostName %h.example.invalid\n Port 2222\n IdentityFile /never-read\nHost blocked\n ProxyCommand never-run\nHost *\n ConnectTimeout 20\n ServerAliveInterval 15',
        );
        await tester.tap(find.byKey(const ValueKey('ssh-import-preview')));
        await tester.pumpAndSettle();
        expect((await rust.listHosts()), isEmpty);
        expect(model.sessions, isEmpty);
        await tester.tap(find.byKey(const ValueKey('ssh-import-select-all')));
        await tester.pumpAndSettle();
        final ack = find.byKey(const ValueKey('ssh-import-ack'));
        await tester.ensureVisible(ack);
        await tester.tap(ack);
        await tester.pumpAndSettle();
        await screenshot('openssh-import-preview');
        await tester.tap(find.byKey(const ValueKey('ssh-import-save')));
        await tester.pumpAndSettle();
        final hosts = await rust.listHosts();
        expect(hosts.length, 2);
        expect(hosts.every((h) => !h.credentialSet), true);
        expect(model.sessions, isEmpty);
        expect(hosts.map((h) => h.name), ['production', 'staging']);
        expect(model.hosts.length, 2);
        await screenshot('openssh-import-saved');
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
