import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';

import 'native_bridge_test.dart' show waitFor;
import 'support/local_sshd.dart';
import 'transfer_bridge_test.dart' show waitTask;

void main() {
  test(
    'real folder snapshot uses one task, read leases, encrypted recovery and offline re-delivery',
    () async {
      await initializeRust();
      final server = await LocalSshd.start();
      final terminal = TerminalController(const NativeTerminalBackend());
      final vault = '${server.directory.path}/export.vault';
      const master = 'test-only-export-master';
      try {
        await rust.unlockVault(path: vault, password: master);
        final host = await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Export fixture',
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            privateKey: true,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        terminal.confirmHostKey = (_) async => true;
        await terminal.start();
        await terminal.connect(host.id);
        await waitFor(() => terminal.connected, 'export SSH');
        final source = await Directory('${server.directory.path}/source')
            .create();
        await Directory('${source.path}/空目录').create();
        final bytes = List.generate(130000, (i) => i % 251);
        await File('${source.path}/中文😀.bin').writeAsBytes(bytes);
        await File('${source.path}/empty').writeAsBytes([]);
        final ticket = await rust.beginExplorerExport(
          id: terminal.id!,
          generation: terminal.generation,
          cacheDirectory: server.directory.path,
          path: source.path,
          name: '导出 根',
        );
        final inventory = await rust.explorerExportInventory(
          task: ticket.task,
          lease: ticket.lease,
        );
        expect(inventory.first.name, '导出 根');
        expect(inventory.first.directory, true);
        expect(
          inventory.any((d) => d.name == '导出 根\\空目录' && d.directory),
          true,
        );
        final row = await waitTask(ticket.task, (t) => !t.busy);
        expect(row.remoteTransport, 'explorer_snapshot');
        expect(row.name, '导出 根');
        expect(row.state, 'Paused');
        expect(
          await FileSystemEntity.type(row.local),
          FileSystemEntityType.notFound,
        );
        expect(
          (await rust.listTransferTasks()).where((t) => t.id == ticket.task),
          hasLength(1),
        );
        final file = inventory.singleWhere((d) => d.name.endsWith('中文😀.bin'));
        final ready = await rust.prepareExplorerExportFile(
          task: ticket.task,
          lease: ticket.lease,
          node: file.node,
        );
        expect(await File(ready.local!).readAsBytes(), bytes);
        expect(await Directory('${row.local}/空目录').exists(), true);
        expect(
          (await waitTask(ticket.task, (t) => !t.busy)).state,
          'ExportReady',
        );
        await expectLater(
          rust.releaseExplorerExport(
            task: ticket.task,
            lease: ticket.lease,
            delivered: true,
          ),
          throwsA(anything),
        );
        expect(await File(ready.local!).exists(), true);
        await rust.releaseExplorerExportFile(
          task: ticket.task,
          lease: ticket.lease,
          read: ready.read!,
        );
        await rust.releaseExplorerExport(
          task: ticket.task,
          lease: ticket.lease,
          delivered: false,
        );
        await terminal.shutdown();
        // No actual remote connection is used by this re-delivery, even after
        // the registry is reloaded from the encrypted device-only task journal.
        await rust.unlockVault(path: vault, password: master);
        final resumed = await rust.attachExplorerExport(task: ticket.task);
        final saved = await rust.explorerExportInventory(
          task: resumed.task,
          lease: resumed.lease,
        );
        final descriptor = saved.singleWhere(
          (d) => d.name.endsWith('中文😀.bin'),
        );
        final local = await rust.prepareExplorerExportFile(
          task: resumed.task,
          lease: resumed.lease,
          node: descriptor.node,
        );
        expect(await File(local.local!).readAsBytes(), bytes);
        await rust.releaseExplorerExportFile(
          task: resumed.task,
          lease: resumed.lease,
          read: local.read!,
        );
        await rust.releaseExplorerExport(
          task: resumed.task,
          lease: resumed.lease,
          delivered: true,
        );
        expect(await File(local.local!).exists(), false);
        expect(await File('${source.path}/中文😀.bin').readAsBytes(), bytes);
        await rust.unlockVault(path: vault, password: master);
        expect(
          (await rust.listTransferTasks()).where((t) => t.id == ticket.task),
          isEmpty,
        );
      } finally {
        await terminal.shutdown();
        terminal.dispose();
        await server.close();
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
