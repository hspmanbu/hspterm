import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/rust/api.dart' as rust;
import 'model.dart';
import '../run_log.dart';

typedef TerminalPathRequest = Future<String> Function(
  int,
  int,
  List<String>,
  bool,
);
String quoteRemotePath(String path) => "'${path.replaceAll("'", "'\\''")}'";

/// One original SFTP context. No file IO or transfer is started by this action.
/// Copy fallback is allowed only before a controlled operation was sent.
Future<void> sendSessionPaths(
  BuildContext context,
  LiveWorkbenchModel model,
  LiveTerminalSession source,
  List<String> paths, {
  bool enterDirectory = false,
  int? expectedGeneration,
  TerminalPathRequest? request,
}) async {
  if (paths.isEmpty ||
      paths.any((path) => !path.startsWith('/') || path.contains('\u0000')) ||
      (enterDirectory && paths.length != 1)) {
    throw StateError('远端路径无效');
  }
  final frozen = List<String>.unmodifiable(paths);
  final generation = expectedGeneration ?? source.controller.generation;
  String result = 'Unavailable';
  String? reason;
  if (!model.isClosing &&
      model.sessions.contains(source) &&
      source.controller.connected &&
      source.controller.generation == generation) {
    result = await source.controller.controlledInput((id, current) async {
      if (current != generation ||
          model.isClosing ||
          !model.sessions.contains(source)) {
        return Future.value('Unavailable');
      }
      final outcome =
          await (request ??
              ((id, current, paths, cd) => rust.insertTerminalPaths(
                id: id,
                generation: current,
                paths: paths,
                enterDirectory: cd,
              )))(id, current, frozen, enterDirectory);
      if (outcome == 'Unavailable' && request == null) {
        try {
          reason = await rust.terminalIntegrationStatus(
            id: id,
            generation: current,
          );
        } catch (error, stack) {
          // The original request is proved unsent. A concurrently closed
          // terminal must not make an optional explanation block copy fallback.
          AppRunLog.instance.event(
            AppLogEvent.operationFailed,
            error: error,
            stack: stack,
          );
        }
      }
      return outcome;
    });
  }
  AppRunLog.instance.event(
    switch (result) {
      'Applied' => AppLogEvent.pathApplied,
      'Unavailable' => AppLogEvent.pathUnavailable,
      _ => AppLogEvent.pathUnconfirmed,
    },
    generation: generation,
    count: frozen.length,
  );
  if (result == 'Unavailable') {
    final literal = frozen.map(quoteRemotePath).join(' ');
    await Clipboard.setData(
      ClipboardData(text: enterDirectory ? 'cd $literal' : literal),
    );
  }
  if (!context.mounted) return;
  final message = switch (result) {
    'Applied' => enterDirectory ? '已向原关联终端提交进入目录操作。' : '已填入原关联终端；未发送回车，未上传或下载。',
    'Unavailable' =>
      enterDirectory
          ? '无法确认空白的普通Shell输入，已复制安全cd命令；未执行。'
          : source.host.shellIntegration
          ? '当前Shell输入状态不可确认，已复制安全路径。'
          : '已复制安全路径；直接填入需先启用此主机的Shell集成。',
    _ => '路径操作结果未确认，请检查原关联终端；未自动重试或改为粘贴。',
  };
  final detail = switch (reason) {
    'ShellUnavailable' => '远端未建立兼容的 Bash 5.1+ 集成。',
    'WaitingForHelper' => '正在等待 Shell 提示符就绪。',
    'TerminalMode' => '当前为远端程序输入模式。',
    'InputStateUnknown' => 'Shell 输入状态尚未确认，请返回普通提示符。',
    'ConnectionNotOptedIn' => '此连接尚未启用集成，保存设置后请手动重连。',
    'TemporaryConnection' => '临时连接未启用集成。',
    _ => '',
  };
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(detail.isEmpty ? message : '$detail $message'),
      action: result == 'Unavailable'
          ? SnackBarAction(
              label: '发送说明',
              onPressed: () {
                if (!context.mounted) return;
                showDialog<void>(
                  context: context,
                  builder: (dialog) => AlertDialog(
                    title: const Text('将路径填入关联终端'),
                    content: const Text(
                      '在“主机管理 → 终端”启用“可选 Bash Shell 集成”，保存后手动重新连接此标签。\n\n集成支持 Bash 5.1+，用于确认输入位置。Vim、Codex、密码提示、tmux 内层或集成未就绪时只复制路径，避免误输入。仅填入路径不会执行命令。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialog),
                        child: const Text('关闭'),
                      ),
                      if (model.hosts.any((host) => host.id == source.host.id))
                        FilledButton(
                          onPressed: () {
                            Navigator.pop(dialog);
                            model.editHostSettings(
                              source.host.id,
                              category: '终端',
                            );
                          },
                          child: const Text('配置此主机'),
                        ),
                    ],
                  ),
                );
              },
            )
          : null,
    ),
  );
}
