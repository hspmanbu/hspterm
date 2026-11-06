import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

void main() {
  testWidgets(
    'scrollbars render visible thumbs: vertical at panel right edge, horizontal at bottom',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final source = m.focus!;
      source.files.addAll(
        List.generate(300, (i) => DemoFile('f-$i', 'bulk-file-$i')),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light().copyWith(
            colorScheme: const ColorScheme.light(),
          ),
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
      await tester.pumpAndSettle();
      // Emit real scroll notifications so scrollbar painters get metrics.
      final list = find.byType(ListView).evaluate().single;
      final vc = (list.widget as ListView).controller!;
      vc.jumpTo(600);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Walk up from the panel to the nearest RepaintBoundary.
      RenderObject node = tester.renderObject(find.byType(FilesPanel));
      while (node is! RenderRepaintBoundary) {
        node = node.parent!;
      }
      final rb = node;
      // toImage needs the real rasterizer: run outside FakeAsync.
      final pair = await tester.runAsync(() async {
        final img = await rb.toImage(pixelRatio: 1);
        final bytes = await img.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        return (img, bytes);
      });
      final image = pair!.$1;
      final data = pair.$2!;

      int pixel(int x, int y) {
        final o = (y * image.width + x) * 4;
        return data.getUint32(o);
      }

      // Count distinct colors inside a pixel band; a flat background has
      // very few. A painted scrollbar thumb (plus its track/text edges)
      // raises the count well above background-only.
      int distinctColors(bool Function(int x, int y) inside) {
        final colors = <int>{};
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            if (inside(x, y)) colors.add(pixel(x, y));
          }
        }
        return colors.length;
      }

      // Right edge band of the list area (below the toolbar, above the
      // status row): the vertical thumb must paint here.
      final rightBand = distinctColors(
        (x, y) => x >= image.width - 20 && y > 80 && y < image.height - 80,
      );
      // Bottom band spanning the panel: the horizontal thumb strip.
      final bottomBand = distinctColors(
        (x, y) => y >= image.height - 20 && x > 60 && x < image.width - 60,
      );
      // Control: a name-column band inside the visible rows.
      final midBand = distinctColors(
        (x, y) => x >= 60 && x < 220 && y > 220 && y < 320,
      );
      final totalDistinct = distinctColors((x, y) => true);

      // ignore: avoid_print
      print('totalDistinct=$totalDistinct mid=$midBand right=$rightBand bottom=$bottomBand');
      for (var bx = 0; bx + 40 <= image.width; bx += 40) {
        final n = distinctColors(
          (x, y) => x >= bx && x < bx + 40 && y > 80 && y < image.height - 60,
        );
        // ignore: avoid_print
        print('band x[$bx-${bx + 40}) colors=$n');
      }
      for (var by = 0; by + 40 <= image.height; by += 40) {
        final n = distinctColors(
          (x, y) => y >= by && y < by + 40 && x >= 756 && x < 780,
        );
        // ignore: avoid_print
        print('col756 y[$by-${by + 40}) colors=$n');
      }
      for (var bx = 720; bx + 12 <= image.width; bx += 12) {
        final n = distinctColors(
          (x, y) => x >= bx && x < bx + 12 && y > 80 && y < image.height - 60,
        );
        // ignore: avoid_print
        print('narrow x[$bx-${bx + 12}) colors=$n');
      }
      for (var by = image.height - 60; by + 20 <= image.height; by += 20) {
        final n = distinctColors((x, y) => y >= by && y < by + 20 && x > 40);
        // ignore: avoid_print
        print('row y[$by-${by + 20}) colors=$n');
      }
      expect(midBand, greaterThan(3), reason: 'sanity: list text renders');
      expect(rightBand, greaterThan(3),
          reason: 'vertical thumb must paint at the panel right edge');
      expect(bottomBand, greaterThan(3),
          reason: 'horizontal thumb must paint at the panel bottom');

      // Exact-position check: the vertical thumb's painted pixels must touch
      // the last 12px column of the panel (right edge), not stop at the last
      // column's boundary.
      var rightmostPainted = 0;
      for (var y = 80; y < image.height - 80; y++) {
        for (var x = image.width - 1; x >= image.width - 12; x--) {
          if (pixel(x, y) != pixel(image.width - 1, 4)) {
            if (x > rightmostPainted) rightmostPainted = x;
            break;
          }
        }
      }
      expect(rightmostPainted, greaterThanOrEqualTo(image.width - 4),
          reason: 'thumb pixels reach the visible right edge');

      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
}
