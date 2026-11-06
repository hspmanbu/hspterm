import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;

enum AppLogEvent {
  startup,
  nativeReady,
  vaultOpen,
  vaultOpened,
  pageChanged,
  settingsApply,
  settingsApplied,
  settingsFailed,
  operationFailed,
  terminalFailed,
  frameworkFailed,
  asyncFailed,
  nativeStartupFailed,
  windowReady,
  windowFailed,
  pathApplied,
  pathUnavailable,
  pathUnconfirmed,
  exportRequested,
  exported,
  exportFailed,
  // Third-round additions: fixed non-content events only. No paths, file
  // names, command text or payloads ever enter the log.
  sftpDirectoryLoaded,
  sftpDirectoryFailed,
  sftpDirectoryCacheHit,
  sftpNavigationApplied,
  transferEnqueued,
  transferConflictPrompt,
  transferConflictResolved,
  transferStateFailed,
  editorOpened,
  editorSaved,
  editorSaveFailed,
  previewOpened,
  propertiesOpened,
  explorerDropAccepted,
  autoReconnectTriggered,
  autoReconnectDisabled,
  // Local editor write-back sessions (sizes/durations only, never content).
  editDownloaded,
  editOpened,
  editUploaded,
  editUploadFailed,
  editConflict,
  // Timings (count = milliseconds) and memory samples (count = KiB).
  connectionTiming,
  sftpDirectoryTiming,
  memorySample,
}

/// Current launch only. Accept fixed events/numbers and code locations, never
/// raw exception messages, terminal text, command/path or credential values.
class AppRunLog {
  AppRunLog({DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    started = _clock().toUtc();
  }
  static final instance = AppRunLog();
  final DateTime Function() _clock;
  late final DateTime started;
  final _records = Queue<({int stamp, String line})>();
  int _bytes = 0, dropped = 0;
  static const budget = 2 * 1024 * 1024;

  /// Structured, allowlisted fields rendered as `key=value`. Only these
  /// keys may appear; no free-form text crosses this boundary.
  static const fieldKeys = {
    'durationMs',
    'bytes',
    'result',
    'errorCode',
    'kind',
    'count',
  };

  void event(
    AppLogEvent event, {
    int? terminal,
    int? generation,
    int? count,
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? fields,
  }) {
    final safeFields = <String, Object?>{
      for (final entry in (fields ?? const {}).entries)
        if (fieldKeys.contains(entry.key) &&
            (entry.value is num ||
                entry.value is bool ||
                entry.value is String))
          entry.key: entry.value,
    };
    final level = event.name.endsWith('Failed')
        ? 'ERROR'
        : (event == AppLogEvent.pathUnavailable ||
              event == AppLogEvent.pathUnconfirmed ||
              event == AppLogEvent.transferConflictPrompt)
        ? 'WARN'
        : 'INFO';
    final type = error?.runtimeType.toString().replaceAll(
      RegExp(r'[^A-Za-z0-9_<>?, ]'),
      '',
    );
    final locations = stack == null
        ? <String>[]
        : RegExp(r'package:(?:hspterm|flutter)/[A-Za-z0-9_./-]+\.dart:\d+:\d+')
              .allMatches(stack.toString())
              .take(12)
              .map((m) => m[0]!)
              .toList();
    final now = _clock().toUtc();
    final line =
        '${now.toIso8601String()} [$level] ui.${event.name}'
        '${terminal == null ? '' : ' terminal=$terminal'}'
        '${generation == null ? '' : ' generation=$generation'}'
        '${count == null ? '' : ' count=$count'}'
        '${safeFields.isEmpty ? '' : ' ${safeFields.entries.map((e) => '${e.key}=${e.value}').join(' ')}'}'
        '${type == null ? '' : ' error-class=${type.substring(0, type.length.clamp(0, 100))}'}'
        '${locations.isEmpty ? '' : ' at=${locations.join(' <- ')}'}';
    final size = utf8.encode(line).length + 1;
    while (_bytes + size > budget && _records.isNotEmpty) {
      _bytes -= utf8.encode(_records.removeFirst().line).length + 1;
      dropped++;
    }
    if (size <= budget) {
      _records.add((stamp: now.millisecondsSinceEpoch, line: line));
      _bytes += size;
    }
  }

  void clear() {
    _records.clear();
    _bytes = 0;
    dropped = 0;
  }

  String export(String native) {
    final rows = _records.toList();
    for (final line in const LineSplitter().convert(native)) {
      final match = RegExp(r'^(\d{10,16}) (.*)$').firstMatch(line);
      if (match == null) continue;
      final stamp = int.tryParse(match[1]!);
      if (stamp == null || stamp > 8640000000000000) continue;
      rows.add((
        stamp: stamp,
        line:
            '${DateTime.fromMillisecondsSinceEpoch(stamp, isUtc: true).toIso8601String()} ${match[2]}',
      ));
    }
    rows.sort((a, b) => a.stamp.compareTo(b.stamp));
    final meta = const LineSplitter()
        .convert(native)
        .where((l) => l.startsWith('start-unix-ms='))
        .join();
    return 'HSPTerm current-launch log\n'
        'launch-start=${started.toIso8601String()} platform=${Platform.operatingSystem} ui-dropped=$dropped $meta\n'
        'No previous-launch logs are loaded. Native/UI buffers are bounded.\n'
        '${rows.map((r) => r.line).join('\n')}\n';
  }
}
