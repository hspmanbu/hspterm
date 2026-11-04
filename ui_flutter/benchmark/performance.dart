import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/view.dart';

import '../test/native_bridge_test.dart' show waitFor, screen;
import '../test/support/local_sshd.dart';

int ticks() {
  final fields = File('/proc/self/stat')
      .readAsStringSync()
      .split(') ')
      .last
      .split(' ');
  return int.parse(fields[11]) + int.parse(fields[12]);
}

Map<String, int> memory() {
  final out = <String, int>{'rss_bytes': ProcessInfo.currentRss};
  for (final line in File('/proc/self/smaps_rollup').readAsLinesSync()) {
    final match = RegExp(
      r'^(Pss|Private_Dirty|Private_Clean|Shared_Clean):\s+(\d+) kB',
    ).firstMatch(line);
    if (match != null) out['${match[1]}_bytes'] = int.parse(match[2]!) * 1024;
  }
  return out;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await runWorkload().timeout(const Duration(minutes: 8));
    exit(0);
  } catch (error, stack) {
    stderr.writeln('Synthetic benchmark failed: $error\n$stack');
    exit(1);
  }
}

Future<void> mount(Widget widget) async {
  runApp(widget);
  await WidgetsBinding.instance.endOfFrame;
}

Future<void> pump() async {
  WidgetsBinding.instance.scheduleFrame();
  await WidgetsBinding.instance.endOfFrame;
}

