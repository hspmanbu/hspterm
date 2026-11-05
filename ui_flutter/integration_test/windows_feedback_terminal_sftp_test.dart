import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';

import '../test/native_bridge_test.dart' show waitFor, screen;
import '../test/support/local_sshd.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK real Bash, SFTP properties, new file and safe path insertion retain one SSH identity',
    (tester) async {
      await initializeRust();
      final ssh = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> shot(String name) async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/hspterm-feedback-second-$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      }

      try {
        await File('${ssh.directory.path}/.bashrc')
            .writeAsString("PS1='feedback> '; PROMPT_COMMAND=()\n");
        await rust.unlockVault(
          path: '${ssh.directory.path}/ui.vault',
          password: 'synthetic-feedback-master',
        );
        await model.load();
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            'Feedback loopback',
            '127.0.0.1',
            (await rust.hostGroups()).first.name,
            user: ssh.username,
            port: ssh.port,
            auth: '私钥',
            openSftp: false,
            shellIntegration: true,
          ),
          secret: ssh.privateKey,
          passphrase: 'test-only-passphrase',
        );
        model.confirmHostKey = (_, _) async => true;
        model.openHost(host);
        final source = model.focus! as LiveTerminalSession;
        final c = source.controller;
        await waitFor(() => c.connected, 'GTK Bash prompt');
        final directory = await Directory('${ssh.directory.path}/browse')
            .create();
        final folder = await Directory('${directory.path}/folder').create();
        await File('${folder.path}/payload.txt').writeAsString('12345');
        await model.loadDirectory(source, directory.path);
        model.sidebarWidth = 420;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await waitFor(
          () => screen(c).contains('feedback>'),
          'mounted Bash frame',
        );
        final resized = await Process.run('python3', [
          'benchmark/resize_x11.py',
          '$pid',
          '1280',
          '800',
        ]);
        expect(resized.exitCode, 0, reason: resized.stderr.toString());
        await tester.pumpAndSettle();
        final id = c.id!, generation = c.generation;
        expect(
          find.byKey(const ValueKey('sftp-parent-directory')),
          findsOneWidget,
        );
        await tester.tap(
          find.text('folder').first,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('属性'));
        await tester.pumpAndSettle();
        await waitFor(
          () => find.textContaining('5 B').evaluate().isNotEmpty,
          'actual recursive folder size',
        );
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextField, '所有者 UID'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await shot('properties');
        await tester.tap(find.text('关闭').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('新建文件'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, '文件名称'),
          'new 中文.txt',
        );
        await tester.tap(find.text('创建'));
        await tester.pumpAndSettle();
        await waitFor(
          () => source.files.any((f) => f.name == 'new 中文.txt'),
          'new exclusive file',
        );
        await tester.pumpAndSettle();
        final row = find.byKey(const ValueKey('file-new 中文.txt'));
        expect(row, findsOneWidget);
        expect(tester.widget<Container>(row).color, isNotNull);
        expect(await File('${directory.path}/new 中文.txt').length(), 0);
        await waitFor(() => screen(c).contains('feedback>'), 'current prompt');
        await tester.tap(row, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('发送路径至终端'));
        await tester.pumpAndSettle();
        await waitFor(
          () => screen(c).contains('new 中文.txt'),
          'controlled literal path reached Bash',
        );
        expect(c.id, id);
        expect(c.generation, generation);
        expect(await rust.listTransferTasks(), isEmpty);
        final before = screen(c);
        c.resize(0, 0, 0, 0);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          screen(c),
          before,
          reason: 'invalid minimized viewport does not clear the PTY',
        );
        await shot('workbench');
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
