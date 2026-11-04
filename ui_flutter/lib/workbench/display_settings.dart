import '../prototype/settings_leave.dart';

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/display.dart';

DisplayConfig copyDisplay(
  DisplayConfig c, {
  bool? enabled,
  bool? semantic,
  bool? rainbow,
  bool? sameWord,
  bool? sensitive,
  bool? alternate,
  List<DisplayRule>? rules,
}) => DisplayConfig(
  enabled: enabled ?? c.enabled,
  semantic: semantic ?? c.semantic,
  rainbow: rainbow ?? c.rainbow,
  sameWord: sameWord ?? c.sameWord,
  sameWordCaseSensitive: sensitive ?? c.sameWordCaseSensitive,
  allowInAlternateScreen: alternate ?? c.allowInAlternateScreen,
  rules: rules ?? c.rules,
);
DisplayRule enabledRule(DisplayRule r, bool enabled) => DisplayRule(
  id: r.id,
  name: r.name,
  pattern: r.pattern,
  regex: r.regex,
  caseSensitive: r.caseSensitive,
  enabled: enabled,
  forceColor: r.forceColor,
  foreground: r.foreground,
  background: r.background,
  underline: r.underline,
);

abstract interface class DisplaySettingsGateway {
  Future<List<rust.HostConfig>> hosts();
  Future<DisplaySettingsView> load(String? host);
  Future<DisplaySettingsView> save(
    String? host,
    String scope,
    int revision,
    DisplayConfig? config,
  );
  Future<List<DisplayRuleMatch>> test(DisplayConfig config, String sample);
  Future<List<DisplayRule>> importRules(String source);
}

class NativeDisplaySettingsGateway implements DisplaySettingsGateway {
  const NativeDisplaySettingsGateway();
  @override
  Future<List<rust.HostConfig>> hosts() => rust.listHosts();
  @override
  Future<DisplaySettingsView> load(String? host) =>
      rust.terminalDisplaySettings(hostId: host);
  @override
  Future<DisplaySettingsView> save(
    String? host,
    String scope,
    int revision,
    DisplayConfig? config,
  ) => rust.saveTerminalDisplaySettings(
    hostId: host,
    vaultScope: scope,
    expectedRevision: revision,
    config: config,
  );
  @override
  Future<List<DisplayRuleMatch>> test(DisplayConfig config, String sample) =>
      rust.testDisplayRules(config: config, sample: sample);
  @override
  Future<List<DisplayRule>> importRules(String source) =>
      rust.importDisplayRules(source: source);
}

class DisplaySettingsPanel extends StatefulWidget {
  const DisplaySettingsPanel({
    super.key,
    this.gateway = const NativeDisplaySettingsGateway(),
  });
  final DisplaySettingsGateway gateway;
  @override
  State<DisplaySettingsPanel> createState() => _DisplaySettingsPanelState();
}

