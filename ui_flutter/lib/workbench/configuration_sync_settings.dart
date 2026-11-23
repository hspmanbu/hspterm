import '../prototype/design.dart';
import '../prototype/settings_style.dart';
import '../prototype/settings_leave.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import 'configuration_sync.dart';
import 'model.dart';
import 'google_drive_account.dart' show validDesktopClientId;

class ConfigurationSyncSettings {
  ConfigurationSyncSettings(Map<String, dynamic> value)
    : scope = value['vault_scope'] as String,
      revision = value['revision'] as String,
      target = _syncTarget(value['target']),
      passwordSet = value['sync_password_set'] as bool,
      authSet = value['webdav_credential_set'] as bool,
      proxyAuthSet = value['proxy_credential_set'] as bool,
      suggestedCollection = value['suggested_collection'] as String,
      collectionDerived = value['collection_derived'] as bool {
    if (value.length != 8 ||
        !value.keys.toSet().containsAll({
          'vault_scope',
          'revision',
          'target',
          'sync_password_set',
          'webdav_credential_set',
          'proxy_credential_set',
          'suggested_collection',
          'collection_derived',
        })) {
      throw const FormatException('同步设置元数据字段不支持');
    }
    if (scope.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision) ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(suggestedCollection)) {
      throw const FormatException('同步配置身份无效');
    }
    final t = target;
    if (t != null &&
        (t.length != (t['drive'] == null ? 6 : 7) ||
            t['enabled'] is! bool ||
            t['endpoint'] is! String ||
            t['collection'] is! String ||
            t['authenticate'] is! bool ||
            t['timeout_seconds'] is! int ||
            !t.containsKey('proxy'))) {
      throw const FormatException('同步目标格式不支持');
    }
    if (t != null) {
      final uri = Uri.tryParse(t['endpoint'] as String);
      final timeout = t['timeout_seconds'] as int;
      final proxy = t['proxy'] as Map<String, dynamic>?;
      final drive = t['drive'] as Map<String, dynamic>?;
      if (drive != null) {
        final id = drive['file_id'] as String;
        if (id.isEmpty ||
            id.length > 256 ||
            !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id) ||
            !validDesktopClientId(drive['client_id'] as String) ||
            !RegExp(r'^[a-f0-9]{32}$')
                .hasMatch(drive['authorization_id'] as String) ||
            t['authenticate'] != false ||
            t['endpoint'] != 'https://www.googleapis.com/drive/v3/files/$id') {
          throw const FormatException('Drive 同步对象或授权绑定无效');
        }
      }
      if (uri == null ||
          !(drive != null ? {'https'} : {'http', 'https'}).contains(
            uri.scheme,
          ) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.path.isEmpty ||
          uri.path.endsWith('/') ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(t['collection'] as String) ||
          timeout < 1 ||
          timeout > 300 ||
          !passwordSet ||
          t['authenticate'] != authSet ||
          (proxy?['authenticate'] ?? false) != proxyAuthSet) {
        throw const FormatException('同步配置元数据不一致');
      }
      if (proxy != null) {
        final address = Uri.tryParse(proxy['address'] as String);
        if (address == null ||
            !['http', 'socks5h'].contains(address.scheme) ||
            address.host.isEmpty ||
            address.userInfo.isNotEmpty ||
            address.hasQuery ||
            address.hasFragment ||
            !['', '/'].contains(address.path)) {
          throw const FormatException('同步代理地址格式不支持');
        }
      }
    } else if (passwordSet || authSet || proxyAuthSet) {
      throw const FormatException('未配置目标不能包含已保存凭据状态');
    }
  }
  final String scope, revision, suggestedCollection;
  final bool passwordSet, authSet, proxyAuthSet, collectionDerived;
  final Map<String, dynamic>? target;
}

