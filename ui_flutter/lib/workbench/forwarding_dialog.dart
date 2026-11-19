import '../prototype/design.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../src/rust/api.dart' as rust;
import '../prototype/model.dart';
import 'model.dart';
import '../src/rust/forwardings.dart';
import '../src/rust/forwardings/runtime.dart';

Future<void> showSavedForwardings(
  BuildContext context,
  LiveWorkbenchModel model,
  DemoHost host, {
  LiveTerminalSession? terminal,
}) async {
  final candidates = terminal == null
      ? model.sessions.cast<LiveTerminalSession>().where(
          (s) => s.host.id == host.id,
        )
      : [terminal];
  final sources = <ForwardingSession>[];
  for (final source in candidates) {
    if (!source.controller.connected || source.controller.id == null) continue;
    final tab = model.tabs.where((t) => t.sessionId == source.id).firstOrNull;
    final native = source.controller.id!,
        generation = source.controller.generation;
    sources.add(
      ForwardingSession(
        source.controller.id!,
        source.controller.generation,
        '${tab?.name ?? source.host.name} · ${sources.length + 1}',
        changes: Listenable.merge([source.controller, model]),
        updates: source.controller.forwardingChanges,
        isCurrent: () =>
            source.controller.connected &&
            source.controller.id == native &&
            source.controller.generation == generation &&
            model.tabs.any((t) => t.sessionId == source.id),
      ),
    );
  }
  await showAppDialog<void>(
    context: context,
    builder: (_) => ForwardingDialog(
      hostId: host.id,
      hostName: host.name,
      sessions: List.unmodifiable(sources),
    ),
  );
}

/// An explicit original terminal binding; selecting another tab later cannot
/// redirect an operation already started from this dialog.
class ForwardingSession {
  const ForwardingSession(
    this.id,
    this.generation,
    this.label, {
    this.changes,
    this.isCurrent,
    this.updates,
  });
  final int id, generation;
  final String label;
  final Listenable? changes;
  final Listenable? updates;
  final bool Function()? isCurrent;
  bool get current => isCurrent?.call() ?? true;
}

abstract interface class ForwardingGateway {
  Future<List<RuleConfig>> load(String host);
  Future<List<RuleConfig>> save(String host, List<RuleConfig> rules);
  Future<List<RunStatus>> list(ForwardingSession session);
  Future<RunStatus> start(ForwardingSession session, String rule);
  Future<void> stop(ForwardingSession session, String token);
  Future<RuleDraft> draft(String host);
  Future<RuleDraft> saveDraft(String host, int revision, DraftFields? fields);
  Future<List<RuleConfig>> commitDraft(String host, int revision);
}

class NativeForwardingGateway implements ForwardingGateway {
  const NativeForwardingGateway();
  @override
  Future<RuleDraft> draft(String host) =>
      rust.forwardingRuleDraft(hostId: host);
  @override
  Future<RuleDraft> saveDraft(String host, int revision, DraftFields? fields) =>
      rust.saveForwardingRuleDraft(
        hostId: host,
        expectedRevision: revision,
        fields: fields,
      );
  @override
  Future<List<RuleConfig>> commitDraft(String host, int revision) =>
      rust.commitForwardingRuleDraft(hostId: host, expectedRevision: revision);
  @override
  Future<List<RuleConfig>> load(String host) =>
      rust.forwardingRules(hostId: host);
  @override
  Future<List<RuleConfig>> save(String host, List<RuleConfig> rules) =>
      rust.saveForwardingRules(hostId: host, rules: rules);
  @override
  Future<List<RunStatus>> list(ForwardingSession session) =>
      rust.terminalForwardings(id: session.id);
  @override
  Future<RunStatus> start(ForwardingSession session, String rule) =>
      rust.startForwarding(
        id: session.id,
        generation: session.generation,
        ruleId: rule,
      );
  @override
  Future<void> stop(ForwardingSession session, String token) =>
      rust.stopForwarding(
        id: session.id,
        generation: session.generation,
        token: token,
      );
}

class ForwardingDialog extends StatefulWidget {
  const ForwardingDialog({
    super.key,
    required this.hostId,
    required this.hostName,
    required this.sessions,
    this.gateway = const NativeForwardingGateway(),
  });
  final String hostId, hostName;
  final List<ForwardingSession> sessions;
  final ForwardingGateway gateway;
  @override
  State<ForwardingDialog> createState() => _ForwardingDialogState();
}

