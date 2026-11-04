import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/editors.dart';
import 'package:hspterm/workbench/editor_controller.dart';
import 'package:hspterm/workbench/external_editor.dart';

import 'editor_controller_test.dart' as fixture;

class ExternalFake implements ExternalEditorBackend {
  ExternalFake(this.editor);
  final fixture.EditorFake editor;
  String latest = 'initial text\n';
  bool existing = false, reject = false;
  int reads = 0, releases = 0;
  Completer<void>? delayedRead;
  final readStarted = Completer<void>();
  @override
  Future<ExternalEditorFile> open(String token, String base) async {
    final old = editor.document;
    editor.document = EditorDocument(
      summary: fixture.row(
        revision: old.summary.revision,
        saved: old.summary.savedRevision,
        directory: '/fixture-work',
      ),
      text: old.text,
    );
    return ExternalEditorFile(
      path: '/fixture-work/document.txt',
      existing: existing,
      summary: editor.document.summary,
    );
  }

  @override
  Future<EditorDocument?> capture(String token, int revision) async {
    reads++;
    final delayed = delayedRead;
    delayedRead = null;
    if (!readStarted.isCompleted) readStarted.complete();
    if (delayed != null) await delayed.future;
    if (reject) throw StateError('controlled local read failure');
    final old = editor.document;
    if (old.summary.revision != revision) {
      throw StateError('stale local revision');
    }
    if (latest == old.text) return null;
    final document = EditorDocument(
      summary: fixture.row(
        revision: revision + 1,
        saved: old.summary.savedRevision,
        directory: '/fixture-work',
      ),
      text: latest,
    );
    editor.document = document;
    return document;
  }

  @override
  Future<void> release(String token) async {
    releases++;
  }

  @override
  Future<EditorDocument> cleanup(String token) async {
    await capture(token, editor.document.summary.revision);
    final old = editor.document;
    final result = EditorDocument(
      summary: fixture.row(
        revision: old.summary.revision,
        saved: old.summary.savedRevision,
      ),
      text: old.text,
    );
    editor.document = result;
    return result;
  }
}

class PlatformFake implements ExternalEditorPlatform {
  final events = StreamController<void>.broadcast(sync: true);
  final launches = <(String, String)>[];
  Completer<void>? launchPending;
  @override
  Stream<void> watch(String path) => events.stream;
  @override
  Future<void> launch(
    String executable,
    String path,
    void Function(String) warning,
  ) async {
    launches.add((executable, path));
    final pending = launchPending;
    if (pending != null) await pending.future;
  }
}

