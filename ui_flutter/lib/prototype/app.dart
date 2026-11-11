import 'operation_notice.dart';
import '../app_notice.dart';
import '../run_log.dart';
import '../terminal/application_keys.dart';
import 'command_palette.dart';

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design.dart';
import 'files.dart';
import 'hosts.dart';
import 'model.dart';
import 'settings.dart';
import 'workspace.dart';
import 'tabs.dart';
import 'window_chrome.dart';

const prototypeWindow = MethodChannel('hspterm/prototype_window');

class PrototypeApp extends StatefulWidget {
  const PrototypeApp({
    super.key,
    this.model,
    this.terminalBuilder,
    this.sidebarBuilder,
    this.transferSettingsBuilder,
    this.fileOpenSettingsBuilder,
    this.sshNetworkSettingsBuilder,
    this.displaySettingsBuilder,
    this.historySettingsBuilder,
    this.navigatorKey,
    this.extraCommands,
    this.paletteBinding = const PaletteBinding(),
    this.paletteSettingsBuilder,
    this.typographySettingsBuilder,
    this.terminalPreferencesBuilder,
    this.diagnosticsBuilder,
    this.statusBarBuilder,
    this.noticeBuilder,
    this.backupSettingsBuilder,
    this.appearanceSettingsBuilder,
    this.sftpViewSettingsBuilder,
  });
  final WorkbenchModel? model;
  final TerminalSurfaceBuilder? terminalBuilder;
  final WidgetBuilder? sidebarBuilder;
  final WidgetBuilder? transferSettingsBuilder;
  final WidgetBuilder? fileOpenSettingsBuilder;
  final WidgetBuilder? sshNetworkSettingsBuilder;
  final WidgetBuilder? displaySettingsBuilder;
  final WidgetBuilder? historySettingsBuilder;
  final GlobalKey<NavigatorState>? navigatorKey;
  final List<AppCommand> Function()? extraCommands;
  final PaletteBinding paletteBinding;
  final WidgetBuilder? paletteSettingsBuilder;
  final WidgetBuilder? typographySettingsBuilder;
  final WidgetBuilder? terminalPreferencesBuilder;
  final WidgetBuilder? diagnosticsBuilder;
  final WidgetBuilder? statusBarBuilder;
  final WidgetBuilder? noticeBuilder;
  final WidgetBuilder? backupSettingsBuilder;
  final WidgetBuilder? appearanceSettingsBuilder;
  final WidgetBuilder? sftpViewSettingsBuilder;
  @override
  State<PrototypeApp> createState() => PrototypeAppState();
}

class PrototypeAppState extends State<PrototypeApp> {
  late final WorkbenchModel m;
  final _hosts = GlobalKey<HostManagerState>();
  final _settings = GlobalKey<SettingsPageState>();
  final _navigator = GlobalKey<NavigatorState>();
  late final AppLifecycleListener _lifecycle;
  Future<AppExitResponse>? _exitDecision;
  bool _exitApproved = false, _commandPanelOpen = false;
  final _recentCommands = RecentAppCommands();
  String _settingsCategory = '外观';
  @override
  void initState() {
    super.initState();
    m = widget.model ?? WorkbenchModel();
    _lifecycle = AppLifecycleListener(onExitRequested: _requestExit);
    unawaited(_initializeWindow());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    if (widget.model == null) m.dispose();
    super.dispose();
  }

  Future<bool> leave() async {
    if (m.page == WorkPage.hosts) {
      return await (_hosts.currentState?.canLeave() ?? Future.value(true));
    }
    if (m.page == WorkPage.settings) {
      return await (_settings.currentState?.canLeave() ?? Future.value(true));
    }
    return true;
  }

  Future<void> navigate(WorkPage p) async {
    if (p == m.page || await leave()) m.show(p);
  }

  /// Shared by local tabs and external notification activation. Capture an ID,
  /// never navigate directly around draft guards or resurrect a closed target.
  Future<bool> activateTab(String id) async {
    if (!mounted || m.isClosing || m.tabById(id) == null) return false;
    if (!await leave()) return false;
    if (!mounted || m.isClosing || m.tabById(id) == null) return false;
    m.selectTab(id);
    return true;
  }

