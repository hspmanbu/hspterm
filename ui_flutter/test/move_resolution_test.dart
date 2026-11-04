import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/src/rust/remote_transfers.dart';
import 'package:hspterm/src/rust/transfers.dart';
import 'package:hspterm/workbench/move_resolution.dart';
import 'package:hspterm/workbench/queue.dart';

import 'transfer_queue_test.dart' show QueueFixture, task;

// UI routing only; actual lost OpenSSH replies, database failure and retained
// reservations are checked independently by remote_move_resolution_bridge_test.
class _ResolutionModel extends QueueFixture {
  final inspections = <String>[];
  final acknowledgements = <(String, String)>[];
  Completer<RemoteMoveInspection>? deferred;
  bool reject = false, inaccessible = false;
  @override
  Future<RemoteMoveEndReview> prepareRemoteMoveEnd(
    TransferTaskView task,
  ) async => const RemoteMoveEndReview(
    ticket: 'local-review-only',
    account: 'synthetic loopback',
    fingerprint: 'synthetic fingerprint',
    sourcePath: '/source/original',
    destinationPath: '/target/original',
  );
  @override
  Future<RemoteMoveInspection> inspectRemoteMove(TransferTaskView task) async {
    inspections.add(task.id);
    if (inaccessible) throw StateError('no connected original SSH');
    return deferred?.future ??
        const RemoteMoveInspection(
          ticket: 'routing-only',
          account: 'synthetic loopback',
          sourcePath: '/source/original',
          destinationPath: '/target/original',
          sourceKind: 'File',
          destinationKind: 'File',
          sourceSize: 42,
          destinationSize: 42,
        );
  }

  @override
  Future<void> endRemoteMoveWait(TransferTaskView task, String ticket) async {
    acknowledgements.add((task.id, ticket));
    if (reject) throw StateError('synthetic persistence failure');
  }
}

