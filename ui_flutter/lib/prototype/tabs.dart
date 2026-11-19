import 'package:flutter/material.dart';

import '../src/rust/forwardings/runtime.dart' show RunStatus;
import '../workbench/forwarding_dialog.dart';
import '../workbench/forwarding_status.dart';
import '../workbench/model.dart';
import 'design.dart';
import 'model.dart';
import 'window_chrome.dart';

/// Distinct payload: dragging a tab cannot trigger a remote-file transfer target.
class TerminalTabDrag {
  const TerminalTabDrag(this.id);
  final String id;
}

Future<void> closeTerminalTab(
  BuildContext context,
  WorkbenchModel model,
  String id,
) async {
  final t = model.tabById(id);
  if (t == null) return;
  if (!await confirm(
    context,
    '关闭“${t.name}”？',
    model.isMock
        ? '仅关闭这个模拟 SSH 会话及其标签。其他会话和标签组保留；移动或取消分屏不会关闭连接。'
        : '关闭此SSH会话及标签，保留其他会话。未完成传输先保存并停止；收尾失败保留后台所有者，可从命令面板重试关闭。',
    accept: '关闭终端',
  )) {
    return;
  }
  model.closeTab(id);
}

Future<void> terminalTabMenu(
  BuildContext context,
  WorkbenchModel model,
  TerminalTab t,
  Offset position,
) async {
  final g = model.groupOf(t.id)!;
  // Live forwarding counts are refreshed on menu open (no polling); the mock
  // workbench has no forwarding runtime and gets no entry.
  LiveTerminalSession? live;
  if (!model.isMock && model is LiveWorkbenchModel) {
    final session = model.session(t);
    if (session is LiveTerminalSession) {
      live = session;
      if (live.controller.id != null && live.controller.connected) {
        await live.forwardings.refresh();
        if (!context.mounted) return;
      }
    }
  }
  final runs = live?.forwardings.runs.value ?? const <RunStatus>[];
  final running = forwardingRunningCount(runs),
      failed = forwardingFailedCount(runs);
  final value = await showMenu<String>(
    context: context,
    // Same (left, top, right, bottom) anchor as every other right-click menu:
    // zeroed right/bottom make Flutter treat the pointer as screen-edge
    // adjacent and reopen the menu docked to the top-right corner.
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx,
      position.dy,
    ),
    items: [
      const DeskMenuItem(value: 'rename', child: Text('重命名终端')),
      DeskMenuItem(value: 'pin', child: Text(t.pinned ? '取消固定' : '固定标签')),
      DeskMenuItem(
        value: 'connection',
        child: Text(
          model.session(t).disconnected
              ? (model.isMock ? '手动重新连接 · 模拟' : '手动重新连接')
              : '断开连接 · 保留标签',
        ),
      ),
      if (live != null)
        DeskMenuItem(
          value: 'forwardings',
          child: Text(
            failed > 0
                ? '端口转发($running 个运行中/$failed 个启动失败)'
                : '端口转发($running 个运行中)',
          ),
        ),
      const DeskMenuDivider(),
      for (final (side, name) in [
        (TabPlacement.left, '左'),
        (TabPlacement.right, '右'),
        (TabPlacement.top, '上'),
        (TabPlacement.bottom, '下'),
      ])
        DeskMenuItem(
          value: 'split:${side.name}',
          enabled: model.canSplit(t.id, g.id),
          child: Text('将此标签分屏至$name'),
        ),
      for (final other in model.layoutGroups.where((v) => v != g))
        DeskMenuItem(
          value: 'move:${other.id}',
          child: Text('移动到 ${model.tabById(other.selectedId)!.name} 所在标签组'),
        ),
      if (model.tabGroups.length > 1)
        const DeskMenuItem(value: 'merge', child: Text('取消分屏 · 合并所有标签')),
      const DeskMenuDivider(),
      const DeskMenuItem(value: 'close', child: Text('关闭终端标签')),
    ],
  );
  if (!context.mounted || model.tabById(t.id) == null) return;
  if (value == 'rename') {
    final name = await showAppDialog<String>(
      context: context,
      builder: (_) => _RenameTab(t.name),
    );
    if (name != null && model.tabById(t.id) != null) {
      t.name = name;
      model.changed();
    }
  } else if (value == 'pin') {
    model.togglePin(t.id);
  } else if (value == 'connection') {
    model.setDisconnected(t.id, !model.session(t).disconnected);
  } else if (value == 'forwardings' && live != null) {
    if (!context.mounted || model.tabById(t.id) == null) return;
    await showSavedForwardings(
      context,
      model as LiveWorkbenchModel,
      live.host.snapshot(),
      terminal: live,
    );
  } else if (value == 'close') {
    await closeTerminalTab(context, model, t.id);
  } else if (value == 'merge') {
    model.selectTab(t.id);
    model.mergeGroups();
  } else if (value?.startsWith('split:') ?? false) {
    model.moveTab(
      t.id,
      g.id,
      placement: TabPlacement.values.byName(value!.substring(6)),
    );
  } else if (value?.startsWith('move:') ?? false) {
    model.moveTab(t.id, value!.substring(5));
  }
}

