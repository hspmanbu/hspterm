import 'dart:math';

import '../src/rust/api.dart';

const _wrap = 16, _wideTail = 64, _hidden = 256, _wrapSpacer = 1024;
const _nonCharacter = _wideTail | _wrapSpacer;
const _maxRows = 16;
const _maxSteps = 512;

bool _validRow(List<List<RenderCell>> rows, int y) =>
    y >= 0 && y < rows.length && rows[y].isNotEmpty;

bool _wraps(List<RenderCell> row) => row.last.flags & _wrap != 0;

int _snap(List<RenderCell> row, int x) {
  final column = x.clamp(0, row.length - 1);
  return column > 0 && row[column].flags & _wideTail != 0 ? column - 1 : column;
}

int _compare(Point<int> a, Point<int> b) =>
    a.y == b.y ? a.x.compareTo(b.x) : a.y.compareTo(b.y);

/// Signed number of horizontal key presses. A soft wrap contributes no key.
/// A hard break contributes one only inside a verified multiline edit.
int caretDistance(
  List<List<RenderCell>> rows,
  Point<int> cursor,
  Point<int> click, {
  ConfirmedCaretEdit? edit,
}) {
  if (!_validRow(rows, cursor.y) || !_validRow(rows, click.y)) return 0;
  cursor = Point(_snap(rows[cursor.y], cursor.x), cursor.y);
  click = Point(_snap(rows[click.y], click.x), click.y);
  final direction = _compare(click, cursor);
  if (direction == 0) return 0;
  final first = direction > 0 ? cursor : click;
  final last = direction > 0 ? click : cursor;
  if (last.y - first.y >= _maxRows) return 0;
  final verified =
      edit != null && edit.contains(rows, first) && edit.contains(rows, last);
  var steps = 0;
  for (var y = first.y; y <= last.y; y++) {
    if (!_validRow(rows, y)) return 0;
    final row = rows[y];
    final start = y == first.y ? first.x : 0;
    var end = y == last.y ? last.x : row.length;
    if (!verified && y == last.y && y != first.y && !_wraps(row)) {
      // A click in the unused tail of the final visual row can land at end
      // of input, but must not send extra keys (which can accept suggestions).
      var used = row.length;
      while (used > start &&
          row[used - 1].flags & _nonCharacter == 0 &&
          row[used - 1].text.trim().isEmpty) {
        used--;
      }
      end = min(end, max(used, cursor.y == y ? cursor.x : 0));
    }
    final hardEnd = y < last.y && !_wraps(row);
    if (hardEnd && !verified) return 0;
    if (verified && end > edit.ends[y - edit.start.y] && !hardEnd) return 0;
    final stop = hardEnd ? edit!.ends[y - edit.start.y] : end;
    for (var x = start; x < stop; x++) {
      if (row[x].flags & _hidden != 0) return 0;
      if (row[x].flags & _nonCharacter == 0) steps++;
    }
    if (hardEnd) steps++;
    if (steps > _maxSteps) return 0;
  }
  return direction.sign * steps;
}

/// Match a fresh, bracketed multiline paste against the visible grid. Require
/// exact echo at the old caret and an end caret at the expected position.
/// Only cell boundaries are retained after confirmation.
ConfirmedCaretEdit? confirmCaretPaste(
  List<List<RenderCell>> rows,
  Point<int> start,
  Point<int> cursor,
  String text,
) {
  if (cursor.y <= start.y ||
      cursor.y - start.y >= _maxRows ||
      !_validRow(rows, cursor.y) ||
      !_validRow(rows, start.y)) {
    return null;
  }
  final ends = <int>[];
  var offset = 0;
  for (var y = start.y; y <= cursor.y; y++) {
    if (!_validRow(rows, y)) return null;
    final row = rows[y];
    final from = y == start.y ? start.x : 0;
    if (from < 0 || from >= row.length) return null;
    var end = from;
    while (end < row.length && offset < text.length && text[offset] != '\n') {
      final cell = row[end++];
      if (cell.flags & _hidden != 0) return null;
      if (cell.flags & _nonCharacter != 0) continue;
      if (cell.text.isEmpty || !text.startsWith(cell.text, offset)) return null;
      offset += cell.text.length;
    }
    // The rendered caret is after the wide lead and its trailing cell.
    if (end < row.length && row[end].flags & _wideTail != 0) end++;
    final softEnd = _wraps(row);
    if (softEnd && end == row.length - 1 && row[end].flags & _wrapSpacer != 0) {
      end++;
    }
    ends.add(end);
    if (y == cursor.y) {
      if (end != cursor.x || offset != text.length) return null;
    } else if (softEnd) {
      if (end != row.length || offset == text.length || text[offset] == '\n') {
        return null;
      }
      continue;
    } else {
      if (offset == text.length || text[offset] != '\n') return null;
      offset++;
    }
    // Text to the right must be blank. It may otherwise be unrelated output
    // or an existing suffix whose editing boundary we do not know.
    for (var x = end; x < row.length; x++) {
      if (row[x].flags & (_hidden | _nonCharacter) != 0 ||
          row[x].text.trim().isNotEmpty) {
        return null;
      }
    }
  }
  return ConfirmedCaretEdit(
    start,
    cursor,
    ends,
    rows.sublist(start.y, cursor.y + 1),
  );
}

class ConfirmedCaretEdit {
  ConfirmedCaretEdit(this.start, this.end, this.ends, this._rows);
  final Point<int> start, end;
  final List<int> ends;
  final List<List<RenderCell>> _rows;

  bool isCurrent(List<List<RenderCell>> rows) {
    if (end.y >= rows.length) return false;
    for (var i = 0; i < _rows.length; i++) {
      if (!identical(rows[start.y + i], _rows[i])) return false;
    }
    return true;
  }

  bool contains(List<List<RenderCell>> rows, Point<int> point) =>
      point.y >= start.y &&
      point.y <= end.y &&
      (point.y != start.y || point.x >= start.x) &&
      point.x <= ends[point.y - start.y] &&
      isCurrent(rows);
}
