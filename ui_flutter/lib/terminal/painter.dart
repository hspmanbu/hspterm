import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;

import 'controller.dart';
import 'same_word.dart';
import 'typography.dart';

/// Snap filled grid edges to device pixels, including a fractional viewport
/// origin. Glyph placement and the actual terminal grid remain unchanged.
class _PixelGrid {
  _PixelGrid(Canvas canvas, double ratio, [List<double>? transform]) {
    final m = transform ?? canvas.getTransform();
    if (m[1] == 0 &&
        m[4] == 0 &&
        m[3] == 0 &&
        m[7] == 0 &&
        m[15] == 1 &&
        m[0].isFinite &&
        m[5].isFinite &&
        m[12].isFinite &&
        m[13].isFinite &&
        m[0] > 0 &&
        m[5] > 0 &&
        ratio.isFinite &&
        ratio > 0) {
      enabled = true;
      sx = m[0] * ratio;
      sy = m[5] * ratio;
      tx = m[12] * ratio;
      ty = m[13] * ratio;
    }
  }
  bool enabled = false;
  double sx = 1, sy = 1, tx = 0, ty = 0;
  (bool, double, double, double, double) get key =>
      (enabled, sx, sy, tx % 1, ty % 1);
  double x(double v) =>
      enabled ? ((v * sx + tx + .5).floorToDouble() - tx) / sx : v;
  double y(double v) =>
      enabled ? ((v * sy + ty + .5).floorToDouble() - ty) / sy : v;
  Rect rect(Rect r) =>
      Rect.fromLTRB(x(r.left), y(r.top), x(r.right), y(r.bottom));
}

/// Owns bounded native pictures and shaped glyphs; no persistent frame ticker.
class TerminalPaintCache {
  static const _runLimit = 96;

  TerminalPaintCache({this.batchAscii = true}) {
    _instances.removeWhere((ref) => ref.target == null);
    _instances.add(WeakReference(this));
  }
  static final _instances = <WeakReference<TerminalPaintCache>>[];

  /// Weak registry: sampling never keeps a closed terminal/cache alive.
  static Map<String, int> memoryCounters() {
    var glyphs = 0, rows = 0, pictures = 0, pictureBytes = 0;
    _instances.removeWhere((ref) => ref.target == null);
    for (final ref in _instances) {
      final cache = ref.target;
      if (cache == null) continue;
      glyphs += cache.glyphCount;
      rows += cache.rowCount;
      for (final row in cache._rows.values) {
        pictureBytes += row.bytes;
        pictures++;
      }
      if (cache._backgroundPicture case final background?) {
        pictureBytes += background.bytes;
        pictures++;
      }
    }
    return {
      'glyphs': glyphs,
      'rowPictures': rows,
      'pictures': pictures,
      'pictureKiB': pictureBytes ~/ 1024,
    };
  }

  final bool batchAscii;
  TerminalTypography _typography = const TerminalTypography();
  void configure(TerminalTypography value) {
    if (_typography == value) return;
    clear();
    _typography = value;
  }

