import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/runtime_errors.dart';

class NeverFormat implements Exception {
  @override
  String toString() =>
      throw StateError('exception payload must never be inspected');
}

void main() {
  test(
    'runtime diagnostics accept only fixed kinds and immutable tiny snapshots',
    () {
      final faults = RuntimeFaults();
      faults.record(RuntimeFault.framework);
      final before = faults.counts;
      faults.record(RuntimeFault.framework);
      faults.record(RuntimeFault.nativeStartup);
      expect(before[RuntimeFault.framework], 1);
      expect(faults.counts[RuntimeFault.framework], 2);
      expect(faults.counts.length, 2);
      expect(() => before.clear(), throwsUnsupportedError);
      faults.clear();
      expect(faults.counts, isEmpty);
    },
  );
  testWidgets(
    'root handlers and error widget never format payloads or stacks',
    (tester) async {
      final framework = FlutterError.onError;
      final platform = PlatformDispatcher.instance.onError;
      final builder = ErrorWidget.builder;
      try {
        RuntimeFaults.instance.clear();
        installApplicationErrorBoundary();
        final details = FlutterErrorDetails(
          exception: NeverFormat(),
          stack: StackTrace.fromString('synthetic-private-stack'),
        );
        FlutterError.onError!(details);
        expect(
          PlatformDispatcher.instance.onError!(
            NeverFormat(),
            StackTrace.current,
          ),
          true,
        );
        expect(RuntimeFaults.instance.counts[RuntimeFault.framework], 1);
        expect(RuntimeFaults.instance.counts[RuntimeFault.asynchronous], 1);
        final widget = ErrorWidget.builder(details);
        expect(widget, isA<ErrorWidget>());
        expect(
          (widget as ErrorWidget).message,
          isNot(contains('synthetic-private-stack')),
        );
      } finally {
        FlutterError.onError = framework;
        PlatformDispatcher.instance.onError = platform;
        ErrorWidget.builder = builder;
        RuntimeFaults.instance.clear();
      }
    },
  );
}
