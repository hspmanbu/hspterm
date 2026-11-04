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
}

class NativeHistoryControlsGateway implements HistoryControlsGateway {
  const NativeHistoryControlsGateway(this.model);
  final LiveWorkbenchModel model;
  @override
  Future<HistoryControls> load() => rust.commandHistoryControls();
  @override
  Future<HistoryControls> setEnabled(HistoryControls source, bool value) =>
      model.updateCommandHistory(source, enabled: value);
  @override
  Future<HistoryControls> clear(HistoryControls source, String? hostId) =>
      model.updateCommandHistory(source, clearHostId: hostId);
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
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
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
      final accepted = await showDialog<bool>(
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
