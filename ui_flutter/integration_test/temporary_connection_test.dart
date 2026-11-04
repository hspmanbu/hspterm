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

import '../test/support/local_sshd.dart';
import '../test/native_bridge_test.dart' show screen;
import '../test/temporary_connection_bridge_test.dart' as fixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK explicit single-use endpoint, original saved key, real SSH and fresh reconnect confirmation',
    (tester) async {
      await initializeRust();
      final first = await LocalSshd.start(), second = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> until(bool Function() condition) async {
        final end = DateTime.now().add(const Duration(seconds: 15));
        while (!condition()) {
          if (DateTime.now().isAfter(end)) {
            throw StateError('synthetic temporary UI fixture timed out');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump();
      }

      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final image =
            await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('/tmp/hspterm-$name.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      }

      try {
        await File('${first.directory.path}/client.pub')
            .copy('${second.directory.path}/client.pub');
        await rust.unlockVault(
          path: '${first.directory.path}/gtk-once.vault',
          password: 'synthetic-gtk-once-master',
        );
        await model.load();
        await fixture.save(model, first);
        model.page = WorkPage.hosts;
        tester.view.physicalSize = const Size(1280, 720);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('temporary-host-connect')));
        await until(
          () => find
              .byKey(const ValueKey('temporary-port'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.enterText(
          find.byKey(const ValueKey('temporary-port')),
          '${second.port}',
        );
        await screenshot('temporary-connection');
        await tester.tap(find.text('连接一次'));
        await until(() => find.text('信任并保存').evaluate().isNotEmpty);
        await tester.tap(find.text('信任并保存'));
        await until(
          () =>
              model.sessions.isNotEmpty &&
              (model.sessions.single as LiveTerminalSession)
                  .controller
                  .connected,
        );
        final c = (model.sessions.single as LiveTerminalSession).controller;
        await c.text(
          "PS1='fixture\$ '; printf '\\033[2J\\033[3J\\033[H%s%s\\n' TEMP_ UI_READY",
        );
        await c.key(
          const rust.KeyboardInput(key: 'Enter', kind: 0, modifiers: 0),
        );
        await until(
          () =>
              screen(c).contains('TEMP_UI_READY') &&
              !screen(c).contains('@') &&
              !screen(c).contains('Last login'),
        );
        await screenshot('temporary-session');
        expect((await rust.listHosts()).single.port, first.port);
        final generation = c.generation;
        await rust.disconnectTerminal(id: c.id!);
        await until(() => !c.connected);
        await tester.tap(find.text('重新连接'));
        await until(
          () => find
              .byKey(const ValueKey('temporary-port'))
              .evaluate()
              .isNotEmpty,
        );
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('temporary-port')),
              )
              .controller!
              .text,
          '${second.port}',
        );
        await screenshot('temporary-reconnect');
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(c.connected, false);
        expect(c.generation, generation);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        await first.close();
        await second.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}
