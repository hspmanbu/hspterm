import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design.dart';
import 'model.dart';

class TransferQueue extends StatefulWidget {
  const TransferQueue({super.key, required this.model});
  final WorkbenchModel model;
  @override
  State<TransferQueue> createState() => _TransferQueueState();
}

class _TransferQueueState extends State<TransferQueue> {
  final selected = <String>{};
  String? expanded, hovered, anchor;
  bool completedOpen = false;
  WorkbenchModel get m => widget.model;
  Color color(DemoTransfer t) => switch (t.state) {
    TransferState.failed || TransferState.partial => Desk.danger,
    TransferState.paused => Desk.warning,
    TransferState.complete => Desk.accent,
    _ => Theme.of(context).colorScheme.primary,
  };
  Future<void> cancel(Iterable<String> ids) async {
    final values = ids.toList();
    if (await confirm(
          context,
          '取消 ${values.length} 个模拟任务？',
          '只停止剩余工作；正式操作也保留已成功传输和已写入的数据。\n本次不会操作真实文件。',
          accept: '取消任务',
        ) &&
        mounted) {
      m.setTransfer(values, TransferState.cancelled);
    }
  }

  void select(DemoTransfer t) {
    final all = m.visibleTransfers;
    if (HardwareKeyboard.instance.isShiftPressed &&
        all.any((t) => t.id == anchor)) {
      final a = all.indexWhere((t) => t.id == anchor), b = all.indexOf(t);
      selected.addAll(
        all.sublist(a < b ? a : b, (a > b ? a : b) + 1).map((t) => t.id),
      );
    } else if (HardwareKeyboard.instance.isControlPressed) {
      if (!selected.add(t.id)) selected.remove(t.id);
      anchor = t.id;
    } else {
      selected
        ..clear()
        ..add(t.id);
      anchor = t.id;
    }
    setState(() {});
  }

