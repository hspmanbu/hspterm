import '../prototype/design.dart';

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'configuration_backup.dart';

abstract interface class ConfigurationBackupFiles {
  Future<String?> open();
  Future<String?> save();
}

class NativeConfigurationBackupFiles implements ConfigurationBackupFiles {
  const NativeConfigurationBackupFiles();
  @override
  Future<String?> open() async => (await openFile(
    acceptedTypeGroups: [
      const XTypeGroup(label: 'HSPTerm 加密备份', extensions: ['hspbackup']),
    ],
  ))?.path;
  @override
  Future<String?> save() async => (await getSaveLocation(
    suggestedName: 'HSPTerm-backup.hspbackup',
    acceptedTypeGroups: [
      const XTypeGroup(label: 'HSPTerm 加密备份', extensions: ['hspbackup']),
    ],
  ))?.path;
}

class ConfigurationBackupPanel extends StatefulWidget {
  const ConfigurationBackupPanel({
    super.key,
    required this.controller,
    this.files = const NativeConfigurationBackupFiles(),
  });
  final ConfigurationBackupController controller;
  final ConfigurationBackupFiles files;
  @override
  State<ConfigurationBackupPanel> createState() =>
      _ConfigurationBackupPanelState();
}

class _ConfigurationBackupPanelState extends State<ConfigurationBackupPanel> {
  late final Object _owner;
  bool _dialog = false;
  String _filter = '';
  ConfigurationBackupController get c => widget.controller;
  bool get busy => _dialog || c.busy;
  @override
  void initState() {
    super.initState();
    _owner = c.attach();
    c.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && c.summary == null && !c.busy) unawaited(c.load());
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    c.detach(_owner);
    super.dispose();
  }

  Future<_Passwords?> _passwords(String kind) => showAppDialog<_Passwords>(
    context: context,
    builder: (_) => _BackupPasswordDialog(kind: kind),
  );
  Future<void> _export() async {
    if (busy || c.summary == null) return;
    setState(() => _dialog = true);
    try {
      final location = await widget.files.save();
      if (!mounted || location == null) return;
      final input = await _passwords('export');
      if (!mounted || input == null) return;
      await c.export(location, input.current, input.backup);
    } catch (error) {
      c.reportFailure('无法完成备份文件选择或确认：$error');
    } finally {
      if (mounted) setState(() => _dialog = false);
    }
  }

  Future<void> _prepare() async {
    if (busy) return;
    setState(() => _dialog = true);
    try {
      final file = await widget.files.open();
      if (!mounted || file == null) return;
      final input = await _passwords('import');
      if (!mounted || input == null) return;
      await c.prepare(_owner, file, input.backup, 'merge');
    } catch (error) {
      c.reportFailure('无法完成备份选择或密码确认：$error');
    } finally {
      if (mounted) setState(() => _dialog = false);
    }
  }

  Future<void> _apply() async {
    final original = c.preview;
    if (busy || original == null) return;
    final selected = Set<String>.unmodifiable(c.selectedIncoming);
    final additions = original.preview.items
        .where((i) => selected.contains(i.id) && !i.local && i.incoming)
        .length;
    final removals = original.preview.items
        .where((i) => selected.contains(i.id) && i.local && !i.incoming)
        .length;
    final replacements = original.preview.items
        .where(
          (i) =>
              selected.contains(i.id) &&
              i.local &&
              i.incoming &&
              i.state != 'same',
        )
        .length;
    setState(() => _dialog = true);
    try {
      final accepted = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('原子恢复所选配置？'),
          scrollable: true,
          content: Text(
            '新增 $additions 项，替换 $replacements 项，移除 $removals 项。\n包含所选主机凭据、服务器信任、书签、用户配置、单行命令历史和本机字体副本；旧清除标记仍阻止旧历史回灌。\n已有 SSH/PTY/SFTP 保持连接。旧配置确认和 Agent 授权将撤销，需要重新明确授权。草稿、任务、编辑正文、屏幕、滚动历史和布局不恢复。\n失败不覆盖数据库；若已进入提交准备，Agent 授权可能已被保守撤销。',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('backup-confirm-restore'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续并验证主密码'),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true) return;
      final input = await _passwords('apply');
      if (!mounted || input == null) return;
      await c.apply(_owner, original, selected, input.current);
    } catch (error) {
      c.reportFailure('无法完成恢复确认：$error');
    } finally {
      if (mounted) setState(() => _dialog = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = c.preview;
    final rows =
        preview?.preview.items
            .where(
              (i) =>
                  _filter.isEmpty ||
                  '${i.label} ${i.category}'.toLowerCase().contains(
                    _filter.toLowerCase(),
                  ),
            )
            .toList(growable: false) ??
        <ConfigurationDiff>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('完整加密备份与恢复'),
        const SizedBox(height: 8),
        const Text(
          '加密备份包含主机、凭据、信任、书签、设置、命令历史和导入字体；不包含终端画面、滚动历史、编辑正文、草稿、任务或布局。',
        ),
        const SizedBox(height: 12),
        if (c.busy) const LinearProgressIndicator(),
        if (c.summary != null)
          Text(
            '当前库：${c.summary!.localHosts} 个正式主机；${c.summary!.items.length} 项配置单元',
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey('backup-export'),
              onPressed: busy || c.summary == null ? null : _export,
              icon: const Icon(Icons.lock_outline, size: 16),
              label: const Text('创建加密备份'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('backup-open'),
              onPressed: busy ? null : _prepare,
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('选择备份并预览'),
            ),
            TextButton(
              key: const ValueKey('backup-load'),
              onPressed: busy ? null : c.load,
              child: const Text('重新读取本机配置'),
            ),
          ],
        ),
        if (c.status != null)
          SelectableText(c.status!, key: const ValueKey('backup-status')),
        if (c.error != null)
          SelectableText(
            c.error!,
            key: const ValueKey('backup-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (c.committed)
          TextButton(
            key: const ValueKey('backup-refresh-committed'),
            onPressed: busy ? null : c.refreshCommitted,
            child: const Text('重新载入已恢复配置（不重复恢复）'),
          ),
        if (preview != null) ...[
          const Divider(height: 24),
          Text(
            '恢复预览 · 本机 ${preview.preview.localHosts} 主机 / 备份 ${preview.preview.incomingHosts} 主机',
          ),
          const Text(
            '勾选表示使用备份；不勾选保留本机。备份不存在的勾选项会从正式配置中移除。合并默认保留本机冲突；替换默认采用备份。分组、跳板及关联凭据须保持完整，否则整次恢复拒绝提交。',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ChoiceChip(
                label: const Text('合并 · 冲突保留本机'),
                selected: preview.preview.mode == 'merge',
                onSelected: busy ? null : (_) => c.mode(_owner, 'merge'),
              ),
              ChoiceChip(
                label: const Text('替换 · 默认使用备份'),
                selected: preview.preview.mode == 'replace',
                onSelected: busy ? null : (_) => c.mode(_owner, 'replace'),
              ),
              TextButton(
                onPressed: busy ? null : () => c.selectAll(false),
                child: const Text('全部保留本机'),
              ),
              TextButton(
                onPressed: busy ? null : () => c.selectAll(true),
                child: const Text('全部使用备份'),
              ),
            ],
          ),
          TextField(
            key: const ValueKey('backup-filter'),
            decoration: const InputDecoration(
              labelText: '筛选恢复项目',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 320,
            child: ListView.builder(
              key: const ValueKey('backup-differences'),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final item = rows[index];
                final state = switch (item.state) {
                  'same' => '相同',
                  'added' => '仅备份存在',
                  'local_only' => '仅本机存在',
                  _ => '内容不同',
                };
                return CheckboxListTile(
                  key: ValueKey('backup-item-${item.id}'),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  value: c.selectedIncoming.contains(item.id),
                  onChanged: busy ? null : (v) => c.select(item.id, v == true),
                  title: Text(
                    '${item.label} · $state',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${item.category}${item.sensitive ? ' · 含凭据/信任/历史变更' : ''}\n本机：${item.localSummary ?? '不存在'}\n备份：${item.incomingSummary ?? '不存在（采用备份将移除本机项）'}',
                  ),
                  isThreeLine: true,
                );
              },
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const ValueKey('backup-apply'),
                onPressed: busy || !c.hasChanges ? null : _apply,
                child: const Text('确认恢复所选项'),
              ),
              TextButton(
                key: const ValueKey('backup-cancel-preview'),
                onPressed: busy ? null : c.closePreview,
                child: const Text('关闭预览，不恢复'),
              ),
            ],
          ),
        ],
        const Divider(height: 24),
        const Text('此处备份到本机文件；配置同步在下方设置。'),
      ],
    );
  }
}