Future<void> runWorkload() async {
  final timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);
  final reports = <Map<String, Object?>>[];
  final clockResult = await Process.run('getconf', ['CLK_TCK']);
  if (clockResult.exitCode != 0) throw StateError('Cannot read Linux CLK_TCK');
  final ticksPerSecond = int.parse(clockResult.stdout.toString().trim());
  const output = String.fromEnvironment(
    'HSPTERM_BENCH_OUT',
    defaultValue: '/tmp/hspterm-performance.json',
  );
  Future<void> save(String status) async {
    await File(output).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'schema': 2,
        'status': status,
        'clock_ticks_per_second': ticksPerSecond,
        'flutter': '3.47.7',
        'mode': const bool.fromEnvironment('dart.vm.profile')
            ? 'profile'
            : const bool.fromEnvironment('dart.vm.product')
            ? 'release'
            : 'debug',
        'samples': reports,
      }),
    );
  }

  TerminalController? c;
  final viewKey = GlobalKey<TerminalViewState>();
  Future<void> sample(String label, Future<void> Function() action) async {
    if (label.endsWith("idle")) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    final cacheBefore = viewKey.currentState?.debugCacheStats ?? {};
    timings.clear();
    final clock = Stopwatch()..start();
    final cpu = ticks();
    final frames = c?.frameCount ?? 0;
    await action();
    if (!label.endsWith("idle")) await pump();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    clock.stop();
    int? percentile(Iterable<int> data) {
      final sorted = data.toList()..sort();
      return sorted.isEmpty
          ? null
          : sorted[((sorted.length - 1) * .95).round()];
    }

    final metrics = c?.id == null ? null : await c!.backend.metrics(c.id!);
    reports.add({
      if (metrics != null)
        'core': {
          'disk_bytes': metrics.diskBytes,
          'disk_reads': metrics.diskReads,
          'disk_writes': metrics.diskWrites,
          'resident_history_cells': metrics.residentHistoryCells,
          'history_rows': metrics.historyRows,
          'frame_pulls': metrics.framePulls,
          'cells_sent': metrics.cellsSent,
          'rows_sent': metrics.changedRowsSent,
        },
      'phase': label,
      'columns': c?.metadata?.columns,
      'rows': c?.metadata?.rows,
      'paint_calls': viewKey.currentState == null
          ? null
          : (viewKey.currentState!.debugCacheStats['paints'] ?? 0) -
                (cacheBefore['paints'] ?? 0),
      'cache': viewKey.currentState?.debugCacheStats,
      ...memory(),
      'elapsed_ms': clock.elapsedMilliseconds,
      'cpu_pct':
          (ticks() - cpu) /
          ticksPerSecond /
          (clock.elapsedMicroseconds / 1e6) *
          100,
      'bridge_frames': (c?.frameCount ?? 0) - frames,
      'rendered_frames': timings.length,
      'build_p95_us': percentile(
        timings.map((t) => t.buildDuration.inMicroseconds),
      ),
      'raster_p95_us': percentile(
        timings.map((t) => t.rasterDuration.inMicroseconds),
      ),
    });
    final delivered = (c?.frameCount ?? 0) - frames;
    if (delivered > (clock.elapsedMicroseconds / 1e6 * 60).ceil() + 2) {
      throw StateError('Frame notification rate exceeds 60/s');
    }
    await save('running');
  }

  LocalSshd? server;
  try {
    await mount(
      const MaterialApp(home: Scaffold(body: Text('engine baseline'))),
    );
    await sample('flutter_engine_idle', () async {});
    await initializeRust();
    await sample('rust_library_loaded', () async {});
    c = TerminalController(const NativeTerminalBackend());
    await c.start();
    await mount(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(key: viewKey, controller: c),
        ),
      ),
    );
    await sample('terminal_created_idle', () async {});
    server = await LocalSshd.start();
    await rust.unlockVault(
      path: '${server.directory.path}/bench.vault',
      password: 'test-only-bench',
    );
    final profile = await rust.saveProfile(
      profile: rust.Profile(
        id: '',
        name: 'synthetic benchmark',
        address: '127.0.0.1',
        port: server.port,
        username: server.username,
        privateKey: true,
      ),
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );
    c.confirmHostKey = (_) async => true;
    await c.connect(profile.id);
    await waitFor(() => c!.connected, 'benchmark connect');
    Future<void> enter(String command) async {
      await c!.text(command);
      await c!.key(rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0));
    }

    await enter(
      "stty -echo; export PS1=''; unset PROMPT_COMMAND; printf '\\033[2 q%s%s\\n' SETUP_ DONE",
    );
    await waitFor(
      () => screen(c!).contains('SETUP_DONE'),
      'benchmark shell setup',
    );
    await sample('ssh_connected_idle', () async {});
    for (final tui in [
      'vim -Nu NONE -n',
      "tmux -S '${server.directory.path}/tmux' -f /dev/null new-session",
      'htop',
    ]) {
      await sample(
        tui.startsWith('tmux') ? 'tmux' : tui.split(' ').first,
        () async {
          await enter(tui);
          await waitFor(
            () => c!.metadata?.alternateScreen == true,
            'TUI startup',
          );
        },
      );
      if (tui.startsWith('vim')) {
        await c.key(rust.KeyboardInput(key: 'Escape', modifiers: 0, kind: 0));
        await enter(':q!');
      } else if (tui.startsWith('tmux')) {
        await enter('exit');
      } else {
        await c.text('q');
      }
      await waitFor(() => c!.metadata?.alternateScreen == false, 'TUI exit');
    }
    await sample('output_50000_unicode_lines', () async {
      await enter(
        "python3 -c \"for i in range(50000): print(f'{i:06} 中文 é ' + 'abcdefghij'*7)\"; printf '%s%s\\n' OUTPUT_ DONE",
      );
      await waitFor(
        () => screen(c!).contains('OUTPUT_DONE'),
        '50k output',
        timeout: const Duration(seconds: 90),
      );
    });
    await sample('scroll_history_100_steps', () async {
      for (var i = 0; i < 100; i++) {
        await c!.backend.scroll(c.id!, i < 50 ? 100 : -100);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await sample('resize_reflow_60_columns', () async {
      await c!.backend.resize(c.id!, 60, 30, 9, 21);
      await waitFor(() => c!.metadata?.columns == 60, 'resize');
    });
    await sample('resize_reflow_140_columns', () async {
      await c!.backend.resize(c.id!, 140, 34, 9, 21);
      await waitFor(() => c!.metadata?.columns == 140, 'resize restore');
    });
    await sample('manual_reconnect_5_cycles', () async {
      for (var i = 0; i < 5; i++) {
        await enter('exit');
        await waitFor(() => c!.phase == 'Disconnected', 'disconnect');
        await c!.reconnect();
        await waitFor(() => c!.connected, 'manual reconnect');
      }
    });
    if (const bool.fromEnvironment('HSPTERM_BENCH_EXTENDED')) {
      final active = c;
      await sample('extended_5s_idle', () async {
        await Future<void>.delayed(const Duration(seconds: 5));
      });
      await sample('search_50k_regex_and_markers', () async {
        final result = await active.backend.search(
          active.id!,
          r'(?m)^\d{6} 中文',
          true,
          true,
        );
        if (result.count < 49000 || result.count > 50000) {
          throw StateError('Long-history match count ${result.count}');
        }
        if (result.markers.fold(0, (a, b) => a + b) != result.count) {
          throw StateError('Search marker total');
        }
        await active.backend.navigate(active.id!, result.count ~/ 2);
        await waitFor(
          () => active.metadata?.searchRevision == result.revision,
          'long search frame',
        );
      });
      await active.setSearch('');
      await active.seek(active.metadata!.historyLines);
      final loadLatencies = <int>[];
      await sample('input_during_continuous_output', () async {
        const script = r'''import os,select,termios,tty
saved=termios.tcgetattr(0)
tty.setraw(0)
ack=0
try:
 os.write(1,b'\x1b]0;HSPTERM_LOAD_READY\x07')
 for i in range(1000):
  os.write(1, (f'{i:06} 中文 é abcdefghijklmnopqrstuvwxyz\r\n'.encode())*8)
  if select.select([0],[],[],.01)[0]:
   for byte in os.read(0,4096):
    if byte==112:
     ack+=1
     os.write(1,f'\x1b]0;HSPTERM_LOAD_ACK_{ack}\x07'.encode())
finally:
 termios.tcsetattr(0,termios.TCSANOW,saved)
 os.write(1,b'\r\nHSPTERM_LOAD_DONE\r\n')
''';
        final payload = base64Encode(utf8.encode(script));
        await enter(
          "python3 -c \"import base64;exec(base64.b64decode('$payload'))\"",
        );
        await waitFor(
          () => active.title == 'HSPTERM_LOAD_READY',
          'load TUI startup',
        );
        for (var i = 1; i <= 20; i++) {
          final timer = Stopwatch()..start();
          await active.text('p');
          await waitFor(
            () => active.title == 'HSPTERM_LOAD_ACK_$i',
            'load TUI input acknowledgement',
          );
          loadLatencies.add(timer.elapsedMilliseconds);
        }
        await waitFor(
          () => screen(active).contains('HSPTERM_LOAD_DONE'),
          'load TUI finish',
        );
      });
      loadLatencies.sort();
      reports.last['input_ack_under_load_ms'] = {
        'samples': 20,
        'p50': loadLatencies[9],
        'p95': loadLatencies[18],
        'max': loadLatencies.last,
      };
      final latencies = <int>[];
      await sample('input_echo_latency_20', () async {
        for (var i = 0; i < 20; i++) {
          final timer = Stopwatch()..start();
          await enter("printf '%s%08d\\n' LATENCY_ $i");
          final marker = 'LATENCY_${i.toString().padLeft(8, '0')}';
          await waitFor(() => screen(active).contains(marker), 'input echo');
          latencies.add(timer.elapsedMilliseconds);
        }
      });
      latencies.sort();
      reports.last['input_latency_ms'] = {
        'samples': latencies.length,
        'p50': latencies[9],
        'p95': latencies[18],
        'max': latencies.last,
      };
      for (final size in [(720, 480), (1280, 720)]) {
        await sample('native_window_resize_${size.$1}x${size.$2}', () async {
          final previous = active.metadata!.columns;
          final result = await Process.run('python3', [
            'benchmark/resize_x11.py',
            '$pid',
            '${size.$1}',
            '${size.$2}',
          ]);
          if (result.exitCode != 0) {
            throw StateError('Window resize helper: ${result.stderr}');
          }
          await waitFor(
            () => active.metadata?.columns != previous,
            'native window -> layout -> PTY',
          );
          await enter('stty size');
          await waitFor(
            () => screen(
              active,
            ).contains('${active.metadata!.rows} ${active.metadata!.columns}'),
            'resized remote PTY',
          );
        });
      }
    }
    await sample('close_terminal', () async {
      await c!.shutdown();
      await mount(const MaterialApp(home: Scaffold(body: Text('released'))));
    });
    await save('complete');
  } finally {
    await c?.shutdown();
    c?.dispose();
    await server?.close();
    SchedulerBinding.instance.removeTimingsCallback(collect);
  }
}
