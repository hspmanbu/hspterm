import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as rust;
import 'configuration_sync_settings.dart';
import 'google_drive_account.dart';

class DriveConfigurationObject {
  DriveConfigurationObject(Map<String, dynamic> value)
    : id = value['id'] as String,
      collection = value['collection'] as String,
      bytes = value['bytes'] as int {
    if (value.length != 3 ||
        !value.keys.toSet().containsAll({'id', 'collection', 'bytes'}) ||
        id.isEmpty ||
        id.length > 256 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id) ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(collection) ||
        bytes < 0) {
      throw const FormatException('Drive 配置对象元数据无效');
    }
  }
  final String id, collection;
  final int bytes;
}

class DriveDiscovery {
  DriveDiscovery(Map<String, dynamic> value)
    : operation = value['operation'] as String,
      account = GoogleDriveAccount(value['account'] as Map<String, dynamic>),
      settings = ConfigurationSyncSettings(
        value['settings'] as Map<String, dynamic>,
      ),
      objects = List.unmodifiable(
        (value['objects'] as List).map(
          (v) => DriveConfigurationObject(v as Map<String, dynamic>),
        ),
      ) {
    if (value.length != 4 ||
        !value.keys.toSet().containsAll({
          'operation',
          'account',
          'settings',
          'objects',
        }) ||
        !RegExp(r'^drive-authorization-[a-f0-9]{32}$').hasMatch(operation) ||
        !account.authorized ||
        account.scope != settings.scope ||
        objects.length > 512 ||
        objects.map((o) => o.id).toSet().length != objects.length) {
      throw const FormatException('Drive 发现票据无效');
    }
  }
  final String operation;
  final GoogleDriveAccount account;
  final ConfigurationSyncSettings settings;
  final List<DriveConfigurationObject> objects;
  bool sameTarget(DriveConfigurationObject object) {
    final target = settings.target;
    final binding = target?['drive'] as Map<String, dynamic>?;
    return binding?['file_id'] == object.id &&
        binding?['client_id'] == account.clientId &&
        target?['collection'] == object.collection;
  }
}

class DriveCreation {
  DriveCreation(Map<String, dynamic> value)
    : scope = value['vault_scope'] as String,
      revision = value['revision'] as String,
      id = value['id'] as String,
      collection = value['collection'] as String,
      clientId = value['client_id'] as String,
      authorizationId = value['authorization_id'] as String,
      bytes = value['bytes'] as int,
      units = value['units'] as int,
      enabled = value['enabled'] as bool,
      attempted = value['attempted'] as bool {
    if (value.length != 10 ||
        !value.keys.toSet().containsAll({
          'vault_scope',
          'revision',
          'id',
          'collection',
          'client_id',
          'authorization_id',
          'bytes',
          'units',
          'enabled',
          'attempted',
        }) ||
        scope.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision) ||
        id.isEmpty ||
        id.length > 256 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id) ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(collection) ||
        !validDesktopClientId(clientId) ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(authorizationId) ||
        bytes < 1 ||
        units < 0 ||
        units > 24000) {
      throw const FormatException('Drive 创建恢复元数据无效');
    }
  }
  final String scope, revision, id, collection, clientId, authorizationId;
  final int bytes, units;
  final bool enabled, attempted;
}

abstract interface class GoogleDriveObjectsGateway {
  Future<String> reserve(GoogleDriveAccount source);
  Future<String> discover(String operation);
  Future<String> select(String operation, Map<String, dynamic> input);
  Future<String> cancel(String operation);
  Future<String> pendingCreation();
  Future<String> reserveCreation(
    GoogleDriveAccount account,
    DriveCreation creation,
  );
  Future<String> prepareCreation(String operation, Map<String, dynamic> input);
  Future<String> finishCreation(String operation);
  Future<void> discardCreation(DriveCreation source);
}

class NativeGoogleDriveObjectsGateway implements GoogleDriveObjectsGateway {
  const NativeGoogleDriveObjectsGateway();
  @override
  Future<String> reserve(GoogleDriveAccount source) =>
      rust.reserveGoogleDriveObjectDiscovery(
        vaultScope: source.scope,
        revision: source.revision,
      );
  @override
  Future<String> discover(String operation) =>
      rust.discoverGoogleDriveObjects(operation: operation);
  @override
  Future<String> select(String operation, Map<String, dynamic> input) => rust
      .selectGoogleDriveObject(operation: operation, input: jsonEncode(input));
  @override
  Future<String> cancel(String operation) =>
      rust.cancelGoogleDriveAuthorization(operation: operation);
  @override
  Future<String> pendingCreation() => rust.pendingGoogleDriveCreation();
  @override
  Future<String> reserveCreation(
    GoogleDriveAccount account,
    DriveCreation creation,
  ) => rust.reserveGoogleDriveCreation(
    vaultScope: creation.scope,
    accountRevision: account.revision,
    creationRevision: creation.revision,
  );
  @override
  Future<String> prepareCreation(
    String operation,
    Map<String, dynamic> input,
  ) => rust.prepareGoogleDriveCreation(
    operation: operation,
    input: jsonEncode(input),
  );
  @override
  Future<String> finishCreation(String operation) =>
      rust.finishGoogleDriveCreation(operation: operation);
  @override
  Future<void> discardCreation(DriveCreation source) =>
      rust.discardGoogleDriveCreation(
        vaultScope: source.scope,
        revision: source.revision,
        confirmLocalOnly: true,
      );
}

