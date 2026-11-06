import '../workbench/agent_dialog.dart';
import '../workbench/remote_inspection_panel.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design.dart';
import '../workbench/model.dart';
import '../workbench/forwarding_dialog.dart';
import 'model.dart';
import 'tabs.dart';
import 'terminal_preview.dart';

typedef TerminalSurfaceBuilder = Widget Function(
  BuildContext context,
  TerminalSession session,
);

class TerminalWorkspace extends StatelessWidget {
  const TerminalWorkspace({
    super.key,
    required this.model,
    this.terminalBuilder,
  });
  final WorkbenchModel model;
  final TerminalSurfaceBuilder? terminalBuilder;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 3, 5, 5),
    child: model.maximizedGroupId != null
        ? TerminalGroup(
            model: model,
            group: model.tabGroups[model.maximizedGroupId]!,
            terminalBuilder: terminalBuilder,
          )
        : _Tree(
            model: model,
            node: model.root!,
            terminalBuilder: terminalBuilder,
          ),
  );
}

Size _minimum(SplitTree node) {
  if (node is GroupLeaf) return const Size(240, 190);
  final s = node as GroupSplit, a = _minimum(s.first), b = _minimum(s.second);
  return s.horizontal
      ? Size(a.width + b.width + 7, math.max(a.height, b.height))
      : Size(math.max(a.width, b.width), a.height + b.height + 7);
}

class _Tree extends StatelessWidget {
  const _Tree({required this.model, required this.node, this.terminalBuilder});
  final WorkbenchModel model;
  final SplitTree node;
  final TerminalSurfaceBuilder? terminalBuilder;
  @override
  Widget build(BuildContext context) {
    if (node case GroupLeaf(:final groupId)) {
      return TerminalGroup(
        key: ValueKey(groupId),
        model: model,
        group: model.tabGroups[groupId]!,
        terminalBuilder: terminalBuilder,
      );
    }
    final s = node as GroupSplit;
    return LayoutBuilder(
      builder: (c, bounds) {
        final minimum = _minimum(node);
        if (bounds.maxWidth < minimum.width ||
            bounds.maxHeight < minimum.height) {
          final ids = node.groupIds.toList();
          final id = ids.contains(model.focusedGroupId)
              ? model.focusedGroupId!
              : ids.first;
          return Column(
            children: [
              SizedBox(
                height: 30,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 6),
                      child: Text(
                        '空间不足 · 临时折叠',
                        style: TextStyle(fontSize: 10),
                      ),
                    ),
                    for (final gid in ids)
                      TextButton(
                        onPressed: () => model.focusGroup(gid),
                        child: Text(
                          model.tabGroups[gid]!.selected.name,
                          style: TextStyle(
                            fontSize: 10,
                            color: gid == id
                                ? Theme.of(c).colorScheme.primary
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: TerminalGroup(
                  key: ValueKey(id),
                  model: model,
                  group: model.tabGroups[id]!,
                  terminalBuilder: terminalBuilder,
                ),
              ),
            ],
          );
        }
        final length = (s.horizontal ? bounds.maxWidth : bounds.maxHeight) - 7;
        final a = _minimum(s.first), b = _minimum(s.second);
        final low = (s.horizontal ? a.width : a.height) / length,
            high = 1 - (s.horizontal ? b.width : b.height) / length;
        final ratio = s.ratio.clamp(low, high);
        Widget area(SplitTree n, double size) => SizedBox(
          width: s.horizontal ? size : null,
          height: s.horizontal ? null : size,
          child: _Tree(model: model, node: n, terminalBuilder: terminalBuilder),
        );
        final children = [
          area(s.first, length * ratio),
          ResizeGrip(
            key: ValueKey(
              'split-grip-${s.first.groupIds.first}-${s.second.groupIds.first}',
            ),
            horizontal: s.horizontal,
            onDelta: (d) {
              // Live-state accumulation; the build-time `ratio` base drops
              // deltas that fire between rebuilds.
              s.ratio = (s.ratio + d / length).clamp(low, high);
              model.changed();
            },
          ),
          area(s.second, length * (1 - ratio)),
        ];
        return s.horizontal
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              );
      },
    );
  }
}

