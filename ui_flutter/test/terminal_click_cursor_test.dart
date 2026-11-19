import 'dart:ui' as ui;

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
}) {
  final blank = List.generate(row0.length, (_) => cell(' '));
  return rust.RenderFrame(
    revision: 1,
    contentRevision: 1,
    outputLines: 0,
    sizeLocked: false,
    searchRevision: null,
    searchSpans: [],
    columns: row0.length,
    rows: 2,
    full: true,
    changedRows: [
      rust.RenderRow(index: 0, cells: row0),
      rust.RenderRow(index: 1, cells: blank),
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

void main() {
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
        home: Scaffold(body: TerminalView(key: key, controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(TerminalView));
    final cell = key.currentState!.cellSize;
    Offset at(int column, int row) => origin +
        Offset((column + .5) * cell.width, (row + .5) * cell.height);
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
        home: Scaffold(body: TerminalView(key: key, controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(TerminalView));
    final cell = key.currentState!.cellSize;
    final beyond =
        origin + Offset((9.5) * cell.width, .5 * cell.height);
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
    expect(
      backend.keys.where((input) => input.key == 'ArrowRight').length,
      3,
    );
    expect(
      backend.keys.where((input) => input.key == 'ArrowLeft').length,
      0,
    );

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
        home: Scaffold(body: TerminalView(key: key, controller: controller)),
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
    expect(
      backend.keys.where((input) => input.key == 'ArrowLeft').length,
      3,
    );
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
          home: Scaffold(body: TerminalView(key: key, controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      final origin = tester.getTopLeft(find.byType(TerminalView));
      final cell = key.currentState!.cellSize;
      Offset at(int column, int row) => origin +
          Offset((column + .5) * cell.width, (row + .5) * cell.height);
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
      expect(backend.keys, isEmpty);

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
        home: Scaffold(body: TerminalView(key: key, controller: controller)),
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
        home: Scaffold(body: TerminalView(key: key, controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(find.byType(TerminalView));
    final cell = key.currentState!.cellSize;
    Offset at(int column, int row) => origin +
        Offset((column + .5) * cell.width, (row + .5) * cell.height);
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