/// App-owned, not route-owned. A live selection holds one original Native
/// capability; closing the page cannot orphan a refresh or a SQLite worker.
class GoogleDriveObjectsController extends ChangeNotifier {
  GoogleDriveObjectsController({
    required this.accounts,
    this.gateway = const NativeGoogleDriveObjectsGateway(),
  });
  final GoogleDriveAccountController accounts;
  final GoogleDriveObjectsGateway gateway;
  DriveDiscovery? discovery;
  DriveCreation? creation;
  ConfigurationSyncSettings? saved;
  String? error, notice, _operation;
  Future<void>? _work, _cancelling, _shutdown;
  bool _closing = false, _disposed = false, _cancelWanted = false;
  bool get busy => _work != null || _cancelling != null;
  bool get available => !_closing && !_disposed;
  bool get selecting => discovery != null && _operation == discovery!.operation;
  bool get canDiscover => available && !busy && _operation == null;
  bool get hasOperation => _operation != null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _run(Future<bool> Function() action) {
    if (!available || busy) return Future.value();
    final done = Completer<void>();
    _work = done.future;
    _cancelWanted = false;
    error = notice = null;
    _notify();
    unawaited(() async {
      bool keep = false;
      try {
        keep = await action();
      } catch (_) {
        discovery = null;
        if (!_cancelWanted && !_closing) {
          error = 'Drive 操作未确认。账号、目标或票据可能已改变；请读取本机状态后重新发现，不要重放旧选择。';
        }
      } finally {
        if (!keep || _closing || _cancelWanted) {
          discovery = null;
          try {
            await _cancelOperation();
          } catch (_) {
            error = 'Drive 操作释放失败；请关闭应用后重试。';
          }
        }
        _work = null;
        done.complete();
        _notify();
      }
    }());
    return done.future;
  }

  Future<void> discover(GoogleDriveAccount source) {
    if (!canDiscover ||
        accounts.busy ||
        !accounts.available ||
        !source.authorized ||
        accounts.account?.scope != source.scope ||
        accounts.account?.revision != source.revision) {
      return Future.value();
    }
    return _run(() async {
      _operation = await gateway.reserve(source);
      if (_cancelWanted || _closing) return false;
      final result = DriveDiscovery(
        jsonDecode(await gateway.discover(_operation!)) as Map<String, dynamic>,
      );
      if (_cancelWanted || _closing) return false;
      if (result.operation != _operation ||
          result.account.scope != source.scope ||
          result.account.clientId != source.clientId ||
          result.account.authorizationId != source.authorizationId) {
        throw const FormatException('Drive 发现来源已改变');
      }
      if (!accounts.adoptOperationMetadata(source, result.account)) {
        throw StateError('本机账号来源已改变');
      }
      discovery = result;
      notice = result.objects.isEmpty
          ? '未发现本应用的配置对象；未创建或上传文件。'
          : '已完整读取配置对象元数据。请选择明确的对象；不会自动选择同集合中的任意文件。';
      return true;
    });
  }

  Future<void> select(
    DriveDiscovery source,
    DriveConfigurationObject object, {
    required bool enabled,
    required String? password,
    required bool confirmTargetChange,
  }) {
    if (!identical(discovery, source) ||
        !selecting ||
        !source.objects.contains(object) ||
        accounts.account?.scope != source.account.scope ||
        accounts.account?.revision != source.account.revision ||
        (!source.sameTarget(object) &&
            (password == null || password.isEmpty))) {
      return Future.value();
    }
    return _run(() async {
      final input = <String, dynamic>{
        'id': object.id,
        'enabled': enabled,
        'sync_password': password?.trim(),
        'confirm_target_change': confirmTargetChange,
      };
      late String value;
      try {
        value = await gateway.select(source.operation, input);
      } finally {
        input.clear();
      }
      // A confirmed SQL ACK remains a save even if exit began afterwards.
      final acknowledged = ConfigurationSyncSettings(
        jsonDecode(value) as Map<String, dynamic>,
      );
      final binding = acknowledged.target?['drive'] as Map<String, dynamic>?;
      if (acknowledged.scope != source.settings.scope ||
          binding?['file_id'] != object.id ||
          binding?['client_id'] != source.account.clientId ||
          binding?['authorization_id'] != source.account.authorizationId ||
          acknowledged.target?['collection'] != object.collection ||
          acknowledged.target?['enabled'] != enabled) {
        throw const FormatException('Drive 目标保存回执无效，请重新读取本机设置');
      }
      saved = acknowledged;
      discovery = null;
      notice = 'Drive 目标已加密保存；本次没有上传配置。启用后仅配置变更或手动操作触发同步。';
      return false;
    });
  }

