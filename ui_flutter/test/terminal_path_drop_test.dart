import 'support/terminal_cleanup.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/surface.dart';

import 'transfer_connection_selection_test.dart' show session;

void main() {
  testWidgets(
    'file drag accepts only original session and generation without replacing its view',
    (tester) async {
      final first = session('A', 1, 4), second = session('B', 2, 4);
      final calls = <(String, List<String>, int)>[];
      final drag = RemoteDrag(first.id, '/tmp/original dir', [
        DemoFile('f', "a'\$;.txt"),
        DemoFile('d', '中文', folder: true),
      ], generation: 4);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Draggable<RemoteDrag>(
                  data: drag,
                  feedback: const Text('drag'),
                  child: const SizedBox(
                    width: 80,
                    height: 30,
                    child: Text('source'),
                  ),
                ),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: LiveTerminalSurface(
                          session: first,
                          focused: true,
                          fontSize: 14,
                          onDropPaths: (paths, generation) async {
                            calls.add(('A', paths, generation));
                          },
                        ),
                      ),
                      Expanded(
                        child: LiveTerminalSurface(
                          session: second,
                          focused: false,
                          fontSize: 14,
                          onDropPaths: (paths, generation) async {
                            calls.add(('B', paths, generation));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final originalView = first.view.currentState;
      Future<void> drop(String id) async {
        final source = tester.getCenter(find.text('source'));
        final target = tester.getCenter(
          find.byKey(ValueKey('terminal-path-drop-$id')),
        );
        await tester.dragFrom(source, target - source);
        await tester.pump();
      }

      await drop(second.id);
      expect(calls, isEmpty);
      await drop(first.id);
      expect(calls.length, 1);
      expect(calls.single.$1, 'A');
      expect(calls.single.$2, [
        "/tmp/original dir/a'\$;.txt",
        '/tmp/original dir/中文',
      ]);
      expect(calls.single.$3, 4);
      expect(first.view.currentState, same(originalView));
      first.controller.generation = 5;
      await tester.pump();
      await drop(first.id);
      expect(
        calls.length,
        1,
        reason: 'a drag started in the prior Root cannot be re-targeted',
      );
      expect(second.controller.generation, 4);
      await tester.pumpWidget(const SizedBox());
      await closeTerminal(tester, first.controller);
      await closeTerminal(tester, second.controller);
    },
  );
}
