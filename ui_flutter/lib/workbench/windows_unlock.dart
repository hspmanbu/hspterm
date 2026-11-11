import '../prototype/design.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/rust/api.dart' as rust;

const windowsUnlockChannel = MethodChannel('hspterm/windows_unlock');

class WindowsUnlockSource {
  WindowsUnlockSource({required this.scope, required this.token}) {
    if (scope.isEmpty || !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      throw const FormatException('配置库解锁标识无效');
    }
  }
  final String scope, token;
  factory WindowsUnlockSource.decode(String json) {
    final value = jsonDecode(json) as Map<String, dynamic>;
    return WindowsUnlockSource(
      scope: value['vault_scope'] as String,
      token: value['token'] as String,
    );
  }
}

abstract interface class WindowsUnlockGateway {
  bool get supported;
  Future<WindowsUnlockSource> source();
  Future<bool> available(String token);
  Future<void> verify(WindowsUnlockSource original, String password);
  Future<void> protect(String token, Uint8List password);
  Future<void> remove(String token);
}

class NativeWindowsUnlockGateway implements WindowsUnlockGateway {
  const NativeWindowsUnlockGateway();
  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  @override
  Future<WindowsUnlockSource> source() async =>
      WindowsUnlockSource.decode(await rust.secureUnlockSource());
  @override
  Future<bool> available(String token) async {
    final value = await windowsUnlockChannel.invokeMethod<bool>('available', {
      'token': token,
    });
    if (value == null) throw StateError('Windows 未确认缓存状态，没有使用默认值覆盖');
    return value;
  }

  @override
  Future<void> verify(WindowsUnlockSource original, String password) =>
      rust.verifySecureUnlock(
        vaultScope: original.scope,
        token: original.token,
        password: password,
      );
  @override
  Future<void> protect(String token, Uint8List password) => windowsUnlockChannel
      .invokeMethod<void>('protect', {'token': token, 'password': password});
  @override
  Future<void> remove(String token) =>
      windowsUnlockChannel.invokeMethod<void>('remove', {'token': token});
}

/// Only an explicit locked-screen action calls this. Bytes owned by Dart are
/// wiped; immutable String/platform-message copies cannot all be guaranteed.
Future<void> openWindowsProtectedVault(String path) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
    throw UnsupportedError('当前平台不支持 Windows 账户解锁');
  }
  final token = await rust.vaultUnlockHint(path: path);
  final bytes = await windowsUnlockChannel.invokeMethod<Uint8List>(
    'unprotect',
    {'token': token},
  );
  if (bytes == null || bytes.isEmpty || bytes.length > 4096) {
    if (bytes != null) bytes.fillRange(0, bytes.length, 0);
    throw StateError('本机解锁缓存无效，请手动输入主密码');
  }
  String password;
  try {
    password = utf8.decode(bytes);
  } on FormatException {
    throw StateError('本机解锁数据格式无效，请手动输入主密码');
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
  // Open-only + token check: a deleted/replaced Vault must not be silently
  // created or redirected using the cached master password.
  await rust.unlockExistingVault(path: path, token: token, password: password);
}

class WindowsUnlockSettingsPanel extends StatefulWidget {
  const WindowsUnlockSettingsPanel({
    super.key,
    required this.run,
    this.gateway = const NativeWindowsUnlockGateway(),
  });
  final Future<void> Function(Future<void> Function()) run;
  final WindowsUnlockGateway gateway;
  @override
  State<WindowsUnlockSettingsPanel> createState() =>
      _WindowsUnlockSettingsPanelState();
}