  Future<void> loadCreation() {
    if (!canDiscover) return Future.value();
    return _run(() async {
      final value = jsonDecode(await gateway.pendingCreation());
      creation = value == null
          ? null
          : DriveCreation(value as Map<String, dynamic>);
      return false;
    });
  }

  Future<void> prepareNew(
    DriveDiscovery source, {
    required String password,
    required bool enabled,
    required bool confirmTargetChange,
    required bool confirmSensitiveUpload,
  }) {
    if (!identical(source, discovery) ||
        !selecting ||
        creation != null ||
        password.trim().isEmpty ||
        utf8.encode(password).length > 4096 ||
        !confirmSensitiveUpload ||
        accounts.account?.scope != source.account.scope ||
        accounts.account?.revision != source.account.revision) {
      return Future.value();
    }
    return _run(() async {
      final input = <String, dynamic>{
        'password': password.trim(),
        'enabled': enabled,
        'confirm_target_change': confirmTargetChange,
        'confirm_sensitive_upload': confirmSensitiveUpload,
      };
      late Map<String, dynamic> value;
      try {
        value = jsonDecode(
          await gateway.prepareCreation(source.operation, input),
        ) as Map<String, dynamic>;
      } finally {
        input.clear();
      }
      if (_cancelWanted || _closing) return false;
      final pending = DriveCreation(value['creation'] as Map<String, dynamic>);
      final next = GoogleDriveAccount(value['account'] as Map<String, dynamic>);
      if (value.length != 3 ||
          value['operation'] != _operation ||
          pending.scope != source.account.scope ||
          pending.clientId != source.account.clientId ||
          pending.authorizationId != source.account.authorizationId ||
          !accounts.adoptOperationMetadata(source.account, next)) {
        throw const FormatException('Drive 新集合来源已改变');
      }
      creation = pending;
      discovery = null;
      notice = '初始快照和唯一对象 ID 已在本机加密保存，尚未上传。请核对后明确开始；取消后可读取原创建记录继续。';
      return true;
    });
  }

  Future<void> finishCreation(DriveCreation source) {
    final account = accounts.account;
    if (!identical(creation, source) ||
        !available ||
        busy ||
        account == null ||
        accounts.busy ||
        account.scope != source.scope ||
        account.clientId != source.clientId ||
        account.authorizationId != source.authorizationId) {
      return Future.value();
    }
    return _run(() async {
      _operation ??= await gateway.reserveCreation(account, source);
      if (_cancelWanted || _closing) return false;
      final acknowledged = ConfigurationSyncSettings(
        jsonDecode(await gateway.finishCreation(_operation!))
            as Map<String, dynamic>,
      );
      final binding = acknowledged.target?['drive'] as Map<String, dynamic>?;
      if (acknowledged.scope != source.scope ||
          binding?['file_id'] != source.id ||
          binding?['client_id'] != source.clientId ||
          binding?['authorization_id'] != source.authorizationId ||
          acknowledged.target?['collection'] != source.collection ||
          acknowledged.target?['enabled'] != source.enabled) {
        throw const FormatException('Drive 创建回执无效，请核对原ID');
      }
      saved = acknowledged;
      creation = null;
      discovery = null;
      notice = '原 ID 的完整加密对象已确认，唯一目标已保存，本机创建记录已原子退休。后续仍按配置变更或手动操作同步。';
      if (!_closing && accounts.available) await accounts.load();
      return false;
    });
  }

  Future<void> discardCreation(DriveCreation source) async {
    if (!identical(creation, source) || !available || busy) return;
    await cancel();
    if (!available) return;
    await _run(() async {
      await gateway.discardCreation(source);
      if (identical(creation, source)) creation = null;
      notice = '仅删除本机创建恢复记录；可能存在的远端对象未删除。后续请明确发现并选择原 ID。';
      return false;
    });
  }

  Future<void> _cancelOperation() {
    if (_cancelling != null) return _cancelling!;
    final operation = _operation;
    if (operation == null) return Future.value();
    final done = Completer<void>();
    _cancelling = done.future;
    unawaited(() async {
      try {
        final result = await gateway.cancel(operation);
        if (result == 'authorization_unknown') {
          error = 'Google 刷新凭据结果未确认；本机原记录保留，但可能需要重新授权。配置未被当作同步成功。';
        }
        if (result == 'staged') notice = '新集合初始快照已在本机加密保存，未确认远端写入；请读取原创建记录后继续。';
        if (result == 'create_unknown') {
          error = '远端创建结果未确认。原 ID 和确切加密正文仍在本机；请重新读取创建记录，核对同一 ID 后继续。不要新建替代对象。';
        }
        if (result == 'created') {
          notice = '原 ID 的远端对象已确认，但本机目标可能尚未保存。请读取原创建记录核对，不要新建替代对象。';
        }
        if (_operation == operation) _operation = null;
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
    discovery = null;
    _notify();
    await _cancelOperation();
    await _work;
  }

  Future<void> shutdown() {
    _closing = true;
    return _shutdown ??= cancel();
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
