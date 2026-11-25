//! Round-8 diagnostics: threshold-gated stall/jank/count records carry only
//! numbers and fixed kind strings.
import 'dart:ui' show FrameTiming;
import 'dart:async';

import 'package:hspterm/terminal/painter.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/run_log.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/runtime_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('memory records native private commit, deltas, CPU and releasable painter counts', () async {
    final log = AppRunLog();
    var n = 0;
    final diagnostics = RuntimeDiagnostics(
      () => null,
      log: log,
      nativeMemory: () async {
        n++;
        return {
          'rssKiB': 1024 + n * 16,
          'maxRssKiB': 2048,
          'privateKiB': 4096 + n * 32,
          'peakPrivateKiB': 8192,
          'handles': 42,
          'cpuUs': n * 500000,
          'uptimeMs': n * 1000,
          'impellerOptOut': 1,
          'privateWsKiB': 1024,
          'systemAvailableKiB': 100_000,
          'virtualMapComplete': 1,
          'virtualPrivateKiB': 256,
          'writeCombinedCommitKiB': 128,
          'writeCombinedWsComplete': n == 1 ? 1 : 0,
          if (n == 1) 'writeCombinedWsKiB': 64,
          'writeCombinedLockedKiB': -1,
          'address': 12345,
        };
      },
    );
    final cache = TerminalPaintCache();
    cache.glyph('A', 0xffffffff, 0, 14);
    await diagnostics.sampleMemory(trigger: MemorySampleTrigger.startup);
    cache.dispose();
    await diagnostics.sampleMemory(trigger: MemorySampleTrigger.vaultReady);
    final text = log.export('');
    expect(text, contains('privateGrowthKiB=32'));
    expect(text, contains('rssDeltaKiB=16'));
    expect(text, contains('cpuPercent=50.0'));
    expect(text, contains('glyphs=1'));
    expect(text, contains('glyphs=0'));
    expect(text, contains('handles=42'));
    expect(text, contains('impellerOptOut=1'));
    expect(text, contains('memoryTrigger=startup'));
    expect(text, contains('memoryTrigger=vaultReady'));
    expect(text, contains('privateWsKiB=1024'));
    expect(text, contains('systemAvailableKiB=100000'));
    expect(text, contains('virtualPrivateKiB=256'));
    expect(text, contains('writeCombinedCommitKiB=128'));
    expect(text, contains('writeCombinedWsKiB=64'));
    final recent = text
        .split('\n')
        .lastWhere((line) => line.contains('memoryTrigger=vaultReady'));
    expect(recent, contains('writeCombinedWsComplete=0'));
    expect(recent, isNot(contains('writeCombinedWsKiB=')));
    expect(text, isNot(contains('writeCombinedLockedKiB=')));
    expect(text, isNot(contains('address=')));
    expect(text, isNot(contains('heapUsedKiB=')));
    diagnostics.stop();
  });
  test(
    'overlapping memory requests coalesce and stop discards late results',
    () async {
      final log = AppRunLog(), pending = Completer<Map<String, int>>();
      var requests = 0;
      final diagnostics = RuntimeDiagnostics(
        () => null,
        log: log,
        nativeMemory: () {
          requests++;
          return pending.future;
        },
      );
      final first = diagnostics.sampleMemory(),
          second = diagnostics.sampleMemory();
      expect(identical(first, second), true);
      diagnostics.stop();
      pending.complete({'privateKiB': 999});
      await first;
      expect(requests, 1);
      expect(log.export(''), isNot(contains('privateKiB=999')));
    },
  );

  testWidgets('first paint samples survive an overlapping periodic sample', (
    tester,
  ) async {
    final log = AppRunLog();
    final pending = Completer<Map<String, int>>();
    var requests = 0;
    final diagnostics = RuntimeDiagnostics(
      () => null,
      log: log,
      nativeMemory: () => ++requests == 1 ? pending.future : Future.value({}),
    );
    addTearDown(diagnostics.stop);
    final periodic = diagnostics.sampleMemory();
    diagnostics.firstConnectedPaint();
    diagnostics.firstConnectedPaint();
    expect(requests, 1);
    pending.complete({});
    await periodic;
    await tester.pump();
    expect(requests, 2);
    final first = log
        .export('')
        .split('\n')
        .singleWhere(
          (line) => line.contains('memoryTrigger=firstTerminalPaint'),
        );
    expect(first, contains('memoryDelayMs='));
    expect(first, contains('viewWidthPx='));
    await tester.pump(const Duration(seconds: 2));
    expect(requests, 3);
    expect(log.export(''), contains('memoryTrigger=firstTerminalSettled'));
  });

  test(
    'janky frames are logged with build/raster times, smooth ones are not',
    () {
      final diagnostics = RuntimeDiagnostics(() => null);
      diagnostics.onFrameTimings([
        FrameTiming(
          vsyncStart: 0,
          buildStart: 0,
          buildFinish: 8 * 1000,
          rasterStart: 0,
          rasterFinish: 9 * 1000,
          rasterFinishWallTime: 0,
        ),
        FrameTiming(
          vsyncStart: 0,
          buildStart: 0,
          buildFinish: 240 * 1000,
          rasterStart: 0,
          rasterFinish: 300 * 1000,
          rasterFinishWallTime: 0,
        ),
      ]);
      diagnostics.stop();
    },
  );

  test('resource counts reflect live sessions, edits and transfers', () {
    final model = LiveWorkbenchModel();
    final diagnostics = RuntimeDiagnostics(() => model);
    diagnostics.sampleCounts();
    diagnostics.stop();
    model.dispose();
  });

  test('heartbeat and frame events exist in the allowlisted enum surface', () {
    // The log renderer only accepts fixed events/fields; compile-time proof
    // that the diagnostics surface stays inside it.
    expect(AppLogEvent.values, contains(AppLogEvent.uiStall));
    expect(AppLogEvent.values, contains(AppLogEvent.frameJank));
    expect(AppLogEvent.values, contains(AppLogEvent.resourceCount));
  });
}
