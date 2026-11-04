import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/editors.dart';

abstract interface class ExternalEditorBackend {
  Future<ExternalEditorFile> open(String token, String base);
  Future<EditorDocument?> capture(String token, int revision);
  Future<void> release(String token);
  Future<EditorDocument> cleanup(String token);
}

class NativeExternalEditorBackend implements ExternalEditorBackend {
  const NativeExternalEditorBackend();
  @override
  Future<ExternalEditorFile> open(String token, String base) =>
      rust.openExternalEditor(editorId: token, baseDirectory: base);
  @override
  Future<EditorDocument?> capture(String token, int revision) =>
      rust.captureExternalEditor(editorId: token, expectedRevision: revision);
  @override
  Future<void> release(String token) =>
      rust.releaseExternalEditor(editorId: token);
  @override
  Future<EditorDocument> cleanup(String token) =>
      rust.cleanupExternalEditor(editorId: token, editorClosed: true);
}

abstract interface class ExternalEditorPlatform {
  Stream<void> watch(String path);
  Future<void> launch(
    String executable,
    String path,
    void Function(String) warning,
  );
}

// Rust canonical paths can use the Windows extended-length prefix whereas
// directory notifications can return the ordinary drive/UNC spelling.
@visibleForTesting
String externalEditorComparablePath(String path, {required bool windows}) {
  if (!windows) return path;
  var value = path.replaceAll('/', r'\').toLowerCase();
  if (value.startsWith(r'\\?\unc\')) {
    value = r'\\' + value.substring(8);
  } else if (value.startsWith(r'\\?\')) {
    value = value.substring(4);
  }
  return value;
}

class LocalExternalEditorPlatform implements ExternalEditorPlatform {
  const LocalExternalEditorPlatform();
  @override
  Stream<void> watch(String path) {
    String comparable(String value) =>
        externalEditorComparablePath(value, windows: Platform.isWindows);
    final target = comparable(File(path).absolute.path);
    return File(path).parent
        .watch()
        .where(
          (event) =>
              comparable(File(event.path).absolute.path) == target ||
              (event is FileSystemMoveEvent &&
                  event.destination != null &&
                  comparable(File(event.destination!).absolute.path) == target),
        )
        .map((_) {});
  }

  @override
  Future<void> launch(
    String executable,
    String path,
    void Function(String) warning,
  ) async {
    if (!File(executable).isAbsolute || !await File(executable).exists()) {
      throw StateError('请选择本机编辑器可执行文件');
    }
    final process = await Process.start(
      executable,
      [path],
      workingDirectory: File(path).parent.path,
      runInShell: false,
    );
    // Editor stdout/stderr can contain file contents. Consume without logging.
    unawaited(
      process.stdout.drain<void>().catchError(
        (Object _) => warning('外部编辑器输出流已关闭；工作文件仍保留'),
      ),
    );
    unawaited(
      process.stderr.drain<void>().catchError(
        (Object _) => warning('外部编辑器错误流已关闭；工作文件仍保留'),
      ),
    );
    unawaited(
      process.stdin.close().catchError(
        (Object _) => warning('外部编辑器输入流关闭失败；工作文件仍保留'),
      ),
    );
    unawaited(
      process.exitCode
          .then((code) {
            // Many GUI launchers fork and immediately exit. Exit never implies the
            // editor is inactive and never authorizes deleting its working file.
            if (code != 0) warning('外部编辑器退出码 $code；工作文件和草稿仍保留');
          })
          .catchError((Object _) => warning('无法确认外部编辑器退出状态；工作文件与草稿仍保留')),
    );
  }
}

/// Directory events are hints; Rust reads/validates/persists actual bytes.
/// One coalescing worker owns capture/upload. No periodic filesystem polling.
class ExternalEditorLink extends ChangeNotifier {
  ExternalEditorLink({
    required this.token,
    required this.revision,
    required this.onDocument,
    required this.onSummary,
    required this.upload,
    required this.canUpload,
    required this.alive,
    this.backend = const NativeExternalEditorBackend(),
    this.platform = const LocalExternalEditorPlatform(),
    this.quiet = const Duration(milliseconds: 350),
  });
  final String token;
  final int Function() revision;
  final void Function(EditorDocument) onDocument;
  final void Function(EditorSummary) onSummary;
  final Future<bool> Function() upload;
  final bool Function() canUpload, alive;
  final ExternalEditorBackend backend;
  final ExternalEditorPlatform platform;
  final Duration quiet;
  String? path, error;
  bool paused = true, busy = false;
  bool _stopping = false, _disposed = false;
  StreamSubscription<void>? _events;
  Timer? _timer;
  final _clock = Stopwatch()..start();
  int _signals = 0, _processed = 0, _lastEvent = 0;
  bool _uploadRequested = false;
  Future<void>? _pumpWork, _startWork, _cleanupWork;
  Future<bool>? _captureWork;
  Completer<void> _closeRequested = Completer<void>();
  bool get active => path != null;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void warn(String value) {
    if (!_disposed) {
      error = value;
      _emit();
    }
  }

  void pause() {
    if (!paused) {
      paused = true;
      _emit();
    }
  }

  /// Shutdown cannot wait for an unanswered modal confirmation behind it.
  void requestClose() {
    if (!_closeRequested.isCompleted) _closeRequested.complete();
    _stopping = true;
    _timer?.cancel();
    pause();
  }

  void resume() {
    if (!active || _stopping || !alive()) return;
    if (_events == null) {
      warn('文件监听已停止，请重新打开外部编辑器；可手动保存当前工作文件');
      return;
    }
    paused = false;
    signal(); // An explicit resume may upload a previously retained dirty file.
    _emit();
  }

  void signal({bool upload = true}) {
    if (_stopping || _disposed || !active || !alive()) return;
    _signals++;
    _uploadRequested |= upload;
    _lastEvent = _clock.elapsedMicroseconds;
    _timer?.cancel();
    _timer = Timer(quiet, () {
      unawaited(_pump());
    });
  }

  Future<void> start(
    String executable,
    String base,
    Future<bool> Function(String) confirmExisting,
  ) {
    return _startWork ??= _start(
      executable,
      base,
      confirmExisting,
    ).whenComplete(() => _startWork = null);
  }

  Future<void> _start(
    String executable,
    String base,
    Future<bool> Function(String) confirmExisting,
  ) async {
    _closeRequested = Completer<void>();
    busy = true;
    error = null;
    _emit();
    try {
      final wasActive = active;
      final file = await backend.open(token, base);
      onSummary(file.summary);
      if (!alive()) return;
      if (!wasActive && file.existing) {
        final accepted = await Future.any<bool>([
          confirmExisting(file.path),
          _closeRequested.future.then((_) => false),
        ]);
        if (!accepted || !alive()) {
          await backend.release(token);
          return;
        }
      }
      path = file.path;
      await capture(); // Recover to the encrypted draft; do not upload here.
      if (!alive()) return;
      _stopping = false;
      _events ??= platform
          .watch(path!)
          .listen(
            (_) => signal(),
            onError: (Object _) {
              paused = true;
              warn('外部文件监听出错；自动回传已暂停，工作文件保留，可手动保存');
            },
            onDone: () {
              if (!_stopping) {
                _events = null;
                paused = true;
                warn('外部文件监听已结束；工作文件保留，可手动保存');
              }
            },
          );
      paused = !canUpload();
      await platform.launch(executable, path!, warn);
      signal(
        upload: false,
      ); // Catch an immediate save before the OS watch was ready.
    } catch (e) {
      paused = true;
      warn('外部编辑未正常启动，工作文件与草稿保留：$e');
      rethrow;
    } finally {
      busy = false;
      _emit();
    }
  }

  Future<bool> capture() =>
      _captureWork ??= _capture().whenComplete(() => _captureWork = null);
  Future<bool> _capture() async {
    if (!active || _disposed) return false;
    final document = await backend.capture(token, revision());
    if (document != null) onDocument(document);
    error = null;
    _emit();
    return document != null;
  }

  Future<void> _pump() =>
      _pumpWork ??= _drain().whenComplete(() => _pumpWork = null);
  Future<void> _drain() async {
    while (!_stopping && alive() && _processed < _signals) {
      if (busy) {
        await Future<void>.delayed(quiet);
        continue;
      }
      final remaining =
          quiet.inMicroseconds - (_clock.elapsedMicroseconds - _lastEvent);
      if (remaining > 0) {
        await Future<void>.delayed(Duration(microseconds: remaining));
        continue;
      }
      final signal = _signals;
      final send = _uploadRequested;
      _uploadRequested = false;
      try {
        final changed = await capture();
        _processed = signal;
        if (!_stopping &&
            alive() &&
            !paused &&
            canUpload() &&
            (changed || send)) {
          if (!await upload()) {
            paused = true;
            _emit();
          }
        }
      } catch (e) {
        _processed = signal;
        warn('读取外部修改失败，未上传；工作文件与原草稿保留：$e');
      }
    }
  }

  void resumeAndUpload() {
    resume();
  }

  Future<void> _quiesce() async {
    paused = true;
    _stopping = true;
    _timer?.cancel();
    final events = _events;
    _events = null;
    if (events != null) await events.cancel();
    final pump = _pumpWork;
    if (pump != null) await pump;
    final capturing = _captureWork;
    if (capturing != null) {
      try {
        await capturing;
      } catch (e) {
        warn('外部修改尚未进入加密草稿，工作文件仍保留：$e');
      }
    }
  }

  Future<void> cleanup() =>
      _cleanupWork ??= _cleanup().whenComplete(() => _cleanupWork = null);
  Future<void> _cleanup() async {
    if (busy) throw StateError('外部编辑操作尚未结束');
    busy = true;
    _emit();
    try {
      await _quiesce();
      final document = await backend.cleanup(token);
      onDocument(document);
      path = null;
      error = null;
    } catch (e) {
      warn('工作文件清理失败，草稿仍保留：$e');
      rethrow;
    } finally {
      busy = false;
      _emit();
    }
  }

  /// Keep raw files and their encrypted pin even when the last capture fails.
  /// A detached GUI editor can still write after this application has exited.
  Future<void> close() async {
    requestClose();
    final starting = _startWork;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        /* error is published */
      }
    }
    final cleaning = _cleanupWork;
    if (cleaning != null) {
      try {
        await cleaning;
      } catch (_) {
        /* pinned file is retained */
      }
    }
    await _quiesce();
    if (active) {
      try {
        await capture();
      } catch (e) {
        warn('最新外部内容尚未进入加密草稿，工作文件原样保留供下次恢复：$e');
      }
    }
    await backend.release(token);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    // The owner normally awaits close. A forced widget teardown must still
    // detach the OS event stream; it never authorizes work-file deletion.
    final events = _events;
    _events = null;
    if (events != null) unawaited(events.cancel());
    _clock.stop();
    super.dispose();
  }
}
