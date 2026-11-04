import 'dart:async';
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

import '../test/native_bridge_test.dart' show waitFor;
import '../test/support/local_sshd.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK saved-host handshake confirms TOFU, reports its limited scope and cancels a stalled proxy',
    (tester) async {
      await initializeRust();
      final server = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final greeting = Completer<void>(), closed = Completer<void>();
      Socket? client;
      final subscription = listener.listen((socket) {
        client = socket;
        socket.listen(
          (bytes) {
            if (!greeting.isCompleted) greeting.complete();
          },
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
        );
      });
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/probe gtk.vault',
          password: 'synthetic GTK probe master',
        );
        await model.load();
        await model.persistHost(
          DemoHost(
            model.nextId(),
            'Handshake-only fixture',
            '127.0.0.1',
            '未分组',
            user: 'synthetic-user-not-present',
            port: server.port,
            auth: '密码',
            openSftp: false,
          ),
          secret: 'invalid synthetic password',
        );
        model.page = WorkPage.hosts;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('测试连接'));
        await tester.pump();
        // Use the real application confirmation dialog, not a fixture callback.
        await waitFor(
          () => find.text('首次连接：确认 SSH 主机指纹').evaluate().isNotEmpty,
          'GTK probe TOFU dialog',
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('信任并保存'));
        await waitFor(
          () => find
              .byKey(const ValueKey('host-test-success'))
              .evaluate()
              .isNotEmpty,
          'GTK handshake-only result',
        );
        await tester.pumpAndSettle();
        expect(model.sessions, isEmpty);
        expect(model.tabs, isEmpty);
        expect(model.recent, isEmpty);
        expect(model.hasActiveSessions, false);
        expect(find.textContaining('不验证目标账号登录认证'), findsOneWidget);
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/hspterm-connection-test.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();

        await model.persistHost(
          DemoHost(
            model.nextId(),
            'Stalled handshake fixture',
            'target.invalid',
            '未分组',
            user: 'fixture',
            auth: '密码',
            timeoutSeconds: 20,
            openSftp: false,
            proxy: DemoProxy(
              socks5: true,
              address: '127.0.0.1',
              port: listener.port,
            ),
          ),
          secret: 'synthetic password',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Stalled handshake fixture'));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text('测试连接'));
        await tester.pump();
        await greeting.future.timeout(const Duration(seconds: 5));
        await tester.pump(const Duration(milliseconds: 250));
        expect(model.hasActiveSessions, true);
        await tester.tap(find.text('取消测试'));
        await waitFor(
          () => !model.hasActiveSessions,
          'GTK explicit probe cancellation',
        );
        await closed.future.timeout(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(find.text('测试已保存的主机'), findsNothing);
        expect(model.sessions, isEmpty);
        expect(model.tabs, isEmpty);
        expect(
          model.operationError,
          isNull,
          reason: 'explicit cancellation is not a global error',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await model.shutdown();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        model.dispose();
        client?.destroy();
        await subscription.cancel();
        await listener.close();
        await server.close();
      }
    },
  );
}
