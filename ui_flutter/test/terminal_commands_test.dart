import 'support/terminal_cleanup.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/view.dart';

import 'support/fake_backend.dart';

class CommandsBackend extends FakeBackend implements TerminalCommandsBackend {
  final copies = <(int, int, int, int, int)>[];
  final jumps = <(int, int, int, int, bool)>[];
  Completer<String>? copyWait;
  @override
  Future<String> copyCommandAt(
    int id,
    int generation,
    int revision,
    int row,
    int column,
  ) async {
    copies.add((id, generation, revision, row, column));
    return copyWait?.future ?? 'actual command output\n';
  }

  @override
  Future<void> navigateCommand(
    int id,
    int generation,
    int revision,
    int topRow,
    bool next,
  ) async {
    jumps.add((id, generation, revision, topRow, next));
  }
}

void main() {
  test(
    'optional capability leaves original terminal backends unchanged',
    () async {
      final c = TerminalController(FakeBackend());
      await c.start();
      expect(c.commandOperationsAvailable, isFalse);
      expect(await c.copyCommandAt(0, 0, 1), isNull);
      await c.shutdown();
      c.dispose();
    },
  );
  test('command requests bind original terminal, generation, frame coordinates and do not send input', () async {
    final b = CommandsBackend();
    final c = TerminalController(b);
    await c.start();
    c.generation = 4;
    c.phase = 'Disconnected';
    expect(await c.copyCommandAt(20, 3, 55), 'actual command output\n');
    expect(b.copies.single, (1, 4, 55, 20, 3));
    await c.navigateCommand(false, 18, 55);
    expect(b.jumps.single, (1, 4, 55, 18, false));
    expect(b.keys, isEmpty);
    expect(b.texts, isEmpty);
    expect(b.connects, 0);
    await c.shutdown();
    c.dispose();
  });
  test('late output copy is discarded after new PTY generation', () async {
    final b = CommandsBackend()..copyWait = Completer();
    final c = TerminalController(b);
    await c.start();
    c.generation = 1;
    c.phase = 'Connected';
    final pending = c.copyCommandAt(10, 2, 3);
    c.generation = 2;
    b.copyWait!.complete('must not reach another session clipboard');
    expect(await pending, isNull);
    await c.shutdown();
    c.dispose();
  });
  testWidgets(
    'local OSC133 menu provides explicit copy/navigation without intercepting TUI keys',
    (tester) async {
      final b = CommandsBackend();
      final c = TerminalController(b);
      await c.start();
      c.generation = 1;
      c.phase = 'Connected';
      c.metadata = fixture();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TerminalView(controller: c)),
        ),
      );
      await tester.pumpAndSettle();
      final point =
          tester.getTopLeft(find.byType(TerminalView)) + const Offset(40, 15);
      final click = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await click.addPointer(location: point);
      await click.down(point);
      await click.up();
      await tester.pumpAndSettle();
      expect(find.text('复制所在命令的输出（OSC133）'), findsOneWidget);
      expect(find.text('上一命令标记'), findsOneWidget);
      expect(b.copies, isEmpty);
      expect(b.jumps, isEmpty);
      await tester.tap(find.text('上一命令标记'));
      await tester.pumpAndSettle();
      expect(b.jumps, hasLength(1));
      expect(b.texts, isEmpty);
      expect(b.keys, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await closeTerminal(tester, c);
    },
  );
}
