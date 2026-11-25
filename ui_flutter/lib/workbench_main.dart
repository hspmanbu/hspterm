import 'dart:io' show Platform;

import 'run_log.dart';
import 'runtime_errors.dart';
import 'prototype/app.dart' show initializeWindowFrame;
import 'terminal/font_licenses.dart';

import 'package:flutter/material.dart';

import 'terminal/backend.dart';
import 'workbench/app.dart';

Future<void> main() async {
  installApplicationErrorBoundary();
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final windows = Platform.isWindows;
  if (windows) binding.deferFirstFrame();
  registerTerminalFontLicenses();
  try {
    await initializeRust();
    AppRunLog.instance.event(AppLogEvent.nativeReady);
    // Set the final client area before Flutter draws the lock screen. Changing
    // the native caption after unlock forces the GPU to resize its surfaces.
    final frameInitialized = windows && await initializeWindowFrame();
    runApp(WorkbenchApp(frameInitialized: frameInitialized));
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
  } finally {
    if (windows) binding.allowFirstFrame();
  }
}
