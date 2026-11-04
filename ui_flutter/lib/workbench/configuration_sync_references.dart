import 'package:flutter/material.dart';

import 'configuration_sync.dart';
import 'configuration_sync_reference_model.dart';

class ConfigurationSyncReferencesDialog extends StatefulWidget {
  const ConfigurationSyncReferencesDialog({
    super.key,
    required this.controller,
    required this.original,
  });
  final ConfigurationSyncController controller;
  final ConfigurationSyncState original;
  @override
  State<ConfigurationSyncReferencesDialog> createState() =>
      _ConfigurationSyncReferencesDialogState();
}

class _ConfigurationSyncReferencesDialogState
    extends State<ConfigurationSyncReferencesDialog> {
  List<SyncReferenceChoice>? _rows;
  final _selected = <String, String>{};
  bool _loading = true;
  String? _message;
  bool get _valid =>
      widget.controller.available &&
      widget.controller.state?.operation == widget.original.operation &&
      widget.controller.state?.review?.token == widget.original.review?.token;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (!_valid) return;
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final rows = await widget.controller.loadReferenceChoices(
        widget.original,
      );
      if (!mounted || !_valid) return;
      setState(() {
        _rows = rows;
        _selected.clear();
        for (final row in rows) {
          _selected[row.id] = row.winner;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _message = '未能读取原引用选项。两端配置保持原状，请重新读取或取消本次同步。');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _batch(String side) => setState(() {
    for (final row in _rows!) {
      _selected[row.id] =
          (side == 'local' ? row.localAvailable : row.remoteAvailable)
          ? side
          : row.winner;
    }
  });
  Future<void> _resolve() async {
    if (!_valid || _rows == null || _loading || widget.controller.busy) return;
    await widget.controller.resolveReferences(
      widget.original,
      Map.from(_selected),
    );
    if (!mounted) return;
    if (widget.controller.state?.phase == 'review' &&
        widget.controller.state?.review?.token !=
            widget.original.review?.token) {
      Navigator.pop(context);
    } else if (_valid) {
      setState(
        () => _message =
            '当前选择仍不能构成有效配置。请核对分组和跳板依赖；例如恢复被引用的分组，或选择引用有效的主机版本。没有上传或应用本次选择。',
      );
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _valid && !_loading && !widget.controller.busy;
    return AlertDialog(
      title: const Text('解决同步引用冲突'),
      content: SizedBox(
        width: 720,
        height: (MediaQuery.sizeOf(context).height * .58)
            .clamp(160.0, 520.0)
            .toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '最近修改合并产生了无效分组或跳板依赖。选择完整配置单位后重新校验；主机包含其关联认证配置。命令历史继续保留清空与去重合并，不在此覆盖。',
            ),
            const SizedBox(height: 8),
            const Text('“本次提案”含当前操作中已确认的合并选择，不表示已经写入本机。缺失的一端不能被当作删除。'),
            if (!_valid) const Text('原候选已改变或结束，请关闭并重新审阅。'),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_message!),
              ),
            if (_loading) const LinearProgressIndicator(),
            if (_rows != null)
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: enabled ? () => _batch('local') : null,
                    child: const Text('批量选本次提案'),
                  ),
                  TextButton(
                    onPressed: enabled ? () => _batch('remote') : null,
                    child: const Text('批量选云端'),
                  ),
                  Text('${_rows!.length} 个不同单位'),
                ],
              ),
            Expanded(
              child: _rows == null
                  ? Center(
                      child: TextButton(
                        onPressed:
                            !_loading && _valid && !widget.controller.busy
                            ? _load
                            : null,
                        child: const Text('重新读取引用选项'),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _rows!.length,
                      itemBuilder: (context, index) {
                        final row = _rows![index];
                        String dependencies(
                          String side,
                          String? group,
                          String? jump,
                        ) =>
                            '$side：${group == null ? '无主机分组字段' : '分组 $group'}${jump == null ? '' : ' · 跳板 $jump'}';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                row.label,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                row.id,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              if (row.localGroup != null ||
                                  row.localJump != null)
                                Text(
                                  dependencies(
                                    '本次提案',
                                    row.localGroup,
                                    row.localJump,
                                  ),
                                ),
                              if (row.remoteGroup != null ||
                                  row.remoteJump != null)
                                Text(
                                  dependencies(
                                    '云端',
                                    row.remoteGroup,
                                    row.remoteJump,
                                  ),
                                ),
                              DropdownButton<String>(
                                value: _selected[row.id],
                                isExpanded: true,
                                items: [
                                  if (row.localAvailable)
                                    DropdownMenuItem(
                                      value: 'local',
                                      child: Text(
                                        row.localDeleted
                                            ? '本次提案：删除'
                                            : '本次提案：保留完整单位',
                                      ),
                                    ),
                                  if (row.remoteAvailable)
                                    DropdownMenuItem(
                                      value: 'remote',
                                      child: Text(
                                        row.remoteDeleted
                                            ? '云端：删除'
                                            : '云端：保留完整单位',
                                      ),
                                    ),
                                ],
                                onChanged: enabled
                                    ? (side) => setState(
                                        () => _selected[row.id] = side!,
                                      )
                                    : null,
                              ),
                              const Divider(height: 1),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: widget.controller.busy
              ? null
              : () async {
                  if (_valid) await widget.controller.cancel();
                  if (context.mounted) Navigator.pop(context);
                },
          child: const Text('取消本次同步'),
        ),
        FilledButton(
          onPressed: enabled && _rows != null ? _resolve : null,
          child: const Text('校验选择并重新审阅'),
        ),
      ],
    );
  }
}
