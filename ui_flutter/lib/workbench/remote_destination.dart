import '../prototype/design.dart';

import 'package:flutter/material.dart';

import '../prototype/model.dart';
import '../src/rust/api.dart' as rust;
import 'model.dart';

/// A destination picker never connects a host or follows the current UI focus.
class RemoteDestinationTarget {
  RemoteDestinationTarget(this.session)
    : nativeId = session.controller.id!,
      generation = session.controller.generation,
      label = '${session.host.name} · ${session.controller.connectionLabel}',
      initialDirectory = session.path.startsWith('/') ? session.path : '/';
  final LiveTerminalSession session;
  final int nativeId, generation;
  final String label, initialDirectory;
  bool get current =>
      session.controller.connected &&
      session.controller.id == nativeId &&
      session.controller.generation == generation;
}

Future<void> showRemoteDestination(
  BuildContext context,
  LiveWorkbenchModel model,
  TerminalSession source,
  List<DemoFile> files,
  bool move,
) async {
  final selection = model.prepareRemoteFileSelection(source, files, cut: move);
  final targets = model.sessions
      .whereType<LiveTerminalSession>()
      .where((s) => s.controller.connected && s.controller.id != null)
      .map(RemoteDestinationTarget.new)
      .toList(growable: false);
  if (targets.isEmpty) throw StateError('没有已连接的目标会话；不会自动连接');
  await showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RemoteDestinationDialog(
      model: model,
      selection: selection,
      targets: targets,
    ),
  );
}

typedef RemoteDirectoryResolver = Future<String> Function(
  RemoteDestinationTarget,
  String,
);

class RemoteDestinationDialog extends StatefulWidget {
  const RemoteDestinationDialog({
    super.key,
    required this.model,
    required this.selection,
    required this.targets,
    this.resolveDirectory,
  });
  final LiveWorkbenchModel model;
  final RemoteFileSelection selection;
  final List<RemoteDestinationTarget> targets;
  final RemoteDirectoryResolver? resolveDirectory;
  @override
  State<RemoteDestinationDialog> createState() =>
      _RemoteDestinationDialogState();
}

class _RemoteDestinationDialogState extends State<RemoteDestinationDialog> {
  late RemoteFileSelection _selection;
  late RemoteDestinationTarget _target;
  late final TextEditingController _directory;
  late final String _sourceLabel;
  String? _error;
  bool _busy = false, _stop = false, _allowRelay = true, _allowDirect = true;
  int _accepted = 0;

  @override
  void initState() {
    super.initState();
    _selection = widget.selection;
    _sourceLabel =
        '${_selection.source.host.name} · ${_selection.source.controller.connectionLabel}';
    _target = widget.targets.firstWhere(
      (t) => identical(t.session, widget.model.focus),
      orElse: () => widget.targets.first,
    );
    _directory = TextEditingController(text: _target.initialDirectory);
  }

  void _checkCurrent(RemoteDestinationTarget target) {
    final source = _selection.source;
    if (!target.current ||
        !widget.model.sessions.contains(target.session) ||
        !widget.model.sessions.contains(source) ||
        !source.controller.connected ||
        source.controller.id != _selection.nativeId ||
        source.controller.generation != _selection.generation) {
      throw StateError('源或目标SSH已关闭或改变；请关闭此对话框后重新选择，不会自动连接');
    }
  }

  Future<String> _resolve(RemoteDestinationTarget target, String path) async {
    final override = widget.resolveDirectory;
    if (override != null) return override(target, path);
    final entry = await rust.sftpResolveEntry(
      id: target.nativeId,
      generation: target.generation,
      path: path,
    );
    if (!entry.directory || entry.symlink) throw StateError('目标必须是已存在的远端目录');
    return entry.path;
  }

