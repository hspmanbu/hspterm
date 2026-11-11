import '../prototype/design.dart';

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
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_notice.dart';
import '../prototype/model.dart';
import '../run_log.dart';
import '../src/rust/api.dart' as rust;
import 'model.dart';

const _maxEditBytes = 16 * 1024 * 1024;

/// Incremental content fingerprint (round-11 P0): two independently seeded
/// 64-bit FNV-1a lanes plus the byte length, fed in fixed 1 MiB chunks so
/// no whole-file buffer is ever held. Collisions across same-length edit
/// re-saves are astronomically unlikely for this purpose (change detection,
/// not security); no new dependency.
class ContentDigest {
  ContentDigest();
  int _a = 0xcbf29ce484222325, _b = 0x9e3779b97f4a7c15, _len = 0;
  static const _prime = 0x100000001b3;
  void add(List<int> bytes) {
    _len += bytes.length;
    var a = _a, b = _b;
    for (final byte in bytes) {
      a = (a ^ byte) * _prime;
      b = (b + byte * 31) * 0x100000001b3;
    }
    _a = a;
    _b = b;
  }

  @override
  String toString() => '$_len.${_a.toRadixString(16)}.${_b.toRadixString(16)}';
}

/// Streams [file] in chunks, returning its fingerprint without buffering
/// the whole content. Runs on a background isolate (round-12): the per-byte
/// loop must never occupy the UI isolate — a 16 MiB file is ~16M iterations
/// and used to stall frames and the heartbeat.
Future<String> digestOf(File file) => Isolate.run(() {
  final digest = ContentDigest();
  final raf = File(file.path).openSync();
  try {
    while (true) {
      final chunk = raf.readSync(1024 * 1024);
      if (chunk.isEmpty) break;
      digest.add(chunk);
    }
  } finally {
    raf.closeSync();
  }
  return digest.toString();
});

const _stableWindow = Duration(milliseconds: 700);

/// Backstop poll only (round-12): the directory watch drives change
/// detection at interactive speed; this catches events the platform drops.
/// A slow interval keeps per-session timers cheap on the UI isolate.
const _pollInterval = Duration(seconds: 5);
const _maxSessionsPerModel = 16;

/// A local-edit session auto-closes after this long without a real content
/// change (round-12). Watches/timers/subscriptions are released and unsynced
/// drafts stay on disk.
const defaultEditIdleTimeout = Duration(minutes: 15);
const _idleCheckInterval = Duration(seconds: 30);

/// Abstraction over the native calls so tests can simulate every flow.
abstract interface class LocalEditGateway {
  /// Streams the remote file straight into [target] (round-11 P0): no
  /// whole-file Dart buffer; progress reports per chunk.
  Future<void> downloadTo(
    int native,
    int generation,
    String path,
    File target, {
    void Function(int done, int? total)? onProgress,
  });
  Future<({int size, int? mtime})> stat(
    int native,
    int generation,
    String path,
  );

  /// Streams [source] from disk to the remote path in chunks (round-11
  /// P0): the file is never fully loaded into memory.
  Future<void> uploadFrom(
    int native,
    int generation,
    String path,
    File source, {
    void Function(int done, int total)? onProgress,
  });

  /// Edit-save replace phase 1: prefers the atomic POSIX rename.
  /// 'Applied' = replaced in one step; 'NeedsConfirmation' = only the
  /// destructive (backup+rollback) path exists, the caller must collect
  /// explicit user consent first.
  Future<String> replaceAtomic(
    int native,
    int generation,
    String temp,
    String original,
  );

  /// Edit-save replace phase 2: the confirmed destructive path with backup
  /// and rollback; preserves mode and owner/group when the server allows.
  Future<String> replaceConfirmed(
    int native,
    int generation,
    String temp,
    String original,
  );
  Future<void> removeFile(int native, int generation, String path);
}

