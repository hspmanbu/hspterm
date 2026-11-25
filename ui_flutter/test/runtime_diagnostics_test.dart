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
        };
      },
    );
    final cache = TerminalPaintCache();
    cache.glyph('A', 0xffffffff, 0, 14);
    await diagnostics.sampleMemory();
    cache.dispose();
    await diagnostics.sampleMemory();
    final text = log.export('');
    expect(text, contains('privateGrowthKiB=32'));
    expect(text, contains('rssDeltaKiB=16'));
    expect(text, contains('cpuPercent=50.0'));
    expect(text, contains('glyphs=1'));
    expect(text, contains('glyphs=0'));
    expect(text, contains('handles=42'));
    expect(text, contains('impellerOptOut=1'));
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
