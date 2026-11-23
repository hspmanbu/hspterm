// Real FilesPanel, synthetic versioned metadata, no SSH/Vault/account access.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

class _Session extends TerminalSession {
  _Session(super.id, super.host);
  @override
  int get fileListRevision => 0;
}

class _File extends DemoFile {
  _File(super.id, super.name);
  static int reads = 0;
  @override
  String get name {
    reads++;
    return super.name;
  }
}

Map<String, int> memory() {
  final values = <String, int>{'peak_rss_bytes': ProcessInfo.maxRss};
  for (final line in File('/proc/self/smaps_rollup').readAsLinesSync()) {
    final m = RegExp(r'^(Rss|Pss|Private_Clean|Private_Dirty):\s+(\d+) kB')
        .firstMatch(line);
    if (m != null) values['${m[1]}_bytes'] = int.parse(m[2]!) * 1024;
  }
  return values;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final m = WorkbenchModel()..demo();
  final p = _Session('measured', m.focus!.host.snapshot())..path = '/synthetic';
  final suffix = List.filled(64, 'X').join();
  p.directories[p.path] = List.generate(4096, (i) {
    final name = 'FILE-${(4096 - i).toString().padLeft(6, '0')}-$suffix.log';
    return _File('${p.path}/$name', name);
  });
  final tick = ValueNotifier(0);
  runApp(
    MaterialApp(
      theme: Desk.theme(false),
      home: Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: tick,
          builder: (context, value, _) => FilesPanel(model: m, pane: p),
        ),
      ),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  await Future<void>.delayed(const Duration(seconds: 2));
  final samples = <Map<String, Object?>>[
    {'phase': 'listing_loaded', ...memory()},
  ];
  _File.reads = 0;
  final clock = Stopwatch()..start();
  for (var i = 0; i < 20; i++) {
    tick.value++;
    await WidgetsBinding.instance.endOfFrame;
  }
  clock.stop();
  await Future<void>.delayed(const Duration(seconds: 2));
  samples.add({
    'phase': '20_unrelated_progress_rebuilds',
    ...memory(),
    'elapsed_ms': clock.elapsedMilliseconds,
    'name_reads': _File.reads,
    'entries': p.files.length,
  });
  await File(
    const String.fromEnvironment(
      'HSPTERM_LIST_MEMORY_REPORT',
      defaultValue: '/tmp/hspterm-list-memory.json',
    ),
  ).writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'platform': Platform.operatingSystem,
      'release': const bool.fromEnvironment('dart.vm.product'),
      'rows': 4096,
      'samples': samples,
    }),
  );
  runApp(const SizedBox());
  await WidgetsBinding.instance.endOfFrame;
  tick.dispose();
  m.dispose();
  exit(0);
}