class NativeLocalEditGateway implements LocalEditGateway {
  const NativeLocalEditGateway();
  @override
  Future<void> downloadTo(
    int native,
    int generation,
    String path,
    File target, {
    void Function(int done, int? total)? onProgress,
  }) async {
    final meta = await rust.sftpProperties(
      id: native,
      generation: generation,
      path: path,
      includeDirectorySize: false,
    );
    final total = meta.size;
    onProgress?.call(0, total);
    final sink = target.openWrite();
    var offset = 0;
    try {
      while (offset < total) {
        final chunk = await rust.sftpReadChunk(
          id: native,
          path: path,
          offset: offset,
          length: (total - offset).clamp(0, 1024 * 1024),
        );
        if (chunk.isEmpty) break;
        sink.add(chunk);
        offset += chunk.length;
        // Flush per chunk (round-12): without an await point the IOSink can
        // buffer the whole file when the target (e.g. %TEMP% under Defender)
        // writes slower than SFTP reads — up to 16 MiB resident per session.
        await sink.flush();
        onProgress?.call(offset, total);
      }
      await sink.flush();
    } catch (error) {
      await sink.close().catchError((_) {});
      rethrow;
    }
    await sink.close();
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
  Future<void> uploadFrom(
    int native,
    int generation,
    String path,
    File source, {
    void Function(int done, int total)? onProgress,
  }) async {
    const chunk = 1024 * 1024;
    final total = await source.length();
    onProgress?.call(0, total);
    if (total == 0) {
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
    final raf = await source.open();
    try {
      var offset = 0;
      while (offset < total) {
        final slice = await raf.read(chunk);
        if (slice.isEmpty) break;
        await rust.sftpWriteChunk(
          id: native,
          path: path,
          offset: offset,
          data: slice,
          truncate: offset == 0,
        );
        offset += slice.length;
        onProgress?.call(offset.clamp(0, total), total);
      }
    } finally {
      await raf.close();
    }
  }

  @override
  Future<String> replaceAtomic(
    int native,
    int generation,
    String temp,
    String original,
  ) {
    return rust.sftpEditReplace(
      id: native,
      generation: generation,
      temp: temp,
      original: original,
    );
  }

  @override
  Future<String> replaceConfirmed(
    int native,
    int generation,
    String temp,
    String original,
  ) {
    return rust.sftpEditReplaceConfirmed(
      id: native,
      generation: generation,
      temp: temp,
      original: original,
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

/// User's choice for the destructive edit-save replace (round-11).
class LocalEditConflictDecision {
  const LocalEditConflictDecision({required this.always});

  /// true = "本次连接均覆盖": remember for this SSH connection only.
  final bool always;
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
    this._overwriteScope,
    this._overwriteAllowed,
    this._overwriteAllowSink, [
    this.idleTimeout = defaultEditIdleTimeout,
  ]);

  final LiveTerminalSession _session;
  final String _remotePath;
  final File _file;

  /// Queue-task surface (round-9): lifecycle state and byte progress for
  /// the download/upload phases. Purely derived UI metadata.
  LocalEditStatus status = LocalEditStatus.downloading;
  int progressDone = 0;
  int? progressTotal;
  String get displayName => _remotePath.split('/').last;
  String get hostLabel => _session.host.name;
  String get remotePath => _remotePath;
  File get localFile => _file;
  LiveTerminalSession get session => _session;

  void _setStatus(LocalEditStatus next) {
    if (_disposed || status == next) return;
    status = next;
    notifyListeners();
  }

  void _setProgress(int done, int? total) {
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

  /// Asks the user how to proceed when only the destructive replace path
  /// exists (round-11): null = cancel, always=false = replace once,
  /// always=true = remember for this connection.
  final Future<LocalEditConflictDecision?> Function(String remotePath)?
  _onConflict;

  /// (native id, generation) of the owning connection; the
  /// connection-scoped overwrite memory keys on it (reconnect → new
  /// generation → consent expires automatically).
  final (int, int)? _overwriteScope;
  final bool Function(int, int)? _overwriteAllowed;
  final void Function(int, int)? _overwriteAllowSink;

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _stability;
  Timer? _poll;
  Timer? _idleTimer;
  DateTime _lastModified = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastSyncedDigest;
  bool _uploading = false, _conflicted = false, _disposed = false;

  /// Instant of the last REAL content change (creation or a digest that
  /// differed from the last synced one). mtime-only churn never resets this.
  DateTime _lastRealChange = DateTime.now();

  /// Idle auto-close threshold; injectable for tests.
  final Duration idleTimeout;

  /// Tracks the running upload so dispose can wait for it instead of racing
  /// a streaming read against file cleanup.
  Future<void> _inFlightUpload = Future.value();
  Future<void> _initialization = Future.value();
  Future<void>? _inFlightCheck;

  Directory get _home => _file.parent;
  bool get conflicted => _conflicted;
  bool get isDisposed => _disposed;
  @visibleForTesting
  bool get hasSessionListeners => hasListeners;

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
    Future<LocalEditConflictDecision?> Function(String remotePath)? onConflict,
    bool Function(int native, int generation)? overwriteAllowed,
    void Function(int native, int generation)? allowOverwrite,
    Duration idleTimeout = defaultEditIdleTimeout,
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
      (native, generation),
      overwriteAllowed,
      allowOverwrite,
      idleTimeout,
    );
    final initialization = Completer<void>();
    session._initialization = initialization.future;
    try {
      onSession?.call(session);
      session._requireOpen();
      await gateway.downloadTo(
        native,
        generation,
        file.id,
        local,
        onProgress: (done, total) => session._setProgress(done, total),
      );
      session._requireOpen();
      final stat = await gateway.stat(native, generation, file.id);
      session._requireOpen();
      session
        .._originSize = stat.size
        .._originMtime = stat.mtime;
      await session._open(launchOverride ?? _launchFileUri);
      session._requireOpen();
    } catch (_) {
      initialization.complete();
      await session.dispose();
      rethrow;
    } finally {
      if (!initialization.isCompleted) initialization.complete();
    }
  }

  void _requireOpen() {
    if (_disposeStarted) throw StateError('本地编辑会话已关闭；未继续启动或传输');
  }

  static Future<bool> _launchFileUri(Uri uri) {
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _open(Future<bool> Function(Uri uri) launch) async {
    _lastModified = await _file.lastModified();
    _lastSyncedDigest = await digestOf(_file);
    _requireOpen();
    _lastRealChange = DateTime.now();
    _watch = _home.watch().listen((event) {
      if (event.path == _file.path) _scheduleStabilityCheck();
    });
    // Directory events can be missed (and editors saving via rename
    // generate create/delete): a cheap poll backs the watch.
    _poll = Timer.periodic(_pollInterval, (_) => _scheduleStabilityCheck());
    // The idle check granularity follows the timeout: production uses the
    // 30 s floor, tests injecting tiny timeouts get equally tiny ticks.
    final idleCheckEvery = idleTimeout < _idleCheckInterval
        ? idleTimeout
        : _idleCheckInterval;
    _idleTimer = Timer.periodic(idleCheckEvery, (_) => _checkIdle());
    final opened = await launch(Uri.file(_file.absolute.path));
    if (!opened) {
      throw StateError('系统没有成功打开本地文件');
    }
    _setStatus(LocalEditStatus.editing);
  }

  /// Auto-close after [idleTimeout] without a real content change. Never
  /// fires mid-download/upload; unsynced drafts survive (dispose keeps them).
  void _checkIdle() {
    if (_disposed || _uploading) return;
    if (status == LocalEditStatus.downloading ||
        status == LocalEditStatus.uploading) {
      return;
    }
    final idle = DateTime.now().difference(_lastRealChange);
    if (idle < idleTimeout) return;
    AppRunLog.instance.event(
      AppLogEvent.editIdleClosed,
      terminal: _native,
      generation: _originGeneration,
      count: idle.inMinutes,
    );
    _onNotice(
      '「$displayName」已连续 $_idleTimeoutLabel 无修改，编辑会话已自动关闭；'
      '未同步的修改保留在本地草稿',
    );
    unawaited(dispose());
  }

  String get _idleTimeoutLabel =>
      idleTimeout.inMinutes >= 1 ? '${idleTimeout.inMinutes} 分钟' : '很短时间';

  void _scheduleStabilityCheck() {
    if (_disposed || _uploading) return;
    _stability?.cancel();
    _stability = Timer(_stableWindow, _checkForStableChange);
  }

  /// Test hook: run the stability check immediately.
  @visibleForTesting
  Future<void> testStableCheck() => _checkForStableChange();

  Future<void> _checkForStableChange() {
    if (_disposed || _uploading) return Future.value();
    return _inFlightCheck ??= _stableChange().whenComplete(
      () => _inFlightCheck = null,
    );
  }

  Future<void> _stableChange() async {
    if (_disposed || _uploading) return;
    if (!await _file.exists()) return;
    final modified = await _file.lastModified();
    // Content comparison, not size: a same-length edit is still a change.
    if (!modified.isAfter(_lastModified)) return;
    // Content fingerprint (round-11): same-length edits still upload; an
    // unchanged file is skipped — without buffering either version.
    final digest = await digestOf(_file);
    if (digest == _lastSyncedDigest) {
      _lastModified = modified;
      return;
    }
    _lastModified = modified;
    // A real content change resets the idle auto-close clock.
    _lastRealChange = DateTime.now();
    await _upload();
  }

  Future<void> retry() => _upload();

  Future<void> _upload() {
    if (_uploading) return _inFlightUpload;
    // Track the in-flight upload so dispose waits instead of deleting the
    // local file under a streaming read.
    return _inFlightUpload = _uploadInner();
  }

  Future<void> _uploadInner() async {
    if (_disposed || _uploading) return;
    _uploading = true;
    File? snapshot;
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
      // Upload to a sibling temp name, then replace the original so a
      // mid-upload failure never destroys the remote file. The local file
      // streams from disk (round-11 P0) — never fully buffered.
      final slash = _remotePath.lastIndexOf('/');
      final parent = slash == 0 ? '/' : _remotePath.substring(0, slash);
      final tempName =
          '$parent/.hspterm-edit-${DateTime.now().microsecondsSinceEpoch}';
      snapshot = await _snapshotForUpload();
      final uploadedDigest = await digestOf(snapshot);
      final uploadedSize = await snapshot.length();
      _setStatus(LocalEditStatus.uploading);
      await _gateway.uploadFrom(
        _native,
        current,
        tempName,
        snapshot,
        onProgress: _setProgress,
      );
      try {
        final outcome = await _gateway.replaceAtomic(
          _native,
          current,
          tempName,
          _remotePath,
        );
        if (outcome != 'Applied') {
          // Only the destructive path exists. With a standing
          // "本次连接均覆盖" consent for THIS connection (native id +
          // generation) replace directly; otherwise ask — and re-verify
          // the remote still matches the snapshot so consent granted
          // against a stale state never overwrites newer content.
          var allowed =
              _overwriteScope != null &&
              _overwriteAllowed != null &&
              _overwriteAllowed(_overwriteScope.$1, _overwriteScope.$2);
          if (!allowed && _onConflict != null) {
            final decision = await _onConflict(_remotePath);
            if (decision == null) {
              throw StateError('已取消替换远端文件');
            }
            // Requirement: re-validate while the user was deciding — the
            // session identity AND the remote snapshot must both still
            // match, so consent granted against a stale state never
            // overwrites newer content.
            final stillCurrent =
                _session.controller.id == _native &&
                _session.controller.connected &&
                _session.controller.generation == current;
            final fresh = stillCurrent
                ? await _gateway.stat(_native, current, _remotePath)
                : null;
            final unchanged =
                fresh != null &&
                fresh.size == _originSize &&
                (fresh.mtime == null ||
                    _originMtime == null ||
                    fresh.mtime == _originMtime);
            if (!unchanged) {
              _conflicted = true;
              _setStatus(LocalEditStatus.conflicted);
              _noticeAndLog(
                stillCurrent
                    ? '远端文件在确认期间已被修改，本地编辑未覆盖；请手动处理后重试'
                    : '确认期间原连接已断开；修改已保留，可稍后重试',
                AppLogEvent.editConflict,
              );
              return;
            }
            if (decision.always &&
                _overwriteScope != null &&
                _overwriteAllowSink != null) {
              _overwriteAllowSink(_overwriteScope.$1, _overwriteScope.$2);
            }
            allowed = true;
          }
          if (!allowed) {
            throw StateError('未获替换授权');
          }
          await _gateway.replaceConfirmed(
            _native,
            current,
            tempName,
            _remotePath,
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
      _originSize = uploadedSize;
      final after = await _gateway.stat(_native, current, _remotePath);
      _originMtime = after.mtime;
      _lastSyncedDigest = uploadedDigest;
      // A finished sync is the newest baseline; restart the idle clock.
      _lastRealChange = DateTime.now();
      _conflicted = false;
      _setStatus(LocalEditStatus.editing);
      AppRunLog.instance.event(
        AppLogEvent.editUploaded,
        terminal: _native,
        generation: current,
        fields: {'bytes': _originSize, 'result': 'ok'},
      );
    } catch (error) {
      _setStatus(LocalEditStatus.failed);
      _noticeAndLog(
        '本地编辑上传失败：修改已保留，可稍后重试',
        AppLogEvent.editUploadFailed,
        error: error,
      );
    } finally {
      if (snapshot != null) {
        try {
          await snapshot.delete();
        } catch (error) {
          AppRunLog.instance.event(
            AppLogEvent.editUploadFailed,
            error: error,
            fields: {'kind': 'snapshot-cleanup'},
          );
        }
      }
      _uploading = false;
    }
  }

  /// Upload a bounded immutable snapshot, not the file an external editor can
  /// change while the network is writing. Only its digest certifies syncing.
  Future<File> _snapshotForUpload() async {
    final snapshot = File(
      '${_home.path}/.upload-${DateTime.now().microsecondsSinceEpoch}',
    );
    RandomAccessFile? input, output;
    try {
      input = await _file.open();
      output = await snapshot.open(mode: FileMode.writeOnly);
      var copied = 0;
      while (true) {
        final bytes = await input.read(1024 * 1024);
        if (bytes.isEmpty) break;
        copied += bytes.length;
        if (copied > _maxEditBytes) throw StateError('本地编辑超过16MiB；原草稿保留');
        await output.writeFrom(bytes);
      }
      await input.close();
      input = null;
      await output.close();
      output = null;
      return snapshot;
    } catch (_) {
      await input?.close();
      await output?.close();
      if (await snapshot.exists()) await snapshot.delete();
      rethrow;
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

  bool _disposeStarted = false;
  Future<void>? _closeFuture;
  LocalEditRegistry? _owner;
  @override
  Future<void> dispose() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final completion = Completer<void>();
    _closeFuture = completion.future;
    _disposeStarted = true;
    _owner?._retire(this, completion.future);
    _owner = null;
    unawaited(
      _disposeOwned().then(
        (_) {
          super.dispose();
          completion.complete();
        },
        onError: (Object error, StackTrace stack) {
          super.dispose();
          completion.completeError(error, stack);
        },
      ),
    );
    return completion.future;
  }

  Future<void> _disposeOwned() async {
    // Publish the terminal state before marking disposed: _setStatus ignores
    // calls after _disposed, but the closed transition itself must land.
    _setStatus(LocalEditStatus.closed);
    _disposed = true;
    await _watch?.cancel();
    _stability?.cancel();
    _poll?.cancel();
    _idleTimer?.cancel();
    // An in-flight upload streams from the local file; let it finish (or
    // fail) before any cleanup decides whether the file can be deleted.
    await _initialization;
    await _inFlightCheck?.catchError((Object _) {});
    await _inFlightUpload.catchError((_) {});
    try {
      // Round-11 requirement: NEVER delete a local file whose content was
      // not confirmed synced. Unsynced drafts stay on disk for the user
      // (the queue tile remains actionable until the process exits); only
      // files identical to the last confirmed upload (or the pristine
      // download, when nothing was ever uploaded) are cleaned up.
      var safeToDelete = false;
      if (await _file.exists()) {
        final current = await digestOf(_file);
        safeToDelete = current == _lastSyncedDigest;
      } else {
        safeToDelete = true;
      }
      if (safeToDelete) {
        if (await _file.exists()) await _file.delete();
        if (await _home.exists() && await _home.list().isEmpty) {
          await _home.delete();
        }
        final root = _home.parent;
        if (_ownRoot && await root.exists() && await root.list().isEmpty) {
          await root.delete();
        }
      } else {
        AppRunLog.instance.event(
          AppLogEvent.editUploadFailed,
          terminal: _native,
          generation: _originGeneration,
          count: 1,
          fields: {'result': 'draft-kept', 'kind': 'dispose'},
        );
      }
    } catch (_) {
      // Best-effort cleanup; the OS temp cleaner owns the rest.
    }
  }
}

/// Registry owned by the workbench model: bounded, disposed with the model.
/// Also the change source for the transfer queue's local-edit section.
class LocalEditRegistry extends ChangeNotifier {
  final _sessions = <LocalEditSession>[];
  bool _closed = false;

  /// "本次连接均覆盖" memory (round-11), keyed by the SSH native id AND
  /// generation: a reconnect bumps the generation, so the consent expires
  /// with the connection that granted it. Runtime state only — never
  /// persisted, never shared across tabs of the same host.
  final _overwriteAllowed = <(int, int)>{};

  bool overwriteAllowed(int native, int generation) =>
      _overwriteAllowed.contains((native, generation));

  void allowOverwrite(int native, int generation) {
    _overwriteAllowed.add((native, generation));
  }

  bool get isFull =>
      _sessions.length + _retiring.length >= _maxSessionsPerModel;
  int get length => _sessions.length;
  List<LocalEditSession> get sessions => List.unmodifiable(_sessions);

  final _retiring = <Future<void>>{};
  bool _notifierDisposed = false;

  void _changed() {
    if (!_notifierDisposed) notifyListeners();
  }

  void register(LocalEditSession session) {
    if (identical(session._owner, this) || session.isDisposed) return;
    if (session._owner != null) throw StateError('编辑会话已有注册表所有者');
    session._owner = this;
    if (_closed || isFull || session._disposeStarted) {
      unawaited(session.dispose());
      return;
    }
    _sessions.add(session);
    session.addListener(_changed);
    _changed();
  }

  void _retire(LocalEditSession session, Future<void> closing) {
    _sessions.remove(session);
    session.removeListener(_changed);
    _retiring.add(closing);
    unawaited(
      closing.then(
        (_) {
          _retiring.remove(closing);
          _changed();
        },
        onError: (Object error, StackTrace stack) {
          _retiring.remove(closing);
          _changed();
        },
      ),
    );
    _changed();
  }

  /// Compatibility entry: unregister also retires resources, so no caller can
  /// accidentally detach a live watcher without closing its owning session.
  void unregister(LocalEditSession session) {
    if (identical(session._owner, this)) unawaited(session.dispose());
  }

  Future<void> _drain() async {
    final prior = List<Future<void>>.of(_retiring);
    final active = List<LocalEditSession>.of(_sessions);
    await Future.wait([
      ...prior,
      for (final session in active) session.dispose(),
    ]);
    _changed();
  }

  Future<void> disposeAll() {
    _closed = true;
    _overwriteAllowed.clear();
    return _drain();
  }

  /// A snapshot close leaves the registry available for later editor sessions.
  Future<void> closeAllActive() => _drain();

  @override
  void dispose() {
    _notifierDisposed = true;
    unawaited(disposeAll());
    super.dispose();
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
      if (context.mounted) {
        showAppNotice(
          context,
          '本地编辑任务过多，请先关闭部分编辑会话',
          level: AppNoticeLevel.warning,
        );
      }
      return;
    }
    await LocalEditSession.launch(
      source,
      file,
      onNotice: (message) {
        if (context.mounted) {
          showAppNotice(context, message, level: AppNoticeLevel.warning);
        }
      },
      onSession: model.localEdits.register,
      overwriteAllowed: model.localEdits.overwriteAllowed,
      allowOverwrite: model.localEdits.allowOverwrite,
      onConflict: (remotePath) async {
        if (!context.mounted) return null;
        final name = remotePath.split('/').last;
        // Three-way decision (round-11); the server lacks POSIX-rename so
        // the replace moves the original aside to a backup first and rolls
        // back on failure — nothing is deleted outright.
        return showAppDialog<LocalEditConflictDecision>(
          context: context,
          builder: (dialog) => AlertDialog(
            scrollable: true,
            title: const Text('替换远端文件？'),
            content: Text(
              '保存需要替换远端同名文件「$name」；服务器不支持原子覆盖，'
              '确认后将备份原文件再写入新内容，失败自动还原。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialog,
                  const LocalEditConflictDecision(always: false),
                ),
                child: const Text('仅本次覆盖'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialog,
                  const LocalEditConflictDecision(always: true),
                ),
                child: const Text('本次连接均覆盖'),
              ),
            ],
          ),
        );
      },
    );
    if (context.mounted) {
      showAppNotice(context, '已在本地编辑器打开；保存后自动上传，远端变更将提示冲突');
    }
  } catch (error) {
    if (context.mounted) {
      showAppNotice(context, '本地编辑打开失败：$error', level: AppNoticeLevel.error);
    }
  }
}
