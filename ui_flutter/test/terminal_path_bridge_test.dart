import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/directory_reader.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  test('literal terminal paths locate only their original SSH/SFTP session', () async {
    await initializeRust();
    final server = await LocalSshd.start();
    var holdPage = false;
    final pageStarted = Completer<void>(), releasePage = Completer<void>();
    final m = LiveWorkbenchModel(
      directoryReader: PagedDirectoryReader(
        page:
            ({
              required id,
              required generation,
              required request,
              required limit,
            }) async {
              if (holdPage) {
                holdPage = false;
                pageStarted.complete();
                await releasePage.future;
              }
              return rust.sftpDirectoryPage(
                id: id,
                generation: generation,
                request: request,
                limit: limit,
              );
            },
      ),
    );
    try {
      await rust.unlockVault(
        path: '${server.directory.path}/paths.vault',
        password: 'synthetic paths master',
      );
      await rust.saveProfile(
        profile: rust.Profile(
          id: '',
          name: 'Paths fixture',
          address: '127.0.0.1',
          port: server.port,
          username: server.username,
          privateKey: true,
        ),
        secret: server.privateKey,
        passphrase: 'test-only-passphrase',
      );
      await m.load();
      m.confirmHostKey = (_, _) async => true;
      m.openHost(m.hosts.single);
      m.openHost(m.hosts.single);
      final a = m.sessions[0] as LiveTerminalSession,
          b = m.sessions[1] as LiveTerminalSession;
      await waitFor(
        () => a.controller.connected && b.controller.connected,
        'path SSH sessions',
      );
      await a.controller.setVisible(true);
      final directory = await Directory('${server.directory.path}/OSC7 dir 中文')
          .create();
      final file = await File("${directory.path}/.hidden '\$;.txt")
          .writeAsString('literal path bytes');
      final uri = Uri(
        scheme: 'file',
        host: '127.0.0.1',
        path: directory.path,
      ).toString();
      await a.controller.text(
        "unset PROMPT_COMMAND; PS1=''; printf '\\033]7;%s\\007' '$uri'; printf '%s%s\\n' PATH_ READY",
      );
      await a.controller.key(
        rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(a.controller).contains('PATH_READY'),
        'passive remote CWD',
      );
      final id = a.controller.id!, generation = a.controller.generation;
      final fileUri = Uri(
        scheme: 'file',
        host: '127.0.0.1',
        path: file.path,
      ).toString();
      expect(
        await rust.resolveTerminalPath(
          id: id,
          generation: generation,
          text: fileUri,
        ),
        file.path,
      );
      // Absolute file links belong to the original authenticated stream and do
      // not need a CWD report, including in another independently owned root.
      expect(
        await rust.resolveTerminalPath(
          id: b.controller.id!,
          generation: b.controller.generation,
          text: fileUri,
        ),
        file.path,
      );
      for (final bad in [
        'file://other.invalid${file.path}',
        'file:///bad%0apath',
        'file:///bad%E2%80%AEpath',
      ]) {
        await expectLater(
          rust.resolveTerminalPath(id: id, generation: generation, text: bad),
          throwsA(anything),
        );
      }
      expect(
        await rust.terminalWorkingDirectory(id: id, generation: generation),
        directory.path,
      );
      expect(
        await rust.resolveTerminalPath(
          id: id,
          generation: generation,
          text: file.path.split('/').last,
        ),
        file.path,
      );
      expect(
        await rust.resolveTerminalPath(
          id: id,
          generation: generation,
          text: '../sibling',
        ),
        '${directory.path}/../sibling',
      );
      await expectLater(
        rust.resolveTerminalPath(
          id: id,
          generation: generation - 1,
          text: file.path,
        ),
        throwsA(anything),
      );
      await expectLater(
        rust.resolveTerminalPath(
          id: id,
          generation: generation,
          text: 'bad\npath',
        ),
        throwsA(anything),
      );
      final bPath = b.path, oldId = id;
      m.sidebar = false;
      await m.locateTerminalPath(a, fileUri);
      expect(a.pendingFileLocation?.file, file.path);
      expect(m.focus, same(b));
      expect(b.path, bPath);
      expect(m.sidebar, false);
      // b owns focus; a's explicit operation must never target b or change its context.
      await m.locateTerminalPath(a, file.path.split('/').last);
      expect(a.path, directory.path);
      expect(a.pendingFileLocation?.file, file.path);
      expect(b.path, bPath);
      expect(m.focus, same(b));
      expect(m.sidebar, false);
      expect(a.controller.id, oldId);
      expect(a.controller.generation, generation);
      expect(await file.readAsString(), 'literal path bytes');
      final link = await Link('${directory.path}/link to file')
          .create(file.path);
      final locatedLink = await rust.sftpLocateTerminalPath(
        id: id,
        generation: generation,
        text: link.path,
      );
      expect(locatedLink.path, link.path);
      expect(
        locatedLink.symlink,
        true,
        reason: 'select the link entry, not an unrelated target directory',
      );
      await a.controller.text(
        "printf '\\033]7;file://other.invalid/unknown\\007'; printf '%s%s\\n' HOST_ MISMATCH",
      );
      await a.controller.key(
        rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(a.controller).contains('HOST_MISMATCH'),
        'different OSC7 authority',
      );
      await expectLater(
        rust.resolveTerminalPath(
          id: id,
          generation: generation,
          text: 'relative',
        ),
        throwsA(anything),
      );
      expect(
        await rust.terminalWorkingDirectory(id: id, generation: generation),
        isNull,
      );
      expect(
        await rust.resolveTerminalPath(
          id: id,
          generation: generation,
          text: file.path,
        ),
        file.path,
      );
      await m.locateTerminalPath(a, directory.path);
      expect(a.pendingFileLocation?.file, isNull);
      expect(a.path, directory.path);
      final tasks = await rust.listTransferTasks();
      // A locate whose fresh read is superseded by explicit user navigation
      // must never publish over the newer state. The stale target directory
      // is deliberately NOT cached yet so its read really is in flight.
      final staleDir = await Directory(
        '${server.directory.path}/stale locate dir',
      ).create();
      holdPage = true;
      final staleLocation = m.locateTerminalPath(a, staleDir.path);
      await pageStarted.future.timeout(const Duration(seconds: 10));
      await m.loadDirectory(a, server.directory.path);
      releasePage.complete();
      await staleLocation;
      expect(a.path, server.directory.path);
      expect(
        a.pendingFileLocation,
        isNull,
        reason: 'late file selection cannot override a newer user navigation',
      );
      expect(
        tasks,
        isEmpty,
        reason: 'path location must not upload or download',
      );
    } finally {
      if (!releasePage.isCompleted) releasePage.complete();
      await m.shutdown();
      m.dispose();
      await server.close();
    }
  }, skip: !Platform.isLinux);
}
