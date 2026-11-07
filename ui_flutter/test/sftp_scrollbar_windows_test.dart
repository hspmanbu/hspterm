import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

/// Windows-desktop scroll behavior adds automatic Scrollbars around every
/// scrollable; this reproduces the duplicated vertical bar from real
/// machines and asserts the panel opts out completely.
void main() {
  testWidgets(
    'windows behavior: exactly one vertical and one horizontal explicit bar',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final m = WorkbenchModel()..demo();
      final source = m.focus!;
      source.files.addAll(
        List.generate(300, (i) => DemoFile('f-$i', 'bulk-file-$i')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: AnimatedBuilder(
                animation: m,
                builder: (_, _) => FilesPanel(model: m, pane: source),
              ),
            ),
          ),
        ),
      );
      final list = find.byType(ListView).evaluate().single;
      final vc = (list.widget as ListView).controller!;
      vc.jumpTo(600);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final bars = tester
          .widgetList<RawScrollbar>(find.byType(RawScrollbar))
          .toList();
      // Only the two explicit bars exist; the desktop wrapper added none.
      expect(bars.length, 2);
      final vertical = bars
          .where((b) => b.scrollbarOrientation == ScrollbarOrientation.right)
          .toList();
      final horizontal = bars
          .where((b) => b.scrollbarOrientation == ScrollbarOrientation.bottom)
          .toList();
      expect(vertical.length, 1);
      expect(horizontal.length, 1);
      // No framework Scrollbar (the automatic desktop widget) anywhere.
      expect(find.byType(Scrollbar), findsNothing);
      // Track mapping: the vertical bar follows the list controller.
      expect(vertical.single.controller, same(vc));
      // Scroll to the end: the position reaches its maximum exactly.
      vc.jumpTo(vc.position.maxScrollExtent);
      await tester.pump();
      expect(vc.position.pixels, vc.position.maxScrollExtent);

      await tester.pumpWidget(const SizedBox());
      m.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
