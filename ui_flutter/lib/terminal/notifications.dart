import 'dart:convert';

/// Terminal-originated only. No file-transfer events use this type or channel.
class RemoteTerminalNotice {
  const RemoteTerminalNotice({
    required this.policy,
    required this.kind,
    required this.title,
    required this.body,
    required this.foreground,
    required this.background,
    required this.desktop,
  });
  final String policy, kind, title, body;
  final bool foreground, background, desktop;
  factory RemoteTerminalNotice.decode(String text) {
    try {
      return RemoteTerminalNotice._decode(text);
    } catch (_) {
      throw const FormatException('终端通知格式无效');
    }
  }
  factory RemoteTerminalNotice._decode(String text) {
    if (text.length > 8192) throw const FormatException('终端通知超过容量');
    final v = jsonDecode(text) as Map<String, dynamic>;
    if (v.length != 7 ||
        !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(v['policy'] as String) ||
        !{'bell', 'osc', 'rule', 'quiet'}.contains(v['kind'])) {
      throw const FormatException('终端通知类型无效');
    }
    final title = v['title'] as String, body = v['body'] as String;
    if (title.runes.length > 128 ||
        body.runes.length > 512 ||
        [title, body].any(
          (s) => s.runes.any(
            (r) =>
                r < 32 ||
                (r >= 127 && r <= 159) ||
                (r >= 0x202a && r <= 0x202e) ||
                (r >= 0x2066 && r <= 0x2069),
          ),
        )) {
      throw const FormatException('终端通知文本无效');
    }
    return RemoteTerminalNotice(
      policy: v['policy'] as String,
      kind: v['kind'] as String,
      title: title,
      body: body,
      foreground: v['foreground'] as bool,
      background: v['background'] as bool,
      desktop: v['desktop'] as bool,
    );
  }
  String get summary => switch (kind) {
    'bell' => '终端响铃',
    'osc' => '远端终端通知',
    'rule' => '终端输出匹配通知规则',
    'quiet' => '终端输出已静默',
    _ => '终端通知',
  };
}

/// Optional extension to the original version-1 terminal preferences.
class TerminalNotificationSettings {
  const TerminalNotificationSettings({
    this.enabled = true,
    this.bell = true,
    this.osc = true,
    this.foreground = false,
    this.background = true,
    this.desktop = false,
    this.preview = false,
    this.quietSeconds = 0,
    this.rules = const [],
  });
  final bool enabled, bell, osc, foreground, background, desktop, preview;
  final int quietSeconds;
  final List<TerminalNotificationRule> rules;
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'bell': bell,
    'osc': osc,
    'foreground': foreground,
    'background': background,
    'desktop': desktop,
    'preview': preview,
    'quiet_seconds': quietSeconds,
    'rules': rules.map((r) => r.toJson()).toList(),
  };
  factory TerminalNotificationSettings.parse(Map<String, dynamic> v) {
    if (v.length != 9) throw const FormatException('通知设置字段无效');
    final rules = (v['rules'] as List)
        .map((r) => TerminalNotificationRule.parse(r as Map<String, dynamic>))
        .toList(growable: false);
    final quiet = v['quiet_seconds'] as int;
    if (rules.length > 16 || (quiet != 0 && (quiet < 5 || quiet > 86400))) {
      throw const FormatException('通知设置超过范围');
    }
    return TerminalNotificationSettings(
      enabled: v['enabled'] as bool,
      bell: v['bell'] as bool,
      osc: v['osc'] as bool,
      foreground: v['foreground'] as bool,
      background: v['background'] as bool,
      desktop: v['desktop'] as bool,
      preview: v['preview'] as bool,
      quietSeconds: quiet,
      rules: List.unmodifiable(rules),
    );
  }
}

class TerminalNotificationRule {
  const TerminalNotificationRule(
    this.text, {
    this.regex = false,
    this.caseSensitive = true,
  });
  final String text;
  final bool regex, caseSensitive;
  Map<String, dynamic> toJson() => {
    'text': text,
    'regex': regex,
    'case_sensitive': caseSensitive,
  };
  factory TerminalNotificationRule.parse(Map<String, dynamic> v) {
    final text = v['text'] as String;
    if (v.length != 3 ||
        text.isEmpty ||
        utf8.encode(text).length > 256 ||
        text.runes.any((r) => r < 32 || (r >= 127 && r <= 159))) {
      throw const FormatException('通知规则无效');
    }
    return TerminalNotificationRule(
      text,
      regex: v['regex'] as bool,
      caseSensitive: v['case_sensitive'] as bool,
    );
  }
}
