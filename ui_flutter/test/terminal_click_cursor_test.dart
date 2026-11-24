import 'dart:ui' as ui;
import 'dart:async';
import 'dart:math';

import 'package:hspterm/terminal/caret_navigation.dart';

import 'package:hspterm/terminal/backend.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/view.dart';

import 'support/fake_backend.dart';

// Wide-glyph grid flags mirrored from the Rust core (alacritty cell flags).
const wideLead = 32, wideSpacer = 64;

rust.RenderCell cell(String text, {int flags = 0}) => rust.RenderCell(
  text: text,
  foreground: 0xffffffff,
  background: 0xff10151d,
  flags: flags,
);

/// "$ 中文": the CJK glyphs occupy lead+spacer cell pairs like the grid the
/// Rust core publishes.
List<rust.RenderCell> promptRow() => [
  cell(r'$'),
  cell(' '),
  cell('中', flags: wideLead),
  cell('', flags: wideSpacer),
  cell('文', flags: wideLead),
  cell('', flags: wideSpacer),
];

rust.RenderFrame frame(
  List<rust.RenderCell> row0, {
  int cursorColumn = 0,
  int cursorRow = 0,
  bool mouse = false,
  bool alternate = false,
  List<rust.RenderCell>? row1,
  int revision = 1,
}) {
  final blank = List.generate(row0.length, (_) => cell(' '));
  return rust.RenderFrame(
    revision: revision,
    contentRevision: revision,
    outputLines: 0,
    sizeLocked: false,
    searchRevision: null,
    searchSpans: [],
    columns: row0.length,
    rows: 2,
    full: true,
    changedRows: [
      rust.RenderRow(index: 0, cells: row0),
      rust.RenderRow(index: 1, cells: row1 ?? blank),
    ],
    cursorColumn: cursorColumn,
    cursorRow: cursorRow,
    cursorVisible: true,
    cursorShape: 0,
    cursorBlink: false,
    cursorColor: 0xffffffff,
    background: 0xff10151d,
    alternateScreen: alternate,
    mouseReporting: mouse,
    historyLines: 0,
    displayOffset: 0,
  );
}

class PointerBackend extends FakeBackend implements TerminalTmuxPointerBackend {
  String route = 'handled';
  Completer<String>? pending;
  final clicks = <(int, int, String, rust.TerminalCursorMove)>[];
  @override
  Future<String> tmuxClickCursor(
    int id,
    int generation,
    String pane,
    rust.TerminalCursorMove movement,
  ) async {
    clicks.add((id, generation, pane, movement));
    return pending?.future ?? route;
  }
}

