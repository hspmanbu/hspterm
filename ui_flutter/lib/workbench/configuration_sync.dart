import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as rust;
import 'configuration_sync_reference_model.dart';

class SyncReview {
  SyncReview(Map<String, dynamic> value)
    : token = value['token'] as String,
      endpoint = value['endpoint'] as String,
      collection = value['collection'] as String,
      uploads = value['uploads'] as bool,
      references = value['references'] as bool? ?? false,
      counts = Map.unmodifiable(
        (value['summary'] as Map<String, dynamic>).cast<String, int>(),
      ) {
    if (token.isEmpty ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(collection) ||
        counts.length != 6 ||
        !counts.keys.toSet().containsAll({
          'conflicts',
          'incoming_winners',
          'deleted',
          'sensitive_changes',
          'incoming_deletions',
          'credential_changes',
        }) ||
        counts.values.any((n) => n < 0 || n > 24000)) {
      throw const FormatException('同步审阅元数据无效');
    }
    final uri = Uri.tryParse(endpoint);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('同步审阅目标无效');
    }
  }
  final String token, endpoint, collection;
  final bool uploads, references;
  final Map<String, int> counts;
  bool get needsConsent =>
      references ||
      counts['conflicts']! > 0 ||
      counts['credential_changes']! > 0 ||
      counts['incoming_deletions']! > 0;
}

class ConfigurationSyncState {
  ConfigurationSyncState(Map<String, dynamic> value)
    : owner = value['owner'] as String,
      scope = value['vault_scope'] as String,
      sequence = value['sequence'] as int,
      eligible = value['eligible'] as bool,
      operation = value['operation'] as String?,
      phase = value['phase'] as String,
      error = value['error'] as String?,
      commits = value['commits'] as int,
      configurationUpdates = value['configuration_updates'] as int,
      remotePublished = value['remote_published'] as bool,
      writeUnknown = value['write_unknown'] as bool,
      authorizationUnknown = value['authorization_unknown'] as bool? ?? false,
      review = value['review'] == null
          ? null
          : SyncReview(value['review'] as Map<String, dynamic>) {
    if (owner.isEmpty ||
        scope.isEmpty ||
        sequence < 0 ||
        commits < 0 ||
        configurationUpdates < 0 ||
        !{
          'idle',
          'reserved',
          'reading',
          'review',
          'references',
          'publishing',
          'applying',
          'committed',
          'cancelled',
          'failed',
        }.contains(phase) ||
        ({'review', 'references'}.contains(phase) &&
            (review == null || operation == null)) ||
        phase == 'references' && review?.references != true) {
      throw const FormatException('同步状态无效');
    }
  }
  final String owner, scope, phase;
  final String? operation, error;
  final int sequence, commits, configurationUpdates;
  final bool eligible, remotePublished, writeUnknown, authorizationUnknown;
  final SyncReview? review;
  bool get active => {
    'reserved',
    'reading',
    'review',
    'references',
    'publishing',
    'applying',
  }.contains(phase);
}

abstract interface class ConfigurationSyncGateway {
  Future<String> open();
  Stream<String> events(String owner);
  Future<String> status(String owner);
  Future<String> reserve(String owner);
  Future<String> prepare(String owner, String operation);
  Future<String> confirm(String owner, String operation, String review);
  Future<String> referenceChoices(
    String owner,
    String operation,
    String review,
  );
  Future<String> resolveReferences(
    String owner,
    String operation,
    String review,
    List<Map<String, String>> choices,
  );
  Future<void> cancel(String owner, String operation);
  Future<void> close(String owner);
}

class NativeConfigurationSyncGateway implements ConfigurationSyncGateway {
  const NativeConfigurationSyncGateway();
  @override
  Future<String> open() => rust.openConfigurationSync();
  @override
  Stream<String> events(String owner) =>
      rust.watchConfigurationSync(owner: owner);
  @override
  Future<String> status(String owner) =>
      rust.configurationSyncStatus(owner: owner);
  @override
  Future<String> reserve(String owner) =>
      rust.reserveConfigurationSync(owner: owner);
  @override
  Future<String> prepare(String owner, String operation) =>
      rust.prepareConfigurationSync(owner: owner, operation: operation);
  @override
  Future<String> confirm(String owner, String operation, String review) =>
      rust.confirmConfigurationSync(
        owner: owner,
        operation: operation,
        review: review,
      );
  @override
  Future<void> cancel(String owner, String operation) =>
      rust.cancelConfigurationSync(owner: owner, operation: operation);
  @override
  Future<void> close(String owner) => rust.closeConfigurationSync(owner: owner);
  @override
  Future<String> referenceChoices(
    String owner,
    String operation,
    String review,
  ) => rust.configurationSyncReferenceChoices(
    owner: owner,
    operation: operation,
    review: review,
  );
  @override
  Future<String> resolveReferences(
    String owner,
    String operation,
    String review,
    List<Map<String, String>> choices,
  ) => rust.resolveConfigurationSyncReferences(
    owner: owner,
    operation: operation,
    review: review,
    choices: jsonEncode(choices),
  );
}

