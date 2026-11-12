import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/tmux_history.dart';

import 'support/fake_backend.dart';
import 'support/terminal_cleanup.dart';

class HistoryBackend extends FakeBackend implements TerminalTmuxHistoryBackend {
  final requests = <(int, int, String?, int?)>[];
  Completer<String>? hold;
  @override
  Future<String> tmuxHistory(
    int id,
    int generation,
    String? pane,
    int? offset,
  ) async {
    requests.add((id, generation, pane, offset));
    return hold?.future ??
        Future.value(
          jsonEncode({
            'pane': '%2',
            'history': 200,
            'offset': offset ?? 0,
            'rows': 24,
            'available': true,
            'readonly': false,
          }),
        );
  }
}

void main() {
  test('tmux snapshot rejects positions outside retained history', () {
    expect(
      () => TmuxHistorySnapshot(
        jsonEncode({
          'pane': '%2',
          'history': 10,
          'offset': 11,
          'rows': 24,
          'available': true,
          'readonly': false,
        }),
      ),
      throwsFormatException,
    );
  });
  testWidgets(
    'remote rail seeks the same pane, coalesces drags and stops polling when hidden',
    (tester) async {
      final backend = HistoryBackend();
      final c = TerminalController(backend);
      await c.start();
      c.phase = 'Connected';
      c.generation = 3;
      c.tmuxReadonly = false;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 12,
                  height: 300,
                  child: TmuxHistoryScrollbar(controller: c),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(backend.requests, [(1, 3, null, null)]);
        backend.hold = Completer<String>();
        final rail = find.byType(TmuxHistoryScrollbar);
        await tester.tapAt(tester.getTopLeft(rail) + const Offset(6, 1));
        await tester.pump();
        expect(backend.requests.last, (1, 3, '%2', 200));
        await tester.tapAt(tester.getBottomLeft(rail) + const Offset(6, -1));
        await tester.pump();
        expect(
          backend.requests.length,
          2,
          reason: 'one outstanding query per visible tab',
        );
        final hold = backend.hold!;
        backend.hold = null;
        hold.complete(
          jsonEncode({
            'pane': '%2',
            'history': 200,
            'offset': 200,
            'rows': 24,
            'available': true,
            'readonly': false,
          }),
        );
        await tester.pump();
        await tester.pump();
        expect(backend.requests.last, (1, 3, '%2', 0));
        await c.setVisible(false);
        await tester.pump();
        final count = backend.requests.length;
        await tester.pump(const Duration(seconds: 3));
        expect(backend.requests.length, count);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await closeTerminal(tester, c);
      }
    },
  );
}
