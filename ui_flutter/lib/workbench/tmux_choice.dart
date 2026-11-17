import '../prototype/design.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../src/rust/tmux.dart' as tmx;
import '../terminal/controller.dart';

bool validTmuxName(String value) =>
    value.isNotEmpty &&
    value.trim() == value &&
    utf8.encode(value).length <= 64 &&
    RegExp(r'^[\p{L}\p{N}_ -]+$', unicode: true).hasMatch(value);

String nextTmuxSessionName(Iterable<String> existing) {
  final names = existing.toSet();
  var number = 1;
  while (names.contains('hspterm$number')) {
    number++;
  }
  return 'hspterm$number';
}

/// Only the captured source can answer. Pending navigation is removed on a
/// source lifecycle change; a later tab/focus cannot become the destination.
Future<tmx.TmuxSelection?> showTmuxChoice(
  BuildContext context,
  TerminalController c,
  tmx.TmuxPrompt prompt,
) async {
  final id = c.id;
  bool current() =>
      c.id == id &&
      c.generation == prompt.generation &&
      c.phase == 'Connecting';
  if (id == null || !current() || !context.mounted) return null;
  final navigator = Navigator.of(context);
  late final DialogRoute<tmx.TmuxSelection> route;
  void changed() {
    if (!current()) {
      scheduleMicrotask(() {
        if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      });
    }
  }

  final prepared = await createAppDialogRoute<tmx.TmuxSelection>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _TmuxChoice(controller: c, prompt: prompt, label: c.connectionLabel),
  );
  if (prepared == null || !context.mounted || !current()) return null;
  route = prepared;
  c.addListener(changed);
  c.closingChanges.addListener(changed);
  try {
    final result = await navigator.push(route);
    return current() ? result : null;
  } finally {
    c.removeListener(changed);
    c.closingChanges.removeListener(changed);
  }
}

class _TmuxChoice extends StatefulWidget {
  const _TmuxChoice({
    required this.controller,
    required this.prompt,
    required this.label,
  });
  final TerminalController controller;
  final tmx.TmuxPrompt prompt;
  final String label;
  @override
  State<_TmuxChoice> createState() => _TmuxChoiceState();
}

