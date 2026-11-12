import 'dart:math';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:hspterm/src/rust/api.dart' as rust;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/painter.dart';
import 'package:hspterm/terminal/view.dart';

import 'support/fake_backend.dart';

void main() {
  testWidgets(
    'link hover is passive, Ctrl click is explicit and remote mouse capture retains priority',
    (tester) async {
      final backend = FakeBackend();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      c.applyFrame(fixture(line: 'http://localhost:8080/a '));
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              controller: c,
              onOpenLink: (link) async {
                opened.add(link.text);
              },
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(TerminalView));
      final point = rect.topLeft + const Offset(20, 8);
      final mouse = await tester.createGesture(
        pointer: 42,
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: point);
      await mouse.moveTo(point);
      await tester.pump(const Duration(seconds: 1));
      expect(opened, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(point);
      await tester.pump();
      expect(opened, ['http://localhost:8080/a']);
      c.applyFrame(
        fixture(revision: 2, mouse: true, line: 'http://localhost:8080/a '),
      );
      await tester.pump();
      await tester.tapAt(point);
      await tester.pump();
      expect(opened, hasLength(1), reason: 'the TUI owns mouse input');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(point);
      await tester.pump();
      expect(
        opened,
        hasLength(2),
        reason: 'Shift explicitly overrides remote capture',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      c.dispose();
    },
  );
  test('forwarding metadata is generation scoped and does not request a frame or notify the workbench', () async {
    final backend = FakeBackend();
    final controller = TerminalController(backend);
    await controller.start();
    controller.generation = 7;
    controller.phase = 'Connected';
    var ordinary = 0, metadata = 0;
    controller.addListener(() => ordinary++);
    controller.forwardingChanges.addListener(() => metadata++);
    for (final generation in [6, 7, 8]) {
      backend.events.add(
        rust.BridgeEvent(
          kind: 'forwardings',
          generation: generation,
          requestId: 0,
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);
    expect(metadata, 1);
    expect(ordinary, 0);
    expect(backend.frames, 0);
    expect(controller.frameCount, 0);
    await controller.shutdown();
    controller.dispose();
  });

  testWidgets('TUI keys pass through; IME composes locally and commits once', (
    tester,
  ) async {
    final backend = FakeBackend(),
        controller = TerminalController(FakeBackend());
    controller.dispose();
    final c = TerminalController(backend);
    await c.start();
    c.phase = 'Connected';
    c.applyFrame(fixture());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalView(controller: c)),
      ),
    );
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    final clients = tester.testTextInput.log.where(
      (call) => call.method == 'TextInput.setClient',
    );
    expect(clients, isNotEmpty);
    expect(
      (clients.last.arguments as List)[1]['viewId'],
      tester.view.viewId,
      reason: 'Windows requires an actual view ID to create its native text/IME model',
    );
    for (final key in [
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.tab,
      LogicalKeyboardKey.escape,
    ]) {
      await tester.sendKeyEvent(key);
    }
    expect(backend.keys.where((k) => k.kind == 0).map((k) => k.key), [
      'ArrowUp',
      'Enter',
      'Tab',
      'Escape',
    ]);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '\u200bzhong',
        composing: TextRange(start: 1, end: 6),
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await tester.pump();
    expect(backend.texts, isEmpty);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '\u200b中文',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();
    expect(backend.texts, ['中文']);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'A');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '\u200b中文A',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(backend.keys.any((k) => k.key == 'ShiftLeft' && k.kind == 0), true);
    expect(
      backend.keys.any(
        (k) =>
            k.key == 'a' &&
            k.modifiers & 1 != 0 &&
            k.text == 'A' &&
            k.kind == 0,
      ),
      true,
    );
    final frames = backend.frames;
    await tester.pump(const Duration(seconds: 2));
    expect(backend.frames, frames);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
  testWidgets('paste preview sends nothing until explicit confirmation', (
    tester,
  ) async {
    final b = FakeBackend();
    final controller = TerminalController(b);
    await controller.start();
    controller.phase = 'Connected';
    final key = GlobalKey<TerminalViewState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(key: key, controller: controller),
        ),
      ),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return {'text': 'echo a\necho b'};
        }
        return null;
      },
    );
    final operation = key.currentState!.paste();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(b.pastes, [('echo a\necho b', false)]);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await operation;
    expect(b.pastes.length, 1);
    final confirmed = key.currentState!.paste();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    await confirmed;
    expect(b.pastes, [
      ('echo a\necho b', false),
      ('echo a\necho b', false),
      ('echo a\necho b', true),
    ]);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('mouse release survives Shift pressed during a remote drag', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = TerminalController(backend);
    await controller.start();
    controller.phase = 'Connected';
    controller.applyFrame(fixture(mouse: true));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalView(controller: controller)),
      ),
    );
    final gesture = await tester.startGesture(const Offset(10, 10));
    await gesture.moveTo(const Offset(20, 20));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await gesture.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(backend.mouseActions, [0, 2, 1]);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets(
    'OSC52 disable revokes queued reads/writes and unlock restores layout PTY',
    (tester) async {
      final backend = FakeBackend(), c = TerminalController(FakeBackend());
      c.dispose();
      final controller = TerminalController(backend);
      await controller.start();
      controller.phase = 'Connected';
      controller.generation = 1;
      final read = Completer<Object?>();
      var writes = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return read.future;
          if (call.method == 'Clipboard.setData') writes++;
          return null;
        },
      );
      backend.events.add(
        rust.BridgeEvent(kind: 'clipboardRead', generation: 1, requestId: 12),
      );
      await tester.pump();
      await controller.setOsc52(false);
      read.complete({'text': 'synthetic clipboard'});
      backend.events.add(
        rust.BridgeEvent(
          kind: 'clipboardWrite',
          generation: 1,
          requestId: 13,
          text: 'synthetic remote',
        ),
      );
      await tester.pump();
      expect(backend.clipboardReplies, isEmpty);
      expect(writes, 0);
      await controller.setOsc52(true);
      backend.events.add(
        rust.BridgeEvent(
          kind: 'clipboardWrite',
          generation: 0,
          requestId: 14,
          text: 'old generation',
        ),
      );
      await tester.pump();
      expect(writes, 0);
      backend.events.add(
        rust.BridgeEvent(
          kind: 'clipboardWrite',
          generation: 1,
          requestId: 15,
          text: 'allowed',
        ),
      );
      await tester.pump();
      expect(writes, 1);
      controller.resize(95, 32, 9, 21);
      await tester.pump(const Duration(milliseconds: 70));
      final count = backend.resizes;
      await controller.lockSize(true);
      await controller.lockSize(false);
      expect(backend.resizes, count + 1);
      controller.dispose();
    },
  );
  test('repeated exit requests await the same native shutdown', () async {
    final backend = FakeBackend(),
        controller = TerminalController(FakeBackend());
    controller.dispose();
    final c = TerminalController(backend);
    await c.start();
    final release = Completer<void>();
    backend.closeWait = release.future;
    final first = c.shutdown(), second = c.shutdown();
    expect(identical(first, second), true);
    var returned = false;
    unawaited(second.then((_) => returned = true));
    await Future<void>.delayed(Duration.zero);
    expect(returned, false);
    expect(backend.closes, 1);
    release.complete();
    await first;
    await second;
    expect(returned, true);
    expect(c.id, isNull);
    c.dispose();
  }, timeout: const Timeout(Duration(seconds: 15)));
  testWidgets('search focus owns its keys and restores remote input on close', (
    tester,
  ) async {
    final backend = FakeBackend(), c = TerminalController(FakeBackend());
    c.dispose();
    final controller = TerminalController(backend);
    await controller.start();
    controller.phase = 'Connected';
    controller.applyFrame(fixture());
    final key = GlobalKey<TerminalViewState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(key: key, controller: controller),
        ),
      ),
    );
    key.currentState!.showSearch();
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('terminal-search-field')),
      'abc',
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(backend.searches.last, ('abc', false, false));
    expect(controller.searchSummary?.count, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(backend.keys, isEmpty);
    expect(backend.navigations.length, 2);
    await tester.tap(find.byTooltip('正则表达式'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(backend.searches.last, ('abc', true, false));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('terminal-search-field')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(backend.keys.any((k) => k.key == 'ArrowDown' && k.kind == 0), true);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test('copy preserves wrapped spaces and skips synthetic wide spacers', () {
    final c = TerminalController(FakeBackend());
    rust.RenderCell cell(String text, [int flags = 0]) => rust.RenderCell(
      text: text,
      foreground: 0xffffffff,
      background: 0xff000000,
      flags: flags,
    );
    c.rows = [
      [for (final ch in 'abcd '.split('')) cell(ch), cell(' ', 16)],
      [for (final ch in 'efg   '.split('')) cell(ch)],
    ];
    c.select(const Point(0, 0), const Point(2, 1));
    expect(c.selectedText(), 'abcd  efg');
    c.rows = [
      [for (final ch in 'abcd '.split('')) cell(ch), cell(' ', 1024 | 16)],
      [
        cell('中', 32),
        cell('', 64),
        cell('é'),
        cell(' '),
        cell(' '),
        cell(' '),
      ],
    ];
    c.select(const Point(0, 0), const Point(2, 1));
    expect(c.selectedText(), 'abcd 中é');
    c.dispose();
  });
  test('block cursor covers both columns of a wide character', () async {
    final controller = TerminalController(FakeBackend());
    controller.applyFrame(fixture(cursorRow: 0, cursorShape: 0));
    final recorder = ui.PictureRecorder(), cache = TerminalPaintCache();
    final blink = ValueNotifier(true), preedit = ValueNotifier('');
    final painter = TerminalPainter(
      controller,
      cache,
      15,
      const Size(10, 21),
      blink,
      true,
      preedit,
    );
    painter.paint(Canvas(recorder), const Size(60, 42));
    final picture = recorder.endRecording(),
        image = await picture.toImage(60, 42);
    final pixels = await image.toByteData();
    final offset = (60 + 15) * 4;
    expect(pixels!.buffer.asUint8List().sublist(offset, offset + 4), [
      255,
      255,
      255,
      255,
    ]);
    image.dispose();
    picture.dispose();
    cache.dispose();
    blink.dispose();
    preedit.dispose();
    controller.dispose();
  });
  test('ASCII runs preserve per-cell positions, Unicode and decorations', () async {
    final loader = FontLoader('JetBrainsMono')
      ..addFont(rootBundle.load('assets/fonts/JetBrainsMono-Regular.ttf'));
    await loader.load();
    final c = TerminalController(FakeBackend());
    const text = 'abc -> != == >= <= [] {} () / ** / 0123456789';
    c.rows = [
      for (final flags in [0, 1, 2, 4, 8, 512, 2048, 4096, 8192, 16384])
        text
            .split('')
            .map(
              (t) => rust.RenderCell(
                text: t,
                foreground: 0xffabcdef,
                background: 0xff10151d,
                flags: flags,
              ),
            )
            .toList(),
      fixture().changedRows.first.cells,
    ];
    c.rowVersions = List.filled(c.rows.length, 1);
    final metric = TextPainter(
      text: const TextSpan(
        text: 'M',
        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 15, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final cell = Size(metric.width, 21);
    metric.dispose();
    Future<List<int>> pixels(bool batch) async {
      final cache = TerminalPaintCache(batchAscii: batch),
          recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      cache.backgrounds(canvas, c, cell);
      for (var row = 0; row < c.rows.length; row++) {
        canvas.save();
        canvas.translate(0, row * cell.height);
        canvas.drawPicture(cache.row(c, row, 15, cell));
        canvas.restore();
      }
      final picture = recorder.endRecording(),
          image = await picture.toImage(
            (cell.width * text.length).ceil(),
            (cell.height * c.rows.length).ceil(),
          );
      final bytes = await image.toByteData();
      image.dispose();
      picture.dispose();
      cache.dispose();
      return bytes!.buffer.asUint8List();
    }

    final reference = await pixels(false), optimized = await pixels(true);
    var changed = 0, maxDifference = 0;
    for (var i = 0; i < reference.length; i++) {
      final diff = (reference[i] - optimized[i]).abs();
      if (diff > 0) changed++;
      maxDifference = max(maxDifference, diff);
    }
    // Small subpixel antialias differences are allowed; cell displacement,
    // substituted programming ligatures or missing decorations are not.
    expect(changed / reference.length, lessThan(.02));
    expect(
      maxDifference,
      lessThanOrEqualTo(16),
      reason:
          'Changed channels: $changed/${reference.length}; per row: ${List.generate(c.rows.length, (row) {
            var peak = 0;
            final start = row * 21 * (cell.width * text.length).ceil() * 4;
            for (var i = start; i < start + 21 * (cell.width * text.length).ceil() * 4; i++) {
              peak = max(peak, (reference[i] - optimized[i]).abs());
            }
            return peak;
          })}',
    );
    c.dispose();
  });
  test(
    'wide cells copy without spacer and unchanged row pictures are reused',
    () async {
      final c = TerminalController(FakeBackend());
      c.applyFrame(fixture());
      c.select(const Point(1, 0), const Point(2, 0));
      expect(c.selectedText(), '中é');
      final cache = TerminalPaintCache();
      final first = cache.row(c, 0, 15, const Size(9, 21));
      expect(identical(first, cache.row(c, 0, 15, const Size(9, 21))), true);
      c.applyFrame(fixture(revision: 2));
      expect(identical(first, cache.row(c, 0, 15, const Size(9, 21))), false);
      cache.dispose();
      c.dispose();
    },
  );
}
