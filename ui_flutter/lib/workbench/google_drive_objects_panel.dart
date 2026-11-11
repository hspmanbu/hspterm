import '../prototype/design.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import 'google_drive_objects.dart';

class GoogleDriveObjectsPanel extends StatefulWidget {
  const GoogleDriveObjectsPanel({super.key, required this.controller});
  final GoogleDriveObjectsController controller;
  @override
  State<GoogleDriveObjectsPanel> createState() =>
      _GoogleDriveObjectsPanelState();
}

class _GoogleDriveObjectsPanelState extends State<GoogleDriveObjectsPanel> {
  final _password = TextEditingController();
  final _newPassword = TextEditingController();
  DriveDiscovery? _source;
  DriveConfigurationObject? _selected;
  bool _enabled = false, _replace = false, _confirming = false;
  bool _newEnabled = false, _sensitive = false;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.accounts.addListener(_changed);
    // Only local encrypted metadata, never startup HTTP.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.loadCreation();
    });
  }

  @override
  void didUpdateWidget(GoogleDriveObjectsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      oldWidget.controller.removeListener(_changed);
      oldWidget.controller.accounts.removeListener(_changed);
      widget.controller.addListener(_changed);
      widget.controller.accounts.addListener(_changed);
      _source = null;
      _selected = null;
      _password.clear();
      _newPassword.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.loadCreation();
      });
    }
  }

  void _changed() {
    final current = widget.controller.discovery;
    if (!identical(_source, current)) {
      _source = current;
      _selected = null;
      _enabled = false;
      _replace = false;
      _password.clear();
      _newPassword.clear();
      _sensitive = false;
    }
    if (mounted) setState(() {});
  }

  Future<void> _select() async {
    final c = widget.controller,
        source = widget.controller.discovery,
        object = _selected;
    if (source == null ||
        object == null ||
        c.busy ||
        !c.available ||
        _confirming ||
        _password.value.composing.isValid &&
            !_password.value.composing.isCollapsed) {
      return;
    }
    final same = source.sameTarget(object);
    final password = !same || _replace ? _password.text : null;
    if (password != null &&
        (password.isEmpty || utf8.encode(password).length > 4096)) {
      return;
    }
    final enabled = _enabled;
    final switching = source.settings.target != null && !same;
    setState(() => _confirming = true);
    try {
      if (switching) {
        final confirmed =
            await showAppDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                scrollable: true,
                title: const Text('更换唯一同步目标'),
                content: Text(
                  '将使用集合 ${object.collection} 的对象 ${object.id}。原云端文件不会删除；本机保存原目标基线。此次仅保存选择，不上传配置。确认更换？',
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
        if (!confirmed) return;
      }
      if (!mounted ||
          !identical(c, widget.controller) ||
          !identical(c.discovery, source)) {
        return;
      }
      await c.select(
        source,
        object,
        enabled: enabled,
        password: password,
        confirmTargetChange: switching,
      );
    } finally {
      if (mounted) {
        _password.clear();
        setState(() => _confirming = false);
      }
    }
  }

  Future<void> _prepareNew() async {
    final c = widget.controller, source = widget.controller.discovery;
    if (source == null ||
        !c.available ||
        c.busy ||
        _confirming ||
        !_sensitive ||
        _newPassword.value.composing.isValid &&
            !_newPassword.value.composing.isCollapsed) {
      return;
    }
    final password = _newPassword.text, enabled = _newEnabled;
    if (password.isEmpty || utf8.encode(password).length > 4096) return;
    final switching = source.settings.target != null;
    setState(() => _confirming = true);
    try {
      if (switching &&
          !await _confirm(
            '准备新同步集合',
            '后续确认创建成功后，将以新集合替换当前唯一目标。本机保留旧目标基线，云端旧文件不删除。初始加密快照包含正式凭据及合格命令历史。继续准备？',
          )) {
        return;
      }
      if (!mounted ||
          !identical(c, widget.controller) ||
          !identical(source, c.discovery)) {
        return;
      }
      await c.prepareNew(
        source,
        password: password,
        enabled: enabled,
        confirmTargetChange: switching,
        confirmSensitiveUpload: true,
      );
    } finally {
      if (mounted) {
        _newPassword.clear();
        setState(() => _confirming = false);
      }
    }
  }

  Future<bool> _confirm(String title, String text) async =>
      await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
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
  Future<void> _discard() async {
    final c = widget.controller, source = widget.controller.creation;
    if (source == null || c.busy || _confirming) return;
    setState(() => _confirming = true);
    try {
      if (!await _confirm(
        '仅清除本机创建恢复记录',
        '原对象 ${source.id} 可能已存在云端。此操作不会删除它，但会丢失本机确切加密正文及恢复能力。后续应发现并选择原 ID，不能把清理当作云端删除。确认清除本机记录？',
      )) {
        return;
      }
      if (mounted &&
          identical(c, widget.controller) &&
          identical(source, c.creation)) {
        await c.discardCreation(source);
      }
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.accounts.removeListener(_changed);
    _password.clear();
    _password.dispose();
    _newPassword.clear();
    _newPassword.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, source = widget.controller.discovery;
    final active = c.available && !c.busy && !_confirming;
    final account = c.accounts.account;
    final same =
        source != null && _selected != null && source.sameTarget(_selected!);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Google Drive · 选择配置对象',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            '只在点击后访问本应用的应用数据目录，不列出其他文件。请选择一个对象；同一集合的多个对象不会自动合并或任选。发现不会上传配置。',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: const ValueKey('drive-objects-discover'),
                onPressed:
                    active &&
                        c.canDiscover &&
                        !c.accounts.busy &&
                        account?.authorized == true
                    ? () => c.discover(account!)
                    : null,
                child: const Text('发现已有配置对象'),
              ),
              TextButton(
                onPressed: active && c.canDiscover ? c.loadCreation : null,
                child: const Text('读取本机创建恢复记录'),
              ),
              if (c.busy || c.hasOperation)
                TextButton(
                  onPressed: _confirming ? null : c.cancel,
                  child: const Text('取消发现或选择并释放'),
                ),
            ],
          ),
          if (c.busy) const LinearProgressIndicator(),
          if (source != null) ...[
            const SizedBox(height: 8),
            Text('已发现 ${source.objects.length} 个对象；选择票据最长保留五分钟，过期后请重新发现。'),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: source.objects.length,
                itemBuilder: (context, i) {
                  final object = source.objects[i];
                  return ListTile(
                    dense: true,
                    selected: identical(_selected, object),
                    leading: Icon(
                      identical(_selected, object)
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    title: Text('集合 ${object.collection}'),
                    subtitle: Text(
                      '${object.id} · ${object.bytes} 字节${source.sameTarget(object) ? ' · 当前目标' : ''}',
                    ),
                    onTap: active
                        ? () => setState(() {
                            _selected = object;
                            _replace = false;
                            _password.clear();
                          })
                        : null,
                  );
                },
              ),
            ),
            if (_selected != null) ...[
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('启用选中的唯一同步目标'),
                value: _enabled,
                onChanged: active ? (v) => setState(() => _enabled = v!) : null,
              ),
              if (same)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('明确填写该集合同步密码'),
                  value: _replace,
                  onChanged: active
                      ? (v) => setState(() {
                          _replace = v!;
                          _password.clear();
                        })
                      : null,
                ),
              if (!same || _replace)
                TextField(
                  controller: _password,
                  obscureText: true,
                  enabled: active,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '该集合的端到端同步密码',
                    isDense: true,
                    helperText: '不是 Google 账号密码；本机加密保存，不回显已有秘密',
                  ),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  key: const ValueKey('drive-objects-select'),
                  onPressed: active ? _select : null,
                  child: const Text('保存为唯一同步目标'),
                ),
              ),
            ],
          ],
          if (source != null && c.creation == null) ...[
            const Divider(),
            const Text('新建独立加密集合（不会覆盖已有对象）'),
            TextField(
              controller: _newPassword,
              obscureText: true,
              enabled: active,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '新集合同步密码',
                isDense: true,
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _sensitive,
              title: const Text('同意初始加密快照包含正式凭据和合格命令历史'),
              onChanged: active ? (v) => setState(() => _sensitive = v!) : null,
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _newEnabled,
              title: const Text('确认创建后启用该唯一目标'),
              onChanged: active
                  ? (v) => setState(() => _newEnabled = v!)
                  : null,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: active && _sensitive ? _prepareNew : null,
                child: const Text('准备新集合并核对快照'),
              ),
            ),
          ],
          if (c.creation case final pending?) ...[
            const Divider(),
            Text('待创建或恢复 · ${pending.id}'),
            SelectableText(
              '集合 ${pending.collection} · ${pending.units} 个配置单位 · ${pending.bytes} 字节加密正文',
            ),
            Text(
              pending.attempted
                  ? '曾开始远端写入；必须核对原 ID，不生成替代对象。'
                  : '本机准备已保存；尚未记录开始远端写入。',
            ),
            Text(
              pending.enabled ? '完成后启用该唯一同步目标。' : '完成后保存为禁用目标；手动启用后才参加常规同步。',
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: active ? () => c.finishCreation(pending) : null,
                  child: const Text('核对原 ID 并创建或继续'),
                ),
                TextButton(
                  onPressed: active ? _discard : null,
                  child: const Text('仅清除本机恢复记录'),
                ),
              ],
            ),
          ],
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
        ],
      ),
    );
  }
}
