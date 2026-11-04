import 'run_log.dart';
import 'runtime_errors.dart';
import 'terminal/font_licenses.dart';

import 'package:flutter/material.dart';

import 'terminal/backend.dart';
import 'workbench/app.dart';

Future<void> main() async {
  installApplicationErrorBoundary();
  WidgetsFlutterBinding.ensureInitialized();
  registerTerminalFontLicenses();
  try {
    await initializeRust();
    AppRunLog.instance.event(AppLogEvent.nativeReady);
    runApp(const WorkbenchApp());
  } catch (error, stack) {
    AppRunLog.instance.event(
      AppLogEvent.nativeStartupFailed,
      error: error,
      stack: stack,
    );
    RuntimeFaults.instance.record(RuntimeFault.nativeStartup);
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(child: SelectableText(nativeStartupFailure)),
        ),
      ),
    );
  }
}
