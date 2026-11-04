import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../prototype/model.dart';
import '../src/rust/api.dart' as rust;
import '../src/rust/previews.dart' as data;
import 'model.dart';

abstract interface class FilePreviewBackend {
  Future<data.FilePreview> prepare(String token, bool allowLarge);
  data.FilePreview progress(String token);
  Future<void> cancel(String token);
}

class NativeFilePreviewBackend implements FilePreviewBackend {
  const NativeFilePreviewBackend();
  @override
  Future<data.FilePreview> prepare(String token, bool allowLarge) =>
      rust.prepareFilePreview(token: token, allowLarge: allowLarge);
  @override
  data.FilePreview progress(String token) =>
      rust.filePreviewProgress(token: token);
  @override
  Future<void> cancel(String token) => rust.cancelFilePreview(token: token);
}

Future<void> openCachedFile(String path) async {
  if (Platform.isAndroid) throw UnsupportedError('Android 文件授权与内置预览仍待专项接入');
  final file = File(path);
  if (!file.isAbsolute || !await file.exists()) throw StateError('临时预览文件已不可用');
  if (!await launchUrl(
    Uri.file(file.absolute.path),
    mode: LaunchMode.externalApplication,
  )) {
    throw StateError('没有可用的系统关联程序；可使用下载另存');
  }
}

Future<void> showFilePreview(
  BuildContext context,
  LiveWorkbenchModel model,
  TerminalSession source,
  DemoFile file, {
  Future<void> Function(String)? opener,
}) async {
  final s = source as LiveTerminalSession;
  final id = s.controller.id;
  final generation = s.controller.generation;
  final directoryEpoch = s.directoryEpoch;
  if (id == null || !s.controller.connected) throw StateError('关联 SSH 会话未连接');
  if (!source.files.contains(file)) throw StateError('目录内容已更新，请重新选择文件');
  if (file.symlink) {
    final resolved = await rust.sftpResolveEntry(
      id: id,
      generation: generation,
      path: file.id,
    );
    if (!context.mounted) return;
    if (s.controller.id != id ||
        s.controller.generation != generation ||
        !s.controller.connected) {
      throw StateError('关联 SSH 会话已改变，请重新打开文件');
    }
    if (s.directoryEpoch != directoryEpoch) throw StateError('目录内容已更新，请重新选择文件');
    if (resolved.directory) {
      await model.loadDirectory(source, resolved.path);
      return;
    }
  }
  await model.initializePreviewCache();
  if (!context.mounted) return;
  if (s.controller.id != id ||
      s.controller.generation != generation ||
      !s.controller.connected) {
    throw StateError('关联 SSH 会话已改变，请重新打开文件');
  }
  if (s.directoryEpoch != directoryEpoch) throw StateError('目录内容已更新，请重新选择文件');
  final token = rust.reserveFilePreview(
    id: id,
    generation: generation,
    path: file.id,
  );
  if (!context.mounted) {
    await rust.cancelFilePreview(token: token);
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => FilePreviewDialog(
      token: token,
      host: source.host.name,
      name: file.name,
      backend: const NativeFilePreviewBackend(),
      opener: opener ?? openCachedFile,
      onCleanupError: model.reportOperation,
    ),
  );
}

/// The ticket is reserved before this dialog mounts. Cancelling before prepare
/// starts is valid, and delayed results cannot launch an external application.
class FilePreviewDialog extends StatefulWidget {
  const FilePreviewDialog({
    super.key,
    required this.token,
    required this.host,
    required this.name,
    required this.backend,
    required this.opener,
    required this.onCleanupError,
  });
  final String token, host, name;
  final FilePreviewBackend backend;
  final Future<void> Function(String) opener;
  final void Function(Object) onCleanupError;
  @override
  State<FilePreviewDialog> createState() => _FilePreviewDialogState();
}

class _FilePreviewDialogState extends State<FilePreviewDialog> {
  data.FilePreview? _preview;
  Timer? _timer;
  bool _busy = true, _launching = false, _cancelling = false, _retained = false;
  bool _cleanupReported = false;
  bool _preparing = false;
  String? _error;
  Future<void>? _release;
  @override
  void initState() {
    super.initState();
    unawaited(_prepare(false));
  }