void main() {
  test('soft wraps count wide glyphs and wrap placeholders only once', () {
    final rows = [
      [
        cell('a'),
        cell('中', flags: wideLead),
        cell('', flags: wideSpacer),
        cell('', flags: 1024 | 16),
      ],
      [
        cell('文', flags: wideLead),
        cell('', flags: wideSpacer),
        cell('z'),
        cell(' '),
      ],
    ];
    expect(caretDistance(rows, const Point(1, 0), const Point(2, 1)), 2);
    expect(caretDistance(rows, const Point(2, 1), const Point(2, 0)), -2);
    expect(caretDistance(rows, const Point(1, 0), const Point(3, 1)), 3);
    rows[0][3] = cell(' ');
    expect(caretDistance(rows, const Point(1, 0), const Point(2, 1)), 0);
  });

  test(
    'hard line proof requires exact echo and excludes padding and output',
    () {
      final rows = [
        [cell('>'), cell('a'), cell(' '), cell(' ')],
        [cell('b'), cell(' '), cell(' '), cell(' ')],
        [cell('o'), cell('u'), cell('t'), cell(' ')],
      ];
      const start = Point(1, 0), end = Point(1, 1);
      expect(confirmCaretPaste(rows, start, end, 'a\nc'), isNull);
      final edit = confirmCaretPaste(rows, start, end, 'a\nb')!;
      expect(caretDistance(rows, end, start, edit: edit), -3);
      expect(caretDistance(rows, end, const Point(3, 0), edit: edit), 0);
      expect(caretDistance(rows, start, const Point(1, 2), edit: edit), 0);
      rows[1] = List.of(rows[1]);
      expect(caretDistance(rows, end, start, edit: edit), 0);
    },
  );

  for (final tmux in [false, true]) {
    testWidgets('default click crosses a soft wrap with tmux=$tmux', (
      tester,
    ) async {
      final backend = PointerBackend();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      if (tmux) {
        c.tmuxReadonly = false;
        c.tmuxLocalSelection = true;
        c.reportTmuxShell('%3', false);
      }
      final key = GlobalKey<TerminalViewState>();
      c.applyFrame(
        frame(
          [
            cell('1'),
            cell('2'),
            cell('3'),
            cell('4'),
            cell('5'),
            cell('6', flags: 16),
          ],
          cursorRow: 1,
          cursorColumn: 2,
          row1: [
            cell('7'),
            cell('8'),
            cell(' '),
            cell(' '),
            cell(' '),
            cell(' '),
          ],
          mouse: tmux,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(key: key, controller: c),
          ),
        ),
      );
      final size = key.currentState!.cellSize;
      final origin = tester.getTopLeft(find.byType(TerminalView));
      final click = await tester.startGesture(
        origin + Offset(2.5 * size.width, .5 * size.height),
        kind: ui.PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await click.up();
      await tester.pump();
      if (tmux) {
        final click = backend.clicks.single.$4;
        expect((click.row, click.column, click.steps), (0, 2, 6));
        expect(backend.keys, isEmpty);
        expect(backend.mouseActions, isEmpty);
      } else {
        expect(backend.keys.map((key) => key.key), List.filled(6, 'ArrowLeft'));
      }
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }

  testWidgets(
    'fresh multiline paste confirms cross-line clicks until another edit',
    (tester) async {
      final backend = FakeBackend();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      c.applyFrame(
        frame([cell('>'), cell(' '), cell(' '), cell(' ')], cursorColumn: 1),
      );
      await c.paste('a\r\nb', true);
      final echo = frame(
        [cell('>'), cell('a'), cell(' '), cell(' ')],
        row1: [cell('b'), cell(' '), cell(' '), cell(' ')],
        cursorRow: 1,
        cursorColumn: 1,
        revision: 2,
      );
      c.applyFrame(echo);
      await c.moveCaret(echo, const Point(1, 0));
      expect(backend.keys.map((key) => key.key), List.filled(3, 'ArrowLeft'));
      await c.text('x');
      await c.moveCaret(echo, const Point(1, 0));
      expect(backend.keys, hasLength(3));
      c.dispose();
    },
  );

  for (final localSelection in [true, false]) {
    for (final nativeMouse in [true, false]) {
      testWidgets(
        'tmux routes actual inner mouse=$nativeMouse local selection=$localSelection',
        (tester) async {
          final backend = PointerBackend()
            ..route = nativeMouse ? 'mouse' : 'handled';
          final c = TerminalController(backend);
          await c.start();
          c.phase = 'Connected';
          c.generation = 1;
          c.tmuxReadonly = false;
          c.tmuxLocalSelection = localSelection;
          c.reportTmuxShell('%3', false);
          c.applyFrame(
            frame(
              [...promptRow(), cell(' '), cell(' ')],
              cursorColumn: 2,
              mouse: true,
              alternate: true,
            ),
          );
          final key = GlobalKey<TerminalViewState>();
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TerminalView(key: key, controller: c),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final size = key.currentState!.cellSize;
          final origin = tester.getTopLeft(find.byType(TerminalView));
          final gesture = await tester.startGesture(
            origin + Offset(4.5 * size.width, .5 * size.height),
            kind: ui.PointerDeviceKind.mouse,
            buttons: kPrimaryMouseButton,
          );
          await tester.pump();
          await gesture.up();
          await tester.pumpAndSettle();
          expect(backend.clicks, hasLength(1));
          final movement = backend.clicks.single.$4;
          expect(
            (backend.clicks.single.$2, backend.clicks.single.$3),
            (1, '%3'),
          );
          expect((movement.column, movement.row, movement.steps), (4, 0, 1));
          expect(backend.keys, isEmpty);
          expect(
            backend.mouseActions,
            nativeMouse || !localSelection ? [0, 1] : <int>[],
          );
          await tester.pumpWidget(const SizedBox());
          c.dispose();
        },
      );
    }
  }
  testWidgets(
    'non-mouse alternate-screen TUI gets same-row keyboard fallback',
    (tester) async {
      final backend = FakeBackend();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      c.generation = 1;
      c.applyFrame(frame(promptRow(), cursorColumn: 2, alternate: true));
      final key = GlobalKey<TerminalViewState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(key: key, controller: c),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final size = key.currentState!.cellSize;
      final origin = tester.getTopLeft(find.byType(TerminalView));
      final gesture = await tester.startGesture(
        origin + Offset(4.5 * size.width, .5 * size.height),
        kind: ui.PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(backend.keys.map((v) => v.key), ['ArrowRight']);
      expect(backend.mouseActions, isEmpty);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'pending tmux probe is not replayed and reconnect cannot receive a late mouse pair',
    (tester) async {
      final backend = PointerBackend()..pending = Completer<String>();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      c.generation = 1;
      c.tmuxReadonly = false;
      c.tmuxLocalSelection = true;
      c.reportTmuxShell('%3', false);
      final original = frame(promptRow(), cursorColumn: 2, mouse: true);
      c.applyFrame(original);
      const target = Point(4, 0);
      final first = c.clickTmuxCursor(original, target, mouseForwarded: false);
      final second = c.clickTmuxCursor(original, target, mouseForwarded: false);
      await tester.pump();
      expect(backend.clicks, hasLength(1));
      c.generation++;
      backend.pending!.complete('mouse');
      await tester.pump();
      await first;
      await second;
      expect(backend.mouseActions, isEmpty);
      await c.clickTmuxCursor(original, target, mouseForwarded: false);
      expect(
        backend.clicks,
        hasLength(1),
        reason: 'old pane metadata cannot cross a reconnect',
      );
      c.dispose();
    },
  );
  testWidgets('click on a wide glyph right half snaps to its lead', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = TerminalController(backend);
    await controller.start();
    controller.phase = 'Connected';
    controller.generation = 1;
    final key = GlobalKey<TerminalViewState>();
    controller.applyFrame(frame(promptRow(), cursorColumn: 2));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(key: key, controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(TerminalView));
    final cell = key.currentState!.cellSize;
    Offset at(int column, int row) =>
        origin + Offset((column + .5) * cell.width, (row + .5) * cell.height);
    Future<void> click(Offset position) async {
      final gesture = await tester.startGesture(
        position,
        kind: ui.PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    int sent(String name) =>
        backend.keys.where((input) => input.key == name).length;

    // Caret sits on 中's lead cell; the click lands on 文's trailing
    // spacer half. One character to the right (文), not a three-column
    // walk over the spacer cells.
    await click(at(5, 0));
    expect(sent('ArrowRight'), 1);
    expect(sent('ArrowLeft'), 0);
    expect(backend.keys.every((input) => input.modifiers == 0), isTrue);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('click past the line end clamps to the last glyph', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = TerminalController(backend);
    await controller.start();
    controller.phase = 'Connected';
    controller.generation = 1;
    final key = GlobalKey<TerminalViewState>();
    controller.applyFrame(frame(promptRow(), cursorColumn: 0));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(key: key, controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(TerminalView));
    final cell = key.currentState!.cellSize;
    final beyond = origin + Offset((9.5) * cell.width, .5 * cell.height);
    // Column 9 is beyond the 6-column grid; the click clamps to 文.
    final gesture = await tester.startGesture(
      beyond,
      kind: ui.PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // $, space and 中 separate the caret from 文: three characters.
    expect(backend.keys.where((input) => input.key == 'ArrowRight').length, 3);
    expect(backend.keys.where((input) => input.key == 'ArrowLeft').length, 0);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('moves left across wide glyphs count one step each', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = TerminalController(backend);
    await controller.start();
    controller.phase = 'Connected';
    controller.generation = 1;
    final key = GlobalKey<TerminalViewState>();
    controller.applyFrame(frame(promptRow(), cursorColumn: 6));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(key: key, controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(TerminalView));
    final cell = key.currentState!.cellSize;
    final click = origin + Offset(.5 * cell.width, .5 * cell.height);
    final gesture = await tester.startGesture(
      click,
      kind: ui.PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // $, space, 中 — 文 is crossed together with its spacer as one step.
    expect(backend.keys.where((input) => input.key == 'ArrowLeft').length, 3);
    expect(backend.keys.where((input) => input.key == 'ArrowRight'), isEmpty);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
    'clicking the caret cell, another row or with shift sends nothing',
    (tester) async {
      final backend = FakeBackend();
      final controller = TerminalController(backend);
      await controller.start();
      controller.phase = 'Connected';
      controller.generation = 1;
      final key = GlobalKey<TerminalViewState>();
      controller.applyFrame(frame(promptRow(), cursorColumn: 2));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(key: key, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final origin = tester.getTopLeft(find.byType(TerminalView));
      final cell = key.currentState!.cellSize;
      Offset at(int column, int row) =>
          origin + Offset((column + .5) * cell.width, (row + .5) * cell.height);
      Future<void> click(Offset position) async {
        final gesture = await tester.startGesture(
          position,
          kind: ui.PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton,
        );
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      // Same cell: zero displacement.
      await click(at(2, 0));
      expect(backend.keys, isEmpty);
      // A click on the row below the caret is not caret movement.
      await click(at(2, 1));
      expect(backend.keys, isEmpty);
      // Shift+click keeps the local selection semantics.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await click(at(4, 0));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(
        backend.keys.where((input) => input.key.startsWith('Arrow')),
        isEmpty,
      );

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('mouse reporting keeps forwarding clicks as mouse events', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = TerminalController(backend);
    await controller.start();
    controller.phase = 'Connected';
    controller.generation = 1;
    final key = GlobalKey<TerminalViewState>();
    controller.applyFrame(frame(promptRow(), cursorColumn: 2, mouse: true));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(key: key, controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(TerminalView));
    final cell = key.currentState!.cellSize;
    final click = origin + Offset(4.5 * cell.width, .5 * cell.height);
    final gesture = await tester.startGesture(
      click,
      kind: ui.PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(backend.mouseActions, [0, 1]);
    expect(backend.keys, isEmpty);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a drag on the caret row still selects instead of moving', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = TerminalController(backend);
    await controller.start();
    controller.phase = 'Connected';
    controller.generation = 1;
    final key = GlobalKey<TerminalViewState>();
    controller.applyFrame(frame(promptRow(), cursorColumn: 2));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(key: key, controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(TerminalView));
    final cell = key.currentState!.cellSize;
    Offset at(int column, int row) =>
        origin + Offset((column + .5) * cell.width, (row + .5) * cell.height);
    final gesture = await tester.startGesture(
      at(0, 0),
      kind: ui.PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await tester.pump();
    await gesture.moveTo(at(4, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.selectedText(), contains('中文'));
    expect(backend.keys, isEmpty);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