Map<String, dynamic>? _syncTarget(Object? raw) {
  if (raw == null) return null;
  final target = Map<String, dynamic>.from(raw as Map<String, dynamic>);
  final proxy = target['proxy'];
  final drive = target['drive'];
  if (drive != null) {
    final d = Map<String, dynamic>.from(drive as Map<String, dynamic>);
    if (d.length != 3 ||
        d['file_id'] is! String ||
        d['client_id'] is! String ||
        d['authorization_id'] is! String) {
      throw const FormatException('Drive 同步对象格式不支持');
    }
    target['drive'] = Map<String, dynamic>.unmodifiable(d);
  }
  if (proxy != null) {
    final p = Map<String, dynamic>.from(proxy as Map<String, dynamic>);
    if (p.length != 2 ||
        p['address'] is! String ||
        p['authenticate'] is! bool) {
      throw const FormatException('同步代理配置格式不支持');
    }
    target['proxy'] = Map<String, dynamic>.unmodifiable(p);
  }
  return Map<String, dynamic>.unmodifiable(target);
}

/// The single object this application derives from a WebDAV root. Mirrors the
/// frozen Rust derivation `<normalized root>hspterm/config.hspterm`.
const _derivedObjectPath = 'hspterm/config.hspterm';

String deriveWebDavObject(String root) {
  final base = root.endsWith('/') ? root : '$root/';
  return '$base$_derivedObjectPath';
}

/// Reverse derivation for loading an older stored endpoint: strip the fixed
/// object suffix to recover the root (kept with its trailing slash). An
/// endpoint that is not in the derived structure returns null and the form
/// shows the endpoint itself unchanged.
String? rootFromEndpoint(String endpoint) =>
    endpoint.endsWith('/$_derivedObjectPath')
    ? endpoint.substring(0, endpoint.length - _derivedObjectPath.length)
    : null;

abstract interface class ConfigurationSyncSettingsGateway {
  Object get owner;
  bool get isClosing;
  Future<ConfigurationSyncSettings> load();
  Future<ConfigurationSyncSettings> save(Map<String, dynamic> proposal);
}

class NativeConfigurationSyncSettingsGateway
    implements ConfigurationSyncSettingsGateway {
  const NativeConfigurationSyncSettingsGateway(this.model);
  final LiveWorkbenchModel model;
  @override
  Object get owner => model;
  @override
  bool get isClosing => model.isClosing;
  @override
  Future<ConfigurationSyncSettings> load() => model.runLocalSettings(
    () async => ConfigurationSyncSettings(
      jsonDecode(await rust.loadConfigurationSyncSettings())
          as Map<String, dynamic>,
    ),
  );
  @override
  Future<ConfigurationSyncSettings> save(Map<String, dynamic> proposal) =>
      model.runLocalSettings(
        () async => ConfigurationSyncSettings(
          jsonDecode(
            await rust.saveConfigurationSyncSettings(
              proposal: jsonEncode(proposal),
            ),
          ) as Map<String, dynamic>,
        ),
      );
}

/// This form owns write-only secret controllers. Model tracks native writes
/// beyond page disposal; no secret is attached to the model, preferences or logs.
class ConfigurationSyncSettingsPanel extends StatefulWidget {
  const ConfigurationSyncSettingsPanel({
    super.key,
    required this.gateway,
    this.schedule,
  });
  final ConfigurationSyncSettingsGateway gateway;

  /// Runtime controller owning the periodic-check timer; present in the real
  /// workbench so interval changes restart it immediately.
  final ConfigurationSyncController? schedule;
  @override
  State<ConfigurationSyncSettingsPanel> createState() =>
      _ConfigurationSyncSettingsPanelState();
}

