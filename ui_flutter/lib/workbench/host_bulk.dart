import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/host_bulk.dart';
import 'model.dart';

abstract interface class HostBulkGateway {
  Future<HostBulkView> load(List<String> ids);
  Future<HostBulkView> save(HostBulkView original, HostBulkPatch patch);
}

class NativeHostBulkGateway implements HostBulkGateway {
  NativeHostBulkGateway(this.model);
  final LiveWorkbenchModel model;
  @override
  Future<HostBulkView> load(List<String> ids) =>
      model.runLocalSettings(() => rust.loadHostBulk(ids: ids));
  @override
  Future<HostBulkView> save(HostBulkView original, HostBulkPatch patch) =>
      model.saveHostBulk(original, patch);
}

class HostBulkResult {
  const HostBulkResult({required this.refreshRequired});
  final bool refreshRequired;
}

Future<HostBulkResult?> showHostBulk(
  BuildContext context,
  LiveWorkbenchModel model,
  Set<String> ids,
) => showDialog<HostBulkResult>(
  context: context,
  barrierDismissible: false,
  builder: (_) => HostBulkDialog(
    ids: List.unmodifiable(ids),
    gateway: NativeHostBulkGateway(model),
  ),
);

/// A field's absence means retain each host's own value. A selected false/zero
/// is an explicit change, never confused with absence. No secret patch exists.
List<String> hostBulkImpact(
  HostBulkHost host,
  HostBulkPatch patch,
  Map<String, String> groups,
) {
  final changes = <String>[];
  if (patch.groupId != null && patch.groupId != host.groupId) {
    changes.add(
      '分组：${groups[host.groupId] ?? host.groupId} → ${groups[patch.groupId] ?? patch.groupId}',
    );
  }
  void flag(String label, bool old, bool? value) {
    if (value != null && old != value) {
      changes.add('$label：${old ? '开' : '关'} → ${value ? '开' : '关'}');
    }
  }

  flag('收藏', host.favorite, patch.favorite);
  flag('连接后打开 SFTP', host.openSftp, patch.openSftp);
  flag('跟随 OSC7', host.followOsc7, patch.followOsc7);
  final network = patch.network;
  if (network != null) {
    final old = host.network;
    if (network.useDefaults) {
      if (!old.useDefaults) changes.add('网络：主机覆盖 → 继承全局（保留原覆盖值）');
    } else {
      if (old.useDefaults) changes.add('网络：继承全局 → 主机覆盖');
      if (old.timeoutSeconds != network.timeoutSeconds) {
        changes.add('连接超时：${old.timeoutSeconds}s → ${network.timeoutSeconds}s');
      }
      if (old.keepaliveSeconds != network.keepaliveSeconds) {
        changes.add(
          '心跳：${old.keepaliveSeconds}s → ${network.keepaliveSeconds}s（0关闭）',
        );
      }
      if (old.keepaliveResponseSeconds != network.keepaliveResponseSeconds) {
        changes.add(
          '响应超时：${old.keepaliveResponseSeconds?.toString() ?? '旧兼容模式'} → ${network.keepaliveResponseSeconds?.toString() ?? '旧兼容模式'}',
        );
      }
      if (old.keepaliveFailures != network.keepaliveFailures) {
        changes.add(
          '失败阈值：${old.keepaliveFailures} → ${network.keepaliveFailures}',
        );
      }
    }
  }
  return changes;
}

class HostBulkDialog extends StatefulWidget {
  const HostBulkDialog({super.key, required this.ids, required this.gateway});
  final List<String> ids;
  final HostBulkGateway gateway;
  @override
  State<HostBulkDialog> createState() => _HostBulkDialogState();
}

