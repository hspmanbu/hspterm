import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/src/rust/editors.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/workbench/editor_controller.dart';
import 'package:hspterm/workbench/file_editor.dart';
import 'package:hspterm/workbench/model.dart';

import 'support/fake_backend.dart';

EditorSummary row({
  int revision = 1,
  int saved = 1,
  int? terminal = 17,
  String encoding = 'utf8',
  String ending = 'lf',
  String? directory,
  int? rawBytes,
}) => EditorSummary(
  id: 'edit-fixture',
  hostId: 'host-fixture',
  address: 'fixture.invalid',
  port: 22,
  username: 'fixture',
  path: '/files/中文.txt',
  revision: revision,
  savedRevision: saved,
  encoding: encoding,
  lineEnding: ending,
  terminalId: terminal,
  active: true,
  externalDirectory: directory,
  rawBytes: rawBytes,
);

class EditorFake implements EditorBackend {
  EditorDocument document = EditorDocument(
    summary: row(),
    text: 'initial text\n',
  );
  int operations = 0, saves = 0, cancels = 0, binds = 0;
  final updates = <(int, String, String, String)>[];
  final closed = <bool>[];
  final destinations = <(int, int)>[];
  bool rejectUpdate = false, rejectSave = false;
  Completer<void>? pauseUpdate;
  final updateStarted = Completer<void>();
  Completer<EditorDocument>? delayedPrepare;
  Completer<EditorSummary>? delayedBind;
  Completer<void>? delayedSave;
  EditorProgress? transferProgress;
  int progressReads = 0;
  bool rejectAutomaticEncoding = false;
  final inputEncodings = <String?>[];
  @override
  EditorProgress? progress(String token, int operation) {
    progressReads++;
    return transferProgress;
  }

  @override
  int begin(String token) => ++operations;
  @override
  Future<EditorDocument> prepare(
    String token,
    int operation, {
    String? inputEncoding,
  }) {
    inputEncodings.add(inputEncoding);
    if (rejectAutomaticEncoding && inputEncoding == null) {
      return Future.error(StateError('explicit encoding required'));
    }
    return delayedPrepare?.future ?? Future.value(document);
  }

  @override
  Future<EditorSummary> update(
    String token,
    int revision,
    String text,
    String encoding,
    String ending,
  ) async {
    updates.add((revision, text, encoding, ending));
    if (!updateStarted.isCompleted) updateStarted.complete();
    if (rejectUpdate) throw StateError('controlled disk failure');
    final next = row(
      revision: revision + 1,
      saved: document.summary.savedRevision,
      terminal: document.summary.terminalId,
      encoding: encoding,
      ending: ending,
      directory: document.summary.externalDirectory,
    );
    document = EditorDocument(summary: next, text: text);
    final pause = pauseUpdate;
    pauseUpdate = null;
    if (pause != null) await pause.future;
    return next;
  }

  @override
  Future<EditorSummary> save(
    String token,
    int operation,
    int revision,
    int terminal,
    int generation,
  ) async {
    saves++;
    destinations.add((terminal, generation));
    if (rejectSave) throw StateError('controlled remote CLOSE failure');
    final wait = delayedSave;
    if (wait != null) await wait.future;
    final next = row(
      revision: revision,
      saved: revision,
      terminal: terminal,
      encoding: document.summary.encoding,
      ending: document.summary.lineEnding,
      directory: document.summary.externalDirectory,
    );
    document = EditorDocument(summary: next, text: document.text);
    return next;
  }

  @override
  Future<EditorSummary> bind(String token, int terminal, int generation) async {
    binds++;
    return await (delayedBind?.future ??
        Future.value(
          row(
            revision: document.summary.revision,
            saved: document.summary.savedRevision,
            terminal: terminal,
          ),
        ));
  }

  @override
  Future<void> cancel(String token, int operation) async {
    cancels++;
  }

  @override
  Future<void> close(String token, bool keepDraft) async {
    closed.add(keepDraft);
  }
}

TerminalController source() => TerminalController(FakeBackend())
  ..id = 17
  ..generation = 4
  ..phase = 'Connected';
