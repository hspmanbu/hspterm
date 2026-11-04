import '../prototype/settings_leave.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../src/rust/shortcut_settings.dart';
import '../terminal/application_keys.dart';
import 'model.dart';

abstract interface class PaletteSettingsGateway {
  Future<PaletteShortcutView> load();
  Future<PaletteShortcutView> save(PaletteShortcutView proposal);
}

class NativePaletteSettingsGateway implements PaletteSettingsGateway {
  const NativePaletteSettingsGateway(this.model);
  final LiveWorkbenchModel model;
  @override
  Future<PaletteShortcutView> load() => model.reloadPaletteShortcut();
  @override
  Future<PaletteShortcutView> save(PaletteShortcutView proposal) =>
      model.savePaletteShortcut(proposal);
}

class PaletteSettingsPanel extends StatefulWidget {
  const PaletteSettingsPanel({super.key, required this.gateway});
  final PaletteSettingsGateway gateway;
  @override
  State<PaletteSettingsPanel> createState() => _PaletteSettingsPanelState();
}

class _PaletteSettingsPanelState extends State<PaletteSettingsPanel> {
  PaletteShortcutView? _source;
  String _key = 'KeyP';
  int _modifiers = 5;
  bool _enabled = true, _application = false, _busy = false, _io = false;
  String? _error, _status;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  void _accept(PaletteShortcutView source) {
    _source = source;
    _key = source.key;
    _modifiers = source.modifiers;
    _enabled = source.enabled;
    _application = source.applicationInTerminal;
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _io = true;
      _source = null;
      _error = null;
      _status = null;
    });
    try {
      final value = await widget.gateway.load();
      if (mounted) setState(() => _accept(value));
    } catch (error) {
      if (mounted) setState(() => _error = '无法读取快捷键：$error。没有用默认值覆盖配置。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  String? get _validation {
    if (_modifiers & 6 == 0) return '请选择 Ctrl 或 Alt，避免拦截普通文字输入。';
    if ((_key == 'F4' && _modifiers & 2 != 0) ||
        (_modifiers == 5 && ['KeyC', 'KeyV', 'KeyT'].contains(_key)) ||
        (_key == 'KeyC' && _modifiers == 4)) {
      return '该组合键已由系统、复制/粘贴或新建标签保留，请另选。';
    }
    return null;
  }

  bool get _dirty {
    final s = _source;
    return s != null &&
        (s.key != _key ||
            s.modifiers != _modifiers ||
            s.enabled != _enabled ||
            s.applicationInTerminal != _application);
  }

  Future<void> _save() async {
    final source = _source;
    if (_busy || source == null || !_dirty) return;
    if (_validation != null) {
      setState(() => _error = _validation);
      return;
    }
    final proposal = PaletteShortcutView(
      vaultScope: source.vaultScope,
      revision: source.revision,
      key: _key,
      modifiers: _modifiers,
      enabled: _enabled,
      applicationInTerminal: _application,
    );
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          scrollable: true,
          title: const Text('保存应用命令面板快捷键？'),
          content: Text(
            '${proposal.enabled ? '启用' : '关闭'}：${_label(proposal.key, proposal.modifiers)}\n${proposal.applicationInTerminal ? '终端内应用优先：这个组合键及其释放将留在本机，不再送给远端 TUI。' : '终端内远端优先：终端焦点下保持原 SSH 键盘协议；使用应用菜单打开面板。'}\n系统及本地文本编辑保留键优先。${proposal.modifiers & 6 == 6 ? '\nCtrl+Alt 在部分键盘布局可能对应 AltGr，请确认不会与输入法冲突。' : ''}',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('palette-confirm-save'),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('保存快捷键'),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) return;
      setState(() => _io = true);
      final saved = await widget.gateway.save(proposal);
      if (mounted) {
        setState(() {
          _accept(saved);
          _status = '已加密保存并应用；没有重新连接 SSH。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          if (error is PaletteShortcutSavedFailure) {
            _accept(error.saved);
            _error = '$error';
          } else {
            _error = '没有保存快捷键：$error。当前选择保留，可重新载入后核对。';
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  String _label(String key, int modifiers) => [
    if (modifiers & 4 != 0) 'Ctrl',
    if (modifiers & 2 != 0) 'Alt',
    if (modifiers & 1 != 0) 'Shift',
    key.replaceFirst(RegExp(r'^(Key|Digit)'), ''),
  ].join('+');
  @override
  Widget build(BuildContext context) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('应用命令面板 · 加密快捷键'),
          const SizedBox(height: 8),
          const Text(
            '默认终端内远端优先。选择应用优先并保存后，只拦截此组合键；其他按键继续使用原终端协议。系统/本地文本编辑保留键不被改写。',
          ),
          if (_io) const LinearProgressIndicator(),
          SwitchListTile(
            key: const ValueKey('palette-binding-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('启用面板快捷键'),
            value: _enabled,
            onChanged: _busy || _source == null
                ? null
                : (v) => setState(() => _enabled = v),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (name, bit) in [('Ctrl', 4), ('Alt', 2), ('Shift', 1)])
                FilterChip(
                  key: ValueKey('palette-mod-$name'),
                  label: Text(name),
                  selected: _modifiers & bit != 0,
                  onSelected: _busy || _source == null
                      ? null
                      : (v) => setState(
                          () => _modifiers = v
                              ? _modifiers | bit
                              : _modifiers & ~bit,
                        ),
                ),
              SizedBox(
                width: 130,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('palette-key-$_key'),
                  initialValue: _key,
                  isExpanded: true,
                  items: [
                    for (final key in PaletteBinding.keys.keys)
                      DropdownMenuItem(
                        key: ValueKey('palette-key-option-$key'),
                        value: key,
                        child: Text(_label(key, 0)),
                      ),
                  ],
                  decoration: const InputDecoration(labelText: '按键'),
                  onChanged: _busy || _source == null
                      ? null
                      : (v) => setState(() => _key = v!),
                ),
              ),
            ],
          ),
          SwitchListTile(
            key: const ValueKey('palette-binding-application'),
            contentPadding: EdgeInsets.zero,
            title: const Text('终端内此组合键应用优先'),
            subtitle: const Text('关闭时保留远端 TUI 优先；面板始终可从应用菜单打开。'),
            value: _application,
            onChanged: _busy || _source == null
                ? null
                : (v) => setState(() => _application = v),
          ),
          if (_error != null)
            Text(
              _error!,
              key: const ValueKey('palette-settings-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_status != null)
            Text(_status!, key: const ValueKey('palette-settings-status')),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const ValueKey('palette-settings-save'),
                onPressed: _busy || !_dirty ? null : _save,
                child: const Text('保存面板快捷键'),
              ),
              TextButton(
                key: const ValueKey('palette-settings-reload'),
                onPressed: _busy ? null : _load,
                child: const Text('重新载入'),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ).guardSettings(
        label: '应用命令面板快捷键',
        dirty: () => _dirty,
        busy: () => _busy && !_io,
      );
}