Future<void> until(bool Function() condition, String reason) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('Windows watcher matches drive and UNC canonical spellings without folding Unix paths', () {
    expect(
      externalEditorComparablePath(
        r'\\?\C:\Users\Name\document.txt',
        windows: true,
      ),
      externalEditorComparablePath('c:/users/name/document.txt', windows: true),
    );
    expect(
      externalEditorComparablePath(
        r'\\?\UNC\Server\Share\document.txt',
        windows: true,
      ),
      externalEditorComparablePath(
        r'\\server\share\DOCUMENT.TXT',
        windows: true,
      ),
    );
    expect(
      externalEditorComparablePath('/tmp/Case.txt', windows: false),
      '/tmp/Case.txt',
    );
    expect(
      externalEditorComparablePath('/tmp/case.txt', windows: false),
      isNot('/tmp/Case.txt'),
    );
  });
  test('directory events coalesce, persist locally once and upload only the captured version', () async {
    final editor = fixture.EditorFake();
    final external = ExternalFake(editor);
    final platform = PlatformFake();
    final source = fixture.source();
    final controller = RemoteEditorController(
      'external-fixture',
      backend: editor,
      externalBackend: external,
      externalPlatform: platform,
      source: source,
    );
    try {
      await controller.load();
      await controller.startExternal(
        '/chosen/editor',
        '/fixture',
        (_) async => true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(editor.saves, 0);
      external.latest = 'external 中文 é\n';
      for (var i = 0; i < 30; i++) {
        platform.events.add(null);
      }
      await until(
        () => editor.saves == 1 && !controller.saving,
        'coalesced external save',
      );
      expect(editor.document.text, external.latest);
      expect(controller.content.text, external.latest);
      expect(
        editor.updates,
        isEmpty,
        reason: 'native capture has already persisted the body',
      );
      expect(editor.destinations, [(17, 4)]);
      final idle = external.reads;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(external.reads, idle, reason: 'there is no idle file polling');
      expect(platform.launches, [
        ('/chosen/editor', '/fixture-work/document.txt'),
      ]);
      await controller.close(keepDraft: false);
      expect(editor.closed, [
        true,
      ], reason: 'an external editor can still modify the retained file');
    } finally {
      await controller.close(keepDraft: true);
      controller.dispose();
      await source.shutdown();
      source.dispose();
      await platform.events.close();
    }
  });
  test('offline recovery does not upload imported data until a real save event or explicit resume', () async {
    final editor = fixture.EditorFake();
    final external = ExternalFake(editor)
      ..existing = true
      ..latest = 'newer work file 中文';
    final platform = PlatformFake();
    final source = fixture.source();
    final controller = RemoteEditorController(
      'external-recovery',
      backend: editor,
      externalBackend: external,
      externalPlatform: platform,
      source: source,
    );
    var confirmations = 0;
    try {
      await controller.load();
      await controller.startExternal('/chosen/editor', '/fixture', (_) async {
        confirmations++;
        return true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(confirmations, 1);
      expect(controller.dirty, true);
      expect(editor.saves, 0);
      platform.events.add(
        null,
      ); // Saving identical bytes still submits a pending recovered draft.
      await until(
        () => editor.saves == 1 && !controller.saving,
        'recovered file explicit external save',
      );
      source.phase = 'Disconnected';
      source.notifyListeners();
      external.latest = 'edited while offline';
      platform.events.add(null);
      await until(
        () => controller.content.text == external.latest,
        'offline local capture',
      );
      expect(editor.saves, 1);
      expect(controller.external!.paused, true);
      source.phase = 'Connected';
      source.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(
        editor.saves,
        1,
        reason: 'reconnect alone does not resume external uploads',
      );
      controller.resumeExternalUploads();
      await until(
        () => editor.saves == 2 && !controller.saving,
        'explicit external upload resume',
      );
      expect(editor.document.text, 'edited while offline');
    } finally {
      await controller.close(keepDraft: true);
      controller.dispose();
      await source.shutdown();
      source.dispose();
      await platform.events.close();
    }
  });
  test(
    'failed uploads pause network work but keep capturing later external edits',
    () async {
      final editor = fixture.EditorFake()..rejectSave = true;
      final external = ExternalFake(editor);
      final platform = PlatformFake();
      final source = fixture.source();
      final controller = RemoteEditorController(
        'external-error',
        backend: editor,
        externalBackend: external,
        externalPlatform: platform,
        source: source,
      );
      try {
        await controller.load();
        await controller.startExternal(
          '/chosen/editor',
          '/fixture',
          (_) async => true,
        );
        external.latest = 'first external change';
        platform.events.add(null);
        await until(
          () => controller.external!.paused && editor.saves == 1,
          'failed external upload pause',
        );
        external.latest = 'second complete local change';
        platform.events.add(null);
        await until(
          () => controller.content.text == external.latest,
          'capture after upload failure',
        );
        expect(editor.saves, 1);
        editor.rejectSave = false;
        controller.resumeExternalUploads();
        await until(
          () => editor.saves == 2 && !controller.saving,
          'manual retry of latest external draft',
        );
        await controller.cleanupExternal();
        expect(controller.hasExternalCopy, false);
        expect(controller.externalActive, false);
        expect(controller.content.text, 'second complete local change');
      } finally {
        await controller.close(keepDraft: true);
        controller.dispose();
        await source.shutdown();
        source.dispose();
        await platform.events.close();
      }
    },
  );
  test('cancelling an external upload pauses later network work without losing local saves', () async {
    final editor = fixture.EditorFake();
    final external = ExternalFake(editor);
    final platform = PlatformFake();
    final controller = RemoteEditorController(
      'external-cancel',
      backend: editor,
      externalBackend: external,
      externalPlatform: platform,
      source: fixture.source(),
    );
    final pending = Completer<void>();
    try {
      await controller.load();
      await controller.startExternal(
        '/chosen/editor',
        '/fixture',
        (_) async => true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 450));
      editor.delayedSave = pending;
      external.latest = 'first external save';
      platform.events.add(null);
      await until(
        () => editor.saves == 1 && controller.saving,
        'upload started',
      );
      await controller.cancelOperation();
      expect(controller.external!.paused, true);
      expect(editor.cancels, 1);
      pending.complete();
      editor.delayedSave = null;
      await until(() => !controller.saving, 'cancelled upload drained');
      external.latest = 'newer local content after cancellation';
      platform.events.add(null);
      await until(
        () => controller.content.text == external.latest,
        'paused capture',
      );
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(editor.saves, 1);
      expect(controller.dirty, true);
      controller.resumeExternalUploads();
      await until(
        () => editor.saves == 2 && !controller.saving,
        'explicit resume',
      );
      expect(editor.destinations, [(17, 4), (17, 4)]);
      expect(controller.dirty, false);
    } finally {
      if (!pending.isCompleted) pending.complete();
      await controller.close(keepDraft: true);
      controller.dispose();
      await platform.events.close();
    }
  });
  test(
    'closing does not wait indefinitely for existing-file confirmation',
    () async {
      final editor = fixture.EditorFake();
      final external = ExternalFake(editor)..existing = true;
      final platform = PlatformFake();
      final controller = RemoteEditorController(
        'external-confirm-close',
        backend: editor,
        externalBackend: external,
        externalPlatform: platform,
      );
      final answer = Completer<bool>(), asked = Completer<void>();
      await controller.load();
      final opening = controller.startExternal('/chosen/editor', '/fixture', (
        _,
      ) {
        asked.complete();
        return answer.future;
      });
      await asked.future;
      final closing = controller.close(keepDraft: true);
      try {
        await closing.timeout(const Duration(seconds: 1));
        expect(controller.closed, true);
        expect(platform.launches, isEmpty);
        expect(editor.saves, 0);
        expect(editor.closed, [true]);
        answer.complete(
          true,
        ); // A late dialog answer must not restart anything.
        await opening;
        expect(platform.launches, isEmpty);
      } finally {
        if (!answer.isCompleted) answer.complete(false);
        await opening;
        await closing;
        controller.dispose();
        await platform.events.close();
      }
    },
  );
  test('closing during launch prevents a late child or upload and releases the lease', () async {
    final editor = fixture.EditorFake();
    final external = ExternalFake(editor)..delayedRead = Completer<void>();
    final pending = external.delayedRead!;
    final platform = PlatformFake();
    final controller = RemoteEditorController(
      'external-close',
      backend: editor,
      externalBackend: external,
      externalPlatform: platform,
    );
    await controller.load();
    final opening = controller.startExternal(
      '/chosen/editor',
      '/fixture',
      (_) async => true,
    );
    await external.readStarted.future;
    final closing = controller.close(keepDraft: true);
    pending.complete();
    await opening;
    await closing;
    expect(platform.launches, isEmpty);
    expect(editor.saves, 0);
    expect(external.releases, 1);
    expect(controller.closed, true);
    controller.dispose();
    await platform.events.close();
  });
}
