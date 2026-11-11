import '../prototype/design.dart';
import '../prototype/settings_style.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import '../prototype/settings_leave.dart';
import '../src/rust/history_controls.dart';
import 'model.dart';

abstract interface class HistoryControlsGateway {
  Future<HistoryControls> load();
  Future<HistoryControls> setEnabled(HistoryControls source, bool value);
  Future<HistoryControls> clear(HistoryControls source, String? hostId);
  Future<List<rust.CommandSearchRow>> searchCommands(
    String query,
    String? hostId,
  );
  Future<int> deleteCommands(List<String> texts, String? hostId);
}

class NativeHistoryControlsGateway implements HistoryControlsGateway {
  NativeHistoryControlsGateway(this.model);
  String? _scope;
  final LiveWorkbenchModel model;
  @override
  Future<HistoryControls> load() async {
    final value = await model.runLocalSettings(
      rust.commandHistoryControls,
      reportFailure: false,
    );
    _scope = value.vaultScope;
    return value;
  }

  @override
  Future<HistoryControls> setEnabled(HistoryControls source, bool value) =>
      model.updateCommandHistory(source, enabled: value);
  @override
  Future<HistoryControls> clear(HistoryControls source, String? hostId) =>
      model.updateCommandHistory(source, clearHostId: hostId);
  @override
  Future<List<rust.CommandSearchRow>> searchCommands(
    String query,
    String? hostId,
  ) {
    if (_scope == null) return Future.error(StateError('请先读取历史设置'));
    return model.runLocalSettings(
      () => rust.searchCommandHistory(
        query: query,
        hostId: hostId,
        limit: 100,
        expectedVaultScope: _scope,
      ),
      reportFailure: false,
    );
  }

  @override
  Future<int> deleteCommands(List<String> texts, String? hostId) {
    if (_scope == null) return Future.error(StateError('请先读取历史设置'));
    return model.runLocalSettings(
      () => rust.deleteCommandHistory(
        texts: texts,
        hostId: hostId,
        expectedVaultScope: _scope,
      ),
      reportFailure: false,
    );
  }
}

/// Metadata only: command contents are never requested or shown here.
class HistoryControlsPanel extends StatefulWidget {
  const HistoryControlsPanel({super.key, required this.gateway});
  final HistoryControlsGateway gateway;
  @override
  State<HistoryControlsPanel> createState() => _HistoryControlsPanelState();
}

class _HistoryControlsPanelState extends State<HistoryControlsPanel> {
  HistoryControls? _view;
  bool _enabled = true, _busy = false, _committing = false;
  String? _error, _status;
  final _search = TextEditingController();

  // Round-12 saved-command manager: decrypted plaintext exists only while
  // this panel is open; controllers/results are disposed with it.
  final _commandSearch = TextEditingController();
  String? _commandHostFilter;
  Timer? _commandDebounce;
  List<rust.CommandSearchRow> _commandResults = const [];
  final _commandSelected = <(String, String)>{};
  bool _commandActive = true;

  void _discardCommands() {
    _commandEpoch++;
    _commandDebounce?.cancel();
    _commandSearch.clear();
    _commandResults = const [];
    _commandSelected.clear();
    _commandLoading = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (_commandActive && !active) _discardCommands();
    _commandActive = active;
  }

