import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';

class _ObservedBackend extends NativeTerminalBackend {
  final directories = <rust.BridgeEvent>[];
  @override
  Stream<rust.BridgeEvent> watch(int id) => super.watch(id).map((event) {
    if (event.kind == 'workingDirectory') directories.add(event);
    return event;
  });
}

void main() {
  test('hidden terminal coalesces passive directory bursts without frame pulls or idle notifications', () async {
    await initializeRust();
    final server = await LocalSshd.start();
    final backend = _ObservedBackend();
    final c = TerminalController(backend)..visible = false;
    try {
      await rust.unlockVault(
        path: '${server.directory.path}/cwd signals.vault',
        password: 'synthetic cwd signals master',
      );
      final profile = await rust.saveProfile(
        profile: rust.Profile(
          id: '',
          name: 'CWD signals',
          address: '127.0.0.1',
          port: server.port,
          username: server.username,
          privateKey: true,
        ),
        secret: server.privateKey,
        passphrase: 'test-only-passphrase',
      );
      c.confirmHostKey = (_) async => true;
      await c.start();
      await c.connect(profile.id);
      await waitFor(() => c.connected, 'hidden cwd SSH');
      await c.text(
        r'''unset PROMPT_COMMAND; PS1=''; python3 -c "import os; os.write(1, b''.join(b'\x1b]7;file://127.0.0.1/burst/' + str(i).encode() + b'\x07' for i in range(4000)))"''',
      );
      await c.key(rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0));
      await waitFor(
        () => backend.directories.any((e) => e.text == '/burst/3999'),
        'final passive directory event',
      );
      final count = backend.directories.length;
      expect(
        count,
        lessThan(100),
        reason: '4000 reports must not mean 4000 cross-language events',
      );
      expect(backend.directories.last.generation, c.generation);
      expect(backend.directories.last.detail, '127.0.0.1');
      expect(
        await rust.resolveTerminalPath(
          id: c.id!,
          generation: c.generation,
          text: 'child',
        ),
        '/burst/3999/child',
      );
      expect(c.frameCount, 0);
      expect((await backend.metrics(c.id!)).framePulls, 0);
      debugPrint(
        'OSC7 4000 reports -> $count metadata events; hidden native frame pulls: 0',
      );
      // A quiet interval is the behavior being measured, not a wait for progress.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(backend.directories.length, count);
      expect(c.frameCount, 0);
      await rust.disconnectTerminal(id: c.id!);
      await waitFor(
        () => backend.directories.last.text == null,
        'disconnect passive invalidation',
      );
      expect(backend.directories.last.generation, c.generation);
    } finally {
      await c.shutdown();
      c.dispose();
      await server.close();
    }
  }, skip: !Platform.isLinux);
}