class GroupActions extends StatelessWidget {
  const GroupActions({super.key, required this.model, required this.group});
  final WorkbenchModel model;
  final TabGroup group;
  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: ValueKey('group-menu-${group.id}'),
    tooltip: '标签组布局',
    icon: const Icon(Icons.splitscreen_outlined, size: 16),
    padding: EdgeInsets.zero,
    itemBuilder: (_) => [
      const DeskMenuItem(value: 'forwardings', child: Text('当前终端端口转发')),
      const DeskMenuItem(value: 'agent', child: Text('应用内 Agent · 限时授权')),
      const DeskMenuItem(value: 'inspection', child: Text('远端资源与进程 · 可选')),
      const DeskMenuDivider(),
      for (final (side, label) in [
        (TabPlacement.left, '左'),
        (TabPlacement.right, '右'),
        (TabPlacement.top, '上'),
        (TabPlacement.bottom, '下'),
      ])
        DeskMenuItem(
          value: side.name,
          enabled: model.canSplit(group.selectedId, group.id),
          child: Text('当前标签分屏至$label'),
        ),
      if (group.tabs.length == 1)
        const DeskMenuItem(enabled: false, child: Text('先打开另一个终端标签即可分屏')),
      if (model.tabGroups.length > 1) ...[
        const DeskMenuDivider(),
        DeskMenuItem(
          value: 'max',
          child: Text(
            model.maximizedGroupId == group.id ? '恢复原分屏布局' : '临时最大化此区域',
          ),
        ),
        const DeskMenuItem(value: 'merge', child: Text('取消分屏 · 合并所有标签')),
      ],
    ],
    onSelected: (value) {
      if (value == 'inspection') {
        final tab = model.tabById(group.selectedId);
        if (!context.mounted || tab == null) return;
        if (model.isMock) {
          notice(context, '模拟终端不探测远端资源或读取进程');
        } else {
          showRemoteInspection(
            context,
            model.session(tab) as LiveTerminalSession,
          );
        }
      } else if (value == 'agent') {
        final tab = model.tabById(group.selectedId);
        if (!context.mounted || tab == null) return;
        if (model case final LiveWorkbenchModel live) {
          showTerminalAgent(
            context,
            live,
            model.session(tab) as LiveTerminalSession,
          );
        } else {
          notice(context, '模拟终端不会读取私钥或建立 Agent 授权');
        }
      } else if (value == 'forwardings') {
        final tab = model.tabById(group.selectedId);
        if (!context.mounted || tab == null) return;
        final session = model.session(tab);
        if (model.isMock) {
          notice(context, '模拟终端不建立真实端口转发');
        } else if (model case final LiveWorkbenchModel live) {
          showSavedForwardings(
            context,
            live,
            session.host.snapshot(),
            terminal: session as LiveTerminalSession,
          );
        }
      } else if (value == 'max') {
        model.maximize(group.id);
      } else if (value == 'merge') {
        model.focusGroup(group.id);
        model.mergeGroups();
      } else {
        model.moveTab(
          group.selectedId,
          group.id,
          placement: TabPlacement.values.byName(value),
        );
      }
    },
  );
}

class TerminalGroup extends StatefulWidget {
  const TerminalGroup({
    super.key,
    required this.model,
    required this.group,
    this.terminalBuilder,
  });
  final WorkbenchModel model;
  final TabGroup group;
  final TerminalSurfaceBuilder? terminalBuilder;
  @override
  State<TerminalGroup> createState() => _TerminalGroupState();
}

class _TerminalGroupState extends State<TerminalGroup> {
  TabPlacement? _drop;
  WorkbenchModel get model => widget.model;
  TabGroup get group => widget.group;
  TabPlacement placement(Offset global) {
    final box = context.findRenderObject()! as RenderBox;
    final p = box.globalToLocal(global), size = box.size;
    final x = math.min(72.0, size.width * .22),
        y = math.min(64.0, size.height * .22);
    if (p.dx < x) return TabPlacement.left;
    if (p.dx > size.width - x) return TabPlacement.right;
    if (p.dy < y) return TabPlacement.top;
    if (p.dy > size.height - y) return TabPlacement.bottom;
    return TabPlacement.center;
  }

