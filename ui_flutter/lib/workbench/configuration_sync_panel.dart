import '../prototype/design.dart';

import 'package:flutter/material.dart';

import 'configuration_sync.dart';
import 'configuration_sync_references.dart';

Future<void> showConfigurationSyncReview(
  BuildContext context,
  ConfigurationSyncController controller,
) async {
  final original = controller.state;
  if (original?.review == null || !controller.available) return;
  if (original!.review!.references) {
    await showAppDialog<void>(
      context: context,
      builder: (_) => ConfigurationSyncReferencesDialog(
        controller: controller,
        original: original,
      ),
    );
    if (context.mounted &&
        controller.state?.phase == 'review' &&
        controller.state?.review?.references == false) {
      await showConfigurationSyncReview(context, controller);
    }
    return;
  }
  if (original.review!.needsDirection) {
    final direction = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AnimatedBuilder(
        animation: controller,
        builder: (_, _) {
          final current = controller.state;
          final valid =
              controller.available &&
              current?.operation == original.operation &&
              current?.review?.token == original.review!.token;
          return AlertDialog(
            scrollable: true,
            title: const Text('两端修改了相同配置单位'),
            content: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(original.review!.endpoint),
                    const SizedBox(height: 8),
                    Text(
                      '${original.review!.divergedUnits.length} 个配置单位在本地与云端都发生了修改，不能按修改时间自动取舍。',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '所属单位：${original.review!.divergedUnits.take(8).join('、')}${original.review!.divergedUnits.length > 8 ? ' 等共 ${original.review!.divergedUnits.length} 项' : ''}',
                    ),
                    const SizedBox(height: 12),
                    const Text('请选择整体方向：所选方向应用于以上全部单位；仅单端修改的其他单位仍自动合并。'),
                    if (!valid)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text('原候选已经改变或结束，请关闭后重新审阅。'),
                      ),
                  ],
                ),
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
                child: const Text('使用云端（覆盖本机）'),
              ),
              FilledButton(
                onPressed: !valid || controller.busy
                    ? null
                    : () => Navigator.pop(ctx, 'local'),
                child: const Text('使用本地（覆盖云端）'),
              ),
            ],
          );
        },
      ),
    );
    if (direction == null || direction == 'cancel') {
      if (controller.available &&
          controller.state?.operation == original.operation &&
          !controller.busy) {
        await controller.cancel();
      }
      return;
    }
    await controller.resolveDirection(original, direction);
    if (!context.mounted) return;
    if (controller.state?.phase == 'review' ||
        controller.state?.phase == 'references') {
      await showConfigurationSyncReview(context, controller);
    }
    return;
  }
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => AnimatedBuilder(
      animation: controller,
      builder: (_, _) {
        final review = original.review!;
        final current = controller.state;
        final valid =
            controller.available &&
            current?.operation == original.operation &&
            current?.review?.token == review.token;
        return AlertDialog(
          scrollable: true,
          title: const Text('审阅配置同步'),
          content: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(review.endpoint),
                  const SizedBox(height: 12),
                  Text(
                    '云端更新 ${review.counts['incoming_winners']} 项，其中两端同改需选方向 ${review.counts['conflicts']} 项。',
                  ),
                  Text(
                    '将删除本机配置 ${review.counts['incoming_deletions']} 项；涉及主机及关联认证配置 ${review.counts['credential_changes']} 项。',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '仅单端修改的单位按基线自动合并；两端同改的单位必须先选择整体方向。主机凭据及合格单行历史始终端到端加密；不会同步终端画面、滚动历史或未完成任务。',
                  ),
                  if (!valid)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('原候选已经改变或结束，请关闭后重新审阅。'),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: controller.busy
                  ? null
                  : () async {
                      if (valid) await controller.cancel();
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: !valid || controller.busy
                  ? null
                  : () async {
                      await controller.confirm(original);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
              child: Text(controller.busy ? '正在同步…' : '确认同步'),
            ),
          ],
        );
      },
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
        'reserved' || 'reading' => '正在读取并合并云端配置…',
        'review' => '需要审阅同步变化',
        'references' => '需要解决分组或跳板引用冲突',
        'publishing' => '正在进行条件写入…',
        'applying' => '正在原子应用本机配置…',
        'committed' => '同步已完成',
        'cancelled' => syncFailureLabel(state),
        'failed' => syncFailureLabel(state),
        _ => state?.eligible == true ? '等待配置变更、定时检查或手动同步' : '请先保存并启用一个同步目标',
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
                child: const Text('同步已保存目标'),
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
                child: Text(
                  controller.error ??
                      (state?.review != null
                          ? '配置同步需要审阅冲突或认证变化'
                          : syncFailureLabel(state)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
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
                  child: const Text('手动重试'),
                ),
            ],
          ),
        ),
      );
    },
  );
}
