import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

Future<void> mount(WidgetTester tester, WorkbenchModel model) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 700,
          child: AnimatedBuilder(
            animation: model,
            builder: (_, _) => FilesPanel(model: model, pane: model.focus!),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> beginRename(WidgetTester tester, WorkbenchModel model) async {
  final file = model.focus!.files.first;
  await tester.tap(find.text(file.name));
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(LogicalKeyboardKey.f2);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'rename editor border spans (nearly) the whole list row height',
    (tester) async {
      final m = WorkbenchModel()..demo();
      await mount(tester, m);
      await beginRename(tester, m);

      final editor = find.byKey(const ValueKey('inline-rename'));
      expect(editor, findsOneWidget);
      final editorBox = tester.renderObject(editor) as RenderBox;
      final rowBox = tester.renderObject(
        find.byWidgetPredicate(
          (w) => w is Container && w.key == ValueKey('file-${m.focus!.files.first.name}'),
        ),
      ) as RenderBox;

      // The decoration's rendered box must fill the row container minus a
      // small design margin (padding left 34 / right 10 is horizontal only).
      final editorHeight = editorBox.size.height;
      final rowHeight = rowBox.size.height;
      expect(editorHeight, greaterThanOrEqualTo(rowHeight - 2),
          reason: 'editor border must hug the full row height');
      // Horizontal: editor starts after the icon gutter and ends near the
      // row's right edge.
      final editorTop = editorBox.localToGlobal(Offset.zero);
      final rowTop = rowBox.localToGlobal(Offset.zero);
      expect(editorTop.dx, greaterThanOrEqualTo(rowTop.dx + 30));
      expect(editorTop.dx + editorBox.size.width,
          lessThanOrEqualTo(rowTop.dx + rowBox.size.width + 1));

      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets('editor keeps full row height in compact mode and after zoom', (
    tester,
  ) async {
    final m = WorkbenchModel()..demo();
    await mount(tester, m);
    // Compact mode via view options
    await tester.tap(find.byTooltip('文件视图选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('紧凑列表'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(790, 550));
    await tester.pumpAndSettle();
    await beginRename(tester, m);
    final editorBox =
        tester.renderObject(find.byKey(const ValueKey('inline-rename')))
            as RenderBox;
    expect(editorBox.size.height, greaterThanOrEqualTo(24));

    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
}
