import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/app.dart';
import 'package:hspterm/prototype/model.dart';

Future<void> mount(
  WidgetTester tester,
  WorkbenchModel model, {
  Size size = const Size(1440, 900),
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = scale;
  tester.view.physicalSize = size * scale;
  await tester.pumpWidget(PrototypeApp(model: model));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'SFTP host preferences save once from the advanced category and reload per host',
    (tester) async {
      final m = WorkbenchModel()..show(WorkPage.hosts);
      final first = m.hosts.first, second = m.hosts[1];
      await mount(tester, m);
      await tester.tap(find.text('SFTP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OSC7 跟随'));
      await tester.tap(find.text('打开 SFTP'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(m.hosts.firstWhere((h) => h.id == first.id).followOsc7, true);
      expect(m.hosts.firstWhere((h) => h.id == first.id).openSftp, false);
      await tester.tap(find.text(second.name).first);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SFTP'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'OSC7 跟随'),
            )
            .value,
        false,
      );
      await tester.tap(find.text(first.name).first);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SFTP'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'OSC7 跟随'),
            )
            .value,
        true,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, '打开 SFTP'),
            )
            .value,
        false,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets(
    'blank startup, select then Enter, terminal navigation and overflow',
    (tester) async {
      final m = WorkbenchModel();
      await mount(tester, m);
      expect(find.text('开始新的连接'), findsOneWidget);
      expect(m.sessions, isEmpty);
      await tester.tap(find.byKey(const ValueKey('home-收藏主机-web')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(m.sessions, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('new-terminal')));
      await tester.pumpAndSettle();
      expect(find.text('开始新的连接'), findsOneWidget);
      await tester.tap(
        find.byKey(ValueKey('tab-overflow-${m.focusedGroupId}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('生产 · Web 服务').last);
      await tester.pumpAndSettle();
      expect(m.sessions, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'sidebar, nested split ratios, temporary maximize and collapse restore',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final first = m.focusedGroupId!;
      m.moveTab(m.tabs[1].id, first, placement: TabPlacement.right);
      m.moveTab(
        m.tabs.last.id,
        m.focusedGroupId!,
        placement: TabPlacement.bottom,
      );
      await mount(tester, m);
      final original = m.sidebarWidth;
      await tester.drag(
        find.byKey(const ValueKey('sidebar-grip')),
        const Offset(45, 0),
      );
      await tester.pumpAndSettle();
      expect(m.sidebarWidth, greaterThan(original));
      final root = m.root as GroupSplit, old = root.ratio;
      await tester.drag(
        find.byKey(
          ValueKey(
            'split-grip-${root.first.groupIds.first}-${root.second.groupIds.first}',
          ),
        ),
        const Offset(65, 0),
      );
      await tester.pumpAndSettle();
      expect(root.ratio, greaterThan(old));
      final p = m.layoutGroups.first;
      await tester.tap(find.byKey(ValueKey('maximize-${p.id}')));
      await tester.pumpAndSettle();
      expect(m.maximizedGroupId, p.id);
      await tester.tap(find.text('恢复布局'));
      await tester.pumpAndSettle();
      expect(m.maximizedGroupId, isNull);
      await tester.tap(find.byKey(const ValueKey('collapse-sftp')));
      await tester.pumpAndSettle();
      expect(m.sidebar, false);
      final width = m.sidebarWidth;
      m.selectTab(m.tabs.last.id);
      await tester.pumpAndSettle();
      expect(m.sidebarWidth, width);
      expect(m.sidebar, false);
      await tester.tap(find.byKey(const ValueKey('expand-sftp')));
      await tester.pumpAndSettle();
      expect(m.sidebar, true);
      await tester.tap(find.byKey(const ValueKey('maximize-files')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('file-README.md'))).left,
        lessThan(15),
      );
      await tester.tap(find.byKey(const ValueKey('maximize-files')));
      await tester.pumpAndSettle();
      await mount(tester, m, size: const Size(720, 540));
      expect(find.text('空间不足 · 临时折叠'), findsWidgets);
      expect(m.root, same(root));
      await mount(tester, m);
      expect(find.text('空间不足 · 临时折叠'), findsNothing);
      expect(m.sessions, hasLength(3));
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'files: navigation, F2 base-name selection, cancel/delete and context menu',
    (tester) async {
      final m = WorkbenchModel()..openHost(WorkbenchModel().hosts.first);
      await mount(tester, m);
      final folder = find.byKey(const ValueKey('file-config'));
      await tester.tap(folder);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(folder);
      await tester.pumpAndSettle();
      expect(m.focus!.path, endsWith('/config'));
      await tester.tap(find.byKey(const ValueKey('file-README.md')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      final rename = find.byKey(const ValueKey('inline-rename-field'));
      expect(rename, findsOneWidget);
      final edit = tester.widget<TextField>(rename);
      expect(
        edit.controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 6),
      );
      await tester.enterText(rename, 'NOTES.md');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('file-NOTES.md')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      // Rename field may still own focus; select row to restore list keyboard scope.
      if (find.text('取消').evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('file-NOTES.md')));
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('file-NOTES.md')), findsOneWidget);
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('file-NOTES.md'))),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('复制路径'), findsOneWidget);
      expect(find.text('发送路径至终端'), findsOneWidget);
      await tester.tap(find.text('复制文件/文件夹名'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'queue inline details, state changes, multiselect and internal maximize',
    (tester) async {
      final m = WorkbenchModel()..demo();
      await mount(tester, m);
      final root = m.root;
      await tester.tap(find.byKey(const ValueKey('maximize-queue')));
      await tester.pumpAndSettle();
      expect(m.queueMaximized, true);
      expect(m.root, same(root));
      final task = m.transfers.first;
      await tester.tap(find.byKey(ValueKey('expand-${task.id}')));
      await tester.pumpAndSettle();
      expect(find.text('文件 128 · 目录 12 · 成功 119 · 失败 2'), findsOneWidget);
      await tester.tap(find.text(task.name));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('pause-${task.id}')));
      await tester.pumpAndSettle();
      expect(task.state, TransferState.paused);
      final second = m.transfers[1];
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text(second.name));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('batch-pause')));
      await tester.pumpAndSettle();
      expect(second.state, TransferState.paused);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets('host validation and unsaved edits block page navigation', (
    tester,
  ) async {
    final m = WorkbenchModel();
    await mount(tester, m);
    await tester.tap(find.byKey(const ValueKey('nav-hosts')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('host-主机名称')), '未保存主机');
    await tester.tap(find.byKey(const ValueKey('new-terminal')));
    await tester.pumpAndSettle();
    expect(find.text('保留未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(m.page, WorkPage.hosts);
    await tester.tap(find.byKey(const ValueKey('new-terminal')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('丢弃'));
    await tester.pumpAndSettle();
    expect(m.page, WorkPage.workspace);
    await tester.tap(find.byKey(const ValueKey('nav-hosts')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-host')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-host')));
    await tester.pumpAndSettle();
    expect(find.text('请输入主机名称'), findsOneWidget);
    expect(find.text('请输入有效地址（不含空白）'), findsOneWidget);
    expect(m.hosts, hasLength(4));
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
  testWidgets(
    'tab drag reorders actual tabs; file drag highlights and moves mock data',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final primary = m.tabs.last.id, before = m.tabs.first.id;
      m.selectTab(primary);
      await mount(tester, m);
      final tabDrag = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('tab-$primary'))),
        kind: PointerDeviceKind.mouse,
      );
      await tabDrag.moveBy(const Offset(0, 20));
      await tester.pump();
      await tabDrag.moveTo(
        tester.getCenter(find.byKey(ValueKey('tab-$before'))),
      );
      await tester.pump();
      await tabDrag.up();
      await tester.pumpAndSettle();
      expect(m.tabs.first.id, primary);
      m.selectTab(before);
      await tester.pumpAndSettle();
      final source = find.byKey(const ValueKey('file-README.md'));
      final target = find.byKey(const ValueKey('file-config'));
      final gesture = await tester.startGesture(
        tester.getTopLeft(source) + const Offset(60, 15),
      );
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump();
      await gesture.moveTo(tester.getTopLeft(target) + const Offset(65, 15));
      await tester.pump(const Duration(milliseconds: 100));
      final colors = tester.widgetList<ColoredBox>(
        find.descendant(
          of: find.byKey(const ValueKey('drop-folder-config')),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(colors.any((c) => c.color.a > 0), true);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(m.focus!.files.any((f) => f.name == 'README.md'), false);
      expect(
        m.focus!.directories['/home/ubuntu/project/config']!.any(
          (f) => f.name == 'README.md',
        ),
        true,
      );
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets('cancel exit and reject file Ctrl+C/X/V actions', (tester) async {
    final m = WorkbenchModel()..demo();
    await mount(tester, m);
    final count = m.focus!.files.length;
    await tester.tapAt(
      tester.getTopLeft(find.byKey(const ValueKey('file-README.md'))) +
          const Offset(60, 15),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    for (final k in [
      LogicalKeyboardKey.keyC,
      LogicalKeyboardKey.keyX,
      LogicalKeyboardKey.keyV,
    ]) {
      await tester.sendKeyEvent(k);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(m.focus!.files.length, count);
    await tester.tap(find.byTooltip('关闭窗口'));
    await tester.pumpAndSettle();
    expect(find.text('退出 HSPTerm 原型？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(m.sessions, hasLength(3));
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
  testWidgets('batch host edit preserves unsaved draft on cancellation', (
    tester,
  ) async {
    final m = WorkbenchModel();
    await mount(tester, m);
    await tester.tap(find.byKey(const ValueKey('nav-hosts')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('host-主机名称')),
      'draft retained',
    );
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量编辑 1'));
    await tester.pumpAndSettle();
    expect(find.text('保留未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('host-主机名称')))
          .controller!
          .text,
      'draft retained',
    );
    expect(m.hosts.first.name, '生产 · Web 服务');
    await tester.tap(find.text('批量编辑 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('丢弃'));
    await tester.pumpAndSettle();
    expect(find.text('批量编辑 1 台主机'), findsOneWidget);
    await tester.tap(find.text('应用到模拟主机'));
    await tester.pumpAndSettle();
    expect(m.hosts.first.group, '开发环境');
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
  testWidgets(
    'all pages and states lay out at desktop sizes and display scales',
    (tester) async {
      final m = WorkbenchModel()..demo();
      for (final size in [
        const Size(720, 540),
        const Size(1024, 640),
        const Size(1440, 900),
      ]) {
        for (final light in [false, true]) {
          m.light = light;
          for (final page in WorkPage.values) {
            m.show(page);
            await mount(tester, m, size: size, scale: light ? 2 : 1.5);
            expect(
              tester.takeException(),
              isNull,
              reason: '$size $page light=$light',
            );
          }
        }
      }
      m.show(WorkPage.settings);
      await mount(tester, m);
      for (final category in [
        '终端与输入',
        '快捷键',
        'SSH 连接',
        'SFTP 与传输',
        '历史命令联想',
        '彩色高亮',
        '加密与同步',
        '外观',
      ]) {
        await tester.tap(find.byKey(ValueKey('settings-$category')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      final previousTheme = m.light;
      await tester.tap(find.byKey(const ValueKey('theme-light')));
      await tester.pumpAndSettle();
      expect(m.light, previousTheme);
      await tester.tap(find.byKey(const ValueKey('settings-apply')));
      await tester.pumpAndSettle();
      expect(m.light, true);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
}
