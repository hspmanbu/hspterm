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
//! the budget. Memory samples gained maxRss, Dart heap metrics and native
//! cache counters (directory cache weight, painter glyph/row caches via the
//! model), letting a future on-device log attribute RSS to a layer.
import 'dart:async';
import 'dart:io' show Platform, ProcessInfo;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart';

import 'dart:ui' show FramePhase;

import '../run_log.dart';
import 'model.dart';

/// Reports how late a heartbeat fired. A blocked UI isolate shows up here
/// as one large drift sample instead of a pile of missing ticks.
class RuntimeDiagnostics {
  RuntimeDiagnostics(this._model);
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
    _nextBeat = DateTime.now().add(beat);
    _heartbeat = Timer.periodic(beat, (_) {
      final now = DateTime.now();
      final drift = now.difference(_nextBeat).inMilliseconds;
      // Re-anchor after every beat so one long stall yields one record.
      _nextBeat = now.add(beat);
      if (drift > stallThresholdMs) {
        AppRunLog.instance.event(
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
        AppRunLog.instance.event(
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
    AppRunLog.instance.event(
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
    AppRunLog.instance.event(AppLogEvent.resourceCount, fields: fields);
  }

  void stop() {
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
