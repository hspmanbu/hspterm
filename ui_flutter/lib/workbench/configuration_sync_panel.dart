import '../prototype/design.dart';

import 'package:flutter/material.dart';

import 'configuration_sync.dart';

Future<void> showConfigurationSyncReview(
  BuildContext context,
  ConfigurationSyncController controller,
) async {
  final original = controller.state;
  if (original?.review == null ||
      !controller.available ||
      !original!.review!.needsConsent) {
    return;
  }
  final direction = await showAppDialog<String>(
    context: context,
    builder: (ctx) => AnimatedBuilder(
      animation: controller,
      builder: (_, _) {
        final valid =
            controller.available &&
            controller.state?.operation == original.operation &&
            controller.state?.review?.token == original.review!.token;
        return AlertDialog(
          scrollable: true,
          title: const Text('选择配置同步方向'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  original.review!.references
                      ? '两端的分组或跳板配置无法自动合并。'
                      : '两端修改了相同配置，无法自动确定保留哪一端。',
                ),
                const SizedBox(height: 10),
                const Text(
                  '请选择本次同步以哪一端的完整配置为准。被覆盖的云端版本会保留在最近 3 个历史快照中。命令历史保留跨设备清除记录。',
                ),
                if (!valid)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text('配置已变化，请关闭后重新同步。'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: controller.busy
                  ? null
                  : () => Navigator.pop(ctx, 'cancel'),
              child: const Text('取消同步'),
            ),
            OutlinedButton(
              onPressed: !valid || controller.busy
                  ? null
                  : () => Navigator.pop(ctx, 'remote'),
              child: const Text('云端覆盖本地'),
            ),
            FilledButton(
              onPressed: !valid || controller.busy
                  ? null
                  : () => Navigator.pop(ctx, 'local'),
              child: const Text('本地覆盖云端'),
            ),
          ],
        );
      },
    ),
  );
  if (controller.state?.operation != original.operation ||
      controller.state?.review?.token != original.review!.token) {
    return;
  }
  if (direction == null || direction == 'cancel') {
    await controller.cancel();
    return;
  }
  await controller.resolveDirection(original, direction);
}

