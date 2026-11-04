import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'staging_cleanup_port.dart';

Future<void> showStagingCleanup(
  BuildContext context,
  StagingCleanupPort port,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => StagingCleanupDialog(port: port),
);

/// Explicit local inventory first. Only “检查” queries the original destination;
/// no metadata, body, deletion or SSH connection is inferred from selection.
class StagingCleanupDialog extends StatefulWidget {
  const StagingCleanupDialog({super.key, required this.port});
  final StagingCleanupPort port;
  @override
  State<StagingCleanupDialog> createState() => _StagingCleanupDialogState();
}

class _StagingCleanupDialogState extends State<StagingCleanupDialog> {
  List<Map<String, dynamic>> _tasks = [], _entries = [];
  Map<String, dynamic>? _task, _review;
  final _taskBack = <int>[], _entryBack = <int>[];
  int _taskOffset = 0, _entryOffset = 0;
  int? _taskNext, _entryNext;
  bool _busy = false, _unconfirmed = false, _consent = false;
  bool _awaitingConsent = false;
  String? _error, _message;
  List<Map<String, dynamic>> _items(Map<String, dynamic> page) =>
      (page['items'] as List).cast<Map<String, dynamic>>();

  @override
  void initState() {
    super.initState();
    unawaited(_run(_loadTasks));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _error = error is StateError ? error.message : '$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadTasks() async {
    final page = await widget.port.stagingTasks(_taskOffset);
    if (!mounted) return;
    setState(() {
      _tasks = _items(page);
      _taskNext = page['next'] as int?;
    });
  }

  Future<void> _loadEntries() async {
    final task = _task!;
    _review = null;
    _consent = false;
    final page = await widget.port.stagingInventory(
      task['id'] as String,
      _entryOffset,
    );
    if (!mounted) return;
    setState(() {
      _entries = _items(page);
      _entryNext = page['next'] as int?;
      _unconfirmed = page['unconfirmed'] as bool;
    });
  }

  Future<void> _inspect(Map<String, dynamic> entry) async {
    _review = null;
    _consent = false;
    final review = await widget.port.prepareStaging(
      _task!['id'] as String,
      _task!['host'] as String,
      entry['index'] as int,
    );
    if (mounted) setState(() => _review = review);
  }

  Future<void> _apply() async {
    final review = _review!;
    // Consume the local button state before the RPC. Errors require a fresh
    // inspection; never replay a request whose REMOVE ACK may have been lost.
    setState(() => _review = null);
    await widget.port.applyStaging(
      _task!['id'] as String,
      _task!['host'] as String,
      review['ticket'] as String,
      _consent,
    );
    await _loadEntries();
    if (mounted) setState(() => _message = '本次清理已确认；原始来源与最终目标未被删除。');
  }

  Future<void> _end() async {
    final task = _task!;
    final review = await widget.port.prepareStagingEnd(task['id'] as String);
    if (!mounted) return;
    final confirmed = await _confirmLocalEnd(review);
    if (confirmed != true || !mounted) return;
    await widget.port.endStagingWait(
      task['id'] as String,
      review['ticket'] as String,
    );
    await _loadEntries();
  }