class _HostBulkDialogState extends State<HostBulkDialog> {
  HostBulkView? _source;
  String? _error, _status, _group;
  bool _busy = false, _io = false, _saved = false, _refreshRequired = false;
  final _fields = <String>{};
  bool _favorite = true, _sftp = true, _follow = false, _inherit = true;
  final _timeout = TextEditingController(text: '30'),
      _heartbeat = TextEditingController(text: '30'),
      _response = TextEditingController(text: '10'),
      _failures = TextEditingController(text: '3');
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _timeout.dispose();
    _heartbeat.dispose();
    _response.dispose();
    _failures.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy || _saved) return;
    setState(() {
      _busy = true;
      _io = true;
      _source = null;
      _error = null;
      _fields.clear();
    });
    try {
      final value = await widget.gateway.load(List.of(widget.ids));
      final expected = widget.ids.toSet();
      if (expected.isEmpty ||
          expected.length != widget.ids.length ||
          value.hosts.length != expected.length ||
          value.hosts.map((h) => h.id).toSet().length != expected.length ||
          value.hosts.any((h) => !expected.contains(h.id)) ||
          value.groups.map((g) => g.id).toSet().length != value.groups.length ||
          value.hosts.any((h) => !value.groups.any((g) => g.id == h.groupId))) {
        throw StateError('预览内容与所选主机不一致');
      }
      if (!mounted) return;
      final first = value.hosts.first;
      setState(() {
        _source = HostBulkView(
          vaultScope: value.vaultScope,
          revision: value.revision,
          groups: List.unmodifiable(value.groups),
          hosts: List.unmodifiable(value.hosts),
        );
        _group = first.groupId;
        _favorite = first.favorite;
        _sftp = first.openSftp;
        _follow = first.followOsc7;
        _inherit = first.network.useDefaults;
        _timeout.text = '${first.network.timeoutSeconds}';
        _heartbeat.text = '${first.network.keepaliveSeconds}';
        _response.text = '${first.network.keepaliveResponseSeconds ?? 10}';
        _failures.text = '${first.network.keepaliveFailures}';
      });
    } catch (error) {
      if (mounted) setState(() => _error = '未载入可编辑预览：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  HostBulkPatch _patch() {
    int number(TextEditingController c, int min, int max, String name) {
      final n = int.tryParse(c.text);
      if (n == null || n < min || n > max) {
        throw FormatException('$name须为$min–$max的整数');
      }
      return n;
    }

    if (_fields.isEmpty) throw const FormatException('先勾选需要修改的字段');
    final useNetwork = _fields.contains('network');
    // Inherit ignores dormant text. They are not sent as accidental overrides.
    final network = !useNetwork
        ? null
        : _inherit
        ? HostBulkNetwork(
            useDefaults: true,
            timeoutSeconds: 30,
            keepaliveSeconds: 30,
            keepaliveResponseSeconds: null,
            keepaliveFailures: 3,
          )
        : HostBulkNetwork(
            useDefaults: false,
            timeoutSeconds: number(_timeout, 1, 3600, '连接超时'),
            keepaliveSeconds: number(_heartbeat, 0, 86400, '心跳间隔'),
            keepaliveResponseSeconds: number(_response, 1, 3600, '响应超时'),
            keepaliveFailures: number(_failures, 1, 100, '失败阈值'),
          );
    return HostBulkPatch(
      groupId: _fields.contains('group') ? _group : null,
      favorite: _fields.contains('favorite') ? _favorite : null,
      openSftp: _fields.contains('sftp') ? _sftp : null,
      followOsc7: _fields.contains('follow') ? _follow : null,
      network: network,
    );
  }

  Future<void> _apply() async {
    final source = _source;
    if (_busy || _saved || source == null) return;
    if ([
      _timeout,
      _heartbeat,
      _response,
      _failures,
    ].any((c) => c.value.composing.isValid && !c.value.composing.isCollapsed)) {
      setState(() => _error = '请先确认输入法候选，再保存参数');
      return;
    }
    late final HostBulkPatch patch;
    try {
      patch = _patch();
    } catch (error) {
      setState(() => _error = '$error');
      return;
    }
    final groups = {for (final g in source.groups) g.id: g.name};
    final affected = source.hosts
        .where((h) => hostBulkImpact(h, patch, groups).isNotEmpty)
        .length;
    if (affected == 0) {
      setState(() => _error = '所选字段与原值相同，没有需要保存的修改');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final answer = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('保存 $affected 台主机的批量修改？'),
          content: const Text(
            '仅应用已勾选并在预览中列出的字段，不会重连 SSH 或重启传输。网络与连接后打开 SFTP 仅下次连接生效；OSC7 跟随偏好可影响现有会话后续目录报告。',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('host-bulk-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存配置'),
            ),
          ],
        ),
      );
      if (!mounted || answer != true) return;
      setState(() => _io = true);
      try {
        await widget.gateway.save(source, patch);
        if (mounted) {
          setState(() {
            _saved = true;
            _status = '配置已原子保存；运行中的会话未重连。';
          });
        }
      } on HostBulkRefreshFailure catch (error) {
        if (mounted) {
          setState(() {
            _saved = true;
            _refreshRequired = true;
            _status = '原配置已保存，主机列表刷新失败。请关闭后重新载入，不要重复应用。';
            _error = '${error.cause}';
          });
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = '未确认保存成功：$error。原预览可能已过期，请重新载入后检查。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _io = false;
        });
      }
    }
  }

  Widget _select(String id, String title, Widget input) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      CheckboxListTile(
        key: ValueKey('host-bulk-field-$id'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(title),
        value: _fields.contains(id),
        onChanged: (value) => setState(() {
          if (value == true) {
            _fields.add(id);
          } else {
            _fields.remove(id);
          }
        }),
      ),
      if (_fields.contains(id)) input,
    ],
  );
  Widget _flag(
    String id,
    String title,
    bool value,
    ValueChanged<bool> change,
  ) => _select(
    id,
    title,
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(value ? '设为开启' : '设为关闭'),
      value: value,
      onChanged: (v) => setState(() => change(v)),
    ),
  );
  Widget _number(String id, String label, TextEditingController controller) =>
      SizedBox(
        width: 140,
        child: TextField(
          key: ValueKey('host-bulk-$id'),
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: label),
          onChanged: (_) => setState(() {}),
        ),
      );
  @override
  Widget build(BuildContext context) {
    final source = _source;
    HostBulkPatch? preview;
    String? validation;
    if (source != null && _fields.isNotEmpty) {
      try {
        preview = _patch();
      } catch (error) {
        validation = '$error';
      }
    }
    final groups = {
      for (final g in source?.groups ?? <rust.HostGroupConfig>[]) g.id: g.name,
    };
    return PopScope(
      canPop: !_busy,
      child: Dialog(
        child: SizedBox(
          width: 680,
          height: math.min(
            680.0,
            math.max(260.0, MediaQuery.sizeOf(context).height - 80),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '批量编辑 ${widget.ids.length} 台主机',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_io) const LinearProgressIndicator(),
                const SizedBox(height: 10),
                Expanded(
                  child: AbsorbPointer(
                    absorbing: _busy || _saved,
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            '只勾选要修改的非敏感字段。地址、用户名、认证、密钥、代理、跳板、转发及 Agent 授权不参与批量编辑。',
                          ),
                          if (source != null) ...[
                            _select(
                              'group',
                              '修改分组',
                              DropdownButtonFormField<String>(
                                key: const ValueKey('host-bulk-group'),
                                initialValue: _group,
                                items: [
                                  for (final g in source.groups)
                                    DropdownMenuItem(
                                      value: g.id,
                                      child: Text(g.name),
                                    ),
                                ],
                                onChanged: (v) => setState(() => _group = v),
                              ),
                            ),
                            _flag(
                              'favorite',
                              '修改收藏',
                              _favorite,
                              (v) => _favorite = v,
                            ),
                            _flag(
                              'sftp',
                              '修改连接后打开 SFTP',
                              _sftp,
                              (v) => _sftp = v,
                            ),
                            _flag(
                              'follow',
                              '修改跟随可信 OSC7 目录',
                              _follow,
                              (v) => _follow = v,
                            ),
                            _select(
                              'network',
                              '修改网络参数（继承或一组明确覆盖）',
                              Column(
                                children: [
                                  SwitchListTile(
                                    key: const ValueKey('host-bulk-inherit'),
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    title: const Text('继承全局网络配置'),
                                    value: _inherit,
                                    onChanged: (v) =>
                                        setState(() => _inherit = v),
                                  ),
                                  if (!_inherit)
                                    Wrap(
                                      spacing: 10,
                                      runSpacing: 12,
                                      children: [
                                        _number('timeout', '连接超时（秒）', _timeout),
                                        _number(
                                          'heartbeat',
                                          '心跳（秒，0关闭）',
                                          _heartbeat,
                                        ),
                                        _number(
                                          'response',
                                          '响应超时（秒）',
                                          _response,
                                        ),
                                        _number('failures', '失败阈值', _failures),
                                      ],
                                    ),
                                  const Text('继承仅改开关，保留每台主机原覆盖值；参数只在下次明确连接生效。'),
                                ],
                              ),
                            ),
                            const Divider(),
                            Text('逐台影响预览（${source.hosts.length} 台）'),
                            if (validation != null)
                              Text(
                                validation,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            SizedBox(
                              height: 180,
                              child: ListView.builder(
                                key: const ValueKey('host-bulk-preview'),
                                itemCount: source.hosts.length,
                                itemBuilder: (context, index) {
                                  final host = source.hosts[index];
                                  final proposal = preview;
                                  final changes = proposal == null
                                      ? <String>[]
                                      : hostBulkImpact(host, proposal, groups);
                                  return ListTile(
                                    dense: true,
                                    title: Text(host.name),
                                    subtitle: Text(
                                      changes.isEmpty
                                          ? '保留原值'
                                          : changes.join('；'),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (_status != null)
                  Text(_status!, key: const ValueKey('host-bulk-status')),
                if (_error != null)
                  Text(
                    _error!,
                    key: const ValueKey('host-bulk-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.pop(
                              context,
                              _saved
                                  ? HostBulkResult(
                                      refreshRequired: _refreshRequired,
                                    )
                                  : null,
                            ),
                      child: Text(_saved ? '完成' : '取消'),
                    ),
                    if (!_saved)
                      TextButton(
                        key: const ValueKey('host-bulk-reload'),
                        onPressed: _busy ? null : _load,
                        child: const Text('重新载入'),
                      ),
                    if (!_saved)
                      FilledButton(
                        key: const ValueKey('host-bulk-apply'),
                        onPressed: _busy || source == null || preview == null
                            ? null
                            : _apply,
                        child: const Text('预览确认并保存'),
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
