import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'support/local_sshd.dart';

Future<void> waitFor(
  bool Function() condition,
  String reason, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException(reason);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

String screen(TerminalController c) => c.rows
    .map(
      (r) => r
          .where((cell) => cell.flags & 64 == 0)
          .map((cell) => cell.text)
          .join(),
    )
    .join('\n');
Future<void> exerciseNative({
  Future<void> Function(TerminalController)? attach,
  Future<void> Function()? beforeCommand,
  Future<void> Function()? afterReady,
}) async {
  // Concurrent entry owners and later users share one completed FRB init.
  await Future.wait(List.generate(4, (_) => initializeRust()));
  await initializeRust();
  final server = await LocalSshd.start();
  final c = TerminalController(const NativeTerminalBackend());
  try {
    await rust.unlockVault(
      path: '${server.directory.path}/test.vault',
      password: 'test-only-vault-password',
    );
    final profile = await rust.saveProfile(
      profile: rust.Profile(
        id: '',
        name: 'Disposable loopback',
        address: '127.0.0.1',
        port: server.port,
        username: server.username,
        privateKey: true,
      ),
      secret: server.privateKey,
      passphrase: 'test-only-passphrase',
    );
    expect((await rust.listProfiles()).single.id, profile.id);
    var confirmations = 0;
    c.confirmHostKey = (_) async {
      confirmations++;
      return true;
    };
    await c.start();
    if (attach != null) await attach(c);
    await c.connect(profile.id);
    await waitFor(() => c.connected, 'SSH connect: ${c.error}');
    expect(confirmations, 1);
    Future<void> enter(String command) async {
      await c.text(command);
      if (beforeCommand != null) {
        await beforeCommand();
      } else {
        await c.key(rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0));
      }
    }

    await enter(
      "printf '\\033[31m\\033[48;2;1;2;3m中文é\\033[0m\\n%s%s\\n' BRIDGE_ READY",
    );
    try {
      await waitFor(
        () =>
            screen(c).contains('BRIDGE_READY') &&
            screen(c).contains('中文é') &&
            c.rows
                .expand((r) => r)
                .any((cell) => cell.background == 0xff010203),
        'Unicode terminal frame',
      );
    } catch (_) {
      throw StateError(
        'fixture frame=${screen(c)} phase=${c.phase} frames=${c.frameCount} error=${c.error}',
      );
    }
    expect(
      c.rows.expand((r) => r).any((cell) => cell.background == 0xff010203),
      true,
    );
    if (afterReady != null) await afterReady();
    await c.backend.resize(c.id!, 101, 33, 9, 21);
    await enter('stty size');
    await waitFor(() => screen(c).contains('33 101'), 'PTY size sync');
    await enter('vim -Nu NONE -n');
    await waitFor(
      () => c.metadata?.alternateScreen == true,
      'Vim alternate screen',
    );
    await c.key(rust.KeyboardInput(key: 'i', text: 'i', modifiers: 0, kind: 0));
    await c.text('中文é');
    await c.key(rust.KeyboardInput(key: 'Escape', modifiers: 0, kind: 0));
    await enter(':q!');
    await waitFor(
      () => c.metadata?.alternateScreen == false,
      'Vim leave alternate screen',
    );
    final socket = '${server.directory.path}/tmux';
    await enter("tmux -S '$socket' -f /dev/null new-session");
    await waitFor(() => c.metadata?.alternateScreen == true, 'tmux entry');
    await enter('exit');
    await waitFor(() => c.metadata?.alternateScreen == false, 'tmux exit');
    await enter('htop');
    await waitFor(() => c.metadata?.alternateScreen == true, 'htop entry');
    await c.text('q');
    await waitFor(() => c.metadata?.alternateScreen == false, 'htop exit');
    await c.setVisible(false);
    final hiddenFrames = c.frameCount;
    await enter("seq 1 10000; printf '%s%s\\n' LOAD_ DONE");
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(c.frameCount, hiddenFrames);
    await c.setVisible(true);
    await waitFor(
      () =>
          screen(c).contains('LOAD_DONE') &&
          screen(c).contains('10000') &&
          c.metadata!.historyLines + c.metadata!.rows >= 10000,
      'high output while hidden',
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final idleFrames = c.frameCount;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(c.frameCount, idleFrames);
    final metrics = await c.backend.metrics(c.id!);
    expect(metrics.diskBytes, greaterThan(0));
    expect(
      metrics.residentHistoryCells,
      lessThanOrEqualTo((256 + c.metadata!.rows) * c.metadata!.columns),
    );
    await c.setSearch('9999');
    await c.runSearch();
    expect(c.searchSummary?.count, 1);
    expect(c.activeSearch, isNotNull);
    expect(c.searchSummary!.markers.fold(0, (a, b) => a + b), 1);
    await waitFor(
      () => c.metadata!.searchSpans.isNotEmpty,
      'search highlight frame',
    );
    await c.setSearch('^99[0-9]{2}%%', regex: true);
    await c.runSearch();
    expect(c.searchSummary?.count, 0);
    await c.setSearch('[', regex: true);
    await c.runSearch();
    expect(c.searchError, isNotNull);
    await c.setSearch('');
    final exported = File('${server.directory.path}/history.txt');
    await c.backend.exportHistory(c.id!, exported.path);
    final exportedText = await exported.readAsString();
    expect(exportedText, contains('中文é'));
    expect(exportedText, contains('9999\n10000'));
    expect(exportedText, isNot(contains('重新连接')));
    await expectLater(
      c.backend.exportHistory(c.id!, exported.path),
      throwsA(anything),
    );
    expect(await exported.readAsString(), exportedText);
    await c.lockSize(true);
    await waitFor(() => c.metadata!.sizeLocked, 'locked PTY frame');
    final columns = c.metadata!.columns, lines = c.metadata!.rows;
    await c.backend.resize(c.id!, 50, 12, 9, 21);
    expect(c.metadata!.columns, columns);
    await c.seek(c.metadata!.historyLines);
    await enter('stty size');
    await waitFor(
      () => screen(c).contains('$lines $columns'),
      'locked remote PTY',
    );
    await c.lockSize(false);
    await c.backend.resize(c.id!, 90, 27, 9, 21);
    await enter('stty size');
    await waitFor(() => screen(c).contains('27 90'), 'unlocked PTY resize');
    await enter('exit');
    await waitFor(() => c.phase == 'Disconnected', 'shell exit');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final retained = screen(c);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(screen(c), retained);
    await c.key(rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0));
    await waitFor(
      () => c.connected && c.reconnectCount == 1,
      'manual reconnect',
    );
    expect(confirmations, 1);
    await enter("printf '%s%s\\n' RECONNECTED_ OK");
    await waitFor(
      () => screen(c).contains('RECONNECTED_OK'),
      'reconnected frame',
    );
    final bytes = await File('${server.directory.path}/test.vault')
        .readAsBytes();
    expect(String.fromCharCodes(bytes).contains(server.privateKey), false);
    await c.shutdown();
    final rss = ProcessInfo.currentRss;
    for (var i = 0; i < 20; i++) {
      final next = TerminalController(const NativeTerminalBackend());
      await next.start();
      await waitFor(() => next.metadata != null, 'lifecycle initial frame');
      await next.shutdown();
      next.dispose();
    }
    final growth = ProcessInfo.currentRss - rss;
    // A generous debug-runtime bound detects retained native sessions, not allocator noise.
    expect(growth, lessThan(64 * 1024 * 1024));
    // Aggregate synthetic-test metrics only, never terminal or credential diagnostics.
    debugPrint('20 native lifecycle cycles: RSS delta=$growth bytes');
  } finally {
    await c.shutdown();
    c.dispose();
    await server.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real FRB + encrypted vault + OpenSSH, Unicode, resize, TUI, idle and reconnect',
    exerciseNative,
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isLinux
        ? "Controlled Linux OpenSSH fixture required"
        : false,
  );
}
