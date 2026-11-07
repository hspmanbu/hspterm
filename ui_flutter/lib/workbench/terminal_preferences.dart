import '../prototype/settings_style.dart';
import '../prototype/settings_leave.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import 'model.dart';
import '../terminal/notifications.dart';
import '../terminal/typography.dart';
import 'notification_settings.dart';

class TerminalPreferencesValue {
  TerminalPreferencesValue({
    required this.historyLines,
    required this.shape,
    required this.blink,
    required this.osc52,
    required this.rightPaste,
    this.copySelection = false,
    this.pastePaths = true,
    required this.foreground,
    required this.background,
    required this.cursor,
    required List<int> ansi,
    this.notifications = const TerminalNotificationSettings(),
    Map<String, dynamic>? typography,
  }) : ansi = List.unmodifiable(ansi),
       typography = typography == null ? null : Map.unmodifiable(typography);
  final int historyLines, foreground, background, cursor;
  final String shape;
  final bool blink, osc52, rightPaste, copySelection, pastePaths;
  final List<int> ansi;
  final TerminalNotificationSettings notifications;

  /// Portable layout/bundled preset; device font names/files never enter this map.
  final Map<String, dynamic>? typography;
  static const dark = [
    0x1d2028,
    0xf07178,
    0xb6ec92,
    0xffd37f,
    0x8fbaff,
    0xc792ea,
    0x89ddff,
    0xd8dee9,
    0x6d7c9b,
    0xff8b92,
    0xddffa7,
    0xffe585,
    0x9cc4ff,
    0xe1acff,
    0xa3f7ff,
    0xffffff,
  ];
  static const light = [
    0x1c2733,
    0xb42330,
    0x387531,
    0x926600,
    0x225cb6,
    0x7543a2,
    0x177477,
    0x526174,
    0x6c7a89,
    0xd43944,
    0x42923a,
    0xb08000,
    0x3c73ce,
    0x9757be,
    0x198d92,
    0xc3cbd5,
  ];
  Map<String, dynamic> toJson() => {
    'version': 1,
    'history_lines': historyLines,
    'cursor_shape': shape,
    'cursor_blink': blink,
    'osc52': osc52,
    'right_click_paste': rightPaste,
    'copy_on_selection': copySelection,
    'paste_paths_direct': pastePaths,
    'colors': {
      'foreground': foreground,
      'background': background,
      'cursor': cursor,
      'ansi': ansi,
    },
    'notifications': notifications.toJson(),
    if (typography != null) 'typography': typography,
  };
  factory TerminalPreferencesValue.parse(Map<String, dynamic> value) {
    bool exact(Map<String, dynamic> v, Set<String> keys) =>
        v.keys.toSet().containsAll(keys) && v.length == keys.length;
    if (!exact(value, {
          'version',
          'history_lines',
          'cursor_shape',
          'cursor_blink',
          'osc52',
          'right_click_paste',
          if (value.containsKey('copy_on_selection')) 'copy_on_selection',
          if (value.containsKey('paste_paths_direct')) 'paste_paths_direct',
          'colors',
          if (value.containsKey('notifications')) 'notifications',
          if (value.containsKey('typography')) 'typography',
        }) ||
        value['version'] != 1) {
      throw const FormatException('终端设置版本或字段不支持');
    }
    final colors = value['colors'] as Map<String, dynamic>;
    if (!exact(colors, {'foreground', 'background', 'cursor', 'ansi'})) {
      throw const FormatException('配色设置字段不支持');
    }
    final geometry = value['typography'] as Map<String, dynamic>?;
    if (geometry != null) {
      if (!exact(geometry, {
        'size',
        'line_height',
        'padding',
        'ligatures',
        if (geometry.containsKey('builtin_family')) 'builtin_family',
      })) {
        throw const FormatException('通用排版设置字段不支持');
      }
      TerminalTypography.fromJson({
        ...const TerminalTypography().toJson(),
        ...geometry,
        'family': geometry['builtin_family'] ?? 'JetBrainsMono',
      });
    }
    final result = TerminalPreferencesValue(
      historyLines: value['history_lines'] as int,
      shape: value['cursor_shape'] as String,
      blink: value['cursor_blink'] as bool,
      osc52: value['osc52'] as bool,
      rightPaste: value['right_click_paste'] as bool,
      copySelection: value['copy_on_selection'] as bool? ?? false,
      pastePaths: value['paste_paths_direct'] as bool? ?? true,
      foreground: colors['foreground'] as int,
      background: colors['background'] as int,
      cursor: colors['cursor'] as int,
      ansi: (colors['ansi'] as List).cast<int>(),
      typography: geometry,
      notifications: !value.containsKey('notifications')
          ? const TerminalNotificationSettings()
          : TerminalNotificationSettings.parse(
              value['notifications'] as Map<String, dynamic>,
            ),
    );
    if (result.historyLines < 0 ||
        result.historyLines > 1000000 ||
        !['block', 'underline', 'beam'].contains(result.shape) ||
        result.ansi.length != 16 ||
        [
          result.foreground,
          result.background,
          result.cursor,
          ...result.ansi,
        ].any((c) => c < 0 || c > 0xffffff)) {
      throw const FormatException('终端参数范围无效');
    }
    return result;
  }
}

