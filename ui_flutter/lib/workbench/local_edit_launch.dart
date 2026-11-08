//! Double-click "open in local editor with write-back" sessions.
//!
//! Downloads the remote file to a temp copy (sanitized name, extension kept),
//! launches it with the OS file association (url_launcher file URI; the OS
//! result is checked), and watches the copy for stable modifications. Each
//! stable save uploads once via a remote temp file + rename so a failed
//! upload never destroys the original; a remote file that changed (size or
//! mtime) since the download snapshot raises an explicit conflict. Sessions
//! are registered on the workbench model so closing the app disposes the
//! watchers and temp files.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_notice.dart';
import '../prototype/model.dart';
import '../run_log.dart';
import '../src/rust/api.dart' as rust;
import 'model.dart';

const _maxEditBytes = 16 * 1024 * 1024;
const _stableWindow = Duration(milliseconds: 700);
const _pollInterval = Duration(milliseconds: 800);
const _maxSessionsPerModel = 16;

/// Abstraction over the native calls so tests can simulate every flow.
abstract interface class LocalEditGateway {
  Future<List<int>> download(
    int native,
    int generation,
    String path, {
    void Function(int done, int? total)? onProgress,
  });
  Future<({int size, int? mtime})> stat(
    int native,
    int generation,
    String path,
  );
  Future<void> upload(
    int native,
    int generation,
    String path,
    List<int> bytes, {
    void Function(int done, int total)? onProgress,
  });

  /// [force] replaces an existing destination (edit-save semantics). The
  /// first, non-forced attempt intentionally surfaces a conflict error so
  /// the caller can ask for the user's consent before replacing.
  Future<void> renameOver(
    int native,
    int generation,
    String from,
    String to, {
    bool force = false,
  });
  Future<void> removeFile(int native, int generation, String path);
}

class NativeLocalEditGateway implements LocalEditGateway {
  const NativeLocalEditGateway();
  @override
  Future<List<int>> download(
    int native,
    int generation,
    String path, {
    void Function(int done, int? total)? onProgress,
  }) async {
    final out = <int>[];
    final meta = await rust.sftpProperties(
      id: native,
      generation: generation,
      path: path,
      includeDirectorySize: false,
    );
    final total = meta.size;
    onProgress?.call(0, total);
    for (var offset = 0; offset < total;) {
      final chunk = await rust.sftpReadChunk(
        id: native,
        path: path,
        offset: offset,
        length: (total - offset).clamp(0, 1024 * 1024),
      );
      if (chunk.isEmpty) break;
      out.addAll(chunk);
      offset += chunk.length;
      onProgress?.call(offset, total);
    }
    return out;
  }

  @override
  Future<({int size, int? mtime})> stat(
    int native,
    int generation,
    String path,
  ) async {
    final meta = await rust.sftpProperties(
      id: native,
      generation: generation,
      path: path,
      includeDirectorySize: false,
    );
    return (size: meta.size, mtime: meta.mtime);
  }

  @override
  Future<void> upload(
    int native,
    int generation,
    String path,
    List<int> bytes, {
    void Function(int done, int total)? onProgress,
  }) async {
    const chunk = 1024 * 1024;
    onProgress?.call(0, bytes.length);
    if (bytes.isEmpty) {
      // An empty save must still create (and truncate) the remote temp
      // file; the chunk loop below would never run.
      await rust.sftpWriteChunk(
        id: native,
        path: path,
        offset: 0,
        data: const [],
        truncate: true,
      );
      onProgress?.call(0, 0);
      return;
    }
    for (var offset = 0; offset < bytes.length; offset += chunk) {
      final slice = bytes.sublist(
        offset,
        (offset + chunk).clamp(0, bytes.length),
      );
      await rust.sftpWriteChunk(
        id: native,
        path: path,
        offset: offset,
        data: slice,
        truncate: offset == 0,
      );
      onProgress?.call(
        (offset + slice.length).clamp(0, bytes.length),
        bytes.length,
      );
    }
  }

  @override
  Future<void> renameOver(
    int native,
    int generation,
    String from,
    String to, {
    bool force = false,
  }) {
    return rust.sftpRename(
      id: native,
      source: from,
      destination: to,
      expectedGeneration: generation,
      overwrite: force ? true : null,
    );
  }

  @override
  Future<void> removeFile(int native, int generation, String path) {
    return rust.sftpRemove(
      id: native,
      path: path,
      recursive: false,
      expectedGeneration: generation,
    );
  }
}

