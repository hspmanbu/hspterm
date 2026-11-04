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
import '../test/native_bridge_test.dart' show waitFor, screen;
import '../test/agent_bridge_test.dart' as fixture;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK saved host opt-in, explicit fingerprint consent, real Agent signature and revoke',
    (tester) async {
      await initializeRust();
      final first = await LocalSshd.start(), second = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> screenshot(String name, {bool Function()? clean}) async {
        await tester.pumpAndSettle();
        if (clean != null) {
          expect(
            clean(),
            true,
            reason: 'only synthetic prompt may appear in committed captures',
          );
        }
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
          path: '${first.directory.path}/agent-gui.vault',
          password: 'synthetic-agent-master',
        );
        await model.load();
        final host = await fixture.save(model, first, 'Agent target fixture');
        final key = await fixture.save(
          model,
          second,
          'Selected app key fixture',
        );
        model.page = WorkPage.hosts;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(host.name).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('认证').last);
        await tester.pumpAndSettle();
        final toggle = find.byKey(const ValueKey('host-agent-forwarding'));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.tap(find.byKey(const ValueKey('save-host')));
        await tester.pumpAndSettle();
        expect(
          (await rust.listHosts())
              .singleWhere((h) => h.id == host.id)
              .agentForwarding,
          true,
        );
        await screenshot('agent-host-option');
        model.confirmHostKey = (_, _) async => true;
        model.openHost(host);
        model.page = WorkPage.workspace;
        model.changed();
        await tester.pumpAndSettle();
        final session = model.sessions.single as LiveTerminalSession,
            c = session.controller;
        await waitFor(() => c.connected, 'GTK Agent fixture connects');
        await fixture.command(
          c,
          "PS1='fixture\$ '; printf '\\033[2J\\033[3J\\033[H%s%s\\n' AGENT_ UI_READY",
        );
        await waitFor(
          () =>
              screen(c).contains('AGENT_UI_READY') &&
              !screen(c).contains('Last login') &&
              !screen(c).contains('@'),
          'synthetic safe prompt',
        );
        await tester.pumpAndSettle();
        Future<void> openAgent() async {
          await tester.tap(
            find.byKey(
              ValueKey('group-menu-${model.tabGroups.values.single.id}'),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('应用内 Agent · 限时授权'));
          await tester.pumpAndSettle();
        }

        await openAgent();
        await tester.tap(find.byKey(ValueKey('agent-key-${key.id}')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('agent-prepare')));
        await tester.pumpAndSettle();
        expect(find.textContaining('SHA256:'), findsWidgets);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('agent-confirm')))
              .onPressed,
          isNull,
        );
        await screenshot(
          'agent-consent',
          clean: () =>
              !screen(c).contains('@') && !screen(c).contains('Last login'),
        );
        await tester.tap(find.text('我信任上述目标，并允许本次限时签名'));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('agent-confirm')));
        await tester.pumpAndSettle();
        expect((await fixture.state(c)).phase, 'Active');
        await tester.tap(find.text('关闭').last);
        await tester.pumpAndSettle();
        expect(
          (await fixture.state(c)).phase,
          'Active',
          reason: 'closing UI does not revoke lease',
        );
        await fixture.command(
          c,
          "ssh-add -T ${fixture.shell('${second.directory.path}/client.pub')} && printf '%s%s\\n' GTK_AGENT_ VERIFIED",
        );
        await waitFor(
          () => screen(c).contains('GTK_AGENT_VERIFIED'),
          'real remote sign and independent OpenSSH verify',
        );
        await openAgent();
        await screenshot(
          'agent-active',
          clean: () =>
              !screen(c).contains('@') && !screen(c).contains('Last login'),
        );
        await tester.tap(find.byKey(const ValueKey('agent-revoke')));
        await tester.pumpAndSettle();
        expect((await fixture.state(c)).phase, 'Revoked');
        expect(c.connected, true);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        await second.close();
        await first.close();
      }
    },
  );
}
