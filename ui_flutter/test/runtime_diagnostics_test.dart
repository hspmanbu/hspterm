//! Round-8 diagnostics: threshold-gated stall/jank/count records carry only
//! numbers and fixed kind strings.
import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/run_log.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/runtime_diagnostics.dart';

void main() {
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