/// Sanitizes a remote basename for the local temp filesystem: keeps the
/// extension, drops separators/reserved characters, and never yields '..'.
String sanitizeLocalName(String name) {
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot + 1) : '';
  String clean(String part) => part
      .replaceAll(RegExp(r'[/\\]'), '_')
      .replaceAll(RegExp(r'[^0-9A-Za-z._\-\u4e00-\u9fff]'), '')
      .replaceAll('..', '_');
  final safeStem = clean(stem).replaceAll('.', '_');
  final safeExt = clean(ext);
  if (safeStem.isEmpty) return 'edit.bin';
  return safeExt.isEmpty ? safeStem : '$safeStem.$safeExt';
}

/// Lifecycle of a local-edit queue task (round-9).
enum LocalEditStatus {
  downloading,
  editing,
  uploading,
  conflicted,
  failed,
  closed,
}

class LocalEditSession extends ChangeNotifier {
  // ignore: use_super_parameters
  LocalEditSession._(
    this._session,
    this._remotePath,
    this._file,
    this._native,
    this._originGeneration,
    this._originSize,
    this._originMtime,
    this._gateway,
    this._onNotice,
    this._ownRoot,
    this._onConflict,
  );

  final LiveTerminalSession _session;
  final String _remotePath;
  final File _file;

  /// Queue-task surface (round-9): lifecycle state and byte progress for
  /// the download/upload phases. Purely derived UI metadata.
  LocalEditStatus status = LocalEditStatus.downloading;
  int progressDone = 0, progressTotal = 0;
  String get displayName => _remotePath.split('/').last;
  String get hostLabel => _session.host.name;
  String get remotePath => _remotePath;
  File get localFile => _file;
  LiveTerminalSession get session => _session;

  void _setStatus(LocalEditStatus next) {
    if (status == next) return;
    status = next;
    notifyListeners();
  }

  void _setProgress(int done, int total) {
    progressDone = done;
    progressTotal = total;
    notifyListeners();
  }

  final int _native;
  final int _originGeneration;
  int _originSize;
  int? _originMtime;
  final LocalEditGateway _gateway;
  final void Function(String message) _onNotice;

  /// True when this task created its temp root directory itself (tests
  /// share an explicit root); only then does dispose retire the root.
  final bool _ownRoot;

  /// Asks the user whether the remote file may be replaced when the server
  /// blocks the atomic rename (round-10): the save itself never destroys
  /// anything without either POSIX-rename support or explicit consent.
  final Future<bool> Function(String remotePath)? _onConflict;

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _stability;
  Timer? _poll;
  DateTime _lastModified = DateTime.fromMillisecondsSinceEpoch(0);
  List<int>? _lastUploadedBytes;
  bool _uploading = false, _conflicted = false, _disposed = false;

  Directory get _home => _file.parent;
  bool get conflicted => _conflicted;
  bool get isDisposed => _disposed;

  /// Opens [file] from [source] in the system editor with write-back; the
  /// constructed session is handed to [onSession] for registry ownership.
  static Future<void> launch(
    LiveTerminalSession source,
    DemoFile file, {
    LocalEditGateway gateway = const NativeLocalEditGateway(),
    void Function(String message)? onNotice,
    Directory? rootOverride,
    Future<bool> Function(Uri uri)? launchOverride,
    void Function(LocalEditSession session)? onSession,
    Future<bool> Function(String remotePath)? onConflict,
  }) async {
    final native = source.controller.id;
    final generation = source.controller.generation;
    final notice = onNotice ?? (_) {};
    if (native == null || !source.controller.connected) {
      throw StateError('关联 SSH 会话未连接');
    }
    if (file.folder || file.symlink) {
      throw StateError('本地编辑仅支持普通文件');
    }
    if (file.byteSize != null && file.byteSize! > _maxEditBytes) {
      throw StateError('超过16MiB的文件请使用外部大文件编辑');
    }
    // Each task owns its own temp directory and keeps the ORIGINAL file
    // name inside it (sanitized only for characters the local OS cannot
    // represent): correct editor association, and same-name files from
    // different hosts can never collide. The session exists before the
    // download so the queue task can stream progress from byte zero.
    final ownRoot = rootOverride == null;
    final root =
        rootOverride ?? Directory.systemTemp.createTempSync('hspterm-edit');
    final taskDir = Directory(
      '${root.path}/edit-${DateTime.now().microsecondsSinceEpoch}',
    );
    taskDir.createSync(recursive: true);
    final local = File('${taskDir.path}/${sanitizeLocalName(file.name)}');
    final session = LocalEditSession._(
      source,
      file.id,
      local,
      native,
      generation,
      file.byteSize ?? 0,
      null,
      gateway,
      notice,
      ownRoot,
      onConflict,
    );
    onSession?.call(session);
    final bytes = await gateway.download(
      native,
      generation,
      file.id,
      onProgress: (done, total) => session._setProgress(done, total ?? 0),
    );
    final stat = await gateway.stat(native, generation, file.id);
    session
      .._originSize = stat.size
      .._originMtime = stat.mtime;
    await local.writeAsBytes(bytes, flush: true);
    final launch = launchOverride ?? _launchFileUri;
    try {
      await session._open(launch);
    } catch (_) {
      await session.dispose();
      rethrow;
    }
  }

