import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

Future<void> mount(WidgetTester tester, WorkbenchModel model) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: model,
          builder: (_, _) => FilesPanel(model: model, pane: model.focus!),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'long paths start at their last breadcrumb and bookmark tools use the second row',
    (tester) async {
      final m = WorkbenchModel()..demo();
      m.focus!.path =
          '/root/${List.generate(15, (i) => 'folder-$i').join('/')}/last-directory';
      await mount(tester, m);
      final view = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('sftp-breadcrumbs-'),
      );
      final scroll = tester.widget<SingleChildScrollView>(view);
      expect(scroll.reverse, isTrue);
      final viewport = tester.getRect(view);
      final tail = tester.getRect(find.text('last-directory'));
      expect(tail.right, lessThanOrEqualTo(viewport.right + 1));
      expect(tail.left, greaterThanOrEqualTo(viewport.left));
      final bookmarks = tester.getCenter(find.byTooltip('书签'));
      final global = tester.getCenter(find.byTooltip('全局书签'));
      final options = tester.getCenter(find.byTooltip('文件视图选项'));
      expect(bookmarks.dy, greaterThan(viewport.bottom));
      expect(bookmarks.dy, closeTo(options.dy, 2));
      expect(global.dy, closeTo(options.dy, 2));
      expect(bookmarks.dx, lessThan(global.dx));
      expect(global.dx, lessThan(options.dx));
      final pane = m.focus!;
      pane.path = '/short';
      m.changed();
      await tester.pumpAndSettle();
      final shortView = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('sftp-breadcrumbs-'),
      );
      expect(
        tester.getRect(find.text('short')).left -
            tester.getRect(shortView).left,
        lessThan(55),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets(
    'first and idle path entry selects all and one outside click exits',
    (tester) async {
      final model = WorkbenchModel()..demo();
      model.focus!.path = '/home/first';
      await mount(tester, model);
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.byKey(const ValueKey('sftp-path-edit-space')));
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('remote-path')),
        );
        expect(field.focusNode!.hasFocus, isTrue);
        expect(
          field.controller!.selection,
          const TextSelection(baseOffset: 0, extentOffset: 11),
        );
        await tester.tapAt(
          tester.getTopLeft(find.byType(FilesPanel)) + const Offset(12, 12),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('remote-path')), findsNothing);
        await tester.pump(const Duration(seconds: 20));
      }
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'deep breadcrumbs reserve an edit hit zone and discard an invalid address',
    (tester) async {
      final model = WorkbenchModel()..demo();
      model.focus!.path = '/root/${List.filled(24, 'deep').join('/')}';
      final loaded = model.focus!.path;
      await mount(tester, model);
      final space = find.byKey(const ValueKey('sftp-path-edit-space'));
      expect(tester.getSize(space).width, 28);
      await tester.tap(space);
      await tester.pumpAndSettle();
      final address = find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == loaded,
      );
      expect(address, findsOneWidget);
      await tester.enterText(address, 'bad-relative-path');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      // Either still editing with the address restored to the loaded path,
      // or focus loss already left edit mode with the breadcrumb restored —
      // both discard the invalid address and keep the loaded path.
      final restored = find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == loaded,
      );
      final breadcrumbBack = find.byKey(const ValueKey('sftp-path-bar'));
      expect(
        restored.evaluate().isNotEmpty || breadcrumbBack.evaluate().isNotEmpty,
        isTrue,
      );
      expect(model.focus!.path, loaded);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'parent placeholder navigates without entering the real file list',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final source = m.focus!;
      final old = source.path;
      await mount(tester, m);
      expect(find.byTooltip('上一级'), findsNothing);
      expect(find.byTooltip('后退'), findsNothing);
      final parent = find.byKey(const ValueKey('sftp-parent-directory'));
      expect(parent, findsOneWidget);
      expect(source.files.any((file) => file.name == '..'), false);
      await tester.tap(parent);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(parent);
      await tester.pumpAndSettle();
      expect(source.path, old.substring(0, old.lastIndexOf('/')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets('two bookmark popups and compact visible unchecked boxes', (
    tester,
  ) async {
    final m = WorkbenchModel()..demo();
    await mount(tester, m);
    for (final tip in ['书签', '全局书签']) {
      await tester.tap(find.byTooltip(tip));
      await tester.pumpAndSettle();
      expect(find.text('收藏当前目录'), findsOneWidget);
      expect(find.byType(PopupMenuDivider), findsWidgets);
      await tester.tapAt(const Offset(790, 550));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('文件视图选项'));
    await tester.pumpAndSettle();
    final checks = find.byType(Checkbox);
    expect(checks, findsNWidgets(3));
    final heights = checks
        .evaluate()
        .map((element) => tester.getSize(find.byWidget(element.widget)).height)
        .toSet();
    expect(heights, {24.0});
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
  testWidgets(
    'file submenu selects another existing host and performs explicit mock copy',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final source = m.focus!, file = m.focus!.files.first;
      final other = m.sessions.firstWhere((s) => s != source);
      other.disconnected = false;
      final initial = other.files.length;
      await mount(tester, m);
      await tester.tap(
        find.text(file.name).first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('复制文件/文件夹名'), findsOneWidget);
      expect(find.text('发送文件/文件夹名至终端'), findsOneWidget);
      // Hover (or focus) opens the cascade; tapping the submenu item works
      // in tests too, then its child item applies the copy target.
      await tester.tap(find.text('复制到'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('${other.host.name} · ${other.path}'));
      await tester.pumpAndSettle();
      expect(other.files.length, initial + 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'newly created file is selected and revealed at the visible list tail',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final source = m.focus!;
      source.files.addAll(
        List.generate(80, (i) => DemoFile('f-$i', 'z-file-$i')),
      );
      await mount(tester, m);
      await tester.tap(find.byTooltip('新建文件'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '文件名称'),
        'aaa-created.txt',
      );
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(source.files.any((file) => file.name == 'aaa-created.txt'), true);
      final listController = tester
          .widget<ListView>(find.byType(ListView).last)
          .controller!;
      expect(
        listController.offset,
        greaterThan(100),
        reason: 'new item must scroll into view',
      );
      final row = find.byKey(const ValueKey('file-aaa-created.txt'));
      expect(row, findsOneWidget);
      expect(tester.widget<Container>(row).color, isNotNull);
      final list = find.ancestor(of: row, matching: find.byType(ListView));
      expect(
        tester.getRect(row).bottom,
        closeTo(tester.getRect(list).bottom, 1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
}
