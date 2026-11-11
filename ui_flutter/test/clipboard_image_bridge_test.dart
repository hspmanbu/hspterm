import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
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
        expect(
          (await Process.run('stat', [
            '-c',
            '%a',
            File(path).parent.path,
          ])).stdout.toString().trim(),
          '700',
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
          await File(path).parent.delete(recursive: true);
        }
        await ssh.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
