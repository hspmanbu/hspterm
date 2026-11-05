import '../workbench/file_properties.dart';
import '../workbench/explorer_export.dart';
import '../workbench/model.dart' show LiveTerminalSession, LiveWorkbenchModel;
import '../workbench/terminal_paths.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart' as picker;

import 'dart:io';

import 'design.dart';
import 'model.dart';
import 'cached_path_field.dart';
import 'queue.dart';
import 'bookmarks.dart';
import '../platform/explorer_drop.dart';

class RemoteDrag {
  RemoteDrag(
    this.sessionId,
    this.sourcePath,
    List<DemoFile> files, {
    this.generation,
  }) : files = List.unmodifiable(
         files.map(
           (file) => DemoFile(
             file.id,
             file.name,
             folder: file.folder,
             size: file.size,
             kind: file.kind,
             modified: file.modified,
             byteSize: file.byteSize,
             modifiedEpoch: file.modifiedEpoch,
             symlink: file.symlink,
           ),
         ),
       );
  final String sessionId, sourcePath;
  final List<DemoFile> files;
  final int? generation;
}

String quotePath(String path) => "'${path.replaceAll("'", "'\\''")}'";
typedef RemoteFileOpener = Future<void> Function(
  BuildContext,
  TerminalSession,
  DemoFile,
);

typedef RemoteBatchDestination = Future<void> Function(
  BuildContext,
  TerminalSession,
  List<DemoFile>,
  bool move,
);

class SftpSidebar extends StatelessWidget {
  const SftpSidebar({
    super.key,
    required this.model,
    this.queueBuilder,
    this.onOpenFile,
    this.onEditFile,
    this.onEditFileWithEncoding,
    this.onEditRawFile,
    this.onSearchFiles,
    this.onTransferTo,
    this.onEditorDrafts,
  });
  final WorkbenchModel model;
  final WidgetBuilder? queueBuilder;
  final RemoteFileOpener? onOpenFile;
  final RemoteFileOpener? onEditFile;
  final RemoteFileOpener? onEditFileWithEncoding;
  final RemoteFileOpener? onEditRawFile;
  final RemoteBatchDestination? onTransferTo;
  final Future<DemoFile?> Function(BuildContext, TerminalSession)?
  onSearchFiles;
  final Future<void> Function(BuildContext)? onEditorDrafts;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final height = model.queueHeight.clamp(
        130.0,
        (bounds.maxHeight * .57).clamp(130, 600),
      );
      return Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            if (!model.queueMaximized)
              Expanded(
                child: model.focus == null
                    ? const Center(child: Text('选择 SSH 会话后打开 SFTP'))
                    : FilesPanel(
                        key: ValueKey(model.focus!.id),
                        model: model,
                        pane: model.focus!,
                        onOpenFile: onOpenFile,
                        onEditFile: onEditFile,
                        onEditFileWithEncoding: onEditFileWithEncoding,
                        onEditRawFile: onEditRawFile,
                        onSearchFiles: onSearchFiles,
                        onTransferTo: onTransferTo,
                        onEditorDrafts: onEditorDrafts,
                      ),
              ),
            if (!model.queueMaximized && model.focus != null)
              SftpTerminalActions(model: model, source: model.focus!),
            if (!model.queueMaximized)
              ColoredBox(
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: .15),
                child: ResizeGrip(
                  key: const ValueKey('queue-grip'),
                  horizontal: false,
                  onDelta: (d) {
                    model.queueHeight = (height - d).clamp(
                      130,
                      bounds.maxHeight * .75,
                    );
                    model.changed();
                  },
                ),
              ),
            SizedBox(
              height: model.queueMaximized
                  ? bounds.maxHeight
                  : height.toDouble(),
              child: queueBuilder?.call(context) ?? TransferQueue(model: model),
            ),
          ],
        ),
      );
    },
  );
}

class FilesPanel extends StatefulWidget {
  const FilesPanel({
    super.key,
    required this.model,
    required this.pane,
    this.onOpenFile,
    this.onEditFile,
    this.onEditFileWithEncoding,
    this.onEditRawFile,
    this.onSearchFiles,
    this.onTransferTo,
    this.onEditorDrafts,
  });
  final WorkbenchModel model;
  final TerminalSession pane;
  final RemoteFileOpener? onOpenFile;
  final RemoteFileOpener? onEditFile;
  final RemoteFileOpener? onEditFileWithEncoding;
  final RemoteFileOpener? onEditRawFile;
  final RemoteBatchDestination? onTransferTo;
  final Future<DemoFile?> Function(BuildContext, TerminalSession)?
  onSearchFiles;
  final Future<void> Function(BuildContext)? onEditorDrafts;
  @override
  State<FilesPanel> createState() => _FilesPanelState();
}

class _FilesPanelState extends State<FilesPanel> {
  int _menuRequest = 0;
  int _navigationRequest = 0;
  final selected = <String>{};
  final _focus = FocusNode();
  final _renameFocus = FocusNode();
  final _rename = TextEditingController(), _filter = TextEditingController();
  late final TextEditingController _path;
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  String? editing, renameError, anchor, hoverTarget, _newEntryTail;
  bool _renameBusy = false, _pathEditing = false;
  late String _shownPath;
  late int _shownGeneration;
  bool hidden = false, compact = false, filtering = false, foldersFirst = true;
  Object? _defaultsRevision;
  int sortColumn = 0;
  bool ascending = true;
  List<DemoFile>? _visible;
  final widths = <double>[210, 155, 90, 105];
  List<int> _columnOrder = [0, 1, 2, 3];
  Set<int> _hiddenColumns = {};
  Iterable<int> get _columns =>
      _columnOrder.where((i) => !_hiddenColumns.contains(i));
  static const _columnNames = ['名称', '修改时间', '大小', '类型'];

