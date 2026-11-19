import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';

// Real-sshd regression for the remove-tree stack order: children must be
// deleted before their parent's RMDIR, at every nesting depth. Run with
// HSPTERM_LIBRARY pointing at the freshly built bridge library (see
// references/verification.md); no account, server config or credentials
// outside this private root are read.
void main() {
  test(
    'recursive delete empties nested trees: children first, RMDIR last',
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
            name: 'remove tree order fixture',
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
        await waitFor(() => c.connected, 'remove tree SSH');
        final id = c.id!, generation = c.generation;
        final root = server.directory.path;
        // Three directory levels below the selected root: the deepest RMDIR
        // must still run before its ancestors', or every level above it
        // answers ENOTEMPTY and the selected folder survives "confirmed but
        // nothing happened".
        final tree = Directory('$root/tree/nested/deeper');
        await tree.create(recursive: true);
        await File('$root/tree/top.txt').writeAsString('top');
        await File('$root/tree/nested/mid.txt').writeAsString('mid');
        await File('$root/tree/nested/deeper/leaf.txt').writeAsString('leaf');

        await rust.sftpRemove(
          id: id,
          path: '$root/tree',
          recursive: true,
          expectedGeneration: generation,
        );

        expect(
          await Directory('$root/tree').exists(),
          false,
          reason: '整个 tree/ 子树（含 nested/deeper/leaf）必须被清空',
        );
      } finally {
        await c.shutdown();
        c.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );

  test(
    'batched mixed selection deletes files and Chinese-named subtrees fully',
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
            name: 'remove batch mixed fixture',
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
        await waitFor(() => c.connected, 'remove batch SSH');
        final id = c.id!, generation = c.generation;
        final root = server.directory.path;
        final loose = '$root/松散文件.txt';
        await File(loose).writeAsString('standalone');
        await Directory('$root/mixed/中文目录').create(recursive: true);
        await File('$root/mixed/说明.txt').writeAsString('说明内容');
        await File('$root/mixed/中文目录/文件.txt').writeAsString('中文内容');

        final outcome = await rust.sftpRemoveBatch(
          id: id,
          paths: [loose, '$root/mixed'],
          expectedGeneration: generation,
        );

        expect(outcome.failed, isEmpty, reason: '混合选择删除不应有失败项');
        expect(
          outcome.succeeded,
          containsAll([
            loose,
            '$root/mixed',
            '$root/mixed/说明.txt',
            '$root/mixed/中文目录',
            '$root/mixed/中文目录/文件.txt',
          ]),
          reason: '文件与含中文子文件的文件夹必须整树删除成功',
        );
        expect(await File(loose).exists(), false);
        expect(await Directory('$root/mixed').exists(), false);
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
