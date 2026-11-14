import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;

import 'controller.dart';
import 'same_word.dart';
import 'typography.dart';

/// Owns bounded native pictures and shaped glyphs; no persistent frame ticker.
class TerminalPaintCache {
  TerminalPaintCache({this.batchAscii = true});
  final bool batchAscii;
  TerminalTypography _typography = const TerminalTypography();
  void configure(TerminalTypography value) {
    if (_typography == value) return;
    clear();
    _typography = value;
  }

  final _glyphs = <(String, int, int, double), TextPainter>{};
  final _runs = <(String, int, int, double), TextPainter>{};
  final _rows = <int, (int, ui.Picture)>{};
  ui.Picture? _backgroundPicture;
  List<int> _backgroundVersions = const [];
  TerminalController? _backgroundOwner;
  Size _backgroundCell = Size.zero;
  int backgroundBuilds = 0;
  double _fontSize = 0;
  Size _cellSize = Size.zero;
  int rowBuilds = 0;
  int paints = 0;
  int? _sameWordKey;
  List<SameWordMatch> _sameWords = const [];
  List<SameWordMatch> sameWords(TerminalController controller) {
    final frame = controller.metadata;
    if (!(frame?.sameWordEnabled ?? false)) {
      _sameWordKey = null;
      _sameWords = const [];
      return _sameWords;
    }
    final key = Object.hash(
      identityHashCode(controller),
      controller.selectionStart,
      controller.selectionEnd,
      frame?.sameWordCaseSensitive,
      controller.frameCount,
    );
    if (key != _sameWordKey) {
      _sameWordKey = key;
      _sameWords = sameWordMatches(
        controller.rows,
        controller.selectionStart,
        controller.selectionEnd,
        caseSensitive: frame?.sameWordCaseSensitive ?? true,
      );
    }
    return _sameWords;
  }

  int get glyphCount => _glyphs.length + _runs.length;
  int get rowCount => _rows.length;
  TextPainter glyph(String text, int color, int flags, double fontSize) {
    final key = (text, color, flags & 6, fontSize);
    final storage = text.length > 1 ? _runs : _glyphs;
    final cached = storage.remove(key);
    if (cached != null) {
      storage[key] = cached;
      return cached;
    }
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: _typography.renderFamily,
          fontFamilyFallback: _typography.fallback,
          fontSize: fontSize,
          height: 1,
          fontFeatures: _typography.features,
          color: Color(color),
          fontWeight: flags & 2 != 0 ? FontWeight.bold : FontWeight.normal,
          fontStyle: flags & 4 != 0 ? FontStyle.italic : FontStyle.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    storage[key] = painter;
    // Halved glyph budget (2026-11-06 memory pass): 2048 single-cell
    // painters + 96 run painters per view keep the most recent working set
    // while bounding retained paragraphs on multi-pane layouts.
    if (storage.length > (identical(storage, _runs) ? 96 : 2048)) {
      storage.remove(storage.keys.first)?.dispose();
    }
    return painter;
  }

  /// Merge vertically identical color runs before recording any glyph row.
  /// Cell height includes line spacing: there is no separate line-gap color.
  void backgrounds(Canvas target, TerminalController controller, Size cell) {
    if (_backgroundPicture != null &&
        identical(_backgroundOwner, controller) &&
        _backgroundCell == cell &&
        listEquals(_backgroundVersions, controller.rowVersions)) {
      target.drawPicture(_backgroundPicture!);
      return;
    }
    _backgroundPicture?.dispose();
    _backgroundOwner = controller;
    _backgroundCell = cell;
    _backgroundVersions = List.of(controller.rowVersions);
    backgroundBuilds++;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final active = <(int, int, int), Rect>{};
    final paint = Paint()..isAntiAlias = false;
    void draw((int, int, int) key, Rect rect) {
      canvas.drawRect(rect, paint..color = Color(key.$3));
    }

    for (var y = 0; y < controller.rows.length; y++) {
      final cells = controller.rows[y];
      final next = <(int, int, int), Rect>{};
      for (var x = 0; x < cells.length;) {
        final start = x, c = cells[x];
        final color = c.flags & 1 != 0 ? c.foreground : c.background;
        while (++x < cells.length) {
          final n = cells[x];
          if ((n.flags & 1 != 0 ? n.foreground : n.background) != color) break;
        }
        final key = (start, x, color);
        final prior = active.remove(key);
        next[key] = Rect.fromLTRB(
          start * cell.width,
          prior?.top ?? y * cell.height,
          x * cell.width,
          (y + 1) * cell.height,
        );
      }
      for (final entry in active.entries) {
        draw(entry.key, entry.value);
      }
      active
        ..clear()
        ..addAll(next);
    }
    for (final entry in active.entries) {
      draw(entry.key, entry.value);
    }
    _backgroundPicture = recorder.endRecording();
    target.drawPicture(_backgroundPicture!);
  }