class _Passwords {
  const _Passwords(this.current, this.backup);
  final String current, backup;
}

class _BackupPasswordDialog extends StatefulWidget {
  const _BackupPasswordDialog({required this.kind});
  final String kind;
  @override
  State<_BackupPasswordDialog> createState() => _BackupPasswordDialogState();
}

class _BackupPasswordDialogState extends State<_BackupPasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController(),
      _backup = TextEditingController(),
      _repeat = TextEditingController();
  void _submit() {
    if (!_form.currentState!.validate()) return;
    final answer = _Passwords(_current.text, _backup.text);
    _current.clear();
    _backup.clear();
    _repeat.clear();
    Navigator.pop(context, answer);
  }

  @override
  void dispose() {
    _current.clear();
    _backup.clear();
    _repeat.clear();
    _current.dispose();
    _backup.dispose();
    _repeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(switch (widget.kind) {
      'export' => '创建加密备份',
      'import' => '解密备份以预览',
      _ => '验证当前主密码并恢复',
    }),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.kind != 'import')
              TextFormField(
                key: const ValueKey('backup-current-password'),
                controller: _current,
                obscureText: true,
                autofocus: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '当前配置库主密码'),
                validator: (v) => v == null || v.isEmpty ? '请输入当前主密码' : null,
              ),
            if (widget.kind != 'apply')
              TextFormField(
                key: const ValueKey('backup-file-password'),
                controller: _backup,
                obscureText: true,
                autofocus: widget.kind == 'import',
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: widget.kind == 'export' ? '备份文件独立密码' : '备份文件密码',
                ),
                validator: (v) => v == null || v.isEmpty ? '请输入备份密码' : null,
              ),
            if (widget.kind == 'export')
              TextFormField(
                key: const ValueKey('backup-repeat-password'),
                controller: _repeat,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '再次输入备份密码'),
                validator: (v) => v != _backup.text ? '两次备份密码不一致' : null,
              ),
            const SizedBox(height: 12),
            const Text('密码只用于本次原生操作，不保存在设置、日志或剪贴板中。请妥善保存备份密码；应用无法找回。'),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('backup-password-submit'),
        onPressed: _submit,
        child: Text(widget.kind == 'apply' ? '验证并恢复' : '确认'),
      ),
    ],
  );
}
