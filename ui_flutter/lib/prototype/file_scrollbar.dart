import 'package:flutter/material.dart';

/// A pinned scrollbar surrounds both the list and fixed chrome. Flutter's
/// painter derives track extent from scroll metrics, not its own box size.
/// Restore that chrome extent before the painter subtracts its padding, so
/// the thumb covers exactly the actual list viewport, including at the end.
class FileViewportScrollbar extends RawScrollbar {
  const FileViewportScrollbar({
    super.key,
    required this.axis,
    required this.viewportChrome,
    required super.controller,
    required super.child,
    super.padding,
    super.scrollbarOrientation,
    super.thickness,
    super.radius,
    super.thumbColor,
    super.trackVisibility,
    super.trackColor,
    super.trackBorderColor,
    super.thumbVisibility,
    super.notificationPredicate,
  });

  final Axis axis;
  final double viewportChrome;

  @override
  RawScrollbarState<FileViewportScrollbar> createState() =>
      _FileScrollbarState();
}

class _FileScrollbarState extends RawScrollbarState<FileViewportScrollbar> {
  void _metrics(ScrollMetrics metrics) {
    if (metrics.axis == widget.axis && metrics.hasViewportDimension) {
      scrollbarPainter.update(
        metrics.copyWith(
          viewportDimension: metrics.viewportDimension + widget.viewportChrome,
        ),
        metrics.axisDirection,
      );
    }
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) {
          _metrics(n.metrics);
          return false;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (widget.notificationPredicate(n)) _metrics(n.metrics);
            return false;
          },
          // Let the standard scrollbar process gestures and notifications
          // first, then correct only its painter. Actual ScrollPosition and
          // notifications passed to other consumers remain unchanged.
          child: super.build(context),
        ),
      );
}
