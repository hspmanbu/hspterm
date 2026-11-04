import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as rust;

class ConfigurationDiff {
  ConfigurationDiff(Map<String, dynamic> v)
    : id = v['id'] as String,
      label = v['label'] as String,
      category = v['category'] as String,
      state = v['state'] as String,
      local = v['local_present'] as bool,
      incoming = v['incoming_present'] as bool,
      useIncoming = v['default_incoming'] as bool,
      sensitive = v['sensitive_change'] as bool,
      localSummary = v['local_summary'] as String?,
      incomingSummary = v['incoming_summary'] as String?;
  final String id, label, category, state;
  final bool local, incoming, useIncoming, sensitive;
  final String? localSummary, incomingSummary;
}

class ConfigurationPreview {
  ConfigurationPreview(Map<String, dynamic> v)
    : scope = v['vault_scope'] as String,
      revision = v['revision'] as String,
      mode = v['mode'] as String,
      localHosts = v['local_hosts'] as int,
      incomingHosts = v['incoming_hosts'] as int,
      items = List.unmodifiable(
        (v['items'] as List).cast<Map<String, dynamic>>().map(
          ConfigurationDiff.new,
        ),
      ) {
    if (items.length > 30000 ||
        items.map((i) => i.id).toSet().length != items.length ||
        !['merge', 'replace'].contains(mode)) {
      throw const FormatException('恢复预览无效');
    }
  }
  final String scope, revision, mode;
  final int localHosts, incomingHosts;
  final List<ConfigurationDiff> items;
}

class ConfigurationRestore {
  ConfigurationRestore(String json) {
    final v = jsonDecode(json) as Map<String, dynamic>;
    ticket = v['ticket'] as String;
    preview = ConfigurationPreview(v['preview'] as Map<String, dynamic>);
    if (ticket.isEmpty) throw const FormatException('缺少原生恢复票据');
  }
  late final String ticket;
  late final ConfigurationPreview preview;
}

abstract interface class ConfigurationBackupGateway {
  Future<ConfigurationPreview> summary();
  Future<void> export(
    ConfigurationPreview source,
    String path,
    String password,
    String backupPassword,
  );
  Future<ConfigurationRestore> prepare(
    String path,
    String password,
    String mode,
  );
  Future<ConfigurationRestore> repreview(String ticket, String mode);
  Future<void> apply(String ticket, List<String> incoming, String password);
  Future<void> cancel(String ticket);
}

class NativeConfigurationBackupGateway implements ConfigurationBackupGateway {
  const NativeConfigurationBackupGateway();
  @override
  Future<ConfigurationPreview> summary() async => ConfigurationPreview(
    jsonDecode(await rust.configurationBackupSummary()) as Map<String, dynamic>,
  );
  @override
  Future<void> export(
    ConfigurationPreview source,
    String path,
    String password,
    String backupPassword,
  ) => rust.exportConfigurationBackup(
    vaultScope: source.scope,
    revision: source.revision,
    path: path,
    password: password,
    backupPassword: backupPassword,
  );
  @override
  Future<ConfigurationRestore> prepare(
    String path,
    String password,
    String mode,
  ) async => ConfigurationRestore(
    await rust.prepareConfigurationRestore(
      path: path,
      password: password,
      mode: mode,
    ),
  );
  @override
  Future<ConfigurationRestore> repreview(String ticket, String mode) async =>
      ConfigurationRestore(
        await rust.previewConfigurationRestore(ticket: ticket, mode: mode),
      );
  @override
  Future<void> apply(
    String ticket,
    List<String> incoming,
    String password,
  ) async {
    final ack = jsonDecode(
      await rust.applyConfigurationRestore(
        ticket: ticket,
        useIncoming: incoming,
        password: password,
      ),
    ) as Map<String, dynamic>;
    if (ack['committed'] != true) throw StateError('原生层没有确认恢复已提交');
  }

  @override
  Future<void> cancel(String ticket) =>
      rust.cancelConfigurationRestore(ticket: ticket);
}