class TerminalPreferencesSnapshot {
  const TerminalPreferencesSnapshot(this.scope, this.revision, this.value);
  final String scope, revision;
  final TerminalPreferencesValue value;
  factory TerminalPreferencesSnapshot.decode(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    final scope = json['vault_scope'] as String,
        revision = json['revision'] as String;
    if (scope.isEmpty || !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision)) {
      throw const FormatException('原配置修订无效');
    }
    return TerminalPreferencesSnapshot(
      scope,
      revision,
      TerminalPreferencesValue.parse(json['value'] as Map<String, dynamic>),
    );
  }
  String proposal(TerminalPreferencesValue value) => jsonEncode({
    'vault_scope': scope,
    'revision': revision,
    'value': value.toJson(),
  });
}

class TerminalPreferencesAckFailure implements Exception {
  const TerminalPreferencesAckFailure();
  @override
  String toString() => '原终端设置已保存，但返回状态解析失败；请重新载入，不要重复保存原修改';
}

abstract interface class TerminalPreferencesGateway {
  Future<TerminalPreferencesSnapshot> load();
  Future<TerminalPreferencesSnapshot> save(
    TerminalPreferencesSnapshot source,
    TerminalPreferencesValue value,
  );
}

class NativeTerminalPreferencesGateway implements TerminalPreferencesGateway {
  NativeTerminalPreferencesGateway(this.model);
  final LiveWorkbenchModel model;
  @override
  Future<TerminalPreferencesSnapshot> load() => model.runLocalSettings(
    () async => TerminalPreferencesSnapshot.decode(
      await rust.loadTerminalPreferences(),
    ),
  );
  @override
  Future<TerminalPreferencesSnapshot> save(
    TerminalPreferencesSnapshot source,
    TerminalPreferencesValue value,
  ) async {
    final result = await model.runLocalSettings(
      () => rust.saveTerminalPreferences(proposal: source.proposal(value)),
    );
    try {
      return TerminalPreferencesSnapshot.decode(result);
    } catch (_) {
      throw const TerminalPreferencesAckFailure();
    }
  }
}

class TerminalPreferencesPanel extends StatefulWidget {
  const TerminalPreferencesPanel({super.key, required this.gateway});
  final TerminalPreferencesGateway gateway;
  @override
  State<TerminalPreferencesPanel> createState() =>
      _TerminalPreferencesPanelState();
}

