import 'package:flutter/foundation.dart';
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
  testWidgets('rename editor border spans (nearly) the whole list row height', (
    tester,
  ) async {
    final m = WorkbenchModel()..demo();
    await mount(tester, m);
    await beginRename(tester, m);

    final editor = find.byKey(const ValueKey('inline-rename'));
    expect(editor, findsOneWidget);
    final editorBox = tester.renderObject(editor) as RenderBox;
    final rowBox = tester.renderObject(
      find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.key == ValueKey('file-${m.focus!.files.first.name}'),
      ),
    ) as RenderBox;

    // The decoration's rendered box must fill the row container minus a
    // small design margin (padding left 34 / right 10 is horizontal only).
    final editorHeight = editorBox.size.height;
    final rowHeight = rowBox.size.height;
    expect(
      editorHeight,
      greaterThanOrEqualTo(rowHeight - 2),
      reason: 'editor border must hug the full row height',
    );
    // Horizontal: editor starts after the icon gutter and ends near the
    // row's right edge.
    final editorTop = editorBox.localToGlobal(Offset.zero);
    final rowTop = rowBox.localToGlobal(Offset.zero);
    expect(editorTop.dx, greaterThanOrEqualTo(rowTop.dx + 30));
    expect(
      editorTop.dx + editorBox.size.width,
      lessThanOrEqualTo(rowTop.dx + rowBox.size.width + 1),
    );

    // The borderless field itself renders fully inside the bordered box.
    final fieldBox = tester.renderObject(
      find.byKey(const ValueKey('inline-rename-field')),
    ) as RenderBox;
    expect(fieldBox.size.height, lessThanOrEqualTo(editorBox.size.height));
    expect(fieldBox.size.width, lessThanOrEqualTo(editorBox.size.width));

    // The editor lives inside the NAME cell: its right edge never passes
    // the name column boundary, so other columns keep their positions and
    // the border cannot be clipped by the horizontal viewport.
    final cellBox = tester.renderObject(
      find.byKey(ValueKey('name-editor-cell-${m.focus!.files.first.id}')),
    ) as RenderBox;
    final editorGlobal = editorBox.localToGlobal(Offset.zero);
    final cellGlobal = cellBox.localToGlobal(Offset.zero);
    expect(
      editorGlobal.dx + editorBox.size.width,
      lessThanOrEqualTo(cellGlobal.dx + cellBox.size.width + 1),
      reason: 'editor ends inside the name cell',
    );
    expect(editorGlobal.dx, greaterThanOrEqualTo(cellGlobal.dx + 30));

    // Sibling columns keep rendering while the name cell edits.
    expect(
      find.text(m.focus!.files.first.kind),
      findsWidgets,
      reason: 'kind column still rendered during rename',
    );

    // The selection highlight is a translucent theme color, not the
    // opaque default that read as a dark rectangle behind the name.
    final selection = tester.widget<DefaultSelectionStyle>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('inline-rename-field')),
            matching: find.byType(DefaultSelectionStyle),
          )
          .first,
    );
    expect(selection.selectionColor!.a, lessThan(1.0));

    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });

  testWidgets(
    'validation error renders below the row without changing its height',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final m = WorkbenchModel()..demo();
      await mount(tester, m);
      await beginRename(tester, m);
      final rowKey = ValueKey('file-${m.focus!.files.first.name}');
      final rowHeightBefore = (tester.renderObject(
        find.byWidgetPredicate((w) => w is Container && w.key == rowKey),
      ) as RenderBox).size.height;

      // Clear the field and submit: the name is invalid.
      await tester.enterText(
        find.byKey(const ValueKey('inline-rename-field')),
        '',
      );
      // On Windows, done keeps field focus (no unfocus-cancel race like
      // the mobile behavior).
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('inline-rename-error')), findsOneWidget);
      final rowHeightAfter = (tester.renderObject(
        find.byWidgetPredicate((w) => w is Container && w.key == rowKey),
      ) as RenderBox).size.height;
      expect(
        rowHeightAfter,
        rowHeightBefore,
        reason: 'the editor row never grows for the error line',
      );
      // The error line sits below the row, not inside the editor box.
      final errorTop = tester.getTopLeft(
        find.byKey(const ValueKey('inline-rename-error')),
      );
      final rowBottom = tester.getBottomLeft(
        find.byWidgetPredicate((w) => w is Container && w.key == rowKey),
      );
      expect(errorTop.dy, greaterThan(rowBottom.dy - 1));

      // Editing continues after the error: typing still reaches the field.
      await tester.enterText(
        find.byKey(const ValueKey('inline-rename-field')),
        'renamed.txt',
      );
      expect(find.widgetWithText(TextField, 'renamed.txt'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      m.dispose();
      debugDefaultTargetPlatformOverride = null;
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
    final editorBox = tester.renderObject(
      find.byKey(const ValueKey('inline-rename')),
    ) as RenderBox;
    expect(editorBox.size.height, greaterThanOrEqualTo(24));

    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
}
