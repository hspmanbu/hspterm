import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as rust;
import '../terminal/controller.dart';

abstract interface class ResourceBarPreference {
  Future<bool> load();
  Future<void> save(bool enabled);
}

class NativeResourceBarPreference implements ResourceBarPreference {
  NativeResourceBarPreference(this.scope, this.host);
  final String scope, host;
  @override
  Future<bool> load() =>
      rust.loadResourceBarPreference(scope: scope, host: host);
  @override
  Future<void> save(bool enabled) => rust.saveResourceBarPreference(
    scope: scope,
    host: host,
    enabled: enabled,
  );
}

class InspectionSource {
  const InspectionSource(this.id, this.generation);
  final int id, generation;
}

abstract interface class RemoteInspectionGateway {
  Future<void> configure(InspectionSource source, bool metrics, bool processes);
  Future<String> sample(InspectionSource source);
  Future<String> processes(InspectionSource source);
  Future<void> terminate(InspectionSource source, String revision, int pid);
}

class NativeRemoteInspectionGateway implements RemoteInspectionGateway {
  const NativeRemoteInspectionGateway();
  @override
  Future<void> configure(InspectionSource s, bool metrics, bool processes) =>
      rust.configureRemoteInspection(
        id: s.id,
        generation: s.generation,
        metrics: metrics,
        processes: processes,
      );
  @override
  Future<String> sample(InspectionSource s) =>
      rust.sampleRemoteResources(id: s.id, generation: s.generation);
  @override
  Future<String> processes(InspectionSource s) =>
      rust.listRemoteProcesses(id: s.id, generation: s.generation);
  @override
  Future<void> terminate(InspectionSource s, String revision, int pid) =>
      rust.terminateRemoteProcess(
        id: s.id,
        generation: s.generation,
        revision: revision,
        pid: pid,
        confirmed: true,
      );
}

int _number(Map<String, dynamic> value, String key) {
  final n = value[key];
  if (n is! int || n < 0 || n > 0x7fffffffffffffff) {
    throw const FormatException('远端资源数据格式无效');
  }
  return n;
}

Map<String, dynamic> _document(String raw, Set<String> keys) {
  if (raw.length > 256 * 1024) throw const FormatException('远端检查数据超过容量');
  final v = jsonDecode(raw) as Map<String, dynamic>;
  if (v.length != keys.length ||
      !v.keys.every(keys.contains) ||
      v['version'] != 1 ||
      v['boot'] is! String ||
      !RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')
          .hasMatch(v['boot'] as String)) {
    throw const FormatException('远端检查数据版本或字段无效');
  }
  return v;
}

class RemoteResourceSample {
  RemoteResourceSample._(
    this.boot,
    this.millis,
    this.cpuTotal,
    this.cpuIdle,
    this.memoryTotal,
    this.memoryAvailable,
    this.diskTotal,
    this.diskAvailable,
    this.rx,
    this.tx,
  );
  final String boot;
  final int millis,
      cpuTotal,
      cpuIdle,
      memoryTotal,
      memoryAvailable,
      diskTotal,
      diskAvailable,
      rx,
      tx;
  factory RemoteResourceSample.parse(String raw) {
    final v = _document(raw, {
      'version',
      'boot',
      'millis',
      'cpu_total',
      'cpu_idle',
      'memory_total',
      'memory_available',
      'disk_total',
      'disk_available',
      'rx',
      'tx',
    });
    final s = RemoteResourceSample._(
      v['boot'] as String,
      _number(v, 'millis'),
      _number(v, 'cpu_total'),
      _number(v, 'cpu_idle'),
      _number(v, 'memory_total'),
      _number(v, 'memory_available'),
      _number(v, 'disk_total'),
      _number(v, 'disk_available'),
      _number(v, 'rx'),
      _number(v, 'tx'),
    );
    if (s.cpuIdle > s.cpuTotal ||
        s.memoryTotal == 0 ||
        s.memoryAvailable > s.memoryTotal ||
        s.diskTotal == 0 ||
        s.diskAvailable > s.diskTotal) {
      throw const FormatException('远端资源计数无效');
    }
    return s;
  }
}

