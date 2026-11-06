import 'package:flutter/material.dart';
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

void main() {
  testWidgets(
    'vertical scrollbar track is pinned at the panel right edge and never moves with horizontal scroll',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final source = m.focus!;
      source.files.addAll(
        List.generate(300, (i) => DemoFile('f-$i', 'bulk-file-$i')),
      );
      await mount(tester, m);

      final panel = tester.getRect(find.byType(FilesPanel));
      final list = find.byType(ListView).evaluate().single;
      final vertical = (list.widget as ListView).controller!;
      vertical.jumpTo(600);
      await tester.pump();

      // The vertical RawScrollbar wraps the horizontal viewport: its box
      // spans the full list area and its thumb hugs the panel's right edge.
      final bars = tester
          .widgetList<RawScrollbar>(find.byType(RawScrollbar))
          .toList();
      expect(bars.length, 2);
      final verticalBar = bars.firstWhere(
        (b) => b.scrollbarOrientation == ScrollbarOrientation.right,
      );
      final verticalBox =
          tester.renderObject(
            find.byWidgetPredicate(
              (w) =>
                  w is RawScrollbar &&
                  w.scrollbarOrientation == ScrollbarOrientation.right,
            ),
          ) as RenderBox;
      final rect = verticalBox.localToGlobal(Offset.zero) & verticalBox.size;
      expect(rect.right, closeTo(panel.right, 1));
      expect(verticalBar.padding?.resolve(TextDirection.ltr).bottom, 14,
          reason: 'bottom padding keeps the corner clear of the horizontal '
              'thumb');

      // Wide content scrolls horizontally; the pinned track stays put.
      final horizontalBar = bars.firstWhere(
        (b) => b.scrollbarOrientation == ScrollbarOrientation.bottom,
      );
      expect(horizontalBar.controller, isNotNull);
      horizontalBar.controller!.jumpTo(400);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final rectAfter =
          verticalBox.localToGlobal(Offset.zero) & verticalBox.size;
      expect(rectAfter.right, closeTo(panel.right, 1),
          reason: 'vertical track stays pinned during horizontal scroll');

      // Dragging the vertical controller moves the thumb (same axis).
      vertical.jumpTo(1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
}