/// Tab and session-list label rules (Windows workbench feedback):
/// - a terminal joined into tmux shows "base · session-name" and never a
///   number;
/// - plain shells of the same host get a creation-order number starting at 1,
///   where the first session keeps the bare base name ("主机名", "主机名 - 2").
String terminalTabLabel(WorkbenchModel model, TerminalTab t) {
  final session = model.session(t);
  final base = t.name;
  String? tmux(TerminalSession s) =>
      s is LiveTerminalSession ? s.controller.tmuxSessionName : null;
  final name = tmux(session);
  if (name != null && name.isNotEmpty) return '$base · $name';
  // model.sessions follows session creation order (map insertion order).
  final peers = model.sessions
      .where((s) => s.host.id == session.host.id && (tmux(s) ?? '').isEmpty)
      .toList();
  final index = peers.indexOf(session);
  return index > 0 ? '$base - ${index + 1}' : base;
}

class TerminalTabStrip extends StatefulWidget {
  const TerminalTabStrip({
    super.key,
    required this.model,
    required this.group,
    this.canLeave,
    this.onWindowAction,
    this.onNewTab,
  });
  final Future<void> Function(String)? onWindowAction;
  final Future<void> Function()? onNewTab;
  final WorkbenchModel model;
  final TabGroup group;
  final Future<bool> Function()? canLeave;
  @override
  State<TerminalTabStrip> createState() => _TerminalTabStripState();
}

