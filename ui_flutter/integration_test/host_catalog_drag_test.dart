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
    'GTK formal main-list drags persist host/group order, group and favorites without creating SSH',
    (tester) async {
      await initializeRust();
      final dir = await Directory.systemTemp.createTemp(
        'hspterm-catalog-drag-',
      );
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> until(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('catalog drag fixture timed out');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump();
      }

      Future<void> drag(
        Finder from,
        Finder target, {
        bool after = false,
      }) async {
        await tester.ensureVisible(from);
        final start = tester.getCenter(from);
        await tester.ensureVisible(target);
        final rect = tester.getRect(target);
        final gesture = await tester.startGesture(start);
        await gesture.moveBy(const Offset(25, 0));
        await tester.pump();
        await gesture.moveTo(
          Offset(rect.center.dx, after ? rect.bottom - 3 : rect.top + 3),
        );
        await tester.pump();
        await gesture.up();
        await tester.pump();
      }

      try {
        await rust.createConfigurationVault(
          path: '${dir.path}/catalog.vault',
          password: 'synthetic-catalog-drag-master',
        );
        await rust.createHostGroup(name: '目标组');
        await model.load();
        final hosts = <DemoHost>[];
        for (var i = 0; i < 3; i++) {
          hosts.add(
            await model.persistHost(
              DemoHost(
                model.nextId(),
                'Drag $i',
                'fixture-$i.invalid',
                '未分组',
                user: 'fixture',
                auth: '密码',
                openSftp: false,
              ),
              secret: 'synthetic-catalog-password',
            ),
          );
        }
        final group = model.hostGroupEntries
            .singleWhere((g) => g.$2 == '目标组')
            .$1;
        model.show(WorkPage.hosts);
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await drag(
          find.byKey(ValueKey('host-row-${hosts[2].id}')),
          find.byKey(ValueKey('host-row-${hosts[0].id}')),
        );
        await until(() => model.hosts.first.id == hosts[2].id);
        await drag(
          find.byKey(ValueKey('host-row-${hosts[0].id}')),
          find.byKey(ValueKey('host-drop-$group')),
        );
        await until(
          () =>
              model.hosts.singleWhere((h) => h.id == hosts[0].id).group ==
              '目标组',
        );
        await drag(
          find.byKey(ValueKey('host-row-${hosts[0].id}')),
          find.byKey(const ValueKey('host-drop-favorites')),
        );
        await until(
          () => model.hosts.singleWhere((h) => h.id == hosts[0].id).favorite,
        );
        await drag(
          find.byKey(ValueKey('host-drop-$group')),
          find.byKey(const ValueKey('host-drop-group-default')),
        );
        await until(() => model.hostGroupEntries.first.$1 == group);
        final stored = await rust.loadHostOrdering();
        expect(stored.hosts.first.id, hosts[2].id);
        expect(stored.groups.first.id, group);
        expect(model.sessions, isEmpty);
        expect(model.tabs, isEmpty);
        expect(tester.takeException(), isNull);
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/hspterm-host-catalog-drag.png')
              .writeAsBytes(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
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
