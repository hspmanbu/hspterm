import 'dart:ui' as ui;
import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/painter.dart';

import 'support/fake_backend.dart';

void main() {
  for (final inverse in [false, true]) {
    for (final selected in [false, true]) {
      testWidgets(
        'colored backgrounds stay joined: remote inverse=$inverse local selection=$selected',
        (tester) async {
          final c = TerminalController(FakeBackend());
          c.applyFrame(fixture(line: 'M       '));
          // Deliberately unlike the default viewport color: the previous regression
          // only tested the default color, which could conceal an uncovered seam.
          for (var y = 0; y < c.rows.length; y++) {
            c.rows[y] = List.generate(c.rows[y].length, (x) {
              // Unequal run boundaries form the T-junction at a selected
              // line wrap that vertically identical rectangles cannot cover.
              final colored = x < 7 && (y == 0 || x >= 2);
              return rust.RenderCell(
                text: x == 0 ? 'M' : ' ',
                foreground: inverse && colored ? 0xff607090 : 0xffeeeeee,
                background: inverse && colored
                    ? 0xffeeeeee
                    : colored
                    ? 0xff607090
                    : 0xff10151d,
                flags: inverse && colored ? 1 : 0,
              );
            });
          }
          if (selected) {
            c.selectionStart = const Point(0, 0);
            c.selectionEnd = const Point(6, 1);
          }
          final expected = selected
              ? Color.alphaBlend(
                  const Color(0x665c92cc),
                  const Color(0xff607090),
                )
              : const Color(0xff607090);
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
                  devicePixelRatio: scale,
                  // A repaint-boundary recording omits ancestor transforms;
                  // production supplies this global logical transform instead.
                  viewportTransform: () => [
                    1,
                    0,
                    0,
                    0,
                    0,
                    1,
                    0,
                    0,
                    0,
                    0,
                    1,
                    0,
                    origin,
                    origin,
                    0,
                    1,
                  ],
                );
                final before = cache.backgroundBuilds;
                painter.paint(canvas, const Size(96, 26.4));
                expect(
                  cache.backgroundBuilds,
                  before + 1,
                  reason: 'DPI/origin change invalidates device-aligned backgrounds',
                );
                final builds = cache.backgroundBuilds;
                // Cursor-only repaints must reuse the bounded background picture.
                painter.paint(canvas, const Size(96, 26.4));
                expect(cache.backgroundBuilds, builds);
                final picture = recorder.endRecording();
                final image = await tester.runAsync(
                  () => picture.toImage(
                    (100 * scale).ceil(),
                    (29 * scale).ceil(),
                  ),
                );
                try {
                  final pixels = await tester.runAsync(
                    () => image!.toByteData(),
                  );
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
                      [
                        closeTo((expected.r * 255).round(), 1),
                        closeTo((expected.g * 255).round(), 1),
                        closeTo((expected.b * 255).round(), 1),
                      ],
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
  }
}
