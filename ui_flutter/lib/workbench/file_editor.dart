import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

import '../prototype/design.dart';
import '../prototype/model.dart';
import '../src/rust/api.dart' as rust;
import '../src/rust/editors.dart';
import 'editor_controller.dart';
import 'model.dart';

const editorEncodings = {
  'utf8': 'UTF-8',
  'utf8_bom': 'UTF-8 BOM',
  'utf16_le': 'UTF-16 LE BOM',
  'utf16_be': 'UTF-16 BE BOM',
  'utf16_le_no_bom': 'UTF-16 LE 无 BOM',
  'utf16_be_no_bom': 'UTF-16 BE 无 BOM',
  'gb18030': 'GB18030',
  'gbk': 'GBK',
  'big5': 'Big5',
  'shift_jis': 'Shift JIS',
  'windows1252': 'Windows-1252',
};

Future<void> showRemoteFileEditor(
  BuildContext context,
  LiveWorkbenchModel model,
  TerminalSession source,
  DemoFile file, {
  bool chooseEncoding = false,
  bool rawMode = false,
}) async {
  final session = source as LiveTerminalSession;
  final id = session.controller.id, generation = session.controller.generation;
  if (id == null || !session.controller.connected) {
    throw StateError('请先连接文件所属SSH会话');
  }
  if (!session.files.contains(file)) throw StateError('目录内容已更新，请重新选择文件');
  if (file.folder) throw StateError('请选择需要编辑的文本文件');
  String? inputEncoding;
  if (chooseEncoding) {
    inputEncoding = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择原文件编码'),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text('不会猜测编码；无法无损往返时拒绝读取。'),
          ),
          for (final entry in editorEncodings.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry.key),
              child: Text(entry.value),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (inputEncoding == null || !context.mounted) return;
    if (session.controller.id != id ||
        session.controller.generation != generation ||
        !session.controller.connected ||
        !session.files.contains(file)) {
      throw StateError('选择期间SSH会话或目录已改变，请重新选择文件');
    }
  }
  final reserve = rawMode ? rust.reserveRawEditor : rust.reserveEditor;
  final token = reserve(id: id, generation: generation, path: file.id);
  final controller = RemoteEditorController(
    token,
    source: session.controller,
    initialInputEncoding: inputEncoding,
    initialRawMode: rawMode,
  );
  await _show(context, model, controller);
}

Future<void> _show(
  BuildContext context,
  LiveWorkbenchModel model,
  RemoteEditorController controller,
) async {
  var registered = false;
  try {
    model.registerEditor(controller);
    registered = true;
    if (!context.mounted) return;
    await showRemoteEditorDialog(context, controller, model: model);
  } finally {
    // The owner, not a widget rebuild/dispose, drains persistence and releases
    // the native token. Model shutdown joins the same idempotent close Future.
    try {
      await controller.close(keepDraft: true);
    } finally {
      if (registered && controller.closed) model.unregisterEditor(controller);
      if (controller.closed) controller.dispose();
    }
  }
}

/// Navigator.push completes at pop, before the outgoing route is unmounted.
/// Owners must retain the text controller until the dialog transition ends.
Future<void> showRemoteEditorDialog(
  BuildContext context,
  RemoteEditorController controller, {
  LiveWorkbenchModel? model,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RemoteEditorDialog(controller: controller, model: model),
  );
  await navigator.push(route);
  await route.completed;
}

class RemoteEditorDialog extends StatefulWidget {
  const RemoteEditorDialog({super.key, required this.controller, this.model});
  final RemoteEditorController controller;
  final LiveWorkbenchModel? model;
  @override
  State<RemoteEditorDialog> createState() => _RemoteEditorDialogState();
}

