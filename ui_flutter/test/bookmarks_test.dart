import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/bookmarks.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/prototype/model.dart';

Future<void> mount(
  WidgetTester tester,
  WorkbenchModel model,
  TerminalSession source,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Desk.theme(false),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDirectoryBookmarks(context, model, source),
            child: const Text('bookmarks'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('bookmarks'));
  await tester.pumpAndSettle();
}

class PendingBookmarks extends WorkbenchModel {
  final pending = Completer<List<PathBookmark>>();
  @override
  Future<List<PathBookmark>> listPathBookmarks(TerminalSession session) =>
      pending.future;
}

void main() {
  testWidgets('bookmark dialogs fit small windows and enlarged text', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final scale in [1.0, 1.5]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 460);
      final model = WorkbenchModel()..demo();
      final source = model.sessions.first;
      await model.savePathBookmark(
        source,
        name: '目录' * 100,
        path: '/中文 空格/project',
        global: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDirectoryBookmarks(context, model, source),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('bookmark-save')));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    }
  });
  testWidgets(
    'bookmark validation, edit, delete cancellation and original-session navigation',
    (tester) async {
      final model = WorkbenchModel()..demo();
      final source = model.sessions.first;
      final other = model.sessions.last;
      source.path = '/project 中文';
      final originalOtherPath = other.path;
      await mount(tester, model, source);
      await tester.tap(find.byKey(const ValueKey('bookmark-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('bookmark-name')), '');
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-path')),
        'relative',
      );
      await tester.tap(find.byKey(const ValueKey('bookmark-save')));
      await tester.pumpAndSettle();
      expect(find.text('请输入书签名称'), findsOneWidget);
      expect(find.text('请输入绝对远端路径'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-name')),
        'project',
      );
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-path')),
        r"/project 中文 ' $; é",
      );
      await tester.tap(find.byKey(const ValueKey('bookmark-global')));
      await tester.tap(find.byKey(const ValueKey('bookmark-save')));
      await tester.pumpAndSettle();
      expect((await model.listPathBookmarks(other)).single.name, 'project');
      await tester.tap(find.byTooltip('编辑书签 project'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('bookmark-name')),
        'renamed',
      );
      await tester.tap(find.byKey(const ValueKey('bookmark-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除书签 renamed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect((await model.listPathBookmarks(source)), hasLength(1));
      model.selectTab(model.tabs.last.id); // the dialog must keep its source
      await tester.tap(find.text('renamed'));
      await tester.pumpAndSettle();
      expect(source.path, r"/project 中文 ' $; é");
      expect(other.path, originalOtherPath);
      await tester.tap(find.text('bookmarks'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除书签 renamed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除书签'));
      await tester.pumpAndSettle();
      expect(await model.listPathBookmarks(source), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'late bookmark responses after dialog disposal never update a dead widget',
    (tester) async {
      final model = PendingBookmarks()..demo();
      final source = model.sessions.first;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDirectoryBookmarks(context, model, source),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      model.pending.completeError(StateError('controlled late load failure'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
