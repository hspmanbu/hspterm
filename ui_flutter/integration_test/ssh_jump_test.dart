import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';

import '../test/native_bridge_test.dart' show waitFor;
import '../test/ssh_jump_bridge_test.dart' as fixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK one-jump connection confirms each real endpoint and saves the actual jump chooser without reconnecting',
    (tester) async {
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      final capture = GlobalKey();
      late Future<bool> Function(DemoHost, rust.BridgeEvent) appConfirm;
      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/hspterm-$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      await fixture.exerciseJump(
        attach: (m) async {
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: WorkbenchApp(model: m),
            ),
          );
          await tester.pumpAndSettle();
          appConfirm = m.confirmHostKey!;
        },
        confirm: (host, event) async {
          final result = appConfirm(host, event);
          final title = event.kind == 'jumpHostKey'
              ? '首次连接：确认跳板机 SSH 指纹'
              : '首次连接：确认 SSH 主机指纹';
          // A hidden probe without a progress dialog has no animation scheduling
          // frames. Drive frames explicitly before waiting for its route to build.
          for (var i = 0; i < 200 && find.text(title).evaluate().isEmpty; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(find.text(title), findsOneWidget);
          await tester.pump(const Duration(milliseconds: 250));
          expect(find.textContaining(event.detail!), findsOneWidget);
          if (event.kind == 'jumpHostKey' &&
              event.detail!.contains('ssh-via-proxy.invalid')) {
            await screenshot('ssh-jump-tofu');
          }
          await tester.tap(find.text('信任并保存'));
          return result;
        },
        afterReady: (model, host, jump) async {
          final session = model.focus! as LiveTerminalSession;
          final id = session.controller.id,
              generation = session.controller.generation;
          await screenshot('ssh-jump-workbench');
          model.page = WorkPage.hosts;
          model.changed();
          await tester.pumpAndSettle();
          final state = tester.state<HostManagerState>(
            find.byType(HostManager),
          );
          await state.choose(host);
          await tester.pumpAndSettle();
          await tester.tap(
            find.descendant(
              of: find.byType(HostManager),
              matching: find.text('网络'),
            ),
          );
          await tester.pumpAndSettle();
          final dropdown = find.byKey(ValueKey('host-jump-${host.id}'));
          await tester.ensureVisible(dropdown);
          await screenshot('ssh-jump-settings');
          await tester.tap(dropdown);
          await tester.pumpAndSettle();
          await tester.tap(find.text('无跳板机').last);
          await tester.pumpAndSettle();
          await tester.tap(dropdown);
          await tester.pumpAndSettle();
          await tester.tap(find.textContaining('Jump fixture ·').last);
          await tester.pumpAndSettle();
          final save = find.descendant(
            of: find.byType(HostManager),
            matching: find.text('保存'),
          );
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pumpAndSettle();
          await waitFor(
            () => !state.dirty,
            'one explicit encrypted jump form save',
          );
          expect(
            (await rust.listHosts())
                .firstWhere((h) => h.id == host.id)
                .jumpHostId,
            jump.id,
          );
          expect(session.controller.id, id);
          expect(session.controller.generation, generation);
          expect(session.controller.connected, true);
          expect(tester.takeException(), isNull);
        },
        detach: () async {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    },
  );
}
