import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/painter.dart';

import 'support/fake_backend.dart';

void main() {
  testWidgets(
    'full painter joins colored text backgrounds across fractional origins and DPI',
    (tester) async {
      final c = TerminalController(FakeBackend());
      c.applyFrame(fixture(line: 'M       '));
      // Deliberately unlike the default viewport color: the previous regression
      // only tested the default color, which could conceal an uncovered seam.
      for (var y = 0; y < c.rows.length; y++) {
        c.rows[y] = [
          for (var x = 0; x < c.rows[y].length; x++)
            rust.RenderCell(
              text: x == 0 ? 'M' : ' ',
              foreground: 0xffeeeeee,
              background: x == 7 ? 0xff10151d : 0xff607090,
              flags: 0,
            ),
        ];
      }
      final cache = TerminalPaintCache();
      final blink = ValueNotifier(false), preedit = ValueNotifier('');
      try {
        for (final scale in [1.0, 1.25, 1.5, 1.75, 2.0]) {
          for (final origin in [0.0, .37, .73]) {
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder)
              ..scale(scale)
              ..translate(origin, origin);
            final painter = TerminalPainter(
              c,
              cache,
              10,
              const Size(12, 13.2),
              blink,
              false,
              preedit,
            );
            painter.paint(canvas, const Size(96, 26.4));
            final builds = cache.backgroundBuilds;
            // Cursor-only repaints must reuse the bounded background picture.
            painter.paint(canvas, const Size(96, 26.4));
            expect(cache.backgroundBuilds, builds);
            final picture = recorder.endRecording();
            final image = await tester.runAsync(
              () => picture.toImage((100 * scale).ceil(), (29 * scale).ceil()),
            );
            try {
              final pixels = await tester.runAsync(() => image!.toByteData());
              final x = ((origin + 40) * scale)
                  .round(); // blank cell inside the colored block
              for (
                var y = (origin * scale).ceil() + 1;
                y < ((origin + 26.4) * scale).floor() - 1;
                y++
              ) {
                final i = (y * image!.width + x) * 4;
                expect(
                  [
                    for (var channel = 0; channel < 3; channel++)
                      pixels!.getUint8(i + channel),
                  ],
                  [0x60, 0x70, 0x90],
                  reason: 'DPI $scale origin $origin row $y',
                );
              }
            } finally {
              image?.dispose();
              picture.dispose();
            }
          }
        }
        final previous = cache.backgroundBuilds;
        c.rowVersions[1]++;
        final recorder = ui.PictureRecorder();
        cache.backgrounds(Canvas(recorder), c, const Size(12, 13.2));
        expect(cache.backgroundBuilds, previous + 1);
        recorder.endRecording().dispose();
      } finally {
        cache.dispose();
        blink.dispose();
        preedit.dispose();
        c.dispose();
      }
    },
  );
}