  @override
  Widget build(BuildContext context) {
    final pane = model.session(group.selected),
        focused = model.focusedGroupId == group.id;
    final color = Theme.of(context).colorScheme.primary;
    return DragTarget<TerminalTabDrag>(
      onWillAcceptWithDetails: (d) => model.tabById(d.data.id) != null,
      onMove: (d) {
        final side = placement(d.offset);
        if (_drop != side) setState(() => _drop = side);
      },
      onLeave: (_) => setState(() => _drop = null),
      onAcceptWithDetails: (d) {
        final side = placement(d.offset);
        setState(() => _drop = null);
        model.moveTab(d.data.id, group.id, placement: side);
      },
      builder: (context, candidates, _) => Listener(
        onPointerDown: (_) {
          if (!focused) model.focusGroup(group.id);
        },
        child: Container(
          key: ValueKey('terminal-group-${group.id}'),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.light
                ? Colors.white
                : const Color(0xff10151c),
            border: Border.all(
              color: focused
                  ? color.withValues(alpha: .7)
                  : Theme.of(context).dividerColor,
            ),
            borderRadius: BorderRadius.circular(5),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Column(
                children: [
                  // In single-group mode the only tab strip lives in the integrated topbar.
                  if (model.tabGroups.length > 1)
                    Container(
                      height: 38,
                      color: focused
                          ? color.withValues(alpha: .07)
                          : Theme.of(context).colorScheme.surface,
                      child: Row(
                        children: [
                          Expanded(
                            child: TerminalTabStrip(model: model, group: group),
                          ),
                          Tool(
                            model.maximizedGroupId == group.id
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                            '临时最大化区域 / 恢复',
                            () => model.maximize(group.id),
                            key: ValueKey('maximize-${group.id}'),
                            size: 14,
                          ),
                          GroupActions(model: model, group: group),
                        ],
                      ),
                    ),
                  if (model.isMock && pane.disconnected)
                    Container(
                      key: ValueKey('disconnected-${pane.id}'),
                      height: 31,
                      color: Desk.warning.withValues(alpha: .1),
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.link_off,
                            size: 14,
                            color: Desk.warning,
                          ),
                          const SizedBox(width: 6),
                          const Expanded(
                            child: Text(
                              '模拟连接已断开 · 保留画面',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: Desk.warning,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () =>
                                model.setDisconnected(group.selectedId, false),
                            child: const Text(
                              '重新连接',
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child:
                        widget.terminalBuilder?.call(context, pane) ??
                        TerminalPreview(
                          key: ValueKey('preview-${pane.id}'),
                          pane: pane,
                        ),
                  ),
                ],
              ),
              if (_drop != null && candidates.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Align(
                      alignment: switch (_drop!) {
                        TabPlacement.left => Alignment.centerLeft,
                        TabPlacement.right => Alignment.centerRight,
                        TabPlacement.top => Alignment.topCenter,
                        TabPlacement.bottom => Alignment.bottomCenter,
                        TabPlacement.center => Alignment.center,
                      },
                      child: FractionallySizedBox(
                        widthFactor:
                            _drop == TabPlacement.left ||
                                _drop == TabPlacement.right
                            ? .5
                            : 1,
                        heightFactor:
                            _drop == TabPlacement.top ||
                                _drop == TabPlacement.bottom
                            ? .5
                            : 1,
                        child: Container(
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: .15),
                            border: Border.all(color: color, width: 2),
                          ),
                          child: Center(
                            child: Text(switch (_drop!) {
                              TabPlacement.center => '移入此标签组',
                              TabPlacement.left => '左侧分屏',
                              TabPlacement.right => '右侧分屏',
                              TabPlacement.top => '上方分屏',
                              TabPlacement.bottom => '下方分屏',
                            }, style: TextStyle(color: color, fontSize: 12)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
