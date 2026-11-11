import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flutter's widget runner has no Windows runner/plugin registration. Keep
/// native geometry explicit and deterministic rather than waiting for an
/// unhandled engine message outside FakeAsync. Geometry-specific tests replace
/// this handler with physical monitor bounds; native startup/placement checks
/// still run against the actual Release executable in Windows CI.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('hspterm/prototype_window'),
          (call) async {
            if (call.method == 'ensureDialogVisible') return null;
            // Unrelated shell/window calls must retain their ordinary fallback
            // or install their own explicit test adapter.
            throw MissingPluginException();
          },
        );
  });
  await testMain();
}
