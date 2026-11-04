import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../src/rust/api.dart' as rust;
import '../terminal/links.dart';
import 'model.dart';

/// One explicit action captured from its original terminal; focus changes never
/// redirect it. Hover/recognition does not enter this function.
Future<void> openTerminalLink(
  BuildContext context,
  LiveWorkbenchModel model,
  LiveTerminalSession source,
  TerminalLink link, {
  Future<bool> Function(Uri)? launcher,
}) async {
  final controller = source.controller, id = source.controller.id;
  final generation = controller.generation;
  final forward = link.canForward;
  final remoteFile = link.remoteFileUri;
  final remotePath = link.remotePath;
  bool current() =>
      (!(forward || remoteFile != null || remotePath != null) ||
          controller.connected) &&
      controller.id == id &&
      controller.generation == generation &&
      model.tabs.any((t) => t.sessionId == source.id);
  if (id == null || !current()) throw StateError('原SSH会话已断开；未打开链接');
  if (remoteFile != null) {
    // Never pass file:// to url_launcher, including localhost and Windows
    // drive-shaped paths. This is an explicit original-session SFTP operation.
    await model.locateTerminalPath(source, remoteFile);
    return;
  }
  if (remotePath != null) {
    String? target = remotePath.path;
    if (remotePath.requiresChoice) {
      target = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
          scrollable: true,
          title: const Text('在关联 SFTP 中定位路径？'),
          content: SelectableText(
            '关联终端：${source.host.name}\n原文：${remotePath.text}\n文件：${remotePath.path}'
            '${remotePath.line == null ? '' : '\n位置提示：第 ${remotePath.line} 行${remotePath.column == null ? '' : '，第 ${remotePath.column} 列'}'}'
            '\n\n行列后缀也可能属于真实文件名，请明确选择。相对路径仅在原SSH有匹配的OSC7工作目录时解析；不展开变量，不打开本机文件或执行命令。',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            if (remotePath.hasLocation)
              TextButton(
                onPressed: () => Navigator.pop(dialog, remotePath.text),
                child: const Text('按原文路径定位'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, remotePath.path),
              child: const Text('定位文件'),
            ),
          ],
        ),
      );
    }
    if (target != null && current()) {
      await model.locateTerminalPath(source, target);
    }
    return;
  }
  if (!forward && (link.uri == null || link.loopback)) return;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(forward ? '通过原 SSH 临时转发？' : '在浏览器中打开链接？'),
      content: SelectableText(
        '关联终端：${source.host.name}\n${link.text}\n\n${forward ? '只在本机 127.0.0.1 随机端口监听，经此 SSH 访问远端回环目标。关闭终端或手动停止后释放，不保存、不重连恢复。${link.uri == null ? '' : '确认后同时打开浏览器；HTTPS 仍由浏览器验证证书，不降低 TLS 安全设置。'}' : '确认后交给系统浏览器；不会预览网页或发送终端内容。'}',
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(forward ? (link.uri == null ? '建立临时转发' : '转发并打开') : '打开'),
        ),
      ],
    ),
  );
  if (accepted != true || !current()) return;
  String? token;
  try {
    Uri? url = link.uri;
    if (forward) {
      final running = await rust.startTemporaryForwarding(
        id: id,
        generation: generation,
        targetAddress: link.address,
        targetPort: link.port!,
      );
      token = running.token;
      if (!current()) throw StateError('原SSH会话已改变，未打开浏览器');
      final port = running.bindPort!;
      if (url != null) {
        url = url.replace(host: '127.0.0.1', port: port);
      } else if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('临时转发已建立'),
            content: SelectableText('127.0.0.1:$port\n可在当前终端的端口转发面板停止。'),
            actions: [
              TextButton(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: '127.0.0.1:$port')),
                child: const Text('复制本机地址'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    }
    if (url != null && current()) {
      final opened =
          await (launcher ??
              (uri) =>
                  launchUrl(uri, mode: LaunchMode.externalApplication))(url);
      if (!opened) {
        throw StateError(token == null ? '系统未能打开浏览器' : '系统未能打开浏览器；新建临时转发将停止');
      }
    }
  } catch (error) {
    if (token != null) {
      try {
        await rust.stopForwarding(id: id, generation: generation, token: token);
      } catch (cleanup) {
        throw StateError('$error；临时转发清理未确认：$cleanup');
      }
    }
    rethrow;
  }
}
