import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';

import 'support/fake_backend.dart';

/// Row layout helper: builds one row where CJK glyphs occupy a lead cell
/// (flags 32) plus a trailing spacer cell (flags 64), matching the grid the
/// Rust core publishes for wide characters.
void main() {
  testWidgets('selection snapping keeps whole wide glyphs at both ends', (
    tester,
  ) async {
    final b = FakeBackend();
    final c = TerminalController(b);
    await c.start();
    c.phase = 'Connected';
    c.generation = 1;
    c.applyFrame(
      rust.RenderFrame(
        revision: 1,
        contentRevision: 1,
        outputLines: 0,
        sizeLocked: false,
        searchRevision: null,
        searchSpans: [],
        columns: 6,
        rows: 1,
        full: true,
        changedRows: [
          rust.RenderRow(
            index: 0,
            cells: [
              // "中" = lead + spacer, "a" plain, "文" = lead + spacer, "!".
              rust.RenderCell(
                text: '中',
                foreground: 0,
                background: 0,
                flags: 32,
              ),
              rust.RenderCell(
                text: '',
                foreground: 0,
                background: 0,
                flags: 64,
              ),
              rust.RenderCell(
                text: 'a',
                foreground: 0,
                background: 0,
                flags: 0,
              ),
              rust.RenderCell(
                text: '文',
                foreground: 0,
                background: 0,
                flags: 32,
              ),
              rust.RenderCell(
                text: '',
                foreground: 0,
                background: 0,
                flags: 64,
              ),
              rust.RenderCell(
                text: '!',
                foreground: 0,
                background: 0,
                flags: 0,
              ),
            ],
          ),
        ],
        cursorColumn: 0,
        cursorRow: 0,
        cursorVisible: false,
        cursorShape: 0,
        cursorBlink: false,
        cursorColor: 0,
        background: 0,
        alternateScreen: false,
        mouseReporting: false,
        historyLines: 0,
        displayOffset: 0,
      ),
    );
    await tester.pumpWidget(const SizedBox());

    // End lands on the wide lead cell: the glyph must be fully covered.
    c.select(const math.Point<int>(0, 0), const math.Point<int>(0, 0));
    expect(c.selectionEnd, const math.Point<int>(1, 0));
    expect(c.selectedText(), '中');

    // End lands on the trailing spacer: already whole, stays.
    c.select(const math.Point<int>(0, 0), const math.Point<int>(1, 0));
    expect(c.selectionEnd, const math.Point<int>(1, 0));
    expect(c.selectedText(), '中');

    // End lands on the plain cell after a wide glyph: untouched.
    c.select(const math.Point<int>(0, 0), const math.Point<int>(2, 0));
    expect(c.selectedText(), '中a');

    // Start on the trailing spacer of the second glyph snaps to its lead.
    c.select(const math.Point<int>(4, 0), const math.Point<int>(5, 0));
    expect(c.selectionStart, const math.Point<int>(3, 0));
    expect(c.selectedText(), '文!');

    // End on the second glyph's lead extends over its spacer.
    c.select(const math.Point<int>(2, 0), const math.Point<int>(3, 0));
    expect(c.selectionEnd, const math.Point<int>(4, 0));
    expect(c.selectedText(), 'a文');

    c.dispose();
  });

  testWidgets('reverse drags cover whole glyphs and copy the same text', (
    tester,
  ) async {
    final b = FakeBackend();
    final c = TerminalController(b);
    await c.start();
    c.phase = 'Connected';
    c.generation = 1;
    c.applyFrame(
      rust.RenderFrame(
        revision: 1,
        contentRevision: 1,
        outputLines: 0,
        sizeLocked: false,
        searchRevision: null,
        searchSpans: [],
        columns: 6,
        rows: 1,
        full: true,
        changedRows: [
          rust.RenderRow(
            index: 0,
            cells: [
              rust.RenderCell(
                text: '中',
                foreground: 0,
                background: 0,
                flags: 32,
              ),
              rust.RenderCell(
                text: '',
                foreground: 0,
                background: 0,
                flags: 64,
              ),
              rust.RenderCell(
                text: 'a',
                foreground: 0,
                background: 0,
                flags: 0,
              ),
              rust.RenderCell(
                text: '文',
                foreground: 0,
                background: 0,
                flags: 32,
              ),
              rust.RenderCell(
                text: '',
                foreground: 0,
                background: 0,
                flags: 64,
              ),
              rust.RenderCell(
                text: '!',
                foreground: 0,
                background: 0,
                flags: 0,
              ),
            ],
          ),
        ],
        cursorColumn: 0,
        cursorRow: 0,
        cursorVisible: false,
        cursorShape: 0,
        cursorBlink: false,
        cursorColor: 0,
        background: 0,
        alternateScreen: false,
        mouseReporting: false,
        historyLines: 0,
        displayOffset: 0,
      ),
    );
    await tester.pumpWidget(const SizedBox());

    // Reverse drag ending on the second glyph's trailing spacer.
    c.select(const math.Point<int>(5, 0), const math.Point<int>(4, 0));
    final forward = c.selectedText();
    c.select(const math.Point<int>(4, 0), const math.Point<int>(5, 0));
    final reverse = c.selectedText();
    expect(
      forward,
      reverse,
      reason: 'drag direction must not change the copied text',
    );
    expect(forward, '文!');

    // Reverse drag ending on the second glyph's lead cell: the pointer sits
    // at that glyph's left edge, so everything from it rightward is covered.
    c.select(const math.Point<int>(5, 0), const math.Point<int>(3, 0));
    final forwardPair = (c.selectedText(), c.selectionStart, c.selectionEnd);
    c.select(const math.Point<int>(3, 0), const math.Point<int>(5, 0));
    expect(
      c.selectedText(),
      forwardPair.$1,
      reason: 'direction must not change coverage',
    );
    expect(c.selectedText(), '文!');

    // Reverse drag starting inside the first glyph's spacer excludes it.
    c.select(const math.Point<int>(1, 0), const math.Point<int>(0, 0));
    expect(c.selectedText(), '中');

    c.dispose();
  });
}