/// Owned by the application, independent of a settings route or terminal view.
/// One-shot debounce only after an actual edit event; no startup/idle polling.
class ConfigurationSyncController extends ChangeNotifier {
  ConfigurationSyncController({
    this.gateway = const NativeConfigurationSyncGateway(),
    this.onCommitted,
  });
  final ConfigurationSyncGateway gateway;
  final Future<void> Function()? onCommitted;
  ConfigurationSyncState? state;
  String? error;
  String? _owner, _operation;
  StreamSubscription<String>? _subscription;
  Completer<void>? _streamDone;
  Future<void>? _starting, _work, _cancellation, _refresh, _shutdown;
  Timer? _debounce;
  bool _closing = false,
      _disposed = false,
      _pendingAuto = false,
      _faulted = false,
      _reloadWanted = false;
  bool _opening = false;
  int _editEpoch = 0, _commits = 0;
  bool get busy => _work != null || _cancellation != null || _opening;
  bool get available => !_closing && !_disposed && !_faulted && _owner != null;
  bool get canRetryStart => !_closing && !_disposed && !busy && _owner == null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _accept(String json) {
    final next = ConfigurationSyncState(
      jsonDecode(json) as Map<String, dynamic>,
    );
    if (_owner != next.owner ||
        state?.owner == next.owner && next.sequence < state!.sequence) {
      return;
    }
    if (state?.sequence == next.sequence && state?.owner == next.owner) return;
    final disabled = state?.eligible == true && !next.eligible;
    state = next;
    if (next.active) {
      _operation = next.operation;
    } else if (next.operation == _operation) {
      _operation = null;
    }
    if (!next.eligible) {
      _pendingAuto = false;
      _debounce?.cancel();
      _debounce = null;
      if (disabled) {
        _editEpoch++;
        if (_operation != null) {
          unawaited(
            _cancelNative().catchError((Object _) {
              error = '同步停用后的取消尚未确认；不会启动新的同步请求。';
              _notify();
            }),
          );
        }
      }
    }
    if (next.configurationUpdates > _commits) {
      _commits = next.configurationUpdates;
      _reloadWanted = true;
      _refresh ??= () async {
        try {
          while (_reloadWanted && !_closing) {
            _reloadWanted = false;
            await onCommitted?.call();
          }
        } catch (_) {
          error = '同步已提交，但界面配置刷新失败；请重新载入，不要重复应用旧结果。';
        } finally {
          _refresh = null;
          _notify();
        }
      }();
    }
    _notify();
  }

  void _event(String json) {
    if (_closing || _disposed || _faulted) return;
    try {
      final value = jsonDecode(json) as Map<String, dynamic>;
      if (value['kind'] == 'state') {
        _accept(jsonEncode(value['value']));
        return;
      }
      if (value['kind'] == 'configurationEdited' &&
          value['owner'] == _owner &&
          value['vault_scope'] == state?.scope) {
        _editEpoch++;
        _pendingAuto = true;
        if (_operation != null) {
          unawaited(
            _cancelNative().catchError((Object _) {
              error = '同步取消尚未确认';
              _notify();
            }),
          );
        }
        _schedule();
      }
    } catch (_) {
      _faulted = true;
      error = '同步事件格式不支持，已停止自动同步；请重新打开配置库。';
      _debounce?.cancel();
      _pendingAuto = false;
      unawaited(_cancelNative().catchError((Object _) {}));
      _notify();
    }
  }

