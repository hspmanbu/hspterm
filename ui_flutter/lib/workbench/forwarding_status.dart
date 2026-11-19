import 'dart:async';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/forwardings/runtime.dart' show RunStatus;
import 'model.dart' show LiveTerminalSession;

/// Terminal forwarding summaries for the tab strip and notices. The only data
/// source is the existing [rust.terminalForwardings] query; it runs on session
/// forwarding events ([TerminalController.forwardingChanges], coalesced) or an
/// explicit [TerminalForwardingMonitor.refresh] such as opening a tab menu.
/// No periodic polling.
class TerminalForwardingMonitor {
  TerminalForwardingMonitor(this._session) {
    _session.controller.forwardingChanges.addListener(_events);
    _session.controller.addListener(_status);
  }

  final LiveTerminalSession _session;
  final runs = ValueNotifier<List<RunStatus>>(const []);

  /// Emitted once per restoration failure token ([RunStatus.token] starting
  /// with `restore-error-`) so reconnect-restore failures stop being silent.
  void Function(RunStatus run)? _onRestorationFailure;
  final _unreported = <RunStatus>[];
  final _reported = <String>{};
  Timer? _settle;
  Future<void>? _work;
  int _generation = 0;
  bool _disposed = false;

  void _events() {
    if (_disposed) return;
    // A busy listener bumps the revision per accepted connection; trailing
    // coalescing keeps refreshes to at most one per quiet gap.
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 400), () {
      if (!_disposed) unawaited(refresh());
    });
  }

  void _status() {
    if (_disposed) return;
    final controller = _session.controller;
    if (!controller.connected || controller.id == null) {
      _generation = controller.generation;
      if (runs.value.isNotEmpty) runs.value = const [];
      return;
    }
    if (controller.generation != _generation) {
      // A new SSH generation starts with an empty runtime view; restoration
      // results arrive through forwarding events right after reconnect.
      _generation = controller.generation;
      if (runs.value.isNotEmpty) runs.value = const [];
    }
  }

  /// Binds the restoration-failure callback and flushes anything observed
  /// before the UI attached (sessions can outlive app-level rebinding).
  void bind(void Function(RunStatus run) onRestorationFailure) {
    if (_disposed) return;
    _onRestorationFailure = onRestorationFailure;
    final pending = List.of(_unreported);
    _unreported.clear();
    for (final run in pending) {
      onRestorationFailure(run);
    }
  }

  /// Single-flight refresh; also the menu-open path required for fresh counts.
  Future<void> refresh() {
    final pending = _work;
    if (pending != null) return pending;
    late Future<void> work;
    work = _query().whenComplete(() {
      if (identical(_work, work)) _work = null;
    });
    _work = work;
    return work;
  }

  Future<void> _query() async {
    if (_disposed) return;
    final controller = _session.controller;
    final id = controller.id;
    if (id == null || !controller.connected) {
      runs.value = const [];
      return;
    }
    final generation = controller.generation;
    _generation = generation;
    try {
      final list = await rust.terminalForwardings(id: id);
      if (_disposed ||
          _session.controller.id != id ||
          _session.controller.generation != generation) {
        return;
      }
      runs.value = List.unmodifiable(
        list.where((run) => run.generation == generation),
      );
      _reportRestorationFailures(runs.value);
    } catch (_) {
      // Metadata only. The forwarding dialog surfaces its own load errors;
      // the cached snapshot stays until the next event.
    }
  }

  void _reportRestorationFailures(List<RunStatus> list) {
    for (final run in list) {
      if (run.phase != 'failed' || !run.token.startsWith('restore-error-')) {
        continue;
      }
      if (!_reported.add(run.token)) continue;
      final sink = _onRestorationFailure;
      if (sink != null) {
        sink(run);
      } else if (_unreported.length < 8) {
        _unreported.add(run);
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _settle?.cancel();
    _session.controller.forwardingChanges.removeListener(_events);
    _session.controller.removeListener(_status);
    runs.dispose();
  }
}

/// Runs that still own a listener; ended metadata keeps history until retire.
bool forwardingRunActive(RunStatus run) =>
    !['stopped', 'failed', 'disconnected'].contains(run.phase);

int forwardingRunningCount(Iterable<RunStatus> runs) =>
    runs.where(forwardingRunActive).length;

int forwardingFailedCount(Iterable<RunStatus> runs) =>
    runs.where((run) => run.phase == 'failed').length;

String forwardingKindLabel(String kind) => switch (kind) {
  'local' => '本地 L',
  'remote' => '远端 R',
  'dynamic' => '动态 D',
  _ => kind,
};

String forwardingPhaseLabel(String phase) => switch (phase) {
  'starting' => '等待远端确认',
  'listening' => '监听中',
  'stopping' => '停止中',
  'cleanupPending' => '取消未确认',
  'cleanupDenied' => '远端拒绝取消',
  'stopped' => '已停止',
  'failed' => '启动失败',
  'disconnected' => '原连接已断开',
  _ => phase,
};

String describeForwardingRun(RunStatus run) {
  final address = run.bindAddress == null ? '' : '${run.bindAddress!}:';
  final port = run.bindPort == null ? '等待分配' : '${run.bindPort}';
  final detail = StringBuffer(
    '${forwardingKindLabel(run.kind)} $address$port'
    ' · ${forwardingPhaseLabel(run.phase)}',
  );
  final error = run.lastError;
  if (error != null) detail.write(' · $error');
  return detail.toString();
}

/// One line per run for tab hover and menu summaries.
String describeForwardingRuns(List<RunStatus> runs) =>
    [for (final run in runs) describeForwardingRun(run)].join('\n');
