import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';

import '../terminal/controller.dart';
import '../terminal/notifications.dart';

abstract interface class TerminalDesktopNotices {
  bool get supported;
  Future<void> show(
    RemoteTerminalNotice notice,
    String payload,
    void Function(String) activate,
    bool Function() stillAllowed,
  );
  void dispose();
}

/// Our OS registration is lazy and Windows-only. Flutter's generated Windows
/// plugin registrant may load its DLL earlier; it does not register this app's
/// notification identity until initialize below. Never used for SFTP tasks.
class WindowsTerminalDesktopNotices implements TerminalDesktopNotices {
  FlutterLocalNotificationsWindows? _plugin;
  Future<bool>? _initializing;
  bool _disposed = false;
  void Function(String)? _activate;
  @override
  bool get supported => Platform.isWindows;
  @override
  Future<void> show(
    RemoteTerminalNotice notice,
    String payload,
    void Function(String) activate,
    bool Function() stillAllowed,
  ) async {
    if (_disposed || !supported) throw StateError('Windows桌面通知不可用');
    _activate = activate;
    _initializing ??= () async {
      final plugin = _plugin = FlutterLocalNotificationsWindows();
      return plugin.initialize(
        settings: const WindowsInitializationSettings(
          appName: 'HSPTerm',
          appUserModelId: 'HSPTerm.Desktop.Terminal',
          guid: '65e7ee44-1fc9-4cb1-85f7-bdbaf657b64f',
        ),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload;
          if (!_disposed && payload != null) _activate?.call(payload);
        },
      );
    }();
    if (!await _initializing! || _disposed) {
      throw StateError('Windows终端通知注册未完成');
    }
    if (!stillAllowed()) return;
    // One application notification slot: storms replace it rather than filling
    // the OS notification center. No launch URL, file path or SSH command.
    await _plugin!.show(
      id: 1,
      title: 'HSPTerm · ${notice.summary}',
      body: [notice.title, notice.body].where((s) => s.isNotEmpty).join('\n'),
      payload: payload,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _activate = null;
    _plugin?.dispose();
  }
}

class TerminalNoticeSubject {
  const TerminalNoticeSubject(
    this.identity,
    this.controller,
    this.isFocused,
    this.activate,
  );
  final Object identity;
  final TerminalController controller;
  final bool Function() isFocused;
  final VoidCallback activate;
}

typedef _Queued = ({
  TerminalNoticeSubject subject,
  int? id,
  int generation,
  RemoteTerminalNotice notice,
  Duration at,
});

