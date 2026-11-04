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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK actual history preference and clear confirmations persist without collecting terminal data',
    (tester) async {
      await initializeRust();
      final dir = await Directory.systemTemp.createTemp(
        'hspterm-history-controls-gtk-',
      );
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Finder keyed(String key) => find.byKey(ValueKey(key));
      Future<void> until(bool Function() condition) async {
        final end = DateTime.now().add(const Duration(seconds: 15));
        while (!condition()) {
          if (DateTime.now().isAfter(end)) {
            throw StateError('history controls GTK fixture timed out');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump();
      }

      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/hspterm-history-controls-$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      }

      try {
        await rust.unlockVault(
          path: '${dir.path}/history.vault',
          password: 'synthetic-history-controls-gtk-master',
        );
        await model.load();
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            '合成历史设置主机',
            'fixture.invalid',
            '未分组',
            auth: '密码',
            openSftp: false,
          ),
          secret: 'synthetic-history-gtk-password',
        );
        model.show(WorkPage.settings);
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(keyed('settings-历史命令联想'));
        await until(
          () =>
              keyed('history-enabled').evaluate().isNotEmpty &&
              tester
                      .widget<SwitchListTile>(keyed('history-enabled'))
                      .onChanged !=
                  null,
        );
        final first = await rust.commandHistoryControls();
        await tester.tap(keyed('history-enabled'));
        await tester.pump();
        expect((await rust.commandHistoryControls()).revision, first.revision);
        await tester.ensureVisible(keyed('settings-apply'));
        await tester.tap(keyed('settings-apply'));
        await until(() => keyed('history-status').evaluate().isNotEmpty);
        expect((await rust.commandHistoryControls()).enabled, false);
        await screenshot('settings');
        await tester.ensureVisible(keyed('history-clear-${host.id}'));
        await tester.tap(keyed('history-clear-${host.id}'));
        await tester.pumpAndSettle();
        expect(find.text('清空此主机命令历史？'), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('取消'),
          ),
        );
        await tester.pumpAndSettle();
        final before = await rust.commandHistoryControls();
        await tester.ensureVisible(keyed('history-clear-all'));
        await tester.tap(keyed('history-clear-all'));
        await tester.pumpAndSettle();
        expect(find.text('清空全部命令历史？'), findsOneWidget);
        expect((await rust.commandHistoryControls()).revision, before.revision);
        await screenshot('confirmation');
        await tester.tap(keyed('history-confirm-clear'));
        await until(() => keyed('history-status').evaluate().isNotEmpty);
        final cleared = await rust.commandHistoryControls();
        expect(cleared.revision, isNot(before.revision));
        expect(cleared.total, 0);
        expect(cleared.enabled, false);
        expect(model.sessions, isEmpty);
        expect(model.tabs, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