  static Future<bool> _launchFileUri(Uri uri) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _open(Future<bool> Function(Uri uri) launch) async {
    _lastModified = await _file.lastModified();
    _lastUploadedBytes = await _file.readAsBytes();
    _watch = _home.watch().listen((event) {
      if (event.path == _file.path) _scheduleStabilityCheck();
    });
    // Directory events can be missed (and editors saving via rename
    // generate create/delete): a cheap poll backs the watch.
    _poll = Timer.periodic(_pollInterval, (_) => _scheduleStabilityCheck());
    final opened = await launch(Uri.file(_file.absolute.path));
    if (!opened) {
      throw StateError('系统没有成功打开本地文件');
    }
    _setStatus(LocalEditStatus.editing);
  }

  void _scheduleStabilityCheck() {
    if (_disposed || _uploading) return;
    _stability?.cancel();
    _stability = Timer(_stableWindow, _checkForStableChange);
  }

  /// Test hook: run the stability check immediately.
  @visibleForTesting
  Future<void> testStableCheck() => _checkForStableChange();

  Future<void> _checkForStableChange() async {
    if (_disposed || _uploading) return;
    if (!await _file.exists()) return;
    final modified = await _file.lastModified();
    // Content comparison, not size: a same-length edit is still a change.
    if (!modified.isAfter(_lastModified)) return;
    final bytes = await _file.readAsBytes();
    final last = _lastUploadedBytes;
    if (last != null && _sameBytes(last, bytes)) {
      _lastModified = modified;
      return;
    }
    _lastModified = modified;
    await _upload();
  }

  Future<void> retry() => _upload();

  Future<void> _upload() async {
    if (_disposed || _uploading) return;
    _uploading = true;
    try {
      final current = _session.controller.id == _native
          ? _session.controller.generation
          : null;
      if (current == null ||
          !_session.controller.connected ||
          current != _originGeneration) {
        _setStatus(LocalEditStatus.failed);
        _noticeAndLog(
          '本地编辑上传暂停：原 SSH 会话已断开；修改已保留，可稍后重试',
          AppLogEvent.editUploadFailed,
        );
        return;
      }
      final remote = await _gateway.stat(_native, current, _remotePath);
      if (remote.size != _originSize ||
          (remote.mtime != null &&
              _originMtime != null &&
              remote.mtime != _originMtime)) {
        _conflicted = true;
        _setStatus(LocalEditStatus.conflicted);
        _noticeAndLog('远端文件已被修改，本地编辑未覆盖；请手动处理后重试', AppLogEvent.editConflict);
        return;
      }
      final bytes = await _file.readAsBytes();
      // Upload to a sibling temp name, then rename over the original so a
      // mid-upload failure never destroys the remote file.
      final slash = _remotePath.lastIndexOf('/');
      final parent = slash == 0 ? '/' : _remotePath.substring(0, slash);
      final tempName =
          '$parent/.hspterm-edit-${DateTime.now().microsecondsSinceEpoch}';
      _setStatus(LocalEditStatus.uploading);
      await _gateway.upload(
        _native,
        current,
        tempName,
        bytes,
        onProgress: _setProgress,
      );
      try {
        try {
          await _gateway.renameOver(_native, current, tempName, _remotePath);
        } on Object catch (blocked) {
          // The destination is the file being edited, so a name conflict is
          // expected on servers without POSIX-rename. Ask once, then retry
          // with an explicit replace; declining keeps the local edits.
          final replace =
              blocked.toString().contains('目标路径已存在') &&
              _onConflict != null &&
              await _onConflict(_remotePath);
          if (!replace) rethrow;
          await _gateway.renameOver(
            _native,
            current,
            tempName,
            _remotePath,
            force: true,
          );
        }
      } catch (error) {
        // The original remote file is untouched, but the temp sibling would
        // otherwise linger forever; remove it best-effort before rethrowing.
        try {
          await _gateway.removeFile(_native, current, tempName);
        } catch (_) {
          // Cleanup itself failed; the upload error below still reports the
          // original failure so the user can retry.
        }
        rethrow;
      }
      _originSize = bytes.length;
      final after = await _gateway.stat(_native, current, _remotePath);
      _originMtime = after.mtime;
      _lastUploadedBytes = bytes;
      _conflicted = false;
      _setStatus(LocalEditStatus.editing);
      AppRunLog.instance.event(
        AppLogEvent.editUploaded,
        terminal: _native,
        generation: current,
        fields: {'bytes': bytes.length, 'result': 'ok'},
      );
    } catch (error) {
      _setStatus(LocalEditStatus.failed);
      _noticeAndLog(
        '本地编辑上传失败：修改已保留，可稍后重试',
        AppLogEvent.editUploadFailed,
        error: error,
      );
    } finally {
      _uploading = false;
    }
  }

