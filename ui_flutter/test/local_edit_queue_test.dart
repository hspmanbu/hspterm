//! Round-9: local-edit tasks appear in the transfer queue with their own
//! lightweight tiles (never as normal downloads), progress states and
//! file/folder actions.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/local_edit_launch.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/queue.dart';

import 'support/fake_backend.dart';

class RecordingGateway implements LocalEditGateway {
  final remoteFiles = <String, List<int>>{};
  final uploads = <(String, List<int>)>[];
  bool failUpload = false;

  @override
  Future<void> downloadTo(
    int native,
    int generation,
    String path,
    File target, {
    void Function(int done, int? total)? onProgress,
  }) async {
    final bytes = List.of(remoteFiles[path] ?? 'hello'.codeUnits);
    onProgress?.call(0, bytes.length);
    await target.writeAsBytes(bytes, flush: true);
    onProgress?.call(bytes.length, bytes.length);
  }

  @override
  Future<({int size, int? mtime})> stat(
    int native,
    int generation,
    String path,
  ) async => (size: (remoteFiles[path] ?? 'hello'.codeUnits).length, mtime: 5);

  @override
  Future<void> uploadFrom(
    int native,
    int generation,
    String path,
    File source, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (failUpload) throw StateError('offline');
    final bytes = await source.readAsBytes();
    uploads.add((path, bytes));
    onProgress?.call(bytes.length, bytes.length);
  }

  @override
  Future<String> replaceAtomic(
    int native,
    int generation,
    String temp,
    String original,
  ) {
    remoteFiles[original] = uploads.lastWhere((u) => u.$1 == temp).$2;
    return Future.value('Applied');
  }

  @override
  Future<String> replaceConfirmed(
    int native,
    int generation,
    String temp,
    String original,
  ) {
    remoteFiles[original] = uploads.lastWhere((u) => u.$1 == temp).$2;
    return Future.value('Applied');
  }

  @override
  Future<void> removeFile(int native, int generation, String path) =>
      Future.value();
}

void main() {
  late DirectoryRoot root;
  late RecordingGateway gateway;
  late LiveWorkbenchModel model;

  setUp(() {
    root = DirectoryRoot();
    gateway = RecordingGateway();
    model = LiveWorkbenchModel();
  });

  tearDown(() async {
    await model.localEdits.disposeAll();
    model.dispose();
    root.dispose();
  });

  Future<LiveTerminalSession> connectedSession() async {
    final b = FakeBackend();
    final session = LiveTerminalSession(
      't',
      DemoHost('h1', 'fixture', 'example.invalid', 'Default'),
      b,
    );
    await session.controller.start();
    session.controller
      ..id = 1
      ..phase = 'Connected'
      ..generation = 2;
    return session;
  }

  Future<LocalEditSession> launchEdit(
    LiveTerminalSession s,
    String name,
  ) async {
    final file = DemoFile('/dir/$name', name, byteSize: 5, size: '5 B');
    late final LocalEditSession created;
    await LocalEditSession.launch(
      s,
      file,
      gateway: gateway,
      onNotice: (_) {},
      rootOverride: root.directory,
      launchOverride: (_) async => true,
      onSession: (session) {
        created = session;
        model.localEdits.register(session);
      },
    );
    return created;
  }

  testWidgets(
    'edit transfer progress handles upload download unknown totals and empty files',
    (tester) async {
      final source = (await tester.runAsync(connectedSession))!;
      final edit = (await tester.runAsync(
        () => launchEdit(source, 'progress.txt'),
      ))!;
      Future<void> render(LocalEditStatus status, int done, int? total) async {
        edit.status = status;
        edit.progressDone = done;
        edit.progressTotal = total;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: LiveTransferQueue(model: model)),
          ),
        );
        await tester.pump();
      }

      await render(LocalEditStatus.downloading, 1024, 2048);
      expect(find.text('50% · 1.0 KiB / 2.0 KiB'), findsOneWidget);
      await render(LocalEditStatus.uploading, 1048576, 2097152);
      expect(find.byTooltip('取消上传'), findsOneWidget);
      expect(find.text('50% · 1.0 MiB / 2.0 MiB'), findsOneWidget);
      await render(LocalEditStatus.downloading, 10, null);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        null,
      );
      await render(LocalEditStatus.uploading, 0, 0);
      expect(find.text('100% · 0 B / 0 B'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      source.controller.dispose();
    },
  );

  testWidgets('edit task renders its own queue section and tile', (
    tester,
  ) async {
    gateway.remoteFiles['/dir/notes.md'] = 'hello'.codeUnits;
    final s = (await tester.runAsync(connectedSession))!;
    final session = (await tester.runAsync(() => launchEdit(s, 'notes.md')))!;
    expect(session.status, LocalEditStatus.editing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LiveTransferQueue(model: model)),
      ),
    );
    await tester.pump();
    expect(find.textContaining('本地编辑 · 1'), findsOneWidget);
    expect(find.text('notes.md'), findsOneWidget);
    // Subtitle shows only host + remote path, with the same string as the
    // hover Tooltip for the truncated case; no lifecycle status text.
    expect(find.text('fixture · /dir/notes.md'), findsOneWidget);
    expect(find.byTooltip('fixture · /dir/notes.md'), findsOneWidget);
    expect(find.textContaining('正在本地编辑'), findsNothing);
    // The remote path is visible from the tile.
    expect(find.textContaining('/dir/notes.md'), findsOneWidget);
    expect(find.byTooltip('打开本地文件'), findsOneWidget);
    expect(find.byTooltip('打开所在文件夹'), findsOneWidget);
    // The overflow menu is gone; ending the session is a direct icon.
    expect(find.byTooltip('本地编辑任务'), findsNothing);
    expect(find.byTooltip('结束编辑会话'), findsOneWidget);
    // No retry button while healthy.
    expect(find.byTooltip('重试上传'), findsNothing);
    // The group heading collapses and re-expands the edit tiles.
    await tester.tap(find.textContaining('本地编辑 ·'));
    await tester.pump();
    expect(find.text('notes.md'), findsNothing);
    await tester.tap(find.textContaining('本地编辑 ·'));
    await tester.pump();
    expect(find.text('notes.md'), findsOneWidget);
    s.controller.dispose();
  });

  testWidgets('failed upload shows retry and the task recovers', (
    tester,
  ) async {
    gateway.remoteFiles['/dir/a.txt'] = 'hello'.codeUnits;
    final s = (await tester.runAsync(connectedSession))!;
    final session = (await tester.runAsync(() => launchEdit(s, 'a.txt')))!;
    gateway.failUpload = true;
    final file = session.localFile;
    await tester.runAsync(() async {
      await file.writeAsString('v2');
      await session.testStableCheck();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LiveTransferQueue(model: model)),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('重试上传'), findsOneWidget);
    // Status text no longer lives in the subtitle; failure is actionable
    // through the retry button and the session can still be ended directly.
    expect(find.byTooltip('结束编辑会话'), findsOneWidget);

    gateway.failUpload = false;
    // Retrying through the tile would start real file IO inside the fake
    // zone (it can never settle there), so the completed retry runs in
    // runAsync; the button wiring is covered by the finder above.
    await tester.runAsync(session.retry);
    await tester.pump();
    expect(uploadsRecorded(gateway), isTrue);
    expect(session.status, LocalEditStatus.editing);
    s.controller.dispose();
  });
}

bool uploadsRecorded(RecordingGateway gateway) => gateway.uploads.isNotEmpty;

class DirectoryRoot {
  final directory = Directory.systemTemp.createTempSync('edit-queue-test');
  void dispose() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