  void _prepare(double fontSize, Size cell) {
    if (_fontSize != fontSize || _cellSize != cell) {
      clear();
      _fontSize = fontSize;
      _cellSize = cell;
    }
  }

  ui.Picture row(
    TerminalController controller,
    int index,
    double fontSize,
    Size cell,
  ) {
    _prepare(fontSize, cell);
    final old = _rows[index];
    if (old != null && old.$1 == controller.rowVersions[index]) return old.$2;
    old?.$2.dispose();
    // Separate row pictures meet at fractional physical pixels on scaled
    // displays. Solid grid edges must not blend with the underlying screen.
    final recorder = ui.PictureRecorder(), paint = Paint()..isAntiAlias = false;
    final canvas = Canvas(recorder);
    final cells = controller.rows[index];
    // Only foreground belongs in per-row pictures. Backgrounds are painted
    // across the viewport in one pass so cached row textures cannot leave seams.
    for (var x = 0; x < cells.length; x++) {
      final c = cells[x];
      final inverse = c.flags & 1 != 0;
      final fg = inverse ? c.background : c.foreground;

      final rect = Rect.fromLTWH(x * cell.width, 0, cell.width, cell.height);

      if (c.flags & (64 | 256 | 1024) != 0) continue;
      final wide = c.flags & 32 != 0 ? 2 : 1;
      if (batchAscii &&
          c.flags & ~147 == 0 &&
          c.text.length == 1 &&
          c.text.codeUnitAt(0) >= 32 &&
          c.text.codeUnitAt(0) <= 126) {
        var end = x + 1;
        while (end < cells.length) {
          final next = cells[end];
          if (next.foreground != c.foreground ||
              next.background != c.background ||
              next.flags != c.flags ||
              next.text.length != 1 ||
              next.text.codeUnitAt(0) < 32 ||
              next.text.codeUnitAt(0) > 126) {
            break;
          }
          end++;
        }
        if (end - x >= (_typography.ligatures ? 2 : 3)) {
          final text = cells.sublist(x, end).map((c) => c.text).join();
          if (text.trim().isEmpty) {
            x = end - 1;
            continue;
          }
          final run = this.glyph(text, fg, c.flags, fontSize);
          // Font fallback/metrics must agree with the fixed terminal grid.
          // Otherwise use the individually clipped cell path below.
          if ((run.width - cell.width * (end - x)).abs() < .01) {
            canvas.save();
            canvas.clipRect(
              Rect.fromLTWH(rect.left, 0, cell.width * (end - x), cell.height),
              doAntiAlias: false,
            );
            run.paint(
              canvas,
              Offset(rect.left, (cell.height - run.height) / 2),
            );
            canvas.restore();
            x = end - 1;
            continue;
          }
        }
      }
      // A blank without decorations has no foreground drawing work.
      if (c.text == ' ' &&
          c.flags & (8 | 2048 | 4096 | 8192 | 16384 | 512) == 0) {
        continue;
      }
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(rect.left, 0, cell.width * wide, cell.height),
        doAntiAlias: false,
      );
      final glyph = this.glyph(c.text, fg, c.flags, fontSize);
      // Center the glyph inside its cell span: CJK fallback glyphs can be
      // narrower or wider than the strict cell grid, and left-aligned painting
      // then visibly detaches text from selection boxes (#7). Centering keeps
      // both on the same midline; ASCII glyphs measure one cell and are
      // unaffected.
      glyph.paint(
        canvas,
        Offset(
          rect.left + ((cell.width * wide) - glyph.width) / 2,
          (cell.height - glyph.height) / 2,
        ),
      );
      paint
        ..color = Color(fg)
        ..strokeWidth = 1;
      if (c.flags & 8 != 0) {
        canvas.drawLine(
          Offset(rect.left, cell.height - 2),
          Offset(rect.left + cell.width * wide, cell.height - 2),
          paint,
        );
      }
      if (c.flags & 2048 != 0) {
        for (final y in [cell.height - 2, cell.height - 4]) {
          canvas.drawLine(
            Offset(rect.left, y),
            Offset(rect.left + cell.width * wide, y),
            paint,
          );
        }
      }
      if (c.flags & (4096 | 8192 | 16384) != 0) {
        final path = Path()..moveTo(rect.left, cell.height - 2);
        if (c.flags & 4096 != 0) {
          for (var dx = 0.0; dx < cell.width * wide; dx += 2) {
            path.lineTo(
              rect.left + dx,
              cell.height - 2 + (dx % 4 == 0 ? -1 : 1),
            );
          }
          canvas.drawPath(path, paint..style = PaintingStyle.stroke);
          paint.style = PaintingStyle.fill;
        } else {
          final step = c.flags & 8192 != 0 ? 2.0 : 5.0;
          for (var dx = 0.0; dx < cell.width * wide; dx += step) {
            canvas.drawLine(
              Offset(rect.left + dx, cell.height - 2),
              Offset(
                rect.left + min(dx + step / 2, cell.width * wide),
                cell.height - 2,
              ),
              paint,
            );
          }
        }
      }
      if (c.flags & 512 != 0) {
        canvas.drawLine(
          Offset(rect.left, cell.height / 2),
          Offset(rect.left + cell.width * wide, cell.height / 2),
          paint,
        );
      }
      canvas.restore();
    }
    final picture = recorder.endRecording();
    _rows[index] = (controller.rowVersions[index], picture);
    rowBuilds++;
    final stale = _rows.keys.where((i) => i >= controller.rows.length).toList();
    for (final i in stale) {
      _rows.remove(i)?.$2.dispose();
    }
    return picture;
  }

  void clear() {
    _backgroundPicture?.dispose();
    _backgroundPicture = null;
    _backgroundOwner = null;
    _backgroundVersions = const [];
    _sameWordKey = null;
    _sameWords = const [];
    for (final row in _rows.values) {
      row.$2.dispose();
    }
    _rows.clear();
    for (final p in _glyphs.values) {
      p.dispose();
    }
    _glyphs.clear();
    for (final p in _runs.values) {
      p.dispose();
    }
    _runs.clear();
  }

  void dispose() => clear();
}