class _TerminalPreferencesPanelState extends State<TerminalPreferencesPanel> {
  TerminalPreferencesSnapshot? _source;
  String? _error, _status;
  bool _busy = false, _io = false, _blink = false, _osc = true, _right = false;
  String _shape = 'block';
  bool _copySelection = false;
  bool _pastePaths = true;
  final _history = TextEditingController();
  final _colors = List.generate(19, (_) => TextEditingController());
  final _notificationEditor = GlobalKey<TerminalNotificationEditorState>();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _history.dispose();
    for (final c in _colors) {
      c.dispose();
    }
    super.dispose();
  }

  void _adopt(TerminalPreferencesSnapshot source) {
    _source = source;
    final v = source.value;
    _history.text = '${v.historyLines}';
    _shape = v.shape;
    _blink = v.blink;
    _osc = v.osc52;
    _right = v.rightPaste;
    _copySelection = v.copySelection;
    _pastePaths = v.pastePaths;
    final colors = [v.foreground, v.background, v.cursor, ...v.ansi];
    for (var i = 0; i < colors.length; i++) {
      _colors[i].text = colors[i]
          .toRadixString(16)
          .padLeft(6, '0')
          .toUpperCase();
    }
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
      final source = await widget.gateway.load();
      if (mounted) setState(() => _adopt(source));
    } catch (error) {
      if (mounted) setState(() => _error = '终端设置未载入，禁止默认覆盖：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  TerminalPreferencesValue _read() {
    final count = int.tryParse(_history.text.trim());
    if (count == null || count < 0 || count > 1000000) {
      throw const FormatException('历史行数须为0–1000000的整数');
    }
    final colors = _colors.map((c) {
      if (!RegExp(r'^[a-fA-F0-9]{6}$').hasMatch(c.text)) {
        throw const FormatException('颜色须为6位RGB十六进制');
      }
      return int.parse(c.text, radix: 16);
    }).toList();
    return TerminalPreferencesValue(
      historyLines: count,
      shape: _shape,
      blink: _blink,
      osc52: _osc,
      rightPaste: _right,
      copySelection: _copySelection,
      pastePaths: _pastePaths,
      foreground: colors[0],
      background: colors[1],
      cursor: colors[2],
      ansi: colors.sublist(3),
      typography: _source!.value.typography,
      notifications:
          _notificationEditor.currentState?.read() ??
          _source!.value.notifications,
    );
  }

  void _preset(bool light) {
    final values = light
        ? [0x24364a, 0xf6f8fb, 0x24364a, ...TerminalPreferencesValue.light]
        : [0xd8dee9, 0x10151d, 0xd8dee9, ...TerminalPreferencesValue.dark];
    setState(() {
      for (var i = 0; i < values.length; i++) {
        _colors[i].text = values[i]
            .toRadixString(16)
            .padLeft(6, '0')
            .toUpperCase();
      }
    });
  }

  Future<void> _save() async {
    var source = _source;
    if (_busy || source == null) return;
    if (SettingsLeaveScope.of(context) != null) {
      final original = source;
      final fresh = await widget.gateway.load();
      if (!mounted) return;
      Map<String, Object?> editable(TerminalPreferencesSnapshot s) =>
          Map<String, Object?>.from(s.value.toJson())..remove('typography');
      if (fresh.scope != original.scope ||
          jsonEncode(editable(fresh)) != jsonEncode(editable(original))) {
        setState(() => _error = '终端设置已由其他操作修改，请重新载入');
        return;
      }
      source = fresh;
      _source = fresh;
    }
    if ([_history, ..._colors].any(
          (c) => c.value.composing.isValid && !c.value.composing.isCollapsed,
        ) ||
        _notificationEditor.currentState?.composing == true) {
      setState(() => _error = '请先确认输入法候选');
      return;
    }
    late final TerminalPreferencesValue value;
    try {
      value = _read();
    } catch (error) {
      setState(() => _error = '$error');
      return;
    }
    if (jsonEncode(value.toJson()) == jsonEncode(source.value.toJson())) {
      setState(() => _status = '没有需要保存的修改');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final yes =
          SettingsLeaveScope.of(context) != null &&
              !(value.notifications.preview &&
                  !source.value.notifications.preview)
          ? true
          : await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                scrollable: true,
                title: const Text('保存终端设置？'),
                content: Text(
                  '历史上限 ${value.historyLines} 行仅作用于新建终端，不裁剪现有历史。光标和配色作为默认值更新，远端控制序列仍可临时覆盖。OSC52 ${value.osc52 ? '允许读写' : '关闭读写'}。右键${value.rightPaste ? '粘贴（Shift+右键菜单）' : '菜单'}；远端鼠标捕获优先。选中即复制${value.copySelection ? '开启（全空白不复制）' : '关闭'}。路径直贴${value.pastePaths ? '开启' : '关闭'}。多行粘贴安全预览始终保留。\n终端通知${value.notifications.enabled ? '开启' : '关闭'}；Windows桌面通知${value.notifications.desktop ? '开启' : '关闭'}；远端正文预览${value.notifications.preview ? '开启，可能含敏感内容' : '关闭'}。SFTP任务不发送桌面通知。',
                ),
                actions: [
                  TextButton(
                    autofocus: true,
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    key: const ValueKey('terminal-preferences-confirm'),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('保存并应用'),
                  ),
                ],
              ),
            );
      if (!mounted || yes != true) return;
      setState(() => _io = true);
      final result = await widget.gateway.save(source, value);
      if (!mounted) return;
      setState(() {
        _adopt(result);
        _status = '终端设置已加密保存；历史行数仅新终端生效，现有 SSH 未重连。';
      });
    } on TerminalPreferencesAckFailure catch (error) {
      if (mounted) {
        setState(() {
          _source = null;
          _status = '原设置已保存';
          _error = '$error';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '未确认保存成功：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  bool get _dirty {
    final source = _source;
    if (source == null) return false;
    try {
      return jsonEncode(_read().toJson()) != jsonEncode(source.value.toJson());
    } catch (_) {
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    Widget color(int index, String label) => SizedBox(
      width: 136,
      child: SettingsField(
        child: TextField(
          key: ValueKey('terminal-color-$index'),
          controller: _colors[index],
          decoration: InputDecoration(labelText: label, prefixText: '#'),
          onChanged: (_) => setState(() {}),
        ),
      ),
    );
    TerminalPreferencesValue? preview;
    try {
      if (source != null) preview = _read();
    } catch (_) {
      /* Invalid in-progress text is preserved; Save reports the field error. */
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('终端默认设置 · 加密保存'),
        if (_io) const LinearProgressIndicator(),
        const SizedBox(height: 12),
        AbsorbPointer(
          absorbing: _busy || source == null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 220,
                child: SettingsField(
                  child: TextField(
                    key: const ValueKey('terminal-history-limit'),
                    controller: _history,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '新终端历史上限（行）',
                      helperText: 'RAM + 临时磁盘；应用退出清理',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SettingsField(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('terminal-cursor-$_shape'),
                  initialValue: _shape,
                  decoration: const InputDecoration(labelText: '默认光标'),
                  items: const [
                    DropdownMenuItem(value: 'block', child: Text('块状')),
                    DropdownMenuItem(value: 'underline', child: Text('下划线')),
                    DropdownMenuItem(value: 'beam', child: Text('竖线')),
                  ],
                  onChanged: (v) => setState(() => _shape = v!),
                ),
              ),
              CompactSettingsToggle(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('默认光标闪烁'),
                  value: _blink,
                  onChanged: (v) => setState(() => _blink = v),
                ),
              ),
              CompactSettingsToggle(
                child: SwitchListTile(
                  key: const ValueKey('terminal-osc52'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('OSC52 剪贴板读写'),
                  subtitle: const Text('默认允许；远端可读取和更改本机剪贴板，解码上限10MiB。可完整关闭。'),
                  value: _osc,
                  onChanged: (v) => setState(() => _osc = v),
                ),
              ),
              CompactSettingsToggle(
                child: SwitchListTile(
                  key: const ValueKey('terminal-right-paste'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('右键粘贴'),
                  subtitle: const Text('Shift+右键强制本地菜单；远端鼠标报告仍优先，多行粘贴仍确认。'),
                  value: _right,
                  onChanged: (v) => setState(() => _right = v),
                ),
              ),
              CompactSettingsToggle(
                child: SwitchListTile(
                  key: const ValueKey('terminal-copy-selection'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('选中即复制'),
                  subtitle: const Text('鼠标拖选松开即复制到本机剪贴板；选区全为空白时不复制。'),
                  value: _copySelection,
                  onChanged: (v) => setState(() => _copySelection = v),
                ),
              ),
              CompactSettingsToggle(
                child: SwitchListTile(
                  key: const ValueKey('terminal-paste-paths'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('允许向交互式程序直接粘贴路径'),
                  subtitle: const Text(
                    '“发送路径至终端”在Shell集成不可用时改为普通终端粘贴（带引号、不按回车、遵守远端粘贴模式）；关闭则只复制安全路径。',
                  ),
                  value: _pastePaths,
                  onChanged: (v) => setState(() => _pastePaths = v),
                ),
              ),
              const Text('多行粘贴预览始终保留；不提供关闭安全确认或清空终端历史的按钮。'),
              if (source != null)
                TerminalNotificationEditor(
                  key: _notificationEditor,
                  source: source.value.notifications,
                  revision: '${source.scope}/${source.revision}',
                ),
              const Divider(height: 32),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => _preset(false),
                    child: const Text('深色配色预设'),
                  ),
                  OutlinedButton(
                    onPressed: () => _preset(true),
                    child: const Text('浅色配色预设'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 16,
                runSpacing: 10,
                children: [
                  color(0, '默认文字'),
                  color(1, '默认背景'),
                  color(2, '默认光标'),
                ],
              ),
              ExpansionTile(
                title: const Text('ANSI 16色'),
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (var i = 0; i < 16; i++) color(i + 3, '色号 $i'),
                    ],
                  ),
                ],
              ),
              if (preview != null)
                ColoredBox(
                  color: Color(0xff000000 | preview.background),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '终端配色预览 · 中文 Aa 0123',
                      style: TextStyle(
                        color: Color(0xff000000 | preview.foreground),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_error != null)
          Text(
            _error!,
            key: const ValueKey('terminal-preferences-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_status != null)
          Text(_status!, key: const ValueKey('terminal-preferences-status')),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              key: const ValueKey('terminal-preferences-reload'),
              onPressed: _busy ? null : _load,
              child: const Text('重新载入'),
            ),
            Visibility(
              visible: SettingsLeaveScope.of(context) == null,
              child: FilledButton(
                key: const ValueKey('terminal-preferences-save'),
                onPressed: _busy || source == null ? null : _save,
                child: const Text('预览确认并保存'),
              ),
            ),
          ],
        ),
      ],
    ).guardSettings(
      confirmed: () => _source != null && _error == null,
      apply: _save,
      label: '终端颜色与输入偏好',
      dirty: () => _dirty,
      busy: () => _busy && !_io,
    );
  }
}