class _ConfigurationSyncSettingsPanelState
    extends State<ConfigurationSyncSettingsPanel> {
  final _form = GlobalKey<FormState>();
  final _root = TextEditingController(),
      _timeout = TextEditingController(),
      _interval = TextEditingController();
  final _password = TextEditingController(),
      _user = TextEditingController(),
      _authPassword = TextEditingController();
  final _proxy = TextEditingController(),
      _proxyUser = TextEditingController(),
      _proxyPassword = TextEditingController();
  ConfigurationSyncSettings? _source;
  String _loadedRoot = '';
  bool _loading = true,
      _saving = false,
      _enabled = false,
      _authenticate = false,
      _proxyEnabled = false,
      _proxyAuth = false,
      _savingInterval = false;
  bool _replacePassword = true, _replaceAuth = true, _replaceProxyAuth = true;
  bool _webDavOverride = false;
  bool get _editingWebDav =>
      _source?.target?['drive'] == null || _webDavOverride;
  bool _edited = false;
  int _request = 0;
  String? _error, _notice, _intervalNotice;
  List<TextEditingController> get _secrets => [
    _password,
    _user,
    _authPassword,
    _proxyUser,
    _proxyPassword,
  ];
  bool get _busy => _loading || _saving || widget.gateway.isClosing;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void didUpdateWidget(ConfigurationSyncSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.gateway.owner, oldWidget.gateway.owner)) {
      _request++;
      _source = null;
      _loading = true;
      _saving = false;
      _clearSecrets();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  void _clearSecrets() {
    for (final c in _secrets) {
      c.clear();
    }
  }

  void _adopt(ConfigurationSyncSettings value) {
    final t = value.target;
    final proxy = t?['proxy'] as Map<String, dynamic>?;
    _source = value;
    _webDavOverride = false;
    final endpoint = t?['endpoint'] as String?;
    // Reverse-derive the root from a derived endpoint; an older endpoint in a
    // different shape is shown unchanged so an untouched form re-saves the
    // exact same object without triggering a target switch.
    _loadedRoot = t == null || t['drive'] != null
        ? (endpoint ?? '')
        : (rootFromEndpoint(endpoint ?? '') ?? endpoint ?? '');
    _root.text = _loadedRoot;
    _timeout.text = '${t?['timeout_seconds'] ?? 60}';
    _interval.text =
        '${widget.schedule?.checkIntervalLoaded == true ? widget.schedule!.checkIntervalMinutes : 10}';
    _enabled = t?['enabled'] as bool? ?? false;
    _authenticate = t?['authenticate'] as bool? ?? false;
    _proxyEnabled = proxy != null;
    _proxy.text = proxy?['address'] as String? ?? '';
    _proxyAuth = proxy?['authenticate'] as bool? ?? false;
    _replacePassword = !value.passwordSet;
    _replaceAuth = !value.authSet;
    _replaceProxyAuth = !value.proxyAuthSet;
    _clearSecrets();
    _edited = false;
  }

  Future<void> _load() async {
    final gateway = widget.gateway, owner = gateway.owner;
    if (gateway.isClosing) return;
    final request = ++_request;
    _clearSecrets();
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
      _source = null;
    });
    try {
      final value = await gateway.load();
      if (!mounted ||
          request != _request ||
          !identical(widget.gateway.owner, owner) ||
          gateway.isClosing) {
        return;
      }
      setState(() => _adopt(value));
    } catch (e) {
      if (mounted &&
          request == _request &&
          identical(widget.gateway.owner, owner)) {
        setState(() => _error = '读取同步配置失败：$e');
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  bool get _composing => [
    _root,
    _timeout,
    _proxy,
    ..._secrets,
  ].any((c) => c.value.composing.isValid && !c.value.composing.isCollapsed);
  Future<bool> _confirmSwitch() async =>
      await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: const Text('更换同步目标'),
          content: const SingleChildScrollView(
            child: Text(
              '原云端数据不会删除。本机将归档原目标的同步基线，并把当前配置作为新目标的一次本机修改。返回旧目标时恢复该目标基线。\n\n新设备须使用相同目录路径和同步密码（同一数据集）。旧版标识的数据集会在下次同步时以新派生集合重新上传，云端数据合并保留。确认更换根目录、密码或集合标识？',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认更换'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _save() async {
    final source = _source,
        gateway = widget.gateway,
        owner = widget.gateway.owner;
    if (_busy ||
        source == null ||
        _composing ||
        !(_form.currentState?.validate() ?? false)) {
      return;
    }
    final old = source.target;
    // WebDAV roots ALWAYS derive the single object URL and the collection from
    // the root + effective sync password on this version. A stored target the
    // form left untouched re-derives the SAME endpoint/collection (no switch,
    // no dialog) — unless its stored collection is a legacy (manual/random)
    // identifier, which the explicit target-switch confirmation then migrates
    // to the derived identifier; the next sync rewrites the cloud object with
    // the derived collection and the old local baseline stays archived.
    final priorWebDav = old != null && old['drive'] == null;
    final deriving = _editingWebDav;
    final endpoint = deriving
        ? deriveWebDavObject(_root.text)
        : old!['endpoint'] as String;
    final collection = _editingWebDav
        ? (old?['collection'] as String? ?? source.suggestedCollection)
        : old!['collection'] as String;
    if (_authenticate &&
        source.authSet &&
        !_replaceAuth &&
        old != null &&
        Uri.tryParse(old['endpoint'] as String)?.origin !=
            Uri.tryParse(endpoint)?.origin) {
      setState(() {
        _replaceAuth = true;
        _error = '更换服务器后，请明确填写新服务器的认证再保存。';
      });
      return;
    }
    final oldProxy = old?['proxy'] as Map<String, dynamic>?;
    if (_proxyEnabled &&
        _proxyAuth &&
        source.proxyAuthSet &&
        !_replaceProxyAuth &&
        oldProxy?['address'] != _proxy.text) {
      setState(() {
        _replaceProxyAuth = true;
        _error = '更换代理地址后，请明确填写新代理的认证再保存。';
      });
      return;
    }
    final request = ++_request;
    final target = <String, dynamic>{
      'enabled': _enabled,
      'endpoint': endpoint,
      'collection': collection,
      'authenticate': _authenticate,
      'timeout_seconds': int.parse(_timeout.text),
      'proxy': _proxyEnabled
          ? {'address': _proxy.text, 'authenticate': _proxyAuth}
          : null,
      if (!_editingWebDav) 'drive': source.target!['drive'],
    };
    final switching =
        source.target != null &&
        (source.target!['endpoint'] != target['endpoint'] ||
            source.target!['drive'] != null && _editingWebDav ||
            deriving && _replacePassword && priorWebDav ||
            deriving && priorWebDav && !source.collectionDerived);
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      if (switching && !await _confirmSwitch()) return;
      if (!mounted ||
          request != _request ||
          !identical(widget.gateway.owner, owner) ||
          gateway.isClosing) {
        return;
      }
      // Freeze exactly the confirmed form. The form is disabled while the
      // dialog/native write is pending; target cannot follow another page.
      // Secrets are trimmed here exactly once; the native side normalizes
      // every remaining entry with the same rule.
      final secretChanges = <String, dynamic>{
        'sync_password': _replacePassword ? _password.text.trim() : null,
        'webdav': _authenticate
            ? (_replaceAuth
                  ? {
                      'action': 'replace',
                      'username': _user.text,
                      'password': _authPassword.text,
                    }
                  : {'action': 'keep'})
            : {'action': 'remove'},
        'proxy': _proxyEnabled && _proxyAuth
            ? (_replaceProxyAuth
                  ? {
                      'action': 'replace',
                      'username': _proxyUser.text,
                      'password': _proxyPassword.text,
                    }
                  : {'action': 'keep'})
            : {'action': 'remove'},
      };
      late ConfigurationSyncSettings saved;
      try {
        saved = await gateway.save({
          'vault_scope': source.scope,
          'revision': source.revision,
          'target': target,
          'derive_collection': deriving ? _root.text : null,
          'secrets': secretChanges,
          'confirm_target_change': switching,
        });
      } finally {
        secretChanges.clear();
      }
      if (!mounted ||
          request != _request ||
          !identical(widget.gateway.owner, owner)) {
        return;
      }
      setState(() {
        _adopt(saved);
        _notice = '同步设置已保存；将按检查间隔同步，也可立即同步。';
      });
    } catch (_) {
      if (mounted &&
          request == _request &&
          identical(widget.gateway.owner, owner)) {
        setState(() {
          _source = null;
          _error = '同步设置保存未确认；可能已提交或原配置改变。请重新载入确认当前值，不要重放旧修改。';
        });
      }
    } finally {
      if (mounted && request == _request) {
        _clearSecrets();
        setState(() => _saving = false);
      }
    }
  }

  /// Device-local periodic check interval (0 disables, 1–1440 minutes,
  /// default 10). Saved through its own record CAS and applied by restarting
  /// the runtime controller's timer from the confirmed value.
  Future<void> _saveInterval() async {
    final schedule = widget.schedule;
    if (schedule == null || _savingInterval || widget.gateway.isClosing) {
      return;
    }
    final minutes = int.tryParse(_interval.text);
    if (minutes == null || minutes < 0 || minutes > 1440) {
      setState(() => _intervalNotice = '检查间隔必须在 0–1440 分钟内；0 表示关闭');
      return;
    }
    setState(() {
      _savingInterval = true;
      _intervalNotice = null;
    });
    try {
      await schedule.setCheckIntervalMinutes(minutes);
      if (mounted) {
        setState(() => _intervalNotice = '定时检查间隔已保存。');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _intervalNotice = '检查间隔保存未确认；请重新载入后重试。');
      }
    } finally {
      if (mounted) setState(() => _savingInterval = false);
    }
  }

  String? _required(String? text) =>
      text == null || text.isEmpty ? '请填写此项' : null;
  Widget _field(
    String label,
    TextEditingController c, {
    bool secret = false,
    bool readOnly = false,
    String? help,
    String? Function(String?)? validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: SettingsField(
      child: TextFormField(
        controller: c,
        enabled: !_busy,
        readOnly: readOnly,
        obscureText: secret,
        enableSuggestions: !secret,
        autocorrect: !secret,
        decoration: InputDecoration(
          labelText: label,
          helperText: help,
          isDense: true,
        ),
        validator: validator ?? _required,
      ),
    ),
  );
  Widget _check(String title, bool value, ValueChanged<bool> set) =>
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(title),
        value: value,
        onChanged: _busy
            ? null
            : (v) => setState(() {
                set(v!);
                _edited = true;
              }),
      );
  @override
  Widget build(BuildContext context) =>
      Form(
        key: _form,
        onChanged: () {
          if (_source != null && !_loading) _edited = true;
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '配置同步 · 目标设置',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              '保存正式主机、凭据、书签、允许的设置及合格单行命令历史；不包含画面、滚动历史、任务、草稿或字体。同步密码与主密码独立；相同目录路径与同步密码对应同一数据集，请在各设备保持一致。',
            ),
            const SizedBox(height: 8),
            const Text(
              '启用后按检查间隔或手动同步。可确定方向时静默合并；无法确定时直接弹窗选择覆盖方向，网络失败自动重试 3 次。云端保留最近 3 个历史快照。',
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
              ),
            if (_source != null && !_editingWebDav) ...[
              const Text(
                '当前唯一同步目标为 Google Drive。对象地址及集合只读；可调整启用、超时和独立代理。选择其他对象请使用下方发现入口。',
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _webDavOverride = true;
                        _root.clear();
                        _loadedRoot = '';
                        _authenticate = false;
                        _replaceAuth = true;
                        _enabled = false;
                        _clearSecrets();
                      }),
                child: const Text('改为配置 WebDAV 目标'),
              ),
            ],
            if (_source != null) ...[
              _check('启用此同步目标', _enabled, (v) => _enabled = v),
              _field(
                _editingWebDav ? 'WebDAV 根目录（HTTP / HTTPS）' : 'Drive 对象地址（只读）',
                _root,
                readOnly: !_editingWebDav,
                help: _editingWebDav
                    ? '只填根目录；对象地址自动派生为 根目录/hspterm/config.hspterm。HTTP不保护WebDAV登录信息，配置内容仍端到端加密'
                    : null,
                validator: (v) {
                  final uri = Uri.tryParse(v ?? '');
                  if (uri == null ||
                      !(_editingWebDav ? {'http', 'https'} : {'https'})
                          .contains(uri.scheme) ||
                      uri.host.isEmpty ||
                      uri.userInfo.isNotEmpty ||
                      uri.hasQuery ||
                      uri.hasFragment ||
                      utf8.encode(v!).length > 8192) {
                    return _editingWebDav
                        ? '请填写 WebDAV 根目录（HTTP / HTTPS）'
                        : '对象地址无效';
                  }
                  if (_editingWebDav) {
                    final derived = Uri.tryParse(deriveWebDavObject(v));
                    if (derived == null ||
                        derived.path.isEmpty ||
                        derived.path.endsWith('/')) {
                      return '根目录无法派生有效对象地址';
                    }
                  }
                  return null;
                },
              ),
              if (_editingWebDav)
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _root,
                  builder: (context, value, _) {
                    final shown = value.text.isEmpty
                        ? '（未填写）'
                        : deriveWebDavObject(value.text);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        '派生对象地址（只读）：$shown\n集合标识由根目录与同步密码自动派生，无需填写。',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  },
                ),
              _field(
                '请求超时（秒）',
                _timeout,
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  return n == null || n < 1 || n > 300 ? '范围为 1–300 秒' : null;
                },
              ),
              if (_source!.passwordSet)
                _check('填写同步密码（留空不表示删除）', _replacePassword, (v) {
                  _replacePassword = v;
                  if (!v) _password.clear();
                }),
              if (_replacePassword)
                _field(
                  '同步密码',
                  _password,
                  secret: true,
                  help: '成功同步过的集合不能仅改本机密码；更换密码请明确使用新集合。首尾空格不计入密码',
                  validator: (v) =>
                      v == null ||
                          v.trim().isEmpty ||
                          utf8.encode(v).length > 4096
                      ? '需要 1–4096 字节的同步密码（首尾空格不计入）'
                      : null,
                ),
              if (_editingWebDav)
                _check('WebDAV 需要用户名和密码', _authenticate, (v) {
                  _authenticate = v;
                  if (!v) {
                    _user.clear();
                    _authPassword.clear();
                  }
                }),
              if (_authenticate) ...[
                if (_source!.authSet)
                  _check('更换 WebDAV 认证', _replaceAuth, (v) => _replaceAuth = v),
                if (_replaceAuth) ...[
                  _field('WebDAV 用户名', _user),
                  _field(
                    'WebDAV 密码',
                    _authPassword,
                    secret: true,
                    validator: (_) => null,
                  ),
                ] else
                  const Text('保留已加密保存的 WebDAV 认证，不回显密码。'),
              ],
              _check('配置独立同步代理', _proxyEnabled, (v) => _proxyEnabled = v),
              if (_proxyEnabled) ...[
                _field(
                  '代理地址',
                  _proxy,
                  help: 'http://主机:端口 或 socks5h://主机:端口；不继承 SSH 代理',
                  validator: (v) {
                    final u = Uri.tryParse(v ?? '');
                    return u == null ||
                            !['http', 'socks5h'].contains(u.scheme) ||
                            u.host.isEmpty ||
                            u.userInfo.isNotEmpty ||
                            u.hasQuery ||
                            u.hasFragment ||
                            !['', '/'].contains(u.path)
                        ? '请填写 HTTP CONNECT 或 SOCKS5h 代理地址'
                        : null;
                  },
                ),
                _check('代理需要认证', _proxyAuth, (v) => _proxyAuth = v),
                if (_proxyAuth) ...[
                  if (_source!.proxyAuthSet)
                    _check(
                      '更换代理认证',
                      _replaceProxyAuth,
                      (v) => _replaceProxyAuth = v,
                    ),
                  if (_replaceProxyAuth) ...[
                    _field('代理用户名', _proxyUser),
                    _field(
                      '代理密码',
                      _proxyPassword,
                      secret: true,
                      validator: (_) => null,
                    ),
                  ] else
                    const Text('保留已加密保存的代理认证。'),
                ],
              ],
            ],
            if (widget.schedule != null) ...[
              const SizedBox(height: 10),
              const Text(
                '定时检查间隔（本设备）',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              _field(
                '检查间隔（分钟）',
                _interval,
                help: '0 关闭定时检查；范围 0–1440，默认 10。仅本设备生效，不同步',
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  return n == null || n < 0 || n > 1440
                      ? '范围为 0–1440 分钟；0 表示关闭'
                      : null;
                },
              ),
              if (_intervalNotice != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(_intervalNotice!),
                ),
              OutlinedButton(
                onPressed: _savingInterval || widget.gateway.isClosing
                    ? null
                    : _saveInterval,
                child: Text(_savingInterval ? '正在保存…' : '保存检查间隔'),
              ),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_notice!),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Visibility(
                  visible: SettingsLeaveScope.of(context) == null,
                  child: FilledButton(
                    key: const ValueKey('sync-settings-save'),
                    onPressed: _busy || _source == null ? null : _save,
                    child: Text(_saving ? '正在保存…' : '保存同步设置'),
                  ),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _load,
                  child: const Text('重新载入'),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ).guardSettings(
        confirmed: () => _source != null && _error == null,
        apply: _save,
        label: '配置同步目标',
        dirty: () => _edited || _webDavOverride,
        busy: () => _saving,
      );
  @override
  void dispose() {
    _request++;
    for (final c in [_root, _timeout, _interval, _proxy, ..._secrets]) {
      c.dispose();
    }
    super.dispose();
  }
}
