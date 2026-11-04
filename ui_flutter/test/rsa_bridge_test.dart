import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('real Native encrypted PKCS8 RSA credential, RSA-only host, TOFU, rekey and explicit reconnect', () async {
    final server = await LocalSshd.start(rsaKeys: true);
    final c = TerminalController(const NativeTerminalBackend());
    try {
      Future<void> fixture(String program, List<String> args) async {
        final result = await Process.run(program, args);
        expect(result.exitCode, 0, reason: 'controlled RSA fixture conversion');
      }

      final source = '${server.directory.path}/client';
      await fixture('ssh-keygen', [
        '-p',
        '-m',
        'PEM',
        '-P',
        'test-only-passphrase',
        '-N',
        '',
        '-f',
        source,
      ]);
      final encrypted = '${server.directory.path}/encrypted-rsa.pem';
      await fixture('openssl', [
        'pkcs8',
        '-topk8',
        '-v2',
        'aes-256-cbc',
        '-iter',
        '1200',
        '-passout',
        'pass:synthetic-pkcs8-passphrase',
        '-in',
        source,
        '-out',
        encrypted,
      ]);
      await rust.unlockVault(
        path: '${server.directory.path}/rsa.vault',
        password: 'synthetic-rsa-master',
      );
      final profile = await rust.saveProfile(
        profile: rust.Profile(
          id: '',
          name: 'RSA fixture',
          address: '127.0.0.1',
          port: server.port,
          username: server.username,
          privateKey: true,
        ),
        secret: await File(encrypted).readAsString(),
        passphrase: 'synthetic-pkcs8-passphrase',
      );
      var confirmations = 0;
      c.confirmHostKey = (event) async {
        confirmations++;
        expect(event.detail, endsWith('ssh-rsa'));
        return true;
      };
      await c.start();
      await c.connect(profile.id);
      await waitFor(() => c.connected, 'RSA host connects with imported PKCS8');
      expect(confirmations, 1);
      await c.text(
        "head -c 65536 /dev/zero | tr '\\0' x; printf '\\n%s%s\\n' RSA_NATIVE_ REKEY_READY",
      );
      await c.key(rust.KeyboardInput(key: 'Enter', kind: 0, modifiers: 0));
      await waitFor(
        () => screen(c).contains('RSA_NATIVE_REKEY_READY'),
        'RSA terminal output survives repeated key exchange',
      );
      expect(
        confirmations,
        1,
        reason: 'same original key does not reprompt during rekey',
      );
      final old = c.generation;
      await rust.disconnectTerminal(id: c.id!);
      await waitFor(() => !c.connected, 'explicit disconnect');
      await c.reconnect();
      await waitFor(
        () => c.connected && c.generation > old,
        'manual reconnect uses persisted RSA credential and trust',
      );
      expect(confirmations, 1);
    } finally {
      await c.shutdown();
      c.dispose();
      await server.close();
    }
  });
}