/// App-owned observers, independent of terminal views and their visibility.
/// Only TerminalController.notices enters here; no transfer/task subscription.
class TerminalNoticeHub with WidgetsBindingObserver {
  TerminalNoticeHub({
    required this.inline,
    TerminalDesktopNotices? desktop,
    this.failure,
    this.elapsed,
  }) : desktop = desktop ?? WindowsTerminalDesktopNotices() {
    final state = WidgetsBinding.instance.lifecycleState;
    _windowFocused = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }
  final void Function(RemoteTerminalNotice, VoidCallback) inline;
  final void Function(String)? failure;
  final TerminalDesktopNotices desktop;
  final Duration Function()? elapsed;
  Duration get _now => elapsed?.call() ?? _watch.elapsed;
  final _subjects = <Object, TerminalNoticeSubject>{};
  final _listeners = <Object, VoidCallback>{};
  final _pending = Queue<_Queued>();
  final _watch = Stopwatch()..start();
  final _nonce = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final _activations = <String, _Queued>{};
  Duration? _lastDesktop;
  Duration? _lastInline;
  Future<void>? _work;
  bool _windowFocused = true,
      _closing = false,
      _disposed = false,
      _failed = false;
  // Can be overridden by fake focus events in widget tests, not by remote data.
  bool get windowFocused => _windowFocused;
  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    _windowFocused = event.state == ViewFocusState.focused;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _windowFocused = state == AppLifecycleState.resumed;
  }

  void reconcile(Iterable<TerminalNoticeSubject> current) {
    if (_disposed || _closing) return;
    final next = {for (final s in current) s.identity: s};
    for (final identity in _subjects.keys.toList()) {
      if (!next.containsKey(identity) ||
          !identical(
            next[identity]!.controller,
            _subjects[identity]!.controller,
          )) {
        _subjects
            .remove(identity)!
            .controller
            .notices
            .removeListener(_listeners.remove(identity)!);
      }
    }
    for (final s in next.values) {
      final added = !_subjects.containsKey(s.identity);
      _subjects[s.identity] = s;
      if (added) {
        void changed() => _received(s.identity);
        _listeners[s.identity] = changed;
        s.controller.notices.addListener(changed);
      }
    }
    _activations.removeWhere((_, queued) => !_current(queued));
  }

  bool _current(_Queued q) =>
      !_disposed &&
      !_closing &&
      identical(
        _subjects[q.subject.identity]?.controller,
        q.subject.controller,
      ) &&
      q.subject.controller.id == q.id &&
      q.subject.controller.connected &&
      q.subject.controller.generation == q.generation &&
      q.subject.controller.acceptsNotice(q.notice);
  bool _allowed(_Queued q) {
    if (!_current(q)) return false;
    final foreground =
        _windowFocused && _subjects[q.subject.identity]!.isFocused();
    return foreground ? q.notice.foreground : q.notice.background;
  }

  void _received(Object identity) {
    final subject = _subjects[identity];
    if (subject == null) return;
    final notice = subject.controller.notices.value;
    if (notice == null) return;
    final q = (
      subject: subject,
      id: subject.controller.id,
      generation: subject.controller.generation,
      notice: notice,
      at: _now,
    );
    if (!_allowed(q)) return;
    if (_lastInline == null ||
        _now - _lastInline! >= const Duration(milliseconds: 250)) {
      _lastInline = _now;
      inline(notice, () {
        if (_current(q)) _subjects[identity]!.activate();
      });
    }
    if (!notice.desktop || _windowFocused) return;
    if (!desktop.supported) {
      if (!_failed) {
        _failed = true;
        failure?.call('Windows桌面通知仅在Windows运行；当前仅显示应用内提示。');
      }
      return;
    }
    if (_pending.length == 16) _pending.removeFirst();
    _pending.add(q);
    _drain();
  }

  void _activate(String payload) {
    final original = _activations[payload];
    if (original != null && _current(original)) {
      _subjects[original.subject.identity]!.activate();
    }
  }

  void _drain() {
    if (_work != null || _closing || _disposed) return;
    final done = Completer<void>();
    _work = done.future;
    unawaited(() async {
      try {
        while (_pending.isNotEmpty && !_closing && !_disposed) {
          final q = _pending.removeFirst();
          final now = _now;
          if (!_allowed(q) ||
              _windowFocused ||
              now - q.at > const Duration(seconds: 3) ||
              (_lastDesktop != null &&
                  now - _lastDesktop! < const Duration(seconds: 1))) {
            continue;
          }
          _lastDesktop = now;
          final payload = '$_nonce/${q.id}/${q.generation}';
          _activations
            ..clear()
            ..[payload] = q;
          try {
            await desktop.show(
              q.notice,
              payload,
              _activate,
              () => _allowed(q) && !_windowFocused,
            );
          } catch (_) {
            if (!_disposed && !_closing && !_failed) {
              _failed = true;
              failure?.call('Windows桌面通知未确认送达；应用内提示保留，请检查系统通知设置。');
            }
          }
        }
      } finally {
        _work = null;
        done.complete();
      }
    }());
  }

  Future<void> shutdown() async {
    _closing = true;
    _pending.clear();
    _activations.clear();
    await _work;
  }

  void resume() {
    if (!_disposed) _closing = false;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await shutdown();
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    for (final identity in _subjects.keys) {
      _subjects[identity]!.controller.notices.removeListener(
        _listeners[identity]!,
      );
    }
    _subjects.clear();
    _listeners.clear();
    desktop.dispose();
    _watch.stop();
  }
}