class _RemoteEditorDialogState extends State<RemoteEditorDialog> {
  final _scroll = ScrollController();
  bool _asking = false;
  String _inputEncoding = 'gb18030';
  RemoteEditorController get c => widget.controller;
  String _progressLabel(EditorProgress? p) {
    if (p == null) return c.loading ? '正在准备读取…' : '正在准备保存…';
    final phase = switch (p.phase) {
      'waiting' => '等待编辑操作',
      'preparing' => '准备编码或SFTP通道',
      'reading' => p.total == p.acknowledged ? '正文已读取，等待关闭确认' : '读取正文',
      'writing' => p.total == p.acknowledged ? '字节已写入，等待服务器确认' : '上传正文',
      'confirming' => '等待SFTP通道关闭确认',
      'persisting' => '写入本机加密草稿及确认状态',
      'restoring' => '读取本机加密草稿',
      'complete' => '操作已确认',
      'cancelled' => '已取消，完整本机草稿保留',
      _ => '操作未确认，完整本机草稿保留',
    };
    return p.total == null
        ? phase
        : '$phase · ${p.acknowledged} / ${p.total} 字节';
  }

  @override
  void initState() {
    super.initState();
    unawaited(c.load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_asking || c.closing || c.saving) return;
    _asking = true;
    try {
      if (c.composing) {
        notice(context, '请先确认或取消输入法候选，再关闭编辑文档');
        return;
      }
      // A failed/offline load may indicate an unknown journal version. Closing
      // the view must release its token without deleting unexamined records.
      var keep = !c.ready;
      if (c.hasExternalCopy) {
        if (!await confirm(
          context,
          '保留外部工作文件并关闭？',
          '关闭将停止本次自动回传。外部编辑器可能仍在运行，本机工作文件与加密草稿会保留，可从本机编辑草稿恢复；不会自动重连。',
          accept: '保留并关闭',
        )) {
          return;
        }
        keep = true;
      } else if (c.dirty) {
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('尚有未保存到远端的修改'),
            content: const Text(
              '保留草稿会在本机加密保存，不上传、不自动重连。丢弃将删除本机草稿；若刚才保存中断，远端可能已有部分写入。',
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'discard'),
                child: const Text('丢弃修改'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'keep'),
                child: const Text('保留草稿并关闭'),
              ),
            ],
          ),
        );
        if (choice == null) return;
        keep = choice == 'keep';
      }
      await c.close(keepDraft: keep);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      // The controller displays the persistence/cleanup failure. Keep the text
      // and dialog open; never turn a failed close into a successful discard.
    } finally {
      _asking = false;
    }
  }

  Future<void> _externalAction(String action) async {
    try {
      if (action == 'pause') {
        c.external?.pause();
        return;
      }
      if (action == 'resume') {
        c.resumeExternalUploads();
        return;
      }
      if (action == 'copy') {
        final path = c.external?.path ?? c.summary?.externalDirectory;
        if (path != null) await Clipboard.setData(ClipboardData(text: path));
        return;
      }
      if (action == 'cleanup') {
        if (!await confirm(
          context,
          '确认外部编辑器已关闭？',
          '请先关闭所有正在编辑此工作文件的外部程序。将读取最新工作内容并保存到本机加密草稿，再清理本机工作文件；不修改远端。存在未知备份或交换文件时保留目录。工作目录缺失时只能保留已有草稿，请先确认没有移走尚未回传的文件。',
          accept: '读取最新修改并清理',
        )) {
          return;
        }
        await c.cleanupExternal();
        return;
      }
      if (c.composing) {
        notice(context, '请先确认或取消输入法候选');
        return;
      }
      FocusScope.of(context).unfocus();
      final executable = await openFile();
      if (executable == null || !mounted) return;
      if (Platform.isWindows &&
          !executable.path.toLowerCase().endsWith('.exe')) {
        notice(context, '请选择外部文本编辑器的 exe 可执行文件');
        return;
      }
      final override = widget.model?.editorSupportDirectory;
      final base = override == null
          ? await getApplicationSupportDirectory()
          : Directory(override);
      await base.create(recursive: true);
      if (!mounted) return;
      await c.startExternal(
        executable.path,
        base.path,
        (path) => confirm(
          context,
          '恢复外部工作文件？',
          '已有工作文件，可能含上次退出后保存的修改。读取后会替换当前内置文本并更新加密草稿，不立即上传；后续外部保存会自动回传到原服务器。\n\n$path',
          accept: '读取工作文件并继续',
        ),
      );
    } catch (e) {
      if (mounted) notice(context, '外部编辑操作未完成：$e');
    }
  }

  Widget format(
    String value,
    String label,
    Map<String, String> choices,
    ValueChanged<String> change,
  ) => SizedBox(
    width: 146,
    child: DropdownButtonFormField<String>(
      key: ValueKey('editor-format-$label-$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: choices.entries
          .map(
            (e) => DropdownMenuItem(
              value: e.key,
              child: Text(e.value, style: const TextStyle(fontSize: 12)),
            ),
          )
          .toList(),
      onChanged:
          c.saving ||
              c.closing ||
              c.closed ||
              c.externalActive ||
              c.externalBusy
          ? null
          : (v) {
              if (v != null) change(v);
            },
    ),
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final size = MediaQuery.sizeOf(context);
      final summary = c.summary;
      final current = widget.model?.focus;
      final bindSource =
          current is LiveTerminalSession && current.controller.connected
          ? current
          : null;
      return PopScope(
        canPop: c.closed,
        onPopInvokedWithResult: (popped, _) {
          if (!popped) unawaited(_close());
        },
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.keyS, control: true):
                _SaveEditorIntent(),
          },
          child: Actions(
            actions: {
              _SaveEditorIntent: CallbackAction<_SaveEditorIntent>(
                onInvoke: (_) {
                  if (c.canSave) unawaited(c.save());
                  return null;
                },
              ),
            },
            child: Dialog(
              insetPadding: const EdgeInsets.all(18),
              child: SizedBox(
                width: math.min(1100, size.width - 36),
                height: math.max(220, size.height - 72),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.edit_document, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${c.rawMode ? '远端文件 · 外部编辑' : '远端文本编辑'}${c.dirty ? ' · 未保存到远端' : ''}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton(
                            key: const ValueKey('editor-close'),
                            onPressed: c.saving || c.closing || c.externalBusy
                                ? null
                                : _close,
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                      if (summary != null) ...[
                        SelectableText(
                          '${summary.username}@${summary.address}:${summary.port}  ${summary.path}',
                          maxLines: 2,
                          style: const TextStyle(fontSize: 11),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (!c.rawMode)
                              format(
                                c.encoding,
                                '编码',
                                editorEncodings,
                                (v) => c.setFormat(encoding: v),
                              ),
                            if (!c.rawMode)
                              format(c.lineEnding, '换行', const {
                                'preserve': '保留原文',
                                'lf': 'LF',
                                'crlf': 'CRLF',
                                'cr': 'CR',
                              }, (v) => c.setFormat(lineEnding: v)),
                            FilledButton.icon(
                              key: const ValueKey('editor-save'),
                              onPressed: c.canSave ? c.save : null,
                              icon: const Icon(Icons.save_outlined, size: 16),
                              label: Text(
                                c.saving ? '正在保存…' : '保存到原服务器 · Ctrl+S',
                              ),
                            ),
                            if (!Platform.isAndroid)
                              PopupMenuButton<String>(
                                key: const ValueKey('external-editor-menu'),
                                tooltip: '外部文本编辑器',
                                enabled:
                                    !c.saving &&
                                    !c.closing &&
                                    !c.externalBusy &&
                                    !c.binding,
                                onSelected: _externalAction,
                                child: const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Text(
                                    '外部编辑…',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'open',
                                    child: Text(
                                      c.externalActive
                                          ? '重新选择外部编辑器…'
                                          : '选择外部编辑器…',
                                    ),
                                  ),
                                  if (c.externalActive)
                                    PopupMenuItem(
                                      value: c.external!.paused
                                          ? 'resume'
                                          : 'pause',
                                      enabled: c.external!.paused
                                          ? c.source?.connected == true
                                          : true,
                                      child: Text(
                                        c.external!.paused
                                            ? '继续自动回传'
                                            : '暂停自动回传',
                                      ),
                                    ),
                                  if (c.hasExternalCopy)
                                    const PopupMenuItem(
                                      value: 'copy',
                                      child: Text('复制本机工作路径'),
                                    ),
                                  if (c.hasExternalCopy)
                                    const PopupMenuItem(
                                      value: 'cleanup',
                                      child: Text('确认结束并清理工作文件…'),
                                    ),
                                ],
                              ),
                            if (c.saving)
                              TextButton(
                                onPressed: c.cancellingSave
                                    ? null
                                    : c.cancelOperation,
                                child: Text(
                                  c.cancellingSave ? '正在取消…' : '取消保存',
                                ),
                              ),
                            if (c.source == null)
                              OutlinedButton(
                                onPressed:
                                    bindSource == null || c.closing || c.closed
                                    ? null
                                    : () => c.bind(bindSource.controller),
                                child: Text(
                                  bindSource == null
                                      ? '先连接原服务器，再关联'
                                      : '关联当前会话：${bindSource.host.name}',
                                ),
                              ),
                            if (c.source != null && !c.source!.connected)
                              OutlinedButton(
                                onPressed:
                                    c.source!.phase == 'Closed' ||
                                        c.source!.phase == 'Connecting' ||
                                        c.closed ||
                                        c.closing
                                    ? null
                                    : c.reconnect,
                                child: Text(
                                  c.source!.phase == 'Connecting'
                                      ? '正在手动连接…'
                                      : c.source!.phase == 'Closed'
                                      ? '原终端已关闭，请保留草稿恢复'
                                      : '手动重新连接原终端',
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (c.loading || c.saving || c.closing) ...[
                        LinearProgressIndicator(
                          key: const ValueKey('editor-progress-bar'),
                          value:
                              c.progress?.total != null &&
                                  c.progress!.total! > 0
                              ? (c.progress!.acknowledged / c.progress!.total!)
                                    .clamp(0, 1)
                              : null,
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 4),
                          child: Text(
                            c.closing
                                ? '正在保留本机草稿并关闭…'
                                : _progressLabel(c.progress),
                            key: const ValueKey('editor-progress'),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                      if (c.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: SelectableText(
                            c.error!,
                            maxLines: 3,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      if (c.hasExternalCopy)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            c.externalActive
                                ? c.external!.paused
                                      ? '外部编辑中 · 自动回传已暂停；工作文件与草稿保留'
                                      : '外部编辑中 · 保存更改后自动回传到原服务器'
                                : '存在外部工作文件或待检查的关联；请先恢复或确认清理，再保存内置文本',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      if (!c.ready &&
                          c.rawMode &&
                          !c.loading &&
                          !c.closing &&
                          c.source != null)
                        TextButton(
                          key: const ValueKey('editor-raw-retry'),
                          onPressed: c.load,
                          child: const Text('重新读取大文件'),
                        ),
                      if (!c.ready &&
                          !c.rawMode &&
                          !c.loading &&
                          !c.closing &&
                          c.source != null)
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: 210,
                              child: DropdownButtonFormField<String>(
                                key: const ValueKey('editor-input-encoding'),
                                initialValue: _inputEncoding,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: '明确选择原文件编码',
                                  isDense: true,
                                ),
                                items: editorEncodings.entries
                                    .map(
                                      (e) => DropdownMenuItem(
                                        value: e.key,
                                        child: Text(e.value),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  if (v != null) {
                                    setState(() => _inputEncoding = v);
                                  }
                                },
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('editor-reload-encoding'),
                              onPressed: () =>
                                  c.load(inputEncoding: _inputEncoding),
                              child: const Text('按此编码重新读取'),
                            ),
                          ],
                        ),
                      if (c.externalActive &&
                          const {
                            'gb18030',
                            'gbk',
                            'big5',
                            'shift_jis',
                            'windows1252',
                          }.contains(c.encoding))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            '外部程序须保持 ${editorEncodings[c.encoding]} 编码；切换为 Unicode 时请保存带 BOM 的文件。',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      Expanded(
                        child: c.ready
                            ? c.rawMode
                                  ? Center(
                                      key: const ValueKey('editor-raw-body'),
                                      child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.insert_drive_file_outlined,
                                              size: 32,
                                            ),
                                            const SizedBox(height: 12),
                                            Text(
                                              '外部大文件编辑 · ${c.summary!.rawBytes ?? 0} 字节',
                                            ),
                                            const SizedBox(height: 8),
                                            const Text(
                                              '通过上方“外部编辑”菜单选择程序。原始字节分块加密保留，编码与换行由外部编辑器控制；应用内不加载完整正文。',
                                              textAlign: TextAlign.center,
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  : DecoratedBox(
                                      key: const ValueKey('editor-text-region'),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Theme.of(context).dividerColor,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: TextField(
                                        key: const ValueKey('editor-content'),
                                        controller: c.content,
                                        scrollController: _scroll,
                                        enabled:
                                            !c.saving &&
                                            !c.closing &&
                                            !c.closed,
                                        readOnly:
                                            c.externalActive || c.externalBusy,
                                        autofocus: true,
                                        expands: true,
                                        maxLines: null,
                                        textAlignVertical:
                                            TextAlignVertical.top,
                                        keyboardType: TextInputType.multiline,
                                        autocorrect: false,
                                        enableSuggestions: false,
                                        style: const TextStyle(
                                          fontFamily: 'JetBrainsMono',
                                          fontSize: 13,
                                          height: 1.4,
                                        ),
                                        decoration: const InputDecoration(
                                          border: InputBorder.none,
                                          contentPadding: EdgeInsets.all(10),
                                        ),
                                      ),
                                    )
                            : Center(
                                child: Text(
                                  c.loading
                                      ? c.source == null
                                            ? '正在读取本机加密草稿…'
                                            : '正在从原SSH会话读取文件…'
                                      : '未载入正文；可关闭后重新选择文件。',
                                ),
                              ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        c.closing
                            ? '正在保存本机草稿并关闭…'
                            : c.ready
                            ? '${c.persisted
                                  ? '本机草稿已加密保存'
                                  : c.composing
                                  ? '输入法组合中，尚未记录'
                                  : '正在等待本机草稿保存'} · 保存将直接覆盖原文件，不比对外部修改；失败后保留完整草稿。'
                            : '仅处理文本文件，正文上限16MiB；不支持或超限时请从文件列表下载处理。',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _SaveEditorIntent extends Intent {
  const _SaveEditorIntent();
}

Future<void> showEditorDrafts(
  BuildContext context,
  LiveWorkbenchModel model,
) async {
  final draft = await showDialog<String>(
    context: context,
    builder: (_) => const _EditorDraftsDialog(),
  );
  if (draft == null || !context.mounted) return;
  final token = rust.reserveSavedEditor(draftId: draft);
  await _show(context, model, RemoteEditorController(token));
}

class _EditorDraftsDialog extends StatefulWidget {
  const _EditorDraftsDialog();
  @override
  State<_EditorDraftsDialog> createState() => _EditorDraftsDialogState();
}

class _EditorDraftsDialogState extends State<_EditorDraftsDialog> {
  List<EditorSummary>? rows;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final next = await rust.listEditorDrafts();
      if (mounted) setState(() => rows = next);
    } catch (e) {
      if (mounted) setState(() => error = '读取本机编辑草稿失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> discard(EditorSummary row) async {
    if (!await confirm(
      context,
      '删除本机编辑草稿？',
      '${row.username}@${row.address}:${row.port}\n${row.path}\n\n删除本机草稿，不修改远端文件；未上传的修改将丢失。',
      accept: '删除草稿',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await rust.discardEditorDraft(draftId: row.id);
      if (mounted) await load();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '草稿删除失败，原数据保留：$e';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('本机加密编辑草稿'),
    content: SizedBox(
      width: 720,
      height: 380,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '恢复只读取本机草稿，不自动连接。保存前需明确关联来源一致的SSH会话。',
            style: TextStyle(fontSize: 12),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Expanded(
            child: rows == null || rows!.isEmpty
                ? const Center(child: Text('没有可恢复的本机编辑草稿'))
                : ListView.builder(
                    itemCount: rows!.length,
                    itemBuilder: (context, index) {
                      final row = rows![index];
                      return ListTile(
                        dense: true,
                        title: Text(
                          row.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${row.username}@${row.address}:${row.port} · ${row.externalDirectory != null
                              ? '有外部工作文件，可能有未回传修改'
                              : row.active
                              ? '正在编辑'
                              : row.revision != row.savedRevision
                              ? '有未保存到远端的修改'
                              : '已与远端保存一致'}',
                        ),
                        onTap: busy || row.active
                            ? null
                            : () => Navigator.pop(context, row.id),
                        trailing: IconButton(
                          tooltip: '删除本机草稿',
                          onPressed: busy || row.active
                              ? null
                              : () => discard(row),
                          icon: const Icon(Icons.delete_outline, size: 18),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: busy ? null : load, child: const Text('刷新')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
