import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';

void main() {
  test('real SFTP exclusive creation, content size, recursive permissions and server-only copy', () async {
    await initializeRust();
    final server = await LocalSshd.start();
    final c = TerminalController(const NativeTerminalBackend());
    try {
      await rust.unlockVault(
        path: '${server.directory.path}/properties.vault',
        password: 'synthetic-properties-master',
      );
      final host = await rust.saveProfile(
        profile: rust.Profile(
          id: '',
          name: 'Synthetic file operations',
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
      await waitFor(() => c.connected, 'private properties SSH');
      final id = c.id!, generation = c.generation;
      final source = Directory('${server.directory.path}/folder 中文');
      await source.create();
      final nested = Directory('${source.path}/nested');
      await nested.create();
      final file = File('${source.path}/new.txt');
      await rust.sftpCreateFile(
        id: id,
        generation: generation,
        path: file.path,
      );
      expect(await file.length(), 0);
      await file.writeAsString('abc');
      await expectLater(
        rust.sftpCreateFile(id: id, generation: generation, path: file.path),
        throwsA(anything),
      );
      expect(await file.readAsString(), 'abc');
      await File('${nested.path}/body.txt').writeAsString('12345');
      final link = Link('${source.path}/link');
      await link.create('../outside.txt');
      final outside = File('${server.directory.path}/outside.txt');
      await outside.writeAsString('outside');
      // Listing follows links only for their UI target type; the link
      // itself remains marked and traversal/copy policies remain independent.
      final linkKinds = await Directory('${server.directory.path}/link-kinds')
          .create();
      await Link('${linkKinds.path}/folder-link').create(nested.path);
      await Link('${linkKinds.path}/file-link').create(file.path);
      await Link('${linkKinds.path}/dangling')
          .create('${linkKinds.path}/absent');
      await rust.sftpOpenDirectory(
        id: id,
        generation: generation,
        request: 1000,
        path: linkKinds.path,
      );
      try {
        final entries = <rust.RemoteFile>[];
        var done = false;
        while (!done) {
          final page = await rust.sftpDirectoryPage(
            id: id,
            generation: generation,
            request: 1000,
            limit: 256,
          );
          entries.addAll(page.files);
          done = page.done;
        }
        final folderLink = entries.singleWhere((f) => f.name == 'folder-link');
        expect(folderLink.symlink, true);
        expect(folderLink.directory, true);
        final fileLink = entries.singleWhere((f) => f.name == 'file-link');
        expect(fileLink.symlink, true);
        expect(fileLink.directory, false);
        expect(entries.singleWhere((f) => f.name == 'dangling').symlink, true);
      } finally {
        await rust.sftpCloseDirectory(
          id: id,
          generation: generation,
          request: 1000,
        );
      }
      final linkSize = (await rust.sftpProperties(
        id: id,
        generation: generation,
        path: link.path,
      )).size;
      final basic = await rust.sftpProperties(
        id: id,
        generation: generation,
        path: source.path,
        includeDirectorySize: false,
      );
      expect(basic.sizeComplete, false);
      final full = await rust.sftpProperties(
        id: id,
        generation: generation,
        path: source.path,
      );
      expect(full.sizeComplete, true);
      expect(full.size, 8 + linkSize);
      expect(full.files, 3);
      expect(full.directories, 2);
      expect(
        (await rust.sftpProperties(
          id: id,
          generation: generation,
          path: link.path,
        )).linkTarget,
        '../outside.txt',
      );
      final outsideMode = (await outside.stat()).mode;
      await rust.sftpSetProperties(
        id: id,
        generation: generation,
        path: source.path,
        permissions: 488,
        recursive: true,
      );
      expect((await file.stat()).mode & 511, 488);
      expect((await nested.stat()).mode & 511, 488);
      expect((await outside.stat()).mode, outsideMode);
      final copy = '${server.directory.path}/copied tree';
      await rust.sftpCopyOnServer(
        id: id,
        generation: generation,
        source: source.path,
        destination: copy,
      );
      expect(await File('$copy/new.txt').readAsString(), 'abc');
      expect(await Link('$copy/link').target(), '../outside.txt');
      await expectLater(
        rust.sftpCopyOnServer(
          id: id,
          generation: generation,
          source: source.path,
          destination: copy,
        ),
        throwsA(anything),
      );
      final residue = await server.directory
          .list()
          .where(
            (entry) => entry.path.split('/').last.startsWith('.hspterm-copy-'),
          )
          .toList();
      expect(residue, isEmpty);
    } finally {
      await c.shutdown();
      c.dispose();
      await server.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
  test('per-tab file clipboard copies and cuts inside the original server without transfer tasks', () async {
    await initializeRust();
    final server = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    try {
      await rust.unlockVault(
        path: '${server.directory.path}/clipboard.vault',
        password: 'synthetic-clipboard-master',
      );
      await model.load();
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Clipboard fixture',
          '127.0.0.1',
          (await rust.hostGroups()).first.name,
          user: server.username,
          port: server.port,
          auth: '私钥',
          openSftp: false,
        ),
        secret: server.privateKey,
        passphrase: 'test-only-passphrase',
      );
      model.confirmHostKey = (_, _) async => true;
      model.openHost(host);
      final source = model.focus! as LiveTerminalSession;
      await waitFor(
        () => source.controller.connected,
        'clipboard original SSH',
      );
      model.openHost(host);
      final other = model.focus! as LiveTerminalSession;
      await waitFor(() => other.controller.connected, 'clipboard other SSH');
      final from = await Directory('${server.directory.path}/from').create();
      final to = await Directory('${server.directory.path}/to').create();
      await File('${from.path}/body.txt').writeAsString('server-only body');
      await model.loadDirectory(source, from.path);
      model.copyRemoteFileClipboard(source, source.files);
      final revision = model.remoteFileClipboardRevision;
      await expectLater(
        model.pasteRemoteFileClipboard(
          other,
          to.path,
          other.controller.generation,
          allowMemoryRelay: false,
          expectedClipboardRevision: revision,
        ),
        throwsStateError,
      );
      final result = await model.pasteRemoteFileClipboard(
        source,
        to.path,
        source.controller.generation,
        allowMemoryRelay: false,
        expectedClipboardRevision: revision,
      );
      expect(result, isEmpty);
      expect(
        await File('${to.path}/body.txt').readAsString(),
        'server-only body',
      );
      expect(await File('${from.path}/body.txt').exists(), true);
      await File('${from.path}/move.txt').writeAsString('server-only move');
      await model.loadDirectory(source, from.path);
      model.copyRemoteFileClipboard(source, [
        source.files.singleWhere((f) => f.name == 'move.txt'),
      ], cut: true);
      final cutRevision = model.remoteFileClipboardRevision;
      await model.pasteRemoteFileClipboard(
        source,
        to.path,
        source.controller.generation,
        allowMemoryRelay: false,
        expectedClipboardRevision: cutRevision,
      );
      expect(await File('${from.path}/move.txt').exists(), false);
      expect(
        await File('${to.path}/move.txt').readAsString(),
        'server-only move',
      );
      expect(await rust.listTransferTasks(), isEmpty);
    } finally {
      await model.shutdown();
      model.dispose();
      await server.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
