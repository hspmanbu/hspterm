//! Low-overhead runtime diagnostics for intermittent UI stalls (round-8
//! feedback). Everything here is metadata: numeric timings, resource counts
//! and fixed kind strings — never terminal text, paths or payloads. Events
//! are threshold-gated (heartbeat only when late, frames only when janky,
//! counts at a fixed slow cadence) so the 2 MiB run-log budget survives
//! long sessions.
import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart';

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
  static const sampleInterval = Duration(seconds: 30);

  Timer? _heartbeat;
  Timer? _counts;
  DateTime _nextBeat = DateTime.now();
  bool _timingsAttached = false;

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
  }

  /// Frame build/raster times for janky frames only.
  @visibleForTesting
  void onFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final total = t.totalSpan.inMilliseconds;
      if (total <= jankThresholdMs) continue;
      AppRunLog.instance.event(
        AppLogEvent.frameJank,
        count: total,
        fields: {
          'buildMs': t.buildDuration.inMilliseconds,
          'rasterMs': t.rasterDuration.inMilliseconds,
          'kind': 'frame',
        },
      );
    }
  }

  void _onTimings(List<FrameTiming> timings) => onFrameTimings(timings);

  /// Active resource counts: terminals/edits/transfers plus the transfer
  /// queue depth. A leak shows up as monotonic growth across samples.
  @visibleForTesting
  void sampleCounts() {
    final model = _model();
    if (model == null) return;
    AppRunLog.instance.event(
      AppLogEvent.resourceCount,
      fields: {
        'terminals': model.sessions.where((s) => !s.disconnected).length,
        'edits': model.localEdits.length,
        'transfers': model.totalTransferCount,
        'kind': 'counts',
      },
    );
  }

  void stop() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _counts?.cancel();
    _counts = null;
    if (_timingsAttached) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _timingsAttached = false;
    }
  }
}
