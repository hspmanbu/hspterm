import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/shortcut_settings.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/store.dart';

rust.HostConfig host(String name) => rust.HostConfig(
  id: 'host-00000000000000000000000000000001',
  name: name,
  address: 'example.invalid',
  port: 22,
  username: 'fixture',
  privateKey: false,
  groupId: 'group-default',
  favorite: false,
  note: '',
  credentialSet: true,
  timeoutSeconds: 30,
  keepaliveSeconds: 30,
  keepaliveFailures: 3,
  openSftp: false,
);

class CatalogTestStore extends Fake implements HostStore {
  final reads = <Completer<List<rust.HostConfig>>>[];
  @override
  Future<List<rust.HostConfig>> hosts() {
    final read = Completer<List<rust.HostConfig>>();
    reads.add(read);
    return read.future;
  }

  @override
  Future<List<rust.HostGroupConfig>> groups() async => [
    rust.HostGroupConfig(id: 'group-default', name: 'Default'),
  ];
  @override
  Future<List<rust.HostConfig>> drafts() async => [];
  @override
  Future<rust.HostConfig> save(
    rust.HostConfig value,
    String? secret,
    String? passphrase, {
    String? proxyUsername,
    String? proxyPassword,
  }) async => value;
  @override
  Future<void> draft(
    rust.HostConfig value,
    String? secret,
    String? passphrase, {
    String? proxyUsername,
    String? proxyPassword,
  }) async {}
}

class _AtomicCatalog extends CatalogTestStore implements HostCatalogStore {
  _AtomicCatalog(this.scope);
  final String scope;
  @override
  Future<rust.HostCatalogSnapshot> snapshot() async => rust.HostCatalogSnapshot(
    vaultScope: scope,
    hosts: [host('Atomic')],
    groups: [rust.HostGroupConfig(id: 'group-default', name: 'Default')],
    drafts: [],
  );
  @override
  Future<List<rust.HostConfig>> hosts() =>
      throw StateError('separate read forbidden');
}

LiveWorkbenchModel model(CatalogTestStore store) => LiveWorkbenchModel(
  store: store,
  paletteLoader: () async => const PaletteShortcutView(
    vaultScope: 'fixture',
    revision: 'fixture',
    enabled: false,
    key: 'KeyP',
    modifiers: 5,
    applicationInTerminal: false,
  ),
);
Future<void> initial(LiveWorkbenchModel value, CatalogTestStore store) async {
  final load = value.load();
  store.reads.last.complete([host('Initial')]);
  await load;
}

void main() {
  test(
    'formal snapshot capability avoids three independently timed catalog reads',
    () async {
      final store = _AtomicCatalog('fixture');
      final current = model(store);
      await current.load();
      expect(current.hosts.single.name, 'Atomic');
      expect(store.reads, isEmpty);
      await current.shutdown();
      current.dispose();
    },
  );
  test('snapshot from another Vault cannot publish against the current shortcut scope', () async {
    final store = _AtomicCatalog('old-vault');
    final current = model(store);
    await expectLater(current.load(), throwsStateError);
    expect(current.hosts, isEmpty);
    await current.shutdown();
    current.dispose();
  });

  test(
    'a late old catalog cannot replace the newest complete snapshot',
    () async {
      final store = CatalogTestStore();
      final current = model(store);
      final old = current.load(), latest = current.load();
      store.reads[1].complete([host('Latest')]);
      await latest;
      store.reads[0].complete([host('Old')]);
      await old;
      expect(current.hosts.single.name, 'Latest');
      await current.shutdown();
      current.dispose();
    },
  );
  test('a save ACK invalidates an older pending list refresh', () async {
    final store = CatalogTestStore();
    final current = model(store);
    await initial(current, store);
    final stale = current.load();
    final edited = current.hosts.single.snapshot()..name = 'Saved';
    await current.persistHost(edited);
    store.reads.last.complete([host('Old')]);
    await stale;
    expect(current.hosts.single.name, 'Saved');
    await current.shutdown();
    current.dispose();
  });
  test('a draft ACK is not erased by an older load result', () async {
    final store = CatalogTestStore();
    final current = model(store);
    await initial(current, store);
    final stale = current.load();
    final edited = current.hosts.single.snapshot()..name = 'New draft';
    await current.persistDraft(edited);
    store.reads.last.complete([host('Old')]);
    await stale;
    expect(current.recoveredDraft(edited.id)!.name, 'New draft');
    await current.shutdown();
    current.dispose();
  });
}