  Future<void> tab(String id) async {
    await activateTab(id);
  }

  Future<void> _initializeWindow() async {
    try {
      await prototypeWindow.invokeMethod<void>('initialize');
      AppRunLog.instance.event(AppLogEvent.windowReady);
    } on MissingPluginException {
      // A runner without optional custom-frame support retains system controls.
    } on PlatformException catch (error, stack) {
      AppRunLog.instance.event(
        AppLogEvent.windowFailed,
        error: error,
        stack: stack,
      );
      // System decorations remain available if optional window hints fail.
    }
  }

  Future<AppExitResponse> _requestExit() {
    if (_exitApproved) return Future.value(AppExitResponse.exit);
    return _exitDecision ??= _decideExit().whenComplete(
      () => _exitDecision = null,
    );
  }

  Future<AppExitResponse> _decideExit() async {
    final context = (widget.navigatorKey ?? _navigator).currentContext;
    if (context == null || !mounted) return AppExitResponse.exit;
    if (m.activeTransferCount > 0 ||
        m.hasPendingExternalDelivery ||
        m.hasActiveSessions ||
        m.hasActiveEditors) {
      if (!await confirm(
        context,
        m.isMock ? '退出 HSPTerm 原型？' : '退出 HSPTerm？',
        m.isMock
            ? '还有模拟会话或传输任务。关闭后原型数据不会保留；正式版将在退出前保存未完成任务并有序释放连接。'
            : m.hasActiveEditors
            ? '还有活动编辑文档。退出将停止当前编辑操作、保留本机加密草稿，关闭连接并释放终端临时历史。'
            : '还有活动 SSH 会话。退出将关闭连接并释放终端临时历史。',
        accept: '退出',
      )) {
        return AppExitResponse.cancel;
      }
    }
    if (!await leave()) return AppExitResponse.cancel;
    try {
      await m.shutdown();
    } catch (error) {
      if (context.mounted) {
        notice(context, '退出前保存或资源释放失败，未退出：$error', level: AppNoticeLevel.error);
      }
      return AppExitResponse.cancel;
    }
    return AppExitResponse.exit;
  }

  Future<void> window(BuildContext context, String method) async {
    if (method == 'close') {
      if (await _requestExit() != AppExitResponse.exit) return;
      _exitApproved = true;
    }
    try {
      await prototypeWindow.invokeMethod<void>(method);
    } on MissingPluginException {
      _exitApproved = false;
      if (context.mounted) notice(context, '本平台原生窗口按钮尚未接入；请使用系统标题栏。');
    } on PlatformException {
      _exitApproved = false;
      if (context.mounted) notice(context, '原生窗口操作不可用；请使用系统标题栏。');
    }
  }

