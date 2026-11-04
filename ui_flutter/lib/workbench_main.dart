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
    runApp(const WorkbenchApp());
  } catch (_) {
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
