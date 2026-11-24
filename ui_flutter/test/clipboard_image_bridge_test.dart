import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/transfers.dart' show TransferPreferences;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test(
    'real image upload is private and generation-bound; insertion never presses Enter',
    () async {
      final ssh = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      String? path;
      try {
        await rust.createConfigurationVault(
          path: '${ssh.directory.path}/image.vault',
          password: 'synthetic-image-master',
        );
        await model.load();
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            'Image test',
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
        final session = model.focus! as LiveTerminalSession,
            c = session.controller;
        await waitFor(() => c.connected || c.phase == 'Failed', 'image SSH');
        expect(c.connected, true, reason: c.error);
        await c.setVisible(true);
        final id = c.id!, generation = c.generation;
        final file = File('${ssh.directory.path}/image.png');
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=',
        );
        await file.writeAsBytes(bytes);
        path = await rust.uploadClipboardImage(
          id: id,
          generation: generation,
          localPath: file.path,
        );
        expect(await File(path).readAsBytes(), bytes);
        expect(
          (await Process.run('stat', [
            '-c',
            '%a',
            path,
          ])).stdout.toString().trim(),
          '600',
        );
        // Images now use exclusive clipboardNNN.png files in safe /tmp;
        // never assume a private subdirectory or recursively delete /tmp.
        expect(path, matches(r'/clipboard[0-9]+\.png$'));
        await rust.saveTransferPreferences(
          value: const TransferPreferences(
            concurrency: 2,
            uploadBytesPerSecond: 32768,
            downloadBytesPerSecond: 0,
          ),
        );
        final large = File('${ssh.directory.path}/cancel.png');
        final handle = await large.open(mode: FileMode.write);
        await handle.writeFrom(bytes);
        await handle.truncate(1024 * 1024);
        await handle.close();
        final work = rust.uploadClipboardImage(
          id: id,
          generation: generation,
          localPath: large.path,
        );
        final stopped = expectLater(work, throwsA(anything));
        String? cancelledPath;
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (true) {
          final progress = jsonDecode(
            await rust.clipboardImageProgress(
              id: id,
              generation: generation,
              localPath: large.path,
            ),
          ) as Map<String, dynamic>;
          if (progress.isNotEmpty && (progress['done'] as int) > 0) {
            cancelledPath = progress['path'] as String;
            break;
          }
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('first acknowledged image chunk');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          await rust.cancelClipboardImage(
            id: id,
            generation: generation + 1,
            localPath: large.path,
          ),
          false,
        );
        expect(
          await rust.cancelClipboardImage(
            id: id,
            generation: generation,
            localPath: large.path,
          ),
          true,
        );
        await stopped;
        expect(
          File(cancelledPath).existsSync(),
          false,
          reason: 'cancelled incomplete image is cleaned only after ACK drain',
        );
        expect(
          await rust.cancelClipboardImage(
            id: id,
            generation: generation,
            localPath: large.path,
          ),
          false,
        );
        await rust.saveTransferPreferences(
          value: const TransferPreferences(
            concurrency: 2,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
          ),
        );
        final marker = File('${ssh.directory.path}/must-not-execute');
        await rust.pasteClipboardImagePath(
          id: id,
          generation: generation,
          path: "/tmp/a b';touch ${marker.path};#",
        );
        await waitFor(
          () =>
              screen(c)
                  .replaceAll(RegExp(r'\s+'), '')
                  .contains('must-not-execute'),
          'image literal path echo',
        );
        expect(marker.existsSync(), false);
        await expectLater(
          rust.pasteClipboardImagePath(
            id: id,
            generation: generation,
            path: '/tmp/x\nwhoami',
          ),
          throwsA(anything),
        );
        await rust.disconnectTerminal(id: id);
        await waitFor(() => !c.connected, 'image disconnect');
        await c.reconnect();
        await waitFor(
          () => c.connected || c.phase == 'Failed',
          'image reconnect',
        );
        expect(c.connected, true, reason: c.error);
        expect(c.generation, isNot(generation));
        await expectLater(
          rust.uploadClipboardImage(
            id: id,
            generation: generation,
            localPath: file.path,
          ),
          throwsA(anything),
        );
        await expectLater(
          rust.pasteClipboardImagePath(
            id: id,
            generation: generation,
            path: path,
          ),
          throwsA(anything),
        );
      } finally {
        await model.shutdown();
        model.dispose();

        if (path != null && File(path).existsSync()) {
          await File(path).delete();
        }
        await ssh.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
