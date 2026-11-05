import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/controller.dart';

import 'support/fake_backend.dart';

void main() {
  test('minimized zero viewport never replaces the last valid PTY geometry or frame', () async {
    final backend = FakeBackend();
    final terminal = TerminalController(backend);
    await terminal.start();
    terminal.applyFrame(fixture(line: 'retained history'));
    final old = terminal.rows
        .map((row) => row.map((c) => c.text).join())
        .join('\n');
    terminal.resize(80, 24, 9, 20);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final first = backend.resizes;
    await terminal.setVisible(false);
    terminal.resize(0, 0, 9, 20);
    terminal.resize(-2, -1, 9, 20);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(backend.resizes, first);
    expect(
      terminal.rows.map((row) => row.map((c) => c.text).join()).join('\n'),
      old,
    );
    await terminal.setVisible(true);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
      terminal.rows.map((row) => row.map((c) => c.text).join()).join('\n'),
      old,
    );
    await terminal.shutdown();
    terminal.dispose();
  });
}
