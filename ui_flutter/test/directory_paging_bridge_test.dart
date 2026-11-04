import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  test(
    'real paged SSH directory cursors are bounded, replaceable and generation scoped',
    () async {
      await initializeRust();
      final server = await LocalSshd.start();
      final c = TerminalController(const NativeTerminalBackend());
      final other = TerminalController(const NativeTerminalBackend());
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/directory.vault',
          password: 'test-only-directory-master',
        );
        final profile = await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Directory fixture',
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            privateKey: true,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        for (final controller in [c, other]) {
          controller.confirmHostKey = (_) async => true;
          await controller.start();
          await controller.connect(profile.id);
        }
        await waitFor(
          () => c.connected && other.connected,
          'directory transports',
        );
        final generation = c.generation;
        final directory = Directory('${server.directory.path}/large');
        await directory.create();
        for (var base = 0; base < 4096; base += 32) {
          await Future.wait(
            List.generate(
              32,
              (i) =>
                  File('${directory.path}/item-${base + i}')
                      .writeAsString('synthetic'),
            ),
          );
        }
        await File('${directory.path}/中文 é').writeAsString('中文');
        var request = 1;
        final canonical = await rust.sftpOpenDirectory(
          id: c.id!,
          generation: generation,
          request: request,
          path: directory.path,
        );
        expect(canonical, directory.path);
        await expectLater(
          rust.sftpDirectoryPage(
            id: c.id!,
            generation: generation,
            request: request,
            limit: 257,
          ),
          throwsA(anything),
        );
        final names = <String>{};
        var pages = 0, done = false;
        while (!done) {
          final page = await rust.sftpDirectoryPage(
            id: c.id!,
            generation: generation,
            request: request,
            limit: 113,
          );
          expect(page.files.length, lessThanOrEqualTo(113));
          expect(
            page.files.fold<int>(
              0,
              (n, f) =>
                  n +
                  utf8.encode(f.name).length +
                  utf8.encode(f.path).length +
                  128,
            ),
            lessThanOrEqualTo(262144),
          );
          for (final file in page.files) {
            expect(file.path, '${directory.path}/${file.name}');
            expect(names.add(file.name), true);
          }
          pages++;
          done = page.done;
        }
        expect(pages, greaterThan(30));
        expect(names, hasLength(4097));
        expect(names, contains('中文 é'));
        await rust.sftpCloseDirectory(
          id: c.id!,
          generation: generation,
          request: request,
        );
        await expectLater(
          rust.sftpDirectoryPage(
            id: c.id!,
            generation: generation,
            request: request,
            limit: 10,
          ),
          throwsA(anything),
        );
        // A new request closes an idle cursor. Late cleanup of the old request
        // cannot affect its replacement, or another SSH session's equal request ID.
        await rust.sftpOpenDirectory(
          id: c.id!,
          generation: generation,
          request: ++request,
          path: directory.path,
        );
        final old = request;
        await rust.sftpOpenDirectory(
          id: c.id!,
          generation: generation,
          request: ++request,
          path: directory.path,
        );
        await rust.sftpOpenDirectory(
          id: other.id!,
          generation: other.generation,
          request: request,
          path: directory.path,
        );
        await rust.sftpCloseDirectory(
          id: c.id!,
          generation: generation,
          request: old,
        );
        expect(
          (await rust.sftpDirectoryPage(
            id: c.id!,
            generation: generation,
            request: request,
            limit: 3,
          )).files,
          hasLength(3),
        );
        expect(
          (await rust.sftpDirectoryPage(
            id: other.id!,
            generation: other.generation,
            request: request,
            limit: 2,
          )).files,
          hasLength(2),
        );
        await expectLater(
          rust.sftpOpenDirectory(
            id: c.id!,
            generation: generation,
            request: old,
            path: directory.path,
          ),
          throwsA(anything),
        );
        await rust.sftpCloseDirectory(
          id: other.id!,
          generation: other.generation,
          request: request,
        );
        // More than the server's usual channel limit: stale listings must release
        // channels instead of accumulating one server process/handle per refresh.
        for (var i = 0; i < 24; i++) {
          await rust.sftpOpenDirectory(
            id: c.id!,
            generation: generation,
            request: ++request,
            path: directory.path,
          );
          expect(
            (await rust.sftpDirectoryPage(
              id: c.id!,
              generation: generation,
              request: request,
              limit: 1,
            )).files,
            hasLength(1),
          );
          if (i.isEven) {
            await rust.sftpCloseDirectory(
              id: c.id!,
              generation: generation,
              request: request,
            );
          }
        }
        // Supersede requests while channel negotiation may still be pending.
        // Only the replacement may be used; old cleanup must remain harmless.
        for (var i = 0; i < 8; i++) {
          final oldRequest = ++request;
          final early = rust
              .sftpOpenDirectory(
                id: c.id!,
                generation: generation,
                request: oldRequest,
                path: directory.path,
              )
              .then<bool>((_) => true, onError: (Object _) => false);
          final nextRequest = ++request;
          final latest = rust.sftpOpenDirectory(
            id: c.id!,
            generation: generation,
            request: nextRequest,
            path: directory.path,
          );
          await latest;
          await early;
          await rust.sftpCloseDirectory(
            id: c.id!,
            generation: generation,
            request: oldRequest,
          );
          expect(
            (await rust.sftpDirectoryPage(
              id: c.id!,
              generation: generation,
              request: nextRequest,
              limit: 1,
            )).files,
            hasLength(1),
          );
        }
        await c.text("printf '%s%s\\n' PAGED_ PTY\n");
        await waitFor(
          () => screen(c).contains('PAGED_PTY'),
          'PTY while directory cursor open',
        );
        expect(c.generation, generation);
        await c.text('exit\n');
        await waitFor(
          () => !c.connected,
          'remote PTY exit releases directory cursor',
        );
        expect(c.generation, generation);
        await expectLater(
          rust.sftpDirectoryPage(
            id: c.id!,
            generation: generation,
            request: request,
            limit: 1,
          ),
          throwsA(anything),
        );
        await c.connect(profile.id);
        await waitFor(
          () => c.connected && c.generation > generation,
          'directory manual reconnect',
        );
        await rust.sftpOpenDirectory(
          id: c.id!,
          generation: c.generation,
          request: 1,
          path: directory.path,
        );
        await rust.sftpCloseDirectory(
          id: c.id!,
          generation: generation,
          request: request,
        );
        expect(
          (await rust.sftpDirectoryPage(
            id: c.id!,
            generation: c.generation,
            request: 1,
            limit: 1,
          )).files,
          hasLength(1),
        );
        final nativeId = c.id!;
        await c.shutdown();
        await rust.sftpCloseDirectory(
          id: nativeId,
          generation: c.generation,
          request: 1,
        );
      } finally {
        await c.shutdown();
        c.dispose();
        await other.shutdown();
        other.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !Platform.isLinux,
  );
}
