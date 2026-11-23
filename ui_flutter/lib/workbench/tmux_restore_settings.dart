import '../app_notice.dart';
import '../prototype/design.dart';

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import 'model.dart';

Future<void> showTmuxRestoreSettings(
  BuildContext context,
  LiveWorkbenchModel model,
  LiveTerminalSession source,
) async {
  final id = source.controller.id, generation = source.controller.generation;
  bool current() =>
      !model.isClosing &&
      model.sessions.contains(source) &&
      identical(model.focus, source) &&
      source.controller.id == id &&
      source.controller.generation == generation;
  if (id == null || !current()) return;
  try {
    final enabled = await model.runLocalSettings(
      () => rust.terminalTmuxRestoreEnabled(id: id, generation: generation),
    );
    if (!context.mounted || !current()) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text('当前终端的重连恢复'),
        content: Text(
          enabled
              ? '此终端已记忆经过身份验证的普通Shell或tmux选择。关闭恢复仅影响下次重连，不断开当前SSH或退出tmux。'
              : '此终端没有启用重连恢复。可在下次连接选择中勾选；新终端和一次性覆盖连接不继承其他终端的记忆。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('返回'),
          ),
          if (enabled)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('关闭重连恢复'),
            ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted || !current()) return;
    await model.runLocalSettings(
      () => rust.forgetTerminalTmuxRestore(id: id, generation: generation),
    );
    if (context.mounted && current()) {
      showAppNotice(
        context,
        '已关闭此终端的重连恢复；当前会话保持。',
        level: AppNoticeLevel.success,
      );
    }
  } catch (_) {
    if (context.mounted && current()) {
      model.reportOperation('无法确认当前恢复设置，请重新读取；没有新建或断开连接。');
    }
  }
}
