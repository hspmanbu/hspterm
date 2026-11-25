import '../prototype/design.dart';

import 'package:flutter/material.dart';

import 'model.dart';
import 'remote_inspection.dart';

Future<void> showRemoteInspection(
  BuildContext context,
  LiveTerminalSession session,
) async {
  try {
    await session.inspection.ready();
  } catch (_) {
    /* The controller retains the authorization/persistence error for the panel. */
  }
  if (!context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (_) => RemoteInspectionPanel(
      controller: session.inspection,
      label: session.host.name,
    ),
  );
}

class RemoteInspectionPanel extends StatefulWidget {
  const RemoteInspectionPanel({
    super.key,
    required this.controller,
    required this.label,
  });
  final RemoteInspectionController controller;
  final String label;
  @override
  State<RemoteInspectionPanel> createState() => _RemoteInspectionPanelState();
}

class _RemoteInspectionPanelState extends State<RemoteInspectionPanel> {
  late bool _metrics = widget.controller.metrics,
      _processes = widget.controller.processesAllowed;
  String? _error;
  Future<void> _act(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '操作未获完整确认；请检查原终端状态和下方提示。');
    }
  }

  Future<void> _terminate(RemoteProcessList list, RemoteProcess process) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('向此远端进程发送 SIGTERM？'),
        content: Text(
          '主机：${widget.label}\n进程：${process.name}\nPID ${process.pid} · 创建计数 ${process.start}\n\n可能导致未保存数据丢失或 SSH 会话断开。只对原列表中的此进程发送一次 SIGTERM，不使用 sudo 或强制 SIGKILL。',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('remote-process-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认发送 SIGTERM'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await _act(() => widget.controller.terminate(list, process));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, list = c.processList;
      return AlertDialog(
        scrollable: true,
        title: Text('远端资源与进程 · ${widget.label}'),
        content: SizedBox(
          width: 760,
          height: 480,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '资源展示按主机在本机加密保存，重连自动恢复；进程授权仅本次连接有效。需要远端 Linux procfs 与 Python 3，通过独立 SSH exec 读取，不改变终端输入。未启用不探测；后台或非焦点终端不自动采样。数据仅在内存，不进日志、备份或云同步。',
                      style: TextStyle(fontSize: 12),
                    ),
                    CheckboxListTile(
                      key: const ValueKey('remote-metrics-consent'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启用资源采样 · 前台焦点每 5 秒'),
                      value: _metrics,
                      onChanged: c.busy
                          ? null
                          : (v) => setState(() => _metrics = v!),
                    ),
                    CheckboxListTile(
                      key: const ValueKey('remote-process-consent'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('允许按需读取进程列表 · 不读取命令参数或环境'),
                      value: _processes,
                      onChanged: c.busy
                          ? null
                          : (v) => setState(() => _processes = v!),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        FilledButton(
                          key: const ValueKey('remote-inspection-apply'),
                          onPressed: c.busy
                              ? null
                              : () => _act(
                                  () => c.configure(
                                    metrics: _metrics,
                                    processes: _processes,
                                  ),
                                ),
                          child: const Text('应用本次授权'),
                        ),
                        TextButton(
                          key: const ValueKey('remote-inspection-sample'),
                          onPressed: c.busy || !c.metrics
                              ? null
                              : () => _act(c.refreshMetrics),
                          child: const Text('采样一次'),
                        ),
                        TextButton(
                          key: const ValueKey('remote-process-refresh'),
                          onPressed: c.busy || !c.processesAllowed
                              ? null
                              : () => _act(c.refreshProcesses),
                          child: const Text('读取 / 刷新进程'),
                        ),
                        if (c.metrics || c.processesAllowed)
                          TextButton(
                            key: const ValueKey('remote-inspection-revoke'),
                            onPressed: () => _act(
                              () =>
                                  c.configure(metrics: false, processes: false),
                            ),
                            child: const Text('撤销并停止'),
                          ),
                      ],
                    ),
                    if (c.busy) const LinearProgressIndicator(),
                    if (c.summary != null) Text(c.summary!.label, maxLines: 2),
                    if (c.sampleDelayed) const Text('检查通道繁忙，显示上次样本。'),
                    if (c.summary?.availabilityDetails case final details?
                        when details.isNotEmpty)
                      Text(details),
                    if (c.summary != null)
                      const Text(
                        'CPU 和网络速率根据两次远端采样计算。内存按 MemAvailable 计算，根盘为 /，网速采自远端默认出口。',
                        style: TextStyle(fontSize: 11),
                      ),
                    if (_error ?? c.error case final String error)
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (c.result != null) Text(c.result!),
                    if (list != null) ...[
                      Text(
                        '${list.processes.length} 个进程${list.truncated ? ' · 达到扫描/显示上限，列表不完整' : ''} · ${list.skipped} 个不可读或已退出。列表 30 秒内有效。',
                      ),
                      if (!list.canSignal)
                        const Text('此服务器缺少 pidfd 安全信号能力；结束进程不可用。'),
                    ],
                    if (list == null)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('进程列表仅在明确读取后显示，不定时刷新。'),
                      ),
                  ],
                ),
              ),
              if (list != null)
                SliverList.builder(
                  itemCount: list.processes.length,
                  itemBuilder: (context, i) {
                    final row = list.processes[i];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${row.pid} · ${row.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'UID ${row.uid} · ${row.state} · RSS ${(row.rss / 1048576).toStringAsFixed(1)} MiB',
                      ),
                      trailing: TextButton(
                        onPressed:
                            !list.canSignal ||
                                c.busy ||
                                row.pid <= 1 ||
                                row.start == 0
                            ? null
                            : () => _terminate(list, row),
                        child: const Text('结束…'),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}
