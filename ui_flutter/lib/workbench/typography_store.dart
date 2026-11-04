import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../src/rust/api.dart' as rust;
import '../terminal/typography.dart';

const terminalFontLimit = 32 * 1024 * 1024;
const fontCatalogChannel = MethodChannel('hspterm/font_catalog');

class ImportedTerminalFont {
  const ImportedTerminalFont(this.id, this.label, this.bytes);
  final String id, label;
  final int bytes;
}

class TypographySnapshot {
  TypographySnapshot({
    required this.scope,
    required this.revision,
    required this.settings,
    this.fonts = const [],
    this.hosts = const {},
  });
  final String scope, revision;
  final TerminalTypography settings;
  final List<ImportedTerminalFont> fonts;
  final Map<String, TerminalTypography> hosts;
  factory TypographySnapshot.decode(String json) {
    final value = jsonDecode(json) as Map<String, dynamic>;
    final fonts = (value['fonts'] as List)
        .cast<Map<String, dynamic>>()
        .map((font) {
          final id = font['id'] as String,
              name = font['label'] as String,
              bytes = font['bytes'] as int;
          if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
              name.isEmpty ||
              bytes < 1 ||
              bytes > terminalFontLimit) {
            throw const FormatException('导入字体元数据无效');
          }
          return ImportedTerminalFont(id, name, bytes);
        })
        .toList(growable: false);
    final settings = TerminalTypography.fromJson(
      value['settings'] as Map<String, dynamic>,
    );
    final rawHosts = (value['hosts'] as Map<String, dynamic>?) ?? const {};
    if (rawHosts.length > 10000 ||
        rawHosts.keys.any(
          (id) => !RegExp(r'^host-[a-fA-F0-9]{32}$').hasMatch(id),
        )) {
      throw const FormatException('主机排版索引无效');
    }
    final hosts = rawHosts.map(
      (id, style) => MapEntry(
        id,
        TerminalTypography.fromJson(style as Map<String, dynamic>),
      ),
    );
    if (fonts.length > 8 ||
        fonts.map((f) => f.id).toSet().length != fonts.length ||
        [settings, ...hosts.values].any(
          (s) => s.kind == 'imported' && !fonts.any((f) => f.id == s.family),
        )) {
      throw const FormatException('导入字体索引无效');
    }
    return TypographySnapshot(
      scope: value['vault_scope'] as String,
      revision: value['revision'] as String,
      settings: settings,
      fonts: List.unmodifiable(fonts),
      hosts: Map.unmodifiable(hosts),
    );
  }
  String proposal(TerminalTypography value) => jsonEncode({
    'vault_scope': scope,
    'revision': revision,
    'settings': value.toJson(),
  });
}

abstract interface class HostTypographyGateway {
  Future<TypographySnapshot> saveHost(
    TypographySnapshot source,
    String hostId,
    TerminalTypography? value,
  );
}

abstract interface class TypographyGateway {
  Future<TypographySnapshot> load();
  Future<TypographySnapshot> save(
    TypographySnapshot source,
    TerminalTypography value,
  );
  Future<TypographySnapshot> importFont(
    TypographySnapshot source,
    String label,
    Uint8List bytes,
  );
  Future<TypographySnapshot> removeFont(TypographySnapshot source, String id);
  Future<Uint8List> fontBytes(TypographySnapshot source, String id);
  Future<List<String>> systemFamilies();
}

class NativeTypographyGateway
    implements TypographyGateway, HostTypographyGateway {
  const NativeTypographyGateway();
  @override
  Future<TypographySnapshot> saveHost(
    TypographySnapshot source,
    String hostId,
    TerminalTypography? value,
  ) async => compute(
    TypographySnapshot.decode,
    await rust.saveHostTerminalTypography(
      proposal: jsonEncode({
        'vault_scope': source.scope,
        'revision': source.revision,
        'host_id': hostId,
        'settings': value?.toJson(),
      }),
    ),
  );
  @override
  Future<TypographySnapshot> load() async =>
      compute(TypographySnapshot.decode, await rust.loadTerminalTypography());
  @override
  Future<TypographySnapshot> save(
    TypographySnapshot source,
    TerminalTypography value,
  ) async => compute(
    TypographySnapshot.decode,
    await rust.saveTerminalTypography(proposal: source.proposal(value)),
  );
  @override
  Future<TypographySnapshot> importFont(
    TypographySnapshot source,
    String label,
    Uint8List bytes,
  ) async => compute(
    TypographySnapshot.decode,
    await rust.importTerminalFont(
      vaultScope: source.scope,
      revision: source.revision,
      label: label,
      bytes: bytes,
    ),
  );
  @override
  Future<TypographySnapshot> removeFont(
    TypographySnapshot source,
    String id,
  ) async => compute(
    TypographySnapshot.decode,
    await rust.removeTerminalFont(
      vaultScope: source.scope,
      revision: source.revision,
      id: id,
    ),
  );
  @override
  Future<Uint8List> fontBytes(TypographySnapshot source, String id) =>
      rust.terminalFontBytes(
        vaultScope: source.scope,
        revision: source.revision,
        id: id,
      );
  @override
  Future<List<String>> systemFamilies() async {
    final names = await fontCatalogChannel.invokeListMethod<String>('families');
    if (names == null) throw StateError('平台未返回系统字体');
    return List.unmodifiable(
      names.where((s) => s.isNotEmpty && s.length <= 192).toSet().toList()
        ..sort(),
    );
  }
}

