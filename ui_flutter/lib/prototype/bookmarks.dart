import 'dart:async';

import 'package:flutter/material.dart';

import 'design.dart';
import 'model.dart';

Future<void> showDirectoryBookmarks(
  BuildContext context,
  WorkbenchModel model,
  TerminalSession source,
) => showDialog<void>(
  context: context,
  builder: (_) => DirectoryBookmarks(model: model, source: source),
);

/// Captures the source session, never reads the subsequently focused terminal.
class DirectoryBookmarks extends StatefulWidget {
  const DirectoryBookmarks({
    super.key,
    required this.model,
    required this.source,
  });
  final WorkbenchModel model;
  final TerminalSession source;
  @override
  State<DirectoryBookmarks> createState() => _DirectoryBookmarksState();
}

class _DirectoryBookmarksState extends State<DirectoryBookmarks> {
  List<PathBookmark> _items = [];
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final items = await widget.model.listPathBookmarks(widget.source);
      if (mounted) setState(() => _items = items);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(PathBookmark bookmark) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.model.loadDirectory(widget.source, bookmark.path);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([PathBookmark? bookmark]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _BookmarkEditor(
        model: widget.model,
        source: widget.source,
        bookmark: bookmark,
      ),
    );
    if (saved == true && mounted) await _load();
  }

  Future<void> _delete(PathBookmark bookmark) async {
    if (!await confirm(
          context,
          '删除目录书签？',
          '${bookmark.name}\n${bookmark.path}\n范围：${bookmark.hostId == null ? '全局' : '当前主机'}\n仅删除书签配置，不删除远端文件。',
          accept: '删除书签',
          danger: true,
        ) ||
        !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.model.deletePathBookmark(bookmark.id);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.model.isMock ? '目录书签 · 模拟数据' : '目录书签'),
    content: SizedBox(
      width: 560,
      height: 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '关联会话：${widget.source.host.name}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Expanded(
            child: _items.isEmpty
                ? const Center(child: Text('尚无目录书签'))
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final item = _items[i];
                      return ListTile(
                        key: ValueKey('bookmark-${item.id}'),
                        dense: true,
                        leading: Icon(
                          item.hostId == null
                              ? Icons.public
                              : Icons.dns_outlined,
                          size: 18,
                        ),
                        title: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Tooltip(
                          message: item.path,
                          child: Text(
                            '${item.hostId == null ? '全局' : '当前主机'} · ${item.path}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        onTap: _busy ? null : () => unawaited(_open(item)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Tool(
                              Icons.edit_outlined,
                              '编辑书签 ${item.name}',
                              _busy ? null : () => unawaited(_edit(item)),
                            ),
                            Tool(
                              Icons.delete_outline,
                              '删除书签 ${item.name}',
                              _busy ? null : () => unawaited(_delete(item)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('bookmark-add'),
        onPressed: _busy ? null : () => unawaited(_edit()),
        child: const Text('收藏当前目录'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

class _BookmarkEditor extends StatefulWidget {
  const _BookmarkEditor({
    required this.model,
    required this.source,
    this.bookmark,
  });
  final WorkbenchModel model;
  final TerminalSession source;
  final PathBookmark? bookmark;
  @override
  State<_BookmarkEditor> createState() => _BookmarkEditorState();
}

class _BookmarkEditorState extends State<_BookmarkEditor> {
  late final TextEditingController _name, _path;
  late bool _global;
  bool _busy = false;
  String? _nameError, _pathError, _error;
  @override
  void initState() {
    super.initState();
    final path = widget.bookmark?.path ?? widget.source.path;
    _name = TextEditingController(
      text:
          widget.bookmark?.name ??
          (path.split('/').last.isEmpty ? '/' : path.split('/').last),
    );
    _path = TextEditingController(text: path);
    _global = widget.bookmark != null && widget.bookmark!.hostId == null;
  }

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _nameError = _name.text.trim().isEmpty ? '请输入书签名称' : null;
      _pathError = !_path.text.startsWith('/') || _path.text.contains('\u0000')
          ? '请输入绝对远端路径'
          : null;
      _error = null;
    });
    if (_nameError != null || _pathError != null) return;
    setState(() => _busy = true);
    try {
      await widget.model.savePathBookmark(
        widget.source,
        id: widget.bookmark?.id,
        name: _name.text,
        path: _path.text,
        global: _global,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.bookmark == null ? '收藏目录' : '编辑目录书签'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '所属主机：${widget.source.host.name}',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('bookmark-name'),
            controller: _name,
            enabled: !_busy,
            autofocus: true,
            decoration: InputDecoration(labelText: '名称', errorText: _nameError),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('bookmark-path'),
            controller: _path,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: '远端绝对路径',
              errorText: _pathError,
            ),
          ),
          const SizedBox(height: 6),
          CheckboxListTile(
            key: const ValueKey('bookmark-global'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('全局书签（各主机均可见）', style: TextStyle(fontSize: 12)),
            value: _global,
            onChanged: _busy
                ? null
                : (v) => setState(() => _global = v ?? false),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('bookmark-save'),
        onPressed: _busy ? null : () => unawaited(_save()),
        child: const Text('保存书签'),
      ),
    ],
  );
}
