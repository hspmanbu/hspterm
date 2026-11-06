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
  Future<List<int>> download(int native, String path);
  Future<({int size, int? mtime})> stat(
    int native,
    int generation,
    String path,
  );
  Future<void> upload(int native, String path, List<int> bytes);
  Future<void> renameOver(int native, String from, String to);
}

class NativeLocalEditGateway implements LocalEditGateway {
  const NativeLocalEditGateway();
  @override
  Future<List<int>> download(int native, String path) async {
    final out = <int>[];
    final meta = await rust.sftpProperties(
      id: native,
      generation: 0,
      path: path,
      includeDirectorySize: false,
    );
    final total = meta.size;
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
  Future<void> upload(int native, String path, List<int> bytes) async {
    const chunk = 1024 * 1024;
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
    }
  }

  @override
  Future<void> renameOver(int native, String from, String to) {
    return rust.sftpRename(id: native, source: from, destination: to);
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

class LocalEditSession {
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
  );

  final LiveTerminalSession _session;
  final String _remotePath;
  final File _file;
  final int _native;
  final int _originGeneration;
  int _originSize;
  int? _originMtime;
  final LocalEditGateway _gateway;
  final void Function(String message) _onNotice;

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
    final bytes = await gateway.download(native, file.id);
    final stat = await gateway.stat(native, generation, file.id);
    final root =
        rootOverride ??
        Directory.systemTemp.createTempSync('hspterm-local-edit');
    final local = File(
      '${root.path}/edit-${DateTime.now().microsecondsSinceEpoch}-${sanitizeLocalName(file.name)}',
    );
    await local.writeAsBytes(bytes, flush: true);
    final session = LocalEditSession._(
      source,
      file.id,
      local,
      native,
      generation,
      stat.size,
      stat.mtime,
      gateway,
      notice,
    );
    final launch = launchOverride ?? _launchFileUri;
    try {
      await session._open(launch);
    } catch (_) {
      await session.dispose();
      rethrow;
    }
    onSession?.call(session);
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
      await _gateway.upload(_native, tempName, bytes);
      await _gateway.renameOver(_native, tempName, _remotePath);
      _originSize = bytes.length;
      final after = await _gateway.stat(_native, current, _remotePath);
      _originMtime = after.mtime;
      _lastUploadedBytes = bytes;
      _conflicted = false;
      AppRunLog.instance.event(
        AppLogEvent.editUploaded,
        terminal: _native,
        generation: current,
        fields: {'bytes': bytes.length, 'result': 'ok'},
      );
    } catch (error) {
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

  Future<void> dispose() async {
    _disposed = true;
    await _watch?.cancel();
    _stability?.cancel();
    _poll?.cancel();
    try {
      if (await _file.exists()) await _file.delete();
      if (await _home.exists() && await _home.list().isEmpty) {
        await _home.delete();
      }
    } catch (_) {
      // Best-effort cleanup; the OS temp cleaner owns the rest.
    }
  }
}

/// Registry owned by the workbench model: bounded, disposed with the model.
class LocalEditRegistry {
  final _sessions = <LocalEditSession>[];
  bool _closed = false;

  bool get isFull => _sessions.length >= _maxSessionsPerModel;
  int get length => _sessions.length;

  void register(LocalEditSession session) {
    if (_closed || isFull) {
      session.dispose();
      return;
    }
    _sessions.add(session);
  }

  void unregister(LocalEditSession session) {
    _sessions.remove(session);
  }

  Future<void> disposeAll() async {
    _closed = true;
    final pending = List.of(_sessions);
    _sessions.clear();
    await Future.wait(pending.map((s) => s.dispose()));
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
    );
    if (context.mounted) {
      showAppNotice(context, '已在本地编辑器打开；保存后自动上传，远端变更将提示冲突');
    }
  } catch (error) {
    if (context.mounted) showAppNotice(context, '本地编辑打开失败：$error');
  }
}
