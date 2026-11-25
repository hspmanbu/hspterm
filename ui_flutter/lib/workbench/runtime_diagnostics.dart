//! Low-overhead runtime diagnostics for intermittent UI stalls (round-8
//! feedback). Everything here is metadata: numeric timings, resource counts
//! and fixed kind strings — never terminal text, paths or payloads. Events
//! are threshold-gated (heartbeat only when late, frames only when janky,
//! counts at a fixed slow cadence) so the 2 MiB run-log budget survives
//! long sessions.
//!
//! Round-12: frame diagnostics now split each janky frame into its queue
//! phases — vsync→buildStart (UI isolate busy: FRB decode, timers, digests),
//! build, buildFinish→rasterStart (raster queue backlog), raster — recorded
//! in microseconds. Only frames over 250 ms log a single event; every other
//! janky frame feeds a one-minute aggregate, so a busy session cannot flood
//! the budget. Memory samples report process and cache counters, never claim
//! that Working Set or private commit is the Dart/Rust heap. No VM service or
//! forced GC is enabled in release builds.
import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform, ProcessInfo;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../terminal/painter.dart';

import 'dart:ui' show FramePhase;

import '../run_log.dart';
import 'model.dart';

enum MemorySampleTrigger {
  periodic,
  startup,
  vaultReady,
  vaultSettled,
  firstSshConnecting,
  firstSshConnected,
  firstTerminalPaint,
  firstTerminalSettled,
  export,
}

/// Reports how late a heartbeat fired. A blocked UI isolate shows up here
/// as one large drift sample instead of a pile of missing ticks.
class RuntimeDiagnostics {
  RuntimeDiagnostics(
    this._model, {
    AppRunLog? log,
    Future<Map<String, int>> Function()? nativeMemory,
  }) : _log = log ?? AppRunLog.instance,
       _nativeMemory = nativeMemory ?? readProcessMemory;
  final AppRunLog _log;
  final Future<Map<String, int>> Function() _nativeMemory;
  static WeakReference<RuntimeDiagnostics>? _active;
  static Future<void> captureActiveMemory() async =>
      _active?.target?.sampleMemory(trigger: MemorySampleTrigger.export);
  static Future<Map<String, int>> readProcessMemory() async {
    if (!Platform.isWindows) return {};
    final values = await const MethodChannel('hspterm/prototype_window')
        .invokeMapMethod<String, int>('processMemory');
    if (values == null) throw StateError('Native memory sample unavailable');
    return values;
  }

  Future<void>? _memoryWork;
  final _milestones = Queue<(MemorySampleTrigger, DateTime)>();
  LiveWorkbenchModel? _connectionModel;
  bool _connectionStarted = false, _connectionReady = false;
  bool _terminalPainted = false;
  Timer? _terminalSettle;
  bool _stopped = false;
  int? _baselineRss,
      _lastRss,
      _baselinePrivate,
      _lastPrivate,
      _lastCpu,
      _lastTime;

  final LiveWorkbenchModel? Function() _model;

  static const beat = Duration(seconds: 5);
  static const stallThresholdMs = 250;
  static const jankThresholdMs = 100;
  static const detailThresholdMs = 250;
  static const sampleInterval = Duration(seconds: 30);
  static const aggregateInterval = Duration(minutes: 1);

  Timer? _heartbeat;
  Timer? _counts;
  Timer? _aggregator;
  DateTime _nextBeat = DateTime.now();
  bool _timingsAttached = false;

  // Aggregated jank window (numbers only).
  int _aggCount = 0, _aggMaxUs = 0, _aggQueueSumUs = 0, _aggTotalSumUs = 0;

  void start() {
    if (_heartbeat != null) return;
    _stopped = false;
    _active = WeakReference(this);
    if (!_connectionReady) {
      _connectionModel = _model();
      _connectionModel?.addListener(_firstConnectionChanged);
      _firstConnectionChanged();
    }
    _nextBeat = DateTime.now().add(beat);
    _heartbeat = Timer.periodic(beat, (_) {
      final now = DateTime.now();
      final drift = now.difference(_nextBeat).inMilliseconds;
      // Re-anchor after every beat so one long stall yields one record.
      _nextBeat = now.add(beat);
      if (drift > stallThresholdMs) {
        _log.event(
          AppLogEvent.uiStall,
          count: drift,
          fields: {'driftMs': drift, 'kind': 'heartbeat'},
        );
      }
    });
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timingsAttached = true;
    _counts = Timer.periodic(sampleInterval, (_) => sampleCounts());
    _aggregator = Timer.periodic(aggregateInterval, (_) => _flushAggregate());
  }

