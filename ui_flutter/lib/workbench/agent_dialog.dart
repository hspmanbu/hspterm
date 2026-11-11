import '../app_notice.dart';
import '../prototype/design.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/agents.dart';
import 'model.dart';

class AgentSession {
  const AgentSession(
    this.id,
    this.generation,
    this.label, {
    required this.current,
    this.lifecycle,
    this.updates,
  });
  final int id, generation;
  final String label;
  final bool Function() current;
  final Listenable? lifecycle, updates;
}

abstract interface class AgentGateway {
  Future<AgentView> state(AgentSession source);
  Future<List<AgentKeyOption>> keys();
  Future<AgentPreview> prepare(
    AgentSession source,
    List<String> hosts,
    int seconds,
  );
  Future<AgentView> approve(AgentSession source, String ticket);
  Future<void> cancel(AgentSession source, String ticket);
  Future<AgentView> revoke(AgentSession source);
}

class NativeAgentGateway implements AgentGateway {
  const NativeAgentGateway();
  @override
  Future<AgentView> state(AgentSession s) =>
      rust.terminalAgentState(id: s.id, generation: s.generation);
  @override
  Future<List<AgentKeyOption>> keys() => rust.agentKeyOptions();
  @override
  Future<AgentPreview> prepare(
    AgentSession s,
    List<String> hosts,
    int seconds,
  ) => rust.prepareAgentAuthorisation(
    id: s.id,
    generation: s.generation,
    hostIds: hosts,
    seconds: seconds,
  );
  @override
  Future<AgentView> approve(AgentSession s, String ticket) =>
      rust.approveAgentAuthorisation(
        id: s.id,
        generation: s.generation,
        ticket: ticket,
      );
  @override
  Future<void> cancel(AgentSession s, String ticket) =>
      rust.cancelAgentAuthorisation(id: s.id, ticket: ticket);
  @override
  Future<AgentView> revoke(AgentSession s) =>
      rust.revokeTerminalAgent(id: s.id, generation: s.generation);
}

Future<void> showTerminalAgent(
  BuildContext context,
  LiveWorkbenchModel model,
  LiveTerminalSession session,
) async {
  final native = session.controller.id;
  if (native == null) {
    showAppNotice(
      context,
      '终端仍在初始化，请稍后打开 Agent 管理',
      level: AppNoticeLevel.warning,
    );
    return;
  }
  final generation = session.controller.generation;
  final source = AgentSession(
    native,
    generation,
    session.host.name,
    current: () =>
        session.controller.id == native &&
        session.controller.generation == generation &&
        session.controller.connected &&
        model.tabs.any((t) => t.sessionId == session.id),
    lifecycle: Listenable.merge([session.controller, model]),
    updates: session.controller.agentChanges,
  );
  await showAppDialog<void>(
    context: context,
    builder: (_) => AgentDialog(source: source),
  );
}

class AgentDialog extends StatefulWidget {
  const AgentDialog({
    super.key,
    required this.source,
    this.gateway = const NativeAgentGateway(),
  });
  final AgentSession source;
  final AgentGateway gateway;
  @override
  State<AgentDialog> createState() => _AgentDialogState();
}

class _AgentDialogState extends State<AgentDialog> {
  AgentView? _state;
  late final ValueNotifier<bool> _valid;
  List<AgentKeyOption> _keys = const [];
  final _selected = <String>{};
  bool _fetching = false, _again = false, _busy = false, _confirming = false;
  String? _error;
  int _minutes = 5;
  AgentSession get source => widget.source;
  AgentGateway get gateway => widget.gateway;
  @override
  void initState() {
    super.initState();
    _valid = ValueNotifier(source.current());
    source.lifecycle?.addListener(_lifecycleUpdated);
    source.updates?.addListener(_updated);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    source.lifecycle?.removeListener(_lifecycleUpdated);
    _valid.dispose();
    source.updates?.removeListener(_updated);
    super.dispose();
  }

  void _lifecycleUpdated() {
    if (!mounted) return;
    final current = source.current();
    // Controller also emits painting changes. Those must never query the Vault
    // or rebuild a consent dialog on each SSH output frame.
    if (_valid.value == current) return;
    _valid.value = current;
    _updated();
  }

