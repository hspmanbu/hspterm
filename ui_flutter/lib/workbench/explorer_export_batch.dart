import 'dart:async';
import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart' as clipboard;
import 'package:super_drag_and_drop/super_drag_and_drop.dart' as native;

import '../src/rust/api.dart' as rust;
import '../src/rust/transfers/explorer.dart' as exports;
import 'explorer_export_io.dart';
import 'model.dart';

class _Root {
  _Root(this.ticket, this.descriptors);
  final exports.ExportTicket ticket;
  final List<exports.ExportDescriptor> descriptors;
  final delivered = <int>{};
  final returningReads = <String>{};
  Future<void> returnRead(String read) async {
    await rust.releaseExplorerExportFile(
      task: ticket.task,
      lease: ticket.lease,
      read: read,
    );
    returningReads.remove(read);
  }

  bool sourceReady = false, cancelled = false;
  Future<void>? stopping;
  Future<void> cancel() {
    cancelled = true;
    return stopping ??= rust
        .cancelExplorerExport(task: ticket.task, lease: ticket.lease)
        .catchError((Object error, StackTrace stack) {
          stopping = null;
          Error.throwWithStackTrace(error, stack);
        });
  }
}

/// A batch outlives its source widget and focus. Registration/disposal and actual
/// provider work, rather than DragEnd alone, govern the source/cache lifetime.
class ExplorerExportBatch {
  ExplorerExportBatch(this.model, this.session) {
    model.registerExplorerExport(this, cancel: cancel, release: release);
    session.dragCompleted.addListener(_dragCompleted);
    if (session.dragCompleted.value != null) _dragCompleted();
  }
  final LiveWorkbenchModel model;
  final native.DragSession session;
  final _roots = <_Root>[];
  final _pendingTickets = <exports.ExportTicket>[];
  final _items = <native.DragItem>[];
  bool _ended = false, _copied = false, _closed = false, _ready = false;
  bool _configured = false, _retiring = false, _released = false;
  int _registered = 0, _disposed = 0, _workers = 0;
  Completer<void>? _idle;
  Future<void>? _releaseFuture;
  void _started() {
    if (_workers++ == 0) _idle = Completer<void>();
  }

  void _finished() {
    if (--_workers == 0) {
      _idle?.complete();
      _idle = null;
    }
    _maybeRelease();
  }

  int get count => _roots.fold(0, (n, root) => n + root.descriptors.length);
  Future<T> preparing<T>(Future<T> Function() action) async {
    if (_closed || _released || model.isClosing) {
      throw ExplorerExportCancelled();
    }
    _started();
    try {
      return await action();
    } finally {
      _finished();
    }
  }

  void checkOpen() {
    if (_closed || _released || model.isClosing) {
      throw ExplorerExportCancelled();
    }
  }

  Future<void> add(
    exports.ExportTicket ticket, {
    bool? expectedDirectory,
  }) async {
    _pendingTickets.add(
      ticket,
    ); // Retain even when inventory fails/caller exits.
    if (_closed || model.isClosing) {
      await rust.cancelExplorerExport(task: ticket.task, lease: ticket.lease);
      throw ExplorerExportCancelled();
    }
    final descriptors = await rust.explorerExportInventory(
      task: ticket.task,
      lease: ticket.lease,
    );
    if (_closed || model.isClosing) throw ExplorerExportCancelled();
    if (count + descriptors.length > 32768) {
      throw StateError('所选目录超过Explorer描述符总容量');
    }
    if (descriptors.isEmpty ||
        expectedDirectory != null &&
            descriptors.first.directory != expectedDirectory) {
      throw StateError('拖出源类型已改变，请刷新后重新选择');
    }
    _roots.add(_Root(ticket, descriptors));
  }

  void ready() {
    final seen = <String>{};
    if (count == 0 || count > 32768) throw StateError('Explorer描述符数量超过安全容量');
    for (final root in _roots) {
      for (final descriptor in root.descriptors) {
        if (descriptor.name.length > 259 ||
            descriptor.name.isEmpty ||
            descriptor.bytes < 0) {
          throw StateError('Explorer描述符名称或长度无效');
        }
        for (final component in descriptor.name.split('\\')) {
          validateExplorerExportName(component);
        }
        if (!seen.add(descriptor.name.toUpperCase())) {
          throw StateError('所选名称在Windows中重复');
        }
      }
    }
    _ready = true;
    for (final root in _roots) {
      for (final descriptor in root.descriptors) {
        _items.add(_item(root, descriptor));
      }
    }
  }

  native.DragItem get first => _items.first;
  List<native.DragItem> claimItems(native.DragSession owner) {
    if (_configured || !_ready || _closed || !identical(owner, session)) {
      throw ExplorerExportCancelled();
    }
    _configured = true;
    return List.unmodifiable(_items);
  }