class RemoteResourceSummary {
  RemoteResourceSummary(this.sample, RemoteResourceSample? previous) {
    if (previous == null || previous.boot != sample.boot) return;
    final elapsed = sample.millis - previous.millis;
    final total = sample.cpuTotal - previous.cpuTotal;
    final idle = sample.cpuIdle - previous.cpuIdle;
    if (elapsed < 1000 || elapsed > 30000) return;
    if (total > 0 && idle >= 0 && idle <= total) {
      cpu = 100 * (total - idle) / total;
    }
    if (sample.rx >= previous.rx) {
      rxPerSecond = (sample.rx - previous.rx) * 1000 / elapsed;
    }
    if (sample.tx >= previous.tx) {
      txPerSecond = (sample.tx - previous.tx) * 1000 / elapsed;
    }
  }
  final RemoteResourceSample sample;
  double? cpu, rxPerSecond, txPerSecond;
  String get label =>
      'CPU ${cpu == null ? '—' : '${cpu!.toStringAsFixed(0)}%'} · '
      '内存 ${((sample.memoryTotal - sample.memoryAvailable) * 100 / sample.memoryTotal).toStringAsFixed(0)}% · '
      '根盘 ${((sample.diskTotal - sample.diskAvailable) * 100 / sample.diskTotal).toStringAsFixed(0)}% · '
      '↓${_rate(rxPerSecond)} ↑${_rate(txPerSecond)}';
  static String _rate(double? n) => n == null
      ? '—'
      : n >= 1048576
      ? '${(n / 1048576).toStringAsFixed(1)}MiB/s'
      : '${(n / 1024).toStringAsFixed(1)}KiB/s';
}

class RemoteProcess {
  const RemoteProcess(
    this.pid,
    this.name,
    this.state,
    this.start,
    this.ticks,
    this.rss,
    this.uid,
  );
  final int pid, start, ticks, rss, uid;
  final String name, state;
}

class RemoteProcessList {
  RemoteProcessList(
    this.revision,
    List<RemoteProcess> processes,
    this.truncated,
    this.skipped,
    this.canSignal,
  ) : processes = List.unmodifiable(processes);
  final String revision;
  final List<RemoteProcess> processes;
  final bool truncated, canSignal;
  final int skipped;
  factory RemoteProcessList.parse(String raw) {
    final v = _document(raw, {
      'version',
      'boot',
      'revision',
      'processes',
      'truncated',
      'skipped',
      'can_signal',
    });
    final revision = v['revision'] as String;
    final rows = v['processes'] as List;
    final skipped = _number(v, 'skipped');
    if (!RegExp(r'^\d{1,20}-\d{1,20}$').hasMatch(revision) ||
        rows.length > 512 ||
        skipped > 4096) {
      throw const FormatException('远端进程列表超过容量或修订无效');
    }
    final ids = <int>{};
    final processes = <RemoteProcess>[];
    for (final row in rows.cast<Map<String, dynamic>>()) {
      final pid = _number(row, 'pid'), start = _number(row, 'start');
      final name = row['name'] as String, state = row['state'] as String;
      if (row.length != 7 ||
          !row.keys.every(
            {'pid', 'name', 'state', 'start', 'ticks', 'rss', 'uid'}.contains,
          ) ||
          pid == 0 ||
          pid > 0xffffffff ||
          !ids.add(pid) ||
          name.length > 256 ||
          name.runes.any(
            (n) =>
                n < 32 ||
                n >= 127 && n <= 159 ||
                n >= 0x202a && n <= 0x202e ||
                n >= 0x2066 && n <= 0x2069,
          ) ||
          !RegExp(r'^[RSDZTtXxKWPI]$').hasMatch(state)) {
        throw const FormatException('远端进程元数据无效');
      }
      processes.add(
        RemoteProcess(
          pid,
          name,
          state,
          start,
          _number(row, 'ticks'),
          _number(row, 'rss'),
          _number(row, 'uid'),
        ),
      );
    }
    return RemoteProcessList(
      revision,
      processes,
      v['truncated'] as bool,
      skipped,
      v['can_signal'] as bool,
    );
  }
}

RemoteProcessList _parseProcesses(String raw) => RemoteProcessList.parse(raw);

