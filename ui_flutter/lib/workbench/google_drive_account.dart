import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../src/rust/api.dart' as rust;

/// Local authorization metadata, never tokens, browser credentials or profile.
class GoogleDriveAccount {
  GoogleDriveAccount(Map<String, dynamic> value)
    : scope = value['vault_scope'] as String,
      revision = value['revision'] as String,
      clientId = value['client_id'] as String?,
      authorizationId = value['authorization_id'] as String? {
    if (value.length != 4 ||
        !value.keys.toSet().containsAll({
          'vault_scope',
          'revision',
          'client_id',
          'authorization_id',
        }) ||
        scope.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision) ||
        (clientId == null) != (authorizationId == null) ||
        authorizationId != null &&
            !RegExp(r'^[a-f0-9]{32}$').hasMatch(authorizationId!) ||
        clientId != null && !validDesktopClientId(clientId!)) {
      throw const FormatException('Google Drive 授权元数据无效');
    }
  }
  final String scope, revision;
  final String? clientId, authorizationId;
  bool get authorized => authorizationId != null;
}

bool validDesktopClientId(String id) =>
    id.length <= 256 &&
    RegExp(r'^[A-Za-z0-9.-]+\.apps\.googleusercontent\.com$').hasMatch(id);

bool _browserAuthorization(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host != 'accounts.google.com' ||
      uri.port != 443 ||
      uri.path != '/o/oauth2/v2/auth' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return false;
  }
  final p = uri.queryParametersAll;
  if (p.length != 9 ||
      p.values.any((v) => v.length != 1) ||
      p['scope']?.single != 'https://www.googleapis.com/auth/drive.appdata' ||
      p['response_type']?.single != 'code' ||
      p['code_challenge_method']?.single != 'S256' ||
      p['access_type']?.single != 'offline' ||
      p['prompt']?.single != 'consent select_account' ||
      !validDesktopClientId(p['client_id']?.single ?? '') ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(p['state']?.single ?? '') ||
      !RegExp(r'^[A-Za-z0-9_-]{43}$')
          .hasMatch(p['code_challenge']?.single ?? '')) {
    return false;
  }
  final callback = Uri.tryParse(p['redirect_uri']?.single ?? '');
  return callback != null &&
      callback.scheme == 'http' &&
      callback.host == '127.0.0.1' &&
      callback.port > 0 &&
      callback.path == '/oauth2/callback' &&
      callback.userInfo.isEmpty &&
      !callback.hasQuery &&
      !callback.hasFragment;
}

abstract interface class GoogleDriveAccountGateway {
  Future<String> load();
  Future<String> reserve(Map<String, dynamic> input);
  Future<String> prepare(String operation);
  Future<String> finish(String operation);
  Future<String> reserveRemoval(
    GoogleDriveAccount source, {
    required bool revoke,
  });
  Future<String> remove(String operation);
  Future<String> cancel(String operation);
}

class NativeGoogleDriveAccountGateway implements GoogleDriveAccountGateway {
  const NativeGoogleDriveAccountGateway();
  @override
  Future<String> load() => rust.loadGoogleDriveAccount();
  @override
  Future<String> reserve(Map<String, dynamic> input) =>
      rust.reserveGoogleDriveAuthorization(input: jsonEncode(input));
  @override
  Future<String> prepare(String operation) =>
      rust.prepareGoogleDriveAuthorization(operation: operation);
  @override
  Future<String> finish(String operation) =>
      rust.finishGoogleDriveAuthorization(operation: operation);
  @override
  Future<String> reserveRemoval(
    GoogleDriveAccount source, {
    required bool revoke,
  }) => rust.reserveGoogleDriveAccountRemoval(
    vaultScope: source.scope,
    revision: source.revision,
    revoke: revoke,
  );
  @override
  Future<String> remove(String operation) =>
      rust.removeGoogleDriveAccount(operation: operation);
  @override
  Future<String> cancel(String operation) =>
      rust.cancelGoogleDriveAuthorization(operation: operation);
}

