import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/painter.dart';

import 'support/fake_backend.dart';

void main() {
  testWidgets('adjacent colored row pictures have no seams at fractional DPI', (
    tester,
  ) async {
    final c = TerminalController(FakeBackend());
    c.applyFrame(fixture(line: '      '));
    final cache = TerminalPaintCache();
    try {
      for (final scale in [1.25, 1.5, 1.75, 2.0]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..scale(scale);
        canvas.drawColor(Colors.black, BlendMode.src);
        for (var row = 0; row < 6; row++) {
          canvas.save();
          canvas.translate(0, row * 13.2);
          canvas.drawPicture(cache.row(c, row % 2, 10, const Size(12, 13.2)));
          canvas.restore();
        }
        final picture = recorder.endRecording();
        final image = await tester.runAsync(
          () => picture.toImage(100, (79.2 * scale).ceil()),
        );
        try {
          final pixels = await tester.runAsync(() => image!.toByteData());
          // Ignore only the outside perimeter; every inter-row boundary must
          // have the exact terminal background, with no blended black line.
          for (var y = 1; y < (79.2 * scale).floor() - 1; y++) {
            final i = (y * 100 + 10) * 4;
            expect(pixels!.getUint8(i), 0x10, reason: 'DPI $scale row $y');
            expect(pixels.getUint8(i + 1), 0x15);
            expect(pixels.getUint8(i + 2), 0x1d);
          }
        } finally {
          image?.dispose();
          picture.dispose();
        }
      }
    } finally {
      cache.dispose();
      c.dispose();
    }
  });
}