/// Session-owned, never widget-owned. No requests until explicit configure ACK;
/// only the focused foreground status view arms one delayed five-second sample.
class RemoteInspectionController extends ChangeNotifier {
  RemoteInspectionController(
    this.terminal, {
    this.gateway = const NativeRemoteInspectionGateway(),
    this.interval = const Duration(seconds: 5),
    this.preference,
  }) {
    terminal.addListener(_sessionChanged);
    _preferenceWork = _loadPreference();
  }
  final TerminalController terminal;
  final RemoteInspectionGateway gateway;
  final Duration interval;
  final ResourceBarPreference? preference;
  late final Future<void> _preferenceWork;
  bool _desiredMetrics = false;
  int? _restoreTriedGeneration;
  Future<void> ready() async {
    await _preferenceWork;
    await _configuration;
  }

  Future<void> _loadPreference() async {
    if (preference == null) return;
    try {
      _desiredMetrics = await preference!.load();
      if (!_disposed && !_closing) _maybeRestore();
    } catch (_) {
      if (!_disposed && !_closing) {
        error = '资源栏偏好读取失败；请手动启用或重试。';
        _notify();
      }
    }
  }

  void _maybeRestore() {
    if (!_desiredMetrics ||
        _disposed ||
        _closing ||
        !terminal.connected ||
        _source != null ||
        _configuration != null ||
        _restoreTriedGeneration == terminal.generation) {
      return;
    }
    _restoreTriedGeneration = terminal.generation;
    unawaited(
      configure(
        metrics: true,
        processes: false,
        persist: false,
      ).catchError((Object _) {}),
    );
  }

  InspectionSource? _source;
  bool metrics = false, processesAllowed = false, active = false;
  bool _closing = false, _disposed = false;
  int _epoch = 0;
  Timer? _timer;
  Future<void>? _work, _configuration;
  RemoteResourceSummary? summary;
  RemoteProcessList? processList;
  String? error, result;
  bool get busy => _work != null || _configuration != null;
  bool _current(InspectionSource s) =>
      !_disposed &&
      terminal.connected &&
      terminal.id == s.id &&
      terminal.generation == s.generation;
  InspectionSource _capture() {
    if (_closing || _disposed || !terminal.connected || terminal.id == null) {
      throw StateError('原终端未连接或正在关闭');
    }
    return InspectionSource(terminal.id!, terminal.generation);
  }