  Future<void> _prepare(bool allowLarge) async {
    if (_preparing || _retained || _cancelling) return;
    _preparing = true;
    setState(() {
      _busy = true;
      _error = null;
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted || _cancelling) return;
      try {
        setState(() => _preview = widget.backend.progress(widget.token));
      } catch (e) {
        setState(() => _error = '$e');
      }
    });
    try {
      final result = await widget.backend.prepare(widget.token, allowLarge);
      _timer?.cancel();
      if (!mounted || _cancelling) return;
      setState(() {
        _preview = result;
        _busy = false;
      });
      if (result.phase == 'Ready') {
        await _open();
      } else if (result.phase != 'NeedsConfirmation') {
        setState(() => _error = result.error ?? '预览未完成，未打开文件');
      }
    } catch (e) {
      if (mounted && !_cancelling) setState(() => _error = '$e');
    } finally {
      _preparing = false;
      _timer?.cancel();
      if (mounted && !_cancelling) setState(() => _busy = false);
    }
  }

  Future<void> _open() async {
    final path = _preview?.localPath;
    if (path == null || _launching || _cancelling || _retained) return;
    setState(() {
      _launching = true;
      _error = null;
    });
    try {
      await widget.opener(path);
      if (!mounted || _cancelling) return;
      _retained = true; // Keep successful previews until application exit.
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '系统关联程序打开失败：$e');
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  Future<void> _cleanup() => _release ??= widget.backend.cancel(widget.token);
  void _reportCleanup(Object error) {
    if (_cleanupReported) return;
    _cleanupReported = true;
    widget.onCleanupError(error);
  }

  Future<void> _cancel() async {
    if (_launching || _cancelling) return;
    setState(() => _cancelling = true);
    _timer?.cancel();
    try {
      await _cleanup();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _reportCleanup(e);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (!_retained) unawaited(_cleanup().catchError(_reportCleanup));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    final needsConfirm =
        p?.phase == 'NeedsConfirmation' && p?.confirmationMib != null && !_busy;
    return PopScope(
      canPop: !_launching && !_cancelling,
      child: AlertDialog(
        scrollable: true,
        title: Text(
          needsConfirm
              ? p!.confirmationMib == 0
                    ? '确认打开远端文件？'
                    : '打开大文件？'
              : '打开远端文件',
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${widget.host} · ${widget.name}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              if (needsConfirm)
                Text(
                  p!.confirmationMib == 0
                      ? '文件大小 ${p.total} 字节，已设置每次打开都确认。继续临时下载并用系统关联程序打开？'
                      : '文件大小 ${p.total} 字节，超过 ${p.confirmationMib} MiB。继续临时下载并用系统关联程序打开？',
                ),
              if (_busy || _launching || _cancelling) ...[
                LinearProgressIndicator(
                  value:
                      !_launching &&
                          !_cancelling &&
                          p?.total != null &&
                          p!.total! > 0
                      ? (p.received / p.total!).clamp(0, 1).toDouble()
                      : null,
                ),
                const SizedBox(height: 8),
                Text(
                  _launching
                      ? '正在打开系统关联程序…'
                      : _cancelling
                      ? '正在取消并释放临时文件…'
                      : '${p?.received ?? 0} / ${p?.total ?? '—'} 字节 · ${p?.phase == 'Waiting' ? '等待传输名额' : '临时下载中'}',
                ),
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 10),
              const Text(
                '每次打开重新下载，临时预览随应用退出清理。此操作不会保存对远端文件的修改。',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('preview-cancel'),
            onPressed: _launching || _cancelling
                ? null
                : () => unawaited(_cancel()),
            child: const Text('取消'),
          ),
          if (needsConfirm)
            FilledButton(
              key: const ValueKey('preview-confirm-large'),
              onPressed: () => unawaited(_prepare(true)),
              child: const Text('继续下载并打开'),
            ),
          if (p?.phase == 'Ready' && _error != null)
            FilledButton(
              onPressed: _launching ? null : () => unawaited(_open()),
              child: const Text('重新尝试打开'),
            ),
        ],
      ),
    );
  }
}
