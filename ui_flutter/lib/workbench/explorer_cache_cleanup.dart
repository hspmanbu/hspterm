import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../prototype/design.dart';
import '../src/rust/api.dart' as rust;
import 'model.dart';

Future<void> showExplorerCacheCleanup(
  BuildContext context,
  LiveWorkbenchModel model,
) async {
  final review = await model.runTransferSubmission(() async {
    final base = await getApplicationSupportDirectory();
    return rust.prepareExplorerCacheCleanup(cacheDirectory: base.path);
  });
  try {
    if (!context.mounted || model.isClosing) return;
    if (review.names.isEmpty) {
      notice(context, '本批没有可清理的孤立导出副本；活动、可恢复及旧版无归属缓存均保留');
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => ExplorerCacheCleanupConfirmation(names: review.names),
    );
    if (accepted != true || !context.mounted || model.isClosing) return;
    final result = await model.runTransferSubmission(
      () => rust.applyExplorerCacheCleanup(ticket: review.ticket),
    );
    if (context.mounted) {
      notice(
        context,
        '本机副本：已清理 ${result.removed} · 保留 ${result.retained} · 失败 ${result.failed}。失败项可重新检查；未删除远端或Explorer目标文件。',
      );
    }
  } finally {
    // Consumed tickets are also safe to release. No disk cleanup is performed
    // here; closing the dialog never implies permission to delete a payload.
    await rust.releaseExplorerCacheCleanup(ticket: review.ticket);
  }
}

class ExplorerCacheCleanupConfirmation extends StatelessWidget {
  const ExplorerCacheCleanupConfirmation({super.key, required this.names});
  final List<String> names;
  @override
  Widget build(BuildContext context) => AlertDialog(
    constraints: const BoxConstraints(maxWidth: 560),
    scrollable: true,
    title: Text('清理 ${names.length} 个孤立导出副本？'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '永久删除下列本机缓存正文。本批最多128项；确认时重新检查任务引用和读取锁。活动任务、可恢复任务、其他配置库及旧版无归属副本不会清理。',
          ),
          const SizedBox(height: 12),
          const Text('不会删除远端来源或Explorer目标文件，也不会中断连接。'),
          const SizedBox(height: 12),
          for (final name in names)
            Text(name, style: const TextStyle(fontSize: 11)),
        ],
      ),
    ),
    actions: [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
        onPressed: () => Navigator.pop(context, true),
        child: const Text('清理本机副本'),
      ),
    ],
  );
}
