import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';

// Source-only until the unified FRB generation/build/test stage. No test reads
// an existing account, server config or credentials outside this private root.
void main() {
  test(
    'old SFTP mutation generations cannot act after manual reconnect',
    () async {
      await initializeRust();
      final server = await LocalSshd.start();
      final c = TerminalController(const NativeTerminalBackend());
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/metadata.vault',
          password: 'test-only-metadata-master',
        );
        final host = await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'metadata generation fixture',
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
        await c.connect(host.id);
        await waitFor(() => c.connected, 'private metadata SSH');
        final original = c.generation, id = c.id!;
        final source = File('${server.directory.path}/payload.txt');
        final target = File('${server.directory.path}/renamed.txt');
        final folder = Directory('${server.directory.path}/new folder');
        await source.writeAsString('synthetic metadata body');
        // Populate the actual metadata channel cache on the original Root.
        await rust.sftpListDirectory(id: id, path: server.directory.path);
        await rust.disconnectTerminal(id: id);
        await waitFor(() => !c.connected, 'metadata SSH disconnect');
        await c.reconnect();
        await waitFor(
          () => c.connected && c.generation > original,
          'manual metadata reconnect',
        );
        await expectLater(
          rust.sftpCreateDirectory(
            id: id,
            path: folder.path,
            expectedGeneration: original,
          ),
          throwsA(anything),
        );
        await expectLater(
          rust.sftpRename(
            id: id,
            source: source.path,
            destination: target.path,
            expectedGeneration: original,
          ),
          throwsA(anything),
        );
        await expectLater(
          rust.sftpRemove(
            id: id,
            path: source.path,
            recursive: false,
            expectedGeneration: original,
          ),
          throwsA(anything),
        );
        expect(await folder.exists(), false);
        expect(await target.exists(), false);
        expect(await source.readAsString(), 'synthetic metadata body');
        // A new explicit action on the current generation still works; failed
        // stale attempts neither poison the cache nor create another SSH Root.
        await rust.sftpCreateDirectory(
          id: id,
          path: folder.path,
          expectedGeneration: c.generation,
        );
        await rust.sftpRename(
          id: id,
          source: source.path,
          destination: target.path,
          expectedGeneration: c.generation,
        );
        await rust.sftpRemove(
          id: id,
          path: target.path,
          recursive: false,
          expectedGeneration: c.generation,
        );
        expect(await folder.exists(), true);
        expect(await source.exists(), false);
        expect(await target.exists(), false);
        expect(c.id, id);
        expect(c.connected, true);
      } finally {
        await c.shutdown();
        c.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