Future<void> _mount(
  WidgetTester tester,
  _ResolutionModel m, {
  bool relocate = false,
}) async {
  m.allTasks = true;
  m.transferTasks = [
    task(
      0,
      state: 'Failed',
      remoteMove: true,
      movePhase: 'Intent',
      relocate: relocate,
      sourceDeletionsConfirmed: relocate ? 0 : null,
      sourceDeletionsTotal: relocate ? 1 : null,
    ),
  ];
  await tester.pumpWidget(
    MaterialApp(
      theme: Desk.theme(false),
      home: Scaffold(
        body: SizedBox(
          width: 380,
          height: 400,
          child: LiveTransferQueue(model: m),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.text(relocate ? '来源删除结果未确认' : '移动结果未确认'), findsOneWidget);
  expect(find.byTooltip('继续任务'), findsNothing);
  await tester.tap(find.byTooltip(relocate ? '检查未确认的来源删除' : '检查未确认移动'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'unknown source deletion has distinct facts and offline local ending without resume',
    (tester) async {
      final m = _ResolutionModel()..inaccessible = true;
      await _mount(tester, m, relocate: true);
      expect(find.text('检查未确认的来源删除'), findsWidgets);
      expect(find.textContaining('来源清理 0 / 1'), findsOneWidget);
      expect(find.byTooltip('继续任务'), findsNothing);
      expect(m.acknowledgements, isEmpty);
      await tester.tap(find.text('结束本机等待'));
      await tester.pumpAndSettle();
      expect(m.acknowledgements, [('task-0', 'local-review-only')]);
      expect(m.actions, isEmpty);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets(
    'missing SSH metadata does not prevent an explicitly authorized local end',
    (tester) async {
      final m = _ResolutionModel()..inaccessible = true;
      await _mount(tester, m);
      expect(find.textContaining('仍可仅结束本机等待'), findsOneWidget);
      expect(find.text('尚未核对当前远端属性'), findsNWidgets(2));
      expect(m.acknowledgements, isEmpty);
      await tester.tap(find.text('结束本机等待'));
      await tester.pumpAndSettle();
      expect(m.acknowledgements, [('task-0', 'local-review-only')]);
      expect(find.byType(MoveResolutionDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'local ending need not wait for an optional stalled metadata read',
    (tester) async {
      final m = _ResolutionModel()
        ..deferred = Completer<RemoteMoveInspection>();
      m.allTasks = true;
      m.transferTasks = [
        task(0, state: 'Failed', remoteMove: true, movePhase: 'Intent'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Scaffold(body: LiveTransferQueue(model: m)),
        ),
      );
      await tester.tap(find.byTooltip('检查未确认移动'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('结束本机等待'));
      await tester.pumpAndSettle();
      expect(m.acknowledgements, [('task-0', 'local-review-only')]);
      expect(find.byType(MoveResolutionDialog), findsNothing);
      m.deferred!.complete(
        const RemoteMoveInspection(
          ticket: 'late-network-only',
          account: 'fixture',
          sourcePath: '/source',
          destinationPath: '/target',
          sourceKind: 'Missing',
          destinationKind: 'File',
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets('late metadata cannot replace a local persistence failure', (
    tester,
  ) async {
    final m = _ResolutionModel()
      ..deferred = Completer<RemoteMoveInspection>()
      ..reject = true;
    m.allTasks = true;
    m.transferTasks = [
      task(0, state: 'Failed', remoteMove: true, movePhase: 'Intent'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: Desk.theme(false),
        home: Scaffold(body: LiveTransferQueue(model: m)),
      ),
    );
    await tester.tap(find.byTooltip('检查未确认移动'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('结束本机等待'));
    await tester.pump();
    m.deferred!.complete(
      const RemoteMoveInspection(
        ticket: 'late-network-only',
        account: 'fixture',
        sourcePath: '/source',
        destinationPath: '/target',
        sourceKind: 'Missing',
        destinationKind: 'File',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('synthetic persistence failure'),
      findsOneWidget,
    );
    expect(find.text('当前路径不存在'), findsNothing);
    await tester.tap(find.text('关闭').last);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
  testWidgets(
    'equal-size path metadata never auto-acknowledges and closing leaves the task unresolved',
    (tester) async {
      final m = _ResolutionModel();
      await _mount(tester, m);
      expect(m.inspections, ['task-0']);
      expect(find.text('普通文件 · 42 字节（元数据）'), findsNWidgets(2));
      expect(m.acknowledgements, isEmpty);
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      expect(m.acknowledgements, isEmpty);
      expect(find.text('移动结果未确认'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets(
    'explicit acknowledgement reports persistence failure and retries the same inspection without remote control',
    (tester) async {
      final m = _ResolutionModel()..reject = true;
      await _mount(tester, m);
      await tester.tap(find.text('结束本机等待'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('synthetic persistence failure'),
        findsOneWidget,
      );
      expect(find.byType(MoveResolutionDialog), findsOneWidget);
      m.reject = false;
      await tester.tap(find.text('结束本机等待'));
      await tester.pumpAndSettle();
      expect(m.acknowledgements, [
        ('task-0', 'local-review-only'),
        ('task-0', 'local-review-only'),
      ]);
      expect(m.actions, isEmpty);
      expect(find.byType(MoveResolutionDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets(
    'closing during inspection suppresses its late result and no acknowledgement is sent',
    (tester) async {
      final m = _ResolutionModel()
        ..deferred = Completer<RemoteMoveInspection>();
      // Avoid pumpAndSettle while the real dialog displays an indeterminate bar.
      m.allTasks = true;
      m.transferTasks = [
        task(0, state: 'Failed', remoteMove: true, movePhase: 'Intent'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Scaffold(body: LiveTransferQueue(model: m)),
        ),
      );
      await tester.tap(find.byTooltip('检查未确认移动'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      m.deferred!.complete(
        const RemoteMoveInspection(
          ticket: 'late-routing-only',
          account: 'fixture',
          sourcePath: '/source',
          destinationPath: '/target',
          sourceKind: 'Missing',
          destinationKind: 'File',
        ),
      );
      await tester.pumpAndSettle();
      expect(m.acknowledgements, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets(
    'batch continue skips an uncertain move and continues unrelated paused work',
    (tester) async {
      final m = _ResolutionModel();
      await _mount(tester, m);
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      m.transferTasks.add(task(1, state: 'Paused'));
      m.changed();
      // This fixture uses a direct rebuild rather than a Native registry update.
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Scaffold(
            body: LiveTransferQueue(key: UniqueKey(), model: m),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('live-transfer-task-0')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byKey(const ValueKey('live-transfer-task-1')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.tap(find.byTooltip('批量继续'));
      await tester.pumpAndSettle();
      expect(m.actions, ['task-1:continue']);
      expect(m.acknowledgements, isEmpty);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets(
    'manually ended moves are labeled separately from success and fit a scaled dialog',
    (tester) async {
      tester.view.physicalSize = const Size(720, 600);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final m = _ResolutionModel();
      await _mount(tester, m);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      m.transferTasks = [
        task(0, state: 'Cancelled', remoteMove: true, movePhase: 'UserEnded'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Scaffold(
            body: LiveTransferQueue(key: UniqueKey(), model: m),
          ),
        ),
      );
      await tester.tap(find.textContaining('已结束'));
      await tester.pumpAndSettle();
      expect(find.text('已人工结束 · 结果未判定'), findsOneWidget);
      expect(find.text('已完成'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
}