  Future<void> start() => _starting ??= () async {
    if (_closing || _disposed) return;
    _opening = true;
    _notify();
    try {
      final owner = await gateway.open();
      if (_closing || _disposed) {
        await gateway.close(owner);
        return;
      }
      _owner = owner;
      state = null;
      _commits = 0;
      _faulted = false;
      _streamDone = Completer<void>();
      _subscription = gateway
          .events(owner)
          .listen(
            _event,
            onError: (Object _) {
              _faulted = true;
              error = '同步状态通道中断；请重新打开配置库。';
              _pendingAuto = false;
              _debounce?.cancel();
              unawaited(_cancelNative().catchError((Object _) {}));
              _notify();
            },
            onDone: () {
              if (!(_streamDone?.isCompleted ?? true)) _streamDone!.complete();
            },
          );
      _accept(await gateway.status(owner));
    } catch (_) {
      error = '无法初始化同步状态；SSH 终端仍可使用。';
      final owner = _owner;
      if (owner != null) {
        try {
          await gateway.close(owner);
          if (_subscription != null) {
            await _streamDone!.future.timeout(const Duration(seconds: 10));
          }
          await _subscription?.cancel();
          _subscription = null;
          _owner = null;
          _operation = null;
        } catch (_) {
          _faulted = true;
          error = '同步初始化和资源释放未确认，请重新打开配置库；SSH 终端仍可使用。';
        }
      }
      _notify();
    } finally {
      _opening = false;
      _notify();
      _schedule();
    }
  }();