  void _noticeAndLog(String message, AppLogEvent event, {Object? error}) {
    _onNotice(message);
    AppRunLog.instance.event(
      event,
      terminal: _native,
      generation: _originGeneration,
      error: error,
    );
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _disposeStarted = false;
  @override
  Future<void> dispose() async {
    if (_disposeStarted) return;
    _disposeStarted = true;
    _disposed = true;
    _setStatus(LocalEditStatus.closed);
    await _watch?.cancel();
    _stability?.cancel();
    _poll?.cancel();
    try {
      if (await _file.exists()) await _file.delete();
      if (await _home.exists() && await _home.list().isEmpty) {
        await _home.delete();
      }
      final root = _home.parent;
      if (_ownRoot && await root.exists() && await root.list().isEmpty) {
        await root.delete();
      }
    } catch (_) {
      // Best-effort cleanup; the OS temp cleaner owns the rest.
    }
    super.dispose();
  }
}

/// Registry owned by the workbench model: bounded, disposed with the model.
/// Also the change source for the transfer queue's local-edit section.
class LocalEditRegistry extends ChangeNotifier {
  final _sessions = <LocalEditSession>[];
  bool _closed = false;

  bool get isFull => _sessions.length >= _maxSessionsPerModel;
  int get length => _sessions.length;
  List<LocalEditSession> get sessions => List.unmodifiable(_sessions);

  void register(LocalEditSession session) {
    if (_closed || isFull) {
      session.dispose();
      notifyListeners();
      return;
    }
    _sessions.add(session);
    session.addListener(notifyListeners);
    notifyListeners();
  }

  void unregister(LocalEditSession session) {
    if (_sessions.remove(session)) {
      session.removeListener(notifyListeners);
      notifyListeners();
    }
  }

  Future<void> disposeAll() async {
    _closed = true;
    final pending = List.of(_sessions);
    for (final session in pending) {
      session.removeListener(notifyListeners);
    }
    _sessions.clear();
    await Future.wait(pending.map((s) => s.dispose()));
    notifyListeners();
  }
}

/// Wraps [LocalEditSession.launch] with the user-facing notices.
Future<void> openLocalEdit(
  BuildContext context,
  LiveWorkbenchModel model,
  LiveTerminalSession source,
  DemoFile file,
) async {
  try {
    if (model.localEdits.isFull) {
      if (context.mounted) showAppNotice(context, '本地编辑任务过多，请先关闭部分编辑会话');
      return;
    }
    await LocalEditSession.launch(
      source,
      file,
      onNotice: (message) {
        if (context.mounted) showAppNotice(context, message);
      },
      onSession: model.localEdits.register,
      onConflict: (remotePath) async {
        if (!context.mounted) return false;
        final name = remotePath.split('/').last;
        return await showDialog<bool>(
              context: context,
              builder: (dialog) => AlertDialog(
                title: const Text('替换远端文件？'),
                content: Text(
                  '保存需要替换远端同名文件「$name」；服务器不支持原子覆盖，'
                  '确认后将先删除远端原文件再写入新内容。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialog, true),
                    child: const Text('覆盖'),
                  ),
                ],
              ),
            ) ==
            true;
      },
    );
    if (context.mounted) {
      showAppNotice(context, '已在本地编辑器打开；保存后自动上传，远端变更将提示冲突');
    }
  } catch (error) {
    if (context.mounted) showAppNotice(context, '本地编辑打开失败：$error');
  }
}
