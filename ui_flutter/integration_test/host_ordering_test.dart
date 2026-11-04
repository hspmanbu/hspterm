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
    'GTK formal ordering edits persist only after preview and create no SSH sessions',
    (tester) async {
      await initializeRust();
      final dir = await Directory.systemTemp.createTemp(
        'hspterm-ordering-gtk-',
      );
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> until(bool Function() condition) async {
        final end = DateTime.now().add(const Duration(seconds: 15));
        while (!condition()) {
          if (DateTime.now().isAfter(end)) {
            throw StateError('ordering GTK fixture timed out');
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
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/hspterm-host-order-$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      Future<void> drag(Finder grip, Finder target) async {
        final from = tester.getCenter(grip), rect = tester.getRect(target);
        final gesture = await tester.startGesture(from);
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump();
        await gesture.moveTo(Offset(rect.center.dx, rect.top + 4));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      try {
        await rust.unlockVault(
          path: '${dir.path}/ordering.vault',
          password: 'synthetic-gtk-ordering-master',
        );
        await rust.createHostGroup(name: '开发环境');
        await rust.createHostGroup(name: '生产环境');
        await model.load();
        final hosts = <DemoHost>[];
        for (var i = 0; i < 3; i++) {
          hosts.add(
            await model.persistHost(
              DemoHost(
                model.nextId(),
                ['开发服务器', '生产服务器', '备份服务器'][i],
                'fixture-$i.invalid',
                i == 0 ? '开发环境' : '未分组',
                user: 'fixture',
                auth: '密码',
                openSftp: false,
              ),
              secret: 'synthetic-gtk-ordering-password',
            ),
          );
        }
        model.show(WorkPage.hosts);
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('host-ordering')));
        await until(
          () => find
              .byKey(ValueKey('host-grip-${hosts[0].id}'))
              .evaluate()
              .isNotEmpty,
        );
        final view = await rust.loadHostOrdering(),
            prod = view.groups.singleWhere((g) => g.name == '生产环境').id;
        await drag(
          find.byKey(ValueKey('host-grip-${hosts[0].id}')),
          find.byKey(ValueKey('order-group-$prod')),
        );
        await tester.tap(find.byKey(ValueKey('order-favorite-${hosts[0].id}')));
        await tester.pump();
        await drag(
          find.byKey(ValueKey('group-grip-$prod')),
          find.byKey(const ValueKey('order-group-group-default')),
        );
        await drag(
          find.byKey(ValueKey('host-grip-${hosts[2].id}')),
          find.byKey(ValueKey('order-host-${hosts[0].id}')),
        );
        expect((await rust.loadHostOrdering()).revision, view.revision);
        await screenshot('proposal');
        await tester.tap(find.byKey(const ValueKey('order-save')));
        await tester.pumpAndSettle();
        await screenshot('confirmation');
        await tester.tap(find.text('保存更改'));
        await until(
          () => find.byKey(const ValueKey('order-save')).evaluate().isEmpty,
        );
        await tester.pumpAndSettle();
        final after = await rust.loadHostOrdering();
        expect(after.hosts.first.id, hosts[2].id);
        expect(after.groups.first.id, prod);
        expect(
          after.hosts.singleWhere((h) => h.id == hosts[0].id).groupId,
          prod,
        );
        expect(
          after.hosts.singleWhere((h) => h.id == hosts[0].id).favorite,
          true,
        );
        expect(model.hosts.first.id, hosts[2].id);
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