  /// Retry a failed metadata-only initialization after the user fixes a local
  /// target. This never abandons an existing owner or starts an HTTP operation.
  Future<void> retryStart() {
    if (!canRetryStart) return Future.value();
    _starting = null;
    _faulted = false;
    error = null;
    return start();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = null;
    if (_closing ||
        _disposed ||
        _faulted ||
        busy ||
        !_pendingAuto ||
        state?.eligible != true) {
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 750), () {
      _debounce = null;
      if (!_closing &&
          !_disposed &&
          !_faulted &&
          !busy &&
          _pendingAuto &&
          state?.eligible == true) {
        unawaited(_synchronize(automatic: true));
      }
    });
  }

  Future<void> _run(Future<void> Function() action) {
    if (!available || busy) return Future.value();
    final done = Completer<void>();
    _work = done.future;
    error = null;
    _notify();
    unawaited(() async {
      try {
        await action();
      } catch (_) {
        error = '同步请求未完成；请查看状态后明确重试。';
        final owner = _owner;
        if (owner != null && !_closing) {
          try {
            _accept(await gateway.status(owner));
          } catch (_) {
            error = '无法读取同步结果；请保留本机数据并重新打开配置库。';
          }
        }
        if (state?.phase == 'cancelled') error = null;
      } finally {
        try {
          await _cancellation;
        } catch (_) {
          error = '同步取消尚未确认，请保留当前会话后重试。';
        }
        _work = null;
        _notify();
        done.complete();
        _schedule();
      }
    }());
    return done.future;
  }

  Future<void> synchronize() => _synchronize(automatic: false);
  Future<void> _synchronize({required bool automatic}) => _run(() async {
    if (automatic && state?.eligible != true) return;
    final owner = _owner!;
    final epoch = _editEpoch;
    _pendingAuto = false;
    _debounce?.cancel();
    _debounce = null;
    final existing = _operation;
    if (existing != null) {
      await gateway.cancel(owner, existing);
      _operation = null;
    }
    final operation = await gateway.reserve(owner);
    _operation = operation;
    if (_closing || epoch != _editEpoch) {
      await gateway.cancel(owner, operation);
      return;
    }
    _accept(await gateway.prepare(owner, operation));
    while (automatic &&
        !_closing &&
        epoch == _editEpoch &&
        state?.phase == 'review' &&
        state?.operation == operation &&
        !state!.review!.needsConsent) {
      final review = state!.review!.token;
      _accept(await gateway.confirm(owner, operation, review));
    }
  });
  Future<void> confirm(ConfigurationSyncState original) => _run(() async {
    if (state?.owner != original.owner ||
        state?.operation != original.operation ||
        state?.review?.token != original.review?.token ||
        original.review == null ||
        original.review!.references) {
      return;
    }
    _accept(
      await gateway.confirm(
        original.owner,
        original.operation!,
        original.review!.token,
      ),
    );
  });
  bool _sameReview(ConfigurationSyncState original) =>
      available &&
      !_closing &&
      original.phase == 'references' &&
      state?.owner == original.owner &&
      state?.operation == original.operation &&
      state?.review?.token == original.review?.token;
  Future<List<SyncReferenceChoice>> loadReferenceChoices(
    ConfigurationSyncState original,
  ) async {
    List<SyncReferenceChoice>? choices;
    await _run(() async {
      if (!_sameReview(original)) return;
      final value = await gateway.referenceChoices(
        original.owner,
        original.operation!,
        original.review!.token,
      );
      final decoded = await compute(parseSyncReferences, value);
      if (_sameReview(original)) choices = decoded;
    });
    return choices ?? (throw StateError('原引用候选已改变或读取失败'));
  }

  Future<void> resolveReferences(
    ConfigurationSyncState original,
    Map<String, String> choices,
  ) => _run(() async {
    if (!_sameReview(original) ||
        choices.isEmpty ||
        choices.length > 24000 ||
        choices.values.any((s) => !{'local', 'remote'}.contains(s))) {
      return;
    }
    final input = [
      for (final entry in choices.entries)
        {'id': entry.key, 'side': entry.value},
    ];
    _accept(
      await gateway.resolveReferences(
        original.owner,
        original.operation!,
        original.review!.token,
        input,
      ),
    );
  });
  Future<void> _cancelNative() {
    final current = _cancellation;
    if (current != null) return current;
    final done = Completer<void>();
    _cancellation = done.future;
    final owner = _owner, operation = _operation;
    unawaited(() async {
      try {
        if (owner != null && operation != null) {
          await gateway.cancel(owner, operation);
        }
        done.complete();
      } catch (e, s) {
        done.completeError(e, s);
      } finally {
        _cancellation = null;
        _notify();
        if (_work == null) _schedule();
      }
    }());
    return done.future;
  }

  Future<void> cancel() async {
    _pendingAuto = false;
    _debounce?.cancel();
    _debounce = null;
    await _cancelNative();
    await _work;
    final owner = _owner;
    if (owner != null && !_closing) {
      try {
        _accept(await gateway.status(owner));
      } catch (_) {
        error = '无法读取取消结果';
        _notify();
      }
    }
  }

  Future<void> shutdown() => _shutdown ??= () async {
    _closing = true;
    _pendingAuto = false;
    _debounce?.cancel();
    _debounce = null;
    _notify();
    await _starting;
    await _cancelNative();
    await _work;
    await _refresh;
    final owner = _owner;
    if (owner != null) {
      await gateway.close(owner);
      if (_subscription != null) {
        await _streamDone!.future.timeout(const Duration(seconds: 10));
      }
    }
    await _subscription?.cancel();
    _subscription = null;
    _owner = null;
    _operation = null;
  }();
  void resumeAfterCancelledShutdown() {
    _closing = false;
    _shutdown = null;
    if (_owner == null) {
      _starting = null;
      unawaited(start());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}

String syncFailureLabel(ConfigurationSyncState? state) {
  if (state?.writeUnknown == true) return '云端写入结果未确认；下次必须重新读取，不能盲目重发。';
  if (state?.authorizationUnknown == true) {
    return 'Google 令牌刷新结果未确认；本机凭据保留，若已失效请重新授权。配置同步未确认完成。';
  }
  if (state?.remotePublished == true && state?.phase != 'committed') {
    return '云端写入已确认，本机新修改仍保留；请再次同步以合并。';
  }
  return switch (state?.error) {
    'source_changed' => '配置或同步目标已改变，旧候选未应用。',
    'references' => '两端的分组或跳板引用冲突；请调整相关配置后重新同步。',
    'clock' => '设备时钟异常，请校准后重试。',
    'capacity' => '同步数据超过容量限制，两端数据均保留。',
    'data' => '同步密码、集合标识或数据版本不匹配，未应用。',
    'denied' => '同步服务器拒绝访问，请检查已保存认证。',
    'authorization' => 'Google Drive 本机授权缺失、已撤销或与目标绑定不一致；请重新授权并明确配置目标。',
    'authorization_busy' => '另一个 Google Drive 账号操作尚未结束；结束后请手动重试同步。',
    'network' => '同步网络、TLS 或服务器响应失败。',
    'cancelled' => '本次同步已取消。',
    _ => '同步未完成，请检查配置后手动重试。',
  };
}
