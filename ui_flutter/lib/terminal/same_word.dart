import 'dart:math';

import '../src/rust/api.dart' show RenderCell;

typedef SameWordMatch = ({int row, int start, int end});
const _delimiters = '()[]{}<>"\'`,;:!?=+*/\\|&';
bool _delimiter(String c) => c.trim().isEmpty || _delimiters.contains(c);

class _Line {
  _Line(this.text, this.columns, this.ends);
  final String text;
  final List<int> columns, ends;
}

_Line? _project(List<RenderCell> cells) {
  final text = StringBuffer(), columns = <int>[], ends = <int>[];
  for (var x = 0; x < cells.length; x++) {
    final cell = cells[x];
    if (cell.flags & (64 | 256) != 0) continue;
    final value = cell.flags & 1024 != 0 ? ' ' : cell.text;
    if (text.length + value.length > 8192) return null;
    text.write(value);
    final end = (x + (cell.flags & 32 != 0 ? 2 : 1)).clamp(0, cells.length);
    for (var i = 0; i < value.length; i++) {
      columns.add(x);
      ends.add(end);
    }
  }
  return _Line(text.toString(), columns, ends);
}

/// Literal-only, bounded selection decoration. No history, input or regex rules.
List<SameWordMatch> sameWordMatches(
  List<List<RenderCell>> rows,
  Point<int>? a,
  Point<int>? b, {
  required bool caseSensitive,
}) {
  if (a == null || b == null || a.y != b.y || a.y < 0 || a.y >= rows.length) {
    return const [];
  }
  final left = min(a.x, b.x), right = max(a.x, b.x);
  if (left < 0 || right >= rows[a.y].length || right - left > 256) {
    return const [];
  }
  if (rows[a.y]
          .sublist(left, right + 1)
          .where((c) => c.flags & (64 | 256) == 0)
          .length <
      2) {
    return const [];
  }
  final source = _project(rows[a.y]);
  if (source == null) return const [];
  var begin = source.columns.indexWhere((c) => c >= left);
  var end = source.columns.lastIndexWhere((c) => c <= right) + 1;
  if (begin < 0 || end <= begin || end - begin < 2 || end - begin > 256) {
    return const [];
  }
  // Concealed cells cannot become a visual query through their real text.
  if (rows[a.y].sublist(left, right + 1).any((c) => c.flags & 1024 != 0)) {
    return const [];
  }
  if (begin > 0 && !_delimiter(source.text.substring(begin - 1, begin))) {
    return const [];
  }
  if (end < source.text.length &&
      !_delimiter(source.text.substring(end, end + 1))) {
    return const [];
  }
  final needle = source.text.substring(begin, end);
  if (needle.trim() != needle ||
      needle.contains(RegExp(r'\s')) ||
      needle.runes.length < 2) {
    return const [];
  }
  final re = RegExp(
    RegExp.escape(needle),
    caseSensitive: caseSensitive,
    unicode: true,
  );
  final matches = <SameWordMatch>[];
  var bytes = 0;
  for (var y = 0; y < rows.length; y++) {
    final line = y == a.y ? source : _project(rows[y]);
    if (line == null) continue;
    bytes += line.text.length;
    if (bytes > 65536) break;
    for (final m in re.allMatches(line.text).take(128)) {
      if (m.start > 0 &&
          !_delimiter(line.text.substring(m.start - 1, m.start))) {
        continue;
      }
      if (m.end < line.text.length &&
          !_delimiter(line.text.substring(m.end, m.end + 1))) {
        continue;
      }
      final start = line.columns[m.start], end = line.ends[m.end - 1];
      if (y == a.y && start == left && end == right + 1) continue;
      matches.add((row: y, start: start, end: end));
      if (matches.length >= 1024) return matches;
    }
  }
  return matches;
}