  native.DragConfiguration? configuration(
    native.DragConfiguration config,
    native.DragSession owner,
  ) {
    if (_configured ||
        !_ready ||
        _closed ||
        !identical(owner, session) ||
        config.items.length != 1) {
      return null;
    }
    _configured = true;
    final first = config.items.single;
    return native.DragConfiguration(
      items: [
        first,
        for (final item in _items.skip(1))
          native.DragConfigurationItem(item: item, image: first.image),
      ],
      allowedOperations: const [native.DropOperation.copy],
      options: config.options,
    );
  }

  native.DragItem _item(_Root root, exports.ExportDescriptor descriptor) {
    final item = native.DragItem(
      suggestedName: descriptor.name,
      localData: const {'hspterm': 'explorer-copy-only'},
    );
    if (!item.virtualFileSupported) throw StateError('当前平台不支持虚拟文件拖出');
    final metadata = Uint8List(10);
    metadata[0] = 1;
    metadata[1] = descriptor.directory ? 1 : 0;
    ByteData.sublistView(metadata)
        .setUint64(2, descriptor.bytes, Endian.little);
    item.add(
      const clipboard.SimpleValueFormat<Uint8List>(
        windows: clipboard.SimplePlatformCodec(
          formats: ['HSPTerm.VirtualDescriptor.v1'],
        ),
      )(metadata),
    );
    var registered = false, disposed = false;
    item.onRegistered.addListener(() {
      if (!registered) {
        registered = true;
        _registered++;
        if (disposed) _disposed++;
      }
      _maybeRelease();
    });
    item.onDisposed.addListener(() {
      if (!disposed) {
        disposed = true;
        if (registered) _disposed++;
        _maybeRelease();
      }
    });
    item.addVirtualFile(
      format: const clipboard.SimpleFileFormat(
        windowsFormats: ['HSPTermRemoteFile'],
        mimeTypes: ['application/octet-stream'],
      ),
      storageSuggestion: clipboard.VirtualFileStorage.temporaryFile,
      provider: (sinkProvider, progress) {
        final cancellation = ExplorerExportCancellation(
          shouldStop: () =>
              _closed ||
              root.cancelled ||
              model.isClosing ||
              model.transferTasks.any(
                (task) =>
                    task.id == root.ticket.task && task.state == 'Cancelled',
              ),
        );
        cancellation.attach(root.cancel);
        void cancelRead() => cancellation.cancel();
        progress.onCancel.addListener(cancelRead);
        EventSink? sink;
        bool finished = false;
        void finish(bool failed) {
          if (finished) return;
          finished = true;
          progress.onCancel.removeListener(cancelRead);
          try {
            if (failed) {
              sink ??= sinkProvider(fileSize: 0);
              sink!.addError(StateError('Explorer数据交付未完成；源任务可在队列继续，目标由接收方管理'));
            }
          } finally {
            sink?.close();
          }
        }

        if (_closed || _released || root.cancelled || model.isClosing) {
          try {
            finish(true);
          } catch (_) {
            model.reportOperation(StateError('Explorer接收结束未确认'));
          }
          return;
        }
        _started();
        final work = model.runTransferSubmission(() async {
          var failed = true;
          try {
            await explorerExportAdmission.run(cancellation, () async {
              if (descriptor.directory) {
                final ready = await rust.prepareExplorerExportFile(
                  task: root.ticket.task,
                  lease: root.ticket.lease,
                  node: descriptor.node,
                );
                if (ready.read != null) root.returningReads.add(ready.read!);
                cancellation.check();
                if (ready.local != null ||
                    ready.read != null ||
                    ready.bytes != 0) {
                  throw StateError('目录描述符内容无效');
                }
                root.sourceReady = true;
                sink = sinkProvider(fileSize: 0);
              } else {
                await streamExplorerSnapshot(
                  (cancel) async {
                    final ready = await rust.prepareExplorerExportFile(
                      task: root.ticket.task,
                      lease: root.ticket.lease,
                      node: descriptor.node,
                    );
                    if (ready.read != null) {
                      root.returningReads.add(ready.read!);
                    }
                    if (ready.local == null ||
                        ready.read == null ||
                        ready.bytes != descriptor.bytes) {
                      if (ready.read != null) {
                        await root.returnRead(ready.read!);
                      }
                      throw StateError('完整源快照与原描述符不一致');
                    }
                    root.sourceReady = true;
                    return ExplorerExportSnapshot(
                      ready.local!,
                      ready.bytes,
                      () => root.returnRead(ready.read!),
                    );
                  },
                  cancellation,
                  (bytes) {
                    sink = sinkProvider(fileSize: bytes);
                    return sink!;
                  },
                );
              }
            });
            failed = false;
          } catch (error) {
            if (error is! ExplorerExportCancelled) {
              throw StateError('Explorer交付未完成，请检查源任务和目标文件');
            }
          } finally {
            try {
              await cancellation.settled();
            } finally {
              try {
                finish(failed);
                if (!failed) root.delivered.add(descriptor.node);
              } finally {
                _finished();
              }
            }
          }
        });
        unawaited(
          work.catchError((Object error) {
            // runTransferSubmission already monitors the actual action. Only a
            // rejected start lacks that action's source/sink finalizer.
            if (!finished) {
              try {
                finish(true);
              } catch (_) {
                model.reportOperation(StateError('Explorer失败流结束未确认'));
              } finally {
                _finished();
              }
            }
          }),
        );
      },
    );
    return item;
  }

