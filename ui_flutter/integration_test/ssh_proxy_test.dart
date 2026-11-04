import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/prototype/model.dart' show WorkPage;
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';

import '../test/native_bridge_test.dart' show waitFor;
import '../test/ssh_proxy_bridge_test.dart' as fixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK proxy metadata form persists write-only authentication and keeps live SSH identity',
    (tester) async {
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      late LiveWorkbenchModel model;
      final capture = GlobalKey();
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

      await fixture.exerciseProxy(
        attach: (m) async {
          model = m;
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: WorkbenchApp(model: m),
            ),
          );
          await tester.pumpAndSettle();
        },
        detach: () async {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
        afterReady: () async {
          final session = model.focus! as LiveTerminalSession;
          final id = session.controller.id!,
              generation = session.controller.generation;
          await screenshot('ssh-proxy-workbench');
          model.page = WorkPage.hosts;
          model.changed();
          await tester.pumpAndSettle();
          final manager = find.byType(HostManager);
          final state = tester.state<HostManagerState>(manager);
          // The host page initially selects HTTP; exercise its actual network form.
          final host = state.snapshot();
          await tester.tap(
            find.descendant(of: manager, matching: find.text('网络')),
          );
          await tester.pumpAndSettle();
          final user = find.byKey(const ValueKey('host-proxy-username'));
          final password = find.byKey(const ValueKey('host-proxy-password'));
          await tester.enterText(
            find.byKey(const ValueKey('host-timeout')),
            '19',
          );
          await tester.enterText(
            find.byKey(const ValueKey('host-keepalive')),
            '0',
          );
          await tester.enterText(
            find.byKey(const ValueKey('host-keepalive-failures')),
            '4',
          );
          await screenshot('ssh-network-timing');
          expect(tester.widget<TextFormField>(user).controller!.text, isEmpty);
          expect(
            tester.widget<TextFormField>(password).controller!.text,
            isEmpty,
          );
          await tester.ensureVisible(user);
          await screenshot('ssh-proxy-settings');
          await tester.enterText(user, 'fixture-user');
          await tester.ensureVisible(password);
          await tester.enterText(password, 'fixture-password');
          final save = find.descendant(of: manager, matching: find.text('保存'));
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pumpAndSettle();
          await waitFor(
            () => !state.dirty,
            'single network-category encrypted save',
          );
          expect(
            (await rust.listHosts())
                .firstWhere((h) => h.id == host.id)
                .proxy!
                .credentialSet,
            true,
          );
          final saved = (await rust.listHosts()).firstWhere(
            (h) => h.id == host.id,
          );
          expect(saved.timeoutSeconds, 19);
          expect(saved.keepaliveSeconds, 0);
          expect(saved.keepaliveFailures, 4);
          expect(session.controller.id, id);
          expect(session.controller.generation, generation);
          // The edited HTTP host must also connect again using the UI-saved auth.
          final http = model.sessions.cast<LiveTerminalSession>().firstWhere(
            (s) => s.host.id == host.id,
          );
          await rust.disconnectTerminal(id: http.controller.id!);
          await waitFor(
            () => !http.controller.connected,
            'HTTP explicit disconnect',
          );
          await http.controller.reconnect();
          await waitFor(
            () => http.controller.connected || http.controller.error != null,
            'HTTP reconnect after form save',
          );
          expect(
            http.controller.connected,
            true,
            reason: http.controller.error,
          );
          expect(http.host.timeoutSeconds, 19);
          expect(http.host.keepaliveSeconds, 0);
          expect(tester.takeException(), isNull);
        },
      );
    },
  );
}
