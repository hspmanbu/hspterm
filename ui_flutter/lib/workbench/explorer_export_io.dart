import 'dart:async';
import 'dart:collection';
import 'dart:io';

void validateExplorerExportName(String name) {
  for (var i = 0; i < name.length; i++) {
    final unit = name.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= name.length ||
          name.codeUnitAt(i) < 0xdc00 ||
          name.codeUnitAt(i) > 0xdfff) {
        throw StateError('文件名包含无效Unicode');
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw StateError('文件名包含无效Unicode');
    }
  }
  if (name.isEmpty ||
      name.length > 255 ||
      name == '.' ||
      name == '..' ||
      name.endsWith('.') ||
      name.endsWith(' ') ||
      name.runes.any((r) => r < 32 || r == 127 || r >= 0xd800 && r <= 0xdfff) ||
      RegExp(r'[<>:"/\\|?*]').hasMatch(name) ||
      RegExp(r'^(CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])$')
          .hasMatch(name.split('.').first.trimRight().toUpperCase())) {
    throw StateError('所选远端名称不能安全映射到Windows；请使用下载并明确选择本地名称');
  }
}

/// A complete local snapshot is handed to Windows only after its original
/// SFTP download/file CLOSE succeeded. No partial or whole-file bytes cross FRB.
class ExplorerExportSnapshot {
  const ExplorerExportSnapshot(this.path, this.bytes, this.release);
  final String path;
  final int bytes;
  final Future<void> Function() release;
}

class ExplorerExportCancelled extends StateError {
  ExplorerExportCancelled() : super('Explorer接收已取消');
}

class ExplorerExportCancellation {
  ExplorerExportCancellation({this.shouldStop});
  final bool Function()? shouldStop;
  bool cancelled = false;
  Future<void> Function()? _stop;
  Future<void>? _stopping;
  Object? _failure;
  StackTrace? _failureStack;
  final _listeners = <void Function()>{};
  void cancel() {
    final notify = !cancelled;
    cancelled = true;
    if (notify) {
      for (final listener in _listeners.toList()) {
        listener();
      }
    }
    final stop = _stop;
    if (stop != null) {
      _stopping ??= Future<void>.sync(stop)
          .catchError((Object e, StackTrace s) {
            _failure = e;
            _failureStack = s;
          });
    }
  }

  void attach(Future<void> Function() stop) {
    _stop = stop;
    if (cancelled) cancel();
  }

  void check() {
    if (shouldStop?.call() ?? false) cancel();
    if (cancelled) throw ExplorerExportCancelled();
  }

  Future<void> settled() async {
    await _stopping;
    final failure = _failure;
    if (failure != null) Error.throwWithStackTrace(failure, _failureStack!);
  }
}

class _ExportWaiter {
  _ExportWaiter(this.cancellation);
  final ExplorerExportCancellation cancellation;
  final ready = Completer<void>();
  bool started = false;
}

/// Native consumers may request every selected FILECONTENTS concurrently (or
/// request one entry more than once). Admit only a bounded number before
/// reserving Rust preview tickets, rather than exhausting their 32-job budget.
/// This gate does not replace the shared Rust FIFO or download limiter.
class ExplorerExportAdmission {
  ExplorerExportAdmission({this.parallel = 3, this.capacity = 256}) {
    if (parallel < 1 || capacity < parallel) throw ArgumentError('导出并发参数无效');
  }
  final int parallel, capacity;
  final _waiting = Queue<_ExportWaiter>();
  int _active = 0;
  bool _pumping = false;

  Future<T> run<T>(
    ExplorerExportCancellation cancellation,
    Future<T> Function() action,
  ) async {
    cancellation.check();
    if (_waiting.length + _active >= capacity) {
      throw StateError('Explorer接收请求过多，请完成或取消当前拖出');
    }
    final waiter = _ExportWaiter(cancellation);
    void cancelWaiting() {
      if (waiter.started || waiter.ready.isCompleted) return;
      _waiting.remove(waiter);
      waiter.ready.completeError(ExplorerExportCancelled());
      _pump();
    }

    _waiting.add(waiter);
    cancellation._listeners.add(cancelWaiting);
    _pump();
    try {
      await waiter.ready.future;
      try {
        cancellation.check();
        return await action();
      } finally {
        // Cancellation is an intent. Wait for the actual action and its cleanup
        // attempts to return. Unknown IO still belongs to the retained Rust job;
        // this admission count is not proof of remote CLOSE or IO retirement.
        _active--;
        _pump();
      }
    } finally {
      cancellation._listeners.remove(cancelWaiting);
    }
  }

  void _pump() {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_active < parallel && _waiting.isNotEmpty) {
        final waiter = _waiting.removeFirst();
        try {
          waiter.cancellation.check();
        } catch (error, stack) {
          if (!waiter.ready.isCompleted) {
            waiter.ready.completeError(error, stack);
          }
          continue;
        }
        if (waiter.ready.isCompleted) continue;
        waiter.started = true;
        _active++;
        waiter.ready.complete();
      }
    } finally {
      _pumping = false;
    }
  }
}

final explorerExportAdmission = ExplorerExportAdmission();

/// Pure transport adapter, separately testable without COM or remote accounts.
/// The caller owns the sink error protocol; this never reports destination
/// creation/success, which belongs to the external receiving application.
Future<void> streamExplorerSnapshot(
  Future<ExplorerExportSnapshot> Function(ExplorerExportCancellation) prepare,
  ExplorerExportCancellation cancellation,
  EventSink Function(int bytes) sinkProvider,
) async {
  ExplorerExportSnapshot? snapshot;
  EventSink? sink;
  try {
    cancellation.check();
    snapshot = await prepare(cancellation);
    cancellation.check();
    final file = File(snapshot.path);
    if (!file.isAbsolute ||
        snapshot.bytes < 0 ||
        await file.length() != snapshot.bytes) {
      throw StateError('完整导出快照已不可用');
    }
    sink = sinkProvider(snapshot.bytes);
    var sent = 0;
    final input = await file.open();
    try {
      while (true) {
        cancellation.check();
        final chunk = await input.read(64 * 1024);
        if (chunk.isEmpty) break;
        cancellation.check();
        sent += chunk.length;
        if (sent > snapshot.bytes) throw StateError('本机导出快照长度已改变');
        sink.add(chunk);
        // Provider storage is explicitly disk backed. Yield so cancellation
        // and its receiver can run; never readAll or post the entire file.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      await input.close();
    }
    cancellation.check();
    if (sent != snapshot.bytes) throw StateError('本机导出快照未完整读取');
  } finally {
    // A release failure is still an error; do not signal a successful stream
    // before our actual source/cache lease cleanup has completed.
    try {
      await cancellation.settled();
    } finally {
      await snapshot?.release();
    }
  }
}
