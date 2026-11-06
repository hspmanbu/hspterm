//! Double-click "open in local editor with write-back" sessions.
//!
//! Downloads the remote file to a temp copy, launches it with the system
//! editor, and watches the copy for stable modifications. Each stable save
//! uploads once back to the original remote path; a remote file that changed
//! since the download snapshot raises an explicit conflict instead of
//! overwriting. Failures keep the temp file and allow retry. No shell, no
//! path interpolation, and the temp directory is removed with the session.
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

class LocalEditSession {
  // ignore: use_super_parameters
  LocalEditSession._(
    this._session,
    this._remotePath,
    this._file,
    this._native,
    this._originGeneration,
    this._originSize,
  );

  final LiveTerminalSession _session;
  final String _remotePath;
  final int _native;
  final int _originGeneration;
  final File _file;
  int _originSize;

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _stability;
  Timer? _poll;
  DateTime _lastModified = DateTime.fromMillisecondsSinceEpoch(0);
  bool _uploading = false, _conflicted = false, _disposed = false;

  Directory get _home => _file.parent;

  static Directory _editRoot() =>
      Directory.systemTemp.createTempSync('hspterm-local-edit');

  /// Opens [file] from [source] in the system editor with write-back.
  static Future<void> launch(LiveTerminalSession source, DemoFile file) async {
    final native = source.controller.id;
    final generation = source.controller.generation;
    if (native == null || !source.controller.connected) {
      throw StateError('关联 SSH 会话未连接');
    }
    if (file.folder || file.symlink) {
      throw StateError('本地编辑仅支持普通文件');
    }
    if (file.byteSize != null && file.byteSize! > _maxEditBytes) {
      throw StateError('超过16MiB的文件请使用外部大文件编辑');
    }
    final started = DateTime.now();
    final bytes = <int>[];
    var offset = 0;
    while (offset < (file.byteSize ?? 0)) {
      final length = (file.byteSize! - offset).clamp(0, 1024 * 1024);
      final chunk = await rust.sftpReadChunk(
        id: native,
        path: file.id,
        offset: offset,
        length: length,
      );
      bytes.addAll(chunk);
      offset += chunk.length;
      if (chunk.isEmpty) break;
    }
    AppRunLog.instance.event(
      AppLogEvent.editDownloaded,
      terminal: native,
      generation: generation,
      count: bytes.length,
    );
    final root = _editRoot();
    final local = File(
      '${root.path}/edit-${DateTime.now().microsecondsSinceEpoch}-${file.name}',
    );
    await local.writeAsBytes(bytes, flush: true);
    final session = LocalEditSession._(
      source,
      file.id,
      local,
      native,
      generation,
      bytes.length,
    );
    try {
      await session._open();
    } catch (_) {
      await session.dispose();
      rethrow;
    }
    AppRunLog.instance.event(
      AppLogEvent.editOpened,
      terminal: native,
      generation: generation,
      count: DateTime.now().difference(started).inMilliseconds,
    );
  }

  Future<void> _open() async {
    _lastModified = await _file.lastModified();
    _watch = _file.parent.watch().listen((event) {
      if (event.path == _file.path &&
          (event.type == FileSystemEvent.modify ||
              event.type == FileSystemEvent.create)) {
        _scheduleStabilityCheck();
      }
    });
    // Directory events can be missed on some platforms: a cheap size poll
    // backs the watch (only while the app runs).
    _poll = Timer.periodic(_pollInterval, (_) => _scheduleStabilityCheck());
    await _launchSystemEditor();
  }

  Future<void> _launchSystemEditor() async {
    // A file URI delegates to the actual OS file association. Calling
    // "cmd /c start" with empty arguments opened the application directory
    // on Windows rather than the downloaded file.
    final uri = Uri.file(_file.absolute.path);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('系统没有成功打开本地文件');
    }
  }

  void _scheduleStabilityCheck() {
    if (_disposed || _uploading) return;
    _stability?.cancel();
    _stability = Timer(_stableWindow, _checkForStableChange);
  }

  Future<void> _checkForStableChange() async {
    if (_disposed || _uploading) return;
    if (!await _file.exists()) return;
    final modified = await _file.lastModified();
    // A same-byte-length edit is still a real modification.
    if (!modified.isAfter(_lastModified)) return;
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
      if (current != _originGeneration ||
          !_session.controller.connected ||
          current == null) {
        AppRunLog.instance.event(
          AppLogEvent.editUploadFailed,
          terminal: _native,
          generation: _originGeneration,
        );
        return;
      }
      // Conflict: remote changed against the download snapshot since the
      // last upload we performed.
      final remote = await rust.sftpProperties(
        id: _native,
        generation: current,
        path: _remotePath,
        includeDirectorySize: false,
      );
      if (remote.size != _originSize) {
        _conflicted = true;
        AppRunLog.instance.event(
          AppLogEvent.editConflict,
          terminal: _native,
          generation: current,
        );
        return;
      }
      final bytes = await _file.readAsBytes();
      const chunk = 1024 * 1024;
      // Zero-byte saves must truncate the remote file too.
      if (bytes.isEmpty) {
        await rust.sftpWriteChunk(
          id: _native,
          path: _remotePath,
          offset: 0,
          data: const [],
          truncate: true,
        );
      }
      for (var offset = 0; offset < bytes.length; offset += chunk) {
        final slice = bytes.sublist(
          offset,
          (offset + chunk).clamp(0, bytes.length),
        );
        await rust.sftpWriteChunk(
          id: _native,
          path: _remotePath,
          offset: offset,
          data: slice,
          truncate: offset == 0,
        );
      }
      _originSize = bytes.length;
      _conflicted = false;
      AppRunLog.instance.event(
        AppLogEvent.editUploaded,
        terminal: _native,
        generation: current,
        count: bytes.length,
      );
    } catch (error) {
      AppRunLog.instance.event(
        AppLogEvent.editUploadFailed,
        terminal: _native,
        generation: _originGeneration,
        error: error,
      );
    } finally {
      _uploading = false;
    }
  }

  bool get conflicted => _conflicted;

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
      // Cleanup is best-effort; the OS temp cleaner owns the rest.
    }
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
    await LocalEditSession.launch(source, file);
    if (context.mounted) {
      showAppNotice(context, '已在本地编辑器打开；保存后自动上传，远端变更将提示冲突');
    }
  } catch (error) {
    if (context.mounted) showAppNotice(context, '本地编辑打开失败：$error');
  }
}
