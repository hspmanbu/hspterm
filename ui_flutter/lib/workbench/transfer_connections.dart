import 'package:flutter/material.dart';

import '../src/rust/transfers.dart' as jobs;
import 'model.dart';

typedef TransferConnections = ({
  TransferConnectionRef? source,
  TransferConnectionRef target,
});

/// Selection is local metadata only: no handshake, SFTP probe or task mutation.
/// The original immutable runtime refs are rechecked by Model and Native before
/// recovery; choosing a same-profile tab never bypasses endpoint verification.
Future<TransferConnections?> showTransferConnections(
  BuildContext context,
  LiveWorkbenchModel model,
  jobs.TransferTaskView task,
) async {
  final sessions = model.sessions.cast<LiveTerminalSession>().toList();
  List<TransferConnectionRef> options(String? host) => [
    for (final session in sessions)
      if (host != null &&
          session.host.id == host &&
          session.controller.connected &&
          session.controller.id != null)
        TransferConnectionRef(session),
  ];
  final sources = task.sourceRemote == null
      ? <TransferConnectionRef>[]
      : options(task.sourceHostId);
  final targets = options(task.hostId);
  TransferConnectionRef? initial(
    List<TransferConnectionRef> list,
    int? native,
    int? generation,
  ) => list
      .where((ref) => ref.nativeId == native && ref.generation == generation)
      .firstOrNull;
  var source = initial(
    sources,
    task.sourceTerminalId,
    task.sourceTerminalGeneration,
  );
  var target = initial(targets, task.terminalId, task.terminalGeneration);
  // A changed generation requires an explicit choice; do not silently adopt the
  // old tab's new SSH connection or guess a source/target pair from one focus.
  return showDialog<TransferConnections>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (context, setLocal) => AnimatedBuilder(
        animation: Listenable.merge([
          model,
          ...sessions.map((s) => s.controller),
        ]),
        builder: (context, _) {
          bool valid(TransferConnectionRef? ref, String? host) =>
              ref != null &&
              ref.valid(model.sessions.cast<LiveTerminalSession>(), host);
          final currentTask = model.transferTasks
              .where((item) => item.id == task.id)
              .firstOrNull;
          final resumable =
              currentTask != null &&
              !currentTask.busy &&
              !{
                'Complete',
                'CompleteWithSkips',
                'Cancelled',
                'ExportReady',
              }.contains(currentTask.state) &&
              currentTask.remoteMovePhase != 'Intent' &&
              currentTask.remoteOperation == task.remoteOperation;
          final ready =
              !model.isClosing &&
              resumable &&
              valid(target, task.hostId) &&
              (task.sourceRemote == null || valid(source, task.sourceHostId));
          Widget selector(
            String label,
            String key,
            List<TransferConnectionRef> choices,
            TransferConnectionRef? selected,
            String? host,
            ValueChanged<TransferConnectionRef?> choose,
          ) => Padding(
            padding: const EdgeInsets.only(top: 12),
            child: DropdownButtonFormField<TransferConnectionRef>(
              key: ValueKey(key),
              initialValue: selected,
              isExpanded: true,
              decoration: InputDecoration(labelText: label),
              hint: const Text('选择已连接的终端标签'),
              items: [
                for (final ref in choices)
                  DropdownMenuItem(
                    value: ref,
                    enabled: valid(ref, host),
                    child: Text(
                      '${model.tabs.where((tab) => tab.sessionId == ref.session.id).firstOrNull?.name ?? ref.session.host.name} · ${ref.session.host.user}@${ref.session.host.address}:${ref.session.host.port}${valid(ref, host) ? '' : ' · 连接已改变'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: model.isClosing ? null : choose,
            ),
          );
          return AlertDialog(
            constraints: const BoxConstraints(maxWidth: 580),
            scrollable: true,
            title: const Text('选择连接继续此任务'),
            content: SizedBox(
              width: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(task.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (!resumable) const Text('任务状态已改变；请取消后重新检查队列。'),
                  const SizedBox(height: 8),
                  const Text(
                    '只使用现有连接，不会自动建立 SSH。原任务的实际服务器、用户和主机指纹必须全部一致；连接改变时请取消后重新选择。此操作不修改主机配置。',
                  ),
                  if (task.sourceRemote != null)
                    selector(
                      '源 SSH 标签',
                      'transfer-source-connection',
                      sources,
                      source,
                      task.sourceHostId,
                      (value) => setLocal(() => source = value),
                    ),
                  selector(
                    task.sourceRemote == null ? 'SSH 标签' : '目标 SSH 标签',
                    'transfer-target-connection',
                    targets,
                    target,
                    task.hostId,
                    (value) => setLocal(() => target = value),
                  ),
                  if (targets.isEmpty ||
                      (task.sourceRemote != null && sources.isEmpty))
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('缺少已连接的原主机标签；请取消后先手动连接。'),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(dialog),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const ValueKey('transfer-confirm-connections'),
                onPressed: ready
                    ? () => Navigator.pop(dialog, (
                        source: source,
                        target: target!,
                      ))
                    : null,
                child: const Text('继续此任务'),
              ),
            ],
          );
        },
      ),
    ),
  );
}
