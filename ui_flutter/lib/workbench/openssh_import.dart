import 'dart:convert';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/openssh_import.dart';

abstract interface class OpenSshImportGateway {
  Future<List<rust.HostGroupConfig>> groups();
  Future<OpenSshImportPreview> preview(String source, String username);
  Future<List<rust.HostConfig>> save({
    required String source,
    required String username,
    required List<String> aliases,
    required bool acknowledge,
    required String group,
    required String scope,
  });
}

class NativeOpenSshImportGateway implements OpenSshImportGateway {
  const NativeOpenSshImportGateway();
  @override
  Future<List<rust.HostGroupConfig>> groups() => rust.hostGroups();
  @override
  Future<OpenSshImportPreview> preview(String source, String username) =>
      rust.previewOpensshImport(source: source, defaultUsername: username);
  @override
  Future<List<rust.HostConfig>> save({
    required String source,
    required String username,
    required List<String> aliases,
    required bool acknowledge,
    required String group,
    required String scope,
  }) => rust.commitOpensshImport(
    source: source,
    defaultUsername: username,
    aliases: aliases,
    acknowledgePartial: acknowledge,
    groupId: group,
    vaultScope: scope,
  );
}

/// The source snapshot and warnings remain only in this dialog's memory.
/// Nothing is persisted or connected until the explicit import button succeeds.
class OpenSshImportDialog extends StatefulWidget {
  const OpenSshImportDialog({
    super.key,
    this.gateway = const NativeOpenSshImportGateway(),
    this.chooseFile,
  });
  final OpenSshImportGateway gateway;
  final Future<XFile?> Function()? chooseFile;
  @override
  State<OpenSshImportDialog> createState() => _OpenSshImportDialogState();
}

