import '../prototype/settings_style.dart';

import 'package:flutter/material.dart';

import '../terminal/notifications.dart';

class TerminalNotificationEditor extends StatefulWidget {
  const TerminalNotificationEditor({
    super.key,
    required this.source,
    required this.revision,
  });
  final TerminalNotificationSettings source;
  final String revision;
  @override
  State<TerminalNotificationEditor> createState() =>
      TerminalNotificationEditorState();
}

class TerminalNotificationEditorState
    extends State<TerminalNotificationEditor> {
  late Map<String, dynamic> _values;
  final _quiet = TextEditingController();
  final _rules = <({TextEditingController text, bool regex, bool sensitive})>[];
  final _retired = <TextEditingController>{};
  bool get composing => [
    _quiet,
    ..._rules.map((r) => r.text),
  ].any((c) => c.value.composing.isValid && !c.value.composing.isCollapsed);
  @override
  void initState() {
    super.initState();
    _adopt();
  }

  void _retire(TextEditingController c) {
    _retired.add(c);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_retired.remove(c)) c.dispose();
    });
  }

  void _adopt() {
    for (final r in _rules) {
      _retire(r.text);
    }
    _rules.clear();
    _values = widget.source.toJson();
    _quiet.text = '${widget.source.quietSeconds}';
    for (final r in widget.source.rules) {
      _rules.add((
        text: TextEditingController(text: r.text),
        regex: r.regex,
        sensitive: r.caseSensitive,
      ));
    }
  }

  @override
  void didUpdateWidget(TerminalNotificationEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision) _adopt();
  }

  TerminalNotificationSettings read() {
    final quiet = int.tryParse(_quiet.text.trim());
    if (quiet == null) throw const FormatException('输出静默秒数须为整数；0关闭，或5–86400秒');
    return TerminalNotificationSettings.parse({
      ..._values,
      'quiet_seconds': quiet,
      'rules': [
        for (final r in _rules)
          {
            'text': r.text.text,
            'regex': r.regex,
            'case_sensitive': r.sensitive,
          },
      ],
    });
  }

  @override
  void dispose() {
    _quiet.dispose();
    for (final r in _rules) {
      r.text.dispose();
    }
    for (final c in _retired) {
      c.dispose();
    }
    _retired.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget toggle(String key, String name, String hint) =>
        CompactSettingsToggle(
          child: SwitchListTile(
            key: ValueKey('terminal-notify-$key'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(name),
            subtitle: hint.isEmpty ? null : Text(hint),
            value: _values[key] as bool,
            onChanged: (v) => setState(() => _values[key] = v),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        const Text('终端通知 · 不包含 SFTP 任务'),
        toggle('enabled', '启用终端通知', '响铃、远端通知、输出规则与静默提醒；自动合并重复提示。'),
        toggle('bell', '终端响铃通知', ''),
        toggle('osc', '远端 OSC 通知', '只显示文本，不执行动作、打开链接或获取网页内容。'),
        toggle('foreground', '当前焦点终端通知', '应用在前台且终端有焦点时，也显示应用内提示。'),
        toggle('background', '后台终端通知', '包括未选中的终端，或应用失焦时的终端。'),
        toggle(
          'desktop',
          'Windows 桌面通知',
          '默认关闭；启用后首次后台通知会注册本应用通知身份。系统勿扰/通知设置仍优先；未打包应用不能保证从通知中心撤回。',
        ),
        toggle(
          'preview',
          '在通知中显示远端内容',
          '默认关闭。开启后远端通知或规则匹配文本可能出现在应用提示和系统通知中心，可能含敏感内容。',
        ),
        TextField(
          key: const ValueKey('terminal-notify-quiet'),
          controller: _quiet,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '输出静默秒数',
            helperText: '0关闭；5–86400秒。收到输出后只提示一次，再次输出重新计时。',
          ),
        ),
        const SizedBox(height: 8),
        const Text('最多16条规则，每条256字节。仅匹配普通输出，不扫描历史或备用屏幕。'),
        for (var i = 0; i < _rules.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                TextField(
                  key: ObjectKey(_rules[i].text),
                  controller: _rules[i].text,
                  decoration: InputDecoration(labelText: '规则 ${i + 1}'),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('正则'),
                      selected: _rules[i].regex,
                      onSelected: (v) => setState(
                        () => _rules[i] = (
                          text: _rules[i].text,
                          regex: v,
                          sensitive: _rules[i].sensitive,
                        ),
                      ),
                    ),
                    FilterChip(
                      label: const Text('区分大小写'),
                      selected: _rules[i].sensitive,
                      onSelected: (v) => setState(
                        () => _rules[i] = (
                          text: _rules[i].text,
                          regex: _rules[i].regex,
                          sensitive: v,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '删除通知规则',
                      onPressed: () => setState(() {
                        _retire(_rules.removeAt(i).text);
                      }),
                      icon: const Icon(Icons.delete_outline, size: 18),
                    ),
                  ],
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _rules.length >= 16
                ? null
                : () => setState(
                    () => _rules.add((
                      text: TextEditingController(),
                      regex: false,
                      sensitive: true,
                    )),
                  ),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('添加通知规则'),
          ),
        ),
        const Text('修改仅在本页“预览确认并保存”成功后应用；关闭通知不改远端程序、终端输出或传输任务。'),
      ],
    );
  }
}
