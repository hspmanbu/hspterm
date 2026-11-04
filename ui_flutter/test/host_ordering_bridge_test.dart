import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/host_ordering.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/host_ordering.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

class _Fixture {
  _Fixture(this.server, this.model, this.hosts, this.path);
  final LocalSshd server;
  final LiveWorkbenchModel model;
  final List<DemoHost> hosts;
  final String path;
  static Future<_Fixture> start() async {
    final server = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    final path = '${server.directory.path}/ordering.vault';
    try {
      await rust.unlockVault(
        path: path,
        password: 'synthetic-host-order-master',
      );
      await rust.createHostGroup(name: '开发环境');
      await rust.createHostGroup(name: '生产环境');
      await rust.createHostGroup(name: '全部主机');
      await rust.createHostGroup(name: '收藏');
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      final hosts = <DemoHost>[];
      for (var i = 0; i < 3; i++) {
        hosts.add(
          await model.persistHost(
            DemoHost(
              model.nextId(),
              'Fixture $i',
              '127.0.0.1',
              i == 0 ? '开发环境' : '未分组',
              user: server.username,
              port: server.port,
              auth: '私钥',
              openSftp: false,
              note: 'preserved synthetic note',
            ),
            secret: server.privateKey,
            passphrase: 'test-only-passphrase',
          ),
        );
      }
      return _Fixture(server, model, hosts, path);
    } catch (_) {
      await model.shutdown();
      model.dispose();
      await server.close();
      rethrow;
    }
  }

  Future<void> close() async {
    await model.shutdown();
    model.dispose();
    await server.close();
  }
}

Future<OrderingView> applyDraft(HostOrderDraft d) => rust.applyHostOrdering(
  vaultScope: d.source.vaultScope,
  revision: d.source.revision,
  groups: d.groupIds,
  hosts: d.hostIds,
  placements: d.placements.values.toList(),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('real encrypted group/host order and placement preserve active original SSH SFTP and independent credentials', () async {
    final f = await _Fixture.start();
    final m = f.model;
    try {
      expect(m.hostGroups, containsAll(['全部主机', '收藏']));
      expect(m.hostGroupEntries.map((g) => g.$1).toSet().length, 5);
      m.openHost(f.hosts[0]);
      final source = m.focus! as LiveTerminalSession, c = source.controller;
      await waitFor(
        () => c.connected || c.phase == 'Failed',
        'ordering original SSH',
      );
      expect(c.connected, true, reason: c.error);
      await c.setVisible(true);
      await m.loadDirectory(source, '.');
      final id = c.id!,
          generation = c.generation,
          path = source.path,
          width = m.sidebarWidth;
      m.sidebar = false;
      final view = await rust.loadHostOrdering(),
          d = HostOrderDraft(await rust.loadHostOrdering());
      final target = d.source.groups.singleWhere((g) => g.name == '生产环境').id;
      d.groupIds.setAll(0, d.groupIds.reversed.toList());
      d.hostIds.setAll(0, d.hostIds.reversed.toList());
      d.assign(d.hostIds.take(2), group: target, favorite: true);
      final saved = await m.saveHostOrdering(
        d.source,
        d.groupIds,
        d.hostIds,
        d.placements.values.toList(),
      );
      expect(saved.revision, (await rust.loadHostOrdering()).revision);
      expect(m.hosts.map((h) => h.id), d.hostIds);
      expect(
        m.hosts.take(2).every((h) => h.group == '生产环境' && h.favorite),
        true,
      );
      final config = await rust.listHosts();
      expect(
        config.every(
          (h) =>
              h.credentialSet &&
              h.note == 'preserved synthetic note' &&
              h.privateKey,
        ),
        true,
      );
      expect(c.id, id);
      expect(c.generation, generation);
      expect(c.connected, true);
      expect(source.sftpEnabled, true);
      expect(source.path, path);
      expect(m.sidebar, false);
      expect(m.sidebarWidth, width);
      expect(m.sessions.single, same(source));
      expect(m.tabs.length, 1);
      await c.text(r"printf '%s%s\n' ORDER_ ALIVE");
      await c.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(c).contains('ORDER_ALIVE'),
        'same transport after ordering',
      );
      await expectLater(applyDraft(HostOrderDraft(view)), throwsA(anything));
      // Another real connection still authenticates from its separately owned
      // stored key after the metadata-only transaction.
      m.openHost(m.hosts.firstWhere((h) => h.id == f.hosts[1].id));
      final second = (m.focus! as LiveTerminalSession).controller;
      await waitFor(
        () => second.connected || second.phase == 'Failed',
        'independent stored credential',
      );
      expect(second.connected, true, reason: second.error);
      expect(c.id, id);
      expect(c.generation, generation);
    } finally {
      await f.close();
    }
  }, skip: !Platform.isLinux);
  test('stale saved metadata, wrong-password reopen and foreign or same-vault scopes cannot overwrite another catalog', () async {
    final f = await _Fixture.start();
    try {
      final view = await rust.loadHostOrdering();
      final h = f.hosts[0].snapshot()..note = 'updated outside ordering';
      await f.model.persistHost(h);
      final stale = HostOrderDraft(view)
        ..hostIds.setAll(0, view.hosts.map((h) => h.id).toList().reversed);
      await expectLater(applyDraft(stale), throwsA(anything));
      expect((await rust.listHosts()).first.note, 'updated outside ordering');
      final fresh = await rust.loadHostOrdering();
      await expectLater(
        rust.unlockVault(path: f.path, password: 'synthetic-wrong-password'),
        throwsA(anything),
      );
      expect(
        (await applyDraft(HostOrderDraft(fresh))).revision,
        fresh.revision,
      );
      await rust.unlockVault(
        path: '${f.server.directory.path}/other-ordering.vault',
        password: 'synthetic-other-master',
      );
      await expectLater(applyDraft(HostOrderDraft(fresh)), throwsA(anything));
      expect((await rust.loadHostOrdering()).hosts, isEmpty);
      await rust.unlockVault(
        path: f.path,
        password: 'synthetic-host-order-master',
      );
      await expectLater(applyDraft(HostOrderDraft(fresh)), throwsA(anything));
      expect((await rust.loadHostOrdering()).hosts.length, 3);
    } finally {
      await f.close();
    }
  }, skip: !Platform.isLinux);
}
