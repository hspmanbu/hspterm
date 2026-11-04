import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/forwardings/runtime.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';

import '../test/native_bridge_test.dart' show waitFor;
import '../test/forwarding_runtime_bridge_test.dart' show echo;
import '../test/support/local_sshd.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK forwarding forms save actual rules and start stop L R D on the original SSH without layout changes',
    (tester) async {
      await initializeRust();
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      final server = await LocalSshd.start();
      final echoServer = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final sockets = <Socket>{};
      final accepts = echoServer.listen((socket) {
        sockets.add(socket);
        socket.listen(
          socket.add,
          onDone: () {
            sockets.remove(socket);
            socket.destroy();
          },
          onError: (Object _) {
            sockets.remove(socket);
            socket.destroy();
          },
        );
      });
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
          path: '${server.directory.path}/forwarding-ui.vault',
          password: 'synthetic-forward-ui-master',
        );
        await model.load();
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            'GTK forwarding fixture',
            '127.0.0.1',
            '未分组',
            port: server.port,
            user: server.username,
            auth: '私钥',
            openSftp: false,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        model.openHost(host);
        final session = model.focus! as LiveTerminalSession;
        await waitFor(
          () =>
              session.controller.connected || session.controller.error != null,
          'GTK forwarding SSH',
        );
        expect(
          session.controller.connected,
          true,
          reason: session.controller.error,
        );
        final native = session.controller.id!,
            generation = session.controller.generation;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(ValueKey('group-menu-${model.focusedGroupId}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('当前终端端口转发'));
        await tester.pumpAndSettle();
        for (final (kind, label) in [
          ('local', '本地 L · 本机 → 服务器目标'),
          ('remote', '远端 R · 服务器 → 本机目标'),
          ('dynamic', '动态 D · 本机 SOCKS5'),
        ]) {
          final add = find.byKey(const ValueKey('forward-add'));
          await tester.ensureVisible(add);
          await tester.tap(add);
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('forward-name')),
            'GTK $kind',
          );
          if (kind != 'local') {
            await tester.tap(find.byKey(const ValueKey('forward-kind')));
            await tester.pumpAndSettle();
            await tester.tap(find.text(label).last);
            await tester.pumpAndSettle();
          }
          if (kind != 'dynamic') {
            await tester.enterText(
              find.byKey(const ValueKey('forward-target-port')),
              echoServer.port.toString(),
            );
          }
          final restore = find.byKey(const ValueKey('forward-restore'));
          await tester.ensureVisible(restore);
          await tester.tap(restore);
          await tester.pumpAndSettle();
          if (kind == 'local') await screenshot('forwarding-restore-rule');
          final save = find.byKey(const ValueKey('forward-save'));
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pumpAndSettle();
        }
        final rules = await rust.forwardingRules(hostId: host.id);
        expect(rules.map((r) => r.kind), ['local', 'remote', 'dynamic']);
        expect(rules.every((r) => r.restoreOnReconnect), true);
        await screenshot('forwarding-config');
        for (final rule in rules) {
          final button = find.byKey(ValueKey('forward-start-${rule.id}'));
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pumpAndSettle();
          RunStatus? live;
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (live?.phase != 'listening') {
            live = (await rust.terminalForwardings(id: native))
                .where((r) => r.ruleId == rule.id)
                .firstOrNull;
            if (DateTime.now().isAfter(deadline)) {
              throw TimeoutException('GTK ${rule.kind} startup');
            }
            await tester.pump(const Duration(milliseconds: 50));
          }
          await echo(live!, echoServer.port, socks: rule.kind == 'dynamic');
        }
        await tester.tap(find.byTooltip('刷新状态'));
        await tester.pumpAndSettle();
        final live = await rust.terminalForwardings(id: native);
        expect(live, hasLength(3));
        final stop = find.byKey(ValueKey('forward-stop-${live.first.token}'));
        await tester.ensureVisible(stop);
        await screenshot('forwarding-running');
        await tester.tap(stop);
        await tester.pumpAndSettle();
        expect(
          (await rust.terminalForwardings(id: native)).first.phase,
          'stopped',
        );
        // Stop outside this view. Only the native metadata invalidation may
        // refresh the panel; no Refresh click or periodic UI timer is used.
        await rust.stopForwarding(
          id: native,
          generation: generation,
          token: live[1].token,
        );
        final updateDeadline = DateTime.now().add(const Duration(seconds: 3));
        while (find.text('GTK remote · 已停止').evaluate().isEmpty) {
          if (DateTime.now().isAfter(updateDeadline)) {
            throw TimeoutException(
              'native forwarding notification did not update the open GTK panel',
            );
          }
          await tester.pump(const Duration(milliseconds: 50));
        }
        final close = find.byTooltip('关闭');
        await tester.ensureVisible(close);
        await tester.tap(close);
        await tester.pumpAndSettle();
        model.page = WorkPage.hosts;
        model.changed();
        await tester.pumpAndSettle();
        final state = tester.state<HostManagerState>(find.byType(HostManager));
        await state.choose(host);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(HostManager),
            matching: find.text('进阶'),
          ),
        );
        await tester.pumpAndSettle();
        final configure = find.byKey(const ValueKey('host-forwardings'));
        await tester.ensureVisible(configure);
        await screenshot('forwarding-host-settings');
        await tester.tap(configure);
        await tester.pumpAndSettle();
        expect(find.text('端口转发 · GTK forwarding fixture'), findsOneWidget);
        expect(
          (await rust.terminalForwardings(id: native))
              .where((r) => r.phase == 'listening'),
          hasLength(1),
        );
        expect(session.controller.id, native);
        expect(session.controller.generation, generation);
        expect(model.sessions, hasLength(1));
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        model.page = WorkPage.workspace;
        model.changed();
        await tester.pumpAndSettle();
        await rust.disconnectTerminal(id: native);
        await tester.pumpAndSettle();
        expect(find.text('重新连接'), findsOneWidget);
        await tester.tap(find.text('重新连接'));
        final restoreDeadline = DateTime.now().add(const Duration(seconds: 10));
        List<RunStatus> restored = [];
        do {
          await tester.pump(const Duration(milliseconds: 50));
          restored = await rust.terminalForwardings(id: native);
          if (DateTime.now().isAfter(restoreDeadline)) {
            throw TimeoutException(
              'GTK explicit reconnect forwarding restoration',
            );
          }
        } while (!session.controller.connected ||
            restored.length != 3 ||
            restored.any((r) => r.phase != 'listening'));
        expect(session.controller.generation, greaterThan(generation));
        expect(session.controller.id, native);
        expect(model.sessions, hasLength(1));
        for (final running in restored) {
          expect(running.generation, session.controller.generation);
          expect(live.map((r) => r.token), isNot(contains(running.token)));
          await echo(
            running,
            echoServer.port,
            socks: running.kind == 'dynamic',
          );
        }
        await tester.tap(
          find.byKey(ValueKey('group-menu-${model.focusedGroupId}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('当前终端端口转发'));
        await tester.pumpAndSettle();
        await screenshot('forwarding-restored');
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        for (final socket in sockets.toList()) {
          socket.destroy();
        }
        await accepts.cancel();
        await echoServer.close();
        await server.close();
      }
    },
  );
}