class _ForwardingDialogState extends State<ForwardingDialog> {
  List<RuleConfig> _rules = [];
  List<RunStatus> _runs = [];
  ForwardingSession? _session;
  String? _error;
  bool _loading = true, _busy = false, _loaded = false;
  bool _editorOpen = false;
  Future<void>? _refreshing;
  bool _refreshDirty = false;
  bool _sourceCurrent = true;
  void _sourceChanged() {
    if (!mounted) return;
    final current = _session?.current ?? false;
    if (current == _sourceCurrent) return;
    _sourceCurrent = current;

    setState(() {});
    if (!current) unawaited(_refresh());
  }

  void _observeSource() {
    _sourceCurrent = _session?.current ?? false;
    _session?.changes?.addListener(_sourceChanged);
    _session?.updates?.addListener(_runtimeChanged);
  }

  void _runtimeChanged() {
    if (mounted && _session?.current == true) unawaited(_refresh());
  }

  void _selectSource(ForwardingSession? source) {
    _session?.changes?.removeListener(_sourceChanged);
    _session?.updates?.removeListener(_runtimeChanged);
    setState(() {
      _session = source;
      _runs = [];
      _observeSource();
    });
    unawaited(_refresh());
  }

  @override
  void initState() {
    super.initState();
    if (widget.sessions.length == 1) _session = widget.sessions.single;
    _observeSource();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loaded = false;
      });
    }
    try {
      final rules = await widget.gateway.load(widget.hostId);
      if (mounted) {
        setState(() {
          _rules = rules;
          _loaded = true;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    await _refresh();
  }

  Future<void> _refresh() {
    if (!mounted || _session == null) return Future.value();
    _refreshDirty = true;
    final pending = _refreshing;
    if (pending != null) return pending;
    late Future<void> work;
    work = _refreshLoop().whenComplete(() {
      if (identical(_refreshing, work)) {
        _refreshing = null;
        // A notification may arrive between loop completion and this microtask.
        if (mounted && _refreshDirty) unawaited(_refresh());
      }
    });
    _refreshing = work;
    return work;
  }

  Future<void> _refreshLoop() async {
    do {
      _refreshDirty = false;
      final session = _session;
      if (!mounted || session == null) return;
      try {
        final runs = (await widget.gateway.list(session))
            .where((r) => r.generation == session.generation)
            .toList();
        if (mounted && identical(_session, session)) {
          setState(() => _runs = runs);
        }
      } catch (error) {
        if (mounted && identical(_session, session)) {
          setState(() => _error = error.toString());
        }
      }
    } while (mounted && _refreshDirty);
  }

  Future<void> _operation(Future<void> Function() operation) async {
    if (_busy || _loading) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([RuleConfig? original]) async {
    if (_busy || _editorOpen) return;
    _editorOpen = true;
    setState(() => _busy = true);
    try {
      var draft = await widget.gateway.draft(widget.hostId);
      if (!mounted) return;
      // Modal editing is not a running IO operation. Keeping the underlying
      // indeterminate progress bar alive would redraw continuously.
      setState(() => _busy = false);
      if (draft.fields != null) {
        final choice = await showAppDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: const Text('发现未保存的转发草稿'),
            content: Text('“${draft.fields!.name}”仅保存在本机加密库，尚未改变正式规则。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'discard'),
                child: const Text('丢弃草稿'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, 'recover'),
                child: const Text('恢复草稿'),
              ),
            ],
          ),
        );
        if (choice == null || !mounted) return;
        if (choice == 'discard') {
          draft = await widget.gateway.saveDraft(
            widget.hostId,
            draft.revision,
            null,
          );
        }
      }
      if (!mounted) return;
      final value = await showAppDialog<_EditorCommit>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _RuleEditor(
          original: original,
          host: widget.hostId,
          gateway: widget.gateway,
          draft: draft,
        ),
      );
      if (value != null && mounted) {
        final before = _rules;
        setState(() => _rules = value.rules);
        unawaited(_offerStartAfterSave(value, before));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      _editorOpen = false;
    }
  }

  /// Saving only persists configuration and never starts a listener. When the
  /// host still has a connected terminal, offer one explicit start through
  /// the normal start chain on the selected (or only) terminal; without a
  /// connectable terminal nothing is asked and the status quo stays.
  Future<void> _offerStartAfterSave(
    _EditorCommit commit,
    List<RuleConfig> before,
  ) async {
    final editedId = commit.editedId;
    final rule = commit.rules
        .where(
          (r) => editedId != null
              ? r.id == editedId
              : !before.any((b) => b.id == r.id),
        )
        .firstOrNull;
    if (rule == null || !rule.enabled) return;
    final target = (_session?.current ?? false)
        ? _session
        : widget.sessions.where((s) => s.current).firstOrNull;
    if (target == null) return;
    if (_runs.any(
      (run) =>
          run.ruleId == rule.id &&
          !['stopped', 'failed', 'disconnected'].contains(run.phase),
    )) {
      return;
    }
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('规则已保存，未自动启动'),
        content: Text(
          '规则已保存，未自动启动。是否立即应用到所选终端？\n\n'
          '“${rule.name}” → ${target.label}',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('立即启动'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!identical(_session, target)) _selectSource(target);
    await _start(rule);
  }

  Future<void> _remove(RuleConfig rule) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('删除转发规则？'),
        content: Text('删除“${rule.name}”只修改保存配置，不会停止当前正在运行的实例。'),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除规则'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _operation(() async {
      final saved = await widget.gateway.save(widget.hostId, [
        for (final r in _rules)
          if (r.id != rule.id) r,
      ]);
      if (mounted) setState(() => _rules = saved);
    });
  }

  Future<void> _start(RuleConfig rule) async {
    final session = _session;
    if (session == null || !session.current) return;
    final bind = InternetAddress.tryParse(rule.bindAddress);
    if (bind != null && !bind.isLoopback) {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('启动非回环监听？'),
          content: Text(
            '请求监听 ${rule.bindAddress}。其他设备可能访问此转发；动态 SOCKS5 不提供认证。远端实际绑定范围由 SSH 服务器策略决定。',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('启动'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _operation(() async {
      await widget.gateway.start(session, rule.id);
      await _refresh();
    });
  }

  Future<void> _stop(RunStatus run) => _operation(() async {
    final session = _session;
    if (session == null || session.generation != run.generation) {
      throw StateError('原连接已变化，请重新打开转发管理');
    }
    try {
      await widget.gateway.stop(session, run.token);
    } finally {
      await _refresh();
    }
  });
  @override
  void dispose() {
    _session?.changes?.removeListener(_sourceChanged);
    _session?.updates?.removeListener(_runtimeChanged);
    super.dispose();
  }

  String _kind(String kind) => switch (kind) {
    'local' => '本地 L',
    'remote' => '远端 R',
    _ => '动态 D',
  };
  String _phase(String phase) => switch (phase) {
    'starting' => '等待远端确认',
    'listening' => '监听中',
    'stopping' => '停止中',
    'cleanupPending' => '取消未确认',
    'cleanupDenied' => '远端拒绝取消',
    'stopped' => '已停止',
    'failed' => '启动失败',
    'disconnected' => '原连接已断开',
    _ => phase,
  };
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: 760,
        height: math.max(
          160,
          math.min(560, MediaQuery.sizeOf(context).height - 80),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '端口转发 · ${widget.hostName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新状态',
                    onPressed: _busy || _loading
                        ? null
                        : () => _operation(_load),
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Expanded(
                child: ListView(
                  children: [
                    const Text(
                      '保存不联网或改变现有实例。运行操作只作用于明确选择的终端；首次连接请手动启动；明确重连成功后按规则恢复，失败单独显示。',
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 260,
                          child: DropdownButtonFormField<ForwardingSession>(
                            key: const ValueKey('forward-session'),
                            initialValue: _session,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '运行操作的关联终端',
                            ),
                            hint: Text(
                              widget.sessions.isEmpty ? '没有已连接的关联终端' : '请选择终端',
                            ),
                            items: [
                              for (final s in widget.sessions)
                                DropdownMenuItem(
                                  value: s,
                                  child: Text(
                                    s.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: _busy ? null : _selectSource,
                          ),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey('forward-add'),
                          onPressed: _busy || _loading || !_loaded
                              ? null
                              : () => _edit(),
                          icon: const Icon(Icons.add),
                          label: const Text('添加规则'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _error!,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (_busy) const LinearProgressIndicator(),
                    SizedBox(
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : ListView(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              children: [
                                if (_rules.isEmpty)
                                  Padding(
                                    padding: EdgeInsets.all(20),
                                    child: Text(
                                      _loaded
                                          ? '尚未保存转发规则。添加本地、远端或动态转发。'
                                          : '配置无法读取，不能添加或修改；已有运行实例仍可停止。',
                                    ),
                                  ),
                                for (final rule in _rules)
                                  Card(
                                    margin: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(10),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  '${_kind(rule.kind)} · ${rule.name}',
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: '编辑规则',
                                                onPressed: _busy || !_loaded
                                                    ? null
                                                    : () => _edit(rule),
                                                icon: const Icon(
                                                  Icons.edit_outlined,
                                                ),
                                              ),
                                              IconButton(
                                                tooltip: '删除规则',
                                                onPressed: _busy || !_loaded
                                                    ? null
                                                    : () => _remove(rule),
                                                icon: const Icon(
                                                  Icons.delete_outline,
                                                ),
                                              ),
                                            ],
                                          ),
                                          SelectableText(
                                            '${rule.kind == 'remote' ? '请求远端' : '本机'} ${rule.bindAddress}:${rule.bindPort == 0 ? '自动分配' : rule.bindPort} → ${rule.kind == 'dynamic' ? 'SOCKS5 CONNECT' : '${rule.targetAddress}:${rule.targetPort}'}',
                                          ),
                                          const SizedBox(height: 6),
                                          Wrap(
                                            spacing: 8,
                                            crossAxisAlignment:
                                                WrapCrossAlignment.center,
                                            children: [
                                              Text(
                                                rule.enabled ? '已启用' : '已停用',
                                              ),
                                              OutlinedButton(
                                                key: ValueKey(
                                                  'forward-start-${rule.id}',
                                                ),
                                                onPressed:
                                                    _busy ||
                                                        !_loaded ||
                                                        _session == null ||
                                                        !_session!.current ||
                                                        !rule.enabled ||
                                                        _runs.any(
                                                          (r) =>
                                                              r.ruleId ==
                                                                  rule.id &&
                                                              ![
                                                                'stopped',
                                                                'failed',
                                                                'disconnected',
                                                              ].contains(
                                                                r.phase,
                                                              ),
                                                        )
                                                    ? null
                                                    : () => _start(rule),
                                                child: const Text('启动'),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                if (_runs.isNotEmpty)
                                  const Padding(
                                    padding: EdgeInsets.only(
                                      top: 12,
                                      bottom: 6,
                                    ),
                                    child: Text('所选终端的运行实例（配置删除后仍可停止）'),
                                  ),
                                for (final run in _runs)
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      '${run.name} · ${_phase(_session?.current == false ? 'disconnected' : run.phase)}',
                                    ),
                                    subtitle: Text(
                                      '${run.bindAddress ?? '等待分配'}${run.bindPort == null ? '' : ':${run.bindPort}'}${run.lastError == null ? '' : '\n${run.lastError}'}',
                                    ),
                                    trailing: TextButton(
                                      key: ValueKey(
                                        'forward-stop-${run.token}',
                                      ),
                                      onPressed:
                                          _busy ||
                                              _session?.current == false ||
                                              [
                                                'stopped',
                                                'failed',
                                                'disconnected',
                                              ].contains(run.phase)
                                          ? null
                                          : () => _stop(run),
                                      child: Text(
                                        run.phase == 'cleanupDenied'
                                            ? '重试停止'
                                            : '停止',
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _EditorCommit {
  const _EditorCommit(this.rules, this.editedId);
  final List<RuleConfig> rules;

  /// The rule this editor session created or changed, so the caller can offer
  /// one explicit start. Null identification means "the newly added rule".
  final String? editedId;
}

class _RuleEditor extends StatefulWidget {
  const _RuleEditor({
    this.original,
    required this.host,
    required this.gateway,
    required this.draft,
  });
  final RuleConfig? original;
  final String host;
  final ForwardingGateway gateway;
  final RuleDraft draft;
  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  final form = GlobalKey<FormState>();
  late final TextEditingController name, bind, port, target, targetPort;
  late String kind;
  late bool enabled, restore;
  late int revision;
  RuleConfig? original;
  Timer? _timer;
  Future<void> _tail = Future.value();
  late final AppLifecycleListener _exit;
  bool _dirty = false, _busy = false, _allowClose = false, _hasDraft = false;
  String? _error, _draftError;
  late List<String> _lastTexts;
  @override
  void initState() {
    super.initState();
    final d = widget.draft.fields;
    revision = widget.draft.revision;
    original = d == null ? widget.original : d.original;
    final r = original;
    _hasDraft = d != null;
    name = TextEditingController(text: d?.name ?? r?.name ?? '');
    bind = TextEditingController(
      text: d?.bindAddress ?? r?.bindAddress ?? '127.0.0.1',
    );
    port = TextEditingController(text: d?.bindPort ?? '${r?.bindPort ?? 0}');
    target = TextEditingController(
      text: d?.targetAddress ?? r?.targetAddress ?? '127.0.0.1',
    );
    targetPort = TextEditingController(
      text: d?.targetPort ?? r?.targetPort?.toString() ?? '',
    );
    kind = d?.kind ?? r?.kind ?? 'local';
    enabled = d?.enabled ?? r?.enabled ?? true;
    restore = d?.restoreOnReconnect ?? r?.restoreOnReconnect ?? false;
    _lastTexts = [
      name.text,
      bind.text,
      port.text,
      target.text,
      targetPort.text,
    ];
    for (final controller in [name, bind, port, target, targetPort]) {
      controller.addListener(_textChanged);
    }
    _exit = AppLifecycleListener(
      onExitRequested: () async {
        if (_busy) return AppExitResponse.cancel;
        return await _flush() ? AppExitResponse.exit : AppExitResponse.cancel;
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _exit.dispose();
    for (final c in [name, bind, port, target, targetPort]) {
      c.dispose();
    }
    super.dispose();
  }

  DraftFields _fields() => DraftFields(
    original: original,
    name: name.text,
    kind: kind,
    bindAddress: bind.text,
    bindPort: port.text,
    targetAddress: target.text,
    targetPort: targetPort.text,
    enabled: enabled,
    restoreOnReconnect: restore,
  );
  void _textChanged() {
    final texts = [
      name.text,
      bind.text,
      port.text,
      target.text,
      targetPort.text,
    ];
    if (List.generate(
      texts.length,
      (i) => texts[i] == _lastTexts[i],
    ).every((same) => same)) {
      return;
    }
    _lastTexts = texts;
    _changed();
  }

  void _changed() {
    if (_busy || _allowClose) return;
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), _queueDraft);
  }

  void _queueDraft() {
    _timer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    _hasDraft = true;
    final fields = _fields();
    _tail = _tail.then((_) async {
      try {
        final saved = await widget.gateway.saveDraft(
          widget.host,
          revision,
          fields,
        );
        revision = saved.revision;
        _hasDraft = true;
        _draftError = null;
        if (mounted) setState(() => _error = null);
      } catch (error) {
        _dirty = true;
        _draftError = '草稿未保存：$error';
        if (mounted) setState(() => _error = _draftError);
      }
    });
  }

  Future<bool> _flush({bool force = false}) async {
    _timer?.cancel();
    if (force) _dirty = true;
    _queueDraft();
    await _tail;
    return !_dirty && _draftError == null;
  }

  Future<void> _close([_EditorCommit? result]) async {
    _timer?.cancel();
    setState(() => _allowClose = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context, result);
  }

  Future<void> _leave() async {
    if (_busy || _allowClose) return;
    if (!_dirty && !_hasDraft) {
      await _close();
      return;
    }
    final choice = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('转发规则尚未正式保存'),
        content: const Text('草稿仅保存在本机加密库，不会启动监听或参与同步。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('丢弃草稿'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'keep'),
            child: const Text('保留草稿并关闭'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    try {
      if (choice == 'keep') {
        if (!await _flush()) return;
      } else {
        _timer?.cancel();
        await _tail;
        final discarded = await widget.gateway.saveDraft(
          widget.host,
          revision,
          null,
        );
        revision = discarded.revision;
      }
      if (mounted) await _close();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted && !_allowClose) setState(() => _busy = false);
    }
  }

  String? portError(String? text, bool zero) {
    final value = int.tryParse(text ?? '');
    return value == null || value < (zero ? 0 : 1) || value > 65535
        ? '端口范围 ${zero ? 0 : 1}–65535'
        : null;
  }

  String? targetError(String? value) {
    if (value == null || value.isEmpty) return '请输入目标地址';
    if (InternetAddress.tryParse(value) != null && !value.contains('%')) {
      return null;
    }
    if (value.startsWith('[') &&
        value.endsWith(']') &&
        InternetAddress.tryParse(value.substring(1, value.length - 1))?.type ==
            InternetAddressType.IPv6) {
      return null;
    }
    return RegExp(r'^[a-zA-Z0-9._-]{1,253}$').hasMatch(value) &&
            RegExp(r'[a-zA-Z0-9]').hasMatch(value)
        ? null
        : '请输入IP或ASCII主机名，不含空格、URL或控制字符';
  }

  Future<void> save() async {
    if (_busy) return;
    if (!form.currentState!.validate()) return;
    if (restore && !InternetAddress(bind.text).isLoopback) {
      final accepted = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('允许重连后恢复非回环监听？'),
          content: const Text(
            '每次明确手动重连成功后，此规则会尝试启动，可能允许其他设备访问。远端 R 的实际暴露范围还取决于服务器 GatewayPorts 策略；动态 D 没有 SOCKS 认证。',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('允许并保存'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await _flush(force: true) || !mounted) return;
      final saved = await widget.gateway.commitDraft(widget.host, revision);
      if (mounted) {
        await _close(_EditorCommit(saved, original?.id));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted && !_allowClose) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowClose,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_leave());
    },
    child: AlertDialog(
      scrollable: true,
      title: Text(original == null ? '添加转发规则' : '编辑转发规则'),
      content: SizedBox(
        width: 440,
        child: AbsorbPointer(
          absorbing: _busy,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_busy) const LinearProgressIndicator(),
                TextFormField(
                  key: const ValueKey('forward-name'),
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '规则名称'),
                  validator: (v) =>
                      v == null ||
                          v.trim().isEmpty ||
                          utf8.encode(v).length > 1024 ||
                          RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(v)
                      ? '名称不能为空、含控制字符或超过1024字节'
                      : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const ValueKey('forward-kind'),
                  isExpanded: true,
                  initialValue: kind,
                  decoration: const InputDecoration(labelText: '转发类型'),
                  items: const [
                    DropdownMenuItem(
                      value: 'local',
                      child: Text(
                        '本地 L · 本机 → 服务器目标',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'remote',
                      child: Text(
                        '远端 R · 服务器 → 本机目标',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'dynamic',
                      child: Text(
                        '动态 D · 本机 SOCKS5',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() => kind = v!);
                    _changed();
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('forward-bind'),
                  controller: bind,
                  decoration: InputDecoration(
                    labelText: kind == 'remote' ? '请求远端监听 IP' : '本机监听 IP',
                  ),
                  validator: (v) =>
                      InternetAddress.tryParse(v ?? '') == null ||
                          (v?.contains('%') ?? false) ||
                          (v?.startsWith('[') ?? false)
                      ? '请输入明确的 IPv4 或 IPv6 地址'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('forward-port'),
                  controller: port,
                  decoration: const InputDecoration(labelText: '监听端口（0 自动分配）'),
                  keyboardType: TextInputType.number,
                  validator: (v) => portError(v, true),
                ),
                if (kind != 'dynamic') ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('forward-target'),
                    controller: target,
                    decoration: InputDecoration(
                      labelText: kind == 'remote' ? '本机目标地址' : '由服务器访问的目标地址',
                    ),
                    validator: targetError,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('forward-target-port'),
                    controller: targetPort,
                    decoration: const InputDecoration(labelText: '目标端口'),
                    keyboardType: TextInputType.number,
                    validator: (v) => portError(v, false),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用此规则'),
                  value: enabled,
                  onChanged: (v) {
                    setState(() => enabled = v);
                    _changed();
                  },
                ),
                SwitchListTile(
                  key: const ValueKey('forward-restore'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('手动重连成功后恢复'),
                  subtitle: const Text('仅启用的规则；不会自动建立 SSH。切换标签或分屏不触发恢复。'),
                  value: restore,
                  onChanged: (v) {
                    setState(() => restore = v);
                    _changed();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : _leave, child: const Text('取消')),
        FilledButton(
          key: const ValueKey('forward-save'),
          onPressed: _busy ? null : save,
          child: const Text('保存规则'),
        ),
      ],
    ),
  );
}