  void _sessionChanged() {
    final s = _source;
    if (s == null) {
      _maybeRestore();
      return;
    }
    if (_current(s)) return;
    ++_epoch;
    _timer?.cancel();
    _timer = null;
    _source = null;
    metrics = false;
    processesAllowed = false;
    summary = null;
    processList = null;
    result = null;
    error = '原终端已断开；进程授权已清除。';
    _notify();
    _maybeRestore();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setActive(bool value) {
    if (active == value || _disposed) return;
    active = value;
    _timer?.cancel();
    _timer = null;
    if (value) _schedule(immediate: true);
  }

  void _schedule({bool immediate = false}) {
    _timer?.cancel();
    _timer = null;
    if (_closing ||
        _disposed ||
        !active ||
        !metrics ||
        busy ||
        error != null ||
        _source == null ||
        !_current(_source!)) {
      return;
    }
    _timer = Timer(immediate ? Duration.zero : interval, () {
      _timer = null;
      unawaited(refreshMetrics().catchError((Object _) {}));
    });
  }

  Future<void> configure({
    required bool metrics,
    required bool processes,
    bool persist = true,
  }) {
    final source = _capture();
    if (_configuration != null) return Future.error(StateError('正在修改原终端检查授权'));
    final done = Completer<void>();
    _configuration = done.future;
    final epoch = ++_epoch;
    _timer?.cancel();
    _timer = null;
    // Hide stale local data before any await; backend cancellation runs without
    // waiting for an in-flight sample/list so it can actually revoke that work.
    this.metrics = false;
    processesAllowed = false;
    summary = null;
    processList = null;
    result = null;
    error = null;
    _source = source;
    _notify();
    unawaited(() async {
      try {
        if (persist) await _preferenceWork;
        if (!_current(source) || _closing) throw StateError('原终端已改变，未修改资源授权');
        await gateway.configure(source, metrics, processes);
        if (_current(source) && epoch == _epoch && !_closing) {
          this.metrics = metrics;
          processesAllowed = processes;
          if (persist) {
            await preference?.save(metrics);
            _desiredMetrics = metrics;
          }
        }
        done.complete();
      } catch (e, stack) {
        if (_current(source) && epoch == _epoch) {
          error = '远端检查或偏好保存未获确认，请检查当前开关后重试。';
        }
        done.completeError(e, stack);
      } finally {
        _configuration = null;
        _notify();
        _schedule(immediate: true);
      }
    }());
    return done.future;
  }

  Future<void> _run(Future<void> Function(InspectionSource, int) action) {
    if (busy) return Future.error(StateError('原终端远端检查正在处理'));
    final source = _capture();
    if (_source?.id != source.id || _source?.generation != source.generation) {
      return Future.error(StateError('请重新启用原终端远端检查'));
    }
    final epoch = _epoch;
    final done = Completer<void>();
    _work = done.future;
    _timer?.cancel();
    _timer = null;
    error = null;
    result = null;
    _notify();
    unawaited(() async {
      try {
        await action(source, epoch);
        done.complete();
      } catch (e, stack) {
        if (_current(source) && epoch == _epoch) {
          error = '远端检查未获完整确认，已停止自动采样；需要 Linux procfs 与 Python 3。';
        }
        done.completeError(e, stack);
      } finally {
        _work = null;
        _notify();
        _schedule();
      }
    }());
    return done.future;
  }

  bool _accept(InspectionSource s, int epoch) =>
      !_closing && epoch == _epoch && _current(s);
  Future<void> refreshMetrics() {
    if (!metrics) return Future.error(StateError('尚未启用资源检查'));
    return _run((s, epoch) async {
      final sample = RemoteResourceSample.parse(await gateway.sample(s));
      if (_accept(s, epoch)) {
        summary = RemoteResourceSummary(sample, summary?.sample);
      }
    });
  }

  Future<void> refreshProcesses() {
    if (!processesAllowed) return Future.error(StateError('尚未授权读取进程列表'));
    return _run((s, epoch) async {
      final value = await compute(_parseProcesses, await gateway.processes(s));
      if (_accept(s, epoch)) processList = value;
    });
  }

  Future<void> terminate(RemoteProcessList original, RemoteProcess process) {
    if (!processesAllowed ||
        !identical(processList, original) ||
        !original.canSignal ||
        !original.processes.contains(process) ||
        (process.pid <= 1 || process.start == 0)) {
      return Future.error(StateError('原进程列表已改变，请刷新后重新确认'));
    }
    return _run((s, epoch) async {
      // Consumed even on unknown response. Never automatically replay a signal.
      processList = null;
      try {
        await gateway.terminate(s, original.revision, process.pid);
        if (_accept(s, epoch)) result = '远端内核已接受 SIGTERM；不代表进程已退出，请按需刷新列表。';
      } catch (_) {
        if (_accept(s, epoch)) result = '结束进程结果未确认，可能已经发送；请刷新列表，不要盲目重复。';
        rethrow;
      }
    });
  }

  Future<void> shutdown() async {
    if (_disposed) return;
    _closing = true;
    await _preferenceWork;
    ++_epoch;
    _timer?.cancel();
    _timer = null;
    metrics = false;
    processesAllowed = false;
    summary = null;
    processList = null;
    final configuration = _configuration;
    if (configuration != null) {
      try {
        await configuration;
      } catch (_) {
        /* Revoke current consent below. */
      }
    }
    final source = _source;
    try {
      if (source != null && _current(source)) {
        await gateway.configure(source, false, false);
      }
    } finally {
      // RPC work is cancelled by consent revocation or original Root teardown.
      final work = _work;
      if (work != null) {
        try {
          await work;
        } catch (_) {
          /* Original caller receives failure. */
        }
      }
    }
  }

  void resumeAfterCancelledShutdown() {
    if (!_disposed) _closing = false;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _timer?.cancel();
    terminal.removeListener(_sessionChanged);
    super.dispose();
  }
}
