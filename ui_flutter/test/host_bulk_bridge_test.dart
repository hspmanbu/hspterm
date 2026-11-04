import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/host_bulk.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('real bulk metadata commit preserves original SSH, SFTP, independent credentials and rejects an old preview', () async {
    final ssh = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    try {
      await rust.createConfigurationVault(
        path: '${ssh.directory.path}/bulk.vault',
        password: 'synthetic-bulk-master',
      );
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      final hosts = <DemoHost>[];
      for (var i = 0; i < 3; i++) {
        hosts.add(
          await model.persistHost(
            DemoHost(
              model.nextId(),
              'Bulk $i',
              '127.0.0.1',
              '未分组',
              user: ssh.username,
              port: ssh.port,
              auth: '私钥',
              openSftp: false,
              note: 'retained synthetic note',
            ),
            secret: ssh.privateKey,
            passphrase: 'test-only-passphrase',
          ),
        );
      }
      model.openHost(hosts.first);
      final session = model.focus! as LiveTerminalSession;
      final c = session.controller;
      await waitFor(
        () => c.connected || c.phase == 'Failed',
        'bulk original SSH',
      );
      expect(c.connected, true, reason: c.error);
      await c.setVisible(true);
      await model.loadDirectory(session, '.');
      final nativeId = c.id,
          generation = c.generation,
          path = session.path,
          width = model.sidebarWidth;
      model.sidebar = false;
      final view = await rust.loadHostBulk(
        ids: hosts.take(2).map((h) => h.id).toList(),
      );
      final patch = HostBulkPatch(
        groupId: null,
        favorite: true,
        openSftp: false,
        followOsc7: null,
        network: const HostBulkNetwork(
          useDefaults: false,
          timeoutSeconds: 17,
          keepaliveSeconds: 0,
          keepaliveResponseSeconds: 7,
          keepaliveFailures: 4,
        ),
      );
      final saved = await model.saveHostBulk(view, patch);
      expect(
        saved.revision,
        (await rust.loadHostBulk(ids: hosts.take(2).map((h) => h.id).toList()))
            .revision,
      );
      final records = await rust.listHosts();
      for (final h in records.where(
        (h) => hosts.take(2).any((old) => old.id == h.id),
      )) {
        expect(h.favorite, true);
        expect(h.timeoutSeconds, 17);
        expect(h.keepaliveSeconds, 0);
        expect(h.credentialSet, true);
        expect(h.note, 'retained synthetic note');
      }
      expect(records.singleWhere((h) => h.id == hosts.last.id).favorite, false);
      expect(c.id, nativeId);
      expect(c.generation, generation);
      expect(c.connected, true);
      expect(session.path, path);
      expect(session.sftpEnabled, true);
      expect(model.sidebar, false);
      expect(model.sidebarWidth, width);
      expect(model.sessions.single, same(session));
      expect(model.tabs.length, 1);
      await c.text(r"printf '%s%s\n' BULK_ ALIVE");
      await c.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(c).contains('BULK_ALIVE'),
        'original SSH after bulk edit',
      );
      await expectLater(model.saveHostBulk(view, patch), throwsA(anything));
      model.openHost(model.hosts.singleWhere((h) => h.id == hosts[1].id));
      final second = model.focus! as LiveTerminalSession;
      await waitFor(
        () =>
            second.controller.connected || second.controller.phase == 'Failed',
        'independent key after bulk',
      );
      expect(
        second.controller.connected,
        true,
        reason: second.controller.error,
      );
      expect(second.controller.id, isNot(nativeId));
      expect(c.connected, true);
    } finally {
      await model.shutdown();
      model.dispose();
      await ssh.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
