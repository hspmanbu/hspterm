import 'package:flutter/material.dart';

import 'google_drive_account.dart';

class GoogleDriveAccountPanel extends StatefulWidget {
  const GoogleDriveAccountPanel({super.key, required this.controller});
  final GoogleDriveAccountController controller;
  @override
  State<GoogleDriveAccountPanel> createState() =>
      _GoogleDriveAccountPanelState();
}

class _GoogleDriveAccountPanelState extends State<GoogleDriveAccountPanel> {
  final _client = TextEditingController(), _secret = TextEditingController();
  String? _loadedRevision;
  bool _touched = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.load();
    });
  }

  @override
  void didUpdateWidget(GoogleDriveAccountPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _secret.clear();
      _client.clear();
      _touched = false;
      _loadedRevision = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.load();
      });
    }
  }

  void _changed() {
    final value = widget.controller.account;
    if (value != null &&
        value.revision != _loadedRevision &&
        !widget.controller.busy) {
      if (!_touched) _client.text = value.clientId ?? '';
      _loadedRevision = value.revision;
    }
    if (mounted) setState(() {});
  }

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _authorize() async {
    final c = widget.controller, source = widget.controller.account;
    if (source == null ||
        c.busy ||
        !c.available ||
        _client.value.composing.isValid &&
            !_client.value.composing.isCollapsed ||
        _secret.value.composing.isValid &&
            !_secret.value.composing.isCollapsed) {
      return;
    }
    final id = _client.text, secret = _secret.text;
    if (!validDesktopClientId(id)) return;
    if (source.authorized &&
        !await _confirm(
          '重新授权 Google Drive',
          '本次授权成功后替换本机旧授权。原云端配置不会删除；旧 Google 授权不会自动撤销。继续打开系统浏览器？',
        )) {
      return;
    }
    if (!mounted || !identical(c, widget.controller) || !c.available) return;
    try {
      await c.authorize(
        source: source,
        clientId: id,
        clientSecret: secret,
        confirmReplace: source.authorized,
      );
    } finally {
      if (mounted) _secret.clear();
    }
  }

  Future<void> _remove({required bool revoke}) async {
    final c = widget.controller, source = widget.controller.account;
    if (source == null || !source.authorized || c.busy || !c.available) return;
    final confirmed = await _confirm(
      revoke ? '撤销 Google 授权并移除' : '仅移除本机授权',
      revoke
          ? '将向 Google 请求撤销这次授权，可能同时影响同一客户端的其他有效令牌。仅在 Google 确认后删除本机凭据，不删除云端配置。继续？'
          : '仅删除当前配置库内的本机授权，不向 Google 请求撤销，也不删除云端配置。继续？',
    );
    if (!confirmed || !mounted || !identical(c, widget.controller)) return;
    await c.remove(source, revoke: revoke);
    if (mounted) _secret.clear();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _secret.clear();
    _secret.dispose();
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, account = widget.controller.account;
    final enabled = c.available && !c.busy;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Google Drive · 本机授权',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            '使用自己注册的桌面 OAuth 客户端，系统浏览器仅申请应用数据目录权限。刷新令牌在当前配置库加密保存，不返回界面、不备份或同步。授权与配置上传是独立操作。',
          ),
          const SizedBox(height: 8),
          const Text('使用已保存的独立同步代理和超时；请先保存需要的代理。未配置时使用直连。此授权入口不读取其他应用的登录信息。'),
          const SizedBox(height: 8),
          Text(
            account?.authorized == true
                ? '已保存本机授权 · ${account!.clientId}'
                : '尚未保存本机授权',
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _client,
            enabled: enabled,
            onChanged: (_) => setState(() => _touched = true),
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '桌面 OAuth Client ID',
              isDense: true,
              helperText: '以 .apps.googleusercontent.com 结尾；请勿填账号密码或访问令牌',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _secret,
            enabled: enabled,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Client secret（注册客户端需要时填写）',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed:
                    enabled &&
                        account != null &&
                        validDesktopClientId(_client.text)
                    ? _authorize
                    : null,
                child: const Text('在系统浏览器授权'),
              ),
              TextButton(
                onPressed: enabled ? c.load : null,
                child: const Text('读取本机状态'),
              ),
              TextButton(
                onPressed: enabled && account?.authorized == true
                    ? () => _remove(revoke: false)
                    : null,
                child: const Text('仅移除本机授权'),
              ),
              TextButton(
                onPressed: enabled && account?.authorized == true
                    ? () => _remove(revoke: true)
                    : null,
                child: const Text('撤销 Google 授权'),
              ),
              if (c.busy)
                TextButton(
                  onPressed: () => c.cancel(),
                  child: const Text('取消并等待释放'),
                ),
            ],
          ),
          if (c.busy) const LinearProgressIndicator(),
          if (c.notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(c.notice!),
            ),
          if (c.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                c.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 8),
          const Text('本机授权状态不代表配置已同步；请在对象选择区域明确选择唯一目标，再手动同步或由启用后的配置变更触发。'),
        ],
      ),
    );
  }
}
