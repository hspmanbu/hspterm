import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Ownership of one physical gesture; native delivery survives Flutter's
/// synthetic cancel and source-widget unmount after the handoff.
class ExplorerDragLease {
  ExplorerDragLease(this.pointer, this.origin);
  final int pointer;
  final Offset origin;
  bool released = false, preparing = false, handedOff = false;
  void release() {
    if (!handedOff) released = true;
  }
}

/// Keep ordinary Flutter drags inside the client. The immutable source is
/// captured at mouse-down, and leaving the client admits native preparation
/// once, irrespective of later selection/focus/rebuild changes.
class ExplorerDragHandoff<T> extends StatefulWidget {
  const ExplorerDragHandoff({
    super.key,
    required this.enabled,
    required this.capture,
    required this.onLeave,
    required this.child,
  });
  final bool enabled;
  final T Function(ExplorerDragLease) capture;
  final Future<void> Function(T, Offset) onLeave;
  final Widget child;
  @override
  State<ExplorerDragHandoff<T>> createState() => _ExplorerDragHandoffState<T>();
}

class _ExplorerDragHandoffState<T> extends State<ExplorerDragHandoff<T>> {
  ({ExplorerDragLease lease, T source})? _active;
  @override
  void dispose() {
    _active?.lease.release();
    super.dispose();
  }

  void _release(PointerEvent event) {
    final active = _active;
    if (active?.lease.pointer == event.pointer) active!.lease.release();
  }

  @override
  Widget build(BuildContext context) => !widget.enabled
      ? widget.child
      : Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (event.buttons != kPrimaryMouseButton) return;
            _active?.lease.release();
            final lease = ExplorerDragLease(event.pointer, event.position);
            _active = (lease: lease, source: widget.capture(lease));
          },
          onPointerMove: (event) {
            final active = _active;
            if (active == null) return;
            final lease = active.lease;
            if (lease.pointer != event.pointer ||
                lease.released ||
                lease.preparing ||
                (event.position - lease.origin).distance < kTouchSlop) {
              return;
            }
            final view = View.of(context);
            final bounds =
                Offset.zero & (view.physicalSize / view.devicePixelRatio);
            if (bounds.contains(event.position)) return;
            lease.preparing = true;
            // The operation owner handles its errors and resource drain, and can
            // outlive this display widget after starting native delivery.
            unawaited(widget.onLeave(active.source, event.position));
          },
          onPointerUp: _release,
          onPointerCancel: _release,
          child: widget.child,
        );
}