class _OpenSshImportDialogState extends State<OpenSshImportDialog> {
  final source = TextEditingController(), username = TextEditingController();
  final selected = <String>{};
  List<rust.HostGroupConfig>? groups;
  String? group, error;
  OpenSshImportPreview? preview;
  bool busy = true, acknowledge = false;
  String _sourceSnapshot = '', _usernameSnapshot = '';
  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  Future<void> _loadGroups() async {
    try {
      final loaded = await widget.gateway.groups();
      if (loaded.isEmpty) throw StateError('没有可用主机分组，请关闭后重新载入');
      if (mounted) {
        setState(() {
          groups = loaded;
          group = loaded.first.id;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    source.dispose();
    username.dispose();
    super.dispose();
  }

  Future<void> _file() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final file =
          await (widget.chooseFile?.call() ??
              openFile(confirmButtonText: '读取SSH配置'));
      if (file == null) return;
      // Enforce both advertised and streamed size; no unbounded readAsBytes.
      if (await file.length().timeout(const Duration(seconds: 10)) >
          1024 * 1024) {
        throw StateError('配置超过1MiB限制');
      }
      final bytes = <int>[];
      await for (final chunk in file.openRead().timeout(
        const Duration(seconds: 10),
      )) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          throw StateError('配置超过1MiB限制');
        }
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: false);
      if (mounted) {
        setState(() {
          source.text = text;
          preview = null;
          selected.clear();
          acknowledge = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法读取配置：需要不超过1MiB的UTF-8文本；未访问其他文件。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _preview() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final captured = source.text, user = username.text.trim();
      final result = await widget.gateway.preview(captured, user);
      if (!mounted) return;
      setState(() {
        preview = result;
        _sourceSnapshot = captured;
        _usernameSnapshot = user;
        selected.clear();
        acknowledge = false;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  bool get warnings =>
      (preview?.warnings.isNotEmpty ?? false) ||
      (preview?.hosts.any(
            (h) => selected.contains(h.alias) && h.warnings.isNotEmpty,
          ) ??
          false);
  Future<void> _save() async {
    final p = preview;
    if (p == null ||
        group == null ||
        selected.isEmpty ||
        busy ||
        (warnings && !acknowledge)) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.gateway.save(
        source: _sourceSnapshot,
        username: _usernameSnapshot,
        aliases: p.hosts
            .where((h) => selected.contains(h.alias))
            .map((h) => h.alias)
            .toList(),
        acknowledge: acknowledge,
        group: group!,
        scope: p.vaultScope,
      );
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  Widget _source() => ListView(
    children: [
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          SizedBox(
            width: 230,
            child: TextField(
              key: const ValueKey('ssh-import-user'),
              controller: username,
              enabled: !busy,
              maxLength: 1024,
              decoration: const InputDecoration(
                labelText: '缺少User时的默认用户名',
                counterText: '',
              ),
            ),
          ),
          OutlinedButton.icon(
            key: const ValueKey('ssh-import-file'),
            onPressed: busy ? null : _file,
            icon: const Icon(Icons.file_open_outlined, size: 16),
            label: const Text('选择配置文件'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        key: const ValueKey('ssh-import-source'),
        controller: source,
        enabled: !busy,
        minLines: 8,
        maxLines: 14,
        maxLength: 1024 * 1024,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: const InputDecoration(
          labelText: 'OpenSSH Config（UTF-8）',
          alignLabelWithHint: true,
          hintText:
              'Host example\n  HostName server.example\n  User user\n  Port 22',
        ),
      ),
      const Text('只为明确Host别名生成候选；通配符用于默认值，不生成主机。缺少用户名时请明确填写。'),
    ],
  );
  Widget _previewList() {
    final p = preview!;
    final selectable = p.hosts
        .where((h) => !h.blocked && !h.nameExists)
        .toList();
    return ListView(
      children: [
        if (p.hosts.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('没有可导入的明确Host别名。'),
          ),
        for (final warning in p.warnings)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(warning),
          ),
        CheckboxListTile(
          key: const ValueKey('ssh-import-select-all'),
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('选择全部可导入主机'),
          value:
              selectable.isNotEmpty &&
              selectable.every((h) => selected.contains(h.alias)),
          onChanged: busy
              ? null
              : (value) => setState(() {
                  selected.clear();
                  if (value == true) {
                    selected.addAll(selectable.map((h) => h.alias));
                  }
                  acknowledge = false;
                }),
        ),
        for (final h in p.hosts)
          CheckboxListTile(
            key: ValueKey('ssh-import-host-${h.alias}'),
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            isThreeLine: false,
            value: selected.contains(h.alias),
            onChanged: busy || h.blocked || h.nameExists
                ? null
                : (value) => setState(() {
                    if (value == true) {
                      selected.add(h.alias);
                    } else {
                      selected.remove(h.alias);
                    }
                    acknowledge = false;
                  }),
            title: Text('${h.alias}  ·  ${h.username}@${h.address}:${h.port}'),
            subtitle: Text(
              [
                '${h.privateKey ? '私钥认证（密钥未导入）' : '密码认证（密码未配置）'}；连接${h.timeoutSeconds}s；心跳${h.keepaliveSeconds}s/${h.keepaliveFailures}次',
                if (h.jumpAlias != null) '跳板：${h.jumpAlias}（须同时选择）',
                if (h.nameExists) '同名主机已存在，禁止覆盖；修改源别名后重新预览',
                if (h.blocked) '不可导入：请修正源内容后重新预览',
                ...h.warnings,
              ].join('\n'),
            ),
          ),
        if (warnings)
          CheckboxListTile(
            key: const ValueKey('ssh-import-ack'),
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: acknowledge,
            onChanged: busy
                ? null
                : (v) => setState(() => acknowledge = v ?? false),
            title: const Text('已核对警告与所有连接参数；仅导入预览列出的字段，未转换的设置不会生效'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return PopScope(
      canPop: !busy,
      child: Dialog(
        child: SizedBox(
          width: math.min(920, size.width - 32),
          height: math.min(
            680,
            size.height - MediaQuery.viewInsetsOf(context).bottom - 48,
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '导入 OpenSSH Config',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text(
                  '显式导入主机元数据，不读取私钥、不执行命令或Match、不自动展开Include、不连接SSH。保存后需在认证页配置凭据。',
                ),
                const SizedBox(height: 12),
                if (busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(child: preview == null ? _source() : _previewList()),
                if (error != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 72),
                    child: SingleChildScrollView(
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (preview != null && groups != null)
                      SizedBox(
                        width: 180,
                        child: DropdownButtonFormField<String>(
                          key: const ValueKey('ssh-import-group'),
                          initialValue: group,
                          decoration: const InputDecoration(labelText: '保存分组'),
                          items: groups!
                              .map(
                                (g) => DropdownMenuItem(
                                  value: g.id,
                                  child: Text(
                                    g.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: busy
                              ? null
                              : (v) => setState(() => group = v),
                        ),
                      ),
                    TextButton(
                      key: const ValueKey('ssh-import-cancel'),
                      onPressed: busy ? null : () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    if (preview != null)
                      TextButton(
                        key: const ValueKey('ssh-import-back'),
                        onPressed: busy
                            ? null
                            : () => setState(() => preview = null),
                        child: const Text('修改源内容'),
                      ),
                    if (preview == null)
                      FilledButton(
                        key: const ValueKey('ssh-import-preview'),
                        onPressed: busy || groups == null ? null : _preview,
                        child: const Text('解析并预览'),
                      )
                    else
                      FilledButton(
                        key: const ValueKey('ssh-import-save'),
                        onPressed:
                            busy ||
                                selected.isEmpty ||
                                (warnings && !acknowledge)
                            ? null
                            : _save,
                        child: Text('导入所选 ${selected.length} 台'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
