import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/host_ordering.dart';
import 'model.dart';

abstract interface class HostOrderingGateway {
  Future<OrderingView> load();
  Future<OrderingView> save(HostOrderDraft draft);
}

class NativeHostOrderingGateway implements HostOrderingGateway {
  NativeHostOrderingGateway(this.model);
  final LiveWorkbenchModel model;
  @override
  Future<OrderingView> load() async {
    final view = await rust.loadHostOrdering();
    await model.load();
    return view;
  }

  @override
  Future<OrderingView> save(HostOrderDraft draft) => model.saveHostOrdering(
    draft.source,
    draft.groupIds,
    draft.hostIds,
    draft.placements.values.toList(),
  );
}

/// Local edit proposal only. Opaque original Vault/revision stays immutable;
/// credentials, endpoints and live SSH sessions are absent from this model.
class HostOrderDraft {
  HostOrderDraft(OrderingView value)
    : source = OrderingView(
        vaultScope: value.vaultScope,
        revision: value.revision,
        groups: List.unmodifiable(value.groups),
        hosts: List.unmodifiable(value.hosts),
      ) {
    groupIds = source.groups.map((g) => g.id).toList();
    hostIds = source.hosts.map((h) => h.id).toList();
    groups = {for (final g in source.groups) g.id: g};
    hosts = {for (final h in source.hosts) h.id: h};
    if (groups.length != groupIds.length ||
        hosts.length != hostIds.length ||
        !groups.containsKey('group-default') ||
        source.hosts.any((h) => !groups.containsKey(h.groupId))) {
      throw StateError('主机排序快照无效，请重新载入');
    }
    placements = {
      for (final h in source.hosts)
        h.id: OrderingPlacement(
          id: h.id,
          groupId: h.groupId,
          favorite: h.favorite,
        ),
    };
  }
  final OrderingView source;
  late final Map<String, OrderingGroup> groups;
  late final Map<String, OrderingHost> hosts;
  late final Map<String, OrderingPlacement> placements;
  late final List<String> groupIds, hostIds;
  HostOrderDraft copy() {
    final next = HostOrderDraft(source);
    next.groupIds
      ..clear()
      ..addAll(groupIds);
    next.hostIds
      ..clear()
      ..addAll(hostIds);
    next.placements
      ..clear()
      ..addAll(placements);
    return next;
  }

  int get moved =>
      source.hosts.where((h) => placements[h.id]!.groupId != h.groupId).length;
  int get starred => source.hosts
      .where((h) => placements[h.id]!.favorite != h.favorite)
      .length;
  bool get groupOrderChanged =>
      !listEquals(groupIds, source.groups.map((g) => g.id).toList());
  bool get hostOrderChanged =>
      !listEquals(hostIds, source.hosts.map((h) => h.id).toList());
  bool get dirty =>
      groupOrderChanged || hostOrderChanged || moved > 0 || starred > 0;
  List<String> visible(String filter, String query) {
    final q = query.toLowerCase();
    return hostIds.where((id) {
      final h = hosts[id]!, p = placements[id]!;
      return (q.isNotEmpty ||
              filter == 'all' ||
              (filter == 'favorites' ? p.favorite : p.groupId == filter)) &&
          '${h.name} ${h.detail}'.toLowerCase().contains(q);
    }).toList();
  }

  void assign(Iterable<String> ids, {String? group, bool? favorite}) {
    if (group != null && !groups.containsKey(group)) throw StateError('分组已失效');
    for (final id in ids) {
      final p = placements[id];
      if (p == null) throw StateError('主机已失效');
      placements[id] = OrderingPlacement(
        id: id,
        groupId: group ?? p.groupId,
        favorite: favorite ?? p.favorite,
      );
    }
  }

  void moveHosts(List<String> ids, String target, bool after) {
    final selected = ids.toSet();
    if (!hosts.containsKey(target) ||
        selected.contains(target) ||
        selected.any((id) => !hosts.containsKey(id))) {
      return;
    }
    final moving = hostIds.where(selected.contains).toList();
    hostIds.removeWhere(selected.contains);
    hostIds.insertAll(hostIds.indexOf(target) + (after ? 1 : 0), moving);
  }

  void moveGroup(String id, String target, bool after) {
    if (id == target ||
        !groups.containsKey(id) ||
        !groups.containsKey(target)) {
      return;
    }
    groupIds.remove(id);
    groupIds.insert(groupIds.indexOf(target) + (after ? 1 : 0), id);
  }
}

class _HostDrag {
  _HostDrag(this.owner, this.ids);
  final HostOrderDraft owner;
  final List<String> ids;
}

class _GroupDrag {
  _GroupDrag(this.owner, this.id);
  final HostOrderDraft owner;
  final String id;
}

class HostOrderingResult {
  const HostOrderingResult({this.refreshRequired = false});
  final bool refreshRequired;
}

