// Synthetic metadata only; no Vault, network, accounts or real file names.
// Exercise the workbench's actual session/cache factory in separate Release
// processes before/after an optimization. Estimated cache weights are reported
// separately from OS memory; neither is a measurement of Windows Private Bytes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/directory_reader.dart';
import 'package:hspterm/workbench/model.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final model = LiveWorkbenchModel();
  final sessions = <LiveTerminalSession>[];
  final samples = <Map<String, Object?>>[];
  Future<void> sample(String stage) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    final os = <String, int>{};
    for (final line in File('/proc/self/smaps_rollup').readAsLinesSync()) {
      final m = RegExp(r'^(Rss|Pss|Private_Clean|Private_Dirty):\s+(\d+) kB')
          .firstMatch(line);
      if (m != null) os['${m[1]}_bytes'] = int.parse(m[2]!) * 1024;
    }
    samples.add({
      'stage': stage,
      ...os,
      'peak_rss_bytes': ProcessInfo.maxRss,
      'cache_estimated_bytes': sessions.fold<int>(
        0,
        (n, s) => n + s.directoryCache.estimatedBytes,
      ),
      'directories': sessions.fold<int>(0, (n, s) => n + s.directories.length),
      'retained_entries': sessions.fold<int>(
        0,
        (n, s) =>
            n + s.directories.values.fold<int>(0, (n, rows) => n + rows.length),
      ),
      'current_entries': [for (final s in sessions) s.files.length],
    });
  }

  try {
    runApp(
      MaterialApp(
        theme: Desk.theme(false),
        home: const Scaffold(
          body: Text('Directory memory benchmark · synthetic metadata'),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    await sample('engine_idle');
    for (var i = 0; i < 4; i++) {
      sessions.add(
        model.createSession(
          'session-$i',
          DemoHost('host-$i', 'Synthetic', 'example.invalid', 'g'),
        ) as LiveTerminalSession,
      );
    }
    await sample('four_sessions_empty');
    final suffix = List.filled(150, 'x').join();
    for (var pass = 0; pass < 2; pass++) {
      for (var d = 0; d < 16; d++) {
        for (var s = 0; s < sessions.length; s++) {
          final path = '/synthetic-$s/pass-$pass/directory-$d';
          final files = List.generate(5000, (i) {
            final name = 'file-${i.toString().padLeft(5, '0')}-$suffix.log';
            return DemoFile(
              '$path/$name',
              name,
              size: '1.0 KiB',
              byteSize: 1024,
              kind: '日志',
            );
          });
          var weight = 256 + 2 * path.length;
          for (final file in files) {
            weight +=
                256 +
                2 *
                    (file.id.length +
                        file.name.length +
                        file.size.length +
                        file.kind.length +
                        file.modified.length);
          }
          sessions[s].path = path;
          sessions[s].directoryCache.store(
            LoadedDirectory(path, files, weight),
          );
        }
        await Future<void>.delayed(Duration.zero);
      }
      await sample('four_sessions_filled_$pass');
      if (sessions.any((s) => s.files.length != 5000)) {
        throw StateError('A current directory was truncated or evicted');
      }
    }
    for (final s in sessions) {
      s.directoryCache.clear();
      await s.controller.shutdown();
      s.controller.dispose();
    }
    await model.shutdown();
    model.dispose();
    await sample('all_caches_cleared');
    final result = {
      'platform': Platform.operatingSystem,
      'release': const bool.fromEnvironment('dart.vm.product'),
      'fixture': {
        'sessions': 4,
        'directories_per_pass': 16,
        'entries_per_directory': 5000,
        'passes': 2,
      },
      'samples': samples,
    };
    await File(
      const String.fromEnvironment(
        'MEMORY_REPORT',
        defaultValue: '/tmp/hspterm-directory-memory.json',
      ),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
    exit(0);
  } catch (error, stack) {
    stderr.writeln('Directory benchmark failed: $error\n$stack');
    exit(1);
  }
}
