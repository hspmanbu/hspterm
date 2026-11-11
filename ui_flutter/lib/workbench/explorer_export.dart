import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart' as native;
import 'package:super_native_extensions/raw_drag_drop.dart' as raw;
import 'package:super_native_extensions/raw_clipboard.dart' as raw;
import 'package:super_clipboard/super_clipboard_internal.dart';

import '../prototype/model.dart';
import '../src/rust/api.dart' as rust;
import 'explorer_export_batch.dart';
import 'explorer_drag_handoff.dart';
import 'explorer_export_io.dart';
import 'model.dart';
export 'explorer_export_io.dart';

Future<raw.DragContext>? _dragContext;
Future<raw.DragContext> _nativeContext() => _dragContext ??=
    raw.DragContext.instance().catchError((Object error, StackTrace stack) {
      _dragContext = null;
      Error.throwWithStackTrace(error, stack);
    });

/// Flutter owns in-app file moves and terminal path drops. Crossing the client
/// edge hands the SAME pointer gesture to Windows, with an immutable source.
/// No Alt key and no temporary download are needed for an internal drag.
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

class _ExportGesture {
  _ExportGesture(this.lease, this.source, this.files)
    : nativeId = source.controller.id,
      generation = source.controller.generation;
  final ExplorerDragLease lease;
  final LiveTerminalSession source;
  final List<DemoFile> files;
  final int? nativeId;
  final int generation;
}

class _ExplorerExportDragState extends State<ExplorerExportDrag> {
  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      unawaited(_nativeContext().then<void>((_) {}, onError: (Object _) {}));
    }
  }

  Future<void> _export(_ExportGesture gesture, Offset at) async {
    final model = widget.model;
    ExplorerExportBatch? owner;
    raw.DragContext? context;
    raw.DragSession? session;
    final handles = <raw.DataProviderHandle>[];
    final images = <raw.TargetedWidgetSnapshot>[];
    bool started = false;
    void check() {
      final source = gesture.source;
      if (gesture.lease.released ||
          !mounted ||
          model.isClosing ||
          !model.sessions.contains(source) ||
          !source.controller.connected ||
          gesture.nativeId == null ||
          source.controller.id != gesture.nativeId ||
          source.controller.generation != gesture.generation) {
        throw ExplorerExportCancelled();
      }
      for (final file in gesture.files) {
        if (!source.files.any(
          (current) =>
              current.id == file.id &&
              current.name == file.name &&
              current.folder == file.folder &&
              !current.symlink,
        )) {
          throw StateError('拖出来源已改变，请重新选择');
        }
      }
    }

    try {
      check();
      final files = gesture.files;
      if (files.isEmpty || files.length > 128) {
        throw StateError('请选择1–128个文件或目录');
      }
      final names = <String>{};
      for (final file in files) {
        if (file.symlink) throw StateError('拖出不跟随符号链接');
        validateExplorerExportName(file.name);
        if (!names.add(file.name.toUpperCase())) {
          throw StateError('所选名称在Windows中重复');
        }
      }
      context = await _nativeContext();
      check();
      session = context.newSession();
      final batch = ExplorerExportBatch(model, session);
      owner = batch;
      await model.runTransferSubmission(
        () => batch.preparing(() async {
          final base = await getApplicationSupportDirectory();
          for (final file in files) {
            check();
            batch.checkOpen();
            final ticket = await rust.beginExplorerExport(
              id: gesture.nativeId!,
              generation: gesture.generation,
              cacheDirectory: base.path,
              path: file.id,
              name: file.name,
            );
            await batch.add(ticket, expectedDirectory: file.folder);
          }
          check();
          batch.ready();
        }),
      );
      check();
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 1, 1),
        Paint()..color = Colors.transparent,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(1, 1);
      picture.dispose();
      final snapshot = raw.WidgetSnapshot.image(image);
      final items = <raw.DragItem>[];
      try {
        for (final item in batch.claimItems(session)) {
          check();
          final provider = await item.asDataProvider();
          final handle = await item.registerWithDataProvider(provider);
          handles.add(handle);
          final targeted = raw.TargetedWidgetSnapshot(
            snapshot.retain(),
            at & const Size(1, 1),
          );
          images.add(targeted);
          items.add(
            raw.DragItem(
              dataProvider: handle,
              image: targeted,
              liftImage: null,
              localData: item.localData,
            ),
          );
        }
      } finally {
        snapshot.dispose();
      }
      check();
      final config = raw.DragConfiguration(
        items: items,
        allowedOperations: const [raw.DropOperation.copy],
      );
      if (!mounted) throw ExplorerExportCancelled();
      gesture.lease.handedOff = true;
      // Cancel only the Flutter avatar; the physical button remains held for
      // DoDragDrop. The batch survives source-widget disposal and DragEnd.
      GestureBinding.instance.cancelPointer(gesture.lease.pointer);
      await context.startDrag(
        buildContext: this.context,
        session: session,
        configuration: config,
        position: at,
      );
      started = true;
      void done() {
        session!.dragCompleted.removeListener(done);
        for (final image in images) {
          image.dispose();
        }
        images.clear();
      }

      session.dragCompleted.addListener(done);
      if (session.dragCompleted.value != null) done();
      unawaited(model.refreshTransfers());
    } catch (error) {
      if (error is! ExplorerExportCancelled) {
        model.reportOperation(StateError('无法准备Explorer拖出：$error'));
      }
    } finally {
      if (!started) {
        for (final image in images) {
          image.dispose();
        }
        for (final handle in handles) {
          await handle.dispose();
        }
        try {
          await owner?.abortPreparation();
        } catch (_) {
          model.reportOperation(StateError('拖出源租约释放未确认，请重试结束Explorer交付'));
        }
        if (context != null && session != null) context.cancelSession(session);
      }
    }
  }

  @override
  Widget build(BuildContext context) => ExplorerDragHandoff<_ExportGesture>(
    enabled: Platform.isWindows,
    capture: (lease) => _ExportGesture(
      lease,
      widget.source,
      widget
          .selection()
          .map(
            (f) => DemoFile(
              f.id,
              f.name,
              folder: f.folder,
              symlink: f.symlink,
              byteSize: f.byteSize,
            ),
          )
          .toList(growable: false),
    ),
    onLeave: _export,
    child: widget.child,
  );
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
