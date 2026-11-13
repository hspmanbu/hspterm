import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/shutdown_intent.dart';

import 'support/fake_backend.dart';

void main() {
  test('only submitted plain power commands suppress reconnection', () {
    for (final command in [
      'reboot',
      'sudo reboot',
      'sudo -n /sbin/reboot',
      'shutdown -r now',
      'sudo shutdown -h now',
      'shutdown +1',
      'systemctl reboot',
      'sudo systemctl poweroff --force',
      'poweroff',
      'halt',
      'init 6',
    ]) {
      final tracker = ShutdownIntent()..text(command);
      expect(tracker.pending, false);
      tracker.enter();
      expect(tracker.pending, true, reason: command);
      tracker.reset();
      expect(tracker.pending, false);
    }
    for (final command in [
      'echo reboot',
      'reboot --help',
      'reboot -w',
      'shutdown --help',
      'shutdown -c',
      'systemctl status',
      'cat reboot.txt',
      'echo x; reboot',
      "echo 'shutdown -r now'",
      'explain reboot',
      'reboot\n',
    ]) {
      final tracker = ShutdownIntent()
        ..text(command)
        ..enter();
      expect(tracker.pending, false, reason: command);
    }
  });
  test('edits and uncertain cursor/history operations cannot produce guessed submissions', () {
    final tracker = ShutdownIntent()
      ..text('reboox')
      ..backspace()
      ..text('t')
      ..enter();
    expect(tracker.pending, true);
    tracker.text('sudo shutdown -c');
    tracker.enter();
    expect(tracker.pending, false);
    tracker.text('reb');
    tracker.invalidate();
    tracker.text('oot');
    tracker.enter();
    expect(tracker.pending, false);
    tracker.text('x' * 1000);
    tracker.enter();
    expect(tracker.pending, false);
  });
  for (final mode in ['shell', 'tmux-shell', 'tmux-tui']) {
    test(
      'disconnection policy follows original input in $mode, no real command executed',
      () async {
        final backend = FakeBackend();
        final terminal = TerminalController(backend);
        await terminal.start();
        terminal.phase = 'Connected';
        terminal.generation = 7;
        terminal.applyFrame(fixture());
        if (mode.startsWith('tmux')) {
          terminal.tmuxReadonly = false;
          terminal.reportTmuxShell('%1', mode == 'tmux-shell');
        }
        try {
          await terminal.text('sudo reboot');
          await terminal.key(
            const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
          );
          expect(backend.texts, ['sudo reboot']);
          backend.events.add(
            const rust.BridgeEvent(
              kind: 'status',
              generation: 7,
              requestId: 0,
              text: 'Disconnected',
            ),
          );
          await Future<void>.delayed(Duration.zero);
          expect(terminal.manualReconnectRequired, mode != 'tmux-tui');
          if (mode != 'tmux-tui') expect(terminal.error, contains('请手动重连'));
          final inputs = backend.texts.length;
          await terminal.connect('fixture-host');
          expect(terminal.manualReconnectRequired, false);
          expect(backend.texts.length, inputs);
          expect(backend.connects, 1);
        } finally {
          await terminal.shutdown();
          terminal.dispose();
        }
      },
    );
  }
}
