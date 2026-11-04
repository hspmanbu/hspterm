import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/transfers.dart' as jobs;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';

void main() {
  test(
    'concurrent preview cancellation waits for the actual worker and releases shared FIFO',
    () async {
      await initializeRust();
      final server = await LocalSshd.start();
      final controller = TerminalController(const NativeTerminalBackend());
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/preview-barrier.vault',
          password: 'test-only-preview-master',
        );
        final host = await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'preview barrier fixture',
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            privateKey: true,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        controller.confirmHostKey = (_) async => true;
        await controller.start();
        await controller.connect(host.id);
        await waitFor(() => controller.connected, 'private preview SSH');
        await rust.initializeFilePreviews(
          cacheDirectory: server.directory.path,
        );
        await rust.saveTransferPreferences(
          value: const jobs.TransferPreferences(
            concurrency: 1,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 1,
          ),
        );
        final source = File('${server.directory.path}/preview-source.bin');
        await source.writeAsBytes(List.filled(131072, 41));
        final token = rust.reserveFilePreview(
          id: controller.id!,
          generation: controller.generation,
          path: source.path,
        );
        final preparing = rust.prepareFilePreview(
          token: token,
          allowLarge: true,
        );
        // Attach the rejection expectation before cancellation can complete.
        final failed = expectLater(preparing, throwsA(anything));
        await waitFor(
          () => rust.filePreviewProgress(token: token).received > 0,
          'preview download started',
        );
        await Future.wait([
          rust.cancelFilePreview(token: token),
          rust.cancelFilePreview(token: token),
        ]);
        await failed;
        expect(() => rust.filePreviewProgress(token: token), throwsA(anything));
        expect(await source.length(), 131072);
        expect(controller.connected, true);
        await rust.saveTransferPreferences(
          value: const jobs.TransferPreferences(
            concurrency: 1,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
          ),
        );
        final next = rust.reserveFilePreview(
          id: controller.id!,
          generation: controller.generation,
          path: source.path,
        );
        final ready = await rust.prepareFilePreview(
          token: next,
          allowLarge: true,
        );
        expect(ready.phase, 'Ready');
        expect(
          await File(ready.localPath!).readAsBytes(),
          await source.readAsBytes(),
        );
        await rust.cancelFilePreview(token: next);
        await rust.shutdownFilePreviews();
      } finally {
        await controller.shutdown();
        controller.dispose();
        await rust.shutdownFilePreviews();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
