import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/previews.dart' as previews;
import 'package:hspterm/src/rust/transfers.dart' as jobs;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';
import 'support/close_failure_sftp.dart';
import 'transfer_bridge_test.dart' show waitTask;

void main() {
  setUpAll(() async {
    if (Platform.isLinux) await initializeRust();
  });
  test(
    'real SSH preview rejects a full file when its SFTP CLOSE fails',
    () async {
      final server = await LocalSshd.start(sftpFixture: closeFailureSftp);
      final c = TerminalController(const NativeTerminalBackend());
      try {
        await rust.initializeFilePreviews(
          cacheDirectory: server.directory.path,
        );
        await rust.unlockVault(
          path: '${server.directory.path}/close-failure.vault',
          password: 'test-only-preview-close',
        );
        final host = await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Close fixture',
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
        await waitFor(() => c.connected, 'CLOSE fixture SSH');
        final generation = c.generation;
        final token = rust.reserveFilePreview(
          id: c.id!,
          generation: generation,
          path: '/fixture.txt',
        );
        final result = await rust.prepareFilePreview(
          token: token,
          allowLarge: false,
        );
        expect(result.phase, 'Failed');
        expect(result.received, 'controlled preview close fixture'.length);
        expect(result.localPath, isNull);
        expect(result.error, isNotNull);
        expect(result.error, contains('远端文件关闭失败'));
        expect(c.connected, true);
        expect(c.generation, generation);
        final roots = await Directory(server.directory.path)
            .list()
            .where(
              (e) => e.path.split('/').last.startsWith('hspterm-previews-v1'),
            )
            .toList();
        final entries = await (roots.single as Directory)
            .list(recursive: true)
            .toList();
        expect(
          entries.whereType<File>().where(
            (f) => f.path.endsWith('preview.txt'),
          ),
          isEmpty,
        );
      } finally {
        await c.shutdown();
        c.dispose();
        await rust.shutdownFilePreviews();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
    skip: !Platform.isLinux,
  );
  test(
    'fresh preview downloads, large confirmation, FIFO, cancel and session generation',
    () async {
      final server = await LocalSshd.start();
      final c = TerminalController(const NativeTerminalBackend());
      final other = TerminalController(const NativeTerminalBackend());
      try {
        await rust.initializeFilePreviews(
          cacheDirectory: server.directory.path,
        );
        await rust.unlockVault(
          path: '${server.directory.path}/previews.vault',
          password: 'test-only-preview-master',
        );
        final host = await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Preview fixture',
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
        await waitFor(() => c.connected, 'preview SSH');
        final source = File('${server.directory.path}/文件 space\' dollar\$.txt');
        final bytes = [
          ...utf8.encode('中文 é\n'),
          ...List.generate(70000, (i) => i % 251),
        ];
        await source.writeAsBytes(bytes);
        // Copy/drag is not an explicit request to open a link. A stale list
        // entry that has become a symlink must not download its referent.
        final exportLink = Link('${server.directory.path}/export-link.txt');
        await exportLink.create(source.path);
        final rejectedExport = rust.reserveExplorerFileExport(
          id: c.id!,
          generation: c.generation,
          path: exportLink.path,
        );
        final rejected = await rust.prepareFilePreview(
          token: rejectedExport,
          allowLarge: true,
        );
        expect(rejected.phase, 'Failed');
        expect(rejected.localPath, isNull);
        await rust.cancelFilePreview(token: rejectedExport);
        final explicitOpen = rust.reserveFilePreview(
          id: c.id!,
          generation: c.generation,
          path: exportLink.path,
        );
        final openedLink = await rust.prepareFilePreview(
          token: explicitOpen,
          allowLarge: true,
        );
        expect(openedLink.phase, 'Ready', reason: openedLink.error);
        expect(await File(openedLink.localPath!).readAsBytes(), bytes);
        await rust.cancelFilePreview(token: explicitOpen);
        final ordinaryExport = rust.reserveExplorerFileExport(
          id: c.id!,
          generation: c.generation,
          path: source.path,
        );
        final exported = await rust.prepareFilePreview(
          token: ordinaryExport,
          allowLarge: true,
        );
        expect(exported.phase, 'Ready', reason: exported.error);
        expect(await File(exported.localPath!).readAsBytes(), bytes);
        await rust.cancelFilePreview(token: ordinaryExport);
        expect(await source.readAsBytes(), bytes);
        expect(await exportLink.target(), source.path);
        expect(c.connected, true);
        final first = rust.reserveFilePreview(
          id: c.id!,
          generation: c.generation,
          path: source.path,
        );
        expect(rust.filePreviewProgress(token: first).phase, 'Reserved');
        final a = await rust.prepareFilePreview(
          token: first,
          allowLarge: false,
        );
        expect(a.phase, 'Ready', reason: a.error);
        expect(a.confirmationMib, 100);
        expect(a.received, bytes.length);
        expect(await File(a.localPath!).readAsBytes(), bytes);
        expect((await rust.fileOpenPreferences()).confirmationMib, 100);
        await rust.saveFileOpenPreferences(
          value: const previews.FileOpenPreferences(confirmationMib: 0),
        );
        expect((await rust.fileOpenPreferences()).confirmationMib, 0);
        final empty = File('${server.directory.path}/empty-preview.txt');
        await empty.writeAsBytes([]);
        final always = rust.reserveFilePreview(
          id: c.id!,
          generation: c.generation,
          path: empty.path,
        );
        final every = await rust.prepareFilePreview(
          token: always,
          allowLarge: false,
        );
        expect(every.phase, 'NeedsConfirmation');
        expect(every.confirmationMib, 0);
        expect(every.total, 0);
        expect(every.localPath, isNull);
        await rust.saveFileOpenPreferences(
          value: const previews.FileOpenPreferences(confirmationMib: 1),
        );
        // Changing configuration cannot alter an already displayed prompt.
        final still = await rust.prepareFilePreview(
          token: always,
          allowLarge: false,
        );
        expect(still.phase, 'NeedsConfirmation');
        expect(still.confirmationMib, 0);
        final accepted = await rust.prepareFilePreview(
          token: always,
          allowLarge: true,
        );
        expect(accepted.phase, 'Ready', reason: accepted.error);
        expect(await File(accepted.localPath!).length(), 0);
        final customFile = File('${server.directory.path}/custom-preview.bin');
        final customHandle = await customFile.open(mode: FileMode.write);
        await customHandle.truncate(1024 * 1024 + 1);
        await customHandle.close();
        final custom = rust.reserveFilePreview(
          id: c.id!,
          generation: c.generation,
          path: customFile.path,
        );
        final smallLimit = await rust.prepareFilePreview(
          token: custom,
          allowLarge: false,
        );
        expect(smallLimit.phase, 'NeedsConfirmation');
        expect(smallLimit.confirmationMib, 1);
        expect(smallLimit.received, 0);
        expect(smallLimit.localPath, isNull);
        await rust.cancelFilePreview(token: custom);
        await rust.saveFileOpenPreferences(
          value: const previews.FileOpenPreferences(confirmationMib: 100),
        );
        final abandoned = rust.reserveFilePreview(
          id: c.id!,
          generation: c.generation,
          path: source.path,
        );
        await rust.cancelFilePreview(token: abandoned);
        await expectLater(
          rust.prepareFilePreview(token: abandoned, allowLarge: false),
          throwsA(anything),
        );
        await source.writeAsString('changed after first preview');
        final second = rust.reserveFilePreview(
          id: c.id!,
          generation: c.generation,
          path: source.path,
        );
        final b = await rust.prepareFilePreview(
          token: second,
          allowLarge: false,
        );
        expect(b.phase, 'Ready', reason: b.error);
        expect(b.localPath, isNot(a.localPath));
        expect(
          await File(b.localPath!).readAsString(),
          'changed after first preview',
        );
        expect(await File(a.localPath!).readAsBytes(), bytes);
        other.confirmHostKey = (_) async => true;
        await other.start();
        await other.connect(host.id);
        await waitFor(() => other.connected, 'independent preview SSH');
        expect(other.id, isNot(c.id));
        final alias = Link('${server.directory.path}/preview-alias.txt');
        await alias.create(source.path);
        final aliasInfo = await rust.sftpResolveEntry(
          id: other.id!,
          generation: other.generation,
          path: alias.path,
        );
        expect(aliasInfo.directory, false);
        expect(aliasInfo.path, source.path);
        final directory = Directory('${server.directory.path}/link-target');
        await directory.create();
        final directoryAlias = Link('${server.directory.path}/directory-alias');
        await directoryAlias.create(directory.path);
        final directoryInfo = await rust.sftpResolveEntry(
          id: c.id!,
          generation: c.generation,
          path: directoryAlias.path,
        );
        expect(directoryInfo.directory, true);
        expect(directoryInfo.path, directory.path);
        final otherToken = rust.reserveFilePreview(
          id: other.id!,
          generation: other.generation,
          path: alias.path,
        );
        final otherPreview = await rust.prepareFilePreview(
          token: otherToken,
          allowLarge: false,
        );
        expect(otherPreview.phase, 'Ready', reason: otherPreview.error);
        expect(otherPreview.localPath, isNot(b.localPath));
        expect(
          await File(otherPreview.localPath!).readAsString(),
          'changed after first preview',
        );

        final sparse = File('${server.directory.path}/large.bin');
        final handle = await sparse.open(mode: FileMode.write);
        await handle.truncate(100 * 1024 * 1024 + 1);
        await handle.close();
        final large = rust.reserveFilePreview(
          id: c.id!,
          generation: c.generation,
          path: sparse.path,
        );
        final confirm = await rust.prepareFilePreview(
          token: large,
          allowLarge: false,
        );
        expect(confirm.phase, 'NeedsConfirmation');
        expect(confirm.total, 100 * 1024 * 1024 + 1);
        expect(confirm.received, 0);
        expect(confirm.localPath, isNull);
        await rust.saveTransferPreferences(
          value: const jobs.TransferPreferences(
            concurrency: 1,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 65536,
          ),
        );
        final pending = rust.prepareFilePreview(token: large, allowLarge: true);
        final cancelled = expectLater(pending, throwsA(anything));
        await waitFor(
          () => rust.filePreviewProgress(token: large).received > 65536,
          'large confirmed preview progress',
        );
        // Preview content shares the real transfer scheduler and direction budget.
        final uploadTarget = File(
          '${server.directory.path}/queued-after-preview.txt',
        );
        final task = await rust.enqueueTransfer(
          id: c.id!,
          local: source.path,
          remote: uploadTarget.path,
          upload: true,
        );
        await waitTask(task, (t) => t.busy && t.state == 'Waiting');
        expect(await uploadTarget.exists(), false);
        await rust.cancelFilePreview(token: large);
        await cancelled;
        final complete = await waitTask(task, (t) => !t.busy);
        expect(complete.state, 'Complete', reason: complete.error);
        final roots = await Directory(server.directory.path)
            .list()
            .where(
              (e) => e.path.split('/').last.startsWith('hspterm-previews-v1'),
            )
            .toList();
        expect(roots, hasLength(1));
        final remaining = await (roots.single as Directory)
            .list(recursive: true)
            .toList();
        expect(
          remaining.whereType<File>().where(
            (f) => f.path.endsWith('preview.bin'),
          ),
          isEmpty,
        );
        await c.text("printf '%s%s\\n' PREVIEW_ PTY\n");
        await waitFor(
          () => screen(c).contains('PREVIEW_PTY'),
          'PTY remains usable during previews',
        );

        final oldGeneration = c.generation;
        final stale = rust.reserveFilePreview(
          id: c.id!,
          generation: oldGeneration,
          path: source.path,
        );
        final medium = File('${server.directory.path}/medium.bin');
        await medium.writeAsBytes(List.filled(1024 * 1024, 11));
        final interrupted = rust.reserveFilePreview(
          id: c.id!,
          generation: oldGeneration,
          path: medium.path,
        );
        final work = rust.prepareFilePreview(
          token: interrupted,
          allowLarge: false,
        );
        await waitFor(
          () => rust.filePreviewProgress(token: interrupted).received > 0,
          'preview before remote exit',
        );
        await c.text('exit\n');
        await waitFor(
          () => c.phase == 'Disconnected',
          'unexpected remote exit',
        );
        final failure = await work;
        expect(failure.phase, 'Failed', reason: failure.error);
        expect(failure.localPath, isNull);
        expect(c.generation, oldGeneration);
        expect(other.connected, true);
        expect(await File(otherPreview.localPath!).exists(), true);
        expect(await File(a.localPath!).readAsBytes(), bytes);
        await c.connect(host.id);
        await waitFor(
          () => c.connected && c.generation == oldGeneration + 1,
          'manual preview reconnect',
        );
        final obsolete = await rust.prepareFilePreview(
          token: stale,
          allowLarge: false,
        );
        expect(obsolete.phase, 'Failed');
        await expectLater(
          rust.sftpResolveEntry(
            id: c.id!,
            generation: oldGeneration,
            path: directoryAlias.path,
          ),
          throwsA(anything),
        );
        expect(c.generation, oldGeneration + 1);
        expect(
          () => rust.reserveFilePreview(
            id: c.id!,
            generation: oldGeneration,
            path: source.path,
          ),
          throwsA(anything),
        );
        await rust.shutdownFilePreviews();
        expect(await File(a.localPath!).exists(), false);
        expect(await File(b.localPath!).exists(), false);
        expect(await File(otherPreview.localPath!).exists(), false);
        expect(
          other.connected,
          true,
          reason: 'cache shutdown does not close unrelated SSH transports',
        );
        final runs = await (roots.single as Directory)
            .list()
            .where((e) => e.path.split('/').last.startsWith('run-'))
            .toList();
        expect(runs, isEmpty);
      } finally {
        await c.shutdown();
        c.dispose();
        await other.shutdown();
        other.dispose();
        await rust.shutdownFilePreviews();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isLinux,
  );
}
