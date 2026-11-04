import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/links.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

const osc8Target =
    'https://example.invalid/actual;a;b;c;d;e;f;g;h;i;j;k;l;m;n;o;p;q;r;s;t?q=one#two';
Future<void> exerciseOsc8({
  Future<void> Function(TerminalController)? attach,
  Future<void> Function(TerminalController)? afterLinked,
  Future<void> Function()? detach,
}) async {
  await initializeRust();
  final server = await LocalSshd.start();
  final a = TerminalController(const NativeTerminalBackend()),
      b = TerminalController(const NativeTerminalBackend());
  bool hasLink(TerminalController c) =>
      c.hyperlinks.expand((r) => r).any((s) => s.uri == osc8Target);
  try {
    await rust.unlockVault(
      path: '${server.directory.path}/osc8.vault',
      password: 'synthetic-osc8-master',
    );
    final profile = await rust.saveProfile(
      profile: rust.Profile(
        id: '',
        name: 'OSC8 fixture',
        address: '127.0.0.1',
        port: server.port,
        username: server.username,
        privateKey: true,
      ),
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );
    for (final c in [a, b]) {
      c.confirmHostKey = (_) async => true;
      await c.start();
      await c.connect(profile.id);
      await waitFor(() => c.connected, 'OSC8 fixture SSH');
    }
    if (attach != null) await attach(a);
    await a.text(
      "unset PROMPT_COMMAND; PS1=''; printf '\\033[2J\\033[3J\\033[H\\033]8;id=fixture;$osc8Target\\033\\\\中é docs\\033]8;;\\033\\\\\\r\\n'",
    );
    await a.key(const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0));
    await waitFor(() => hasLink(a), 'real SSH OSC8 reaches Dart');
    expect(
      hasLink(b),
      false,
      reason: 'a separate SSH tag never inherits link metadata',
    );
    final span = a.hyperlinks[0].single;
    expect(
      TerminalLink.atGrid(
        a.rows,
        0,
        span.start,
        hyperlinks: a.hyperlinks,
      )?.text,
      osc8Target,
    );
    expect(screen(a), contains('中é docs'));
    final export = '${server.directory.path}/osc8-export.txt';
    await a.backend.exportHistory(a.id!, export);
    final text = await File(export).readAsString();
    expect(text, contains('中é docs'));
    expect(
      text,
      isNot(contains(osc8Target)),
      reason: 'actual label, never an OSC8 URI annotation',
    );
    if (afterLinked != null) await afterLinked(a);
    await a.backend.resize(a.id!, 8, 4, 9, 20);
    await waitFor(
      () => a.metadata?.columns == 8 && hasLink(a),
      'OSC8 survives real PTY shrink/reflow',
    );
    await rust.disconnectTerminal(id: a.id!);
    await waitFor(() => !a.connected, 'explicit disconnect');
    expect(
      hasLink(a),
      true,
      reason: 'retained labels remain available without reconnect',
    );
    final generation = a.generation;
    await a.reconnect();
    await waitFor(
      () => a.connected && a.generation != generation,
      'explicit new PTY',
    );
    await waitFor(
      () => !hasLink(a),
      'fresh PTY does not inherit old hyperlink template',
    );
    expect(b.connected, true);
  } finally {
    // GTK callers detach their view before its owning controller is disposed.
    if (detach != null) await detach();
    for (final c in [a, b]) {
      await c.shutdown();
      c.dispose();
    }
    await server.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real SSH OSC8 spans, unchanged export, independent sessions, resize and manual reconnect',
    exerciseOsc8,
    skip: !Platform.isLinux,
  );
}