class TerminalPainter extends CustomPainter {
  TerminalPainter(
    this.controller,
    this.cache,
    this.fontSize,
    this.cell,
    this.blink,
    this.focused,
    this.preedit, {
    this.typography = const TerminalTypography(),
  }) : super(repaint: Listenable.merge([controller, blink, preedit]));
  final TerminalController controller;
  final TerminalPaintCache cache;
  final double fontSize;
  final Size cell;
  final ValueNotifier<bool> blink;
  final bool focused;
  final ValueNotifier<String> preedit;
  final TerminalTypography typography;
  @override
  void paint(Canvas canvas, Size size) {
    if (!controller.visible) return;
    cache.configure(typography);
    cache._prepare(fontSize, cell);
    cache.paints++;
    final frame = controller.metadata;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..isAntiAlias = false
        ..color = Color(frame?.background ?? 0xff10151d),
    );
    canvas.save();
    canvas.clipRect(Offset.zero & size, doAntiAlias: false);
    cache.backgrounds(canvas, controller, cell);
    for (var y = 0; y < controller.rows.length; y++) {
      canvas.save();
      canvas.translate(0, y * cell.height);
      canvas.drawPicture(cache.row(controller, y, fontSize, cell));
      canvas.restore();
    }
    for (final match in cache.sameWords(controller)) {
      final rect = Rect.fromLTWH(
        match.start * cell.width,
        match.row * cell.height,
        (match.end - match.start) * cell.width,
        cell.height,
      );
      canvas.drawRect(rect, Paint()..color = const Color(0x337f9eaf));
      canvas.drawRect(
        rect.deflate(.5),
        Paint()
          ..color = const Color(0x997f9eaf)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    if (frame != null && frame.searchRevision == frame.contentRevision) {
      for (final span in frame.searchSpans) {
        canvas.drawRect(
          Rect.fromLTWH(
            span.start * cell.width,
            span.row * cell.height,
            (span.end - span.start) * cell.width,
            cell.height,
          ),
          Paint()..color = const Color(0x667e6613),
        );
      }
      final active = controller.activeSearch;
      if (active != null && active.revision == frame.contentRevision) {
        final first = frame.historyLines - frame.displayOffset;
        for (
          var row = max(active.startRow, first);
          row <= min(active.endRow, first + frame.rows - 1);
          row++
        ) {
          final start = row == active.startRow ? active.startColumn : 0,
              end = row == active.endRow ? active.endColumn : frame.columns;
          if (end > start) {
            canvas.drawRect(
              Rect.fromLTWH(
                start * cell.width,
                (row - first) * cell.height,
                (end - start) * cell.width,
                cell.height,
              ),
              Paint()..color = const Color(0x99d68127),
            );
          }
        }
      }
    }
    final a = controller.selectionStart, b = controller.selectionEnd;
    if (a != null && b != null && frame != null) {
      final reversed = a.y > b.y || a.y == b.y && a.x > b.x;
      final start = reversed ? b : a, end = reversed ? a : b;
      final selected = Path();
      for (var y = max(0, start.y); y <= min(end.y, frame.rows - 1); y++) {
        final left = y == start.y ? start.x : 0,
            right = y == end.y ? end.x : frame.columns - 1;
        selected.addRect(
          Rect.fromLTWH(
            left * cell.width,
            y * cell.height,
            (right - left + 1) * cell.width,
            cell.height,
          ),
        );
      }
      canvas.drawPath(
        selected,
        Paint()
          ..isAntiAlias = false
          ..color = const Color(0x665c92cc),
      );
    }
    if (frame != null &&
        frame.cursorVisible &&
        frame.cursorShape != 4 &&
        frame.cursorRow >= 0 &&
        frame.cursorRow < frame.rows &&
        (!focused || !frame.cursorBlink || blink.value)) {
      final cursorCell =
          frame.cursorRow < controller.rows.length &&
              frame.cursorColumn < controller.rows[frame.cursorRow].length
          ? controller.rows[frame.cursorRow][frame.cursorColumn]
          : null;
      final cursorWidth = cursorCell != null && cursorCell.flags & 32 != 0
          ? 2
          : 1;
      final rect = Rect.fromLTWH(
        frame.cursorColumn * cell.width,
        frame.cursorRow * cell.height,
        cell.width * cursorWidth,
        cell.height,
      );
      final paint = Paint()..color = Color(frame.cursorColor);
      if (!focused || frame.cursorShape == 3) {
        canvas.drawRect(rect.deflate(.5), paint..style = PaintingStyle.stroke);
      } else if (frame.cursorShape == 1) {
        canvas.drawRect(
          Rect.fromLTWH(rect.left, rect.bottom - 2, rect.width, 2),
          paint,
        );
      } else if (frame.cursorShape == 2) {
        canvas.drawRect(
          Rect.fromLTWH(rect.left, rect.top, 2, rect.height),
          paint,
        );
      } else {
        canvas.drawRect(rect, paint);
        if (frame.cursorRow < controller.rows.length &&
            frame.cursorColumn < controller.rows[frame.cursorRow].length) {
          final c = controller.rows[frame.cursorRow][frame.cursorColumn];
          final glyph = cache.glyph(
            c.text,
            frame.background,
            c.flags,
            fontSize,
          );
          glyph.paint(
            canvas,
            Offset(rect.left, rect.top + (cell.height - glyph.height) / 2),
          );
        }
      }
    }
    if (frame != null && preedit.value.isNotEmpty) {
      final text = TextPainter(
        text: TextSpan(
          text: preedit.value,
          style: TextStyle(
            fontFamily: typography.renderFamily,
            fontFamilyFallback: typography.fallback,
            fontFeatures: typography.features,
            fontSize: fontSize,
            color: const Color(0xffffffff),
            decoration: TextDecoration.underline,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      final x = min(
        frame.cursorColumn * cell.width,
        max(0.0, size.width - text.width),
      );
      final y = frame.cursorRow.clamp(0, frame.rows - 1) * cell.height;
      canvas.drawRect(
        Rect.fromLTWH(x, y, text.width, cell.height),
        Paint()..color = Color(frame.background),
      );
      text.paint(canvas, Offset(x, y));
      text.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TerminalPainter old) =>
      old.controller != controller ||
      old.fontSize != fontSize ||
      old.typography != typography ||
      old.focused != focused ||
      old.cell != cell;
}
