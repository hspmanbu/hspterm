import '../run_log.dart';
import 'settings_style.dart';

import 'package:flutter/material.dart';

import 'design.dart';
import 'model.dart';
import 'settings_leave.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.model,
    this.transferSettingsBuilder,
    this.fileOpenSettingsBuilder,
    this.sshNetworkSettingsBuilder,
    this.displaySettingsBuilder,
    this.historySettingsBuilder,
    this.paletteSettingsBuilder,
    this.typographySettingsBuilder,
    this.terminalPreferencesBuilder,
    this.diagnosticsBuilder,
    this.backupSettingsBuilder,
    this.appearanceSettingsBuilder,
    this.sftpViewSettingsBuilder,
    this.initialCategory = '外观',
  });
  final WorkbenchModel model;
  final WidgetBuilder? transferSettingsBuilder;
  final WidgetBuilder? fileOpenSettingsBuilder;
  final WidgetBuilder? sshNetworkSettingsBuilder;
  final WidgetBuilder? displaySettingsBuilder;
  final WidgetBuilder? historySettingsBuilder;
  final WidgetBuilder? paletteSettingsBuilder;
  final WidgetBuilder? typographySettingsBuilder;
  final WidgetBuilder? terminalPreferencesBuilder;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? backupSettingsBuilder;
  final WidgetBuilder? appearanceSettingsBuilder;
  final WidgetBuilder? sftpViewSettingsBuilder;
  final String initialCategory;
  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> {
  final _leave = SettingsLeaveRegistry();
  final _panels = <String, Widget>{};
  bool _applying = false;
  bool? _themeDraft;
  Future<bool> canLeave() => _leave.canLeave(context);
  Future<void> _chooseCategory(String value) async {
    if (value == category) return;
    if (mounted && !_applying) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => category = value);
    }
  }

  Future<void> _apply({bool close = false}) async {
    if (_applying) return;
    AppRunLog.instance.event(AppLogEvent.settingsApply);
    setState(() => _applying = true);
    final saved = await _leave.applyAll(context);
    AppRunLog.instance.event(
      saved ? AppLogEvent.settingsApplied : AppLogEvent.settingsFailed,
    );
    if (!mounted) return;
    setState(() {
      _applying = false;
      if (_leave.failedCategory != null) category = _leave.failedCategory!;
    });
    if (saved && close) m.show(WorkPage.workspace);
  }

  void _cancel() {
    if (_leave.busy || _applying) {
      notice(context, '设置正在保存，请稍候。');
      return;
    }
    m.show(WorkPage.workspace);
  }

  String category = '外观';
  @override
  void initState() {
    super.initState();
    category = widget.initialCategory;
  }

  @override
  void didUpdateWidget(SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialCategory != oldWidget.initialCategory) {
      final requested = widget.initialCategory;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _chooseCategory(requested);
      });
    }
  }

  final categories = <String, IconData>{
    '外观': Icons.palette_outlined,
    '终端与输入': Icons.terminal,
    '快捷键': Icons.keyboard_outlined,
    'SSH 连接': Icons.hub_outlined,
    'SFTP 与传输': Icons.folder_outlined,
    '历史命令联想': Icons.history,
    '彩色高亮': Icons.format_color_text,
    '加密与同步': Icons.lock_outline,
    '运行诊断': Icons.bug_report_outlined,
  };
  WorkbenchModel get m => widget.model;
  final rules = ['ERROR · FAIL', 'WARN', 'SUCCESS'];
  Widget toggle(String title, String subtitle, {bool initial = true}) =>
      CompactSettingsToggle(
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(title, style: const TextStyle(fontSize: 12)),
          subtitle: Text(
            subtitle,
            style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor),
          ),
          value: (m.settings[title] ?? initial) as bool,
          onChanged: (v) {
            m.settings[title] = v;
            m.changed();
          },
        ),
      );
  Widget select(String label, List<String> options) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: DropdownButtonFormField<String>(
      key: ValueKey('setting-$label'),
      initialValue: (m.settings[label] ?? options.first) as String,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final s in options) DropdownMenuItem(value: s, child: Text(s)),
      ],
      onChanged: (v) {
        if (v != null) {
          m.settings[label] = v;
          m.changed();
        }
      },
    ),
  );
  Widget heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 14),
    child: Text(
      text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
  );
  List<Widget> get controls => switch (category) {
    '外观' => [
      heading('主题与布局').guardSettings(
        label: '界面主题',
        dirty: () => _themeDraft != null && _themeDraft != m.light,
        busy: () => false,
        apply: () async {
          final draft = _themeDraft;
          if (draft != null) await m.applyTheme(draft);
        },
      ),
      Row(
        children: [
          for (final light in [false, true])
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: light ? 0 : 12),
                child: InkWell(
                  key: ValueKey(light ? 'theme-light' : 'theme-dark'),
                  borderRadius: BorderRadius.circular(7),
                  onTap: m.themeAvailable
                      ? () => setState(() => _themeDraft = light)
                      : null,
                  child: Container(
                    height: 94,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: light
                          ? const Color(0xffeff3f7)
                          : const Color(0xff111820),
                      border: Border.all(
                        color: (_themeDraft ?? m.light) == light
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).dividerColor,
                        width: (_themeDraft ?? m.light) == light ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            for (final color in [
                              Desk.accent,
                              const Color(0xff7f9cbf),
                              Desk.warning,
                            ])
                              Container(
                                margin: const EdgeInsets.only(right: 4),
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: color,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                          ],
                        ),
                        const Spacer(),
                        Text(
                          light ? '浅色 · 云白' : '深色 · 石墨',
                          style: TextStyle(
                            color: light
                                ? const Color(0xff24364a)
                                : const Color(0xffd8e1ec),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          height: 3,
                          width: 75,
                          color: light
                              ? const Color(0xffc8d2dd)
                              : const Color(0xff344253),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 24),
      if (widget.appearanceSettingsBuilder != null)
        widget.appearanceSettingsBuilder!(context)
      else
        select('界面密度', ['紧凑', '标准']),
      heading('终端字体'),
      if (widget.typographySettingsBuilder != null)
        widget.typographySettingsBuilder!(context)
      else ...[
        select('字体', ['JetBrains Mono + Noto Sans CJK', '系统等宽字体', '自定义字体（预览）']),
        select('字体大小', ['13 px', '14 px', '15 px', '16 px', '18 px']),
        select('内容内边距', ['8 px', '4 px', '12 px']),
        toggle('编程连字', '默认关闭；正式字体/PTY尺寸接入沿用现有终端组件', initial: false),
        OutlinedButton.icon(
          onPressed: () => notice(context, '仅展示字体导入入口；未读取本机字体文件'),
          icon: const Icon(Icons.upload_file, size: 16),
          label: const Text('导入 TTF / OTF · 原型'),
        ),
      ],
    ],
    '终端与输入' => [
      if (widget.terminalPreferencesBuilder != null)
        widget.terminalPreferencesBuilder!(context)
      else ...[
        heading('终端行为'),
        select('滚动历史行数', ['100000', '50000', '200000']),
        select('光标形状', ['块状', '下划线', '竖线']),
        toggle('光标闪烁', '远端 DECSCUSR 可临时覆盖'),
        toggle('OSC52 剪贴板读写', '默认开启，解码上限 10 MiB'),
        toggle('多行粘贴预览', '包含换行或满足风险条件时先编辑确认'),
        select('右键行为', ['上下文菜单', '粘贴（Shift+右键打开菜单）']),
        const SizedBox(height: 8),
        const Text('历史缓存仅本次运行有效；没有手动清空滚动历史按钮。'),
      ],
    ],
    '快捷键' => [
      if (!m.isMock) ...[
        if (widget.paletteSettingsBuilder != null)
          widget.paletteSettingsBuilder!(context),
        heading('现有键盘操作'),
        for (final entry in const [
          ('终端复制 / 粘贴', 'Ctrl+Shift+C / V'),
          ('终端粘贴', 'Shift+Insert'),
          ('选区复制；无选区发送远端中断', 'Ctrl+C'),
          ('浏览滚动历史', 'Shift+PgUp / PgDn'),
          ('新建终端入口（终端外焦点）', 'Ctrl+Shift+T'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                Text(entry.$1),
                SelectableText(
                  entry.$2,
                  style: const TextStyle(fontFamily: Desk.mono, fontSize: 11),
                ),
              ],
            ),
          ),
        const Text(
          '命令面板的组合键与终端优先策略由上方设置控制。会话搜索、分屏和临时最大化可从命令面板或原菜单操作。SFTP 文件列表不提供 Ctrl+C/X/V 文件快捷键。',
        ),
      ] else ...[
        if (widget.paletteSettingsBuilder != null)
          widget.paletteSettingsBuilder!(context),
        heading(widget.paletteSettingsBuilder == null ? '应用快捷键' : '其他快捷键 · 原型'),
        for (final entry in [
          ('新建终端标签', 'Ctrl+Shift+T'),
          ('当前会话搜索', 'Ctrl+Shift+F'),
          if (widget.paletteSettingsBuilder == null) ('应用命令面板', 'Ctrl+Shift+P'),
          ('左右分屏', 'Ctrl+Shift+D'),
          ('临时最大化窗格', 'Ctrl+Shift+M'),
          ('复制 / 粘贴', 'Ctrl+Shift+C / V'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: Row(
              children: [
                Expanded(child: Text(entry.$1)),
                OutlinedButton(
                  onPressed: () =>
                      notice(context, '快捷键编辑原型；不覆盖 Phase 2 的远端终端键位'),
                  child: Text(
                    entry.$2,
                    style: const TextStyle(fontFamily: Desk.mono, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        Text(
          widget.paletteSettingsBuilder == null
              ? '远端 TUI 键盘捕获优先。正式快捷键冲突路由未接入；SFTP 文件列表不提供 Ctrl+C/X/V 文件快捷键。'
              : '应用命令面板组合键按上方设置路由；其他快捷键编辑仍为原型。系统/文本编辑键保留，SFTP 不提供 Ctrl+C/X/V 文件快捷键。',
        ),
      ],
    ],
    'SSH 连接' => [
      if (widget.sshNetworkSettingsBuilder != null)
        widget.sshNetworkSettingsBuilder!(context)
      else ...[
        heading('超时与心跳'),
        select('总连接超时', ['30 秒', '15 秒', '60 秒']),
        toggle('连接心跳', '只检查现有 Transport，不自动重建连接'),
        select('心跳间隔', ['30 秒', '15 秒', '60 秒']),
        select('响应超时', ['10 秒', '20 秒', '30 秒']),
        select('失败阈值', ['3 次', '2 次', '5 次']),
        const Text('断线后保留画面；只有明确点击或焦点窗格 Enter 才手动重连一次。确认等待时间不计入连接超时。'),
      ],
    ],
    'SFTP 与传输' => [
      heading('文件浏览'),
      if (widget.sftpViewSettingsBuilder != null)
        widget.sftpViewSettingsBuilder!(context)
      else ...[
        toggle('目录优先', '目录缓存按需加载，远端变化需手动刷新'),
        toggle('显示隐藏文件', '当前原型浏览默认值', initial: false),
        select('默认视图', ['详细列表', '紧凑列表']),
      ],
      if (widget.fileOpenSettingsBuilder != null)
        widget.fileOpenSettingsBuilder!(context)
      else
        select('大文件预览确认', ['超过 100 MiB', '超过 50 MiB', '始终确认']),
      heading('传输'),
      if (widget.transferSettingsBuilder != null)
        widget.transferSettingsBuilder!(context)
      else ...[
        select('并发顶层任务', ['3', '1', '2', '4']),
        select('上传带宽限制', ['不限速', '10 MB/s', '50 MB/s']),
        select('下载带宽限制', ['不限速', '10 MB/s', '50 MB/s']),
        select('同名冲突默认动作', ['询问', '覆盖', '跳过', '重命名']),
      ],
      const Text('队列按 FIFO；文件夹是一个顶层任务。不发布 Windows 传输成功/失败桌面通知。'),
    ],
    '历史命令联想' => [
      if (widget.historySettingsBuilder != null)
        widget.historySettingsBuilder!(context)
      else ...[
        heading('合格单行命令'),
        toggle('记录单行命令历史', '仅可靠普通 Shell 输入；关闭后停止记录和联想，已有历史保留'),
        toggle('参与加密配置同步', '默认参与已启用的加密同步，不上传明文'),
        const SizedBox(height: 12),
        const Text('命令可能含敏感信息。正式版保守过滤密码、Token、隐藏回显与复杂 TUI 输入；不读取远端 Shell 历史。'),
        const SizedBox(height: 16),
        select('每主机保留上限', ['1000 条', '500 条', '3000 条']),
        OutlinedButton(
          onPressed: () async {
            if (await confirm(
                  context,
                  '清空命令历史？',
                  '正式版将清空所选范围的合格命令并传播删除标记，防止跨设备旧记录回灌。\n当前没有真实历史；本次仅演示确认流程。',
                  accept: '清空模拟历史',
                  danger: true,
                ) &&
                mounted) {
              notice(context, '已演示清空确认；未修改真实历史');
            }
          },
          child: const Text('清空命令历史 · 原型'),
        ),
      ],
    ],
    '彩色高亮' => [
      if (widget.displaySettingsBuilder != null)
        widget.displaySettingsBuilder!(context)
      else ...[
        heading('可见区域装饰'),
        toggle('自定义高亮规则', '不改写原文、搜索索引、复制或导出内容'),
        toggle('语义着色', '时间戳、IP、路径等低优先级显示，不发网络请求'),
        toggle('彩虹括号', '无法可靠配对时保留原状'),
        toggle('选中同词高亮', '只作用于当前可见区域'),
        toggle('复杂 TUI 保守模式', '默认关闭非必要装饰，避免遮盖远端 ANSI 色'),
        heading('示例规则 · 仅原型'),
        for (var i = 0; i < rules.length; i++)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: [Desk.danger, Desk.warning, Desk.accent][i % 3],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            title: Text(rules[i], style: const TextStyle(fontSize: 12)),
            subtitle: const Text(
              '关键词 · 远端颜色优先',
              style: TextStyle(fontSize: 10),
            ),
            trailing: Tool(
              Icons.delete_outline,
              '移除模拟规则',
              () => setState(() => rules.removeAt(i)),
            ),
          ),
        TextButton.icon(
          onPressed: () =>
              setState(() => rules.add('CUSTOM_${rules.length + 1}')),
          icon: const Icon(Icons.add, size: 15),
          label: const Text('新增示例规则'),
        ),
      ],
    ],
    '运行诊断' => [
      if (widget.diagnosticsBuilder != null)
        widget.diagnosticsBuilder!(context)
      else
        const Text('纯原型不读取 Rust 运行诊断；正式工作台提供有界内存状态记录。'),
    ],
    _ => [
      if (widget.backupSettingsBuilder != null)
        widget.backupSettingsBuilder!(context)
      else ...[
        heading('加密存储'),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.lock_outline),
          title: Text('Argon2id + AES-256-GCM', style: TextStyle(fontSize: 13)),
          subtitle: Text(
            '正式配置使用现有 Rust Vault；原型设置不写入其中',
            style: TextStyle(fontSize: 11),
          ),
        ),
        toggle(
          '设备便捷解锁',
          'Windows DPAPI / Android Keystore，不能替代数据加密',
          initial: false,
        ),
        heading('配置同步'),
        select('唯一同步目标', ['未启用', 'WebDAV', 'Google Drive']),
        const Text('只在允许的配置变化或用户主动操作时同步；不在启动时或定时同步。终端画面、滚动历史和布局不同步。'),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => notice(context, '模拟同步预览；未登录外部账号，未上传任何数据'),
              child: const Text('手动同步 · 原型'),
            ),
            OutlinedButton(
              onPressed: () => notice(context, '加密备份/恢复范围预览将在业务阶段接入；本次未读写文件'),
              child: const Text('备份与恢复 · 原型'),
            ),
          ],
        ),
      ],
    ],
  };
  Widget _buildCategory(BuildContext context) => ListView(
    key: ValueKey('settings-content-$category'),
    padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
    children: [
      Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                category,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const SizedBox(height: 12),
              for (final control in controls)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: control,
                ),
            ],
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    _panels[category] = _buildCategory(context);
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        inputDecorationTheme: theme.inputDecorationTheme.copyWith(
          helperMaxLines: 3,
          errorMaxLines: 3,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 14,
          ),
        ),
      ),
      child: SettingsLeaveScope(
        registry: _leave,
        child: Column(
          children: [
            Container(
              height: 49,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  const Text(
                    '设置',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 12),
                  if (MediaQuery.sizeOf(context).width >= 900)
                    DeskBadge(
                      widget.transferSettingsBuilder == null
                          ? '交互原型 · 不持久化'
                          : '本机加密设置',
                    ),
                  const Spacer(),
                  TextButton(
                    key: const ValueKey('settings-cancel'),
                    onPressed: _applying ? null : _cancel,
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const ValueKey('settings-apply'),
                    onPressed: _applying ? null : _apply,
                    child: Text(_applying ? '应用中…' : '应用'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('settings-ok'),
                    onPressed: _applying ? null : () => _apply(close: true),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: LayoutBuilder(
                builder: (context, bounds) => Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: bounds.maxWidth < 850 ? 166 : 210,
                      child: ListView(
                        padding: const EdgeInsets.all(9),
                        children: [
                          for (final entry in categories.entries)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: ListTile(
                                key: ValueKey('settings-${entry.key}'),
                                dense: true,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                selected: category == entry.key,
                                selectedTileColor: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: .1),
                                leading: Icon(entry.value, size: 17),
                                minLeadingWidth: 16,
                                title: Text(
                                  entry.key,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                onTap: () => _chooseCategory(entry.key),
                              ),
                            ),
                        ],
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      color: Theme.of(context).dividerColor,
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          for (final entry in _panels.entries)
                            Positioned.fill(
                              key: ValueKey('settings-category-${entry.key}'),
                              child: Offstage(
                                offstage: entry.key != category,
                                child: TickerMode(
                                  enabled: entry.key == category,
                                  child: ExcludeFocus(
                                    excluding: entry.key != category,
                                    child: SettingsLeaveScope(
                                      registry: _leave,
                                      category: entry.key,
                                      child: entry.value,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