class _DisplaySettingsPanelState extends State<DisplaySettingsPanel> {
  List<rust.HostConfig> hosts = [];
  String? host, error, message;
  DisplaySettingsView? document;
  DisplayConfig? config;
  bool busy = true, dirty = false, inherit = false;
  final sample = TextEditingController(
    text: 'ERROR 2026-10-26 12:00:00 /var/log/app 127.0.0.1 [status=(42)]',
  );
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    sample.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => busy = true);
    try {
      final h = await widget.gateway.hosts(),
          doc = await widget.gateway.load(host);
      if (mounted) {
        setState(() {
          hosts = h;
          document = doc;
          config = doc.effective;
          inherit = host != null && doc.overrideConfig == null;
          dirty = false;
          error = null;
          message = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          document = null;
          config = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _select(String? next) async {
    if (dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('丢弃未保存的显示设置？'),
          content: const Text('更改尚未生效；切换范围将重新载入已保存设置。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('丢弃更改'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    host = next;
    await _load();
  }

  void _set(DisplayConfig next) {
    setState(() {
      config = next;
      dirty = true;
      message = null;
    });
  }

  Future<void> _save() async {
    final doc = document, c = config;
    if (doc == null || c == null || busy) return;
    setState(() => busy = true);
    try {
      final saved = await widget.gateway.save(
        host,
        doc.vaultScope,
        doc.revision,
        inherit ? null : c,
      );
      if (mounted) {
        setState(() {
          document = saved;
          config = saved.effective;
          dirty = false;
          error = null;
          message = '已加密保存并应用于同一配置库的终端；SSH原文不变。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _edit([int? index]) async {
    final c = config;
    if (c == null) return;
    final rule = await showDialog<DisplayRule>(
      context: context,
      builder: (_) => DisplayRuleEditor(
        initial: index == null ? null : c.rules[index],
        gateway: widget.gateway,
      ),
    );
    if (rule == null || !mounted) return;
    final rules = [...c.rules];
    if (index == null) {
      rules.add(rule);
    } else {
      rules[index] = rule;
    }
    _set(copyDisplay(c, rules: rules));
  }

  Future<void> _import() async {
    final rules = await showDialog<List<DisplayRule>>(
      context: context,
      builder: (_) => _RuleImportDialog(gateway: widget.gateway),
    );
    if (rules != null && mounted && config != null) {
      _set(copyDisplay(config!, rules: rules));
    }
  }

  Future<void> _test() async {
    final c = config;
    if (c == null) return;
    setState(() => busy = true);
    try {
      final matches = await widget.gateway.test(c, sample.text);
      if (mounted) {
        setState(() {
          message = matches.isEmpty
              ? '没有启用的规则'
              : matches
                    .map(
                      (m) =>
                          '${c.rules.firstWhere((r) => r.id == m.id).name}：${m.count}处',
                    )
                    .join('；');
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _switch(
    String key,
    String label,
    bool value,
    void Function(bool)? change, {
    String? detail,
  }) => SwitchListTile(
    key: ValueKey(key),
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(label, style: const TextStyle(fontSize: 13)),
    subtitle: detail == null
        ? null
        : Text(detail, style: const TextStyle(fontSize: 11)),
    value: value,
    onChanged: change,
  );
  @override
  Widget build(BuildContext context) {
    final c = config;
    final editable = !busy && c != null && !inherit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '终端显示增强',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          key: ValueKey('display-scope-${host ?? 'global'}'),
          initialValue: host ?? '',
          decoration: const InputDecoration(labelText: '设置范围'),
          isExpanded: true,
          items: [
            const DropdownMenuItem(value: '', child: Text('全局默认')),
            for (final h in hosts)
              DropdownMenuItem(
                value: h.id,
                child: Text(h.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: busy ? null : (v) => _select(v == '' ? null : v),
        ),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        if (host != null)
          _switch(
            'display-inherit',
            '继承全局显示设置',
            inherit,
            busy || document == null
                ? null
                : (v) => setState(() {
                    inherit = v;
                    dirty = true;
                  }),
          ),
        if (c != null) ...[
          _switch(
            'display-enabled',
            '启用显示增强',
            c.enabled,
            editable ? (v) => _set(copyDisplay(c, enabled: v)) : null,
          ),
          _switch(
            'display-semantic',
            '语义着色',
            c.semantic,
            editable ? (v) => _set(copyDisplay(c, semantic: v)) : null,
            detail: '识别稳定格式的时间、IP、数字、路径与选项；不访问网络或文件',
          ),
          _switch(
            'display-rainbow',
            '彩虹括号',
            c.rainbow,
            editable ? (v) => _set(copyDisplay(c, rainbow: v)) : null,
            detail: '仅着色可可靠配对的行；不完整或不匹配的括号保持原状',
          ),
          _switch(
            'display-same-word',
            '选中同词高亮',
            c.sameWord,
            editable ? (v) => _set(copyDisplay(c, sameWord: v)) : null,
          ),
          _switch(
            'display-same-word-case',
            '同词匹配区分大小写',
            c.sameWordCaseSensitive,
            editable ? (v) => _set(copyDisplay(c, sensitive: v)) : null,
          ),
          _switch(
            'display-alternate',
            '在备用屏幕TUI中允许装饰',
            c.allowInAlternateScreen,
            editable ? (v) => _set(copyDisplay(c, alternate: v)) : null,
            detail: '默认关闭，以保留Vim、tmux、Codex等TUI的显示语义',
          ),
          const Divider(),
          const Text('自定义规则 · 最上方优先，远端颜色优先，明确强制覆盖除外'),
          for (var i = 0; i < c.rules.length; i++)
            ListTile(
              key: ValueKey('display-rule-${c.rules[i].id}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Checkbox(
                value: c.rules[i].enabled,
                onChanged: editable
                    ? (v) {
                        final rules = [...c.rules];
                        rules[i] = enabledRule(rules[i], v ?? false);
                        _set(copyDisplay(c, rules: rules));
                      }
                    : null,
              ),
              title: Text(c.rules[i].name),
              subtitle: Text(
                '${c.rules[i].regex ? '正则' : '关键词'} · ${c.rules[i].forceColor ? '强制覆盖显示色' : '保留远端颜色'}',
              ),
              trailing: MediaQuery.sizeOf(context).width < 900
                  ? PopupMenuButton<String>(
                      key: ValueKey('display-rule-menu-${c.rules[i].id}'),
                      enabled: editable,
                      tooltip: '规则操作',
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'up',
                          enabled: i > 0,
                          child: const Text('上移规则'),
                        ),
                        PopupMenuItem(
                          value: 'down',
                          enabled: i < c.rules.length - 1,
                          child: const Text('下移规则'),
                        ),
                        const PopupMenuItem(value: 'edit', child: Text('编辑规则')),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('移除规则'),
                        ),
                      ],
                      onSelected: (action) {
                        if (action == 'edit') {
                          _edit(i);
                          return;
                        }
                        final rules = [...c.rules];
                        final rule = rules.removeAt(i);
                        if (action == 'up') {
                          rules.insert(i - 1, rule);
                        } else if (action == 'down') {
                          rules.insert(i + 1, rule);
                        }
                        _set(copyDisplay(c, rules: rules));
                      },
                    )
                  : Wrap(
                      spacing: 0,
                      children: [
                        IconButton(
                          tooltip: '上移规则',
                          onPressed: !editable || i == 0
                              ? null
                              : () {
                                  final rules = [...c.rules];
                                  final r = rules.removeAt(i);
                                  rules.insert(i - 1, r);
                                  _set(copyDisplay(c, rules: rules));
                                },
                          icon: const Icon(Icons.arrow_upward, size: 16),
                        ),
                        IconButton(
                          tooltip: '下移规则',
                          onPressed: !editable || i == c.rules.length - 1
                              ? null
                              : () {
                                  final rules = [...c.rules];
                                  final r = rules.removeAt(i);
                                  rules.insert(i + 1, r);
                                  _set(copyDisplay(c, rules: rules));
                                },
                          icon: const Icon(Icons.arrow_downward, size: 16),
                        ),
                        IconButton(
                          tooltip: '编辑规则',
                          onPressed: editable ? () => _edit(i) : null,
                          icon: const Icon(Icons.edit_outlined, size: 16),
                        ),
                        IconButton(
                          tooltip: '移除规则',
                          onPressed: editable
                              ? () {
                                  final rules = [...c.rules]..removeAt(i);
                                  _set(copyDisplay(c, rules: rules));
                                }
                              : null,
                          icon: const Icon(Icons.delete_outline, size: 16),
                        ),
                      ],
                    ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('display-add-rule'),
                onPressed: editable && c.rules.length < 32
                    ? () => _edit()
                    : null,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新增规则'),
              ),
              OutlinedButton(
                onPressed: editable ? _import : null,
                child: const Text('导入规则 JSON'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('display-sample'),
            controller: sample,
            minLines: 2,
            maxLines: 4,
            maxLength: 8192,
            decoration: const InputDecoration(labelText: '规则测试文本（仅当前界面内存）'),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('display-test'),
              onPressed: editable ? _test : null,
              child: const Text('测试规则，不保存'),
            ),
          ),
        ],
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (message != null) Text(message!),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          children: [
            FilledButton(
              key: const ValueKey('display-save'),
              onPressed: busy || document == null ? null : _save,
              child: const Text('保存显示设置'),
            ),
            TextButton(
              onPressed: busy ? null : () => _select(host),
              child: const Text('重新载入'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          '只处理变化的可见行；每帧8ms装饰预算（匹配边界检查）、文本128KiB、单行8KiB、最多32规则，每规则每行128匹配、最多16Ki绘制单元。超限行/装饰会跳过，SSH原文、复制、导出和历史保持完整。正则使用有界Rust引擎；不支持回溯引用等语法。',
          style: TextStyle(fontSize: 11),
        ),
      ],
    ).guardSettings(
      label: '彩色高亮',
      dirty: () => dirty,
      busy: () => busy && config != null,
    );
  }
}

class DisplayRuleEditor extends StatefulWidget {
  const DisplayRuleEditor({super.key, this.initial, required this.gateway});
  final DisplayRule? initial;
  final DisplaySettingsGateway gateway;
  @override
  State<DisplayRuleEditor> createState() => _DisplayRuleEditorState();
}

class _DisplayRuleEditorState extends State<DisplayRuleEditor> {
  final name = TextEditingController(),
      pattern = TextEditingController(),
      fg = TextEditingController(),
      bg = TextEditingController();
  bool regex = false,
      sensitive = true,
      force = false,
      underline = false,
      busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    if (r != null) {
      name.text = r.name;
      pattern.text = r.pattern;
      regex = r.regex;
      sensitive = r.caseSensitive;
      force = r.forceColor;
      underline = r.underline;
      fg.text = r.foreground?.toRadixString(16).substring(2) ?? '';
      bg.text = r.background?.toRadixString(16).substring(2) ?? '';
    }
  }

  @override
  void dispose() {
    name.dispose();
    pattern.dispose();
    fg.dispose();
    bg.dispose();
    super.dispose();
  }

  int? color(String s) {
    if (s.trim().isEmpty) return null;
    final value = s.trim().replaceFirst('#', '');
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value)) {
      throw const FormatException('颜色需要6位RGB十六进制');
    }
    return 0xff000000 | int.parse(value, radix: 16);
  }

  Future<void> _accept() async {
    setState(() => busy = true);
    try {
      final r = DisplayRule(
        id:
            widget.initial?.id ??
            'rule-${DateTime.now().microsecondsSinceEpoch}',
        name: name.text.trim(),
        pattern: pattern.text,
        regex: regex,
        caseSensitive: sensitive,
        enabled: widget.initial?.enabled ?? true,
        forceColor: force,
        foreground: color(fg.text),
        background: color(bg.text),
        underline: underline,
      );
      final c = DisplayConfig(
        enabled: true,
        semantic: false,
        rainbow: false,
        sameWord: false,
        sameWordCaseSensitive: true,
        allowInAlternateScreen: false,
        rules: [r],
      );
      await widget.gateway.test(c, '');
      if (mounted) Navigator.pop(context, r);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(widget.initial == null ? '新增显示规则' : '编辑显示规则'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('display-rule-name'),
              controller: name,
              maxLength: 256,
              decoration: const InputDecoration(labelText: '规则名称'),
            ),
            TextField(
              key: const ValueKey('display-rule-pattern'),
              controller: pattern,
              maxLength: 512,
              decoration: const InputDecoration(labelText: '关键词或正则'),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('正则表达式'),
              value: regex,
              onChanged: busy ? null : (v) => setState(() => regex = v),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('区分大小写'),
              value: sensitive,
              onChanged: busy ? null : (v) => setState(() => sensitive = v),
            ),
            TextField(
              key: const ValueKey('display-rule-foreground'),
              controller: fg,
              decoration: const InputDecoration(
                labelText: '文字颜色 RGB，例如 E57373（空白保留）',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: bg,
              decoration: const InputDecoration(labelText: '背景颜色 RGB（空白保留）'),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('下划线'),
              value: underline,
              onChanged: busy ? null : (v) => setState(() => underline = v),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('明确强制覆盖远端颜色'),
              value: force,
              onChanged: busy ? null : (v) => setState(() => force = v),
            ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('display-rule-accept'),
          onPressed: busy ? null : _accept,
          child: const Text('应用到待保存规则'),
        ),
      ],
    ),
  );
}

class _RuleImportDialog extends StatefulWidget {
  const _RuleImportDialog({required this.gateway});
  final DisplaySettingsGateway gateway;
  @override
  State<_RuleImportDialog> createState() => _RuleImportDialogState();
}

class _RuleImportDialogState extends State<_RuleImportDialog> {
  final text = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> accept() async {
    setState(() => busy = true);
    try {
      final rules = await widget.gateway.importRules(text.text);
      if (mounted) Navigator.pop(context, rules);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('导入显示规则 JSON'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('最多32条规则/32KiB；替换当前待保存规则，点击设置页保存后才生效。仅规则，不导入主题。'),
            TextField(
              controller: text,
              minLines: 6,
              maxLines: 12,
              maxLength: 32768,
              decoration: const InputDecoration(labelText: '规则数组 JSON'),
            ),
            if (error != null) Text(error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy ? null : accept,
          child: const Text('校验并载入待保存规则'),
        ),
      ],
    ),
  );
}