Future<void> showCloudConfigurationHistory(
  BuildContext context,
  ConfigurationSyncController controller,
) async {
  final snapshots =
      controller.state?.snapshots ?? const <CloudConfigurationSnapshot>[];
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: const Text('云端历史快照'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '最近一次成功读取的历史，最多 3 份，全部端到端加密。恢复会覆盖当前配置并同步到云端，当前云端版本会先加入历史。',
            ),
            const SizedBox(height: 12),
            if (snapshots.isEmpty) const Text('暂无历史。请先完成一次同步；首次创建的配置没有旧快照。'),
            for (final snapshot in snapshots)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  snapshot.time.toLocal().toString().split('.').first,
                ),
                subtitle: Text(
                  '${snapshot.hosts} 个主机 · ${snapshot.bookmarks} 个书签',
                ),
                trailing: OutlinedButton(
                  onPressed: controller.busy
                      ? null
                      : () async {
                          final confirmed = await showAppDialog<bool>(
                            context: ctx,
                            builder: (c) => AlertDialog(
                              title: const Text('恢复此快照？'),
                              content: const Text(
                                '将以该历史版本覆盖本机和云端配置。当前云端配置会保留为新的历史快照；正在运行的终端不会自动重新连接。',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(c, false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(c, true),
                                  child: const Text('恢复并同步'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed != true || !ctx.mounted) return;
                          Navigator.pop(ctx);
                          await controller.restoreSnapshot(snapshot);
                        },
                  child: const Text('恢复'),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class ConfigurationSyncRuntimePanel extends StatelessWidget {
  const ConfigurationSyncRuntimePanel({super.key, required this.controller});
  final ConfigurationSyncController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final state = controller.state;
      final label = switch (state?.phase) {
        'reserved' || 'reading' => '正在读取云端配置…',
        'review' => '需要审阅同步变化',
        'references' => '需要解决分组或跳板引用冲突',
        'publishing' => '正在进行条件写入…',
        'applying' => '正在原子应用本机配置…',
        'committed' => controller.pendingEdits ? '有本地修改，等待同步' : '同步已完成',
        'cancelled' =>
          controller.historyRead ? '云端历史已更新（未同步配置）' : syncFailureLabel(state),
        'failed' => syncFailureLabel(state),
        _ =>
          state?.eligible == true
              ? (controller.pendingEdits
                    ? '有未同步的本地修改，等待下一次检查或手动同步'
                    : '等待配置变更、定时检查或手动同步')
              : '请先保存并启用一个同步目标',
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('配置同步状态', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(label),
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!controller.available)
                TextButton(
                  onPressed: controller.canRetryStart
                      ? controller.retryStart
                      : null,
                  child: const Text('重试读取同步状态'),
                ),
              FilledButton(
                key: const ValueKey('configuration-sync-now'),
                onPressed:
                    !controller.available ||
                        controller.busy ||
                        state?.eligible != true
                    ? null
                    : controller.synchronize,
                child: Text(controller.retrying ? '正在处理…' : '立即同步'),
              ),
              OutlinedButton(
                onPressed:
                    !controller.available ||
                        controller.busy ||
                        state?.active == true ||
                        state?.eligible != true
                    ? null
                    : () async {
                        final loaded = await controller.refreshHistory();
                        if (loaded && context.mounted) {
                          await showCloudConfigurationHistory(
                            context,
                            controller,
                          );
                        }
                      },
                child: const Text('云端历史快照'),
              ),
              if (state?.review != null)
                OutlinedButton(
                  onPressed: controller.busy
                      ? null
                      : () => showConfigurationSyncReview(context, controller),
                  child: const Text('审阅变化'),
                ),
              if (state?.active == true || controller.busy)
                TextButton(
                  onPressed: controller.cancel,
                  child: const Text('取消本次同步'),
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      );
    },
  );
}

class ConfigurationSyncBanner extends StatelessWidget {
  const ConfigurationSyncBanner({super.key, required this.controller});
  final ConfigurationSyncController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final state = controller.state;
      // A disabled target must not keep the failure banner up: the residual
      // failed phase and stale controller notices (including the greyed
      // manual retry) vanish the moment eligibility drops and only return
      // after the target is enabled again.
      if (state?.eligible == false ||
          controller.retrying ||
          controller.noticeDismissed ||
          state?.review != null) {
        return const SizedBox.shrink();
      }
      if (controller.error == null &&
          state?.review == null &&
          state?.phase != 'failed' &&
          state?.writeUnknown != true) {
        return const SizedBox.shrink();
      }
      return Material(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // A failed phase wins: the typed syncFailureLabel text is
                      // the actionable cause; a controller notice only adds
                      // request-level context in the smaller line below.
                      state?.phase == 'failed' && state?.review == null
                          ? syncFailureLabel(state)
                          : controller.error ??
                                (state?.review != null
                                    ? '配置同步需要审阅冲突或认证变化'
                                    : syncFailureLabel(state)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                    if (state?.phase == 'failed' &&
                        state?.review == null &&
                        controller.error != null)
                      Text(
                        controller.error!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '关闭提示',
                onPressed: controller.dismissNotice,
                icon: const Icon(Icons.close, size: 16),
              ),
              if (state?.review != null)
                TextButton(
                  onPressed: controller.busy
                      ? null
                      : () => showConfigurationSyncReview(context, controller),
                  child: const Text('审阅'),
                ),
              if (state?.review == null)
                TextButton(
                  onPressed:
                      !controller.available ||
                          controller.busy ||
                          state?.eligible != true
                      ? null
                      : controller.synchronize,
                  child: const Text('立即同步'),
                ),
            ],
          ),
        ),
      );
    },
  );
}
