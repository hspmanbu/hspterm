import '../prototype/design.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../prototype/model.dart';
import '../src/rust/api.dart' as rust;
import 'file_search_controller.dart';
import 'model.dart';

Future<DemoFile?> showRemoteFileSearch(
  BuildContext context,
  TerminalSession source,
) async {
  final session = source as LiveTerminalSession;
  final terminal = session.controller;
  final id = terminal.id, generation = terminal.generation;
  if (id == null || !terminal.connected) throw StateError('请先连接文件所属SSH会话');
  final controller = FileSearchController(
    id: id,
    generation: generation,
    path: session.path,
    isCurrent: () =>
        terminal.id == id &&
        terminal.generation == generation &&
        terminal.connected,
  );
  final route = await createAppDialogRoute<rust.RemoteFile>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RemoteFileSearchDialog(controller: controller),
  );
  if (route == null || !context.mounted) {
    try {
      await controller.close();
    } finally {
      controller.dispose();
    }
    return null;
  }
  try {
    final result = await Navigator.of(context).push(route);
    await route.completed;
    if (result == null) return null;
    if (!controller.isCurrent()) throw StateError('原SSH会话已改变；未定位到其他会话');
    return DemoFile(
      result.path,
      result.name,
      folder: result.directory && !result.symlink,
      symlink: result.symlink,
      byteSize: result.size,
      modifiedEpoch: result.modified,
    );
  } finally {
    try {
      await controller.close();
    } finally {
      controller.dispose();
    }
  }
}

class RemoteFileSearchDialog extends StatefulWidget {
  const RemoteFileSearchDialog({super.key, required this.controller});
  final FileSearchController controller;
  @override
  State<RemoteFileSearchDialog> createState() => _RemoteFileSearchDialogState();
}

class _RemoteFileSearchDialogState extends State<RemoteFileSearchDialog> {
  final _query = TextEditingController();
  bool _caseSensitive = false, _closing = false;
  FileSearchController get c => widget.controller;
  void _search() =>
      unawaited(c.start(_query.text, caseSensitive: _caseSensitive));
  Future<void> _finish([rust.RemoteFile? result]) async {
    if (_closing) return;
    setState(() => _closing = true);
    await c.cancel();
    if (mounted) Navigator.pop(context, result);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_finish());
      },
      child: AlertDialog(
        scrollable: true,
        title: const Text('递归查找文件'),
        content: SizedBox(
          width: 760,
          height: 480,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      c.root,
                      maxLines: 2,
                      style: const TextStyle(fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 270,
                          child: TextField(
                            key: const ValueKey('file-search-query'),
                            controller: _query,
                            autofocus: true,
                            enabled: !c.running && !_closing,
                            onSubmitted: (_) => _search(),
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: '文件名包含（不读取文件正文）',
                            ),
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Checkbox(
                              value: _caseSensitive,
                              onChanged: c.running || _closing
                                  ? null
                                  : (v) => setState(() => _caseSensitive = v!),
                            ),
                            const Text('区分大小写'),
                          ],
                        ),
                        FilledButton(
                          key: const ValueKey('file-search-start'),
                          onPressed: c.running || _closing ? null : _search,
                          child: const Text('搜索'),
                        ),
                        TextButton(
                          onPressed: c.running && !_closing ? c.cancel : null,
                          child: const Text('取消搜索'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${c.results.length} 项匹配 · 已扫描 ${c.scanned} 项 / ${c.directories} 个目录 · ${c.running
                          ? '搜索中'
                          : c.done
                          ? '搜索完成'
                          : '未完整搜索'}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    if (c.running)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: LinearProgressIndicator(),
                      ),
                    if (c.error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: SelectableText(
                          c.error!,
                          maxLines: 3,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate((context, i) {
                  final file = c.results[i];
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: Icon(
                      file.directory
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                      size: 18,
                    ),
                    title: Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      file.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.my_location, size: 16),
                    onTap: _closing ? null : () => _finish(file),
                  );
                }, childCount: c.results.length),
              ),
              const SliverToBoxAdapter(
                child: Text(
                  '点击结果在原会话 SFTP 中定位；不自动打开或下载文件，不遍历子目录符号链接。',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('file-search-close'),
            onPressed: _closing ? null : _finish,
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );
}
