import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

Future<List<Map<String, dynamic>>> ranges(
  TerminalController c, {
  required bool nonempty,
  String stage = 'initial output',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    final frame = c.metadata;
    if (frame != null) {
      try {
        final rows = (jsonDecode(
          await rust.terminalCommandRanges(
            id: c.id!,
            generation: c.generation,
            revision: frame.contentRevision,
          ),
        ) as List).cast<Map<String, dynamic>>();
        if (!nonempty || rows.isNotEmpty) return rows;
      } catch (failure) {
        // Retry only the documented frame race. A binding/build, I/O or
        // protocol error must fail this fixture instead of being hidden.
        if (!failure.toString().contains('终端画面已更新')) rethrow;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError(
    'command boundary metadata did not reach the expected frame: $stage',
  );
}

Future<void> exerciseCommandRanges({
  Future<void> Function(TerminalController)? attach,
  Future<void> Function()? detach,
}) async {
  await initializeRust();
  final server = await LocalSshd.start();
  final c = TerminalController(const NativeTerminalBackend());
  try {
    await rust.unlockVault(
      path: '${server.directory.path}/command-ranges.vault',
      password: 'synthetic-range-master',
    );
    final host = await rust.saveProfile(
      profile: rust.Profile(
        id: '',
        name: 'Command range fixture',
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
    if (attach != null) await attach(c);
    await c.connect(host.id);
    await waitFor(() => c.connected, 'range fixture SSH');
    // Keep the fixture quiescent while proving local reflow. Interactive
    // Readline can repaint previous rows on WINCH, which must invalidate an
    // overwritten OSC range (covered independently by real SSH tests).
    await c.text(
      "printf '\\033]133;A\\007SYNTHETIC> \\033]133;B\\007fixture\\r\\n\\033]133;C\\007%s%s\\r\\n\\033]133;D;7\\007' RANGE_ 'READY中文é'; IFS= read -r hspterm_fixture_resume; exit\n",
    );
    await waitFor(
      () => screen(c).contains('RANGE_READY中文é'),
      'command output frame',
    );
    final rows = await ranges(c, nonempty: true);
    final range = rows.singleWhere((r) => r['exit_status'] == 7);
    final pointRow = range['start_row'] as int,
        pointColumn = range['start_column'] as int;
    final copied = await c.copyCommandAt(
      pointRow,
      pointColumn,
      c.metadata!.contentRevision,
    );
    expect(copied, 'RANGE_READY中文é\n');
    expect(range['exit_status'], 7);
    expect(copied, isNot(contains('SYNTHETIC')));
    if (attach == null) {
      final originalGeneration = c.generation;
      for (final columns in [23, 65, 17]) {
        c.resize(columns, 24, 8, 16);
        await waitFor(
          () => c.metadata?.columns == columns,
          'range reflow frame',
        );
        final remapped = (await ranges(
          c,
          nonempty: true,
          stage: 'reflow $columns',
        )).singleWhere((r) => r['id'] == range['id']);
        expect(
          await c.copyCommandAt(
            remapped['start_row'] as int,
            remapped['start_column'] as int,
            c.metadata!.contentRevision,
          ),
          copied,
        );
        expect(c.generation, originalGeneration);
      }
    }
    await c.text('exit\n');
    await waitFor(() => c.phase == 'Disconnected', 'range fixture disconnect');
    final retained = await ranges(
      c,
      nonempty: true,
      stage: 'disconnected history',
    );
    expect(
      await c.copyCommandAt(
        retained.singleWhere((r) => r['exit_status'] == 7)['start_row'] as int,
        retained.singleWhere((r) => r['exit_status'] == 7)['start_column']
            as int,
        c.metadata!.contentRevision,
      ),
      copied,
    );
    await c.connect(host.id);
    await waitFor(() => c.connected, 'range manual reconnect');
    await waitFor(() => c.metadata != null, 'range reconnect frame');
    expect(await ranges(c, nonempty: false), isEmpty);
  } finally {
    if (detach != null) await detach();
    await c.shutdown();
    c.dispose();
    await server.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real OpenSSH command bounds, original Unicode text, disconnect preservation and manual reconnect invalidation',
    exerciseCommandRanges,
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
