import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart' as native;

import '../prototype/model.dart';
import '../src/rust/api.dart' as rust;
import 'explorer_export_batch.dart';
import 'explorer_export_io.dart';
import 'model.dart';
export 'explorer_export_io.dart';

bool get explorerExportGesture =>
    Platform.isWindows &&
    HardwareKeyboard.instance.isAltPressed &&
    !HardwareKeyboard.instance.isControlPressed &&
    !HardwareKeyboard.instance.isMetaPressed;

/// Alt selects external copy; normal Flutter moves/path drags keep their semantics.
class ExplorerExportDrag extends StatefulWidget {
  const ExplorerExportDrag({
    super.key,
    required this.model,
    required this.source,
    required this.selection,
    required this.child,
  });
  final LiveWorkbenchModel model;
  final LiveTerminalSession source;
  final List<DemoFile> Function() selection;
  final Widget child;
  @override
  State<ExplorerExportDrag> createState() => _ExplorerExportDragState();
}

class _ExplorerExportDragState extends State<ExplorerExportDrag> {
  ExplorerExportBatch? batch;
  @override
  Widget build(BuildContext context) {
    final model = widget.model, source = widget.source;
    final selection = widget.selection, child = widget.child;
    if (!Platform.isWindows) return child;
    return native.DragItemWidget(
      allowedOperations: () => [native.DropOperation.copy],
      dragBuilder: (_, _) => const SizedBox(width: 1, height: 1),
      dragItemProvider: (request) async {
        ExplorerExportBatch? preparing;
        try {
          final files = List<DemoFile>.of(selection());
          final id = source.controller.id,
              generation = source.controller.generation;
          void checkSource() {
            if (model.isClosing ||
                !model.sessions.contains(source) ||
                !source.controller.connected ||
                id == null ||
                source.controller.id != id ||
                source.controller.generation != generation) {
              throw StateError('原SSH连接已改变，未继续创建拖出任务');
            }
          }

          checkSource();
          if (files.isEmpty || files.length > 128) {
            throw StateError('请选择1–128个文件或目录');
          }
          final names = <String>{};
          for (final file in files) {
            if (!source.files.contains(file) || file.symlink) {
              throw StateError('拖出不跟随符号链接，请重新选择');
            }
            validateExplorerExportName(file.name);
            if (!names.add(file.name.toUpperCase())) {
              throw StateError('所选名称在Windows中重复，请分别下载');
            }
          }
          final owner = ExplorerExportBatch(model, request.session);
          preparing = owner;
          batch = owner;
          return await model.runTransferSubmission(
            () => owner.preparing(() async {
              final base = await getApplicationSupportDirectory();
              for (final file in files) {
                owner.checkOpen();
                checkSource();
                final ticket = await rust.beginExplorerExport(
                  id: id!,
                  generation: generation,
                  cacheDirectory: base.path,
                  path: file.id,
                  name: file.name,
                );
                final inventory = owner.add(
                  ticket,
                  expectedDirectory: file.folder,
                );
                await Future.wait([inventory, model.refreshTransfers()]);
              }
              owner.ready();
              return owner.first;
            }),
          );
        } catch (error) {
          if (preparing != null) {
            try {
              await preparing.abortPreparation();
            } catch (_) {
              model.reportOperation(StateError('未完成拖出仍有源任务租约，请保留当前运行并重试退出'));
            }
          }
          if (error is! ExplorerExportCancelled) {
            model.reportOperation(StateError('无法准备Explorer拖出，请检查源任务及所选名称'));
          }
          return null;
        }
      },
      child: native.DraggableWidget(
        isLocationDraggable: (_) => explorerExportGesture,
        onDragConfiguration: (config, session) =>
            batch?.configuration(config, session),
        child: Tooltip(
          message: '按住Alt拖到Explorer下载文件或目录；普通拖动保留应用内操作',
          child: child,
        ),
      ),
    );
  }
}

/// Ready cached trees can be re-dragged without a new SSH connection/download.
class ExplorerReadySnapshotDrag extends StatefulWidget {
  const ExplorerReadySnapshotDrag({
    super.key,
    required this.model,
    required this.task,
    required this.child,
  });
  final LiveWorkbenchModel model;
  final String task;
  final Widget child;
  @override
  State<ExplorerReadySnapshotDrag> createState() =>
      _ExplorerReadySnapshotDragState();
}

class _ExplorerReadySnapshotDragState extends State<ExplorerReadySnapshotDrag> {
  ExplorerExportBatch? batch;
  @override
  Widget build(BuildContext context) {
    final model = widget.model, task = widget.task, child = widget.child;
    if (!Platform.isWindows) return child;
    return native.DragItemWidget(
      allowedOperations: () => [native.DropOperation.copy],
      dragBuilder: (_, _) => const SizedBox(width: 1, height: 1),
      dragItemProvider: (request) async {
        ExplorerExportBatch? owner;
        try {
          final current = ExplorerExportBatch(model, request.session);
          owner = current;
          batch = current;
          return await model.runTransferSubmission(
            () => current.preparing(() async {
              final ticket = await rust.attachExplorerExport(task: task);
              await current.add(ticket);
              current.ready();
              return current.first;
            }),
          );
        } catch (_) {
          if (owner != null) {
            try {
              await owner.abortPreparation();
            } catch (_) {
              model.reportOperation(StateError('原源快照租约释放未确认'));
            }
          }
          model.reportOperation(StateError('源快照暂不可拖出，请检查队列状态'));
          return null;
        }
      },
      child: native.DraggableWidget(
        isLocationDraggable: (_) =>
            !HardwareKeyboard.instance.isControlPressed &&
            !HardwareKeyboard.instance.isMetaPressed,
        onDragConfiguration: (config, session) =>
            batch?.configuration(config, session),
        child: Tooltip(
          message: '将就绪源快照拖到Explorer继续交付；不重新连接或重新下载',
          child: child,
        ),
      ),
    );
  }
}
