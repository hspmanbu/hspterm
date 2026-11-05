import '../prototype/settings_style.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import '../prototype/settings_leave.dart';

class SftpViewSettings {
  const SftpViewSettings({
    this.foldersFirst = true,
    this.showHidden = false,
    this.compact = false,
    this.restoreLastDirectory = false,
  });
  factory SftpViewSettings.parse(Map<String, dynamic> value) {
    // The restore flag is serde-defaulted on the Rust side: legacy payloads
    // with exactly the first three keys stay readable.
    final legacy = value.length == 3 && value['restore_last_directory'] == null;
    if (value.length != (legacy ? 3 : 4) ||
        value['folders_first'] is! bool ||
        value['show_hidden'] is! bool ||
        value['compact'] is! bool ||
        (!legacy && value['restore_last_directory'] is! bool)) {
      throw const FormatException('SFTP浏览设置格式无效');
    }
    return SftpViewSettings(
      foldersFirst: value['folders_first'] as bool,
      showHidden: value['show_hidden'] as bool,
      compact: value['compact'] as bool,
      restoreLastDirectory: legacy
          ? false
          : value['restore_last_directory'] as bool,
    );
  }
  final bool foldersFirst, showHidden, compact, restoreLastDirectory;
  SftpViewSettings copyWith({
    bool? foldersFirst,
    bool? showHidden,
    bool? compact,
    bool? restoreLastDirectory,
  }) => SftpViewSettings(
    foldersFirst: foldersFirst ?? this.foldersFirst,
    showHidden: showHidden ?? this.showHidden,
    compact: compact ?? this.compact,
    restoreLastDirectory: restoreLastDirectory ?? this.restoreLastDirectory,
  );
  Map<String, dynamic> toJson() => {
    'folders_first': foldersFirst,
    'show_hidden': showHidden,
    'compact': compact,
    'restore_last_directory': restoreLastDirectory,
  };
  bool sameAs(SftpViewSettings other) =>
      foldersFirst == other.foldersFirst &&
      showHidden == other.showHidden &&
      compact == other.compact &&
      restoreLastDirectory == other.restoreLastDirectory;
}

class SftpViewSnapshot {
  SftpViewSnapshot(Map<String, dynamic> value)
    : scope = value['vault_scope'] as String,
      revision = value['revision'] as String,
      settings = SftpViewSettings.parse(
        value['settings'] as Map<String, dynamic>,
      ) {
    if (value.length != 3 ||
        scope.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision)) {
      throw const FormatException('SFTP浏览设置元数据无效');
    }
  }
  final String scope, revision;
  final SftpViewSettings settings;
}

abstract interface class SftpViewSettingsGateway {
  Future<SftpViewSnapshot> load();
  Future<SftpViewSnapshot> save(
    SftpViewSnapshot source,
    SftpViewSettings settings,
  );
}

class NativeSftpViewSettingsGateway implements SftpViewSettingsGateway {
  const NativeSftpViewSettingsGateway();
  @override
  Future<SftpViewSnapshot> load() async => SftpViewSnapshot(
    jsonDecode(await rust.loadSftpViewSettings()) as Map<String, dynamic>,
  );
  @override
  Future<SftpViewSnapshot> save(
    SftpViewSnapshot source,
    SftpViewSettings settings,
  ) async => SftpViewSnapshot(
    jsonDecode(
      await rust.saveSftpViewSettings(
        proposal: jsonEncode({
          'vault_scope': source.scope,
          'revision': source.revision,
          'settings': settings.toJson(),
        }),
      ),
    ) as Map<String, dynamic>,
  );
}