  final _glyphs = <(String, int, int, double), TextPainter>{};
  final _runs = <(String, int, int, double), TextPainter>{};
  final _unfitAsciiRuns = <(String, int)>{};
  var _rows = <int, ({int version, ui.Picture picture, int bytes})>{};
  ({ui.Picture picture, int bytes})? _backgroundPicture;
  List<int> _backgroundVersions = const [];
  TerminalController? _backgroundOwner;
  Size _backgroundCell = Size.zero;
  (bool, double, double, double, double)? _backgroundPixels;
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
    if (storage.length > (identical(storage, _runs) ? _runLimit : 2048)) {
      storage.remove(storage.keys.first)?.dispose();
    }
    return painter;
  }

  TextPainter? _fitAsciiRun(
    String text,
    int color,
    int flags,
    double fontSize,
  ) {
    final style = flags & 6;
    final key = (text, style);
    // Color cannot change the fit. Font or cell changes clear this cache.
    if (_unfitAsciiRuns.contains(key)) return null;
    final run = glyph(text, color, flags, fontSize);
    if ((run.width - _cellSize.width * text.length).abs() < .01) return run;

    // No picture ever used this paragraph. Retain only the failed fit result
    // so updates with the same text do not allocate another native paragraph.
    _runs.remove((text, color, style, fontSize))?.dispose();
    _unfitAsciiRuns.add(key);
    if (_unfitAsciiRuns.length > _runLimit) {
      _unfitAsciiRuns.remove(_unfitAsciiRuns.first);
    }
    return null;
  }

  /// Merge vertically identical color runs before recording any glyph row.
  /// Cell height includes line spacing: there is no separate line-gap color.
  void backgrounds(
    Canvas target,
    TerminalController controller,
    Size cell, {
    double devicePixelRatio = 1,
    List<double>? viewportTransform,
  }) {
    final pixels = _PixelGrid(target, devicePixelRatio, viewportTransform);
    final old = _backgroundPicture;
    if (old != null &&
        identical(_backgroundOwner, controller) &&
        _backgroundCell == cell &&
        _backgroundPixels == pixels.key &&
        listEquals(_backgroundVersions, controller.rowVersions)) {
      target.drawPicture(old.picture);
      return;
    }
    final versions = List<int>.of(controller.rowVersions);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final active = <(int, int, int), Rect>{};
    final paint = Paint()..isAntiAlias = false;
    void draw((int, int, int) key, Rect rect) {
      canvas.drawRect(pixels.rect(rect), paint..color = Color(key.$3));
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
    // Publish a complete recording before retiring its predecessor. If
    // recording throws, the cache still owns a live picture with its old key.
    final picture = recorder.endRecording();
    _backgroundPicture = (
      picture: picture,
      bytes: picture.approximateBytesUsed,
    );
    _backgroundOwner = controller;
    _backgroundCell = cell;
    _backgroundPixels = pixels.key;
    _backgroundVersions = versions;
    backgroundBuilds++;
    old?.picture.dispose();
    target.drawPicture(picture);
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
    final version = controller.rowVersions[index];
    if (old != null && old.version == version) return old.picture;
    // Separate row pictures meet at fractional physical pixels on scaled
    // displays. Solid grid edges must not blend with the underlying screen.
    final recorder = ui.PictureRecorder(), paint = Paint()..isAntiAlias = false;
    final canvas = Canvas(recorder);
    final cells = controller.rows[index];
    // Only foreground belongs in per-row pictures. Backgrounds are painted
    // across the viewport in one pass so cached row textures cannot leave seams.
    var asciiRunEnd = 0;
    for (var x = 0; x < cells.length; x++) {
      final c = cells[x];
      final inverse = c.flags & 1 != 0;
      final fg = inverse ? c.background : c.foreground;

      final rect = Rect.fromLTWH(x * cell.width, 0, cell.width, cell.height);

      // Spacers carry no glyph of their own: a trailing spacer (64) is
      // covered by its lead cell's wide paint, a wrap marker (1024) is
      // drawn as the wrapped glyph on the next row, and hidden cells
      // (256) stay blank. A trailing spacer whose left neighbor lost the
      // WIDE_CHAR flag is an orphan; degrade it to a plain single cell
      // so its own text is never swallowed by the skip.
      if (c.flags & (256 | 1024) != 0) continue;
      if (c.flags & 64 != 0 && (x == 0 || cells[x - 1].flags & 32 != 0)) {
        continue;
      }
      final wide = c.flags & 32 != 0 ? 2 : 1;
      if (batchAscii &&
          x >= asciiRunEnd &&
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
        // If the run cannot fit the cell grid, draw its cells individually.
        // Do not scan and shape the same run's suffix for each remaining cell.
        asciiRunEnd = end;
        if (end - x >= (_typography.ligatures ? 2 : 3)) {
          final text = cells.sublist(x, end).map((c) => c.text).join();
          if (text.trim().isEmpty) {
            x = end - 1;
            continue;
          }
          final run = _fitAsciiRun(text, fg, c.flags, fontSize);
          // Font fallback/metrics must agree with the fixed terminal grid.
          // Otherwise use the individually clipped cell path below.
          if (run != null) {
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
    _rows[index] = (
      version: version,
      picture: picture,
      bytes: picture.approximateBytesUsed,
    );
    old?.picture.dispose();
    rowBuilds++;
    final stale = _rows.keys.where((i) => i >= controller.rows.length).toList();
    for (final i in stale) {
      _rows.remove(i)?.picture.dispose();
    }
    return picture;
  }

  void clear() {
    final background = _backgroundPicture;
    final rows = _rows;
    _backgroundPicture = null;
    _backgroundOwner = null;
    _backgroundVersions = const [];
    _rows = {};
    _sameWordKey = null;
    _sameWords = const [];
    background?.picture.dispose();
    for (final row in rows.values) {
      row.picture.dispose();
    }
    for (final p in _glyphs.values) {
      p.dispose();
    }
    _glyphs.clear();
    for (final p in _runs.values) {
      p.dispose();
    }
    _runs.clear();
    _unfitAsciiRuns.clear();
  }

  void dispose() {
    clear();
    _instances.removeWhere(
      (ref) => ref.target == null || identical(ref.target, this),
    );
  }
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
    this.devicePixelRatio = 1,
    this.viewportTransform,
    this.onConnectedPaint,
  }) : super(repaint: Listenable.merge([controller, blink, preedit]));
  final TerminalController controller;
  final TerminalPaintCache cache;
  final double fontSize;
  final Size cell;
  final ValueNotifier<bool> blink;
  final bool focused;
  final ValueNotifier<String> preedit;
  final TerminalTypography typography;
  final double devicePixelRatio;
  // RepaintBoundary recordings start at (0,0); their Canvas transform omits
  // ancestor offsets. Obtain the real logical viewport transform at paint.
  final List<double>? Function()? viewportTransform;
  final VoidCallback? onConnectedPaint;
  @override
  void paint(Canvas canvas, Size size) {
    if (!controller.visible) return;
    cache.configure(typography);
    cache._prepare(fontSize, cell);
    cache.paints++;
    final frame = controller.metadata;
    final transform = viewportTransform?.call();
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..isAntiAlias = false
        ..color = Color(frame?.background ?? 0xff10151d),
    );
    canvas.save();
    canvas.clipRect(Offset.zero & size, doAntiAlias: false);
    cache.backgrounds(
      canvas,
      controller,
      cell,
      devicePixelRatio: devicePixelRatio,
      viewportTransform: transform,
    );
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
      final pixels = _PixelGrid(canvas, devicePixelRatio, transform);
      Path? united;
      final first = max(0, start.y), last = min(end.y, frame.rows - 1);
      final bands = <Rect>[];
      if (first <= last) {
        bands.add(
          Rect.fromLTRB(
            (first == start.y ? start.x : 0) * cell.width,
            first * cell.height,
            (first == end.y ? end.x + 1 : frame.columns) * cell.width,
            (first + 1) * cell.height,
          ),
        );
        if (last - first > 1) {
          bands.add(
            Rect.fromLTRB(
              0,
              (first + 1) * cell.height,
              frame.columns * cell.width,
              last * cell.height,
            ),
          );
        }
        if (last > first) {
          bands.add(
            Rect.fromLTRB(
              0,
              last * cell.height,
              (last == end.y ? end.x + 1 : frame.columns) * cell.width,
              (last + 1) * cell.height,
            ),
          );
        }
      }
      // At most three bands and two unions, independent of selected row count.
      // Interior row contours never become translucent raster boundaries.
      for (final band in bands) {
        final selected = Path()..addRect(pixels.rect(band));
        united = united == null
            ? selected
            : Path.combine(PathOperation.union, united, selected);
      }
      if (united != null) {
        canvas.drawPath(
          united,
          Paint()
            ..isAntiAlias = false
            ..color = const Color(0x665c92cc),
        );
      }
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
          // Repaint the glyph on top of the block with the same layout
          // rule as the row path above: centered inside the cursor rect
          // and clipped to it, so a wide glyph never bleeds past its own
          // 2-cell span.
          canvas.save();
          canvas.clipRect(rect, doAntiAlias: false);
          glyph.paint(
            canvas,
            Offset(
              rect.left + (rect.width - glyph.width) / 2,
              rect.top + (cell.height - glyph.height) / 2,
            ),
          );
          canvas.restore();
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
    if (frame != null && controller.connected) onConnectedPaint?.call();
  }

  @override
  bool shouldRepaint(covariant TerminalPainter old) =>
      old.controller != controller ||
      old.fontSize != fontSize ||
      old.typography != typography ||
      old.focused != focused ||
      old.cell != cell ||
      old.devicePixelRatio != devicePixelRatio;
}
