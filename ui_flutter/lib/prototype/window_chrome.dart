import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Native hit testing needs physical client coordinates; no screen position or
/// guessed titlebar button width is persisted. Linux/Phase 2 stay unaffected.
class NativeMaximizeRegion extends StatefulWidget {
  const NativeMaximizeRegion({super.key, required this.child});
  final Widget child;
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  @override
  State<NativeMaximizeRegion> createState() => _NativeMaximizeRegionState();
}

class _NativeMaximizeRegionState extends State<NativeMaximizeRegion>
    with WidgetsBindingObserver {
  static const _window = MethodChannel('hspterm/prototype_window');
  final _bounds = GlobalKey();
  Rect? _sent;
  bool _scheduled = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    _sent = null;
    _schedule();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(NativeMaximizeRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  void _schedule() {
    if (!NativeMaximizeRegion.supported || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final box = _bounds.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) return;
      final scale = View.of(context).devicePixelRatio;
      final offset = box.localToGlobal(Offset.zero);
      final rect = Rect.fromLTWH(
        offset.dx * scale,
        offset.dy * scale,
        box.size.width * scale,
        box.size.height * scale,
      );
      if (!rect.isFinite || rect.isEmpty || rect == _sent) return;
      _sent = rect;
      unawaited(_send([rect.left, rect.top, rect.right, rect.bottom]));
    });
  }

  Future<void> _send(List<double> bounds) async {
    try {
      await _window.invokeMethod<void>('maximizeRect', bounds);
    } on MissingPluginException {
      // Standard system frame / older runner: normal maximize action remains.
      _sent = null;
    } on PlatformException {
      _sent = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (NativeMaximizeRegion.supported) unawaited(_send(const []));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    return SizedBox(key: _bounds, child: widget.child);
  }
}

/// Attach only to actual caption text/empty space. Never wrap terminal tabs,
/// controls or remote content: their drag gestures belong to the application.
class WindowDragRegion extends StatelessWidget {
  const WindowDragRegion({
    super.key,
    required this.onAction,
    required this.child,
  });
  final Future<void> Function(String) onAction;
  final Widget child;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    onPanStart: (_) => unawaited(onAction('drag')),
    onDoubleTap: () => unawaited(onAction('maximize')),
    onSecondaryTapUp: NativeMaximizeRegion.supported
        ? (_) => unawaited(onAction('systemMenu'))
        : null,
    child: child,
  );
}
