import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/app.dart';
import 'package:hspterm/prototype/model.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'interactive Ubuntu workbench and review screenshots',
    (tester) async {
      final model = WorkbenchModel();
      final capture = GlobalKey();
      const output = String.fromEnvironment(
        'HSPTERM_SCREENSHOTS',
        defaultValue: '/tmp/hspterm-phase3a-screenshots',
      );
      await Directory(output).create(recursive: true);
      final manifest = <Map<String, Object>>[];
      Future<void> resize(int width, int height) async {
        final result = await Process.run('python3', [
          'benchmark/resize_x11.py',
          '$pid',
          '$width',
          '$height',
        ]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
      }

      Future<void> shot(String name) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$output/$name.png').writeAsBytes(png!.buffer.asUint8List());
        manifest.add({
          'file': '$name.png',
          'width': image.width,
          'height': image.height,
        });
        image.dispose();
      }

      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: PrototypeApp(model: model),
        ),
      );
      await tester.pumpAndSettle();
      await resize(1440, 900);
      expect(model.sessions, isEmpty);
      await shot('01-start-dark');
      await tester.tap(find.byKey(const ValueKey('open-demo')));
      await tester.pumpAndSettle();
      expect(model.sessions, hasLength(3));
      final primary = model.tabs.first.id;
      await shot('16-terminal-tabs-normal');
      final initialGroup = model.focusedGroupId!;
      final second = model.tabs[1].id, third = model.tabs.last.id;
      final sessions = model.sessions;
      await tester.tap(find.byKey(ValueKey('tab-$second')));
      await tester.pumpAndSettle();
      // Real menu interaction splits an existing tab, never opens another host.
      await tester.tap(find.byKey(ValueKey('group-menu-$initialGroup')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('当前标签分屏至右'));
      await tester.pumpAndSettle();
      expect(model.sessions, hasLength(3));
      expect(model.layoutGroups, hasLength(2));
      model.selectTab(primary);
      await tester.pumpAndSettle();
      await shot('02-workbench-dark');
      final rightGroup = model.groupOf(second)!.id;
      final rightArea = tester.getRect(
        find.byKey(ValueKey('terminal-group-$rightGroup')),
      );
      final drag = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('tab-$third'))),
      );
      await drag.moveBy(const Offset(0, 16));
      await tester.pump();
      await drag.moveTo(rightArea.center);
      await tester.pumpAndSettle();
      await shot('20-tab-drop-target');
      await drag.up();
      await tester.pumpAndSettle();
      expect(model.groupOf(third)!.id, rightGroup);
      await tester.tap(find.byKey(ValueKey('tab-$second')));
      await tester.pumpAndSettle();
      await shot('18-split-group-tabs');
      final leftArea = tester.getRect(
        find.byKey(ValueKey('terminal-group-$initialGroup')),
      );
      final back = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('tab-$third'))),
      );
      await back.moveBy(const Offset(0, 16));
      await tester.pump();
      await back.moveTo(leftArea.center);
      await tester.pump();
      await back.up();
      await tester.pumpAndSettle();
      expect(model.groupOf(third)!.id, initialGroup);
      model.selectTab(primary);
      await tester.pumpAndSettle();
      expect(model.sessions, orderedEquals(sessions));

      final tree = model.root;
      final focused = model.focusedGroupId!;
      await tester.tap(find.byKey(ValueKey('maximize-$focused')));
      await tester.pumpAndSettle();
      await shot('17-terminal-group-maximized');
      await tester.tap(find.text('恢复布局'));
      await tester.pumpAndSettle();
      expect(model.root, same(tree));

      await tester.tap(find.byKey(const ValueKey('maximize-queue')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('expand-${model.transfers.first.id}')),
      );
      await tester.pumpAndSettle();
      await shot('03-transfer-details');
      await tester.tap(find.byKey(const ValueKey('maximize-queue')));
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const ValueKey('file-README.md'))) +
            const Offset(55, 13),
        buttons: 2,
      );
      await tester.pumpAndSettle();
      expect(find.text('复制路径'), findsOneWidget);
      await shot('04-file-context-menu');
      await tester.tap(find.text('复制文件/文件夹名'));
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const ValueKey('file-README.md'))) +
            const Offset(55, 13),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inline-rename')), findsOneWidget);
      await shot('05-inline-rename');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      await shot('06-delete-confirmation');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-hosts')));
      await tester.pumpAndSettle();
      await shot('07-host-manager');
      await tester.tap(find.byKey(const ValueKey('new-host')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('save-host')));
      await tester.pumpAndSettle();
      expect(find.text('请输入主机名称'), findsOneWidget);
      await shot('08-host-validation');
      await tester.tap(find.byKey(const ValueKey('app-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await shot('09-settings-dark');
      await tester.tap(find.byKey(const ValueKey('settings-历史命令联想')));
      await tester.pumpAndSettle();
      await shot('10-history-settings');
      await tester.tap(find.byKey(const ValueKey('settings-外观')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('theme-light')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-apply')));
      await tester.pumpAndSettle();
      expect(model.light, true);
      await shot('11-settings-light');
      await tester.tap(find.byKey(const ValueKey('session-list')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('生产 · Web 服务 · 模拟').last);
      await tester.pumpAndSettle();
      await shot('12-workbench-light');
      model.light = false;
      model.changed();
      await resize(720, 540);
      expect(find.text('空间不足 · 临时折叠'), findsWidgets);
      await shot('13-workbench-compact');
      await resize(1440, 900);
      expect(find.text('空间不足 · 临时折叠'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('maximize-files')));
      await tester.pumpAndSettle();
      await shot('14-sftp-maximized');
      await tester.tap(find.byKey(const ValueKey('maximize-files')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭窗口'));
      await tester.pumpAndSettle();
      expect(find.text('退出 HSPTerm 原型？'), findsOneWidget);
      await shot('15-exit-confirmation');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      final group = model.focusedGroupId!;
      await tester.tap(find.byKey(ValueKey('group-menu-$group')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消分屏 · 合并所有标签'));
      await tester.pumpAndSettle();
      expect(model.layoutGroups, hasLength(1));
      expect(model.sessions, orderedEquals(sessions));
      await shot('19-tabs-recombined');
      // Verify the Linux runner registered the optional window channel.
      await prototypeWindow.invokeMethod<void>('maximize');
      await prototypeWindow.invokeMethod<void>('maximize');
      await File('$output/manifest.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'platform': 'Ubuntu / Xvfb, actual Flutter GTK process',
          'data': 'mock only, no SSH or account access',
          'screenshots': manifest,
        }),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      model.dispose();
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