  Future<void> commandPanel(BuildContext context) async {
    if (_commandPanelOpen) return;
    _commandPanelOpen = true;
    try {
      final commands = <AppCommand>[
        ...(widget.extraCommands?.call() ?? const <AppCommand>[]),
        AppCommand('hosts', '主机管理', () => navigate(WorkPage.hosts)),
        AppCommand('settings', '设置与字体', () async {
          _settingsCategory = '外观';
          await navigate(WorkPage.settings);
        }),
        AppCommand('new-terminal', '新建终端标签', () async {
          if (await leave()) m.newTab();
        }),
        if (m.focus != null) ...[
          AppCommand(
            'sftp',
            '打开或收起 SFTP',
            m.toggleSidebar,
            available: () => m.focus != null,
          ),
          AppCommand('queue', '打开传输任务队列', () {
            m.sidebar = true;
            m.queueMaximized = true;
            m.filesMaximized = false;
            m.changed();
          }, available: () => m.focus != null),
        ],
        for (final t in m.tabs)
          AppCommand(
            'session:${t.id}',
            '切换终端 · ${t.name}',
            () => tab(t.id),
            available: () => m.tabById(t.id) != null,
          ),
      ];
      final selected = await showAppCommandPalette(
        context,
        commands: commands,
        recent: _recentCommands,
        changes: Listenable.merge([
          m,
          ...commands
              .map((c) => c.availableChanges)
              .whereType<Listenable>()
              .toSet(),
        ]),
      );
      if (!mounted || selected == null || !selected.allowed) return;
      _recentCommands.record(selected.id);
      await selected.run();
    } catch (error) {
      if (mounted) m.reportOperation(error);
    } finally {
      _commandPanelOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: m,
    builder: (_, _) => MaterialApp(
      title: m.isMock ? 'HSPTerm · UI 原型' : 'HSPTerm',
      navigatorKey: widget.navigatorKey ?? _navigator,
      debugShowCheckedModeBanner: false,
      theme: Desk.theme(m.light),
      builder: (_, child) => ApplicationKeyScope(
        binding: widget.paletteBinding,
        openPalette: () async {
          final context = (widget.navigatorKey ?? _navigator).currentContext;
          if (mounted && context != null) await commandPanel(context);
        },
        child: child!,
      ),
      home: Builder(
        builder: (context) => CallbackShortcuts(
          bindings: {
            const SingleActivator(
              LogicalKeyboardKey.keyT,
              control: true,
              shift: true,
            ): () async {
              if (await leave()) m.newTab();
            },
          },
          child: Scaffold(
            body: Column(
              children: [
                Container(
                  height: 43,
                  color: Theme.of(context).colorScheme.surface,
                  child: Row(
                    children: [
                      const SizedBox(width: 10),
                      GestureDetector(
                        onPanStart: (_) => window(context, 'drag'),
                        onDoubleTap: () => window(context, 'maximize'),
                        onSecondaryTapUp: NativeMaximizeRegion.supported
                            ? (_) => window(context, 'systemMenu')
                            : null,
                        child: Container(
                          width: 27,
                          height: 27,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary
                                .withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            Icons.terminal,
                            color: Theme.of(context).colorScheme.primary,
                            size: 18,
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                      WindowDragRegion(
                        onAction: (action) => window(context, action),
                        child: const Text(
                          'HSPTerm',
                          style: TextStyle(
                            fontFamily: Desk.mono,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Tool(
                        Icons.dns_outlined,
                        '主机管理',
                        () => navigate(WorkPage.hosts),
                        active: m.page == WorkPage.hosts,
                        key: const ValueKey('nav-hosts'),
                      ),
                      Expanded(
                        child: m.tabGroups.length == 1
                            ? TerminalTabStrip(
                                model: m,
                                group: m.layoutGroups.single,
                                canLeave: leave,
                                onWindowAction: (action) =>
                                    window(context, action),
                              )
                            : Row(
                                children: [
                                  const SizedBox(width: 12),
                                  if (m.tabs.isNotEmpty)
                                    Flexible(
                                      flex: 2,
                                      child: Text(
                                        '${m.tabs.length} 个终端 · ${m.tabGroups.length} 个标签组',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Theme.of(context).hintColor,
                                        ),
                                      ),
                                    ),
                                  Expanded(
                                    child: WindowDragRegion(
                                      onAction: (action) =>
                                          window(context, action),
                                      child: const SizedBox.expand(),
                                    ),
                                  ),
                                  if (m.focusedGroup != null &&
                                      (m.page != WorkPage.workspace ||
                                          m.startPage))
                                    TextButton(
                                      onPressed: () =>
                                          tab(m.focusedGroup!.selectedId),
                                      child: const Text('返回终端'),
                                    ),
                                  if (m.maximizedGroupId != null)
                                    TextButton.icon(
                                      onPressed: () =>
                                          m.maximize(m.maximizedGroupId!),
                                      icon: const Icon(
                                        Icons.fullscreen_exit,
                                        size: 15,
                                      ),
                                      label: const Text('恢复布局'),
                                    ),
                                ],
                              ),
                      ),
                      if (m.tabGroups.length == 1 &&
                          m.page == WorkPage.workspace &&
                          !m.startPage)
                        GroupActions(model: m, group: m.layoutGroups.single),
                      Tool(Icons.add, '新建终端标签', () async {
                        if (await leave()) m.newTab();
                      }, key: const ValueKey('new-terminal')),
                      PopupMenuButton<String>(
                        key: const ValueKey('app-menu'),
                        tooltip: '应用菜单',
                        icon: const Icon(Icons.more_horiz, size: 18),
                        onSelected: (s) {
                          if (s == 'settings') {
                            _settingsCategory = '外观';
                            navigate(WorkPage.settings);
                          }
                          if (s == 'commands') commandPanel(context);
                          if (s == 'theme') {
                            m.chooseTheme(!m.light);
                          }
                          if (s == 'sync') {
                            if (widget.backupSettingsBuilder == null) {
                              notice(context, '配置同步为原型入口；未连接外部服务');
                            } else {
                              _settingsCategory = '加密与同步';
                              navigate(WorkPage.settings);
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          const DeskMenuItem(
                            value: 'settings',
                            child: Text('设置'),
                          ),
                          const DeskMenuItem(
                            value: 'commands',
                            child: Text('应用命令面板'),
                          ),
                          DeskMenuItem(
                            value: 'theme',
                            enabled: m.themeAvailable,
                            child: Text('切换深色 / 浅色'),
                          ),
                          const DeskMenuDivider(),
                          DeskMenuItem(
                            value: 'sync',
                            child: Text(
                              widget.backupSettingsBuilder == null
                                  ? '配置同步 / 导入导出 · 原型'
                                  : '加密备份 / 恢复与同步',
                            ),
                          ),
                        ],
                      ),
                      Tool(
                        Icons.remove,
                        '最小化窗口',
                        () => window(context, 'minimize'),
                        size: 15,
                      ),
                      NativeMaximizeRegion(
                        child: Tool(
                          Icons.crop_square,
                          '最大化 / 还原窗口',
                          () => window(context, 'maximize'),
                          size: 13,
                        ),
                      ),
                      Tool(
                        Icons.close,
                        '关闭窗口',
                        () => window(context, 'close'),
                        size: 16,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (widget.noticeBuilder != null)
                  widget.noticeBuilder!(context),
                OperationNotice(model: m),
                Expanded(
                  child: switch (m.page) {
                    WorkPage.hosts => HostManager(key: _hosts, model: m),
                    WorkPage.settings => SettingsPage(
                      key: _settings,
                      appearanceSettingsBuilder:
                          widget.appearanceSettingsBuilder,
                      sftpViewSettingsBuilder: widget.sftpViewSettingsBuilder,
                      initialCategory: _settingsCategory,
                      model: m,
                      transferSettingsBuilder: widget.transferSettingsBuilder,
                      backupSettingsBuilder: widget.backupSettingsBuilder,
                      displaySettingsBuilder: widget.displaySettingsBuilder,
                      historySettingsBuilder: widget.historySettingsBuilder,
                      paletteSettingsBuilder: widget.paletteSettingsBuilder,
                      typographySettingsBuilder:
                          widget.typographySettingsBuilder,
                      terminalPreferencesBuilder:
                          widget.terminalPreferencesBuilder,
                      diagnosticsBuilder: widget.diagnosticsBuilder,
                      fileOpenSettingsBuilder: widget.fileOpenSettingsBuilder,
                      sshNetworkSettingsBuilder:
                          widget.sshNetworkSettingsBuilder,
                    ),
                    WorkPage.workspace =>
                      m.startPage || m.root == null
                          ? StartPage(
                              model: m,
                              manage: () => navigate(WorkPage.hosts),
                              create: () async {
                                await navigate(WorkPage.hosts);
                                await WidgetsBinding.instance.endOfFrame;
                                if (m.page == WorkPage.hosts) {
                                  _hosts.currentState?.choose(null);
                                }
                              },
                            )
                          : _WorkbenchBody(
                              model: m,
                              terminalBuilder: widget.terminalBuilder,
                              sidebarBuilder: widget.sidebarBuilder,
                            ),
                  },
                ),
                Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    border: Border(
                      top: BorderSide(color: Theme.of(context).dividerColor),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.science_outlined,
                        size: 13,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      // Flexible: a long quiet notice ellipsizes instead of
                      // widening the fixed-height status row.
                      const Flexible(child: QuietNoticeView()),
                      Text(
                        m.isMock ? 'UI 原型 · 模拟数据 · 不连接服务器' : 'HSPTerm · SSH',
                        style: TextStyle(fontSize: 10),
                      ),
                      if (widget.statusBarBuilder != null)
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: widget.statusBarBuilder!(context),
                          ),
                        )
                      else ...[
                        const Spacer(),
                        if (m.focus != null)
                          Text(
                            m.isMock
                                ? 'RTT —  ·  PTY 模拟  ·  ${m.transfers.length} 个任务'
                                : '${m.focus!.statusLabel} · ${m.sessions.length} 个终端 · ${m.totalTransferCount} 个任务',
                            style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                      ],
                      const SizedBox(width: 12),
                      Text(
                        m.light ? '浅色' : '深色',
                        style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _WorkbenchBody extends StatelessWidget {
  const _WorkbenchBody({
    required this.model,
    this.terminalBuilder,
    this.sidebarBuilder,
  });
  final WorkbenchModel model;
  final TerminalSurfaceBuilder? terminalBuilder;
  final WidgetBuilder? sidebarBuilder;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, b) {
      final m = model;
      final width = m.filesMaximized
          ? b.maxWidth
          : m.sidebarWidth
                .clamp(276, (b.maxWidth - 245).clamp(276, 660))
                .toDouble();
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (m.sidebar)
            SizedBox(
              width: width,
              child: sidebarBuilder?.call(context) ?? SftpSidebar(model: m),
            )
          else
            Container(
              width: 42,
              color: Theme.of(context).colorScheme.surface,
              child: Column(
                children: [
                  const SizedBox(height: 4),
                  Tool(
                    Icons.folder_open_outlined,
                    '展开 SFTP',
                    m.toggleSidebar,
                    key: const ValueKey('expand-sftp'),
                  ),
                  Tool(Icons.swap_vert, '打开传输队列', m.queueToggle),
                  if (m.hasTransferErrors)
                    const Padding(
                      padding: EdgeInsets.only(top: 5),
                      child: Icon(
                        Icons.error_outline,
                        size: 14,
                        color: Desk.warning,
                      ),
                    ),
                ],
              ),
            ),
          if (!m.filesMaximized || !m.sidebar) ...[
            if (m.sidebar)
              ResizeGrip(
                key: const ValueKey('sidebar-grip'),
                horizontal: true,
                onDelta: (d) {
                  // Accumulate against the live value: a build-time base
                  // loses pan deltas that arrive between rebuilds (visible
                  // as the grip lagging behind the pointer at high input
                  // rates / display scaling).
                  // Upper bound: never stretch far past the SFTP panel's
                  // real column content into dead space. The window bound
                  // still applies, and the minimum wins when the content
                  // is narrower than it.
                  final windowBound = (b.maxWidth - 245).clamp(276.0, 660.0);
                  final content = m.sftpContentBound;
                  final upper = content <= 0
                      ? windowBound
                      : content.clamp(276.0, windowBound);
                  m.sidebarWidth = (m.sidebarWidth + d).clamp(276, upper);
                  m.changed();
                },
              ),
            Expanded(
              child: TerminalWorkspace(
                model: m,
                terminalBuilder: terminalBuilder,
              ),
            ),
          ],
        ],
      );
    },
  );
}

class StartPage extends StatefulWidget {
  const StartPage({
    super.key,
    required this.model,
    required this.manage,
    required this.create,
  });
  final WorkbenchModel model;
  final VoidCallback manage, create;
  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  String? selected;
  final focus = FocusNode();
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focus,
    onKeyEvent: (_, e) {
      if (e is KeyDownEvent &&
          e.logicalKey == LogicalKeyboardKey.enter &&
          selected != null) {
        widget.model.openHost(
          widget.model.hosts.firstWhere((h) => h.id == selected),
        );
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: LayoutBuilder(
      builder: (context, b) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    DeskBadge('SSH / SFTP'),
                    SizedBox(width: 8),
                    Text(
                      'Windows 工作台预览',
                      style: TextStyle(fontSize: 11, color: Color(0xff8090a0)),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text(
                  '开始新的连接',
                  style: TextStyle(
                    fontSize: 29,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.5,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '选择已保存的主机，打开独立 SSH 终端标签。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ),
                const SizedBox(height: 25),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: selected,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: widget.model.isMock ? '选择模拟主机' : '选择已保存主机',
                          prefixIcon: Icon(Icons.dns_outlined, size: 17),
                        ),
                        items: [
                          for (final h in widget.model.hosts)
                            DropdownMenuItem(
                              value: h.id,
                              child: Text(
                                h.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => selected = v),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      key: const ValueKey('quick-connect'),
                      onPressed: selected == null
                          ? null
                          : () => widget.model.openHost(
                              widget.model.hosts.firstWhere(
                                (h) => h.id == selected,
                              ),
                            ),
                      icon: const Icon(Icons.arrow_forward, size: 16),
                      label: const Text('连接'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 5,
                  children: [
                    TextButton.icon(
                      onPressed: widget.create,
                      icon: const Icon(Icons.add, size: 15),
                      label: const Text('新建主机'),
                    ),
                    TextButton.icon(
                      onPressed: widget.manage,
                      icon: const Icon(Icons.dns_outlined, size: 15),
                      label: const Text('主机管理'),
                    ),
                    if (widget.model.isMock)
                      TextButton.icon(
                        key: const ValueKey('open-demo'),
                        onPressed: widget.model.demo,
                        icon: const Icon(
                          Icons.dashboard_customize_outlined,
                          size: 15,
                        ),
                        label: const Text('打开示例工作台'),
                      ),
                  ],
                ),
                const SizedBox(height: 26),
                LayoutBuilder(
                  builder: (context, inner) {
                    Widget group(String title, List<DemoHost> hosts) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                        ),
                        ...hosts.map(
                          (h) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: SelectionTarget(
                              key: ValueKey('home-$title-${h.id}'),
                              onTapDown: (_) {
                                setState(() => selected = h.id);
                                focus.requestFocus();
                              },
                              onDoubleTap: () => widget.model.openHost(h),
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surface,
                                  border: Border.all(
                                    color: selected == h.id
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context).dividerColor,
                                  ),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 31,
                                      height: 31,
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: .08),
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: Icon(
                                        Icons.terminal,
                                        size: 17,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            h.name,
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            '${h.user}@${h.address}',
                                            style: TextStyle(
                                              fontFamily: Desk.mono,
                                              fontSize: 10,
                                              color: Theme.of(context)
                                                  .hintColor,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      h.favorite
                                          ? Icons.star_outline
                                          : Icons.history,
                                      size: 14,
                                      color: Theme.of(context).hintColor,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                    final favorites = group(
                          '收藏主机',
                          widget.model.hosts
                              .where((h) => h.favorite)
                              .take(3)
                              .toList(),
                        ),
                        // Order follows the most-recent-first list, not the
                        // catalog ordering; unknown IDs stay hidden.
                        recent = group(
                          widget.model.isMock ? '最近使用 · 模拟' : '最近使用',
                          widget.model.recent
                              .map(
                                (id) => widget.model.hosts
                                    .where((h) => h.id == id)
                                    .firstOrNull,
                              )
                              .whereType<DemoHost>()
                              .take(3)
                              .toList(),
                        );
                    return inner.maxWidth >= 700
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: favorites),
                              const SizedBox(width: 18),
                              Expanded(child: recent),
                            ],
                          )
                        : Column(
                            children: [
                              favorites,
                              const SizedBox(height: 10),
                              recent,
                            ],
                          );
                  },
                ),
                const SizedBox(height: 15),
                Text(
                  widget.model.isMock
                      ? '双击主机卡片或选择后按 Enter 连接 · 本原型不会进行网络请求'
                      : '选择已保存的主机后连接 · 每个标签拥有独立 SSH 会话',
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