class _TmuxChoiceState extends State<_TmuxChoice> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(
    text: nextTmuxSessionName(widget.prompt.sessions.map((s) => s.name)),
  );
  late int kind = widget.prompt.sessions.isNotEmpty
      ? 3
      : widget.prompt.version != null
      ? 2
      : 1;
  late String? session = widget.prompt.sessions.firstOrNull?.id;
  late bool readonly = widget.prompt.readonlyDefault ?? true;
  // Per-host remembered consent (device-local); unchecked on first use.
  late bool ensureLocale = widget.prompt.ensureLocale ?? false;
  bool lockSize = false, restore = false;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    return AlertDialog(
      scrollable: true,
      title: const Text('选择此终端的 tmux 会话'),
      content: SizedBox(
        width: 540,
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                '${widget.label}\n${p.version ?? '无法确定tmux版本'} · 初始PTY ${p.columns} × ${p.rows}',
              ),
              if (p.issue != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    p.issue!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                key: const ValueKey('tmux-kind'),
                initialValue: kind,
                decoration: const InputDecoration(labelText: '本次操作'),
                items: [
                  if (p.sessions.isNotEmpty)
                    const DropdownMenuItem(value: 3, child: Text('附着原列表中的会话')),
                  if (p.version != null)
                    const DropdownMenuItem(value: 2, child: Text('新建独立会话')),
                  const DropdownMenuItem(
                    value: 1,
                    child: Text('明确改用普通 SSH Shell'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      kind = value;
                      restore = false;
                    });
                  }
                },
              ),
              if (kind == 3) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const ValueKey('tmux-session'),
                  initialValue: session,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '远端会话'),
                  items: [
                    for (final s in p.sessions)
                      DropdownMenuItem(
                        value: s.id,
                        child: Text(
                          '${s.name}  ${s.id} · ${s.attached}个客户端',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    session = value;
                    restore = false;
                  }),
                ),
                SwitchListTile.adaptive(
                  key: const ValueKey('tmux-readonly'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('只读观看'),
                  subtitle: Text(
                    readonly
                        ? '观看端不参与远端尺寸计算；远端tmux限制输入。'
                        : '直接接管所选会话，并分离其他客户端。',
                  ),
                  value: readonly,
                  onChanged: (value) => setState(() {
                    readonly = value;
                    restore = false;
                  }),
                ),
              ],
              if (kind == 2)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextFormField(
                    key: const ValueKey('tmux-name'),
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: '新会话名称',
                      helperText: '字母、数字、中文、空格、下划线或短横线，UTF-8最多64字节；同名不会自动附着。',
                    ),
                    validator: (value) =>
                        validTmuxName(value ?? '') ? null : '请填写有效名称（不含首尾空格）',
                  ),
                ),
              if (p.restoreAvailable == true && kind != 1)
                CheckboxListTile(
                  key: const ValueKey('tmux-restore-on-reconnect'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('本终端手动重连时恢复此 tmux 会话'),
                  subtitle: Text(
                    kind == 3 && readonly
                        ? '仅保留到终端关闭；每次重新验证 SSH 指纹及会话身份，沿用只读和尺寸锁。仍需手动点击重新连接。'
                        : '仅保留到终端关闭；手动重连将接管原会话，分离其他客户端。',
                  ),
                  value: restore,
                  onChanged: (value) => setState(() => restore = value == true),
                ),
              if (kind == 2 && restore)
                const Text('会先明确创建并确认远端会话身份；若之后附着失败或取消，已创建的会话保留，不自动删除或同名重建。'),
              if (kind != 1)
                CheckboxListTile(
                  key: const ValueKey('tmux-lock-size'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('锁定此PTY初始尺寸 ${p.columns} × ${p.rows}'),
                  subtitle: const Text('锁定后窗口布局变化不发送PTY resize；可在终端解除锁定。'),
                  value: lockSize,
                  onChanged: (value) =>
                      setState(() => lockSize = value == true),
                ),
              if (kind != 1)
                CheckboxListTile(
                  key: const ValueKey('tmux-ensure-locale'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('自动补齐远端 locale（默认关闭）'),
                  subtitle: const Text(
                    '将修改远端 ~/.bashrc：缺哪条补哪条地追加备注行'
                    '“# added by hspterm (LANG/LC_ALL)”及 export LANG/LC_ALL=en_US.UTF-8；'
                    '附着时在 tmux 全局环境同步设置。不向已运行的Shell注入内容。勾选后按主机记住。',
                  ),
                  value: ensureLocale,
                  onChanged: (value) =>
                      setState(() => ensureLocale = value == true),
                ),
              const SizedBox(height: 8),
              const Text('取消不会启动普通Shell或新建其他连接。断线后始终需要手动重连；未启用恢复或身份发生变化时重新选择。'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          child: const Text('取消连接'),
        ),
        FilledButton(
          key: const ValueKey('tmux-confirm'),
          onPressed: (kind == 3 && session == null)
              ? null
              : () {
                  if (!form.currentState!.validate()) return;
                  Navigator.pop(
                    context,
                    tmx.TmuxSelection(
                      restoreOnReconnect: kind != 1 && restore,
                      kind: kind,
                      name: kind == 2 ? name.text : null,
                      sessionId: kind == 3 ? session : null,
                      readonly: kind == 3 && readonly,
                      takeoverConfirmed: kind == 3 && !readonly,
                      lockSize: kind != 1 && lockSize,
                      ensureLocale: kind != 1 && ensureLocale,
                    ),
                  );
                },
          child: const Text('确认并继续'),
        ),
      ],
    );
  }
}
