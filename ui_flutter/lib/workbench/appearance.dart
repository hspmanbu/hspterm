import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;

class AppearanceSnapshot {
  AppearanceSnapshot(Map<String, dynamic> value)
    : scope = value['vault_scope'] as String,
      revision = value['revision'] as String,
      theme = value['theme'] as String {
    if (value.length != 3 ||
        !value.keys.toSet().containsAll({'vault_scope', 'revision', 'theme'}) ||
        scope.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision) ||
        !{'dark', 'light'}.contains(theme)) {
      throw const FormatException('界面外观元数据无效');
    }
  }
  final String scope, revision, theme;
  bool get light => theme == 'light';
}

abstract interface class AppearanceGateway {
  Future<AppearanceSnapshot> load();
  Future<AppearanceSnapshot> save(AppearanceSnapshot source, bool light);
}

class NativeAppearanceGateway implements AppearanceGateway {
  const NativeAppearanceGateway();
  @override
  Future<AppearanceSnapshot> load() async => AppearanceSnapshot(
    jsonDecode(await rust.loadAppearance()) as Map<String, dynamic>,
  );
  @override
  Future<AppearanceSnapshot> save(
    AppearanceSnapshot source,
    bool light,
  ) async => AppearanceSnapshot(
    jsonDecode(
      await rust.saveAppearance(
        vaultScope: source.scope,
        revision: source.revision,
        theme: light ? 'light' : 'dark',
      ),
    ) as Map<String, dynamic>,
  );
}

/// The model consumes acknowledged values. A failed read disables writes;
/// failing SQL never previews a theme as if it were already saved.
class AppearanceController extends ChangeNotifier {
  AppearanceController({this.gateway = const NativeAppearanceGateway()});
  final AppearanceGateway gateway;
  AppearanceSnapshot? value;
  String? error;
  Future<void>? _work, _shutdown;
  bool _closing = false, _disposed = false;
  bool get busy => _work != null;
  bool get available => !_closing && !_disposed && !busy && value != null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _run(Future<void> Function() action) {
    if (_closing || _disposed || busy) return Future.value();
    final done = Completer<void>();
    _work = done.future;
    error = null;
    _notify();
    unawaited(() async {
      try {
        await action();
      } catch (_) {
        value = null;
        error = '外观操作未获完整确认，请重新读取当前设置；画面保持上次确认的主题。';
      } finally {
        _work = null;
        done.complete();
        _notify();
      }
    }());
    return done.future;
  }

  Future<void> load() async {
    // A completed original save is not abandoned to publish after a restore's
    // fresh read. No polling/second request is started until it really ends.
    await _work;
    if (_closing || _disposed) return;
    await _run(() async {
      value = null;
      value = await gateway.load();
    });
  }

  Future<void> choose(bool light) {
    final source = value;
    if (!available || source == null || source.light == light) {
      return Future.value();
    }
    return _run(() async {
      final saved = await gateway.save(source, light);
      if (saved.scope != source.scope || saved.light != light) {
        value = null;
        throw StateError('主题保存回执来源不一致');
      }
      value = saved;
    });
  }

  Future<void> shutdown() {
    _closing = true;
    return _shutdown ??= () async {
      await _work;
    }();
  }

  void resumeAfterCancelledShutdown() {
    if (!_disposed) {
      _closing = false;
      _shutdown = null;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}

class AppearanceStatusPanel extends StatelessWidget {
  const AppearanceStatusPanel({super.key, required this.controller});
  final AppearanceController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controller.busy) const LinearProgressIndicator(),
        if (controller.value != null)
          Text('当前界面主题：${controller.value!.light ? '浅色 · 云白' : '深色 · 石墨'}'),
        if (controller.error != null)
          Text(
            controller.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: controller.busy ? null : controller.load,
            child: const Text('重新读取外观设置'),
          ),
        ),
      ],
    ),
  );
}
