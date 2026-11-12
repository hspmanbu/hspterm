import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/links.dart';
import 'package:hspterm/src/rust/api.dart';

void main() {
  test('OSC8 annotations resolve only the matching literal path token', () {
    final cells = 'APK: /opt/carsum/demo.apk'
        .split('')
        .map(
          (text) => RenderCell(
            text: text,
            foreground: 0xffffffff,
            background: 0xff000000,
            flags: 0,
          ),
        )
        .toList();
    final spans = [
      [
        RenderHyperlink(
          start: 0,
          end: cells.length,
          uri: 'APK: /opt/carsum/demo.apk',
        ),
      ],
    ];
    expect(TerminalLink.atGrid([cells], 0, 1, hyperlinks: spans), isNull);
    expect(
      TerminalLink.atGrid([cells], 0, 10, hyperlinks: spans)?.remotePath?.path,
      '/opt/carsum/demo.apk',
    );
    expect(
      TerminalLink.atGrid(
        [cells],
        0,
        10,
        hyperlinks: [
          [
            RenderHyperlink(
              start: 0,
              end: cells.length,
              uri: 'javascript:/opt/carsum/demo.apk',
            ),
          ],
        ],
      ),
      isNull,
    );
    expect(
      TerminalLink.atGrid(
        [cells],
        0,
        10,
        hyperlinks: [
          [
            RenderHyperlink(
              start: 0,
              end: cells.length,
              uri: 'APK: /tmp/other.apk',
            ),
          ],
        ],
      ),
      isNull,
    );
  });
  test(
    'early wide-character wraps and whitespace boundaries keep link identity',
    () {
      List<RenderCell> row(String text) => text
          .split('')
          .map(
            (c) => RenderCell(
              text: c,
              foreground: 0xffffffff,
              background: 0xff000000,
              flags: 0,
            ),
          )
          .toList();
      final first = row('https://example.invalid/');
      first[first.length - 1] = RenderCell(
        text: '/',
        foreground: 0xffffffff,
        background: 0xff000000,
        flags: 16,
      );
      first.add(
        const RenderCell(
          text: '',
          foreground: 0xffffffff,
          background: 0xff000000,
          flags: 1024,
        ),
      );
      final second = row('path?q=1 other text');
      expect(
        TerminalLink.atGrid([first, second], 1, 2)?.text,
        'https://example.invalid/path?q=1',
      );
      expect(TerminalLink.atGrid([first, second], 1, 12), isNull);
      expect(
        TerminalLink.atGrid(
          [row('https://example.invalid/'), second],
          0,
          2,
        )?.text,
        'https://example.invalid/',
      );
    },
  );
  test('recognition is pure and distinguishes URLs, bare addresses and explicit ports', () {
    final http = TerminalLink.parse('http://localhost:8080/path?q=one#two')!;
    expect(http.loopback, true);
    expect(http.canForward, true);
    expect(http.port, 8080);
    expect(http.uri!.query, 'q=one');
    expect(TerminalLink.parse('https://example.invalid/path')!.port, 443);
    expect(TerminalLink.parse('127.0.0.4:5678')!.canForward, true);
    expect(TerminalLink.parse('[::1]:42')!.address, '::1');
    expect(TerminalLink.parse('::1')!.port, isNull);
    expect(TerminalLink.parse('192.0.2.1')!.loopback, false);
    expect(TerminalLink.parse('internal-host:2222')!.uri, isNull);
    for (final invalid in [
      'javascript:alert(1)',
      'file://user@host/tmp/a',
      'data:text/html,x',
      'https://user:password@example.invalid/',
      'http://localhost:0',
      'localhost:65536',
      'localhost:abc',
      'http://localhost:99999999999999999999',
      'http://host/\nhello',
      'https://example.invalid/\u202eevil',
      'https://example.invalid/\u0085bad',
      'https://example.invalid/\u061cbad',
      'http://[broken',
      'word',
    ]) {
      expect(TerminalLink.parse(invalid), isNull, reason: invalid);
    }
  });
  test(
    'remote file links have no browser URI, port or forwarding capability',
    () {
      for (final target in [
        'file:///tmp/a%20b;tail.',
        'FILE://127.0.0.1/tmp/%2520',
        'file:///C:/fixture',
      ]) {
        final link = TerminalLink.parse(target)!;
        expect(link.text, target);
        expect(link.remoteFileUri, target);
        expect(link.uri, isNull);
        expect(link.port, isNull);
        expect(link.canForward, false);
        expect(link.address, isEmpty);
      }
      for (final bad in [
        'file://host:22/a',
        'file:///a#fragment',
        'file:///a?query',
        'file:relative',
        'file://user:pass@host/a',
      ]) {
        expect(TerminalLink.parse(bad), isNull);
      }
      final row = [
        for (final ch in 'file:///tmp/a;tail.'.split(''))
          RenderCell(text: ch, foreground: 0, background: 0, flags: 0),
      ];
      expect(TerminalLink.at(row, 1)?.remoteFileUri, 'file:///tmp/a;tail.');
      List<RenderCell> cells(String s) => [
        for (final ch in s.split(''))
          RenderCell(text: ch, foreground: 0, background: 0, flags: 0),
      ];
      expect(
        TerminalLink.at(cells('file:///tmp/a)'), 1)?.remoteFileUri,
        'file:///tmp/a)',
      );
      expect(TerminalLink.at(cells("file:///tmp/a'b"), 1), isNull);
      expect(TerminalLink.at(cells('"file:///tmp/a"'), 2), isNull);
    },
  );
  test(
    'visible-cell mapping preserves wide and combining character columns',
    () {
      RenderCell cell(String text, [int flags = 0]) => RenderCell(
        text: text,
        foreground: 0xffffff,
        background: 0,
        flags: flags,
      );
      final row = [
        cell('中', 32),
        cell('', 64),
        cell('e\u0301'),
        cell(' '),
        for (final c in 'http://localhost:3210/a'.split('')) cell(c),
        cell(' '),
      ];
      expect(TerminalLink.at(row, 5)?.port, 3210);
      expect(TerminalLink.at(row, 0), isNull);
      expect(TerminalLink.at(row, row.length - 1), isNull);
      expect(TerminalLink.at(row, -1), isNull);
      final prose = [
        for (final c in '(https://example.invalid/a).'.split('')) cell(c),
      ];
      expect(TerminalLink.at(prose, 5)?.text, 'https://example.invalid/a');
      final wrapped = [
        [for (final c in 'http://localhos'.split('')) cell(c), cell('t', 16)],
        [for (final c in ':8080/path '.split('')) cell(c)],
      ];
      expect(
        TerminalLink.atGrid(wrapped, 1, 3)?.text,
        'http://localhost:8080/path',
      );
      expect(
        TerminalLink.atGrid([wrapped.first], 0, 4),
        isNull,
        reason: 'do not activate a truncated visible wrapped URL',
      );
      expect(
        TerminalLink.at([
          for (final c in 'http://localhost:8080'.split('')) cell(c, 256),
        ], 4),
        isNull,
        reason: 'concealed text must not appear through a tooltip',
      );
    },
  );
  test('remote path locations preserve literal alternatives and never become browser or forwarding targets', () {
    for (final (text, path, line, column) in <(String, String, int?, int?)>[
      ('/tmp/中文.rs:12:3', '/tmp/中文.rs', 12, 3),
      ('src/main.rs:42:5:', 'src/main.rs', 42, 5),
      ('./README.md:12', './README.md', 12, null),
      ('../logs/output.log', '../logs/output.log', null, null),
      ('main.rs:12', 'main.rs', 12, null),
      ('/tmp/name;tail.', '/tmp/name;tail.', null, null),
    ]) {
      final link = TerminalLink.parse(text)!;
      expect(link.remotePath!.text, text);
      expect(link.remotePath!.path, path);
      expect(link.remotePath!.line, line);
      expect(link.remotePath!.column, column);
      expect(link.uri, isNull);
      expect(link.remoteFileUri, isNull);
      expect(link.canForward, false);
    }
    for (final bad in [
      r'C:\Users\fixture.rs:12',
      '/tmp/a:0',
      '/tmp/a:9999999999',
      r'$HOME/a',
      '~/a',
      '/tmp/\u202ename',
      'user@host:/tmp/a',
      'src/a.rs:12\n',
      'src/a.rs:12\u0085',
      '//other/path',
      'javascript:alert(1)',
    ]) {
      expect(TerminalLink.parse(bad)?.remotePath, isNull, reason: bad);
    }
  });

  test(
    'path cell recognition keeps punctuation, wide columns and OSC8 ownership',
    () {
      List<RenderCell> cells(String value) => [
        for (final ch in value.split(''))
          RenderCell(text: ch, foreground: 0, background: 0, flags: 0),
      ];
      final rows = [
        [
          RenderCell(text: '中', foreground: 0, background: 0, flags: 32),
          RenderCell(text: '', foreground: 0, background: 0, flags: 64),
          ...cells(' src/main.'),
          RenderCell(text: 'r', foreground: 0, background: 0, flags: 16),
        ],
        cells('s:12:3: error'),
      ];
      expect(TerminalLink.atGrid(rows, 1, 1)!.remotePath!.path, 'src/main.rs');
      expect(TerminalLink.at(cells('"/tmp/a b.rs"'), 2), isNull);
      expect(TerminalLink.at(cells('(/tmp/a.rs:12)'), 3), isNull);
      final row = cells('https://example.invalid/');
      expect(
        TerminalLink.atGrid(
          [row],
          0,
          2,
          hyperlinks: [
            [
              RenderHyperlink(
                start: 0,
                end: row.length,
                uri: '/tmp/not-an-OSC8-URI.rs:12',
              ),
            ],
          ],
        ),
        isNull,
      );
    },
  );
}