void main() {
  testWidgets(
    'raw mode shows an explicit external file view and cannot persist inline edits',
    (tester) async {
      final fake = EditorFake()
        ..document = EditorDocument(
          summary: row(encoding: 'raw', ending: 'preserve', rawBytes: 18000000),
          text: '',
        );
      final editor = RemoteEditorController(
        'raw-widget',
        backend: fake,
        source: source(),
        initialRawMode: true,
      );
      await tester.pumpWidget(
        MaterialApp(home: RemoteEditorDialog(controller: editor)),
      );
      await tester.pumpAndSettle();
      expect(editor.rawMode, isTrue);
      expect(
        editor.canSave,
        isFalse,
        reason: 'raw Save requires a leased external copy',
      );
      expect(find.byKey(const ValueKey('editor-raw-body')), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-content')), findsNothing);
      expect(find.text('外部大文件编辑 · 18000000 字节'), findsOneWidget);
      editor.content.text = 'must not be treated as a draft';
      editor.setFormat(encoding: 'gbk', lineEnding: 'crlf');
      await tester.pump(const Duration(milliseconds: 600));
      await editor.flush();
      expect(fake.updates, isEmpty);
      expect(editor.encoding, 'raw');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await editor.close(keepDraft: true);
      editor.dispose();
    },
  );
  testWidgets(
    'failed read exposes explicit encoding retry and loads selected text',
    (tester) async {
      final fake = EditorFake()..rejectAutomaticEncoding = true;
      final editor = RemoteEditorController(
        'codec-widget',
        backend: fake,
        source: source(),
      );
      await tester.pumpWidget(
        MaterialApp(home: RemoteEditorDialog(controller: editor)),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-content')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('editor-input-encoding')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GBK').last);
      await tester.pumpAndSettle();
      fake.document = EditorDocument(
        summary: row(encoding: 'gbk'),
        text: '中文',
      );
      await tester.tap(find.byKey(const ValueKey('editor-reload-encoding')));
      await tester.pumpAndSettle();
      expect(fake.inputEncodings, [null, 'gbk']);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('editor-content')))
            .controller!
            .text,
        '中文',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await editor.close(keepDraft: true);
      editor.dispose();
    },
  );
  test('failed automatic decoding can be retried explicitly without replacing a live draft', () async {
    final fake = EditorFake()..rejectAutomaticEncoding = true;
    final editor = RemoteEditorController(
      'codec-retry',
      backend: fake,
      source: source(),
    );
    try {
      await editor.load();
      expect(editor.ready, false);
      expect(editor.error, contains('explicit encoding required'));
      fake.document = EditorDocument(
        summary: row(encoding: 'gbk'),
        text: '中文',
      );
      await editor.load(inputEncoding: 'gbk');
      expect(editor.ready, true);
      expect(editor.error, isNull);
      expect(editor.encoding, 'gbk');
      editor.content.text = 'new unsaved text';
      await editor.load(inputEncoding: 'utf8');
      expect(editor.content.text, 'new unsaved text');
      expect(fake.inputEncodings, [null, 'gbk']);
    } finally {
      await editor.close(keepDraft: true);
      editor.dispose();
    }
  });
  test('cancel during draft persistence prevents a later upload and permits explicit retry', () async {
    final fake = EditorFake()..pauseUpdate = Completer<void>();
    final pause = fake.pauseUpdate!;
    final terminal = source();
    final editor = RemoteEditorController(
      'editor-cancel-before-upload',
      backend: fake,
      source: terminal,
    );
    await editor.load();
    editor.content.text = 'local complete draft 中文';
    final save = editor.save();
    await fake.updateStarted.future;
    await editor.cancelOperation();
    pause.complete();
    await save;
    expect(
      fake.saves,
      0,
      reason: 'cancel before the remote operation must prevent upload',
    );
    expect(editor.persisted, true);
    expect(editor.dirty, true);
    expect(fake.document.text, 'local complete draft 中文');
    await editor.save();
    expect(
      fake.saves,
      1,
      reason: 'a new explicit save clears the cancellation intent',
    );
    await editor.close(keepDraft: false);
    editor.dispose();
    await terminal.shutdown();
    terminal.dispose();
  });
  testWidgets(
    'progress observes active operations only and ignores stale snapshots without idle polling',
    (tester) async {
      final fake = EditorFake()..delayedPrepare = Completer<EditorDocument>();
      final editor = RemoteEditorController('editor-progress', backend: fake);
      final model = LiveWorkbenchModel()..registerEditor(editor);
      var workbenchBuilds = 0;
      await tester.pumpWidget(
        AnimatedBuilder(
          animation: model,
          builder: (context, _) {
            workbenchBuilds++;
            return MaterialApp(
              theme: Desk.theme(false),
              home: RemoteEditorDialog(controller: editor),
            );
          },
        ),
      );
      await tester.pump();
      expect(find.text('正在读取本机加密草稿…'), findsOneWidget);
      fake.transferProgress = const EditorProgress(
        operation: 1,
        phase: 'reading',
        acknowledged: 4,
        total: 10,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('读取正文 · 4 / 10 字节'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .4,
      );
      var notifications = 0;
      editor.addListener(() => notifications++);
      await tester.pump(const Duration(milliseconds: 750));
      expect(notifications, 0);
      expect(workbenchBuilds, 1);
      fake.transferProgress = const EditorProgress(
        operation: 0,
        phase: 'complete',
        acknowledged: 99,
        total: 99,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(editor.progress!.acknowledged, 4);
      fake.delayedPrepare!.complete(fake.document);
      await tester.pumpAndSettle();
      final reads = fake.progressReads;
      await tester.pump(const Duration(seconds: 2));
      expect(fake.progressReads, reads);
      expect(find.byKey(const ValueKey('editor-progress')), findsNothing);
      await model.shutdown();
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
      model.dispose();
    },
  );
  testWidgets(
    'all written bytes still await remote confirmation and CLOSE failure keeps dirty text',
    (tester) async {
      final fake = EditorFake()
        ..delayedSave = Completer<void>()
        ..transferProgress = const EditorProgress(
          operation: 1,
          phase: 'complete',
          acknowledged: 77,
          total: 77,
        );
      final terminal = source();
      final editor = RemoteEditorController(
        'editor-confirm',
        backend: fake,
        source: terminal,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: RemoteEditorDialog(controller: editor),
        ),
      );
      await tester.pumpAndSettle();
      editor.content.text = 'unsaved body';
      expect(editor.progress!.phase, 'complete');
      final save = editor.save();
      expect(editor.progress, isNull);
      await tester.pump();
      fake.transferProgress = const EditorProgress(
        operation: 2,
        phase: 'writing',
        acknowledged: 12,
        total: 12,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('字节已写入，等待服务器确认 · 12 / 12 字节'), findsOneWidget);
      expect(editor.dirty, true);
      fake.transferProgress = const EditorProgress(
        operation: 2,
        phase: 'failed',
        acknowledged: 12,
        total: 12,
      );
      fake.delayedSave!.completeError(
        StateError('controlled remote CLOSE failure'),
      );
      await save;
      await tester.pumpAndSettle();
      expect(editor.dirty, true);
      expect(editor.content.text, 'unsaved body');
      expect(editor.error, contains('CLOSE failure'));
      expect(editor.progress!.phase, 'failed');
      final reads = fake.progressReads;
      await tester.pump(const Duration(seconds: 2));
      expect(fake.progressReads, reads);
      await editor.close(keepDraft: true);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
      await terminal.shutdown();
      terminal.dispose();
    },
  );
  testWidgets(
    'failed document load can close without deleting unexamined drafts',
    (tester) async {
      final fake = EditorFake()..delayedPrepare = Completer<EditorDocument>();
      final editor = RemoteEditorController(
        'editor-failed-load',
        backend: fake,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRemoteEditorDialog(
                context,
                editor,
              ).then((_) => editor.dispose()),
              child: const Text('edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('edit'));
      await tester.pump();
      fake.delayedPrepare!.completeError(
        StateError('controlled future draft format'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('读取编辑文件失败'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-close')));
      await tester.pumpAndSettle();
      expect(fake.closed, [true]);
      expect(find.byType(RemoteEditorDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('late binding cannot resurrect a closed editor or attach terminal listeners', () async {
    final fake = EditorFake()..delayedBind = Completer<EditorSummary>();
    final terminal = source();
    final editor = RemoteEditorController('editor-late-bind', backend: fake);
    await editor.load();
    final binding = editor.bind(terminal);
    await editor.close(keepDraft: true);
    fake.delayedBind!.complete(row());
    await binding;
    expect(editor.source, isNull);
    await editor.bind(terminal);
    expect(fake.binds, 1);
    editor.dispose();
    await terminal.shutdown();
    terminal.dispose();
  });
  testWidgets(
    'editor retains text at small window sizes and larger text scales',
    (tester) async {
      final fake = EditorFake();
      final editor = RemoteEditorController('editor-layout', backend: fake);
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false).copyWith(platform: TargetPlatform.windows),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: RemoteEditorDialog(controller: editor),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-content')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('editor-text-region')),
          matching: find.byType(Scrollbar),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await editor.close(keepDraft: true);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );
  test(
    'one in-flight writer coalesces to latest text without remote saves',
    () async {
      final fake = EditorFake()..pauseUpdate = Completer<void>();
      final pause = fake.pauseUpdate!;
      final editor = RemoteEditorController('editor-fixture', backend: fake);
      await editor.load();
      editor.content.text = 'first';
      final flush = editor.flush();
      await fake.updateStarted.future;
      editor.content.text = 'intermediate';
      editor.content.text = 'latest 中文';
      expect(identical(editor.flush(), flush), true);
      expect(fake.updates.map((u) => u.$2), ['first']);
      pause.complete();
      await flush;
      expect(fake.updates.map((u) => u.$2), ['first', 'latest 中文']);
      expect(fake.updates.map((u) => u.$1), [1, 2]);
      expect(fake.saves, 0);
      expect(editor.persisted, true);
      expect(editor.dirty, true);
      await editor.close(keepDraft: true);
      editor.dispose();
    },
  );
  test(
    'IME composing is not recorded; only explicit save sends final text',
    () async {
      final fake = EditorFake();
      final terminal = source();
      final editor = RemoteEditorController(
        'editor-fixture',
        backend: fake,
        source: terminal,
      );
      await editor.load();
      editor.content.value = const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      await editor.flush();
      await editor.save();
      expect(fake.updates, isEmpty);
      expect(fake.saves, 0);
      expect(editor.error, contains('输入法候选'));
      editor.content.value = const TextEditingValue(
        text: '中文',
        selection: TextSelection.collapsed(offset: 2),
      );
      await editor.flush();
      expect(fake.updates.single.$2, '中文');
      expect(fake.saves, 0);
      await editor.save();
      expect(fake.saves, 1);
      expect(fake.destinations, [(17, 4)]);
      expect(editor.dirty, false);
      expect((terminal.backend as FakeBackend).texts, isEmpty);
      await editor.close(keepDraft: false);
      editor.dispose();
      await terminal.shutdown();
      terminal.dispose();
    },
  );
  test(
    'failed persistence and save retain text and remain retryable',
    () async {
      final fake = EditorFake()..rejectUpdate = true;
      final terminal = source();
      final editor = RemoteEditorController(
        'editor-fixture',
        backend: fake,
        source: terminal,
      );
      await editor.load();
      editor.content.text = 'unsaved exact body 中文\n';
      await expectLater(editor.flush(), throwsA(anything));
      expect(editor.content.text, 'unsaved exact body 中文\n');
      expect(editor.error, contains('本机加密草稿未保存'));
      expect(editor.persisted, false);
      fake.rejectUpdate = false;
      await editor.flush();
      fake.rejectSave = true;
      await editor.save();
      expect(editor.dirty, true);
      expect(editor.error, contains('远端保存未确认'));
      expect(editor.content.text, 'unsaved exact body 中文\n');
      fake.rejectSave = false;
      await editor.save();
      expect(editor.dirty, false);
      expect(editor.error, isNull);
      await editor.close(keepDraft: false);
      editor.dispose();
      await terminal.shutdown();
      terminal.dispose();
    },
  );
  test('close joins a delayed load without showing a late body', () async {
    final fake = EditorFake()..delayedPrepare = Completer<EditorDocument>();
    final editor = RemoteEditorController('editor-fixture', backend: fake);
    final load = editor.load();
    final close = editor.close(keepDraft: true);
    await Future<void>.delayed(Duration.zero);
    expect(editor.closed, false);
    expect(fake.cancels, 1);
    fake.delayedPrepare!.complete(fake.document);
    await load;
    await close;
    expect(editor.ready, false);
    expect(editor.content.text, '');
    expect(fake.closed, [true]);
    editor.dispose();
  });
  test(
    'terminal frame notifications do not rebuild editor or reconnect',
    () async {
      final fake = EditorFake();
      final terminal = source();
      final editor = RemoteEditorController(
        'editor-fixture',
        backend: fake,
        source: terminal,
      );
      await editor.load();
      var notifications = 0;
      editor.addListener(() => notifications++);
      for (var i = 0; i < 100; i++) {
        terminal.notifyListeners();
      }
      expect(notifications, 0);
      terminal.phase = 'Disconnected';
      terminal.notifyListeners();
      expect(notifications, 1);
      await editor.save();
      expect(fake.saves, 0);
      expect(terminal.phase, 'Disconnected');
      await editor.close(keepDraft: true);
      editor.dispose();
      await terminal.shutdown();
      terminal.dispose();
    },
  );
  test('shutdown waits for local draft persistence and retries after failure without Rust', () async {
    final fake = EditorFake()..rejectUpdate = true;
    final editor = RemoteEditorController('editor-fixture', backend: fake);
    final model = LiveWorkbenchModel();
    model.registerEditor(editor);
    await editor.load();
    editor.content.text = 'keep on shutdown';
    await expectLater(model.shutdown(), throwsA(anything));
    expect(model.hasActiveEditors, true);
    expect(editor.closed, false);
    expect(fake.closed, isEmpty);
    fake.rejectUpdate = false;
    await model.shutdown();
    expect(fake.document.text, 'keep on shutdown');
    expect(fake.closed, [true]);
    expect(model.hasActiveEditors, false);
    editor.dispose();
    model.dispose();
  });
  testWidgets(
    'real dialog edits text locally, Ctrl+S saves and clean close releases token',
    (tester) async {
      final fake = EditorFake();
      final terminal = source();
      final editor = RemoteEditorController(
        'editor-fixture',
        backend: fake,
        source: terminal,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRemoteEditorDialog(
                context,
                editor,
              ).then((_) => editor.dispose()),
              child: const Text('edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('editor-content')),
        'user edited 中文\nsecond line',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(fake.saves, 0);
      expect(fake.document.text, 'user edited 中文\nsecond line');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(fake.saves, 1);
      expect(editor.dirty, false);
      await tester.tap(find.byKey(const ValueKey('editor-close')));
      await tester.pumpAndSettle();
      expect(find.byType(RemoteEditorDialog), findsNothing);
      expect(fake.closed, [false]);
      expect((terminal.backend as FakeBackend).texts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
      await terminal.shutdown();
      terminal.dispose();
    },
  );
  testWidgets(
    'dirty close can cancel or keep encrypted draft without uploading',
    (tester) async {
      final fake = EditorFake();
      final editor = RemoteEditorController('editor-fixture', backend: fake);
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => RemoteEditorDialog(controller: editor),
              ),
              child: const Text('edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('editor-content')),
        'keep draft 中文',
      );
      await tester.tap(find.byKey(const ValueKey('editor-close')));
      await tester.pumpAndSettle();
      expect(find.text('尚有未保存到远端的修改'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(editor.closed, false);
      await tester.tap(find.byKey(const ValueKey('editor-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留草稿并关闭'));
      await tester.pumpAndSettle();
      expect(fake.closed, [true]);
      expect(fake.document.text, 'keep draft 中文');
      expect(fake.saves, 0);
      expect(find.byType(RemoteEditorDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
    },
  );
}
