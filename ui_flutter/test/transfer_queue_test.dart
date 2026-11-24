import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/src/rust/transfers.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/queue.dart';
import 'package:hspterm/workbench/transfer_rate.dart';

TransferTaskView task(
  int n, {
  String state = 'Running',
  int conflicts = 0,
  int failed = 0,
  bool remoteMove = false,
  String? movePhase,
  bool relocate = false,
  int? sourceDeletionsConfirmed,
  int? sourceDeletionsTotal,
  List<TransferActiveFile>? activeFiles,
  bool explorer = false,
  bool upload = true,
  bool folder = false,
  String? local,
  int? terminalGeneration,
  int? sourceTerminalGeneration,
}) => TransferTaskView(
  id: 'task-$n',
  terminalId: 1,
  terminalGeneration: terminalGeneration,
  sourceTerminalGeneration: sourceTerminalGeneration,
  sourceTerminalId: remoteMove ? 2 : null,
  sourceHostId: remoteMove ? 'source-fixture' : null,
  sourceRemote: remoteMove ? '/source/item-$n.txt' : null,
  remoteOperation: remoteMove ? (relocate ? 'relocate' : 'move') : null,
  remoteTransport: explorer ? 'explorer_snapshot' : null,
  sourceDeletionsConfirmed: sourceDeletionsConfirmed,
  sourceDeletionsTotal: sourceDeletionsTotal,
  remoteMovePhase: movePhase,
  hostId: 'fixture',
  name: 'item-$n.txt',
  local: local ?? '/fixture/item-$n.txt',
  remote: '/remote/item-$n.txt',
  upload: upload,
  folder: folder,
  state: state,
  busy: state == 'Running',
  discovered: 1,
  files: 1,
  directories: 0,
  completed: 0,
  failed: failed,
  conflicts: conflicts,
  skipped: 0,
  acknowledged: remoteMove ? 0 : 100,
  total: remoteMove ? 0 : 1000,
  current: 'item-$n.txt',
  activeFiles: activeFiles,
  error: null,
);

/// UI routing fixture only; real queue/SQLite/OpenSSH is tested separately.
class QueueFixture extends LiveWorkbenchModel {
  final actions = <String>[];
  @override
  Future<void> controlTransfer(
    TransferTaskView task,
    String action, {
    int? node,
    String? rename,
    TransferConnectionRef? sourceConnection,
    TransferConnectionRef? targetConnection,
  }) async {
    actions.add('${task.id}:$action');
  }
}