/// Only acknowledged values reach file browsers. Read/save failure blocks
/// further writes until an explicit reload; the last confirmed view remains.
class SftpViewSettingsController extends ChangeNotifier {
  SftpViewSettingsController({
    this.gateway = const NativeSftpViewSettingsGateway(),
  });
  final SftpViewSettingsGateway gateway;
  SftpViewSnapshot? value, confirmed;
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
        error = 'SFTP浏览设置未获完整确认，请重新读取；文件列表保持上次确认的默认值。';
      } finally {
        _work = null;
        done.complete();
        _notify();
      }
    }());
    return done.future;
  }

  Future<void> load() async {
    await _work;
    if (_closing || _disposed) return;
    await _run(() async {
      value = null;
      value = await gateway.load();
      confirmed = value;
    });
  }

  Future<void> choose(SftpViewSettings settings) {
    final source = value;
    if (!available || source == null || source.settings.sameAs(settings)) {
      return Future.value();
    }
    return _run(() async {
      final saved = await gateway.save(source, settings);
      if (saved.scope != source.scope || !saved.settings.sameAs(settings)) {
        throw StateError('SFTP浏览设置保存回执来源不一致');
      }
      value = saved;
      confirmed = saved;
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

class SftpViewSettingsPanel extends StatefulWidget {
  const SftpViewSettingsPanel({super.key, required this.controller});
  final SftpViewSettingsController controller;
  @override
  State<SftpViewSettingsPanel> createState() => _SftpViewSettingsPanelState();
}

class _SftpViewSettingsPanelState extends State<SftpViewSettingsPanel> {
  SftpViewSettingsController get controller => widget.controller;
  SftpViewSettings? _draft;
  SftpViewSnapshot? _original;
  bool get _dirty =>
      _draft != null && !(_original?.settings.sameAs(_draft!) ?? true);
  Future<void> _apply() async {
    final source = controller.value, draft = _draft;
    if (!_dirty || draft == null) return;
    if (source == null ||
        source.scope != _original?.scope ||
        source.revision != _original?.revision) {
      throw StateError('文件浏览默认值已改变，请重新载入');
    }
    await controller.choose(draft);
    if (mounted && controller.value?.settings.sameAs(draft) == true) {
      setState(() {
        _draft = null;
        _original = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final settings =
          _draft ??
          controller.value?.settings ??
          controller.confirmed?.settings ??
          const SftpViewSettings();
      Widget toggle(
        String key,
        String label,
        bool value,
        SftpViewSettings next,
      ) => CompactSettingsToggle(
        child: SwitchListTile(
          key: ValueKey(key),
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          value: value,
          onChanged: controller.available
              ? (_) {
                  if (SettingsLeaveScope.of(context) == null) {
                    controller.choose(next);
                  } else {
                    setState(() {
                      _original ??= controller.value;
                      _draft = next;
                    });
                  }
                }
              : null,
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('全局浏览默认值 · 修改成功保存后生效；列表菜单只影响当前浏览器。'),
          if (controller.busy) const LinearProgressIndicator(),
          toggle(
            'sftp-default-folders-first',
            '目录优先',
            settings.foldersFirst,
            settings.copyWith(foldersFirst: !settings.foldersFirst),
          ),
          toggle(
            'sftp-default-show-hidden',
            '显示隐藏文件',
            settings.showHidden,
            settings.copyWith(showHidden: !settings.showHidden),
          ),
          toggle(
            'sftp-default-compact',
            '紧凑列表',
            settings.compact,
            settings.copyWith(compact: !settings.compact),
          ),
          toggle(
            'sftp-default-restore-last-dir',
            '连接后进入上次目录',
            settings.restoreLastDirectory,
            settings.copyWith(
              restoreLastDirectory: !settings.restoreLastDirectory,
            ),
          ),
          if (controller.error != null)
            Text(
              controller.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: controller.busy
                  ? null
                  : () async {
                      await controller.load();
                      if (mounted) {
                        setState(() {
                          _draft = null;
                          _original = null;
                        });
                      }
                    },
              child: const Text('重新读取浏览默认值'),
            ),
          ),
        ],
      ).guardSettings(
        confirmed: () => controller.value != null && controller.error == null,
        label: 'SFTP浏览默认值',
        dirty: () => _dirty,
        busy: () => controller.busy,
        apply: _apply,
      );
    },
  );
}
