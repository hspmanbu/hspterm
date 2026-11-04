import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/prototype/settings.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/terminal_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real settings apply cross-category drafts and startup distinguishes existing Vault',
    (tester) async {
      await initializeRust();
      final directory = await Directory.systemTemp.createTemp(
        'hspterm-settings-feedback-',
      );
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      final path = '${directory.path}/synthetic.vault';
      Future<void> category(String name) async {
        await tester.tap(find.byKey(ValueKey('settings-$name')));
        await tester.pumpAndSettle();
      }

      Future<void> snapshot(String name) async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/hspterm-settings-feedback-$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      }

      try {
        await tester.pumpWidget(WorkbenchApp(vaultPath: path));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('vault-confirm')), findsOneWidget);
        expect(find.text('创建配置库'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await rust.createConfigurationVault(
          path: path,
          password: 'synthetic-settings-only',
        );
        await tester.pumpWidget(WorkbenchApp(vaultPath: path));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('vault-confirm')), findsNothing);
        expect(find.text('解锁配置库'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();

        await model.load();
        await model.appearance.load();
        await model.sftpView.load();
        await model.typography.load();
        model.show(WorkPage.settings);
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        tester
            .widget<DropdownButtonFormField<double>>(
              find.byKey(const ValueKey('typography-字号-15.0')),
            )
            .onChanged!(18);
        await tester.pumpAndSettle();
        await category('终端与输入');
        await tester.enterText(
          find.byKey(const ValueKey('terminal-history-limit')),
          '12345',
        );
        await category('SFTP 与传输');
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('sftp-default-show-hidden')),
            )
            .onChanged!(true);
        await tester.pumpAndSettle();
        expect(model.typography.value.size, 15);
        expect(model.sftpView.value!.settings.showHidden, false);
        await tester.tap(find.byKey(const ValueKey('settings-apply')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(model.typography.value.size, 18);
        expect(model.sftpView.value!.settings.showHidden, true);
        final preferences = TerminalPreferencesSnapshot.decode(
          await rust.loadTerminalPreferences(),
        );
        expect(preferences.value.historyLines, 12345);
        expect(preferences.value.typography!['size'], 18);
        expect(
          await tester
              .state<SettingsPageState>(find.byType(SettingsPage))
              .canLeave(),
          true,
        );
        expect(model.sessions, isEmpty);
        for (final name in [
          '外观',
          '终端与输入',
          '快捷键',
          'SSH 连接',
          'SFTP 与传输',
          '历史命令联想',
          '彩色高亮',
          '加密与同步',
          '运行诊断',
        ]) {
          await category(name);
          expect(tester.takeException(), isNull);
          await snapshot(name);
        }
        final resized = await Process.run('python3', [
          'benchmark/resize_x11.py',
          '$pid',
          '760',
          '620',
        ]);
        expect(
          resized.exitCode,
          0,
          reason: 'resize only the test process window',
        );
        await tester.pumpAndSettle();
        for (final name in [
          '外观',
          '终端与输入',
          '快捷键',
          'SSH 连接',
          'SFTP 与传输',
          '历史命令联想',
          '彩色高亮',
          '加密与同步',
          '运行诊断',
        ]) {
          await category(name);
          expect(tester.takeException(), isNull);
          await snapshot('compact-$name');
        }
        await tester.tap(find.byKey(const ValueKey('settings-ok')));
        await tester.pumpAndSettle();
        expect(model.page, WorkPage.workspace);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