void main() {
  testWidgets('file folder paused and remote uploads expose per-item cancel', (
    tester,
  ) async {
    final model = QueueFixture()..allTasks = true;
    model.transferTasks = [
      task(0),
      task(1, folder: true),
      task(2, state: 'Paused'),
      task(3, remoteMove: true),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LiveTransferQueue(model: model)),
      ),
    );
    expect(find.byTooltip('取消上传'), findsNWidgets(4));
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byTooltip('取消上传').at(i));
      await tester.pump();
    }
    expect(model.actions, [
      'task-3:cancel',
      'task-2:cancel',
      'task-1:cancel',
      'task-0:cancel',
    ]);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets(
    'completed downloads open their own file or folder without SSH or a new transfer',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'hspterm-download-open-',
      );
      final file = File('${directory.path}/fixture.txt');
      file.writeAsStringSync('fixture');
      final model = QueueFixture()..allTasks = true;
      model.transferTasks = [
        task(0, state: 'Complete', upload: false, local: file.path),
        task(
          1,
          state: 'CompleteWithSkips',
          upload: false,
          folder: true,
          local: directory.path,
        ),
        task(2, upload: false, local: file.path),
      ];
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Scaffold(
            body: LiveTransferQueue(
              model: model,
              launchLocal: (uri) async {
                opened.add(uri);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.textContaining('已结束'));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('live-transfer-task-0'));
      await tester.ensureVisible(row);
      await tester.runAsync(() async {
        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('打开文件')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(opened.single, Uri.file(file.absolute.path));
      await tester.runAsync(() async {
        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('打开所在文件夹')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(opened.last, Uri.directory(directory.absolute.path));
      final folder = find.byKey(const ValueKey('live-transfer-task-1'));
      await tester.ensureVisible(folder);
      await tester.runAsync(() async {
        await tester.tap(
          find.descendant(of: folder, matching: find.byTooltip('打开目录')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(opened.last, Uri.directory(directory.absolute.path));
      expect(opened, hasLength(3));
      expect(model.actions, isEmpty);
      final active = find.byKey(const ValueKey('live-transfer-task-2'));
      expect(
        find.descendant(of: active, matching: find.byTooltip('打开文件')),
        findsNothing,
      );
      file.deleteSync();
      await tester.ensureVisible(row);
      await tester.runAsync(() async {
        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('打开文件')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(opened, hasLength(3));
      expect(find.textContaining('已不存在'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      directory.deleteSync(recursive: true);
    },
  );

  testWidgets(
    'Explorer ready source is distinct from external destination success',
    (tester) async {
      final model = QueueFixture()..allTasks = true;
      model.transferTasks = [task(0, state: 'ExportReady', explorer: true)];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 540,
              height: 420,
              child: LiveTransferQueue(model: model),
            ),
          ),
        ),
      );
      expect(find.text('源快照就绪 · 可拖出'), findsOneWidget);
      expect(find.byTooltip('继续任务'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'expanded folder task lists only bounded active files with individual acknowledged bytes',
    (tester) async {
      final m = QueueFixture()..allTasks = true;
      m.transferTasks = [
        task(
          0,
          activeFiles: const [
            TransferActiveFile(
              path: 'nested/first.bin',
              acknowledged: 1024,
              total: 4096,
            ),
            TransferActiveFile(
              path: '中文/second.bin',
              acknowledged: 2048,
              total: 8192,
            ),
          ],
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Scaffold(
            body: SizedBox(
              width: 380,
              height: 500,
              child: LiveTransferQueue(model: m),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('展开任务详情'));
      await tester.pump();
      expect(find.text('当前文件：nested/first.bin'), findsOneWidget);
      expect(find.text('当前文件：中文/second.bin'), findsOneWidget);
      expect(find.text('1.0 KiB / 4.0 KiB'), findsOneWidget);
      expect(find.text('2.0 KiB / 8.0 KiB'), findsOneWidget);
      expect(find.text('当前文件：item-0.txt'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'metadata move shows source and target without invented file-byte progress',
    (tester) async {
      final m = QueueFixture()..allTasks = true;
      m.transferTasks = [task(0, state: 'Complete', remoteMove: true)];
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
      await tester.tap(find.textContaining('已结束'));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('live-transfer-task-0'));
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('展开任务详情')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('远端移动：/source/item-0.txt'), findsOneWidget);
      expect(find.text('服务器直接移动；未扫描内部目录，不统计传输字节'), findsOneWidget);
      expect(find.text('服务器直接移动 · 无正文中转'), findsOneWidget);
      expect(find.textContaining('0 B /'), findsNothing);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.descendant(
                of: row,
                matching: find.byType(LinearProgressIndicator),
              ),
            )
            .value,
        1,
      );
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'batch conflict decision is explicit and scoped to the clicked task',
    (tester) async {
      final m = QueueFixture()..allTasks = true;
      m.transferTasks = [
        task(0, state: 'Partial', conflicts: 2, failed: 1),
        task(1, state: 'Paused'),
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
      // The queue now prompts once on discovering conflicts; explicitly
      // decline before testing the manually reopened task menu.
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-transfer-task-1')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byKey(const ValueKey('live-transfer-task-0')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      Future<void> open() async {
        await tester.tap(
          find.byKey(const ValueKey('live-transfer-task-0')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('处理本任务同名冲突…'));
        await tester.pumpAndSettle();
      }

      await open();
      expect(find.text('处理 2 个同名冲突？'), findsOneWidget);
      expect(find.textContaining('已成功文件和其他失败项不受影响'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(m.actions, isEmpty);
      await open();
      await tester.tap(find.text('全部明确从头覆盖'));
      await tester.pumpAndSettle();
      expect(m.actions, ['task-0:overwrite_conflicts']);
      await open();
      await tester.tap(find.text('全部跳过'));
      await tester.pumpAndSettle();
      await open();
      await tester.tap(find.text('全部更名另存'));
      await tester.pumpAndSettle();
      expect(m.actions, [
        'task-0:overwrite_conflicts',
        'task-0:skip_conflicts',
        'task-0:rename_conflicts',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets(
    'large real queue builds only visible rows and routes Ctrl multiselect',
    (tester) async {
      final m = QueueFixture()..allTasks = true;
      m.transferTasks = List.generate(2000, task);
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 380,
                height: 300,
                child: AnimatedBuilder(
                  animation: m,
                  builder: (_, _) => LiveTransferQueue(model: m),
                ),
              ),
            ),
          ),
        ),
      );
      // Newest task first: task-1999 (enqueued last) is the top visible row
      // and task-0 is far offscreen, so only the head of the queue builds.
      expect(find.text('item-0.txt'), findsNothing);
      expect(
        find.byKey(const ValueKey('live-transfer-task-1999')),
        findsOneWidget,
      );
      expect(find.byType(Text).evaluate().length, lessThan(100));
      await tester.tap(find.byKey(const ValueKey('live-transfer-task-1999')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byKey(const ValueKey('live-transfer-task-1998')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.tap(find.byTooltip('批量暂停'));
      await tester.pump();
      expect(m.actions, ['task-1999:pause', 'task-1998:pause']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets(
    'compact queue supports text scaling and keeps successful rows folded',
    (tester) async {
      final m = QueueFixture()..allTasks = true;
      m.transferTasks = [task(0), task(1, state: 'Complete')];
      m.transferRates['task-0'] = TransferRate()
        ..sample(
          acknowledged: 0,
          total: 1000,
          running: true,
          elapsed: Duration.zero,
        )
        ..sample(
          acknowledged: 100,
          total: 1000,
          running: true,
          elapsed: const Duration(milliseconds: 500),
        );
      for (final scale in [1.0, 1.5]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: Desk.theme(false),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 260,
                    height: 180,
                    child: LiveTransferQueue(model: m),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('item-1.txt'), findsNothing);
        expect(find.textContaining('200 B/s'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'text scale $scale');
      }
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
}
