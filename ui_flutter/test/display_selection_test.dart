import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

RenderFrame frame({
  int color = 0xffeeeeee,
  int flags = 0,
  int revision = 1,
  int content = 1,
  int columns = 20,
  int offset = 0,
  int history = 0,
  bool alternate = false,
  bool mouse = false,
  String text = 'ERROR',
}) => RenderFrame(
  revision: revision,
  contentRevision: content,
  outputLines: 0,
  sizeLocked: false,
  columns: columns,
  rows: 2,
  full: true,
  changedRows: List.generate(
    2,
    (y) => RenderRow(
      index: y,
      cells: (y == 0 ? text : '')
          .padRight(columns)
          .split('')
          .map(
            (c) => RenderCell(
              text: c,
              foreground: color,
              background: 0xff10151d,
              flags: flags,
            ),
          )
          .toList(),
    ),
  ),
  cursorColumn: 0,
  cursorRow: 0,
  cursorVisible: false,
  cursorShape: 0,
  cursorBlink: false,
  cursorColor: 0xffeeeeee,
  background: 0xff10151d,
  alternateScreen: alternate,
  mouseReporting: mouse,
  historyLines: history,
  displayOffset: offset,
  searchSpans: const [],
);
void main() {
  test('selection survives unrelated content revisions, but selected text and geometry still invalidate it', () async {
    final c = TerminalController(const NativeTerminalBackend());
    try {
      c.applyFrame(frame());
      c.select(const Point(0, 0), const Point(4, 0));
      c.applyFrame(frame(revision: 2, color: 0xff112233, flags: 8));
      expect(c.selectedText(), 'ERROR');
      c.applyFrame(frame(revision: 3, text: 'OTHER'));
      expect(c.selectedText(), isEmpty);
      c.select(const Point(0, 0), const Point(4, 0));
      c.applyFrame(frame(revision: 4, text: 'OTHER', content: 2));
      expect(c.selectedText(), 'OTHER');
      c.select(const Point(0, 0), const Point(4, 0));
      c.applyFrame(frame(revision: 5, content: 2, columns: 21));
      expect(c.selectedText(), isEmpty);
    } finally {
      await c.shutdown();
      c.dispose();
    }
  });
  test('history viewport, alternate screen, mouse capture and hidden mappings cannot retain a stale selection', () async {
    final c = TerminalController(const NativeTerminalBackend());
    try {
      for (final next in [
        frame(offset: 1, history: 2),
        frame(alternate: true),
        frame(mouse: true),
        frame(flags: 1024),
        frame(flags: 32),
      ]) {
        c.applyFrame(frame());
        c.select(const Point(0, 0), const Point(4, 0));
        c.applyFrame(next);
        expect(c.selectedText(), isEmpty);
      }
    } finally {
      await c.shutdown();
      c.dispose();
    }
  });
}
