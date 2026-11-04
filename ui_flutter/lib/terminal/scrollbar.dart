import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'controller.dart';

class HistoryScrollbar extends StatelessWidget {
  const HistoryScrollbar({super.key, required this.controller});
  final TerminalController controller;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      void seek(double y) {
        final frame = controller.metadata;
        if (frame == null || frame.historyLines == 0) return;
        unawaited(
          controller
              .seek(
                (y / constraints.maxHeight * frame.historyLines).round().clamp(
                  0,
                  frame.historyLines,
                ),
              )
              .catchError(controller.report),
        );
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (event) => seek(event.localPosition.dy),
        onTapDown: (event) => seek(event.localPosition.dy),
        child: CustomPaint(
          painter: _HistoryPainter(controller),
          child: const SizedBox.expand(),
        ),
      );
    },
  );
}

class _HistoryPainter extends CustomPainter {
  _HistoryPainter(this.c) : super(repaint: c);
  final TerminalController c;
  @override
  void paint(Canvas canvas, Size size) {
    if (!c.visible) return;
    final frame = c.metadata;
    if (frame == null) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xff18212e),
    );
    final summary = c.searchSummary;
    if (summary != null && summary.revision == frame.contentRevision) {
      for (var i = 0; i < summary.markers.length; i++) {
        if (summary.markers[i] > 0) {
          canvas.drawRect(
            Rect.fromLTWH(
              0,
              i * size.height / summary.markers.length,
              size.width,
              2,
            ),
            Paint()..color = Colors.amber,
          );
        }
      }
    }
    final total = frame.historyLines + frame.rows;
    final height = max(
      12.0,
      size.height * frame.rows / total,
    ).clamp(0.0, size.height);
    final fraction = frame.historyLines == 0
        ? 0.0
        : (frame.historyLines - frame.displayOffset) / frame.historyLines;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          2,
          fraction * (size.height - height),
          size.width - 4,
          height,
        ),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xff7c8a9f),
    );
  }

  @override
  bool shouldRepaint(_HistoryPainter old) => old.c != c;
}