  Future<void> menu(Offset position, DemoTransfer t) async {
    if (!selected.contains(t.id)) select(t);
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: const [
        DeskMenuItem(value: 'pause', child: Text('暂停选中任务')),
        DeskMenuItem(value: 'resume', child: Text('继续 / 重试选中任务')),
        DeskMenuItem(value: 'cancel', child: Text('取消选中任务')),
        DeskMenuDivider(),
        DeskMenuItem(value: 'complete', child: Text('演示：切换为已完成')),
        DeskMenuItem(value: 'failed', child: Text('演示：切换为失败')),
        DeskMenuItem(value: 'partial', child: Text('演示：切换为部分完成')),
      ],
    );
    if (!mounted || value == null) return;
    switch (value) {
      case 'pause':
        m.setTransfer(selected, TransferState.paused);
      case 'resume':
        m.setTransfer(selected, TransferState.active);
      case 'cancel':
        await cancel(selected);
      case 'complete':
        m.setTransfer(selected, TransferState.complete);
      case 'failed':
        m.setTransfer(selected, TransferState.failed);
      case 'partial':
        m.setTransfer(selected, TransferState.partial);
    }
  }

  Widget item(DemoTransfer t) {
    final active = selected.contains(t.id),
        showActions = active || hovered == t.id;
    return Column(
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => hovered = t.id),
          onExit: (_) => setState(() => hovered = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => select(t),
            onSecondaryTapDown: (d) => menu(d.globalPosition, t),
            child: Container(
              key: ValueKey('transfer-${t.name}'),
              height: 50,
              padding: const EdgeInsets.fromLTRB(7, 2, 6, 3),
              color: active
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: .09)
                  : null,
              child: Column(
                children: [
                  Row(
                    children: [
                      Tool(
                        expanded == t.id
                            ? Icons.expand_less
                            : Icons.expand_more,
                        '展开任务详情',
                        () => setState(
                          () => expanded = expanded == t.id ? null : t.id,
                        ),
                        key: ValueKey('expand-${t.id}'),
                        size: 14,
                      ),
                      Icon(
                        t.upload ? Icons.north_east : Icons.south_west,
                        size: 13,
                        color: color(t),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          t.name,
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (showActions) ...[
                        Tool(
                          t.state == TransferState.active
                              ? Icons.pause
                              : Icons.play_arrow,
                          t.state == TransferState.active ? '暂停任务' : '继续任务',
                          () => m.setTransfer(
                            [t.id],
                            t.state == TransferState.active
                                ? TransferState.paused
                                : TransferState.active,
                          ),
                          key: ValueKey('pause-${t.id}'),
                          size: 14,
                        ),
                        Tool(
                          Icons.close,
                          '取消任务',
                          () => cancel([t.id]),
                          size: 13,
                        ),
                      ] else
                        Text(
                          t.label,
                          style: TextStyle(color: color(t), fontSize: 9),
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 34),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Text(
                              t.state == TransferState.waiting
                                  ? '等待扫描 · —'
                                  : '${(t.progress * 100).round()}% · ${(t.progress * 48).toStringAsFixed(1)} / 48 MB',
                              style: TextStyle(
                                fontSize: 9,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              t.state == TransferState.active
                                  ? '12.4 MB/s · 约 23 秒'
                                  : '—',
                              style: TextStyle(
                                fontSize: 9,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        LinearProgressIndicator(
                          value: t.state == TransferState.waiting
                              ? 0
                              : t.progress,
                          minHeight: 2,
                          color: color(t),
                          backgroundColor: Theme.of(context).dividerColor,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded == t.id)
          Container(
            key: ValueKey('details-${t.id}'),
            margin: const EdgeInsets.fromLTRB(37, 0, 10, 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.folder
                      ? '文件 128 · 目录 12 · 成功 119 · 失败 2'
                      : '单文件任务 · 偏移续传（原型）',
                  style: const TextStyle(fontSize: 10),
                ),
                const SizedBox(height: 4),
                Text(
                  '${t.upload ? '上传到' : '下载自'} /home/ubuntu/project',
                  style: TextStyle(
                    fontSize: 9,
                    color: Theme.of(context).hintColor,
                  ),
                ),
                if (t.folder) ...[
                  const SizedBox(height: 6),
                  const Text(
                    '当前传输  static/app.js  ·  74%',
                    style: TextStyle(fontSize: 10),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    '失败  config/private.json · 权限不足',
                    style: TextStyle(fontSize: 10, color: Desk.danger),
                  ),
                  const Text(
                    '失败  assets/banner.png · 通道中断',
                    style: TextStyle(fontSize: 10, color: Desk.danger),
                  ),
                  TextButton(
                    onPressed: () =>
                        m.setTransfer([t.id], TransferState.active),
                    child: const Text(
                      '重试失败项 · 模拟',
                      style: TextStyle(fontSize: 10),
                    ),
                  ),
                ],
                Text(
                  '仅为模拟数据；无真实字节传输',
                  style: TextStyle(
                    fontSize: 9,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Newest task first: demo transfers are appended oldest→newest, so the
    // queue renders the reversed list; a transfer added later shows on top.
    final tasks = m.visibleTransfers.reversed.toList();
    selected.removeWhere((id) => !tasks.any((t) => t.id == id));
    final activity = tasks
        .where(
          (t) => [
            TransferState.active,
            TransferState.waiting,
            TransferState.paused,
          ].contains(t.state),
        )
        .toList();
    final errors = tasks
        .where(
          (t) =>
              [TransferState.failed, TransferState.partial].contains(t.state),
        )
        .toList();
    final done = tasks
        .where(
          (t) => [
            TransferState.complete,
            TransferState.cancelled,
          ].contains(t.state),
        )
        .toList();
    return Column(
      children: [
        SizedBox(
          height: 30,
          child: Row(
            children: [
              const SizedBox(width: 10),
              const Icon(Icons.swap_vert, size: 16),
              const SizedBox(width: 6),
              const Text(
                '传输队列',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 6),
              DeskBadge(
                '${activity.length} 活动 · ${errors.length} 异常',
                color: errors.isEmpty ? null : Desk.warning,
              ),
              const Spacer(),
              Tool(
                m.queueMaximized ? Icons.fullscreen_exit : Icons.fullscreen,
                '队列在侧栏内最大化',
                m.queueToggle,
                key: const ValueKey('maximize-queue'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 26,
          child: Row(
            children: [
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  m.allTasks = !m.allTasks;
                  m.changed();
                },
                child: Text(
                  m.allTasks ? '全部会话 ▾' : '当前会话 ▾',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
              const Spacer(),
              if (selected.isNotEmpty) ...[
                Text(
                  '已选 ${selected.length}',
                  style: const TextStyle(fontSize: 9),
                ),
                Tool(
                  Icons.pause,
                  '批量暂停',
                  () => m.setTransfer(selected, TransferState.paused),
                  key: const ValueKey('batch-pause'),
                  size: 14,
                ),
                Tool(
                  Icons.play_arrow,
                  '批量继续',
                  () => m.setTransfer(selected, TransferState.active),
                  size: 14,
                ),
                Tool(Icons.close, '批量取消', () => cancel(selected), size: 14),
              ] else
                Tool(
                  Icons.play_arrow_outlined,
                  '继续所有暂停任务',
                  () => m.setTransfer(
                    tasks
                        .where((t) => t.state == TransferState.paused)
                        .map((t) => t.id),
                    TransferState.active,
                  ),
                  size: 14,
                ),
            ],
          ),
        ),
        Expanded(
          child: tasks.isEmpty
              ? Center(
                  child: Text(
                    m.isMock ? '暂无模拟传输任务' : '暂无传输任务 · 任务系统接入中',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                )
              : ListView(
                  children: [
                    if (activity.isNotEmpty) ...[
                      SectionHeading('活动与等待 · ${activity.length}'),
                      ...activity.map(item),
                    ],
                    if (errors.isNotEmpty) ...[
                      SectionHeading('需要处理 · ${errors.length}'),
                      ...errors.map(item),
                    ],
                    if (done.isNotEmpty) ...[
                      InkWell(
                        key: const ValueKey('completed-group'),
                        onTap: () =>
                            setState(() => completedOpen = !completedOpen),
                        child: SectionHeading(
                          '${completedOpen ? '▾' : '▸'} 已结束 · ${done.length}',
                          trailing: Tool(Icons.playlist_remove, '清理已结束任务', () {
                            m.transfers.removeWhere((t) => done.contains(t));
                            m.changed();
                          }, size: 14),
                        ),
                      ),
                      if (completedOpen) ...done.map(item),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}
