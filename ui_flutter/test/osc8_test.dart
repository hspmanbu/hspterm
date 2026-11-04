import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/links.dart';
import 'package:hspterm/terminal/view.dart';

import 'support/fake_backend.dart';

rust.RenderHyperlink span(String? uri, {int end = 6}) =>
    rust.RenderHyperlink(start: 0, end: end, uri: uri);

void main() {
  test('explicit targets win over deceptive labels and unsafe targets never fall back', () async {
    final backend = FakeBackend();
    final c = TerminalController(backend);
    try {
      const target = 'https://example.invalid/real;a?q=one#two';
      c.applyFrame(
        fixture(
          line: 'http://localhost:1234',
          hyperlinks: [span(target, end: 21)],
        ),
      );
      // Match the real label length, as a well-formed native frame does.
      c.hyperlinks[0] = [span(target, end: c.rows.first.length)];
      expect(
        TerminalLink.atGrid(c.rows, 0, 1, hyperlinks: c.hyperlinks)?.text,
        target,
      );
      expect(
        TerminalLink.atGrid(c.rows, 0, 1, hyperlinks: c.hyperlinks)?.canForward,
        false,
      );
      for (final invalid in [
        null,
        'file://user@host/etc/passwd',
        'javascript:alert(1)',
        'https://user:secret@example.invalid/',
        '127.0.0.1:22',
        'https://example.invalid/\u202eevil',
        'https://example.invalid/\u0085bad',
        'https://example.invalid/\u061cbad',
        'https://example.invalid/\nnext',
        'https://example.invalid/${'x' * 4096}',
      ]) {
        c.hyperlinks[0] = [span(invalid, end: c.rows.first.length)];
        expect(
          TerminalLink.atGrid(c.rows, 0, 1, hyperlinks: c.hyperlinks),
          isNull,
          reason: 'no unsafe target or label fallback',
        );
      }
      c.applyFrame(fixture(hyperlinks: [span(target)]));
      expect(
        TerminalLink.atGrid(c.rows, 0, 0, hyperlinks: c.hyperlinks)?.text,
        target,
      );
      expect(
        TerminalLink.atGrid(c.rows, 0, 1, hyperlinks: c.hyperlinks)?.text,
        target,
      );
      expect(
        TerminalLink.atGrid(c.rows, 0, 2, hyperlinks: c.hyperlinks)?.text,
        target,
      );
      c.rows[0][2] = const rust.RenderCell(
        text: 'hidden',
        foreground: 0,
        background: 0,
        flags: 256,
      );
      expect(
        TerminalLink.atGrid(c.rows, 0, 2, hyperlinks: c.hyperlinks),
        isNull,
      );
    } finally {
      c.dispose();
      await backend.events.close();
    }
  });
  test('OSC8 file target remains separate from browser URLs and deceptive label addresses', () async {
    final backend = FakeBackend();
    final controller = TerminalController(backend);
    controller.applyFrame(
      fixture(
        line: 'http://localhost:1234',
        hyperlinks: [span('file:///remote/a%20b', end: 21)],
      ),
    );
    controller.hyperlinks[0] = [
      span('file:///remote/a%20b', end: controller.rows.first.length),
    ];
    final link = TerminalLink.atGrid(
      controller.rows,
      0,
      1,
      hyperlinks: controller.hyperlinks,
    )!;
    expect(link.remoteFileUri, 'file:///remote/a%20b');
    expect(link.uri, isNull);
    expect(link.canForward, false);
    controller.dispose();
    await backend.events.close();
  });

  test('row deltas retain unchanged link metadata and full/overwritten rows retire it', () async {
    final backend = FakeBackend();
    final c = TerminalController(backend);
    try {
      c.applyFrame(fixture(hyperlinks: [span('https://example.invalid/a')]));
      final untouched = fixture(full: false)..changedRows.removeAt(0);
      c.applyFrame(untouched);
      expect(c.hyperlinks[0].single.uri, endsWith('/a'));
      c.applyFrame(
        fixture(full: false, hyperlinks: [span('https://example.invalid/b')]),
      );
      expect(c.hyperlinks[0].single.uri, endsWith('/b'));
      c.applyFrame(fixture(full: false));
      expect(c.hyperlinks[0], isEmpty);
      c.applyFrame(fixture(hyperlinks: [span('https://example.invalid/a')]));
      c.applyFrame(fixture());
      expect(c.hyperlinks.every((row) => row.isEmpty), true);
    } finally {
      c.dispose();
      await backend.events.close();
    }
  });

  for (final target in [
    'https://example.invalid/original',
    'file:///remote/a%20b',
  ]) {
    testWidgets(
      'OSC8 ${target.startsWith('file:') ? 'file' : 'web'} hover is passive, Ctrl click uses target, remote capture wins until Shift override',
      (tester) async {
        final backend = FakeBackend();
        final c = TerminalController(backend)
          ..phase = 'Connected'
          ..id = 1;
        final opened = <String>[];
        c.applyFrame(fixture(mouse: true, hyperlinks: [span(target)]));
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
        final point =
            tester.getTopLeft(find.byType(TerminalView)) + const Offset(5, 5);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tapAt(point);
        await tester.pump();
        expect(opened, isEmpty);
        expect(backend.mouseActions, isNotEmpty);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: point);
        await mouse.moveTo(point + const Offset(1, 1));
        await tester.pump(const Duration(milliseconds: 700));
        expect(opened, isEmpty);
        expect(find.byTooltip(target), findsOneWidget);
        final modifierKeys = backend.keys.length;
        await tester.tapAt(point);
        await tester.pump();
        expect(opened, [target]);
        expect(backend.texts, isEmpty);
        expect(
          backend.keys.length,
          modifierKeys,
          reason: 'link activation adds no terminal keystrokes; physical modifiers still follow the negotiated keyboard protocol',
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        await backend.events.close();
      },
    );
  }
}