/// Flutter cannot unload a dynamically loaded font. A process-wide budget
/// limits successful AND failed load attempts, including after Vault switches.
class TerminalFontLoader {
  static final shared = TerminalFontLoader();
  final _loads = <String, Future<void>>{};
  final _ready = <String>{};
  bool isReady(String id) => _ready.contains(id);
  int _bytes = 0, _attempts = 0;
  Future<void> ensure(
    TypographyGateway gateway,
    TypographySnapshot source,
    TerminalTypography value,
  ) async {
    if (value.kind != 'imported') return;
    final metadata = source.fonts
        .where((f) => f.id == value.family)
        .firstOrNull;
    if (metadata == null) throw StateError('所选导入字体不存在');
    final existing = _loads[value.family];
    if (existing != null) return existing;
    // Reserve synchronously before any await. Concurrent callers share it.
    if (_attempts >= 16 || _bytes + metadata.bytes > 128 * 1024 * 1024) {
      throw StateError('本次运行字体加载已达容量，请重启应用后再载入其他字体');
    }
    _bytes += metadata.bytes;
    _attempts++;
    final operation = () async {
      final bytes = await gateway.fontBytes(source, value.family);
      if (bytes.length != metadata.bytes) throw StateError('字体正文长度与索引不一致');
      final loader = FontLoader(value.renderFamily)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _ready.add(value.family);
    }();
    _loads[value.family] = operation;
    try {
      await operation;
    } catch (_) {
      // Permit explicit retry; the process budget is deliberately not refunded.
      if (identical(_loads[value.family], operation)) {
        _loads.remove(value.family);
      }
      rethrow;
    }
  }
}

/// A font/settings write survives page disposal. Shutdown waits for the write;
/// a font switch never replaces or reconnects TerminalControllers.
class TerminalTypographyController extends ChangeNotifier {
  TerminalTypographyController({
    this.gateway = const NativeTypographyGateway(),
    TerminalFontLoader? loader,
  }) : loader = loader ?? TerminalFontLoader.shared;
  final TypographyGateway gateway;
  final TerminalFontLoader loader;
  TypographySnapshot? snapshot;
  TerminalTypography value = const TerminalTypography();
  bool _disposed = false, _closing = false;
  int _epoch = 0;
  Future<TypographySnapshot>? _operation;
  final _hostLoads = <String, Future<void>>{};
  final _hostErrors = <String, String>{};
  final _hostZoom = <String, double>{};
  String _key(TypographySnapshot source, String hostId) =>
      '${source.scope}/${source.revision}/$hostId';
  TerminalTypography forHost(String? hostId) {
    final original = snapshot?.hosts[hostId];
    if (original == null) return value;
    var style = original;
    if (style.kind == 'imported' && !loader.isReady(style.family)) {
      style = style.copyWith(kind: value.kind, family: value.family);
    }
    return style.copyWith(size: _hostZoom[hostId] ?? original.size);
  }

  String? hostNotice(String hostId) {
    final source = snapshot;
    if (source == null) return null;
    final key = _key(source, hostId);
    if (_hostLoads.containsKey(key)) return '正在载入本机主机字体，暂用全局字体。';
    return _hostErrors[key];
  }