  bool _commandLoading = false;
  int _commandEpoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _discardCommands();
    _commandSearch.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _committing = true;
      _view = null;
      _error = null;
      _status = null;
    });
    try {
      final view = await widget.gateway.load();
      if (mounted) {
        setState(() {
          _view = view;
          _enabled = view.enabled;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '无法读取历史设置：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  Future<void> _save() async {
    final source = _view, value = _enabled;
    if (_busy || source == null || source.enabled == value) return;
    setState(() {
      _busy = true;
      _committing = true;
      _error = null;
      _status = null;
    });
    try {
      final saved = await widget.gateway.setEnabled(source, value);
      if (mounted) {
        setState(() {
          _view = saved;
          _enabled = saved.enabled;
          _status = '已加密保存。关闭记录不会删除已有历史。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '未保存历史设置：$error。当前选择仍保留，请核对或重新载入。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  Future<void> _clear(HistoryHostCount? host) async {
    final source = _view;
    if (_busy || source == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final accepted = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(host == null ? '清空全部命令历史？' : '清空此主机命令历史？'),
          content: Text(
            '${host == null ? '全部主机（包括已删除主机）' : host.name}\n本机现有 ${host?.count ?? source.total} 条。清除后无法撤销；不会清空终端画面或滚动历史。清除标记会用于防止旧同步记录复活，即使当前记录为空也会保存标记。\n\n本次仅清除历史，不保存尚未提交的记录开关。',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('history-confirm-clear'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认清空'),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true || !identical(source, _view)) return;
      setState(() => _committing = true);
      final saved = await widget.gateway.clear(source, host?.id);
      if (mounted) {
        setState(() {
          _view = saved;
          _status = '已清空所选历史并加密保存清除标记；未改动终端滚动历史。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '未清空历史：$error。没有自动重试，请重新载入后核对。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _committing = false;
        });
      }
    }
  }

  Future<void> _searchCommands() async {
    if (!_commandActive || !mounted) return;
    final epoch = ++_commandEpoch;
    setState(() => _commandLoading = true);
    try {
      final results = await widget.gateway.searchCommands(
        _commandSearch.text,
        _commandHostFilter,
      );
      if (mounted && _commandActive && epoch == _commandEpoch) {
        setState(() {
          _commandResults = results;
          _commandSelected.removeWhere(
            (key) => !results.any((row) => (row.hostId, row.text) == key),
          );
        });
      }
    } catch (_) {
      // Public summary only; the query and results never reach the log.
      if (mounted && _commandActive && epoch == _commandEpoch) {
        setState(() => _commandResults = const []);
      }
    } finally {
      if (mounted && _commandActive && epoch == _commandEpoch) {
        setState(() => _commandLoading = false);
      }
    }
  }

  Future<void> _deleteCommands(List<(String, String)> rows) async {
    if (rows.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      var deleted = 0;
      final grouped = <String, List<String>>{};
      for (final row in rows) {
        (grouped[row.$1] ??= []).add(row.$2);
      }
      for (final group in grouped.entries) {
        for (var offset = 0; offset < group.value.length; offset += 32) {
          deleted += await widget.gateway.deleteCommands(
            group.value.skip(offset).take(32).toList(),
            group.key,
          );
        }
      }
      if (mounted) {
        setState(() {
          _status = '已删除 $deleted 条并加密保存删除标记；其他设备的旧同步记录也不会复活。';
        });
      }
      await _searchCommands();
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '删除未完成：$error。记录仍保留，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _view;
    final query = _search.text.toLowerCase();
    final hosts =
        source?.hosts
            .where((h) => h.name.toLowerCase().contains(query))
            .toList() ??
        <HistoryHostCount>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('合格单行命令历史 · 加密管理'),
        const SizedBox(height: 8),
        const Text(
          '命令可能包含敏感信息，可关闭记录或清空历史。历史按保存主机隔离，仅在已启用配置同步时参与端到端加密同步；本页不读取或显示命令正文。',
        ),
        const SizedBox(height: 8),
        const Text(
          '需在对应主机中主动启用可选 Bash 集成；仅在可确认的普通单行输入状态下记录和联想。不读取远端历史，不抓取屏幕、隐藏输入或 TUI 内容。',
          style: TextStyle(fontSize: 12),
        ),
        if (_committing) const LinearProgressIndicator(),
        CompactSettingsToggle(
          child: SwitchListTile(
            key: const ValueKey('history-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('允许记录合格单行命令'),
            subtitle: const Text('关闭后停止记录与建议，已有加密历史保留。'),
            value: _enabled,
            onChanged: _busy || source == null
                ? null
                : (value) => setState(() => _enabled = value),
          ),
        ),
        if (_error != null)
          Text(
            _error!,
            key: const ValueKey('history-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_status != null)
          Text(_status!, key: const ValueKey('history-status')),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Visibility(
              visible: SettingsLeaveScope.of(context) == null,
              child: FilledButton(
                key: const ValueKey('history-save'),
                onPressed: _busy || source == null || source.enabled == _enabled
                    ? null
                    : _save,
                child: const Text('保存历史设置'),
              ),
            ),
            TextButton(
              key: const ValueKey('history-reload'),
              onPressed: _busy ? null : _load,
              child: const Text('重新载入'),
            ),
            OutlinedButton(
              key: const ValueKey('history-clear-all'),
              onPressed: _busy || source == null ? null : () => _clear(null),
              child: Text('清空全部历史（${source?.total ?? 0}）'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (source != null) ...[
          SettingsField(
            child: TextField(
              key: const ValueKey('history-host-search'),
              controller: _search,
              enabled: !_busy,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: '查找保存的主机',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 220,
            child: ListView.builder(
              itemCount: hosts.length,
              itemBuilder: (_, i) {
                final h = hosts[i];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    h.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${h.count} 条已保存历史'),
                  trailing: TextButton(
                    key: ValueKey('history-clear-${h.id}'),
                    onPressed: _busy ? null : () => _clear(h),
                    child: const Text('清空'),
                  ),
                );
              },
            ),
          ),
        ],
        const Divider(height: 32),
        const Text('管理已保存命令'),
        const SizedBox(height: 8),
        const Text(
          '搜索并删除具体命令记录。删除会写入防复活标记：其他设备的旧同步数据不会把命令带回来；重新执行同一命令会形成新的正常记录。命令正文仅在本页打开时解密读取，不写入日志。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        SettingsField(
          child: TextField(
            key: const ValueKey('history-command-search'),
            controller: _commandSearch,
            enabled: !_busy,
            onChanged: (_) {
              _commandDebounce?.cancel();
              _commandDebounce = Timer(
                const Duration(milliseconds: 300),
                () => _searchCommands(),
              );
            },
            decoration: const InputDecoration(
              labelText: '搜索命令正文（全部主机，不区分大小写）',
              prefixIcon: Icon(Icons.manage_search, size: 18),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<String?>(
              key: const ValueKey('history-command-host-filter'),
              value: _commandHostFilter,
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('全部主机'),
                ),
                ...?source?.hosts.map(
                  (h) => DropdownMenuItem<String?>(
                    value: h.id,
                    child: Text(h.name),
                  ),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(() => _commandHostFilter = value);
                      _searchCommands();
                    },
            ),
            if (_commandLoading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            TextButton(
              key: const ValueKey('history-command-search-run'),
              onPressed: _busy ? null : _searchCommands,
              child: const Text('搜索'),
            ),
            FilledButton.tonal(
              key: const ValueKey('history-command-delete-selected'),
              onPressed: _busy || _commandSelected.isEmpty
                  ? null
                  : () => _deleteCommands(_commandSelected.toList()),
              child: Text('删除所选（${_commandSelected.length}）'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_commandResults.isEmpty)
          const Text(
            '输入关键词后搜索；无结果显示为空。',
            key: ValueKey('history-command-empty'),
            style: TextStyle(fontSize: 12),
          )
        else
          SizedBox(
            height: 240,
            child: ListView.builder(
              key: const ValueKey('history-command-results'),
              itemCount: _commandResults.length,
              itemBuilder: (_, i) {
                final row = _commandResults[i];
                final hostName =
                    source?.hosts
                        .where((h) => h.id == row.hostId)
                        .firstOrNull
                        ?.name ??
                    row.hostId;
                return CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  key: ValueKey('history-command-row-$i'),
                  value: _commandSelected.contains((row.hostId, row.text)),
                  onChanged: _busy
                      ? null
                      : (checked) => setState(() {
                          if (checked == true) {
                            _commandSelected.add((row.hostId, row.text));
                          } else {
                            _commandSelected.remove((row.hostId, row.text));
                          }
                        }),
                  title: Text(
                    row.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  subtitle: Text('$hostName · 使用序号 ${row.usedCounter}'),
                  secondary: IconButton(
                    tooltip: '删除该命令记录',
                    onPressed: _busy
                        ? null
                        : () => _deleteCommands([(row.hostId, row.text)]),
                    icon: const Icon(Icons.delete_outline, size: 18),
                  ),
                );
              },
            ),
          ),
      ],
    ).guardSettings(
      confirmed: () => _view != null && _error == null,
      apply: _save,
      label: '历史命令记录设置',
      dirty: () => _view != null && _enabled != _view!.enabled,
      busy: () => _committing && _view != null,
    );
  }
}
