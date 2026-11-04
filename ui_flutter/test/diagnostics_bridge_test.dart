import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/diagnostics.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('actual SSH and rejected request produce numeric diagnostics without host, command, output or credential data', () async {
    final ssh = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    int? unused;
    try {
      await rust.createConfigurationVault(
        path: '${ssh.directory.path}/diagnostics.vault',
        password: 'synthetic-diagnostic-master',
      );
      await rust.clearDiagnostics();
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'synthetic-private-display-name',
          '127.0.0.1',
          '未分组',
          user: ssh.username,
          port: ssh.port,
          auth: '私钥',
          openSftp: false,
        ),
        secret: ssh.privateKey,
        passphrase: 'test-only-passphrase',
      );
      model.openHost(host);
      final c = (model.focus! as LiveTerminalSession).controller;
      await waitFor(
        () => c.connected || c.phase == 'Failed',
        'diagnostic original SSH',
      );
      expect(c.connected, true, reason: c.error);
      await c.setVisible(true);
      await c.text(r"printf '%s%s\n' SYNTHETIC_DIAGNOSTIC_ OUTPUT_SECRET");
      await c.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(c).contains('SYNTHETIC_DIAGNOSTIC_OUTPUT_SECRET'),
        'diagnostic output fixture',
      );
      unused = await rust.createTerminal(
        columns: 80,
        rows: 24,
        historyLines: 10,
      );
      await expectLater(
        rust.connectTerminal(
          id: unused,
          profileId: 'missing-diagnostic-fixture-host',
        ),
        throwsA(anything),
      );
      final snapshot = await rust.diagnosticSnapshot();
      expect(snapshot.capacity, 1000);
      expect(snapshot.events.length, lessThanOrEqualTo(1000));
      expect(
        snapshot.events.any(
          (e) =>
              e.terminalId == c.id && e.code == DiagnosticCode.stateConnected,
        ),
        true,
      );
      expect(
        snapshot.events.any(
          (e) =>
              e.terminalId == unused &&
              e.code == DiagnosticCode.connectionRejected,
        ),
        true,
      );
      final projection = jsonEncode([
        for (final e in snapshot.events)
          {
            'sequence': e.sequence,
            'elapsed_ms': e.elapsedMs,
            'id': e.terminalId,
            'generation': e.generation,
            'code': e.code.name,
          },
      ]);
      for (final excluded in [
        'SYNTHETIC_DIAGNOSTIC_OUTPUT_SECRET',
        'synthetic-private-display-name',
        'synthetic-diagnostic-master',
        'test-only-passphrase',
        ssh.privateKey,
        ssh.directory.path,
      ]) {
        expect(projection, isNot(contains(excluded)));
      }
      expect(c.connected, true);
      await rust.clearDiagnostics();
      expect((await rust.diagnosticSnapshot()).events, isEmpty);
    } finally {
      if (unused != null) await rust.destroyTerminal(id: unused);
      await model.shutdown();
      model.dispose();
      await ssh.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