  /// Called on open/configuration changes only, never from build or frame IO.
  Future<void> ensureHost(String hostId, {bool retry = false}) {
    final source = snapshot, style = snapshot?.hosts[hostId];
    if (_disposed ||
        _closing ||
        source == null ||
        style == null ||
        style.kind != 'imported' ||
        loader.isReady(style.family)) {
      return Future.value();
    }
    final key = _key(source, hostId);
    final existing = _hostLoads[key];
    if (existing != null) return existing;
    if (!retry && _hostErrors.containsKey(key)) return Future.value();
    _hostErrors.remove(key);
    final done = Completer<void>();
    _hostLoads[key] = done.future;
    notifyListeners();
    unawaited(() async {
      try {
        await loader.ensure(gateway, source, style);
      } catch (_) {
        if (!_disposed &&
            snapshot?.scope == source.scope &&
            snapshot?.revision == source.revision) {
          _hostErrors[key] = '本机主机字体未能载入，暂用全局字体；可重试。';
        }
      } finally {
        _hostLoads.remove(key);
        done.complete();
        if (!_disposed) notifyListeners();
      }
    }());
    return done.future;
  }

  bool get busy => _operation != null;
  Future<TypographySnapshot> _run(
    Future<TypographySnapshot> Function(int) action,
  ) {
    if (_disposed || _closing || busy) {
      return Future.error(StateError('字体设置正在处理或应用正在关闭'));
    }
    final epoch = ++_epoch;
    final done = Completer<TypographySnapshot>();
    _operation = done.future;
    notifyListeners();
    unawaited(() async {
      try {
        final result = await action(epoch);
        if (!_disposed && epoch == _epoch) {
          final previous = snapshot;
          snapshot = result;
          if (previous?.scope != result.scope ||
              previous?.settings != result.settings) {
            value = result.settings;
          }
          _hostZoom.removeWhere(
            (id, _) =>
                previous?.scope != result.scope ||
                previous?.hosts[id] != result.hosts[id],
          );
          _hostErrors.removeWhere(
            (key, _) => !key.startsWith('${result.scope}/${result.revision}/'),
          );
        }
        done.complete(result);
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        _operation = null;
        if (!_disposed) notifyListeners();
      }
    }());
    return done.future;
  }

  Future<TypographySnapshot> load() async {
    if (_disposed || _closing) throw StateError('应用正在关闭，不能开始字体读取');
    // A restore/sync refresh must wait for the actual previous write, then read
    // the current Vault. Never replay that write or let its old ACK win last.
    final previous = _operation;
    if (previous != null) {
      await previous.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // The original caller still receives its failure; this is a new read.
        },
      );
    }
    return _run((_) async {
      snapshot = null;
      value = const TerminalTypography();
      final result = await gateway.load();
      await loader.ensure(gateway, result, result.settings);
      return result;
    });
  }

  TypographySnapshot _source([TypographySnapshot? expected]) {
    final current = snapshot ?? (throw StateError('尚未成功读取原字体设置，不能覆盖'));
    if (expected != null &&
        (current.scope != expected.scope ||
            current.revision != expected.revision)) {
      throw StateError('原字体设置已改变，请重新载入；没有保存');
    }
    return current;
  }

  Future<TypographySnapshot> save(
    TerminalTypography value, {
    TypographySnapshot? expected,
  }) => _run((_) async {
    final source = _source(expected);
    TerminalTypography.fromJson(value.toJson());
    await loader.ensure(gateway, source, value);
    return gateway.save(source, value);
  });
  Future<TypographySnapshot> saveHost(
    String hostId,
    TerminalTypography? value, {
    TypographySnapshot? expected,
  }) => _run((_) async {
    final source = _source(expected);
    final target = gateway;
    if (target is! HostTypographyGateway) throw StateError('当前入口不支持主机排版保存');
    if (value != null) {
      TerminalTypography.fromJson(value.toJson());
      await loader.ensure(gateway, source, value);
    }
    return (target as HostTypographyGateway).saveHost(source, hostId, value);
  });
  Future<TypographySnapshot> importFont(
    String name,
    Uint8List bytes, {
    TypographySnapshot? expected,
  }) => _run((_) async {
    if (bytes.length > terminalFontLimit) throw StateError('字体超过32MiB');
    return gateway.importFont(_source(expected), name, bytes);
  });
  Future<TypographySnapshot> removeFont(
    String id, {
    TypographySnapshot? expected,
  }) => _run((_) => gateway.removeFont(_source(expected), id));
  void zoom(int direction, {String? hostId}) {
    if (_disposed || _closing) return;
    if (hostId != null && snapshot?.hosts.containsKey(hostId) == true) {
      _hostZoom[hostId] = (forHost(hostId).size + direction).clamp(9.0, 36.0);
    } else {
      value = value.copyWith(size: (value.size + direction).clamp(9.0, 36.0));
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> shutdown() async {
    _closing = true;
    final work = _operation;
    await Future.wait<Object?>([?work, ..._hostLoads.values]);
  }

  void resumeAfterCancelledShutdown() {
    if (!_disposed) _closing = false;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    super.dispose();
  }
}