class _WindowsUnlockSettingsPanelState
    extends State<WindowsUnlockSettingsPanel> {
  WindowsUnlockSource? _source;
  bool _busy = false, _io = false, _available = false, _known = false;
  String? _error, _status;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.gateway.supported) unawaited(_load());
    });
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _io = true;
      _source = null;
      _known = false;
      _error = null;
    });
    try {
      final source = await widget.gateway.source();
      if (mounted) setState(() => _source = source);
      final available = await widget.gateway.available(source.token);
      if (mounted) {
        setState(() {
          _known = true;
          _available = available;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '无法读取本机解锁状态：$error。手动主密码入口保持可用。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  Future<void> _enable() async {
    final source = _source;
    if (_busy || source == null || !_known) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final password = await showAppDialog<String>(
        context: context,
        builder: (_) => const _WindowsUnlockConsent(),
      );
      if (!mounted || password == null) return;
      setState(() => _io = true);
      var saved = false;
      await widget.run(() async {
        await widget.gateway.verify(source, password);
        final bytes = Uint8List.fromList(utf8.encode(password));
        try {
          if (bytes.isEmpty || bytes.length > 4096) {
            throw StateError('便捷解锁支持1–4096个UTF-8字节的主密码');
          }
          await widget.gateway.protect(source.token, bytes);
          saved = true;
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      });
      if (!mounted) return;
      if (saved) {
        await _ack(source, true, '已保存原配置库的 Windows 账户保护缓存；不会自动打开 SSH 连接。');
      }
    } catch (error) {
      if (mounted) setState(() => _error = '未确认启用成功：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  Future<void> _disable() async {
    final source = _source;
    if (_busy || source == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final accepted = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('关闭 Windows 账户解锁？'),
          content: const Text('仅删除当前配置库对应的本机保护缓存。加密配置库和主机凭据保留，下次仍可手动输入主密码。'),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('windows-unlock-confirm-remove'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除本机解锁缓存'),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) return;
      setState(() => _io = true);
      await widget.run(() async {
        final current = await widget.gateway.source();
        if (current.scope != source.scope || current.token != source.token) {
          throw StateError('原配置库已改变，请重新载入');
        }
        await widget.gateway.remove(source.token);
      });
      if (mounted) await _ack(source, false, '已删除本机解锁缓存，加密配置库保留。');
    } catch (error) {
      if (mounted) setState(() => _error = '没有确认关闭成功：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  Future<void> _ack(
    WindowsUnlockSource original,
    bool available,
    String status,
  ) async {
    if (!mounted) return;
    try {
      final current = await widget.gateway.source();
      if (!mounted) return;
      if (current.token != original.token) {
        setState(() {
          _source = null;
          _known = false;
          _status = '原配置库的缓存操作已完成。';
          _error = '当前配置库已改变，请重新载入当前状态，不要重复原操作。';
        });
      } else {
        setState(() {
          _source = current;
          _known = true;
          _available = available;
          _status = status;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _source = null;
          _known = false;
          _status = '原配置库的缓存操作已完成。';
          _error = '重新读取状态失败：$error。请重新载入，不要重复提交。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.gateway.supported) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Windows DPAPI 便捷解锁仅在 Windows 提供；当前仍使用主密码。'),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Windows 账户便捷解锁 · 默认关闭'),
        const SizedBox(height: 8),
        const Text(
          '当前 Windows 登录账户可解开此库的本机缓存；能使用此账户运行程序的人也可能使用该能力。不会替代 Argon2id/AES 加密，不会保存明文主密码，不进入云同步或配置备份。',
        ),
        if (_io) const LinearProgressIndicator(),
        if (_source != null && _known)
          Text(
            _available
                ? '本机保护缓存已存在；解锁时由 Windows 校验账户。'
                : '当前库尚未启用 Windows 账户解锁。',
          ),
        if (_source != null && !_known)
          const Text('尚未确认缓存状态。可明确清理此库缓存后再重新启用，手动主密码仍可使用。'),
        if (_error != null)
          Text(
            _error!,
            key: const ValueKey('windows-unlock-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_status != null)
          Text(_status!, key: const ValueKey('windows-unlock-status')),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              key: const ValueKey('windows-unlock-enable'),
              onPressed: _busy || _source == null || !_known ? null : _enable,
              child: Text(_available ? '重新验证并更新缓存' : '验证主密码并启用'),
            ),
            TextButton(
              key: const ValueKey('windows-unlock-disable'),
              onPressed: _busy || _source == null ? null : _disable,
              child: const Text('关闭 / 清理此库缓存'),
            ),
            TextButton(
              key: const ValueKey('windows-unlock-reload'),
              onPressed: _busy ? null : _load,
              child: const Text('重新载入'),
            ),
          ],
        ),
        const Divider(height: 24),
      ],
    );
  }
}

class _WindowsUnlockConsent extends StatefulWidget {
  const _WindowsUnlockConsent();
  @override
  State<_WindowsUnlockConsent> createState() => _WindowsUnlockConsentState();
}

class _WindowsUnlockConsentState extends State<_WindowsUnlockConsent> {
  final _password = TextEditingController();
  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('启用 Windows 账户便捷解锁？'),
    content: SizedBox(
      width: 410,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '将主密码的 Windows DPAPI 保护副本保存在当前账户的本机应用目录。以后需明确点击 Windows 解锁入口，不会自动连接主机。',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('windows-unlock-master'),
            controller: _password,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '重新输入当前主密码'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('windows-unlock-consent'),
        onPressed: () {
          if (_password.text.isEmpty ||
              (_password.value.composing.isValid &&
                  !_password.value.composing.isCollapsed)) {
            return;
          }
          final value = _password.text;
          _password.clear();
          Navigator.pop(context, value);
        },
        child: const Text('验证并保存保护缓存'),
      ),
    ],
  );
}
