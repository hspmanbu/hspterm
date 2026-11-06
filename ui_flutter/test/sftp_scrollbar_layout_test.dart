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
    'vertical scrollbar thumb stays pinned at the panel right edge; horizontal bar is a separate bottom row',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final source = m.focus!;
      source.files.addAll(
        List.generate(300, (i) => DemoFile('f-$i', 'bulk-file-$i')),
      );
      await mount(tester, m);

      final bars = find
          .byType(Scrollbar)
          .evaluate()
          .map((e) => e.renderObject as RenderBox)
          .toList();
      expect(bars.length, 2, reason: 'one vertical + one horizontal bar');

      // The vertical bar spans the full viewport height and touches the
      // panel's right edge (left edge of the terminal splitter).
      final panel = tester.getRect(find.byType(FilesPanel));
      final tall = bars.reduce((a, b) => a.size.height >= b.size.height ? a : b);
      final tallRect = tall.localToGlobal(Offset.zero) & tall.size;
      expect(tallRect.right, closeTo(panel.right, 1),
          reason: 'vertical thumb track must hug the visible right edge');
      expect(tallRect.height, greaterThan(400));

      // The horizontal bar is a short bottom strip and does not intersect
      // the vertical track's right edge column.
      final wide = bars.reduce((a, b) => a.size.height <= b.size.height ? a : b);
      final wideRect = wide.localToGlobal(Offset.zero) & wide.size;
      expect(wideRect.height, lessThan(40));
      expect(wideRect.bottom, lessThanOrEqualTo(panel.bottom + 1));
      expect(tallRect.bottom, lessThanOrEqualTo(wideRect.top),
          reason: 'tracks must not cross');

      // Wide content scrolls horizontally; the vertical thumb must not move
      // with it.
      final list = find.byType(ListView).evaluate().single;
      final controller =
          (list.widget as ListView).controller ?? ScrollController();
      controller.jumpTo(400);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final tallRectAfter =
          tall.localToGlobal(Offset.zero) & tall.size;
      expect(tallRectAfter.right, closeTo(panel.right, 1),
          reason: 'vertical thumb stays pinned during horizontal scroll');

      // Vertical scrolling moves the thumb inside the pinned track.
      final vertical = (find
          .byType(ListView)
          .evaluate()
          .single
          .widget as ListView).controller!;
      vertical.jumpTo(600);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
}
