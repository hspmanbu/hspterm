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
import '../workbench/file_kinds.dart';
import '../run_log.dart';
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
            if (!model.queueMaximized)
              ColoredBox(
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: .15),
                child: ResizeGrip(
                  key: const ValueKey('queue-grip'),
                  horizontal: false,
                  onDelta: (d) {
                    model.queueHeight = (model.queueHeight - d).clamp(
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

int _compareText(String a, String b) {
  final x = a.toLowerCase().compareTo(b.toLowerCase());
  return x != 0 ? x : a.compareTo(b);
}

class _FilesPanelState extends State<FilesPanel> {
  final _fileMenu = MenuController();
  final _fileMenuAnchor = GlobalKey();
  DemoFile? _menuFile;
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

  /// Ctrl+wheel list font scale, session-only like the terminal zoom.
  static const _fontScaleMin = 0.8, _fontScaleMax = 1.6;
  double _fontScale = 1.0;
  double get _rowHeight => (compact ? 28 : 33) * _fontScale;
  double get _nameSize => 11 * _fontScale;
  double get _metaSize => 10 * _fontScale;
  late String _shownPath;
  late int _shownGeneration;
  bool hidden = false, compact = false, filtering = false, foldersFirst = true;
  Object? _defaultsRevision;
  int sortColumn = 0;
  bool ascending = true;
  List<DemoFile>? _visible;
  // Stable column identifiers (persisted per host); the canonical order
  // below doubles as the sort-column index mapping.
  static const _columnIds = [
    'name',
    'modified',
    'size',
    'kind',
    'permissions',
    'owner',
  ];
  static const _columnLabels = {
    'name': '名称',
    'modified': '修改时间',
    'size': '大小',
    'kind': '类型',
    'permissions': '权限',
    'owner': '所有者',
  };
  static const _columnDefaultWidths = {
    'name': 210.0,
    'modified': 155.0,
    'size': 90.0,
    'kind': 105.0,
    'permissions': 108.0,
    'owner': 96.0,
  };
  List<String> _columnOrder = List.of(_columnIds);
  Set<String> _hiddenColumns = {};
  final widths = <String, double>{..._columnDefaultWidths};
  Iterable<String> get _columns =>
      _columnOrder.where((id) => !_hiddenColumns.contains(id));
  int _sortIndexOf(String id) => _columnIds.indexOf(id);
  Timer? _columnSave;

  /// Coalesces column writes: width drags fire continuously, the persisted
  /// layout must not write the vault per pixel.
  void _rememberColumns() {
    _columnSave?.cancel();
    _columnSave = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      m.rememberColumns(
        p.host.id,
        SftpColumnLayout(
          order: List.of(_columnOrder),
          hidden: Set.of(_hiddenColumns),
          widths: Map.of(widths),
        ),
      );
    });
  }

  Future<void> configureColumns() async {
    final order = List<String>.of(_columnOrder),
        hidden = Set<String>.of(_hiddenColumns);
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
                for (final id in order)
                  CheckboxListTile(
                    key: ValueKey('configure-file-column-$id'),
                    title: Text(_columnLabels[id] ?? id),
                    subtitle: id == 'name'
                        ? const Text('名称列保持可见，支持移动位置')
                        : null,
                    value: !hidden.contains(id),
                    onChanged: id == 'name'
                        ? null
                        : (value) => update(() {
                            if (value == true) {
                              hidden.remove(id);
                            } else {
                              hidden.add(id);
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
      _rememberColumns();
    }
  }

  Timer? _hoverTimer;
  final _folderBounds = <String, GlobalKey>{};
  final _folderObjects = <String, DemoFile>{};
  bool _explorerOver = false;

  /// True while an Explorer drag hovers the right-edge hot strip: dropping
  /// there targets the current directory instead of the row under it.
  bool _explorerHotZone = false;
  static const _explorerHotZoneWidth = 72.0;
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

  void _trimFolderRegistries() {
    _folderBounds.removeWhere((_, key) => key.currentContext == null);
    _folderObjects.removeWhere((id, _) => !_folderBounds.containsKey(id));
  }

  void _applyBrowserDefaults() {
    final revision = m.fileDefaultsRevision;
    if (_defaultsRevision == revision) return;
    _defaultsRevision = revision;
    foldersFirst = m.fileFoldersFirst;
    hidden = m.fileShowHidden;
    compact = m.fileCompact;
    final remembered = m.rememberedSort(p.host.id);
    if (remembered case final pref?) {
      sortColumn = pref.$1;
      ascending = pref.$2;
    }
    final layout = m.rememberedColumns(p.host.id);
    if (layout != null) {
      // Only stable ids this build understands survive; anything else keeps
      // the default layout instead of corrupting order or widths.
      final known = layout.order
          .where(_columnDefaultWidths.containsKey)
          .toList();
      for (final id in _columnIds) {
        if (!known.contains(id)) known.add(id);
      }
      _columnOrder = known;
      _hiddenColumns = layout.hidden
          .where((id) => id != 'name' && _columnDefaultWidths.containsKey(id))
          .toSet();
      for (final entry in layout.widths.entries) {
        final width = entry.value;
        if (_columnDefaultWidths.containsKey(entry.key) &&
            width.isFinite &&
            width >= 60 &&
            width <= 500) {
          widths[entry.key] = width;
        }
      }
    }
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
    _columnSave?.cancel();
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
        // Case-insensitive compare with the raw spelling as a stable
        // tie-breaker: mixed-case listings must not bucket uppercase first.
        3 => _compareText(a.kind, b.kind),
        4 => (a.permissions ?? -1).compareTo(b.permissions ?? -1),
        5 => _compareText(a.owner ?? '', b.owner ?? ''),
        _ => _compareText(a.name, b.name),
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

  /// Icon for a non-folder entry from its kind label (see _kindOf for the
  /// classification source).
  /// Desk-themed panel style shared by the file menu and its cascades.
  MenuStyle _panelMenuStyle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll(scheme.surface),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(8),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(264, 0)),
      maximumSize: const WidgetStatePropertyAll(Size(560, 560)),
    );
  }

  /// Compact desktop-menu item: 34px rows, subtle hover, dimmed disabled.
  ButtonStyle _menuItemStyle(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? scheme.onSurfaceVariant.withValues(alpha: 0.45)
            : scheme.onSurface,
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered)
            ? scheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
      ),
      overlayColor: WidgetStatePropertyAll(
        scheme.primary.withValues(alpha: 0.08),
      ),
      textStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 13, color: scheme.onSurface),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12),
      ),
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(34)),
      maximumSize: const WidgetStatePropertyAll(
        Size.fromWidth(double.infinity),
      ),
    );
  }

  IconData _kindIcon(String kind) => switch (kind) {
    'JSON' || 'YAML' => Icons.data_object,
    'Markdown' => Icons.article_outlined,
    '日志' || '文本' => Icons.description_outlined,
    'Python' => Icons.code,
    'Shell' => Icons.terminal,
    '图片' => Icons.image_outlined,
    '视频' => Icons.movie_outlined,
    '音频' => Icons.audio_file_outlined,
    'PDF' => Icons.picture_as_pdf_outlined,
    '压缩包' => Icons.folder_zip_outlined,
    '可执行' || '动态库' => Icons.settings_applications_outlined,
    _ => Icons.description_outlined,
  };

  /// Static-file icon shared by the name cell so the edit swap keeps the
  /// glyph position identical (folder/kind precedence follows metadata).
  Widget _fileIcon(BuildContext context, DemoFile f) => Icon(
    f.folder ? Icons.folder_outlined : _kindIcon(f.kind),
    size: 16,
    color: f.folder ? Desk.warning : Theme.of(context).hintColor,
  );

  /// Non-editing name cell: gutter, icon, ellipsized name.
  Widget _nameCell(BuildContext context, DemoFile f, double width) => SizedBox(
    width: width,
    child: Row(
      children: [
        const SizedBox(width: 10),
        _fileIcon(context, f),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            f.name,
            style: TextStyle(fontSize: _nameSize),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 7),
      ],
    ),
  );

  /// Editing name cell: the bordered editor starts exactly where the name
  /// text began (after the icon gutter) and fills the rest of the name
  /// column, so no other column moves and the horizontal scroll offset is
  /// untouched. The border is never clipped by the viewport because it
  /// lives inside the scrolled cell; overflowing text scrolls inside the
  /// field itself, like Windows Explorer.
  Widget _nameEditorCell(BuildContext context, DemoFile f, double width) =>
      SizedBox(
        key: ValueKey('name-editor-cell-${f.id}'),
        width: width,
        child: Row(
          children: [
            const SizedBox(width: 10),
            _fileIcon(context, f),
            const SizedBox(width: 8),
            Expanded(
              child: Focus(
                onKeyEvent: (_, e) {
                  if (e is KeyDownEvent &&
                      e.logicalKey == LogicalKeyboardKey.escape) {
                    setState(() {
                      editing = null;
                      renameError = null;
                    });
                    _focus.requestFocus();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Clicking anywhere inside the box keeps editing.
                  onTap: () => _renameFocus.requestFocus(),
                  child: DecoratedBox(
                    key: const ValueKey('inline-rename'),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    // A true SINGLE-LINE field (round-11): maxLines/minLines
                    // pinned to 1 — with expands the null maxLines wrapped
                    // long names to a second line that overflowed the
                    // border and pushed the visible line off-center. The
                    // field now sizes itself to one line and Center aligns
                    // it on the row midline; long input scrolls inside the
                    // field (RenderEditable keeps the caret visible) instead
                    // of wrapping. A translucent selection color replaces
                    // the opaque default that read as a stray dark
                    // rectangle behind the name.
                    child: DefaultSelectionStyle(
                      selectionColor: Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0.35),
                      cursorColor: Theme.of(context).colorScheme.primary,
                      child: Center(
                        child: TextField(
                          key: const ValueKey('inline-rename-field'),
                          controller: _rename,
                          focusNode: _renameFocus,
                          autofocus: true,
                          maxLines: 1,
                          minLines: 1,
                          // No forced line height: the CJK fallback metrics
                          // on Windows differ from the test fonts; natural
                          // metrics keep the glyphs optically centered
                          // across DPI and font fallbacks.
                          style: TextStyle(fontSize: _nameSize),
                          decoration: const InputDecoration(
                            isDense: true,
                            isCollapsed: true,
                            contentPadding: EdgeInsets.symmetric(horizontal: 8),
                            border: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            filled: false,
                          ),
                          onEditingComplete: () {},
                          onSubmitted: (_) => commitRename(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 7),
          ],
        ),
      );

  /// Metadata cell shared by both row states, dispatched by stable id.
  Widget _metaCell(BuildContext context, DemoFile f, String id, double width) {
    final text = switch (id) {
      'modified' => f.modified,
      'size' => f.folder ? '—' : f.size,
      'kind' => f.kind,
      'permissions' => permissionString(
        f.permissions,
        folder: f.folder,
        symlink: f.symlink,
      ),
      'owner' => f.owner ?? '—',
      _ => '',
    };
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Text(
          text,
          style: TextStyle(
            fontSize: _metaSize,
            color: Theme.of(context).hintColor,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// Header cell: click sorts by the column's canonical index; dragging the
  /// label reorders columns (the resize grip stays a separate target).
  Widget _headerCell(BuildContext context, String id) {
    final index = _sortIndexOf(id);
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => details.data != id,
      onAcceptWithDetails: (details) {
        setState(() {
          final from = _columnOrder.indexOf(details.data);
          final to = _columnOrder.indexOf(id);
          if (from >= 0 && to >= 0) {
            _columnOrder.removeAt(from);
            _columnOrder.insert(to, details.data);
          }
        });
        _rememberColumns();
      },
      builder: (context, candidate, _) => Draggable<String>(
        data: id,
        feedback: Text(
          _columnLabels[id] ?? id,
          style: TextStyle(
            fontSize: _metaSize,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        child: InkWell(
          onTap: () {
            setState(() {
              ascending = sortColumn == index ? !ascending : true;
              sortColumn = index;
              _newEntryTail = null;
            });
            if (!m.isMock) m.rememberSort(p.host.id, index, ascending);
          },
          child: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Text(
              '${_columnLabels[id] ?? id}${sortColumn == index ? (ascending ? '  ↑' : '  ↓') : ''}',
              style: TextStyle(
                fontSize: _metaSize,
                color: Theme.of(context).hintColor,
              ),
            ),
          ),
        ),
      ),
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

  void _openFileMenuAt(Offset globalPosition, DemoFile file) {
    _menuFile = file;
    final box = _fileMenuAnchor.currentContext?.findRenderObject();
    if (box is RenderBox && mounted) {
      _fileMenu.open(position: box.globalToLocal(globalPosition));
    }
  }

  List<Widget> _buildFileMenuChildren() => [
    // Compact icon toolbar (the pre-round-7 layout): copy/cut/paste/rename/
    // delete as one horizontal row, restored on top of the MenuAnchor menu.
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tool(Icons.copy, '复制', () => _dispatchFileAction('copy')),
          Tool(Icons.content_cut, '剪切', () => _dispatchFileAction('cut')),
          Tool(Icons.content_paste, '粘贴', () => _dispatchFileAction('paste')),
          Tool(
            Icons.drive_file_rename_outline,
            '重命名',
            () => _dispatchFileAction('rename'),
          ),
          Tool(Icons.delete_outline, '删除', () => _dispatchFileAction('delete')),
        ],
      ),
    ),
    const Divider(height: 8),
    MenuItemButton(
      style: _menuItemStyle(context),
      onPressed: () => _dispatchFileAction('open'),
      child: const Text('打开'),
    ),
    MenuItemButton(
      style: _menuItemStyle(context),
      onPressed: () => _dispatchFileAction('download'),
      child: const Text('下载'),
    ),
    if (widget.onEditFile != null)
      MenuItemButton(
        style: _menuItemStyle(context),
        onPressed: () => _dispatchFileAction('edit'),
        child: const Text('编辑'),
      ),
    if (widget.onEditFileWithEncoding != null)
      MenuItemButton(
        style: _menuItemStyle(context),
        onPressed: () => _dispatchFileAction('edit-encoding'),
        child: const Text('按指定编码编辑…'),
      ),
    if (widget.onEditRawFile != null)
      MenuItemButton(
        style: _menuItemStyle(context),
        onPressed: () => _dispatchFileAction('edit-raw'),
        child: const Text('外部编辑大文件…'),
      ),
    for (final move in [false, true])
      SubmenuButton(
        style: _menuItemStyle(context),
        menuChildren: [
          for (final target in _remoteCopyTargets())
            MenuItemButton(
              onPressed: () => _dispatchFileAction(
                '${move ? 'move' : 'copy'}-target:${target.$4}',
              ),
              child: Text('${target.$1.host.name} · ${target.$3}'),
            ),
          if (_remoteCopyTargets().isEmpty)
            MenuItemButton(
              style: _menuItemStyle(context),
              onPressed: null,
              child: const Text('没有其他已连接主机'),
            ),
        ],
        child: Text(move ? '移动到' : '复制到'),
      ),
    MenuItemButton(
      style: _menuItemStyle(context),
      onPressed: () => _dispatchFileAction('name'),
      child: const Text('复制文件/文件夹名'),
    ),
    MenuItemButton(
      style: _menuItemStyle(context),
      onPressed: () => _dispatchFileAction('path'),
      child: const Text('复制路径'),
    ),
    MenuItemButton(
      style: _menuItemStyle(context),
      onPressed: () => _dispatchFileAction('send-name'),
      child: const Text('发送文件/文件夹名至终端'),
    ),
    MenuItemButton(
      style: _menuItemStyle(context),
      onPressed: () => _dispatchFileAction('send'),
      child: const Text('发送路径至终端'),
    ),
    MenuItemButton(
      style: _menuItemStyle(context),
      onPressed: () => _dispatchFileAction('properties'),
      child: const Text('属性'),
    ),
  ];

  /// (session, generation, path, index) of other connected sessions.
  List<(TerminalSession, int, String, int)> _remoteCopyTargets() {
    final origin = p;
    final result = <(TerminalSession, int, String, int)>[];
    for (final item in m.sessions) {
      if (identical(item, origin) ||
          item.disconnected ||
          (item is LiveTerminalSession && !item.controller.connected)) {
        continue;
      }
      result.add((item, item.connectionGeneration, item.path, result.length));
    }
    return result;
  }

  Future<void> _dispatchFileAction(String action) async {
    _fileMenu.close();
    // Re-validate freshness at dispatch time, exactly like the old
    // post-showMenu guard.
    await menuDispatch(action, file: _menuFile);
  }

  /// Opens the shared MenuAnchor file menu at [position] for [file]; the
  /// cascade (复制到/移动到) uses the framework's own menu machinery, so the
  /// parent stays open, the child flips by screen space, and hover works.
  Future<void> _openFileMenu(Offset position, DemoFile file) async {
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
    _openFileMenuAt(position, file);
  }

  /// Executes one menu action against the live state; every entry re-validates
  /// freshness exactly like the old post-showMenu guard did.
  Future<void> menuDispatch(String action, {DemoFile? file}) async {
    final request = _menuRequest;
    final origin = p;
    final generation = origin.connectionGeneration;
    final directory = origin.path;
    final frozenSelection = Set<String>.of(selected);
    final files = origin.files
        .where((f) => frozenSelection.contains(f.id))
        .toList(growable: false);
    final paths = List<String>.unmodifiable(
      files.map((f) => pathOf(directory, f.name)),
    );
    file ??= files.isNotEmpty ? files.first : null;
    final targets = [
      for (final target in _remoteCopyTargets())
        (target.$1, target.$2, target.$3),
    ];
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
    final row = file;
    switch (action) {
      case 'open':
        if (row != null) open(row);
      case 'edit':
        final editor = widget.onEditFile;
        if (editor != null) run(editor(context, p, row!));
      case 'edit-encoding':
        final editor = widget.onEditFileWithEncoding;
        if (editor != null) run(editor(context, p, row!));
      case 'edit-raw':
        final editor = widget.onEditRawFile;
        if (editor != null) run(editor(context, p, row!));
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
        if (row != null &&
            m is LiveWorkbenchModel &&
            origin is LiveTerminalSession) {
          await showFileProperties(
            context,
            m as LiveWorkbenchModel,
            origin,
            row,
          );
        } else if (row != null) {
          await showDialog<void>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('模拟文件属性'),
              content: Text(
                '${row.name}\n${p.path}\n${row.kind} · ${row.folder ? '未计算' : row.size}',
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

  /// The right-edge strip of the file list always targets the current
  /// directory; only pointers left of it can drop into a hovered folder.
  bool _inHotZone(Offset point) {
    final box = context.findRenderObject();
    return box is RenderBox &&
        box.hasSize &&
        point.dx >=
            box.localToGlobal(Offset.zero).dx +
                box.size.width -
                _explorerHotZoneWidth;
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
    final hot = point != null && _inHotZone(point);
    final folder = point == null || hot ? null : _explorerFolder(point);
    if (_explorerOver == (point != null) &&
        _explorerHotZone == hot &&
        hoverTarget == folder?.id) {
      return;
    }
    _hoverTimer?.cancel();
    setState(() {
      _explorerOver = point != null;
      _explorerHotZone = hot;
      hoverTarget = folder?.id;
    });
    if (folder == null) return;
    // Hovering during an Explorer upload never opens the folder: drops are
    // explicit, and an accidental navigate would retarget the upload.
  }

  Future<void> _explorerDrop(List<String> paths, Offset point) async {
    final model = m, source = p, generation = p.connectionGeneration;
    AppRunLog.instance.event(
      AppLogEvent.explorerDropAccepted,
      terminal: source is LiveTerminalSession ? source.controller.id : null,
      generation: generation,
      count: paths.length,
    );
    final hot = _inHotZone(point);
    final directory = p.path, folder = hot ? null : _explorerFolder(point);
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
          // No hover-navigation during drags: dropping onto a folder is the
          // only way to target it.
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
    _trimFolderRegistries();
    // Publish the visible content width so the sidebar grip can cap the
    // panel at its real columns instead of a hardcoded 660px.
    m.sftpContentBound =
        _columns.fold<double>(0, (sum, i) => sum + (widths[i] ?? 90)) + 24;
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
    return Listener(
      // Ctrl+wheel adjusts the SFTP list font scale for this session, like
      // the terminal zoom. Plain wheel scrolling stays with the list.
      onPointerSignal: (event) {
        if (event is PointerScrollEvent &&
            event.scrollDelta.dy != 0 &&
            HardwareKeyboard.instance.isControlPressed) {
          setState(
            () => _fontScale =
                (_fontScale + (event.scrollDelta.dy < 0 ? .1 : -.1)).clamp(
                  _fontScaleMin,
                  _fontScaleMax,
                ),
          );
        }
      },
      child: Focus(
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
                                              padding:
                                                  const EdgeInsets.symmetric(
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
                    run(
                      m.loadDirectory(
                        p,
                        p.path,
                        remember: false,
                        refresh: true,
                      ),
                    );
                  }),
                  Builder(
                    builder: (c) => Tool(
                      Icons.bookmark_border,
                      '书签',
                      () => run(
                        showDirectoryBookmarkPopup(c, m, p, global: false),
                      ),
                    ),
                  ),
                  Builder(
                    builder: (c) => Tool(
                      Icons.public,
                      '全局书签',
                      () => run(
                        showDirectoryBookmarkPopup(c, m, p, global: true),
                      ),
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
                  Tool(
                    Icons.file_upload_outlined,
                    m.isMock ? '模拟上传' : '上传',
                    () {
                      if (m.isMock) {
                        m.addTransfer('example-upload.zip', upload: true);
                      } else {
                        run(upload());
                      }
                    },
                  ),
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
                onSecondaryTapUp: (event) {
                  final box = _fileMenuAnchor.currentContext
                      ?.findRenderObject();
                  if (box is RenderBox) {
                    _fileMenu.open(
                      position: box.globalToLocal(event.globalPosition),
                    );
                  }
                },
                child: Stack(
                  children: [
                    // Zero-size anchor marker at the stack origin: the
                    // MenuAnchor's TapRegion covers only this point, so a
                    // click ANYWHERE else (list rows, blank areas, other
                    // panes) counts as outside and closes the menu, while
                    // the click itself proceeds to its normal target.
                    // open(position:) still converts via this box.
                    Positioned(
                      left: 0,
                      top: 0,
                      child: MenuAnchor(
                        key: _fileMenuAnchor,
                        controller: _fileMenu,
                        style: _panelMenuStyle(context),
                        menuChildren: _buildFileMenuChildren(),
                        // Outside taps close the menu and are consumed,
                        // exactly like the Windows shell: the dismissing
                        // click never selects, opens or starts a drag.
                        consumeOutsideTap: true,
                        child: const SizedBox(width: 0, height: 0),
                      ),
                    ),
                    Positioned.fill(
                      child: dropTarget(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // The vertical scrollbar wraps the viewport so its thumb
                            // stays pinned to the visible right edge; the horizontal
                            // bar is a separate row below and never crosses it.
                            Expanded(
                              child: RawScrollbar(
                                controller: _vertical,
                                thumbVisibility: true,
                                scrollbarOrientation:
                                    ScrollbarOrientation.right,
                                // Notifications from the vertical list reach
                                // this scrollbar with depth 1 after bubbling
                                // through the horizontal scroller; the axis
                                // filter accepts them (the default depth==0
                                // predicate rejected every one, so the thumb
                                // never painted — pixel-verified).
                                notificationPredicate: (n) =>
                                    n.metrics.axis == Axis.vertical,
                                // Keep the bottom 14px clear of the horizontal
                                // thumb so the tracks never cross.
                                padding: const EdgeInsets.only(bottom: 14),
                                child: RawScrollbar(
                                  controller: _horizontal,
                                  thumbVisibility: true,
                                  scrollbarOrientation:
                                      ScrollbarOrientation.bottom,
                                  notificationPredicate: (n) =>
                                      n.metrics.axis == Axis.horizontal,
                                  child: ScrollConfiguration(
                                    // Desktop platforms wrap scrollables in
                                    // their own automatic Scrollbar; that
                                    // produced the second vertical bar glued
                                    // to the content. Only the explicit
                                    // RawScrollbars below may draw.
                                    behavior: ScrollConfiguration.of(context)
                                        .copyWith(scrollbars: false),
                                    child: SingleChildScrollView(
                                      controller: _horizontal,
                                      scrollDirection: Axis.horizontal,
                                      child: SizedBox(
                                        width: _columns.fold<double>(
                                          0,
                                          (sum, i) => sum + (widths[i] ?? 90),
                                        ),
                                        child: Column(
                                          children: [
                                            SizedBox(
                                              height: (27 * _fontScale)
                                                  .roundToDouble(),
                                              child: Row(
                                                children: [
                                                  for (final id in _columns)
                                                    SizedBox(
                                                      width:
                                                          widths[id] ??
                                                          _columnDefaultWidths[id]!,
                                                      child: Row(
                                                        children: [
                                                          Expanded(
                                                            child: _headerCell(
                                                              context,
                                                              id,
                                                            ),
                                                          ),
                                                          ResizeGrip(
                                                            key: ValueKey(
                                                              'file-column-$id',
                                                            ),
                                                            horizontal: true,
                                                            onDelta: (d) => setState(
                                                              () => widths[id] =
                                                                  ((widths[id] ?? _columnDefaultWidths[id]!).clamp(
                                                                            70,
                                                                            500,
                                                                          ) +
                                                                          d)
                                                                      .clamp(
                                                                        70,
                                                                        500,
                                                                      ),
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
                                              color: Theme.of(context)
                                                  .dividerColor,
                                            ),
                                            Expanded(
                                              child: ScrollConfiguration(
                                                behavior:
                                                    ScrollConfiguration.of(
                                                      context,
                                                    ).copyWith(
                                                      scrollbars: false,
                                                    ),
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
                                                          final slash = p.path
                                                              .lastIndexOf('/');
                                                          navigate(
                                                            slash <= 0
                                                                ? '/'
                                                                : p.path
                                                                      .substring(
                                                                        0,
                                                                        slash,
                                                                      ),
                                                          );
                                                        },
                                                        child: SizedBox(
                                                          height: _rowHeight,
                                                          child: const Row(
                                                            children: [
                                                              SizedBox(
                                                                width: 10,
                                                              ),
                                                              Icon(
                                                                Icons
                                                                    .drive_folder_upload_outlined,
                                                                size: 16,
                                                              ),
                                                              SizedBox(
                                                                width: 8,
                                                              ),
                                                              Text('..'),
                                                            ],
                                                          ),
                                                        ),
                                                      );
                                                    }
                                                    final f =
                                                        visible[index - 1];
                                                    if (f.folder) {
                                                      _folderObjects[f.id] = f;
                                                    }
                                                    Widget
                                                    row = SelectionTarget(
                                                      behavior: HitTestBehavior
                                                          .opaque,
                                                      // Taps land on the inline
                                                      // rename editor itself while
                                                      // it is open; taking list focus
                                                      // there would cancel editing.
                                                      onTapDown: (_) {
                                                        if (editing != f.id) {
                                                          select(f);
                                                        }
                                                      },
                                                      onDoubleTap: () =>
                                                          open(f),
                                                      // Complete the pointer sequence before pushing
                                                      // a modal menu/editor that can steal input.
                                                      onSecondaryTapUp: (d) =>
                                                          _openFileMenu(
                                                            d.globalPosition,
                                                            f,
                                                          ),
                                                      child: Container(
                                                        key: ValueKey(
                                                          'file-${f.name}',
                                                        ),
                                                        // The editor row
                                                        // never grows: an
                                                        // invalid name shows
                                                        // below the row.
                                                        height: _rowHeight,
                                                        color:
                                                            selected.contains(
                                                              f.id,
                                                            )
                                                            ? Theme.of(c)
                                                                  .colorScheme
                                                                  .primary
                                                                  .withValues(
                                                                    alpha: .12,
                                                                  )
                                                            : null,
                                                        // Editing keeps the row's column
                                                        // layout: only the name cell swaps
                                                        // to the editor so widths and the
                                                        // horizontal scroll stay put.
                                                        child: editing == f.id
                                                            ? Row(
                                                                children: [
                                                                  _nameEditorCell(
                                                                    c,
                                                                    f,
                                                                    widths['name'] ??
                                                                        _columnDefaultWidths['name']!,
                                                                  ),
                                                                  for (final id
                                                                      in _columns)
                                                                    if (id !=
                                                                        'name')
                                                                      _metaCell(
                                                                        c,
                                                                        f,
                                                                        id,
                                                                        widths[id] ??
                                                                            _columnDefaultWidths[id]!,
                                                                      ),
                                                                ],
                                                              )
                                                            : Row(
                                                                children: [
                                                                  for (final id
                                                                      in _columns)
                                                                    if (id ==
                                                                        'name')
                                                                      _nameCell(
                                                                        c,
                                                                        f,
                                                                        widths[id] ??
                                                                            _columnDefaultWidths[id]!,
                                                                      )
                                                                    else
                                                                      _metaCell(
                                                                        c,
                                                                        f,
                                                                        id,
                                                                        widths[id] ??
                                                                            _columnDefaultWidths[id]!,
                                                                      ),
                                                                ],
                                                              ),
                                                      ),
                                                    );
                                                    row = Draggable<RemoteDrag>(
                                                      // Secondary clicks belong to the file menu;
                                                      // never enter a drag arena for that button.
                                                      allowedButtonsFilter: (buttons) =>
                                                          buttons ==
                                                              kPrimaryMouseButton &&
                                                          !explorerExportGesture,
                                                      data: RemoteDrag(
                                                        p.id,
                                                        p.path,
                                                        selected.contains(f.id)
                                                            ? visible
                                                                  .where(
                                                                    (
                                                                      f,
                                                                    ) => selected
                                                                        .contains(
                                                                          f.id,
                                                                        ),
                                                                  )
                                                                  .toList()
                                                            : [f],
                                                        generation: p
                                                            .connectionGeneration,
                                                      ),
                                                      feedback:
                                                          const SizedBox.shrink(),
                                                      child: row,
                                                    );
                                                    final live = m;
                                                    if (live
                                                            is LiveWorkbenchModel &&
                                                        p is LiveTerminalSession) {
                                                      row = ExplorerExportDrag(
                                                        model: live,
                                                        source:
                                                            p as LiveTerminalSession,
                                                        selection: () =>
                                                            selected.contains(
                                                              f.id,
                                                            )
                                                            ? visible
                                                                  .where(
                                                                    (
                                                                      entry,
                                                                    ) => selected
                                                                        .contains(
                                                                          entry
                                                                              .id,
                                                                        ),
                                                                  )
                                                                  .toList()
                                                            : [f],
                                                        child: row,
                                                      );
                                                    }
                                                    Widget item = f.folder
                                                        ? KeyedSubtree(
                                                            key: _folderBounds
                                                                .putIfAbsent(
                                                                  f.id,
                                                                  GlobalKey.new,
                                                                ),
                                                            child: dropTarget(
                                                              folder: f,
                                                              child: row,
                                                            ),
                                                          )
                                                        : row;
                                                    // Validation errors render
                                                    // below the row so the
                                                    // editor box height is
                                                    // independent of the
                                                    // error text.
                                                    if (editing == f.id &&
                                                        renameError != null) {
                                                      item = Column(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .stretch,
                                                        children: [
                                                          item,
                                                          Padding(
                                                            padding:
                                                                const EdgeInsets.only(
                                                                  left: 34,
                                                                  top: 2,
                                                                ),
                                                            child: Text(
                                                              key:
                                                                  const ValueKey(
                                                                    'inline-rename-error',
                                                                  ),
                                                              renameError!,
                                                              style: TextStyle(
                                                                fontSize: 11,
                                                                color: Theme.of(c)
                                                                    .colorScheme
                                                                    .error,
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      );
                                                    }
                                                    return item;
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
                          ],
                        ),
                      ),
                    ),
                    if (_explorerOver)
                      IgnorePointer(
                        child: Stack(
                          children: [
                            if (_explorerHotZone)
                              Positioned(
                                top: 0,
                                right: 0,
                                bottom: 0,
                                width: _explorerHotZoneWidth,
                                child: ColoredBox(
                                  color: Theme.of(context).colorScheme.primary
                                      .withValues(alpha: .16),
                                ),
                              ),
                            Positioned(
                              top: 8,
                              left: 0,
                              right: 0,
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: .9),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    _explorerHotZone
                                        ? '松开上传到当前目录（右侧热区）'
                                        : hoverTarget != null
                                        ? '松开上传到文件夹「${_folderObjects[hoverTarget]?.name ?? ''}」'
                                        : '松开上传到当前目录',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(
              // One merged status row: item count left, terminal link actions
              // right; no separate strip below the list.
              height: 30,
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
                  _terminalLinkActions(context, m),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The three terminal-link tools, shared by the SFTP bottom status row.
Widget _terminalLinkActions(BuildContext context, WorkbenchModel m) {
  final source = m.focus;
  if (source == null) return const SizedBox.shrink();
  void runAction(Future<void> action) =>
      unawaited(action.catchError(m.reportOperation));
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Tool(Icons.drive_file_move_outlined, '发送当前目录路径到关联终端', () {
        if (m is LiveWorkbenchModel && source is LiveTerminalSession) {
          final live = source;
          runAction(
            sendSessionPaths(context, m, live, [
              source.path,
            ], expectedGeneration: live.controller.generation),
          );
        } else {
          source.draft += quotePath(source.path);
          m.changed();
          notice(context, '仅模拟插入路径；未执行');
        }
      }),
      DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color: m.followsTerminalDirectory(source)
              ? Theme.of(context).colorScheme.primary.withValues(alpha: .15)
              : null,
        ),
        child: Tool(
          Icons.sync_alt,
          '自动跟随终端路径',
          () => runAction(
            m.setTerminalDirectoryFollow(
              source,
              !m.followsTerminalDirectory(source),
            ),
          ),
        ),
      ),
      Tool(
        Icons.my_location_outlined,
        '跳转至终端路径',
        () => runAction(m.jumpToTerminalDirectory(source)),
      ),
    ],
  );
}