  void _dragCompleted() {
    _ended = true;
    _copied = session.dragCompleted.value == native.DropOperation.copy;
    session.dragCompleted.removeListener(_dragCompleted);
    if (!_copied) {
      model.monitorExplorerExport(cancel().whenComplete(_maybeRelease));
    } else {
      // Empty directory trees may never receive FILECONTENTS. A copy gesture
      // still starts their actual one-root task and confirms the source tree.
      for (final root in _roots) {
        // FILEDESCRIPTORW explicitly represents zero-length files; Explorer
        // need not ask for their FILECONTENTS to create them.
        root.delivered.addAll(
          root.descriptors
              .where((d) => !d.directory && d.bytes == 0)
              .map((d) => d.node),
        );
        if (_closed ||
            model.isClosing ||
            !root.descriptors.every((d) => d.directory || d.bytes == 0)) {
          continue;
        }
        _started();
        var entered = false;
        final work = model.runTransferSubmission(() async {
          entered = true;
          try {
            final ready = await rust.prepareExplorerExportFile(
              task: root.ticket.task,
              lease: root.ticket.lease,
              node: root.descriptors.first.node,
            );
            if (ready.read != null) {
              root.returningReads.add(ready.read!);
              await root.returnRead(ready.read!);
            }
            root.sourceReady = true;
          } finally {
            _finished();
          }
        });
        unawaited(
          work.catchError((Object _) {
            if (!entered) {
              _finished();
            }
          }),
        );
      }
      _maybeRelease();
    }
  }

  Future<void> cancel() async {
    _closed = true;
    Object? failure;
    for (final ticket in _pendingTickets.toList()) {
      try {
        final root = _roots
            .where((r) => r.ticket.lease == ticket.lease)
            .firstOrNull;
        if (root == null) {
          await rust.cancelExplorerExport(
            task: ticket.task,
            lease: ticket.lease,
          );
        } else {
          await root.cancel();
        }
      } catch (e) {
        failure ??= e;
      }
    }
    await _idle?.future;
    if (failure != null) throw StateError('原Explorer源取消未确认，请保留任务后重试结束');
  }

  void _maybeRelease() {
    if (_retiring ||
        _released ||
        !_ended ||
        !_ready ||
        _workers != 0 ||
        _disposed != _registered ||
        (_copied && _registered != count)) {
      return;
    }
    _retiring = true;
    model.monitorExplorerExport(
      release().whenComplete(() => _retiring = false),
    );
  }

  Future<void> abortPreparation() async {
    _ended = true;
    _copied = false;
    _ready = true;
    await cancel();
    await release();
  }

  Future<void> release() =>
      _releaseFuture ??= _release().whenComplete(() => _releaseFuture = null);
  Future<void> _release() async {
    if (_released) return;
    if (_workers != 0) throw StateError('本机Explorer读取仍在收尾，源缓存租约保留');
    _closed = true;
    Object? failure;
    for (final ticket in _pendingTickets.toList()) {
      final root = _roots
          .where((r) => r.ticket.lease == ticket.lease)
          .firstOrNull;
      final delivered =
          _copied &&
          root != null &&
          !root.cancelled &&
          root.sourceReady &&
          root.descriptors
              .where((d) => !d.directory)
              .every((d) => root.delivered.contains(d.node));
      try {
        if (root != null) {
          for (final read in root.returningReads.toList()) {
            await root.returnRead(read);
          }
        }
        if (!delivered) {
          if (root == null) {
            await rust.cancelExplorerExport(
              task: ticket.task,
              lease: ticket.lease,
            );
          } else {
            await root.cancel();
          }
        }
        await rust.releaseExplorerExport(
          task: ticket.task,
          lease: ticket.lease,
          delivered: delivered,
        );
        _pendingTickets.remove(ticket);
      } catch (e) {
        failure ??= e;
      }
    }
    if (failure != null) throw StateError('Explorer源缓存释放未确认；原任务及租约保留');
    _released = true;
    model.unregisterExplorerExport(this);
    session.dragCompleted.removeListener(_dragCompleted);
    if (!model.isClosing) await model.refreshTransfers();
  }
}