class _TerminalTabStripState extends State<TerminalTabStrip> {
  final _scroll = ScrollController();
  String? _layout;
  WorkbenchModel get model => widget.model;
  TabGroup get group => widget.group;
  Future<bool> leave() async => await widget.canLeave?.call() ?? true;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void revealSelected(double width, double available) {
    final layout =
        '${group.id}/${group.selectedId}/$available/${group.tabs.map((t) => t.id).join(',')}';
    if (_layout == layout) return;
    _layout = layout;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _layout != layout) return;
      final index = group.tabs.indexWhere((t) => t.id == group.selectedId);
      if (index < 0) return;
      final left = index * (width + 2), right = left + width + 2;
      final position = _scroll.position;
      final offset = left < position.pixels
          ? left
          : right > position.pixels + position.viewportDimension
          ? right - position.viewportDimension
          : position.pixels;
      final target = offset.clamp(0.0, position.maxScrollExtent);
      if ((target - position.pixels).abs() > .5) _scroll.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      // Narrower default cards (Windows workbench feedback): more tabs fit
      // before scrolling; hover/selected visuals are unchanged.
      final width = ((bounds.maxWidth - 32) / group.tabs.length).clamp(
        90.0,
        150.0,
      );
      final viewport = (bounds.maxWidth - 32).clamp(0.0, double.infinity);
      final trailing = widget.onNewTab == null ? 0.0 : 30.0;
      final contentWidth = group.tabs.length * (width + 2) + 28 + trailing;
      final spare = (viewport - contentWidth).clamp(0.0, double.infinity);
      revealSelected(width, viewport);
      return Row(
        children: [
          SizedBox(
            width: widget.onWindowAction == null ? viewport : viewport - spare,
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (i, t) in group.tabs.indexed)
                    DragTarget<TerminalTabDrag>(
                      onWillAcceptWithDetails: (d) =>
                          d.data.id != t.id && model.tabById(d.data.id) != null,
                      onAcceptWithDetails: (d) {
                        final box = context.findRenderObject()! as RenderBox;
                        // Dropping onto a tab inserts before it; dropping on strip space appends.
                        if (box.attached) {
                          model.moveTab(d.data.id, group.id, beforeTabId: t.id);
                        }
                      },
                      builder: (context, candidates, _) =>
                          Draggable<TerminalTabDrag>(
                            key: ValueKey('tab-${t.id}'),
                            data: TerminalTabDrag(t.id),
                            dragAnchorStrategy: pointerDragAnchorStrategy,
                            maxSimultaneousDrags:
                                model.page == WorkPage.workspace ? 1 : 0,
                            feedback: Material(
                              elevation: 6,
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(4),
                              child: SizedBox(
                                width: 180,
                                height: 34,
                                child: Center(
                                  child: Text(
                                    terminalTabLabel(model, t),
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              ),
                            ),
                            childWhenDragging: Opacity(
                              opacity: .3,
                              child: _tab(context, t, width, false),
                            ),
                            child: _tab(
                              context,
                              t,
                              width,
                              candidates.isNotEmpty,
                              separator:
                                  i > 0 &&
                                  !_activeTab(group.tabs[i - 1]) &&
                                  !_activeTab(t),
                            ),
                          ),
                    ),
                  DragTarget<TerminalTabDrag>(
                    onWillAcceptWithDetails: (d) =>
                        model.tabById(d.data.id) != null,
                    onAcceptWithDetails: (d) =>
                        model.moveTab(d.data.id, group.id),
                    builder: (_, candidates, _) => Container(
                      key: ValueKey('tab-end-${group.id}'),
                      width: 28,
                      height: 35,
                      color: candidates.isEmpty
                          ? null
                          : Theme.of(context).colorScheme.primary
                                .withValues(alpha: .2),
                    ),
                  ),
                  // Browser-style trailing new-tab button: flows after the
                  // last card instead of the former fixed top-right slot.
                  if (widget.onNewTab != null)
                    SizedBox(
                      width: 30,
                      child: IconButton(
                        key: const ValueKey('new-terminal'),
                        tooltip: '新建终端标签',
                        onPressed: () async {
                          if (await leave()) await widget.onNewTab!();
                        },
                        icon: const Icon(Icons.add, size: 15),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (widget.onWindowAction != null && spare > 0)
            SizedBox(
              width: spare,
              height: 43,
              child: DragTarget<TerminalTabDrag>(
                onWillAcceptWithDetails: (d) =>
                    model.tabById(d.data.id) != null,
                onAcceptWithDetails: (d) => model.moveTab(d.data.id, group.id),
                builder: (_, candidates, _) => WindowDragRegion(
                  onAction: widget.onWindowAction!,
                  child: ColoredBox(
                    color: candidates.isEmpty
                        ? Colors.transparent
                        : Theme.of(context).colorScheme.primary
                              .withValues(alpha: .2),
                  ),
                ),
              ),
            ),
          SizedBox(
            width: 32,
            child: PopupMenuButton<String>(
              key: ValueKey('tab-overflow-${group.id}'),
              // One navigation menu: every session across all groups, so the
              // former separate global-session list stays unnecessary.
              tooltip: '全部 SSH 会话 · 仅导航',
              icon: const Icon(Icons.keyboard_arrow_down, size: 15),
              padding: EdgeInsets.zero,
              onSelected: (id) async {
                if (await leave()) model.selectTab(id);
              },
              itemBuilder: (_) => [
                for (final g in model.layoutGroups)
                  for (final t in g.tabs)
                    DeskMenuItem(
                      value: t.id,
                      child: Text(
                        '${t.pinned ? '固定 · ' : ''}${terminalTabLabel(model, t)}'
                        '${model.tabGroups.length > 1 ? ' · 区域 ${model.layoutGroups.indexOf(g) + 1}' : ''}'
                        '${model.session(t).disconnected ? ' · 已断开' : ''}',
                      ),
                    ),
              ],
            ),
          ),
        ],
      );
    },
  );

  /// Selected card in the workspace page: the one card without a divider
  /// beside it and with the accent bar and page background.
  bool _activeTab(TerminalTab t) =>
      group.selectedId == t.id &&
      !model.startPage &&
      model.page == WorkPage.workspace;
  Widget _tab(
    BuildContext context,
    TerminalTab t,
    double width,
    bool target, {
    bool separator = false,
  }) {
    final active = _activeTab(t);
    final session = model.session(t);
    final live =
        !model.isMock &&
            model is LiveWorkbenchModel &&
            session is LiveTerminalSession
        ? session
        : null;
    return Tooltip(
      message:
          '${terminalTabLabel(model, t)}\n${model.session(t).host.user}@${model.session(t).host.address} · ${model.isMock ? (model.session(t).disconnected ? '已断开' : '模拟连接') : model.session(t).statusLabel}\n拖到标签调整顺序；拖到终端边缘分屏',
      child: GestureDetector(
        onTap: () async {
          if (await leave()) model.selectTab(t.id);
        },
        onSecondaryTapDown: (d) async {
          if (await leave() && context.mounted) {
            terminalTabMenu(context, model, t, d.globalPosition);
          }
        },
        child: Container(
          width: width,
          height: 35,
          margin: const EdgeInsets.only(left: 2, top: 3),
          // A divider card trades 8px of leading padding for the short
          // separator line, so icon/text offsets and the strip layout
          // (per-card width, reveal math) stay byte-identical.
          padding: EdgeInsets.only(left: separator ? 1 : 9),
          decoration: BoxDecoration(
            color: target
                ? Theme.of(context).colorScheme.primary.withValues(alpha: .18)
                : active
                ? Theme.of(context).scaffoldBackgroundColor
                : null,
            border: active
                ? Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  )
                : null,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
          ),
          child: Row(
            children: [
              if (separator) ...[
                Container(
                  width: 1,
                  height: 14,
                  color: Theme.of(context).dividerColor.withValues(alpha: .6),
                ),
                const SizedBox(width: 7),
              ],
              Icon(
                t.pinned ? Icons.push_pin_outlined : Icons.circle,
                size: t.pinned ? 12 : 6,
                color: model.session(t).disconnected
                    ? Desk.warning
                    : Desk.accent,
              ),
              const SizedBox(width: 7),
              // Event-driven forwarding state: a warning mark survives as long
              // as a start failed; hover lists every listener and its phase.
              if (live != null)
                ValueListenableBuilder<List<RunStatus>>(
                  valueListenable: live.forwardings.runs,
                  builder: (context, runs, _) {
                    if (runs.isEmpty) return const SizedBox.shrink();
                    final failed = forwardingFailedCount(runs),
                        running = forwardingRunningCount(runs);
                    return Tooltip(
                      message: failed > 0
                          ? '端口转发：$running 个运行中 · $failed 个启动失败\n${describeForwardingRuns(runs)}'
                          : '端口转发：$running 个运行中\n${describeForwardingRuns(runs)}',
                      child: Icon(
                        Icons.alt_route,
                        size: 12,
                        color: failed > 0 ? Desk.warning : Desk.accent,
                      ),
                    );
                  },
                ),
              if (live != null) const SizedBox(width: 6),
              Expanded(
                child: Text(
                  terminalTabLabel(model, t),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              if (!t.pinned)
                Tool(Icons.close, '关闭终端标签', () async {
                  if (await leave() && context.mounted) {
                    closeTerminalTab(context, model, t.id);
                  }
                }, size: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _RenameTab extends StatefulWidget {
  const _RenameTab(this.initial);
  final String initial;
  @override
  State<_RenameTab> createState() => _RenameTabState();
}

class _RenameTabState extends State<_RenameTab> {
  late final name = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('重命名终端'),
    content: TextField(
      controller: name,
      autofocus: true,
      onSubmitted: (s) {
        if (s.trim().isNotEmpty) Navigator.pop(context, s.trim());
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (name.text.trim().isNotEmpty) {
            Navigator.pop(context, name.text.trim());
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}