  Future<void> _submit() async {
    if (_busy) return;
    final composing = _directory.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      setState(() => _error = '请先提交输入法候选，再确认目标目录');
      return;
    }
    // Do not trim: leading/trailing spaces can be part of a remote filename.
    final path = _directory.text;
    if (!path.startsWith('/') || path.contains('\u0000')) {
      setState(() => _error = '请输入远端绝对目录');
      return;
    }
    final target = _target;
    setState(() {
      _busy = true;
      _stop = false;
      _error = null;
    });
    var complete = false;
    try {
      _checkCurrent(target);
      final resolved = await _resolve(target, path);
      if (!mounted || _stop) throw StateError('已停止，未继续提交任务');
      _checkCurrent(target);
      final ids = await widget.model.enqueueRemoteFileSelection(
        _selection,
        target.session,
        resolved,
        target.generation,
        allowMemoryRelay: _allowRelay,
        allowDirect: _allowDirect,
        shouldStop: () => !mounted || _stop,
      );
      _accepted += ids.length;
      complete = true;
    } on RemoteFileSubmissionFailure catch (error) {
      if (mounted) {
        setState(() {
          _accepted += error.acceptedIds.length;
          _selection = error.remaining;
          _error = '仅剩 ${_selection.paths.length} 项未入队：${error.cause}';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (complete && mounted) {
      // Rebuild PopScope before the explicit successful dismissal.
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _stop = true;
    _directory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(_selection.cut ? '移动到…' : '复制到…'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '固定来源：$_sourceLabel',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Text(
                '待提交 ${_selection.paths.length} 项 · 已入队 $_accepted 项',
                key: const ValueKey('remote-destination-count'),
              ),
              for (final path in _selection.paths.take(6))
                Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (_selection.paths.length > 6) const Text('…'),
              const SizedBox(height: 16),
              DropdownButtonFormField<RemoteDestinationTarget>(
                key: const ValueKey('remote-destination-session'),
                initialValue: _target,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '已连接的目标 SSH 会话'),
                items: [
                  for (final target in widget.targets)
                    DropdownMenuItem(
                      value: target,
                      child: Text(
                        target.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (target) {
                        if (target == null) return;
                        setState(() {
                          _target = target;
                          _directory.text = target.initialDirectory;
                          _error = null;
                        });
                      },
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('remote-destination-path'),
                controller: _directory,
                enabled: !_busy,
                maxLines: 2,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: '远端目标目录',
                  helperText: '确认时检查目录；不改变侧栏当前目录',
                ),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                key: const ValueKey('remote-destination-direct-policy'),
                value: _allowDirect,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('优先安全直传（确认 SSH 与 SFTP 路径一致）'),
                subtitle: const Text(
                  '自定义 SFTP 虚拟根与 SSH 路径不对应时请关闭。需要原会话已有明确应用 Agent 授权，不上传私钥。',
                ),
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _allowDirect = value ?? false),
              ),
              CheckboxListTile(
                key: const ValueKey('remote-destination-relay-policy'),
                value: _allowRelay,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('直传不可用时允许通过本机中转'),
                subtitle: const Text(
                  '关闭后仅尝试安全直传；同账户移动仍可直接更名。直传不受本机准确限速，未知写入不自动切换方式。',
                ),
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _allowRelay = value ?? false),
              ),
              Text(
                _selection.cut
                    ? '同账户使用无覆盖更名；跨账户优先使用已授权应用Agent和原目标指纹保护的直传，不可用时允许中转；整树复制确认后再删除来源，未知删除不重发。来源可能被其他程序替换，大小/类型不能证明身份；请确保来源不被修改。暂停/取消不恢复已经删除的来源，目标副本保留；未结束任务会保留来源编辑保护。'
                    : '优先使用已授权应用Agent和原目标指纹保护的服务器直传；不可用时允许本机中转，使用上下行带宽；正文不落本机临时文件。同名按入队时设置处理。',
              ),
              const SizedBox(height: 8),
              const Text('不会修改文件剪贴板。每项独立入队，已接受任务在传输队列管理；停止只阻止后续入队。'),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        if (_busy)
          TextButton(
            onPressed: _stop ? null : () => setState(() => _stop = true),
            child: const Text('停止继续入队'),
          )
        else
          FilledButton(
            onPressed:
                _selection.paths.isEmpty ||
                    (!_allowDirect && !_allowRelay && !_selection.cut)
                ? null
                : _submit,
            child: Text(
              !_allowDirect
                  ? (_allowRelay
                        ? (_selection.cut ? '中转复制后移动' : '仅通过本机中转')
                        : '仅同账户移动')
                  : _allowRelay
                  ? (_selection.cut ? '确认移动并允许跨服中转' : '允许中转并复制')
                  : (_selection.cut ? '仅安全直传并移动' : '仅尝试安全直传'),
            ),
          ),
      ],
    ),
  );
}
