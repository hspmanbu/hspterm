import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'editor_bridge_test.dart' show profile, connect;
import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';

void main() {
  setUpAll(() async {
    if (Platform.isLinux) await initializeRust();
  });
  test(
    'real SSH recursive search stays independent of directory cursors, sessions and reconnect generations',
    () async {
      final server = await LocalSshd.start();
      final first = TerminalController(const NativeTerminalBackend());
      final second = TerminalController(const NativeTerminalBackend());
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/search.vault',
          password: 'test-only-search-master',
        );
        final host = await profile(server);
        await connect(first, host.id);
        await connect(second, host.id);
        final id = first.id!, generation = first.generation;
        final root = Directory('${server.directory.path}/search 中文');
        final child = Directory('${root.path}/sub 深层');
        final outside = Directory('${server.directory.path}/outside');
        await child.create(recursive: true);
        await outside.create();
        for (var i = 0; i < 300; i++) {
          await File('${root.path}/Needle 中文 $i.txt')
              .writeAsString('not read by search');
        }
        await File('${child.path}/needle child.txt')
            .writeAsString('not read by search');
        await File('${outside.path}/needle outside.txt')
            .writeAsString('must not scan');
        await Link('${root.path}/loop').create(root.path);
        await Link('${root.path}/outside-link').create(outside.path);
        await rust.sftpOpenDirectory(
          id: id,
          generation: generation,
          request: 1,
          path: root.path,
        );
        final canonical = await rust.sftpOpenFileSearch(
          id: id,
          generation: generation,
          request: 1,
          path: root.path,
          query: 'needle',
          caseSensitive: false,
        );
        expect(canonical, root.path);
        final files = <rust.RemoteFile>[];
        var scanned = 0;
        while (true) {
          final page = await rust.sftpFileSearchPage(
            id: id,
            generation: generation,
            request: 1,
            limit: 128,
          );
          expect(page.files.length, lessThanOrEqualTo(128));
          expect(page.scanned, greaterThanOrEqualTo(scanned));
          scanned = page.scanned;
          files.addAll(page.files);
          if (page.done) break;
        }
        expect(files.length, 301);
        expect(scanned, 304);
        expect(files.every((f) => f.path.startsWith('${root.path}/')), true);
        // Search EOF must not close the sidebar's independently opened cursor.
        final listing = await rust.sftpDirectoryPage(
          id: id,
          generation: generation,
          request: 1,
          limit: 256,
        );
        expect(listing.files, isNotEmpty);
        await rust.sftpCloseDirectory(
          id: id,
          generation: generation,
          request: 1,
        );
        await expectLater(
          rust.sftpFileSearchPage(
            id: second.id!,
            generation: second.generation,
            request: 1,
            limit: 10,
          ),
          throwsA(anything),
        );
        await rust.sftpOpenFileSearch(
          id: id,
          generation: generation,
          request: 2,
          path: root.path,
          query: 'Needle',
          caseSensitive: true,
        );
        await rust.sftpCloseFileSearch(
          id: id,
          generation: generation,
          request: 1,
        );
        final exact = await rust.sftpFileSearchPage(
          id: id,
          generation: generation,
          request: 2,
          limit: 256,
        );
        expect(exact.files.length, 256);
        await rust.sftpOpenFileSearch(
          id: id,
          generation: generation,
          request: 3,
          path: root.path,
          query: 'absent',
          caseSensitive: false,
        );
        await expectLater(
          rust.sftpFileSearchPage(
            id: id,
            generation: generation,
            request: 2,
            limit: 10,
          ),
          throwsA(anything),
        );
        await rust.sftpCloseFileSearch(
          id: id,
          generation: generation,
          request: 2,
        );
        final absent = await rust.sftpFileSearchPage(
          id: id,
          generation: generation,
          request: 3,
          limit: 256,
        );
        expect(absent.files, isEmpty);
        expect(absent.done, true);
        await rust.sftpOpenFileSearch(
          id: id,
          generation: generation,
          request: 4,
          path: root.path,
          query: 'needle',
          caseSensitive: false,
        );
        await rust.disconnectTerminal(id: id);
        await waitFor(() => first.phase == 'Disconnected', 'search disconnect');
        await expectLater(
          rust.sftpFileSearchPage(
            id: id,
            generation: generation,
            request: 4,
            limit: 10,
          ),
          throwsA(anything),
        );
        expect(first.generation, generation);
        await first.reconnect();
        await waitFor(
          () => first.connected && first.generation > generation,
          'explicit search reconnect',
        );
        await rust.sftpOpenFileSearch(
          id: id,
          generation: first.generation,
          request: 1,
          path: root.path,
          query: 'needle child',
          caseSensitive: false,
        );
        await rust.sftpCloseFileSearch(
          id: id,
          generation: generation,
          request: 4,
        );
        final after = await rust.sftpFileSearchPage(
          id: id,
          generation: first.generation,
          request: 1,
          limit: 256,
        );
        expect(after.files.single.path, '${child.path}/needle child.txt');
        expect(after.done, true);
        expect(second.connected, true);
      } finally {
        await second.shutdown();
        second.dispose();
        await first.shutdown();
        first.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
