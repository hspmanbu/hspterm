import '../prototype/settings_leave.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/network_settings.dart';

abstract interface class SshDefaultsGateway {
  Future<SshNetworkDefaults> load();
  Future<SshNetworkDefaults> save(SshNetworkDefaults value);
}

class NativeSshDefaultsGateway implements SshDefaultsGateway {
  const NativeSshDefaultsGateway();
  @override
  Future<SshNetworkDefaults> load() => rust.sshNetworkDefaults();
  @override
  Future<SshNetworkDefaults> save(SshNetworkDefaults value) =>
      rust.saveSshNetworkDefaults(value: value);
}

class SshNetworkDefaultsPanel extends StatefulWidget {
  const SshNetworkDefaultsPanel({
    super.key,
    this.gateway = const NativeSshDefaultsGateway(),
  });
  final SshDefaultsGateway gateway;
  @override
  State<SshNetworkDefaultsPanel> createState() =>
      _SshNetworkDefaultsPanelState();
}

class _SshNetworkDefaultsPanelState extends State<SshNetworkDefaultsPanel> {
  final _form = GlobalKey<FormState>();
  final _timeout = TextEditingController(),
      _interval = TextEditingController(),
      _response = TextEditingController(),
      _failures = TextEditingController();
  bool _busy = true, _loaded = false;
  String? _error, _status;
  Object? _originalView;
  Object get _view =>
      (_timeout.text, _interval.text, _response.text, _failures.text);
  bool get _dirty => _loaded && _originalView != _view;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _loaded = false;
      _error = null;
      _status = null;
    });
    try {
      final value = await widget.gateway.load();
      if (!mounted) return;
      _timeout.text = '${value.timeoutSeconds}';
      _interval.text = '${value.keepaliveSeconds}';
      _response.text = '${value.responseTimeoutSeconds}';
      _failures.text = '${value.keepaliveFailures}';
      _originalView = _view;
      setState(() => _loaded = true);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || !_loaded || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      await widget.gateway.save(
        SshNetworkDefaults(
          timeoutSeconds: int.parse(_timeout.text),
          keepaliveSeconds: int.parse(_interval.text),
          responseTimeoutSeconds: int.parse(_response.text),
          keepaliveFailures: int.parse(_failures.text),
        ),
      );
      if (mounted) {
        setState(() {
          _originalView = _view;
          _status = '已加密保存；只在下次明确连接时使用，不改变当前会话。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _number(
    String key,
    String label,
    TextEditingController controller,
    int min,
    int max,
  ) => SizedBox(
    width: 190,
    child: TextFormField(
      key: ValueKey(key),
      controller: controller,
      enabled: _loaded && !_busy,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, helperText: '$min–$max'),
      validator: (text) {
        final n = int.tryParse(text ?? '');
        return n == null || n < min || n > max ? '请输入 $min–$max' : null;
      },
    ),
  );
  @override
  Widget build(BuildContext context) =>
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('SSH 全局默认参数'),
            const SizedBox(height: 8),
            const Text('仅对使用全局参数的主机生效。心跳间隔0关闭；心跳响应以SSH ACK为准。'),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _number('ssh-default-timeout', '总连接超时（秒）', _timeout, 1, 3600),
                _number('ssh-default-interval', '心跳间隔（秒）', _interval, 0, 86400),
                _number('ssh-default-response', '响应超时（秒）', _response, 1, 3600),
                _number('ssh-default-failures', '连续失败阈值', _failures, 1, 100),
              ],
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_status != null) Text(_status!),
            Wrap(
              spacing: 8,
              children: [
                Visibility(
                  visible: SettingsLeaveScope.of(context) == null,
                  child: FilledButton(
                    onPressed: !_loaded || _busy ? null : _save,
                    child: const Text('保存 SSH 默认参数'),
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : _load,
                  child: const Text('重新载入'),
                ),
              ],
            ),
            const Text('断线后保留画面；只有明确点击或焦点窗格 Enter 才尝试一次重连。确认等待时间不计入总连接超时。'),
          ],
        ),
      ).guardSettings(
        confirmed: () => _loaded && _error == null,
        apply: _save,
        label: 'SSH连接默认值',
        dirty: () => _dirty,
        busy: () => _busy && _loaded,
      );
  @override
  void dispose() {
    for (final c in [_timeout, _interval, _response, _failures]) {
      c.dispose();
    }
    super.dispose();
  }
}
