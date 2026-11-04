import '../prototype/settings_leave.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../terminal/typography.dart';
import '../terminal/font_licenses.dart';
import 'typography_store.dart';

class TypographySettingsPanel extends StatefulWidget {
  const TypographySettingsPanel({
    super.key,
    required this.controller,
    this.hostId,
    this.hostLabel,
  });
  final TerminalTypographyController controller;
  final String? hostId, hostLabel;
  @override
  State<TypographySettingsPanel> createState() =>
      _TypographySettingsPanelState();
}

class _TypographySettingsPanelState extends State<TypographySettingsPanel> {
  TypographySnapshot? _source;
  TerminalTypography _draft = const TerminalTypography();
  List<String> _systems = const [];
  bool _working = false;
  bool _inherit = false;
  String? _error, _status, _systemError;
  TerminalTypographyController get c => widget.controller;
  bool get _busy => _working || c.busy;
  bool get _host => widget.hostId != null;
  bool get _editable => !_busy && _source != null && (!_host || !_inherit);
  bool get _dirty {
    final source = _source;
    if (source == null) return false;
    if (!_host) return source.settings != _draft;
    final previous = source.hosts[widget.hostId];
    return _inherit ? previous != null : previous != _draft;
  }

  @override
  void initState() {
    super.initState();
    registerTerminalFontLicenses();
    c.addListener(_changed);
    if (c.snapshot != null) _accept(c.snapshot!);
    unawaited(_systemsLoad());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _source == null && !c.busy) unawaited(_load());
    });
  }

  void _changed() {
    if (mounted) {
      setState(() {
        if (_source == null && !c.busy && c.snapshot != null) {
          _accept(c.snapshot!);
        }
      });
    }
  }

  void _accept(TypographySnapshot source) {
    _source = source;
    _draft = source.hosts[widget.hostId] ?? source.settings;
    _inherit = _host && !source.hosts.containsKey(widget.hostId);
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  Future<void> _systemsLoad() async {
    try {
      final names = await c.gateway.systemFamilies();
      if (mounted) {
        setState(() {
          _systems = names;
          _systemError = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _systemError = '系统字体列表暂不可用，仍可选择内置或已导入字体。');
    }
  }

  Future<void> _perform(
    Future<TypographySnapshot> Function() operation,
    String success,
  ) async {
    if (_busy) return;
    setState(() {
      _working = true;
      _error = null;
      _status = null;
    });
    try {
      final result = await operation();
      if (mounted) {
        setState(() {
          _accept(result);
          _status = success;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error。没有重新连接 SSH。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          scrollable: true,
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ==
      true;
  Future<void> _load() async {
    if (_busy) return;
    if (_dirty && !await _confirm('重新载入字体设置？', '将放弃此表单尚未保存的字体与排版选择。')) return;
    if (!mounted) return;
    setState(() => _source = null);
    await _perform(c.load, '已载入原配置。');
  }

  Future<void> _choose(String choice) async {
    final source = _source;
    if (_busy || source == null) return;
    final colon = choice.indexOf(':');
    final selected = _draft.copyWith(
      kind: choice.substring(0, colon),
      family: choice.substring(colon + 1),
    );
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await c.loader.ensure(c.gateway, source, selected);
      if (mounted) setState(() => _draft = selected);
    } catch (error) {
      if (mounted) setState(() => _error = '无法载入字体：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _import() async {
    final source = _source;
    if (_busy || source == null || _dirty) return;
    setState(() {
      _working = true;
      _error = null;
      _status = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'TTF / OTF 字体', extensions: ['ttf', 'otf']),
        ],
      );
      if (!mounted || file == null) return;
      if (await file.length() > terminalFontLimit) {
        throw StateError('单份字体不能超过32MiB');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final block in file.openRead(0, terminalFontLimit + 1)) {
        if (bytes.length + block.length > terminalFontLimit) {
          throw StateError('单份字体不能超过32MiB');
        }
        bytes.add(block);
      }
      if (!mounted) return;
      final result = await c.importFont(
        file.name,
        bytes.takeBytes(),
        expected: source,
      );
      if (mounted) {
        setState(() {
          _accept(result);
          _status = '字体已保存到本机加密库；请选择字体并保存设置后应用。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '字体导入未完成：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _remove(ImportedTerminalFont font) async {
    final source = _source;
    if (_busy || source == null || _dirty) return;
    setState(() => _working = true);
    try {
      if (!await _confirm(
        '删除本机导入字体？',
        '${font.label}\n原始字体文件不会删除。全局和所有主机覆盖中使用此字体的设置将恢复内置 JetBrains Mono，其他排版参数保持。若全局正在使用此字体，通用内置字体预设也会恢复 JetBrains Mono，并参加已配置的加密同步。',
      )) {
        return;
      }
      if (!mounted) return;
      final result = await c.removeFont(font.id, expected: source);
      if (mounted) {
        setState(() {
          _accept(result);
          _error = null;
          _status = '已删除本机字体副本；没有改动原始文件。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '没有删除字体：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _number(
    String name,
    double value,
    double min,
    double max,
    ValueChanged<double> change,
  ) => SizedBox(
    width: 160,
    child: DropdownButtonFormField<double>(
      key: ValueKey('typography-$name-$value'),
      isExpanded: true,
      initialValue: value,
      decoration: InputDecoration(labelText: name),
      items: [
        for (final v in <double>{
          value,
          for (double v = min; v <= max + .001; v += name == '行高' ? .1 : 1)
            double.parse(v.toStringAsFixed(2)),
        }.toList()..sort())
          DropdownMenuItem(
            value: v,
            child: Text(
              name == '行高'
                  ? '${v.toStringAsFixed(1)} 倍'
                  : '${v.toStringAsFixed(0)} px',
            ),
          ),
      ],
      onChanged: !_editable
          ? null
          : (v) {
              if (v != null) setState(() => change(v));
            },
    ),
  );
  @override
  Widget build(BuildContext context) {
    final choices = <String, String>{
      'builtin:JetBrainsMono': '内置 · JetBrains Mono',
      'builtin:NotoSansCJK': '内置 · Noto Sans CJK',
      'builtin:JetBrainsMonoNerd': '内置 · JetBrains Mono + Nerd 符号（许可子集）',
      for (final name in _systems) 'system:$name': '系统 · $name',
      for (final font in _source?.fonts ?? <ImportedTerminalFont>[])
        'imported:${font.id}': '导入 · ${font.label}',
    };
    final selected = '${_draft.kind}:${_draft.family}';
    choices.putIfAbsent(selected, () => '已保存 · ${_draft.family}（本机可能缺失）');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('终端字体与排版 · 本机加密保存'),
        if (_host) ...[
          Text('主机：${widget.hostLabel ?? widget.hostId}'),
          SwitchListTile(
            key: const ValueKey('typography-inherit'),
            contentPadding: EdgeInsets.zero,
            title: const Text('继承全局字体与排版'),
            subtitle: const Text('仅作用于该主机；保存后应用，不重新建立 SSH 连接。'),
            value: _inherit,
            onChanged: _busy || _source == null
                ? null
                : (v) => setState(() {
                    _inherit = v;
                    if (v) _draft = _source!.settings;
                  }),
          ),
        ],
        const SizedBox(height: 8),
        const Text(
          '使用系统字体或导入的 TTF / OTF。字符仍按终端网格定位；非等宽字体可能被裁切。字体文件与本机字体映射不参与云同步。',
        ),
        if (!_host)
          const Text(
            '内置字体选择、全局字号、行高、内边距与连字作为通用终端偏好参加已配置的加密同步。系统/导入字体映射和主机本机覆盖独立保存。',
          ),
        const Text(
          'Nerd 候选含 Devicon、Octicons、Seti、Powerline 和 Powerline Extra 的 1111 个已许可字形；其他 Nerd 图标仍可通过明确导入字体使用。',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () =>
                showLicensePage(context: context, applicationName: 'HSPTerm'),
            child: const Text('查看字体及组件许可'),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('typography-family-$selected'),
          initialValue: selected,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '字体'),
          items: [
            for (final entry in choices.entries)
              DropdownMenuItem(
                value: entry.key,
                child: Text(entry.value, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: !_editable
              ? null
              : (v) {
                  if (v != null) unawaited(_choose(v));
                },
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _number(
              '字号',
              _draft.size,
              9,
              36,
              (v) => _draft = _draft.copyWith(size: v),
            ),
            _number(
              '行高',
              _draft.lineHeight,
              1,
              2,
              (v) => _draft = _draft.copyWith(lineHeight: v),
            ),
            _number(
              '内边距',
              _draft.padding,
              0,
              32,
              (v) => _draft = _draft.copyWith(padding: v),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('编程连字'),
          subtitle: const Text('默认关闭；仅在整段字形宽度与网格吻合时使用连字。'),
          value: _draft.ligatures,
          onChanged: !_editable
              ? null
              : (v) => setState(() => _draft = _draft.copyWith(ligatures: v)),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Text(
            'SSH 0123456789 => != [] {}\n中文 e\u0301 ┌─┐ 😀',
            style: _draft.textStyle(),
          ),
        ),
        if (_systemError != null) Text(_systemError!),
        if (_error != null)
          Text(
            _error!,
            key: const ValueKey('typography-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_status != null)
          Text(_status!, key: const ValueKey('typography-status')),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              key: const ValueKey('typography-save'),
              onPressed: _busy || !_dirty
                  ? null
                  : () {
                      final draft = _draft, source = _source!;
                      unawaited(
                        _perform(
                          () => _host
                              ? c.saveHost(
                                  widget.hostId!,
                                  _inherit ? null : draft,
                                  expected: source,
                                )
                              : c.save(draft, expected: source),
                          '已加密保存并应用到终端；SSH 会话保持。',
                        ),
                      );
                    },
              child: const Text('保存字体与排版'),
            ),
            TextButton(
              key: const ValueKey('typography-reload'),
              onPressed: _busy ? null : _load,
              child: const Text('重新载入'),
            ),
            if (!_host)
              OutlinedButton.icon(
                key: const ValueKey('typography-import'),
                onPressed: _busy || _source == null || _dirty ? null : _import,
                icon: const Icon(Icons.upload_file, size: 16),
                label: const Text('导入 TTF / OTF'),
              ),
          ],
        ),
        if (!_host && _dirty) const Text('请先保存或重新载入未提交的排版选择，再导入或删除字体。'),
        if (_host)
          const Text('可选择已有本机字体；导入或删除字体请使用全局字体设置。此覆盖不参与云同步，完整加密备份包含它。'),
        for (final font
            in _host
                ? <ImportedTerminalFont>[]
                : _source?.fonts ?? <ImportedTerminalFont>[])
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(font.label, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${(font.bytes / 1024).toStringAsFixed(0)} KiB · 本机字体',
            ),
            trailing: IconButton(
              tooltip: '删除本机字体副本',
              onPressed: _busy || _dirty ? null : () => _remove(font),
              icon: const Icon(Icons.delete_outline, size: 18),
            ),
          ),
        const SizedBox(height: 16),
      ],
    ).guardSettings(
      label: '终端字体与排版',
      dirty: () => _dirty,
      busy: () => _working,
    );
  }
}