/// Owned by the workbench, not a modal route. Only metadata and selected opaque
/// item IDs live in Dart; passwords are passed once and never retained here.
class ConfigurationBackupController extends ChangeNotifier {
  ConfigurationBackupController({
    this.gateway = const NativeConfigurationBackupGateway(),
    required this.onRestored,
  });
  final ConfigurationBackupGateway gateway;
  final Future<void> Function() onRestored;
  ConfigurationPreview? summary;
  ConfigurationRestore? preview;
  Set<String> selectedIncoming = {};
  String? error, status;
  bool committed = false, _disposed = false, _closing = false;
  Object? _owner;
  Future<void>? _operation;
  final _retired = <String>{};
  bool get busy => _operation != null;
  bool get hasChanges =>
      preview?.preview.items.any(
        (i) => selectedIncoming.contains(i.id) && i.state != 'same',
      ) ??
      false;
  Object attach() => _owner = Object();
  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    final old = preview;
    preview = null;
    selectedIncoming = {};
    if (old != null) _retired.add(old.ticket);
    if (!busy && !_disposed && !_closing && _retired.isNotEmpty) {
      unawaited(_run(() async {}));
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void reportFailure(Object failure) {
    error = '$failure';
    _notify();
  }

  Future<void> _retire() async {
    for (final ticket in _retired.toList()) {
      await gateway.cancel(ticket);
      _retired.remove(ticket);
    }
  }

  Future<void> _run(Future<void> Function() action) {
    if (busy || _closing || _disposed) return Future.value();
    final done = Completer<void>();
    _operation = done.future;
    error = null;
    status = null;
    _notify();
    unawaited(() async {
      try {
        await action();
      } catch (failure) {
        error = '$failure';
      } finally {
        try {
          await _retire();
        } catch (failure) {
          error = '${error ?? ''}\n原生恢复预览尚未确认释放：$failure';
        }
        _operation = null;
        _notify();
        done.complete();
      }
    }());
    return done.future;
  }

  Future<void> load() => _run(() async {
    summary = null;
    summary = await gateway.summary();
  });
  Future<void> export(String path, String password, String backupPassword) =>
      _run(() async {
        final source = summary ?? (throw StateError('请先成功读取原配置，再导出备份'));
        await gateway.export(source, path, password, backupPassword);
        status = '完整加密备份已创建；原有同名文件不会被覆盖。';
      });
  Future<void> prepare(
    Object owner,
    String path,
    String password,
    String mode,
  ) => _run(() async {
    if (!identical(_owner, owner)) return;
    final old = preview;
    preview = null;
    selectedIncoming = {};
    if (old != null) {
      _retired.add(old.ticket);
      await _retire();
    }
    final result = await gateway.prepare(path, password, mode);
    if (!identical(_owner, owner) || _closing || _disposed) {
      _retired.add(result.ticket);
      return;
    }
    preview = result;
    selectedIncoming = {
      for (final i in result.preview.items)
        if (i.useIncoming) i.id,
    };
    committed = false;
    status = '备份已解密并验证；当前只预览，没有改动配置。';
  });
  Future<void> mode(Object owner, String mode) => _run(() async {
    final original = preview;
    if (!identical(_owner, owner) || original == null) return;
    final result = await gateway.repreview(original.ticket, mode);
    if (!identical(_owner, owner) ||
        !identical(preview, original) ||
        _closing) {
      _retired.add(result.ticket);
      return;
    }
    preview = result;
    selectedIncoming = {
      for (final i in result.preview.items)
        if (i.useIncoming) i.id,
    };
  });
  void select(String id, bool incoming) {
    if (busy ||
        _closing ||
        preview == null ||
        !preview!.preview.items.any((i) => i.id == id)) {
      return;
    }
    selectedIncoming = {...selectedIncoming};
    incoming ? selectedIncoming.add(id) : selectedIncoming.remove(id);
    _notify();
  }

  void selectAll(bool incoming) {
    if (busy || _closing || preview == null) return;
    selectedIncoming = incoming
        ? preview!.preview.items.map((i) => i.id).toSet()
        : {};
    _notify();
  }

  Future<void> apply(
    Object owner,
    ConfigurationRestore original,
    Set<String> selected,
    String password,
  ) => _run(() async {
    if (!identical(_owner, owner) ||
        !identical(preview, original) ||
        !setEquals(selected, selectedIncoming)) {
      throw StateError('原恢复选择已改变，请重新确认');
    }
    if (!hasChanges) throw StateError('当前选择没有需要恢复的配置变更');
    await gateway.apply(
      original.ticket,
      selected.toList(growable: false),
      password,
    );
    committed = true;
    preview = null;
    selectedIncoming = {};
    summary = null;
    status = '恢复已原子提交。已有 SSH 连接保持，旧确认及 Agent 授权已撤销。';
    try {
      await onRestored();
      summary = await gateway.summary();
    } catch (failure) {
      error = '恢复已经提交，但界面重新载入失败：$failure。请重新载入已恢复配置，不要重复应用备份。';
    }
  });
  Future<void> refreshCommitted() => _run(() async {
    await onRestored();
    summary = await gateway.summary();
    status = '已重新载入数据库中的配置，没有重复应用备份。';
  });
  Future<void> closePreview() => _run(() async {
    final old = preview;
    preview = null;
    selectedIncoming = {};
    if (old != null) _retired.add(old.ticket);
    status = '已关闭恢复预览；没有提交恢复。';
  });
  Future<void> shutdown() async {
    _closing = true;
    _owner = null;
    final pending = _operation;
    if (pending != null) await pending;
    final old = preview;
    preview = null;
    if (old != null) _retired.add(old.ticket);
    await _retire();
  }

  void resumeAfterCancelledShutdown() {
    if (!_disposed) _closing = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _owner = null;
    super.dispose();
  }
}