  Future<bool> _confirmLocalEnd(Map<String, dynamic> review) async {
    setState(() => _awaitingConsent = true);
    try {
      return await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('仅结束本机等待'),
              content: SingleChildScrollView(
                child: Text(
                  '旧删除请求仍可能在服务器执行。本操作不判定删除成功、不撤销请求、不再次发送删除。'
                  '原暂存引用将保留；旧任务禁止续传，复制必须新建任务以使用新的随机路径。\n\n'
                  '${jsonEncode(review['path'])}',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('确认结束等待'),
                ),
              ],
            ),
          ) ==
          true;
    } finally {
      if (mounted) setState(() => _awaitingConsent = false);
    }
  }

  Widget _navigation(bool tasks) {
    final back = tasks ? _taskBack : _entryBack;
    final next = tasks ? _taskNext : _entryNext;
    return Row(
      children: [
        TextButton(
          onPressed: _busy || back.isEmpty
              ? null
              : () => unawaited(
                  _run(() async {
                    final previous = back.removeLast();
                    if (tasks) {
                      _taskOffset = previous;
                      await _loadTasks();
                    } else {
                      _entryOffset = previous;
                      await _loadEntries();
                    }
                  }),
                ),
          child: const Text('上一页'),
        ),
        TextButton(
          onPressed: _busy || next == null
              ? null
              : () => unawaited(
                  _run(() async {
                    back.add(tasks ? _taskOffset : _entryOffset);
                    if (tasks) {
                      _taskOffset = next;
                      await _loadTasks();
                    } else {
                      _entryOffset = next;
                      await _loadEntries();
                    }
                  }),
                ),
          child: const Text('下一页'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final review = _review;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('远端暂存清理'),
        content: SizedBox(
          width: 680,
          height: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '仅清理本机加密日志中记录的私有暂存路径；不删除原始来源或最终目标。'
                  '路径以带转义的文字显示。不会自动连接SSH。',
                ),
                if (_task == null) ...[
                  _navigation(true),
                  SizedBox(
                    height: 200,
                    child: ListView(
                      children: [
                        if (_tasks.isEmpty) const Text('本页没有可清理暂存；可翻页或刷新。'),
                        for (final task in _tasks)
                          ListTile(
                            dense: true,
                            title: Text(jsonEncode(task['name'])),
                            subtitle: Text('目标主机：${task['host']}'),
                            trailing: Text(
                              task['busy'] == true ? '正在工作' : '查看清单',
                            ),
                            onTap: _busy || task['busy'] == true
                                ? null
                                : () => unawaited(
                                    _run(() async {
                                      setState(() {
                                        _task = task;
                                        _entries = [];
                                        _entryOffset = 0;
                                        _entryBack.clear();
                                        _entryNext = null;
                                      });
                                      await _loadEntries();
                                    }),
                                  ),
                          ),
                      ],
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _task = null;
                                _review = null;
                                _entries = [];
                                _unconfirmed = false;
                              }),
                        child: const Text('返回任务'),
                      ),
                      Expanded(
                        child: Text(
                          jsonEncode(_task!['name']),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_unconfirmed)
                        TextButton(
                          onPressed: _busy ? null : () => unawaited(_run(_end)),
                          child: const Text('结束本机等待…'),
                        ),
                    ],
                  ),
                  if (_unconfirmed)
                    const Text('上次删除结果未确认，禁止盲目重发。可先明确结束本机等待，再重新检查。'),
                  _navigation(false),
                  SizedBox(
                    height: 200,
                    child: ListView(
                      children: [
                        if (_entries.isEmpty) const Text('本页没有待清理引用。'),
                        for (final entry in _entries)
                          ListTile(
                            dense: true,
                            title: Text(jsonEncode(entry['path'])),
                            subtitle: Text(
                              '${entry['phase']} · 确认传输 ${entry['bytes']} 字节',
                            ),
                            trailing: TextButton(
                              onPressed: _busy || _unconfirmed
                                  ? null
                                  : () =>
                                        unawaited(_run(() => _inspect(entry))),
                              child: const Text('检查'),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (review != null) ...[
                    SelectableText(jsonEncode(review['path'])),
                    Text(
                      review['missing'] == true
                          ? '当前路径不存在：只退休本机引用，不判定旧请求成功。'
                          : '当前普通私有文件 ${review['bytes']} 字节。大小和权限不能证明文件身份；服务器可在检查后改变路径。',
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _consent,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _consent = v ?? false),
                      title: Text(
                        review['uncertain'] == true
                            ? '我确认处理未知创建/发布/删除状态；旧请求可能迟到，旧任务将禁止续传，后续复制需新建任务。'
                            : '我确认只处理此确切暂存路径，并了解路径可能已被其他进程替换。',
                      ),
                    ),
                    FilledButton(
                      onPressed: _busy || !_consent
                          ? null
                          : () => unawaited(_run(_apply)),
                      child: Text(
                        review['missing'] == true ? '确认退休缺失引用' : '确认删除此暂存文件',
                      ),
                    ),
                  ],
                ],
                if (_busy && !_awaitingConsent) const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_message != null) Text(_message!),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy
                ? null
                : () => unawaited(
                    _run(_task == null ? _loadTasks : _loadEntries),
                  ),
            child: const Text('刷新'),
          ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
