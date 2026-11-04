import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';

import '../src/rust/remote_transfers.dart';
import '../src/rust/transfers.dart';
import 'model.dart';

Future<void> showMoveResolution(
  BuildContext context,
  LiveWorkbenchModel model,
  TransferTaskView task,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => MoveResolutionDialog(model: model, task: task),
);

class MoveResolutionDialog extends StatefulWidget {
  const MoveResolutionDialog({
    super.key,
    required this.model,
    required this.task,
  });
  final LiveWorkbenchModel model;
  final TransferTaskView task;
  @override
  State<MoveResolutionDialog> createState() => _MoveResolutionDialogState();
}

class _MoveResolutionDialogState extends State<MoveResolutionDialog> {
  RemoteMoveInspection? _inspection;
  RemoteMoveEndReview? _review;
  int _inspectionEpoch = 0;
  String? _error;
  bool _preparing = false, _reading = false, _saving = false;
  String _message(Object error) =>
      error is StateError ? error.message : '$error';
  @override
  void initState() {
    super.initState();
    unawaited(_reviewAndInspect());
  }

  Future<void> _reviewAndInspect() async {
    if (_preparing || _reading || _saving) return;
    setState(() {
      _preparing = true;
      _review = null;
      _inspection = null;
      _error = null;
    });
    try {
      final review = await widget.model.prepareRemoteMoveEnd(widget.task);
      if (mounted) setState(() => _review = review);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
    if (mounted && _review != null && !_saving) await _inspect();
  }

  Future<void> _inspect() async {
    if (_reading || _saving) return;
    final epoch = ++_inspectionEpoch;
    bool current() => mounted && epoch == _inspectionEpoch;
    setState(() {
      _reading = true;
      _inspection = null;
      _error = null;
    });
    try {
      final result = await widget.model.inspectRemoteMove(widget.task);
      if (current()) setState(() => _inspection = result);
    } catch (error) {
      if (current()) {
        setState(() => _error = '当前无法核对远端路径：${_message(error)}。仍可仅结束本机等待。');
      }
    } finally {
      if (current()) setState(() => _reading = false);
    }
  }

  Future<void> _end() async {
    final review = _review;
    if (review == null || _preparing || _saving) return;
    // Ending is independent of the optional metadata query. Its late response
    // must not replace a transaction error or update a closing route.
    _inspectionEpoch++;
    setState(() {
      _saving = true;
      _reading = false;
      _error = null;
    });
    var ended = false;
    try {
      await widget.model.endRemoteMoveWait(widget.task, review.ticket);
      ended = true;
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (ended && mounted) {
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    }
  }

  String _kind(String value, int? size) {
    final label = switch (value) {
      'File' => '普通文件',
      'Directory' => '目录',
      'Symlink' => '符号链接（未跟随）',
      'Missing' => '当前路径不存在',
      'Unavailable' => '当前属性无法读取',
      _ => '其他文件类型',
    };
    return '$label${size == null ? '' : ' · $size 字节（元数据）'}';
  }

  Widget _entry(String label, String path, String? kind, int? size) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        SelectableText(jsonEncode(path)),
        if (kind != null) Text(_kind(kind, size)) else const Text('尚未核对当前远端属性'),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final snapshot = _inspection, review = _review;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(
          widget.task.remoteOperation == 'relocate' ? '检查未确认的来源删除' : '检查未确认移动',
        ),
        content: SizedBox(
          width: 620,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.task.remoteOperation == 'relocate'
                      ? '原来源删除请求可能已执行，或仍在服务器处理中。目标副本已经确认；当前缺失/同大小不能证明旧来源身份或原删除结果，不会重发删除。'
                      : '原更名请求可能已执行，或仍在服务器处理中。当前路径元数据不能证明原文件身份或更名结果，即使两个文件大小相同也不能判定。',
                ),
                if (review != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectableText(review.account),
                  ),
                if (review != null)
                  SelectableText(
                    '原记录主机指纹：${review.fingerprint}',
                    style: const TextStyle(fontSize: 11),
                  ),
                _entry(
                  '原源路径',
                  review?.sourcePath ?? widget.task.sourceRemote!,
                  snapshot?.sourceKind,
                  snapshot?.sourceSize,
                ),
                _entry(
                  '原目标路径',
                  review?.destinationPath ?? widget.task.remote,
                  snapshot?.destinationKind,
                  snapshot?.destinationSize,
                ),
                const SizedBox(height: 8),
                const Text(
                  '结束本机等待不会撤销已发出的服务器请求，也不能保证原请求已停止处理。本动作不会再发送更名、写入或删除，也不记作服务器确认成功。原请求记录保留在本机加密日志；后续文件操作需重新明确发起。',
                ),
                if (_preparing || _reading || _saving)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: LinearProgressIndicator(),
                  ),
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
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: _preparing || _reading || _saving
                ? null
                : _reviewAndInspect,
            child: const Text('重新检查'),
          ),
          FilledButton(
            onPressed: review == null || _preparing || _saving ? null : _end,
            child: const Text('结束本机等待'),
          ),
        ],
      ),
    );
  }
}