Future<HostOrderingResult?> showHostOrdering(
  BuildContext context,
  LiveWorkbenchModel model,
) => showDialog<HostOrderingResult>(
  context: context,
  barrierDismissible: false,
  builder: (_) => HostOrderingDialog(gateway: NativeHostOrderingGateway(model)),
);

class HostOrderingDialog extends StatefulWidget {
  const HostOrderingDialog({super.key, required this.gateway});
  final HostOrderingGateway gateway;
  @override
  State<HostOrderingDialog> createState() => _HostOrderingDialogState();
}

class _HostOrderingDialogState extends State<HostOrderingDialog> {
  final search = TextEditingController();
  HostOrderDraft? draft;
  String filter = 'all';
  final selected = <String>{};
  String? anchor, error, hover;
  bool hoverAfter = false,
      loading = false,
      saving = false,
      committing = false,
      loaded = false,
      saved = false,
      refreshRequired = false;
  int epoch = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    epoch++;
    search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++epoch;
    setState(() {
      loading = true;
      loaded = false;
      error = null;
    });
    try {
      final value = HostOrderDraft(await widget.gateway.load());
      if (!mounted || request != epoch) return;
      setState(() {
        draft = value;
        loaded = true;
        refreshRequired = false;
        filter = 'all';
        selected.clear();
        search.clear();
        anchor = null;
      });
    } catch (failure) {
      if (mounted && request == epoch) {
        setState(() => error = '无法读取排序：$failure');
      }
    } finally {
      if (mounted && request == epoch) setState(() => loading = false);
    }
  }

  Future<bool> _discard() async =>
      !(draft?.dirty ?? false) ||
      await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('放弃未保存的排序修改？'),
              content: const Text('当前分组、收藏及排序还没有保存。'),
              actions: [
                TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('继续编辑'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('放弃修改'),
                ),
              ],
            ),
          ) ==
          true;
  Future<void> _close() async {
    if (saving) return;
    if (await _discard() && mounted) {
      Navigator.pop(
        context,
        saved ? HostOrderingResult(refreshRequired: refreshRequired) : null,
      );
    }
  }

  Future<void> _save() async {
    final d = draft;
    if (d == null || !d.dirty || saving || loading || !loaded) return;
    final proposal = d.copy();
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('保存分组与排序？'),
          content: Text(
            '分组顺序：${d.groupOrderChanged ? '已调整' : '保持'}\n主机顺序：${d.hostOrderChanged ? '已调整' : '保持'}\n修改分组 ${d.moved} 台 · 修改收藏 ${d.starred} 台\n\n现有 SSH 会话继续运行；本次只保存显示顺序、分组与收藏。',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('保存更改'),
            ),
          ],
        ),
      );
      if (!mounted || accepted != true || !identical(d, draft)) return;
      setState(() => committing = true);
      await widget.gateway.save(proposal);
      if (mounted) Navigator.pop(context, const HostOrderingResult());
    } catch (failure) {
      if (mounted) {
        setState(() {
          if (failure is HostOrderingRefreshFailure) {
            draft = HostOrderDraft(failure.saved);
            saved = true;
            refreshRequired = true;
            error = '$failure。可重新载入；不要重复应用旧修改。';
          } else {
            error = '没有保存排序：$failure。当前修改仍保留，可重试或重新载入后核对。';
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          saving = false;
          committing = false;
        });
      }
    }
  }

  void _select(String id, List<String> visible) {
    final keyboard = HardwareKeyboard.instance;
    setState(() {
      if (keyboard.isShiftPressed &&
          anchor != null &&
          visible.contains(anchor)) {
        final a = visible.indexOf(anchor!), b = visible.indexOf(id);
        if (!keyboard.isControlPressed) selected.clear();
        selected.addAll(visible.sublist(math.min(a, b), math.max(a, b) + 1));
      } else if (keyboard.isControlPressed) {
        selected.contains(id) ? selected.remove(id) : selected.add(id);
        anchor = id;
      } else {
        selected
          ..clear()
          ..add(id);
        anchor = id;
      }
    });
  }

  Widget _feedback(String text) => Material(
    elevation: 5,
    borderRadius: BorderRadius.circular(5),
    child: Padding(
      padding: const EdgeInsets.all(9),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    ),
  );
  bool _validHost(Object? data) =>
      data is _HostDrag &&
      identical(data.owner, draft) &&
      data.ids.every(draft!.hosts.containsKey);
  bool _after(BuildContext row, Offset offset) {
    final box = row.findRenderObject() as RenderBox;
    return box.globalToLocal(offset).dy > box.size.height / 2;
  }

  void _hover(String id, bool after) {
    if (hover != id || hoverAfter != after) {
      setState(() {
        hover = id;
        hoverAfter = after;
      });
    }
  }

  Widget _groupRow(String id, String name, {bool actual = true}) {
    final d = draft!;
    return Builder(
      builder: (row) => DragTarget<Object>(
        onWillAcceptWithDetails: (e) =>
            !saving &&
            (_validHost(e.data) && id != 'all' ||
                actual &&
                    e.data is _GroupDrag &&
                    identical((e.data as _GroupDrag).owner, d) &&
                    (e.data as _GroupDrag).id != id),
        onMove: (e) => _hover('g:$id', _after(row, e.offset)),
        onLeave: (_) {
          if (hover == 'g:$id') setState(() => hover = null);
        },
        onAcceptWithDetails: (e) {
          if (saving || loading || !identical(d, draft)) return;
          setState(() {
            if (_validHost(e.data)) {
              final drag = e.data as _HostDrag;
              d.assign(
                drag.ids,
                group: actual ? id : null,
                favorite: id == 'favorites' ? true : null,
              );
            } else if (e.data is _GroupDrag &&
                identical((e.data as _GroupDrag).owner, d)) {
              d.moveGroup((e.data as _GroupDrag).id, id, _after(row, e.offset));
            }
            hover = null;
          });
        },
        builder: (_, candidates, _) => Material(
          key: ValueKey('order-group-$id'),
          color: filter == id
              ? Theme.of(context).colorScheme.primary.withValues(alpha: .12)
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            side: BorderSide(
              color: candidates.isNotEmpty
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
            ),
          ),
          child: ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            minLeadingWidth: 16,
            horizontalTitleGap: 6,
            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
            onTap: saving ? null : () => setState(() => filter = id),
            title: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            leading: Icon(
              id == 'favorites' ? Icons.star_border : Icons.folder_outlined,
              size: 16,
            ),
            trailing: actual
                ? Draggable<Object>(
                    data: _GroupDrag(d, id),
                    maxSimultaneousDrags: saving ? 0 : 1,
                    dragAnchorStrategy: pointerDragAnchorStrategy,
                    feedback: _feedback(name),
                    child: Tooltip(
                      message: '拖动调整分组顺序',
                      child: Icon(
                        Icons.drag_indicator,
                        key: ValueKey('group-grip-$id'),
                        size: 16,
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  Widget _hostRow(String id, List<String> visible, List<String> dragSelection) {
    final d = draft!, h = d.hosts[id]!, p = d.placements[id]!;
    final ids = selected.contains(id)
        ? dragSelection
        : List<String>.unmodifiable([id]);
    return Builder(
      builder: (row) => DragTarget<_HostDrag>(
        onWillAcceptWithDetails: (e) =>
            !saving && identical(e.data.owner, d) && !e.data.ids.contains(id),
        onMove: (e) => _hover('h:$id', _after(row, e.offset)),
        onLeave: (_) {
          if (hover == 'h:$id') setState(() => hover = null);
        },
        onAcceptWithDetails: (e) {
          if (saving || loading || !identical(d, draft)) return;
          setState(() {
            if (identical(e.data.owner, d)) {
              d.moveHosts(e.data.ids, id, _after(row, e.offset));
            }
            hover = null;
          });
        },
        builder: (_, candidates, _) {
          final color = Theme.of(context).colorScheme.primary;
          return Container(
            key: ValueKey('order-host-$id'),
            decoration: BoxDecoration(
              color: selected.contains(id) ? color.withValues(alpha: .1) : null,
              border: Border(
                top: BorderSide(
                  color: candidates.isNotEmpty && !hoverAfter
                      ? color
                      : Colors.transparent,
                ),
                bottom: BorderSide(
                  color: candidates.isNotEmpty && hoverAfter
                      ? color
                      : Colors.transparent,
                ),
              ),
            ),
            child: InkWell(
              onTap: saving ? null : () => _select(id, visible),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                child: Row(
                  children: [
                    Draggable<Object>(
                      data: _HostDrag(d, ids),
                      maxSimultaneousDrags: saving ? 0 : 1,
                      dragAnchorStrategy: pointerDragAnchorStrategy,
                      feedback: _feedback(
                        ids.length > 1 ? '${ids.length} 台主机' : h.name,
                      ),
                      child: Tooltip(
                        message: '拖动排序，或拖到左侧分组 / 收藏',
                        child: Icon(
                          Icons.drag_indicator,
                          key: ValueKey('host-grip-$id'),
                          size: 17,
                        ),
                      ),
                    ),
                    Checkbox(
                      value: selected.contains(id),
                      visualDensity: VisualDensity.compact,
                      onChanged: saving
                          ? null
                          : (v) => setState(() {
                              v! ? selected.add(id) : selected.remove(id);
                              anchor = id;
                            }),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            h.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          Text(
                            '${d.groups[p.groupId]!.name} · ${h.detail}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: ValueKey('order-favorite-$id'),
                      tooltip: p.favorite ? '取消收藏' : '加入收藏',
                      onPressed: saving
                          ? null
                          : () => setState(
                              () => d.assign([id], favorite: !p.favorite),
                            ),
                      icon: Icon(
                        p.favorite ? Icons.star : Icons.star_border,
                        size: 16,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = draft, size = MediaQuery.sizeOf(context);
    final visible = d?.visible(filter, search.text) ?? <String>[];
    final dragSelection = List<String>.unmodifiable(
      d?.hostIds.where(selected.contains) ?? const <String>[],
    );
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              unawaited(_close());
              return null;
            },
          ),
        },
        child: PopScope(
          canPop: !saving,
          child: Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 16,
            ),
            child: SizedBox(
              width: math.min(960, math.max(0, size.width - 48)),
              height: math.min(680, math.max(0, size.height - 48)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: math.max(
                          70,
                          (math.min(680, math.max(0, size.height - 48)) - 24) *
                              .42,
                        ),
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    '主机排序与分组',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '关闭',
                                  onPressed: saving ? null : _close,
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                              ],
                            ),
                            const Text(
                              '拖动主机可排序、移入分组或加入收藏。修改在保存后生效。',
                              style: TextStyle(fontSize: 11),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: search,
                              enabled: !saving && !loading,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search, size: 17),
                                hintText: '搜索全部主机（名称、用户和地址）',
                                isDense: true,
                              ),
                            ),
                            Wrap(
                              spacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  '已选 ${selected.length} / ${d?.hosts.length ?? 0} 台 · 当前 ${visible.length} 项',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                if (selected.isNotEmpty) ...[
                                  PopupMenuButton<String>(
                                    tooltip: '批量移入分组',
                                    enabled: !saving && !loading,
                                    onSelected: (g) => setState(
                                      () => d!.assign(selected, group: g),
                                    ),
                                    itemBuilder: (_) => [
                                      for (final id in d!.groupIds)
                                        PopupMenuItem(
                                          value: id,
                                          child: Text(d.groups[id]!.name),
                                        ),
                                    ],
                                    child: const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: Text('移入分组'),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: saving || loading
                                        ? null
                                        : () => setState(
                                            () => d!.assign(
                                              selected,
                                              favorite: true,
                                            ),
                                          ),
                                    child: const Text('加入收藏'),
                                  ),
                                  TextButton(
                                    onPressed: saving || loading
                                        ? null
                                        : () => setState(
                                            () => d!.assign(
                                              selected,
                                              favorite: false,
                                            ),
                                          ),
                                    child: const Text('取消收藏'),
                                  ),
                                  TextButton(
                                    onPressed: saving || loading
                                        ? null
                                        : () => setState(selected.clear),
                                    child: const Text('清除选择'),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (error != null)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 54),
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text(
                              error!,
                              key: const ValueKey('ordering-error'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (loading || committing) const LinearProgressIndicator(),
                    Expanded(
                      child: d == null
                          ? const Center(child: Text('等待配置载入'))
                          : AbsorbPointer(
                              absorbing: loading || saving,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(
                                    width: math.min(
                                      200,
                                      math.max(85, (size.width - 72) * .3),
                                    ),
                                    child: ListView.builder(
                                      itemCount: d.groupIds.length + 3,
                                      itemBuilder: (_, i) {
                                        if (i == 0) {
                                          return _groupRow(
                                            'all',
                                            '全部主机',
                                            actual: false,
                                          );
                                        }
                                        if (i == 1) {
                                          return _groupRow(
                                            'favorites',
                                            '收藏',
                                            actual: false,
                                          );
                                        }
                                        if (i == 2) {
                                          return const Divider(height: 8);
                                        }
                                        final id = d.groupIds[i - 3];
                                        return _groupRow(
                                          id,
                                          d.groups[id]!.name,
                                        );
                                      },
                                    ),
                                  ),
                                  const VerticalDivider(width: 12),
                                  Expanded(
                                    child: visible.isEmpty
                                        ? const Center(
                                            child: Text(
                                              '没有匹配主机',
                                              style: TextStyle(fontSize: 12),
                                            ),
                                          )
                                        : ListView.builder(
                                            itemCount: visible.length,
                                            itemBuilder: (_, i) => _hostRow(
                                              visible[i],
                                              visible,
                                              dragSelection,
                                            ),
                                          ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: saving || loading
                              ? null
                              : () async {
                                  if (await _discard() && mounted) {
                                    await _load();
                                  }
                                },
                          child: const Text('重新载入'),
                        ),
                        TextButton(
                          onPressed: saving ? null : _close,
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          key: const ValueKey('order-save'),
                          onPressed:
                              d?.dirty == true && !saving && !loading && loaded
                              ? _save
                              : null,
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
