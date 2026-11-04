import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart';
import 'package:hspterm/terminal/same_word.dart';

RenderCell c(String text, {int flags = 0}) => RenderCell(
  text: text,
  foreground: 0xffeeeeee,
  background: 0xff10151d,
  flags: flags,
);
List<RenderCell> row(String text) =>
    text.runes.map((r) => c(String.fromCharCode(r))).toList();
void main() {
  test('only whole exact words and visible matches; original selection is excluded', () {
    final rows = [row('hello HELLO hello helloworld'), row('hello')];
    final exact = sameWordMatches(
      rows,
      const Point(0, 0),
      const Point(4, 0),
      caseSensitive: true,
    );
    expect(exact, [(row: 0, start: 12, end: 17), (row: 1, start: 0, end: 5)]);
    expect(
      sameWordMatches(
        rows,
        const Point(0, 0),
        const Point(4, 0),
        caseSensitive: false,
      ).length,
      3,
    );
    expect(
      sameWordMatches(
        rows,
        const Point(1, 0),
        const Point(4, 0),
        caseSensitive: true,
      ),
      isEmpty,
    );
    expect(
      sameWordMatches(
        rows,
        const Point(0, 0),
        const Point(4, 1),
        caseSensitive: true,
      ),
      isEmpty,
    );
  });
  test('Unicode wide cells, combining glyphs and hidden text retain physical mapping', () {
    final rows = [
      [
        c('中', flags: 32),
        c('', flags: 64),
        c('文', flags: 32),
        c('', flags: 64),
        c(' '),
        c('中', flags: 32),
        c('', flags: 64),
        c('文', flags: 32),
        c('', flags: 64),
      ],
      [
        c('中', flags: 32 | 1024),
        c('', flags: 64),
        c('文', flags: 32 | 1024),
        c('', flags: 64),
      ],
      [c('é'), c('x'), c(' '), c('é'), c('x')],
    ];
    expect(
      sameWordMatches(
        rows,
        const Point(0, 0),
        const Point(3, 0),
        caseSensitive: true,
      ),
      [(row: 0, start: 5, end: 9)],
    );
    expect(
      sameWordMatches(
        rows,
        const Point(0, 1),
        const Point(3, 1),
        caseSensitive: true,
      ),
      isEmpty,
    );
    expect(
      sameWordMatches(
        rows,
        const Point(0, 2),
        const Point(1, 2),
        caseSensitive: true,
      ),
      [(row: 2, start: 3, end: 5)],
    );
  });
}