  /// Frame timings split into queue phases. `vsyncToBuildUs` is UI-isolate
  /// queue wait (FRB decode, timers, isolate-bound work); `buildToRasterUs`
  /// is raster-thread queue backlog; both were previously invisible while
  /// totalSpan still exceeded the threshold ("buildMs=0 but slow").
  @visibleForTesting
  void onFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final totalUs = t.totalSpan.inMicroseconds;
      if (totalUs <= jankThresholdMs * 1000) continue;
      final vsyncToBuildUs =
          t.timestampInMicroseconds(FramePhase.buildStart) -
          t.timestampInMicroseconds(FramePhase.vsyncStart);
      final buildUs = t.buildDuration.inMicroseconds;
      final buildToRasterUs =
          t.timestampInMicroseconds(FramePhase.rasterStart) -
          t.timestampInMicroseconds(FramePhase.buildFinish);
      final rasterUs = t.rasterDuration.inMicroseconds;
      _aggCount++;
      _aggTotalSumUs += totalUs;
      _aggMaxUs = totalUs > _aggMaxUs ? totalUs : _aggMaxUs;
      _aggQueueSumUs += vsyncToBuildUs + buildToRasterUs;
      if (totalUs > detailThresholdMs * 1000) {
        _log.event(
          AppLogEvent.frameJank,
          count: totalUs ~/ 1000,
          fields: {
            'vsyncToBuildUs': vsyncToBuildUs,
            'buildUs': buildUs,
            'buildToRasterUs': buildToRasterUs,
            'rasterUs': rasterUs,
            'totalUs': totalUs,
            'kind': 'frame',
          },
        );
      }
    }
  }

  void _flushAggregate() {
    if (_aggCount == 0) return;
    _log.event(
      AppLogEvent.frameJank,
      count: _aggCount,
      fields: {
        'avgTotalUs': _aggTotalSumUs ~/ _aggCount,
        'maxTotalUs': _aggMaxUs,
        'queueShare': _aggQueueSumUs * 100 ~/ _aggTotalSumUs,
        'kind': 'frameAgg',
      },
    );
    _aggCount = _aggMaxUs = _aggQueueSumUs = _aggTotalSumUs = 0;
  }

  void _onTimings(List<FrameTiming> timings) => onFrameTimings(timings);

  /// Active resource counts: terminals/edits/transfers plus native cache
  /// weights. A leak shows up as monotonic growth across samples.
  @visibleForTesting
  void sampleCounts() {
    final model = _model();
    if (model == null) return;
    var directoryCacheBytes = 0, directoryCacheCount = 0;
    for (final s in model.sessions) {
      if (s is LiveTerminalSession) {
        directoryCacheBytes += s.directoryCache.estimatedBytes;
        directoryCacheCount += s.directoryCache.files.length;
      }
    }
    final fields = <String, Object>{
      'terminals': model.sessions.where((s) => !s.disconnected).length,
      'edits': model.localEdits.length,
      'transfers': model.totalTransferCount,
      'dirCacheKiB': directoryCacheBytes ~/ 1024,
      'dirCacheDirs': directoryCacheCount,
      'kind': 'counts',
    };
    if (Platform.isWindows || Platform.isLinux) {
      // currentRss/maxRss on Linux is VmRSS/VmHWM; on Windows the working
      // set. Same numbers as memorySample, but co-located with the counts.
      fields['rssKiB'] = ProcessInfo.currentRss ~/ 1024;
      fields['maxRssKiB'] = ProcessInfo.maxRss ~/ 1024;
    }
    _log.event(AppLogEvent.resourceCount, fields: fields);
  }

  /// Coalesced, low-frequency sample. Native metrics only take local locks;
  /// this never starts SSH probing, parses history or copies terminal text.
  Future<void> sampleMemory({
    MemorySampleTrigger trigger = MemorySampleTrigger.periodic,
  }) {
    if (_stopped) return Future.value();
    return _memoryWork ??= _startMemorySample(trigger);
  }

  void _firstConnectionChanged() {
    final sessions = _connectionModel?.sessions
        .whereType<LiveTerminalSession>();
    if (sessions == null) return;
    if (!_connectionStarted &&
        sessions.any((s) => s.controller.phase == 'Connecting')) {
      _connectionStarted = true;
      _sampleMilestone(MemorySampleTrigger.firstSshConnecting);
    }
    if (sessions.any((s) => s.controller.connected)) {
      _connectionReady = true;
      _sampleMilestone(MemorySampleTrigger.firstSshConnected);
      _connectionModel?.removeListener(_firstConnectionChanged);
      _connectionModel = null;
    }
  }

  void firstConnectedPaint() {
    if (_stopped || _terminalPainted) return;
    _terminalPainted = true;
    _sampleMilestone(MemorySampleTrigger.firstTerminalPaint);
    _terminalSettle = Timer(
      const Duration(seconds: 2),
      () => _sampleMilestone(MemorySampleTrigger.firstTerminalSettled),
    );
  }

  void _sampleMilestone(MemorySampleTrigger trigger) {
    if (_stopped) return;
    // Each milestone fires at most once per launch. Keep its label even if
    // another sample is in flight and report any resulting capture delay.
    if (_memoryWork != null) {
      _milestones.addLast((trigger, DateTime.now()));
    } else {
      _memoryWork = _startMemorySample(trigger);
    }
  }

  Future<void> _startMemorySample(
    MemorySampleTrigger trigger, [
    DateTime? requested,
  ]) => _sampleMemory(trigger, requested).whenComplete(() {
    _memoryWork = null;
    if (!_stopped && _milestones.isNotEmpty) {
      final (next, at) = _milestones.removeFirst();
      _memoryWork = _startMemorySample(next, at);
    }
  });

  Future<void> _sampleMemory(
    MemorySampleTrigger trigger,
    DateTime? requested,
  ) async {
    final model = _model();
    final viewport = SchedulerBinding.instance.platformDispatcher.implicitView;
    final fields = <String, Object>{
      'kind': 'memory',
      'memoryTrigger': trigger.name,
      'nativeFailures': 0,
      if (requested != null)
        'memoryDelayMs': DateTime.now().difference(requested).inMilliseconds,
      if (viewport != null) ...{
        'viewWidthPx': viewport.physicalSize.width.toInt(),
        'viewHeightPx': viewport.physicalSize.height.toInt(),
      },
    };
    try {
      final native = await _nativeMemory();
      // Accept only numeric, known fields even if the platform bridge changes.
      for (final key in AppRunLog.processMemoryKeys) {
        if (native[key] case final value? when value >= 0) fields[key] = value;
      }
    } catch (_) {
      fields['nativeFailures'] = 1;
    }
    if (_stopped) return;
    fields.putIfAbsent('rssKiB', () => ProcessInfo.currentRss ~/ 1024);
    fields.putIfAbsent('maxRssKiB', () => ProcessInfo.maxRss ~/ 1024);
    final rss = fields['rssKiB'] as int;
    _baselineRss ??= rss;
    fields['rssGrowthKiB'] = rss - _baselineRss!;
    if (_lastRss != null) fields['rssDeltaKiB'] = rss - _lastRss!;
    _lastRss = rss;
    if (fields['privateKiB'] case final int private) {
      _baselinePrivate ??= private;
      fields['privateGrowthKiB'] = private - _baselinePrivate!;
      if (_lastPrivate != null) {
        fields['privateDeltaKiB'] = private - _lastPrivate!;
      }
      _lastPrivate = private;
    }
    if (fields['cpuUs'] case final int cpu) {
      final millis = fields['uptimeMs'] as int?;
      if (millis != null &&
          _lastTime != null &&
          millis > _lastTime! &&
          _lastCpu != null &&
          cpu >= _lastCpu!) {
        // 100% = one fully occupied logical CPU, may exceed 100%.
        fields['cpuPercent'] = (cpu - _lastCpu!) / ((millis - _lastTime!) * 10);
      }
      _lastCpu = cpu;
      _lastTime = millis;
    }
    final images = PaintingBinding.instance.imageCache;
    fields.addAll({
      'imageCacheKiB': images.currentSizeBytes ~/ 1024,
      'imageCacheCount': images.currentSize,
      'liveImages': images.liveImageCount,
      'pendingImages': images.pendingImageCount,
    });
    fields.addAll(TerminalPaintCache.memoryCounters());
    if (model != null) {
      fields.addAll(model.editorMemoryCounters);
      fields.addAll({
        'terminals': model.sessions.length,
        'edits': model.localEdits.length,
        'transfers': model.totalTransferCount,
      });
      var cacheBytes = 0, dirs = 0, frameCells = 0, metricFailures = 0;
      final totals = <String, int>{};
      for (final s
          in model.sessions.whereType<LiveTerminalSession>().toList()) {
        final c = s.controller;
        cacheBytes += s.directoryCache.estimatedBytes;
        dirs += s.directoryCache.files.length;
        frameCells += c.rows.fold<int>(0, (sum, row) => sum + row.length);
        final id = c.id, generation = c.generation;
        if (id == null) continue;
        try {
          final value = await c.backend.metrics(id);
          if (_stopped) return;
          if (c.id != id ||
              c.generation != generation ||
              !model.sessions.contains(s)) {
            continue;
          }
          final values = {
            'historyDiskKiB': value.diskBytes ~/ 1024,
            'historyRows': value.historyRows,
            'residentCells': value.residentHistoryCells,
            'framePulls': value.framePulls,
            'cellsSent': value.cellsSent,
            'changedRows': value.changedRowsSent,
          };
          for (final entry in values.entries) {
            totals.update(
              entry.key,
              (old) => old + entry.value,
              ifAbsent: () => entry.value,
            );
          }
        } catch (_) {
          metricFailures++;
        }
      }
      fields.addAll(totals);
      fields.addAll({
        'dirCacheKiB': cacheBytes ~/ 1024,
        'dirCacheDirs': dirs,
        'frameCells': frameCells,
        'metricFailures': metricFailures,
      });
    }
    if (!_stopped) {
      _log.event(AppLogEvent.memorySample, count: rss, fields: fields);
    }
  }

  void stop() {
    _stopped = true;
    _connectionModel?.removeListener(_firstConnectionChanged);
    _connectionModel = null;
    _terminalSettle?.cancel();
    _milestones.clear();
    if (identical(_active?.target, this)) _active = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _counts?.cancel();
    _counts = null;
    _aggregator?.cancel();
    _aggregator = null;
    _flushAggregate();
    if (_timingsAttached) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _timingsAttached = false;
    }
  }
}