  Future<void> configureColumns() async {
    final order = List<int>.of(_columnOrder),
        hidden = Set<int>.of(_hiddenColumns);
    final result = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          title: const Text('文件列表列'),
          content: SizedBox(
            width: 320,
            height: 240,
            child: ReorderableListView(
              onReorderItem: (oldIndex, newIndex) => update(() {
                final item = order.removeAt(oldIndex);
                order.insert(newIndex, item);
              }),
              children: [
                for (final i in order)
                  CheckboxListTile(
                    key: ValueKey('configure-file-column-$i'),
                    title: Text(_columnNames[i]),
                    subtitle: i == 0 ? const Text('名称列保持可见，支持移动位置') : null,
                    value: !hidden.contains(i),
                    onChanged: i == 0
                        ? null
                        : (value) => update(() {
                            if (value == true) {
                              hidden.remove(i);
                            } else {
                              hidden.add(i);
                            }
                          }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (result == true && mounted) {
      setState(() {
        _columnOrder = order;
        _hiddenColumns = hidden;
      });
    }
  }

  Timer? _hoverTimer;
  final _folderBounds = <String, GlobalKey>{};
  final _folderObjects = <String, DemoFile>{};
  bool _explorerOver = false;
  List<DemoFile> clipboard = [];
  bool cut = false;
  WorkbenchModel get m => widget.model;
  TerminalSession get p => widget.pane;
  @override
  void initState() {
    super.initState();
    _path = TextEditingController(text: p.path);
    _shownPath = p.path;
    _shownGeneration = p.connectionGeneration;
    // Clicking outside the inline rename editor cancels it; only Enter in the
    // field applies the new name (Escape also cancels via the key handler).
    _renameFocus.addListener(_renameFocusChanged);
    _applyBrowserDefaults();
    _applyPendingLocation();
  }

  void _renameFocusChanged() {
    if (_renameFocus.hasFocus || _renameBusy || editing == null) return;
    if (mounted) {
      setState(() {
        editing = null;
        renameError = null;
      });
    }
  }

  @override
  void didUpdateWidget(FilesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _applyBrowserDefaults();
    if (!identical(oldWidget.pane, p) ||
        _shownPath != p.path ||
        _shownGeneration != p.connectionGeneration) {
      _hoverTimer?.cancel();
      hoverTarget = null;
      _explorerOver = false;
      _folderBounds.clear();
      _folderObjects.clear();
      _newEntryTail = null;
      _shownPath = p.path;
      _shownGeneration = p.connectionGeneration;
      _path.text = p.path;
      selected.clear();
      anchor = null;
      editing = null;
      renameError = null;
    } else {
      // An explicit refresh may replace/remove rows in the same directory.
      // Keep valid selections, but never route keys through missing objects.
      final ids = p.files.map((file) => file.id).toSet();
      selected.removeWhere((id) => !ids.contains(id));
      if (anchor != null && !ids.contains(anchor)) anchor = null;
      if (editing != null && !ids.contains(editing)) {
        editing = null;
        renameError = null;
      }
    }
    _applyPendingLocation();
  }

  void _applyBrowserDefaults() {
    final revision = m.fileDefaultsRevision;
    if (_defaultsRevision == revision) return;
    _defaultsRevision = revision;
    foldersFirst = m.fileFoldersFirst;
    hidden = m.fileShowHidden;
    compact = m.fileCompact;
    _visible = null;
  }

  void _applyPendingLocation() {
    final location = p.pendingFileLocation;
    if (location == null) return;
    p.pendingFileLocation = null;
    if (location.generation != p.connectionGeneration ||
        location.directory != p.path) {
      return;
    }
    _filter.clear();
    _visible = null;
    selected.clear();
    anchor = editing = renameError = null;
    final file = location.file;
    if (file != null && p.files.any((f) => f.id == file)) {
      selected.add(file);
      anchor = file;
      hidden = hidden || file.split('/').last.startsWith('.');
      _scrollToFile(file, p, location.generation);
    }
  }

  void _scrollToFile(
    String file,
    TerminalSession source,
    int generation, {
    bool bottom = false,
  }) {
    void reveal(int retries) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !identical(source, p) ||
            source.connectionGeneration != generation ||
            !selected.contains(file) ||
            !_vertical.hasClients) {
          return;
        }
        final index = visible.indexWhere((f) => f.id == file);
        if (index < 0) return;
        final rowHeight = compact ? 28.0 : 33.0;
        final target =
            (index + 1) * rowHeight -
            (bottom ? _vertical.position.viewportDimension - rowHeight : 0);
        final maximum = _vertical.position.maxScrollExtent;
        _vertical.jumpTo(target.clamp(0, maximum));
        if (_horizontal.hasClients) _horizontal.jumpTo(0);
        // A lazy list can still estimate its old extent immediately after an
        // insertion. The jump lays out its tail; use the corrected next frame.
        if (target > maximum && retries > 0) {
          reveal(retries - 1);
          WidgetsBinding.instance.scheduleFrame();
        }
      });
    }

    reveal(2);
  }

  void run(Future<void> work) => unawaited(
    work.catchError((Object error) {
      if (mounted) notice(context, '操作失败：$error');
    }),
  );
  String pathOf(String directory, String name) =>
      '${directory == '/' ? '' : directory}/$name';
  @override
  void dispose() {
    _hoverTimer?.cancel();
    _focus.dispose();
    _renameFocus.dispose();
    _path.dispose();
    _rename.dispose();
    _filter.dispose();
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  List<DemoFile> get visible {
    final cached = _visible;
    if (cached != null) return cached;
    final query = _filter.text.toLowerCase();
    final list = p.files
        .where(
          (f) =>
              (hidden || !f.name.startsWith('.')) &&
              f.name.toLowerCase().contains(query),
        )
        .toList();
    list.sort((a, b) {
      if (foldersFirst && a.folder != b.folder) return a.folder ? -1 : 1;
      final x = switch (sortColumn) {
        1 =>
          a.modifiedEpoch != null && b.modifiedEpoch != null
              ? a.modifiedEpoch!.compareTo(b.modifiedEpoch!)
              : a.modified.compareTo(b.modified),
        2 =>
          a.byteSize != null && b.byteSize != null
              ? a.byteSize!.compareTo(b.byteSize!)
              : a.size.compareTo(b.size),
        3 => a.kind.compareTo(b.kind),
        _ => a.name.compareTo(b.name),
      };
      return ascending ? x : -x;
    });
    final tail = list.where((file) => file.id == _newEntryTail).firstOrNull;
    if (tail != null) {
      list.remove(tail);
      list.add(tail);
    }
    return _visible = list;
  }

  bool _sameSource(
    WorkbenchModel model,
    TerminalSession source,
    int generation,
    int? native,
  ) =>
      mounted &&
      identical(m, model) &&
      identical(p, source) &&
      !model.isClosing &&
      model.sessions.contains(source) &&
      source.connectionGeneration == generation &&
      (source is! LiveTerminalSession ||
          (source.controller.id == native && source.controller.connected));

  Future<bool> _navigateDirectory(
    String path, {
    bool back = false,
    bool ahead = false,
  }) async {
    final model = m, source = p;
    final generation = source.connectionGeneration;
    final native = source is LiveTerminalSession ? source.controller.id : null;
    final originPath = source.path;
    final history = List<String>.of(source.back);
    final forward = List<String>.of(source.forward);
    final request = ++_navigationRequest;
    final operation = model.loadDirectory(
      source,
      path,
      remember: !back && !ahead,
    );
    // Live loadDirectory allocates its epoch synchronously before its first await.
    final epoch = source is LiveTerminalSession ? source.directoryEpoch : null;
    await operation;
    if (!_sameSource(model, source, generation, native) ||
        request != _navigationRequest ||
        (source is LiveTerminalSession && source.directoryEpoch != epoch) ||
        source.path != path ||
        source.loadingDirectory ||
        source.sftpError != null) {
      return false;
    }
    if (back) {
      if (!listEquals(source.back, history) ||
          !listEquals(source.forward, forward) ||
          history.isEmpty ||
          history.last != path) {
        return false;
      }
      source.back.removeLast();
      source.forward.add(originPath);
    }
    if (ahead) {
      if (!listEquals(source.back, history) ||
          !listEquals(source.forward, forward) ||
          forward.isEmpty ||
          forward.last != path) {
        return false;
      }
      source.forward.removeLast();
      source.back.add(originPath);
    }
    _path.text = source.path;
    _shownPath = source.path;
    setState(() {
      selected.clear();
      editing = null;
    });
    return true;
  }

  void navigate(String path) =>
      run(_navigateDirectory(path).then<void>((_) {}));

  void select(DemoFile f) {
    _focus.requestFocus();

    final rows = visible,
        shift = HardwareKeyboard.instance.isShiftPressed,
        ctrl = HardwareKeyboard.instance.isControlPressed;
    if (shift && anchor != null && rows.any((f) => f.id == anchor)) {
      final a = rows.indexWhere((f) => f.id == anchor), b = rows.indexOf(f);
      selected.addAll(
        rows.sublist(a < b ? a : b, (a > b ? a : b) + 1).map((f) => f.id),
      );
    } else if (ctrl) {
      if (!selected.add(f.id)) selected.remove(f.id);
      anchor = f.id;
    } else {
      selected
        ..clear()
        ..add(f.id);
      anchor = f.id;
    }
    setState(() {});
  }

  void open(DemoFile f) {
    if (f.folder) {
      navigate('${p.path == '/' ? '' : p.path}/${f.name}');
    } else {
      if (!m.isMock) {
        final opener = widget.onOpenFile;
        if (opener != null) {
          run(opener(context, p, f));
        } else {
          notice(context, '当前入口未配置文件打开处理器');
        }
        return;
      }
      showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(f.name),
          content: const SizedBox(
            width: 380,
            child: SelectableText(
              '模拟文件预览\n\n本阶段不下载或打开真实文件。\n正式远端编辑与系统关联程序将在业务集成阶段接入。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> searchFiles() async {
    final action = widget.onSearchFiles;
    if (action == null) return;
    final source = p, generation = p.connectionGeneration;
    final result = await action(context, source);
    if (result == null ||
        !mounted ||
        !identical(source, p) ||
        source.connectionGeneration != generation) {
      return;
    }
    final directory = result.folder
        ? result.id
        : result.id.substring(0, result.id.lastIndexOf('/'));
    if (!await _navigateDirectory(directory.isEmpty ? '/' : directory)) return;
    if (!mounted ||
        !identical(source, p) ||
        source.connectionGeneration != generation) {
      return;
    }
    _shownPath = source.path;
    _shownGeneration = generation;
    _path.text = source.path;
    setState(() {
      _filter.clear();
      selected.clear();
      editing = null;
      if (!result.folder) {
        hidden = hidden || result.name.startsWith('.');
        if (source.files.any((f) => f.id == result.id)) {
          selected.add(result.id);
          anchor = result.id;
        }
      }
    });
    _focus.requestFocus();
    if (!result.folder) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !identical(source, p) ||
            source.connectionGeneration != generation ||
            !selected.contains(result.id) ||
            !_vertical.hasClients) {
          return;
        }
        final index = visible.indexWhere((f) => f.id == result.id);
        if (index < 0) return;
        _vertical.jumpTo(
          ((index + 1) * (compact ? 28.0 : 33.0)).clamp(
            0,
            _vertical.position.maxScrollExtent,
          ),
        );
        if (_horizontal.hasClients) _horizontal.jumpTo(0);
      });
    }
  }

  Future<void> upload() async {
    final target = p;
    final generation = p.connectionGeneration;
    final directory = target.path;
    final folder = await showDialog<bool>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('上传到当前 SFTP 目录'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('选择文件（可多选）'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('选择文件夹（一个顶层任务）'),
          ),
        ],
      ),
    );
    if (folder == null || !mounted) return;
    final paths = folder
        ? [if (await picker.getDirectoryPath() case final String path) path]
        : (await picker.openFiles()).map((f) => f.path).toList();
    final requests = paths
        .map((local) {
          final name = File(local).uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last;
          return LocalTransferRequest(local, pathOf(directory, name));
        })
        .toList(growable: false);
    await m.submitFileTransfers(
      target,
      requests,
      generation: generation,
      upload: true,
    );
  }

  Future<void> download(List<DemoFile> files) async {
    if (files.isEmpty) return;
    final target = p;
    final generation = p.connectionGeneration;
    final selected = List<DemoFile>.unmodifiable(files);
    final directory = await picker.getDirectoryPath();
    if (directory == null || !mounted) return;
    for (final file in selected) {
      if (file.name.isEmpty ||
          file.name == '.' ||
          file.name == '..' ||
          file.name.contains('/') ||
          file.name.contains('\u0000') ||
          (Platform.isWindows &&
              (RegExp(r'[\\<>:"|?*]').hasMatch(file.name) ||
                  file.name.endsWith('.') ||
                  file.name.endsWith(' ')))) {
        throw StateError('远端文件名不能安全映射到本地，请先在远端重命名');
      }
    }
    await m.submitFileTransfers(
      target,
      selected
          .map(
            (file) => LocalTransferRequest(
              '$directory${Platform.pathSeparator}${file.name}',
              file.id,
            ),
          )
          .toList(growable: false),
      generation: generation,
      upload: false,
    );
  }

  void beginRename() {
    if (selected.length != 1) return;
    final f = p.files.firstWhere((f) => f.id == selected.first);
    _rename.text = f.name;
    final dot = f.name.lastIndexOf('.');
    _rename.selection = TextSelection(
      baseOffset: 0,
      extentOffset: !f.folder && dot > 0 ? dot : f.name.length,
    );
    setState(() {
      editing = f.id;
      renameError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && editing == f.id) _renameFocus.requestFocus();
    });
  }

  Future<void> commitRename() async {
    if (_renameBusy) return;
    final name = _rename.text;
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\u0000') ||
        p.files.any((f) => f.id != editing && f.name == name)) {
      setState(() => renameError = '名称无效或已存在');
      return;
    }
    final model = m, source = p;
    final generation = source.connectionGeneration;
    final native = source is LiveTerminalSession ? source.controller.id : null;
    final directory = source.path, originalEditing = editing;
    final file = source.files.firstWhere((f) => f.id == originalEditing);
    bool current() =>
        _sameSource(model, source, generation, native) &&
        source.path == directory &&
        editing == originalEditing;
    setState(() => _renameBusy = true);
    try {
      await model.renameRemote(source, file, name);
      if (!current()) return;
      setState(() {
        editing = null;
        renameError = null;
        selected.clear();
      });
      _focus.requestFocus();
    } catch (error) {
      if (current()) setState(() => renameError = '重命名失败：$error');
    } finally {
      if (mounted) setState(() => _renameBusy = false);
    }
  }

  Future<void> delete() async {
    final model = m, source = p;
    final generation = source.connectionGeneration;
    final native = source is LiveTerminalSession ? source.controller.id : null;
    final directory = source.path;
    final files = p.files.where((f) => selected.contains(f.id)).toList();
    if (files.isEmpty) return;
    final recursive = files.any((f) => f.folder);
    if (await confirm(
          context,
          recursive || files.length > 1
              ? '确认永久删除 ${files.length} 个项目？'
              : '删除“${files.first.name}”？',
          m.isMock
              ? '模拟目录：${p.path}\n${files.map((f) => f.name).join('、')}\n${recursive ? '包含文件夹及内部内容；正式操作不会移入回收站。' : '正式操作不会移入回收站。'}\n本次只删除模拟数据。'
              : '远端目录：${p.path}\n${files.map((f) => f.name).join('、')}\n${recursive ? '将递归删除所选目录内的内容，不跟随符号链接。' : ''}此操作不可撤销，不会移入回收站。',
          accept: '删除',
          danger: true,
        ) &&
        mounted) {
      try {
        if (!_sameSource(model, source, generation, native) ||
            source.path != directory) {
          throw StateError('原删除会话或目录已改变，请重新选择并确认');
        }
        await model.deleteRemoteFiles(source, files);
        if (_sameSource(model, source, generation, native) &&
            source.path == directory) {
          setState(() => selected.clear());
        }
      } catch (error) {
        if (mounted) notice(context, '删除未全部完成：$error');
      }
    }
  }

  Future<void> menu(Offset position, DemoFile file) async {
    final request = ++_menuRequest;
    final origin = p;
    final generation = origin.connectionGeneration;
    final directory = origin.path;
    if (!selected.contains(file.id)) {
      selected
        ..clear()
        ..add(file.id);
      setState(() {});
    }
    final frozenSelection = Set<String>.of(selected);
    final files = origin.files
        .where((f) => frozenSelection.contains(f.id))
        .toList(growable: false);
    final paths = List<String>.unmodifiable(
      files.map((f) => pathOf(directory, f.name)),
    );
    if (files.isEmpty || files.length != frozenSelection.length) {
      notice(context, '文件列表已改变，请重新选择');
      return;
    }
    bool current() =>
        mounted &&
        !m.isClosing &&
        request == _menuRequest &&
        identical(p, origin) &&
        p.connectionGeneration == generation &&
        p.path == directory &&
        selected.length == frozenSelection.length &&
        selected.every(frozenSelection.contains) &&
        files.asMap().entries.every(
          (entry) => pathOf(directory, entry.value.name) == paths[entry.key],
        );
    if (!mounted || !current()) return;
    final targets = m.sessions
        .where(
          (item) =>
              !identical(item, origin) &&
              !item.disconnected &&
              (item is! LiveTerminalSession || item.controller.connected),
        )
        .map((item) => (item, item.connectionGeneration, item.path))
        .toList();
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        DeskMenuItem(
          enabled: false,
          height: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in [
                (Icons.copy, '复制', 'copy'),
                (Icons.content_cut, '剪切', 'cut'),
                (Icons.content_paste, '粘贴', 'paste'),
                (Icons.drive_file_rename_outline, '重命名', 'rename'),
                (Icons.delete_outline, '删除', 'delete'),
              ])
                Tool(item.$1, item.$2, () => Navigator.pop(context, item.$3)),
            ],
          ),
        ),
        const DeskMenuDivider(),
        const DeskMenuItem(value: 'open', child: Text('打开')),
        const DeskMenuItem(value: 'download', child: Text('下载')),
        if (widget.onEditFile != null && !file.folder)
          const DeskMenuItem(value: 'edit', child: Text('编辑')),
        if (widget.onEditFileWithEncoding != null && !file.folder)
          const DeskMenuItem(value: 'edit-encoding', child: Text('按指定编码编辑…')),
        if (widget.onEditRawFile != null && !file.folder)
          const DeskMenuItem(value: 'edit-raw', child: Text('外部编辑大文件…')),
        for (final move in [false, true])
          DeskMenuItem<String>(
            enabled: false,
            child: SubmenuButton(
              menuChildren: [
                for (var i = 0; i < targets.length; i++)
                  MenuItemButton(
                    onPressed: () => Navigator.pop(
                      context,
                      '${move ? 'move' : 'copy'}-target:$i',
                    ),
                    child: Text(
                      '${targets[i].$1.host.name} · ${targets[i].$3}',
                    ),
                  ),
                if (targets.isEmpty)
                  const MenuItemButton(
                    onPressed: null,
                    child: Text('没有其他已连接主机'),
                  ),
              ],
              child: Text(move ? '移动到' : '复制到'),
            ),
          ),
        const DeskMenuItem(value: 'name', child: Text('复制文件/文件夹名')),
        const DeskMenuItem(value: 'path', child: Text('复制路径')),
        const DeskMenuItem(value: 'send-name', child: Text('发送文件/文件夹名至终端')),
        const DeskMenuItem(value: 'send', child: Text('发送路径至终端')),
        const DeskMenuItem(value: 'properties', child: Text('属性')),
      ],
    );
    if (!mounted || action == null) return;
    if (!current()) {
      notice(context, '目录或会话已切换，请重新打开菜单；未执行文件操作');
      return;
    }
    if ((action.startsWith('copy-target:') ||
        action.startsWith('move-target:'))) {
      final target = targets[int.parse(action.split(':').last)];
      if (target.$1.connectionGeneration != target.$2 ||
          target.$1.path != target.$3 ||
          target.$1.disconnected) {
        notice(context, '目标会话或目录已改变，请重新选择');
        return;
      }
      final moving = action.startsWith('move-');
      if (m is LiveWorkbenchModel &&
          origin is LiveTerminalSession &&
          target.$1 is LiveTerminalSession) {
        if (moving &&
            !await confirm(
              context,
              '移动到 ${target.$1.host.name}？',
              '目标：${target.$3}\n复制确认后才删除来源；失败可能保留部分副本。',
              accept: '确认移动',
              danger: true,
            )) {
          return;
        }
        if (!current()) return;
        final live = m as LiveWorkbenchModel;
        final selection = live.prepareRemoteFileSelection(
          origin,
          files,
          cut: moving,
        );
        final ids = await live.enqueueRemoteFileSelection(
          selection,
          target.$1,
          target.$3,
          target.$2,
          allowMemoryRelay: true,
          allowDirect: true,
        );
        if (mounted) {
          notice(context, '已加入 ${ids.length} 个${moving ? '移动' : '复制'}任务');
        }
      } else {
        for (final f in files) {
          target.$1.files.add(
            DemoFile(
              m.nextId(),
              f.name,
              folder: f.folder,
              kind: f.kind,
              size: f.size,
            ),
          );
        }
        if (moving) origin.files.removeWhere(files.contains);
        m.changed();
        notice(context, '模拟操作；没有执行真实文件传输');
      }
      return;
    }
    switch (action) {
      case 'open':
        open(file);
      case 'edit':
        final editor = widget.onEditFile;
        if (editor != null) run(editor(context, p, file));
      case 'edit-encoding':
        final editor = widget.onEditFileWithEncoding;
        if (editor != null) run(editor(context, p, file));
      case 'edit-raw':
        final editor = widget.onEditRawFile;
        if (editor != null) run(editor(context, p, file));
      case 'copy-to':
      case 'move-to':
        final transfer = widget.onTransferTo;
        if (transfer != null) {
          run(transfer(context, origin, files, action == 'move-to'));
        }
      case 'rename':
        beginRename();
      case 'delete':
        await delete();
      case 'copy':
      case 'cut':
        if (!m.isMock) {
          try {
            m.copyRemoteFileClipboard(p, files, cut: action == 'cut');
            notice(
              context,
              '文件剪贴板：${m.remoteFileClipboardDescription}；粘贴前不会读取正文',
            );
          } catch (error) {
            notice(context, '文件选择失败：$error');
          }
          break;
        }
        clipboard = List.of(files);
        cut = action == 'cut';
        notice(context, '模拟文件剪贴板：${files.length} 项；未使用系统文件剪贴板');
      case 'paste':
        await pasteClipboard();
      case 'download':
        if (!m.isMock) {
          await download(files);
          break;
        }
        for (final f in files) {
          m.addTransfer(f.name, upload: false, folder: f.folder);
        }
        notice(context, '已加入模拟下载队列');
      case 'name':
        await Clipboard.setData(
          ClipboardData(text: files.map((f) => f.name).join('\n')),
        );
      case 'path':
        await Clipboard.setData(ClipboardData(text: paths.join('\n')));
      case 'send-name':
        sendPaths(paths, namesOnly: true);
      case 'send':
        sendPaths(paths);
      case 'terminal-cd':
        sendPaths([paths.first], enterDirectory: true);
      case 'properties':
        if (m is LiveWorkbenchModel && origin is LiveTerminalSession) {
          await showFileProperties(
            context,
            m as LiveWorkbenchModel,
            origin,
            file,
          );
        } else {
          await showDialog<void>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('模拟文件属性'),
              content: Text(
                '${file.name}\n${p.path}\n${file.kind} · ${file.folder ? '未计算' : file.size}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('关闭'),
                ),
              ],
            ),
          );
        }
    }
  }

  Future<void> pasteClipboard() async {
    if (!m.isMock) {
      final description = m.remoteFileClipboardDescription;
      if (description == null) {
        notice(context, '文件剪贴板为空');
        return;
      }
      final clipboardRevision = m.remoteFileClipboardRevision;
      final cutting = m.remoteFileClipboardIsCut;
      final target = p,
          targetDirectory = p.path,
          targetGeneration = p.connectionGeneration;
      if (await confirm(
            context,
            cutting ? '移动到当前远端目录？' : '复制到当前远端目录？',
            '$description\n目标：${target.host.name}\n$targetDirectory\n\n'
            '${cutting ? '在当前服务器执行移动，同名目标不覆盖。请避免其他程序同时修改来源。' : '在当前服务器执行复制，正文不经过本机；需 SSH 与 SFTP 使用同一路径。已有同名目标不覆盖。'}',
            accept: cutting ? '确认移动' : '确认复制',
          ) &&
          mounted) {
        try {
          final ids = await m.pasteRemoteFileClipboard(
            target,
            targetDirectory,
            targetGeneration,
            allowMemoryRelay: true,
            allowDirect: true,
            expectedClipboardRevision: clipboardRevision,
          );
          if (mounted) {
            notice(
              context,
              ids.isEmpty
                  ? '远端${cutting ? '移动' : '复制'}已完成'
                  : '已加入 ${ids.length} 个${cutting ? '移动' : '复制'}任务',
            );
          }
        } catch (error) {
          if (mounted) notice(context, '粘贴未全部入队：$error');
        }
      }
      return;
    }
    if (clipboard.isEmpty) {
      notice(context, '模拟文件剪贴板为空');
    } else {
      setState(() {
        for (final f in clipboard) {
          p.files.add(
            DemoFile(
              m.nextId(),
              '${f.name} 副本',
              folder: f.folder,
              size: f.size,
              kind: f.kind,
            ),
          );
        }
        if (cut) clipboard.clear();
      });
      notice(context, '仅演示粘贴列表；真实复制/移动尚未接入');
    }
  }

  Future<void> blankMenu(Offset position) async {
    final source = p, generation = p.connectionGeneration, directory = p.path;
    final chosen = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        DeskMenuItem(
          enabled: false,
          height: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tool(
                Icons.copy,
                '复制',
                selected.isEmpty ? null : () => Navigator.pop(context, 'copy'),
              ),
              Tool(
                Icons.content_cut,
                '剪切',
                selected.isEmpty ? null : () => Navigator.pop(context, 'cut'),
              ),
              Tool(
                Icons.content_paste,
                '粘贴',
                () => Navigator.pop(context, 'paste'),
              ),
            ],
          ),
        ),
        const DeskMenuDivider(),
        const DeskMenuItem(value: 'file', child: Text('新建文件')),
        const DeskMenuItem(value: 'folder', child: Text('新建文件夹')),
        const DeskMenuItem(value: 'refresh', child: Text('刷新目录')),
      ],
    );
    if (!mounted ||
        !identical(source, p) ||
        generation != p.connectionGeneration ||
        directory != p.path ||
        m.isClosing) {
      return;
    }
    switch (chosen) {
      case 'paste':
        await pasteClipboard();
      case 'file':
        await newFile();
      case 'folder':
        await newFolder();
      case 'refresh':
        await m.loadDirectory(p, p.path, remember: false);
      case 'copy':
      case 'cut':
        final files = p.files.where((f) => selected.contains(f.id)).toList();
        if (!m.isMock) {
          m.copyRemoteFileClipboard(p, files, cut: chosen == 'cut');
        } else {
          clipboard = files;
          cut = chosen == 'cut';
        }
    }
  }

  List<ContextMenuButtonItem> pathMenu(EditableTextState field) {
    final source = p,
        model = m,
        directory = p.path,
        generation = p.connectionGeneration;
    void dispatch(bool cd) {
      field.hideToolbar();
      if (!mounted ||
          !identical(p, source) ||
          !identical(m, model) ||
          p.path != directory ||
          p.connectionGeneration != generation ||
          model.isClosing) {
        if (mounted) notice(context, '目录或会话已改变，未发送路径');
        return;
      }
      sendPaths([directory], enterDirectory: cd);
    }

    return [
      ContextMenuButtonItem(
        label: '发送当前目录路径到终端',
        onPressed: () => dispatch(false),
      ),
      ContextMenuButtonItem(
        label: '在终端中进入当前目录',
        onPressed: () => dispatch(true),
      ),
    ];
  }

  void sendPaths(
    List<String> paths, {
    bool enterDirectory = false,
    bool namesOnly = false,
  }) {
    final model = m, source = p;
    if (model is LiveWorkbenchModel && source is LiveTerminalSession) {
      final generation = source.controller.generation;
      run(
        sendSessionPaths(
          context,
          model,
          source,
          paths,
          enterDirectory: enterDirectory,
          namesOnly: namesOnly,
          expectedGeneration: generation,
        ),
      );
      return;
    }
    if (source.disconnected) {
      notice(context, '关联模拟终端已断开；未插入路径');
      return;
    }
    final text = paths.map(quotePath).join(' ');
    source.draft += enterDirectory ? 'cd $text\n' : text;
    model.changed();
    notice(
      context,
      enterDirectory ? '仅模拟向关联终端执行cd；未进行文件传输' : '仅插入关联模拟终端；未执行、未上传下载',
    );
  }

  Future<void> newFolder() => _newEntry(true);
  Future<void> newFile() => _newEntry(false);
  Future<void> _newEntry(bool folder) async {
    final model = m, source = p;
    final generation = source.connectionGeneration;
    final native = source is LiveTerminalSession ? source.controller.id : null;
    final directory = source.path;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${m.isMock ? '模拟：' : ''}新建${folder ? '文件夹' : '文件'}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: folder ? '文件夹名称' : '文件名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final n = controller.text;
              if (n.isNotEmpty &&
                  n != '.' &&
                  n != '..' &&
                  !n.contains('\u0000') &&
                  !n.contains('/') &&
                  !source.files.any((f) => f.name == n)) {
                Navigator.pop(c, n);
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    // The route must finish disposing its TextField before its controller.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (name != null && mounted) {
      try {
        if (!_sameSource(model, source, generation, native) ||
            source.path != directory) {
          throw StateError('原创建目录会话或目录已改变，请重新确认');
        }
        if (folder) {
          await model.createRemoteDirectory(source, name);
        } else {
          await model.createRemoteFile(source, name);
        }
        if (!_sameSource(model, source, generation, native) ||
            source.path != directory) {
          return;
        }
        final item = source.files
            .where((file) => file.name == name)
            .firstOrNull;
        if (item != null) {
          setState(() {
            selected
              ..clear()
              ..add(item.id);
            anchor = item.id;
            _newEntryTail = item.id;
            hidden = hidden || name.startsWith('.');
            _filter.clear();
            _visible = null;
          });
          _scrollToFile(item.id, source, generation, bottom: true);
        }
      } catch (error) {
        if (mounted) notice(context, '创建${folder ? '目录' : '文件'}失败：$error');
      }
    }
  }

  DemoFile? _explorerFolder(Offset point) {
    _folderBounds.removeWhere((_, key) => key.currentContext == null);
    _folderObjects.removeWhere((id, _) => !_folderBounds.containsKey(id));
    for (final entry in _folderBounds.entries) {
      final file = _folderObjects[entry.key];
      if (file == null) continue;
      final box = entry.value.currentContext?.findRenderObject();
      if (box is RenderBox &&
          box.attached &&
          box.hasSize &&
          (box.localToGlobal(Offset.zero) & box.size).contains(point)) {
        return file;
      }
    }
    return null;
  }

  void _explorerHover(Offset? point) {
    if (!mounted) return;
    final folder = point == null ? null : _explorerFolder(point);
    if (_explorerOver == (point != null) && hoverTarget == folder?.id) return;
    _hoverTimer?.cancel();
    setState(() {
      _explorerOver = point != null;
      hoverTarget = folder?.id;
    });
    if (folder == null) return;
    final source = p,
        generation = p.connectionGeneration,
        directory = p.path,
        files = p.files;
    _hoverTimer = Timer(const Duration(milliseconds: 750), () {
      if (mounted &&
          identical(source, p) &&
          p.connectionGeneration == generation &&
          p.path == directory &&
          identical(p.files, files) &&
          !p.loadingDirectory &&
          !p.disconnected &&
          hoverTarget == folder.id) {
        navigate(pathOf(directory, folder.name));
      }
    });
  }

  Future<void> _explorerDrop(List<String> paths, Offset point) async {
    final model = m, source = p, generation = p.connectionGeneration;
    final directory = p.path, folder = _explorerFolder(point);
    final destination = folder == null
        ? directory
        : pathOf(directory, folder.name);
    // Validate every basename before submitting the first member. Each local
    // directory remains one task; native only delivered path metadata.
    final names = paths.map(explorerFileName).toList(growable: false);
    try {
      await model.submitFileTransfers(
        source,
        [
          for (var i = 0; i < paths.length; i++)
            LocalTransferRequest(paths[i], pathOf(destination, names[i])),
        ],
        generation: generation,
        upload: true,
      );
    } on LocalTransferSubmissionFailure catch (failure) {
      if (mounted) notice(context, failure.toString());
    }
  }

  Widget _explorerTarget(Widget child) => ExplorerFileDropRegion(
    owner: '${p.id}:${p.connectionGeneration}',
    view: (
      p.path,
      p.files,
      sortColumn,
      ascending,
      foldersFirst,
      hidden,
      compact,
      _filter.text,
      editing,
      _columnOrder,
      _hiddenColumns,
    ),
    enabled:
        !m.isMock &&
        !p.disconnected &&
        p.sftpEnabled &&
        !p.loadingDirectory &&
        p.sftpError == null &&
        editing == null &&
        !_renameBusy,
    onHover: _explorerHover,
    onDrop: _explorerDrop,
    onFailure: (message) {
      if (mounted) notice(context, message);
    },
    child: child,
  );

  Widget dropTarget({required Widget child, DemoFile? folder}) {
    final target = DragTarget<RemoteDrag>(
      key: ValueKey(
        folder == null ? 'drop-current' : 'drop-folder-${folder.name}',
      ),
      onWillAcceptWithDetails: (d) {
        if (d.data.sessionId != p.id ||
            (d.data.generation != null &&
                d.data.generation != p.connectionGeneration) ||
            (!m.isMock && d.data.generation == null) ||
            (folder != null && d.data.files.any((f) => f.id == folder.id))) {
          return false;
        }
        if (folder != null) {
          final origin = p, generation = p.connectionGeneration, path = p.path;
          _hoverTimer?.cancel();
          _hoverTimer = Timer(const Duration(milliseconds: 750), () {
            if (mounted &&
                identical(p, origin) &&
                p.connectionGeneration == generation &&
                p.path == path &&
                hoverTarget == folder.id) {
              navigate('${p.path}/${folder.name}');
            }
          });
          setState(() => hoverTarget = folder.id);
        }
        return true;
      },
      onLeave: (_) {
        _hoverTimer?.cancel();
        if (mounted) setState(() => hoverTarget = null);
      },
      onAcceptWithDetails: (d) {
        _hoverTimer?.cancel();
        if (d.data.sessionId != p.id ||
            (d.data.generation != null &&
                d.data.generation != p.connectionGeneration) ||
            (!m.isMock && d.data.generation == null)) {
          return;
        }
        final destination = folder == null
            ? p.path
            : '${p.path}/${folder.name}';
        if (!m.isMock) {
          setState(() => hoverTarget = null);
          if (destination != d.data.sourcePath) {
            run(
              m.moveRemoteFiles(
                p,
                d.data.sourcePath,
                d.data.files,
                destination,
              ),
            );
          }
          return;
        }
        if (destination != d.data.sourcePath) {
          final source = p.directories[d.data.sourcePath];
          final movedIds = d.data.files.map((file) => file.id).toSet();
          source?.removeWhere((file) => movedIds.contains(file.id));
          final old = p.path;
          p.path = destination;
          p.files.addAll(d.data.files);
          p.path = old;
        }
        setState(() => hoverTarget = null);
        notice(context, '模拟移动到 $destination；没有真实文件操作');
      },
      builder: (c, candidates, rejected) => ColoredBox(
        color:
            candidates.isNotEmpty ||
                (_explorerOver && hoverTarget == folder?.id)
            ? Theme.of(c).colorScheme.primary.withValues(alpha: .12)
            : Colors.transparent,
        child: child,
      ),
    );
    return folder == null ? _explorerTarget(target) : target;
  }

  @override
  Widget build(BuildContext context) {
    if (p.loadingDirectory ||
        p.disconnected ||
        !p.sftpEnabled ||
        p.sftpError != null) {
      _hoverTimer?.cancel();
      _explorerOver = false;
      hoverTarget = null;
    }
    // One consistent sorted/filtered snapshot per build. Lazy row builders and
    // scrolling reuse it; the next rebuild observes even in-place Mock edits.
    _visible = null;
    if (!p.sftpEnabled) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (p.loadingDirectory)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (p.sftpError != null)
                Text(
                  p.sftpError!,
                  style: const TextStyle(fontSize: 11, color: Desk.warning),
                ),
              OutlinedButton.icon(
                onPressed: p.loadingDirectory || (!m.isMock && p.disconnected)
                    ? null
                    : () => run(m.loadDirectory(p, p.path, remember: false)),
                icon: const Icon(Icons.folder_open, size: 16),
                label: Text(
                  m.isMock
                      ? '打开模拟 SFTP'
                      : p.disconnected
                      ? 'SSH 连接后可打开 SFTP'
                      : '打开 SFTP',
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Focus(
      focusNode: _focus,
      onKeyEvent: (node, e) {
        // Descendant text fields own Delete/Enter/Ctrl+A while editing paths or
        // filters. File actions belong only to the list's primary focus.
        if (!node.hasPrimaryFocus || e is! KeyDownEvent || editing != null) {
          return KeyEventResult.ignored;
        }
        if (e.logicalKey == LogicalKeyboardKey.f2) {
          beginRename();
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.delete) {
          delete();
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.enter && selected.isNotEmpty) {
          open(p.files.firstWhere((f) => f.id == selected.first));
          return KeyEventResult.handled;
        }
        if (HardwareKeyboard.instance.isControlPressed &&
            e.logicalKey == LogicalKeyboardKey.keyA) {
          setState(() => selected.addAll(visible.map((f) => f.id)));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored; // No Ctrl+C/X/V file shortcuts.
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 33,
            child: Row(
              children: [
                const SizedBox(width: 10),
                const Icon(Icons.folder_open_outlined, size: 16),
                const SizedBox(width: 7),
                const Text(
                  'SFTP',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    p.host.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).hintColor,
                      fontSize: 10,
                    ),
                  ),
                ),
                Tool(
                  m.filesMaximized ? Icons.fullscreen_exit : Icons.fullscreen,
                  'SFTP 临时最大化',
                  () {
                    m.filesMaximized = !m.filesMaximized;
                    m.changed();
                  },
                  key: const ValueKey('maximize-files'),
                ),
                Tool(
                  Icons.chevron_left,
                  '收起 SFTP',
                  m.toggleSidebar,
                  key: const ValueKey('collapse-sftp'),
                ),
              ],
            ),
          ),
          if (p.loadingDirectory) const LinearProgressIndicator(minHeight: 2),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 36,
                    child: _pathEditing
                        ? CachedPathField(
                            key: ValueKey(
                              'cached-path-${p.id}-${p.connectionGeneration}',
                            ),
                            controller: _path,
                            currentDirectory: p.path,
                            cache: p.directories,
                            contextMenuExtras: pathMenu,
                            onFocusLost: () {
                              if (_pathEditing) {
                                setState(() => _pathEditing = false);
                              }
                            },
                            onSubmitted: (value) {
                              if (value.startsWith('/') &&
                                  !value.contains('\u0000')) {
                                setState(() => _pathEditing = false);
                                navigate(value);
                              } else {
                                notice(context, '请输入绝对远端路径');
                              }
                            },
                          )
                        : GestureDetector(
                            // The whole breadcrumb strip enters path editing;
                            // breadcrumb segments still navigate themselves.
                            key: const ValueKey('sftp-path-bar'),
                            behavior: HitTestBehavior.opaque,
                            onTap: () => setState(() => _pathEditing = true),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  InkWell(
                                    onTap: () => navigate('/'),
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 8,
                                      ),
                                      child: Text('/'),
                                    ),
                                  ),
                                  for (
                                    var i = 0;
                                    i <
                                        p.path
                                            .split('/')
                                            .where((s) => s.isNotEmpty)
                                            .length;
                                    i++
                                  ) ...[
                                    const Icon(Icons.chevron_right, size: 13),
                                    Builder(
                                      builder: (context) {
                                        final parts = p.path
                                            .split('/')
                                            .where((s) => s.isNotEmpty)
                                            .toList();
                                        return InkWell(
                                          onTap: () => navigate(
                                            '/${parts.take(i + 1).join('/')}',
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 8,
                                            ),
                                            child: Text(parts[i]),
                                          ),
                                        );
                                      },
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                  ),
                ),
                Tool(Icons.refresh, m.isMock ? '刷新模拟目录' : '刷新目录', () {
                  setState(() => _newEntryTail = null);
                  run(m.loadDirectory(p, p.path, remember: false));
                }),
                Builder(
                  builder: (c) => Tool(
                    Icons.bookmark_border,
                    '书签',
                    () =>
                        run(showDirectoryBookmarkPopup(c, m, p, global: false)),
                  ),
                ),
                Builder(
                  builder: (c) => Tool(
                    Icons.public,
                    '全局书签',
                    () =>
                        run(showDirectoryBookmarkPopup(c, m, p, global: true)),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Row(
              children: [
                Tool(Icons.note_add_outlined, '新建文件', newFile),
                Tool(Icons.create_new_folder_outlined, '新建文件夹', newFolder),
                Tool(Icons.file_upload_outlined, m.isMock ? '模拟上传' : '上传', () {
                  if (m.isMock) {
                    m.addTransfer('example-upload.zip', upload: true);
                  } else {
                    run(upload());
                  }
                }),
                Tool(
                  Icons.file_download_outlined,
                  m.isMock ? '模拟下载选中项目' : '下载选中项目',
                  selected.isEmpty
                      ? null
                      : () {
                          if (!m.isMock) {
                            run(
                              download(
                                p.files
                                    .where((f) => selected.contains(f.id))
                                    .toList(),
                              ),
                            );
                            return;
                          }
                          for (final f in p.files.where(
                            (f) => selected.contains(f.id),
                          )) {
                            m.addTransfer(
                              f.name,
                              upload: false,
                              folder: f.folder,
                            );
                          }
                        },
                ),
                Tool(
                  Icons.search,
                  '筛选文件',
                  () => setState(() => filtering = !filtering),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  tooltip: '文件视图选项',
                  icon: const Icon(Icons.more_horiz, size: 17),
                  onSelected: (s) {
                    if (s == 'columns') {
                      unawaited(configureColumns());
                      return;
                    }
                    if (s == 'search-files') {
                      run(searchFiles());
                      return;
                    }
                    if (s == 'editor-drafts') {
                      final action = widget.onEditorDrafts;
                      if (action != null) run(action(context));
                      return;
                    }
                    setState(() {
                      if (s == 'hidden') hidden = !hidden;
                      if (s == 'compact') compact = !compact;
                      if (s == 'folders-first') foldersFirst = !foldersFirst;
                    });
                  },
                  itemBuilder: (_) => [
                    const DeskMenuItem(
                      value: 'columns',
                      child: Text('显示与排列列…'),
                    ),
                    if (widget.onSearchFiles != null)
                      const DeskMenuItem(
                        value: 'search-files',
                        child: Text('递归查找文件…'),
                      ),
                    if (widget.onEditorDrafts != null)
                      const DeskMenuItem(
                        value: 'editor-drafts',
                        child: Text('本机编辑草稿…'),
                      ),
                    DeskCheckedMenuItem(
                      value: 'folders-first',
                      checked: foldersFirst,
                      child: const Text('目录优先'),
                    ),
                    DeskCheckedMenuItem(
                      value: 'hidden',
                      checked: hidden,
                      child: const Text('显示隐藏文件'),
                    ),
                    DeskCheckedMenuItem(
                      value: 'compact',
                      checked: compact,
                      child: const Text('紧凑列表'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (filtering)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: SizedBox(
                height: 30,
                child: TextField(
                  controller: _filter,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: '筛选当前目录',
                    prefixIcon: Icon(Icons.search, size: 15),
                  ),
                ),
              ),
            ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onSecondaryTapUp: (event) => run(blankMenu(event.globalPosition)),
              child: dropTarget(
                child: Scrollbar(
                  controller: _horizontal,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _horizontal,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: _columns.fold<double>(
                        0,
                        (sum, i) => sum + widths[i],
                      ),
                      child: Column(
                        children: [
                          SizedBox(
                            height: 27,
                            child: Row(
                              children: [
                                for (final i in _columns)
                                  SizedBox(
                                    width: widths[i],
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: InkWell(
                                            onTap: () => setState(() {
                                              ascending = sortColumn == i
                                                  ? !ascending
                                                  : true;
                                              sortColumn = i;
                                              _newEntryTail = null;
                                            }),
                                            child: Padding(
                                              padding: const EdgeInsets.only(
                                                left: 10,
                                              ),
                                              child: Text(
                                                '${_columnNames[i]}${sortColumn == i ? (ascending ? '  ↑' : '  ↓') : ''}',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  color: Theme.of(context)
                                                      .hintColor,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        ResizeGrip(
                                          key: ValueKey('file-column-$i'),
                                          horizontal: true,
                                          onDelta: (d) => setState(
                                            () => widths[i] = (widths[i] + d)
                                                .clamp(70, 500),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Divider(
                            height: 1,
                            color: Theme.of(context).dividerColor,
                          ),
                          Expanded(
                            child: Scrollbar(
                              controller: _vertical,
                              thumbVisibility: true,
                              child: ListView.builder(
                                controller: _vertical,
                                itemCount: visible.length + 1,
                                itemBuilder: (c, index) {
                                  if (index == 0) {
                                    return InkWell(
                                      key: const ValueKey(
                                        'sftp-parent-directory',
                                      ),
                                      onDoubleTap: () {
                                        final slash = p.path.lastIndexOf('/');
                                        navigate(
                                          slash <= 0
                                              ? '/'
                                              : p.path.substring(0, slash),
                                        );
                                      },
                                      child: SizedBox(
                                        height: compact ? 28 : 33,
                                        child: const Row(
                                          children: [
                                            SizedBox(width: 10),
                                            Icon(
                                              Icons
                                                  .drive_folder_upload_outlined,
                                              size: 16,
                                            ),
                                            SizedBox(width: 8),
                                            Text('..'),
                                          ],
                                        ),
                                      ),
                                    );
                                  }
                                  final f = visible[index - 1];
                                  if (f.folder) _folderObjects[f.id] = f;
                                  Widget row = SelectionTarget(
                                    behavior: HitTestBehavior.opaque,
                                    onTapDown: (_) => select(f),
                                    onDoubleTap: () => open(f),
                                    // Complete the pointer sequence before pushing
                                    // a modal menu/editor that can steal input.
                                    onSecondaryTapUp: (d) =>
                                        run(menu(d.globalPosition, f)),
                                    child: Container(
                                      key: ValueKey('file-${f.name}'),
                                      height:
                                          editing == f.id && renameError != null
                                          ? 54
                                          : compact
                                          ? 28
                                          : 33,
                                      color: selected.contains(f.id)
                                          ? Theme.of(c).colorScheme.primary
                                                .withValues(alpha: .12)
                                          : null,
                                      // While renaming, the whole row becomes
                                      // one full-width editor; only Enter in the
                                      // field applies the change.
                                      child: editing == f.id
                                          ? Padding(
                                              padding: const EdgeInsets.only(
                                                left: 34,
                                                right: 10,
                                              ),
                                              child: Focus(
                                                onKeyEvent: (_, e) {
                                                  if (e is KeyDownEvent &&
                                                      e.logicalKey ==
                                                          LogicalKeyboardKey
                                                              .escape) {
                                                    setState(() {
                                                      editing = null;
                                                      renameError = null;
                                                    });
                                                    _focus.requestFocus();
                                                    return KeyEventResult
                                                        .handled;
                                                  }
                                                  return KeyEventResult.ignored;
                                                },
                                                child: TextField(
                                                  key: const ValueKey(
                                                    'inline-rename',
                                                  ),
                                                  controller: _rename,
                                                  focusNode: _renameFocus,
                                                  autofocus: true,
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                  ),
                                                  decoration: InputDecoration(
                                                    errorText: renameError,
                                                    contentPadding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 6,
                                                        ),
                                                  ),
                                                  onSubmitted: (_) =>
                                                      commitRename(),
                                                ),
                                              ),
                                            )
                                          : Row(
                                              children: [
                                                for (final column in _columns)
                                                  if (column == 0)
                                                    SizedBox(
                                                      width: widths[0],
                                                      child: Row(
                                                        children: [
                                                          const SizedBox(
                                                            width: 10,
                                                          ),
                                                          Icon(
                                                            f.folder
                                                                ? Icons
                                                                      .folder_outlined
                                                                : f.kind ==
                                                                          'YAML' ||
                                                                      f.kind ==
                                                                          'JSON'
                                                                ? Icons
                                                                      .data_object
                                                                : Icons
                                                                      .description_outlined,
                                                            size: 16,
                                                            color: f.folder
                                                                ? Desk.warning
                                                                : Theme.of(
                                                                    c,
                                                                  ).hintColor,
                                                          ),
                                                          const SizedBox(
                                                            width: 8,
                                                          ),
                                                          Expanded(
                                                            child: Text(
                                                              f.name,
                                                              style:
                                                                  const TextStyle(
                                                                    fontSize:
                                                                        11,
                                                                  ),
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                            width: 7,
                                                          ),
                                                        ],
                                                      ),
                                                    )
                                                  else
                                                    SizedBox(
                                                      width: widths[column],
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets.only(
                                                              left: 10,
                                                            ),
                                                        child: Text(
                                                          [
                                                            '',
                                                            f.modified,
                                                            f.folder
                                                                ? '—'
                                                                : f.size,
                                                            f.kind,
                                                          ][column],
                                                          style: TextStyle(
                                                            fontSize: 10,
                                                            color: Theme.of(c)
                                                                .hintColor,
                                                          ),
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                      ),
                                                    ),
                                              ],
                                            ),
                                    ),
                                  );
                                  row = Draggable<RemoteDrag>(
                                    // Secondary clicks belong to the file menu;
                                    // never enter a drag arena for that button.
                                    allowedButtonsFilter: (buttons) =>
                                        buttons == kPrimaryMouseButton &&
                                        !explorerExportGesture,
                                    data: RemoteDrag(
                                      p.id,
                                      p.path,
                                      selected.contains(f.id)
                                          ? visible
                                                .where(
                                                  (f) =>
                                                      selected.contains(f.id),
                                                )
                                                .toList()
                                          : [f],
                                      generation: p.connectionGeneration,
                                    ),
                                    feedback: const SizedBox.shrink(),
                                    child: row,
                                  );
                                  final live = m;
                                  if (live is LiveWorkbenchModel &&
                                      p is LiveTerminalSession) {
                                    row = ExplorerExportDrag(
                                      model: live,
                                      source: p as LiveTerminalSession,
                                      selection: () => selected.contains(f.id)
                                          ? visible
                                                .where(
                                                  (entry) => selected.contains(
                                                    entry.id,
                                                  ),
                                                )
                                                .toList()
                                          : [f],
                                      child: row,
                                    );
                                  }
                                  return f.folder
                                      ? KeyedSubtree(
                                          key: _folderBounds.putIfAbsent(
                                            f.id,
                                            GlobalKey.new,
                                          ),
                                          child: dropTarget(
                                            folder: f,
                                            child: row,
                                          ),
                                        )
                                      : row;
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 25,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Text(
                  '${visible.length} 项${selected.isNotEmpty ? ' · 已选 ${selected.length}' : ''}',
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).hintColor,
                  ),
                ),
                const Spacer(),
                if (m.isMock) const DeskBadge('模拟数据'),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SftpTerminalActions extends StatelessWidget {
  const SftpTerminalActions({
    super.key,
    required this.model,
    required this.source,
  });
  final WorkbenchModel model;
  final TerminalSession source;
  void _run(Future<void> action) =>
      unawaited(action.catchError(model.reportOperation));
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 32,
    child: Row(
      children: [
        const Spacer(),
        Tool(Icons.drive_file_move_outlined, '发送当前目录路径到关联终端', () {
          if (model is LiveWorkbenchModel && source is LiveTerminalSession) {
            final live = source as LiveTerminalSession;
            _run(
              sendSessionPaths(context, model as LiveWorkbenchModel, live, [
                source.path,
              ], expectedGeneration: live.controller.generation),
            );
          } else {
            source.draft += quotePath(source.path);
            model.changed();
            notice(context, '仅模拟插入路径；未执行');
          }
        }),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: model.followsTerminalDirectory(source)
                ? Theme.of(context).colorScheme.primary.withValues(alpha: .15)
                : null,
          ),
          child: Tool(
            Icons.sync_alt,
            '自动跟随终端路径',
            () => _run(
              model.setTerminalDirectoryFollow(
                source,
                !model.followsTerminalDirectory(source),
              ),
            ),
          ),
        ),
        Tool(
          Icons.my_location_outlined,
          '跳转至终端路径',
          () => _run(model.jumpToTerminalDirectory(source)),
        ),
      ],
    ),
  );
}
