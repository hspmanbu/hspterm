import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

Future<void> openColumns(WidgetTester tester) async {
  await tester.tap(find.byTooltip('文件视图选项'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('显示与排列列…'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'column visibility is applied explicitly and cancelling preserves the current layout',
    (tester) async {
      final model = WorkbenchModel()..demo();
      final source = model.focus!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              child: FilesPanel(model: model, pane: source),
            ),
          ),
        ),
      );
      await openColumns(tester);
      await tester.tap(find.byKey(const ValueKey('configure-file-column-modified')));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('修改时间'), findsOneWidget);
      await openColumns(tester);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('configure-file-column-name')),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('configure-file-column-modified')));
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(find.text('修改时间'), findsNothing);
      expect(find.byKey(const ValueKey('file-column-modified')), findsNothing);
      expect(find.byKey(const ValueKey('file-column-name')), findsOneWidget);
      expect(source.entered, isEmpty);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'column order controls move header and data together without changing file selection identities',
    (tester) async {
      final model = WorkbenchModel()..demo();
      final source = model.focus!;
      final original = source.files.map((f) => f.id).toList();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              child: FilesPanel(model: model, pane: source),
            ),
          ),
        ),
      );
      await openColumns(tester);
      // Exercise the reordering callback independently of OS pointer conventions.
      tester
          .widget<ReorderableListView>(find.byType(ReorderableListView))
          .onReorderItem!(0, 3);
      await tester.pump();
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.byKey(const ValueKey('file-column-name'))).dx,
        greaterThan(
          tester.getCenter(find.byKey(const ValueKey('file-column-kind'))).dx,
        ),
      );
      expect(source.files.map((f) => f.id).toList(), original);
      expect(source.entered, isEmpty);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
