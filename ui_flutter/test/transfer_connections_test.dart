import 'support/terminal_cleanup.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/transfer_connections.dart';

import 'transfer_connection_selection_test.dart' show session;
import 'transfer_queue_test.dart' show task;

class TransferTestSessions extends LiveWorkbenchModel {
  TransferTestSessions(this.items);
  final List<LiveTerminalSession> items;
  @override
  List<TerminalSession> get sessions => List.unmodifiable(items);
}

Future<void> launch(
  WidgetTester tester,
  TransferTestSessions model,
  ValueChanged<TransferConnections?> result, {
  bool remote = false,
}) async {
  model.transferTasks = [task(1, state: 'Paused', remoteMove: remote)];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result(
                await showTransferConnections(
                  context,
                  model,
                  task(1, state: 'Paused', remoteMove: remote),
                ),
              );
            },
            child: const Text('choose'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('choose'));
  await tester.pumpAndSettle();
}

Finder confirm() => find.byKey(const ValueKey('transfer-confirm-connections'));
DropdownButton<TransferConnectionRef> selector(
  WidgetTester tester,
  String key,
) => tester.widget<DropdownButton<TransferConnectionRef>>(
  find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(DropdownButton<TransferConnectionRef>),
  ),
);

void main() {
  testWidgets(
    'no implicit candidate and cancel does not start or reconnect a task',
    (tester) async {
      final target = session('Target', 1, 2, host: 'fixture');
      final model = TransferTestSessions([target]);
      TransferConnections? result;
      await launch(tester, model, (value) => result = value);
      expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(target.controller.generation, 2);
      await tester.pumpWidget(const SizedBox());
      await drainAsync(tester, model.shutdown());
      model.dispose();
    },
  );
  testWidgets(
    'source and target can be chosen independently from existing labels',
    (tester) async {
      final source = session('Source', 2, 4, host: 'source-fixture');
      final target = session('Target', 1, 7, host: 'fixture');
      final model = TransferTestSessions([source, target]);
      TransferConnections? result;
      await launch(tester, model, (value) => result = value, remote: true);
      final sourcePicker = selector(tester, 'transfer-source-connection');
      final targetPicker = selector(tester, 'transfer-target-connection');
      sourcePicker.onChanged!(sourcePicker.items!.single.value);
      await tester.pump();
      targetPicker.onChanged!(targetPicker.items!.single.value);
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm()).onPressed, isNotNull);
      await tester.tap(confirm());
      await tester.pumpAndSettle();
      expect(result!.source!.session, same(source));
      expect(result!.source!.generation, 4);
      expect(result!.target.session, same(target));
      expect(result!.target.generation, 7);
      await tester.pumpWidget(const SizedBox());
      await drainAsync(tester, model.shutdown());
      model.dispose();
    },
  );
  testWidgets(
    'a chosen connection changing generation cannot be implicitly reselected',
    (tester) async {
      final target = session('Target', 1, 2, host: 'fixture');
      final model = TransferTestSessions([target]);
      await launch(tester, model, (_) {});
      final picker = selector(tester, 'transfer-target-connection');
      picker.onChanged!(picker.items!.single.value);
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm()).onPressed, isNotNull);
      target.controller.generation++;
      target.controller.notifyListeners();
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
      expect(
        selector(tester, 'transfer-target-connection').items!.single.enabled,
        false,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await drainAsync(tester, model.shutdown());
      model.dispose();
    },
  );
  testWidgets('a target alone cannot authorize two-ended recovery', (
    tester,
  ) async {
    final target = session('Target', 1, 2, host: 'fixture');
    final model = TransferTestSessions([target]);
    await launch(tester, model, (_) {}, remote: true);
    final picker = selector(tester, 'transfer-target-connection');
    picker.onChanged!(picker.items!.single.value);
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
    expect(find.text('缺少已连接的原主机标签；请取消后先手动连接。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await drainAsync(tester, model.shutdown());
    model.dispose();
  });
  testWidgets(
    'another action changing the task disables a pending recovery selection',
    (tester) async {
      final target = session('Target', 1, 2, host: 'fixture');
      final model = TransferTestSessions([target]);
      await launch(tester, model, (_) {});
      final picker = selector(tester, 'transfer-target-connection');
      picker.onChanged!(picker.items!.single.value);
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm()).onPressed, isNotNull);
      model.transferTasks = [task(1, state: 'Running')];
      model.changed();
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm()).onPressed, isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await drainAsync(tester, model.shutdown());
      model.dispose();
    },
  );

  test(
    'refs fail closed after removal, generation change or profile mismatch',
    () async {
      final target = session('Target', 1, 2, host: 'fixture');
      final ref = TransferConnectionRef(target);
      expect(ref.valid([target], 'fixture'), true);
      expect(ref.valid([], 'fixture'), false);
      expect(ref.valid([target], 'foreign'), false);
      target.controller.generation++;
      expect(ref.valid([target], 'fixture'), false);
      await target.controller.shutdown();
      target.controller.dispose();
    },
  );
}