/// Owned by the real application, not a settings route. Opening a panel reads
/// metadata only. There is no refresh/polling timer or startup authorization.
class GoogleDriveAccountController extends ChangeNotifier {
  GoogleDriveAccountController({
    this.gateway = const NativeGoogleDriveAccountGateway(),
    Future<bool> Function(Uri)? browser,
  }) : _browser =
           browser ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));
  final GoogleDriveAccountGateway gateway;
  final Future<bool> Function(Uri) _browser;
  GoogleDriveAccount? account;
  String? error, notice;
  String? _operation;
  Future<void>? _work, _cancelling, _shutdown;
  bool _closing = false, _disposed = false, _cancelWanted = false;
  bool get busy => _work != null || _cancelling != null;
  bool get available => !_closing && !_disposed;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _adopt(String value) {
    account = GoogleDriveAccount(jsonDecode(value) as Map<String, dynamic>);
  }

  bool _source(GoogleDriveAccount source) =>
      available &&
      source.scope == account?.scope &&
      source.revision == account?.revision;

  /// Metadata ACK from the original serialized Drive operation. No credential
  /// is accepted here; native source/CAS checks remain authoritative.
  bool adoptOperationMetadata(
    GoogleDriveAccount source,
    GoogleDriveAccount next,
  ) {
    if (!_source(source) ||
        busy ||
        source.scope != next.scope ||
        source.clientId != next.clientId ||
        source.authorizationId != next.authorizationId) {
      return false;
    }
    account = next;
    _notify();
    return true;
  }

  Future<void> _run(Future<void> Function() action) {
    if (!available || busy) return Future.value();
    final done = Completer<void>();
    _work = done.future;
    _cancelWanted = false;
    error = notice = null;
    _notify();
    unawaited(() async {
      try {
        await action();
      } catch (_) {
        // No raw OAuth exception, callback URL, client secret or HTTP body in
        // the UI model, diagnostic text, logs or native error details.
        if (!_cancelWanted && !_closing) {
          error = 'Google Drive 操作未完成。原授权可能已过期、被拒绝或源配置改变；请重新读取本机状态。';
        }
      } finally {
        try {
          await _cancelOperation();
        } catch (_) {
          error = '授权操作释放失败；请关闭应用后重试。';
        }
        _operation = null;
        _work = null;
        done.complete();
        _notify();
      }
    }());
    return done.future;
  }

  Future<void> load() => _run(() async {
    final value = await gateway.load();
    if (!_closing) _adopt(value);
  });
  Future<void> authorize({
    required GoogleDriveAccount source,
    required String clientId,
    required String clientSecret,
    required bool confirmReplace,
  }) {
    if (!_source(source) ||
        !validDesktopClientId(clientId) ||
        source.authorized && !confirmReplace) {
      return Future.value();
    }
    return _run(() async {
      final input = <String, dynamic>{
        'vault_scope': source.scope,
        'revision': source.revision,
        'client_id': clientId,
        'client_secret': clientSecret,
        'confirm_replace': confirmReplace,
      };
      try {
        _operation = await gateway.reserve(input);
      } finally {
        input.clear();
      }
      if (_cancelWanted || _closing) return;
      final url = Uri.parse(await gateway.prepare(_operation!));
      if (_cancelWanted || _closing) return;
      if (!_browserAuthorization(url) ||
          url.queryParameters['client_id'] != clientId) {
        throw const FormatException('授权浏览器地址无效');
      }
      if (!await _browser(url)) throw StateError('系统浏览器未打开');
      if (_cancelWanted || _closing) return;
      notice = '请在系统浏览器选择账号并授权；等待期间可以取消。';
      _notify();
      final saved = await gateway.finish(_operation!);
      // An acknowledged save remains a save, even if route shutdown/cancel
      // began after SQL completed. Cancellation must never request a replay.
      _adopt(saved);
      notice = 'Google Drive 本机授权已加密保存。授权不会上传配置。';
    });
  }

  Future<void> remove(GoogleDriveAccount source, {required bool revoke}) {
    if (!_source(source) || !source.authorized) return Future.value();
    return _run(() async {
      _operation = await gateway.reserveRemoval(source, revoke: revoke);
      if (_cancelWanted || _closing) return;
      final saved = await gateway.remove(_operation!);
      _adopt(saved);
      notice = revoke ? 'Google 已确认撤销；本机授权已移除。' : '仅移除了本机授权，Google 端访问授权未撤销。';
    });
  }

  Future<void> _cancelOperation() {
    final active = _cancelling;
    if (active != null) return active;
    final id = _operation;
    if (id == null) return Future.value();
    final done = Completer<void>();
    _cancelling = done.future;
    unawaited(() async {
      try {
        final result = await gateway.cancel(id);
        if (result == 'revoke_unknown') {
          error = 'Google 撤销结果未确认；本机凭据保持原状，请重新读取状态，不要当作撤销成功。';
        } else if (result == 'revoked' && account?.authorized == true) {
          notice = 'Google 已确认撤销，但本机账号可能尚未移除；请重新读取状态。';
        }
        done.complete();
      } catch (e, stack) {
        done.completeError(e, stack);
      } finally {
        _cancelling = null;
        _notify();
      }
    }());
    return done.future;
  }

  Future<void> cancel() async {
    _cancelWanted = true;
    await _cancelOperation();
    // reserve may still be running before it has returned the original ID;
    // _run's finally will cancel that ID when it arrives. Do not lose it.
    await _work;
  }

  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    _closing = true;
    return _shutdown = cancel();
  }

  void resumeAfterCancelledShutdown() {
    if (_disposed) return;
    _closing = false;
    _shutdown = null;
    _cancelWanted = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown().catchError((Object _) {}));
    super.dispose();
  }
}
