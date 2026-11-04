import 'dart:ui' show PlatformDispatcher;

import 'run_log.dart';

import 'package:flutter/material.dart';

/// Four fixed counters for this process. No API accepts or formats an exception,
/// stack, path, terminal output, candidate, clipboard or credential payload.
enum RuntimeFault { framework, asynchronous, nativeStartup, shutdown }

class RuntimeFaults {
  static final instance = RuntimeFaults();
  final _counts = <RuntimeFault, int>{};
  Map<RuntimeFault, int> get counts => Map.unmodifiable(_counts);
  void record(RuntimeFault kind) {
    _counts[kind] = ((_counts[kind] ?? 0) + 1).clamp(0, 1000000).toInt();
    // The framework error handler can be invoked during build or notification.
    // Diagnostics reads this tiny snapshot on its existing explicit refresh;
    // do not notify widgets recursively from an error callback.
  }

  void clear() => _counts.clear();
}

const nativeStartupFailure = 'Rust 核心加载失败。请检查匹配版本的原生库与应用文件，并重新启动；错误详情已脱敏。';

/// Install only at application entry, never while importing a widget or test.
/// Platform failures remain visible in diagnostics. Framework failures also
/// replace the failed widget with a fixed message rather than secret-bearing
/// default FlutterErrorDetails.toString()/ErrorWidget output.
void installApplicationErrorBoundary() {
  AppRunLog.instance.event(AppLogEvent.startup);
  FlutterError.onError = (details) {
    RuntimeFaults.instance.record(RuntimeFault.framework);
    AppRunLog.instance.event(
      AppLogEvent.frameworkFailed,
      error: details.exception,
      stack: details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    RuntimeFaults.instance.record(RuntimeFault.asynchronous);
    AppRunLog.instance.event(
      AppLogEvent.asyncFailed,
      error: error,
      stack: stack,
    );
    return true;
  };
  ErrorWidget.builder = (_) =>
      ErrorWidget.withDetails(message: '界面操作异常，请检查本次运行诊断并保留当前状态；详情已脱敏。');
}

String runtimeFaultLabel(RuntimeFault kind) => switch (kind) {
  RuntimeFault.framework => '界面工作异常',
  RuntimeFault.asynchronous => '未获处理的异步异常',
  RuntimeFault.nativeStartup => '原生核心启动失败',
  RuntimeFault.shutdown => '资源释放尚未确认',
};
