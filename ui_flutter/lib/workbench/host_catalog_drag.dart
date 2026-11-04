import 'dart:async';

import 'package:flutter/material.dart';

import '../src/rust/host_ordering.dart';
import 'host_ordering.dart';

/// One gesture, one immutable original Vault/catalog view. Reading starts only
/// once a drag actually starts; rebuilding every row never queries storage.
class HostCatalogDrag {
  HostCatalogDrag({
    required this.owner,
    required this.load,
    List<String> ids = const [],
    this.groupId,
  }) : ids = List.unmodifiable(ids);
  final Object owner;
  final Future<OrderingView> Function() load;
  final List<String> ids;
  final String? groupId;
  Future<({HostOrderDraft? draft, Object? error})>? _original;
  void start() {
    // The widget may survive a cancelled gesture. A new drag must capture a
    // fresh original; already accepted drops retain their own local Future.
    _original = () async {
      try {
        return (draft: HostOrderDraft(await load()), error: null);
      } catch (error) {
        return (draft: null, error: error);
      }
    }();
  }

  Future<HostOrderDraft> proposal(HostCatalogIntent intent) async {
    final future = _original;
    if (future == null) throw StateError('拖放没有有效的起始配置');
    final result = await future;
    final draft = result.draft;
    if (draft == null) throw StateError('无法读取原拖放配置：${result.error}');
    final next = draft.copy();
    final group = groupId;
    if (group != null) {
      final target = intent.groupId;
      if (target == null ||
          intent.hostId != null ||
          intent.favorite ||
          !next.groups.containsKey(group) ||
          !next.groups.containsKey(target)) {
        throw StateError('分组拖放目标已失效');
      }
      next.moveGroup(group, target, intent.after);
    } else {
      if (ids.isEmpty ||
          ids.toSet().length != ids.length ||
          ids.any((id) => !next.hosts.containsKey(id))) {
        throw StateError('拖放主机选择已改变');
      }
      final target = intent.hostId;
      if (target != null &&
          (!next.hosts.containsKey(target) || ids.contains(target))) {
        throw StateError('不能放到所选主机自身');
      }
      if (intent.groupId != null) next.assign(ids, group: intent.groupId);
      if (intent.favorite) next.assign(ids, favorite: true);
      if (target != null) {
        next.moveHosts(ids, target, intent.after);
      } else if (intent.groupId != null) {
        final rest = next.hostIds
            .where(
              (id) =>
                  !ids.contains(id) &&
                  next.placements[id]!.groupId == intent.groupId,
            )
            .toList();
        if (rest.isNotEmpty) next.moveHosts(ids, rest.last, true);
      } else if (!intent.favorite) {
        throw StateError('请选择明确的主机、分组或收藏目标');
      }
    }
    return next;
  }
}

class HostCatalogIntent {
  const HostCatalogIntent({
    this.hostId,
    this.groupId,
    this.favorite = false,
    this.after = false,
  });
  final String? hostId, groupId;
  final bool favorite, after;
}

class HostCatalogDragSource extends StatelessWidget {
  const HostCatalogDragSource({
    super.key,
    required this.drag,
    required this.label,
    required this.child,
  });
  final HostCatalogDrag drag;
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Draggable<HostCatalogDrag>(
    dragAnchorStrategy: pointerDragAnchorStrategy,
    data: drag,
    onDragStarted: drag.start,
    maxSimultaneousDrags: 1,
    feedback: Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(4),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
    ),
    childWhenDragging: Opacity(opacity: .45, child: child),
    child: child,
  );
}

class HostCatalogDrop extends StatefulWidget {
  const HostCatalogDrop({
    super.key,
    required this.owner,
    required this.accept,
    required this.onDrop,
    required this.child,
    this.insertion = false,
  });
  final Object owner;
  final bool Function(HostCatalogDrag) accept;
  final Future<void> Function(HostCatalogDrag, bool after) onDrop;
  final Widget child;
  final bool insertion;
  @override
  State<HostCatalogDrop> createState() => _HostCatalogDropState();
}

class _HostCatalogDropState extends State<HostCatalogDrop> {
  bool _after = false;
  @override
  Widget build(BuildContext context) => DragTarget<HostCatalogDrag>(
    onWillAcceptWithDetails: (d) =>
        identical(d.data.owner, widget.owner) && widget.accept(d.data),
    onMove: (d) {
      final box = context.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        final point = box.globalToLocal(d.offset);
        final after = widget.insertion
            ? point.dy > box.size.height / 2
            : point.dx > box.size.width / 2;
        if (after != _after) setState(() => _after = after);
      }
    },
    onAcceptWithDetails: (d) => unawaited(widget.onDrop(d.data, _after)),
    builder: (context, candidates, rejected) {
      final color = Theme.of(context).colorScheme.primary;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: candidates.isEmpty ? null : color.withValues(alpha: .12),
          border: candidates.isEmpty
              ? null
              : widget.insertion
              ? Border(
                  top: !_after
                      ? BorderSide(color: color, width: 2)
                      : BorderSide.none,
                  bottom: _after
                      ? BorderSide(color: color, width: 2)
                      : BorderSide.none,
                )
              : Border.all(color: color),
        ),
        child: widget.child,
      );
    },
  );
}