  void _updated() {
    if (!mounted) return;
    if (!source.current()) {
      setState(() => _error = '原终端已断开、关闭或重连；本窗口不会授权到其他会话。');
      return;
    }
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_fetching || _busy) {
      _again = true;
      return;
    }
    if (!source.current()) {
      _updated();
      return;
    }
    _fetching = true;
    try {
      final state = await gateway.state(source);
      if (!mounted || !source.current()) return;
      setState(() => _state = state);
      // Failure to read key metadata must not hide the existing grant or its
      // revoke action. No private material is loaded by this list operation.
      final keys = await gateway.keys();
      if (!mounted || !source.current()) return;
      setState(() {
        _keys = keys;
        _selected.removeWhere((id) => !_keys.any((key) => key.hostId == id));
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      _fetching = false;
      if (mounted) setState(() {});
      if (_again && mounted && source.current()) {
        _again = false;
        unawaited(_refresh());
      }
    }
  }

  Future<void> _authorise() async {
    if (_busy || !source.current() || _selected.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    AgentPreview? preview;
    var consumed = false;
    try {
      final prepared = await gateway.prepare(
        source,
        List.unmodifiable(_selected),
        _minutes * 60,
      );
      preview = prepared;
      if (!mounted || !source.current()) return;
      var acceptedRisk = false;
      setState(() => _confirming = true);
      final approved = await showAppDialog<bool>(
        context: context,
        builder: (context) => ValueListenableBuilder<bool>(
          valueListenable: _valid,
          builder: (context, valid, _) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
              scrollable: true,
              title: const Text('确认本次限时密钥授权'),
              content: SizedBox(
                width: 520,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      '实际目标：${prepared.target}\n主机指纹：${prepared.hostKey}\n有效期：${prepared.seconds} 秒',
                    ),
                    const SizedBox(height: 12),
                    for (final key in prepared.keys)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SelectableText(
                          '${key.name}\n${key.fingerprint}',
                        ),
                      ),
                    const Text(
                      '远端可在有效期内请求这些密钥签名，可能用于访问其他服务器。原始私钥不会发送到远端。关闭此对话框不等于撤销授权；可随时撤销，断线、重连或切换加密库后不继承授权。',
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('我信任上述目标，并允许本次限时签名'),
                      value: acceptedRisk,
                      onChanged: (v) => update(() => acceptedRisk = v ?? false),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const ValueKey('agent-confirm'),
                  onPressed: acceptedRisk && valid
                      ? () => Navigator.pop(context, true)
                      : null,
                  child: const Text('确认授权'),
                ),
              ],
            ),
          ),
        ),
      );
      if (mounted) setState(() => _confirming = false);
      if (approved != true || !mounted || !source.current()) return;
      final state = await gateway.approve(source, preview.ticket);
      consumed = true;
      if (mounted && source.current()) setState(() => _state = state);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      // Cancelling a metadata-only preview cannot authorize keys. Root teardown
      // already invalidates it when the original terminal no longer exists.
      if (preview != null && !consumed && source.current()) {
        try {
          await gateway.cancel(source, preview.ticket);
        } catch (error) {
          if (mounted) setState(() => _error = '取消授权预览失败：$error');
        }
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _confirming = false;
        });
        if (_again) {
          _again = false;
          unawaited(_refresh());
        }
      }
    }
  }

  Future<void> _revoke() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = await gateway.revoke(source);
      if (mounted) setState(() => _state = state);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_again) {
          _again = false;
          unawaited(_refresh());
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = source.current() ? _state?.phase : 'Closed';
    final available =
        source.current() &&
        !_busy &&
        !_fetching &&
        const ['Ready', 'Active', 'Expired', 'Revoked'].contains(phase);
    const labels = {
      'NotRequested': '本连接未申请 Agent socket',
      'Denied': '服务器拒绝 Agent 转发',
      'Ready': '已准备，尚未授权',
      'Active': '限时授权中',
      'Expired': '授权已到期',
      'Revoked': '授权已撤销',
      'Closed': '原连接已关闭',
      'Failed': 'Agent 失败，权限已撤销',
    };
    final expires = _state?.expiresUnixMillis;
    return AlertDialog(
      scrollable: true,
      title: Text('应用内 Agent · ${source.label}'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              labels[phase] ?? '正在读取状态…',
              key: const ValueKey('agent-state'),
            ),
            if (expires != null)
              Text(
                '到期：${DateTime.fromMillisecondsSinceEpoch(expires.toInt()).toLocal()} · ${_state!.keyCount} 个密钥',
              ),
            if (const ['NotRequested', 'Denied'].contains(phase))
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '请在主机的认证设置启用 Agent socket，然后明确重新连接。启用 socket 不会自动授权任何密钥。',
                ),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey('agent-duration'),
              initialValue: _minutes,
              decoration: const InputDecoration(labelText: '本次授权时长'),
              items: [
                for (final n in [1, 5, 10, 30, 60])
                  DropdownMenuItem(value: n, child: Text('$n 分钟')),
              ],
              onChanged: available
                  ? (n) => setState(() => _minutes = n!)
                  : null,
            ),
            const SizedBox(height: 12),
            const Text('显式选择已保存在应用加密库中的私钥；仅预览所选项的公钥指纹。'),
            if (_keys.isEmpty && !_fetching)
              const Text('没有可用私钥。请先在主机管理中导入或生成并正式保存。'),
            if (_keys.isNotEmpty)
              SizedBox(
                height: 180,
                child: ListView(
                  children: [
                    for (final key in _keys)
                      CheckboxListTile(
                        key: ValueKey('agent-key-${key.hostId}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(key.name),
                        value: _selected.contains(key.hostId),
                        onChanged: available
                            ? (value) => setState(() {
                                if (value == true) {
                                  _selected.add(key.hostId);
                                } else {
                                  _selected.remove(key.hostId);
                                }
                              })
                            : null,
                      ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _error!,
                  key: const ValueKey('agent-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if ((_busy && !_confirming) || _fetching)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy || _fetching
              ? null
              : () {
                  setState(() => _error = null);
                  unawaited(_refresh());
                },
          child: const Text('刷新'),
        ),
        TextButton(
          key: const ValueKey('agent-revoke'),
          onPressed: phase == 'Active' && !_busy ? _revoke : null,
          child: const Text('撤销授权'),
        ),
        FilledButton(
          key: const ValueKey('agent-prepare'),
          onPressed: available && _selected.isNotEmpty ? _authorise : null,
          child: const Text('预览授权'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
