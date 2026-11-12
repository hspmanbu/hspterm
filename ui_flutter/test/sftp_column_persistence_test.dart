import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/shortcut_settings.dart';
import 'package:hspterm/workbench/model.dart';

import 'host_catalog_snapshot_test.dart' show CatalogTestStore, host;

final layout = SftpColumnLayout(
  order: ['size', 'name', 'modified', 'kind', 'permissions', 'owner'],
  hidden: {'owner'},
  widths: {'name': 305},
);

class SavedColumns {
  final entries = <String, rust.SftpColumnPref>{};
  Completer<void>? ack;
  Future<void> write(String hostId, SftpColumnLayout value) async {
    await ack?.future;
    entries[hostId] = rust.SftpColumnPref(
      hostId: hostId,
      order: List.of(value.order),
      hidden: value.hidden.toList(),
      widths: [for (final e in value.widths.entries) (e.key, e.value.round())],
    );
  }
}

LiveWorkbenchModel create(
  CatalogTestStore store,
  SavedColumns disk, {
  Future<List<rust.SftpColumnPref>> Function()? load,
}) => LiveWorkbenchModel(
  store: store,
  columnPreferenceLoader: load ?? () async => disk.entries.values.toList(),
  columnPreferenceWriter: disk.write,
  sortPreferenceLoader: () async => [],
  paletteLoader: () async => const PaletteShortcutView(
    vaultScope: 'fixture',
    revision: 'fixture',
    enabled: false,
    key: 'KeyP',
    modifiers: 5,
    applicationInTerminal: false,
  ),
);

Future<void> loadCatalog(LiveWorkbenchModel m, CatalogTestStore store) async {
  final loading = m.load();
  store.reads.last.complete([host('Columns')]);
  await loading;
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'column restore runs independently after sort state is marked loaded',
    () async {
      final store = CatalogTestStore(), disk = SavedColumns();
      final pending = Completer<List<rust.SftpColumnPref>>();
      var reads = 0;
      final m = create(
        store,
        disk,
        load: () {
          reads++;
          return pending.future;
        },
      );
      await loadCatalog(m, store);
      final before = m.fileDefaultsRevision;
      expect(reads, 1);
      pending.complete([
        rust.SftpColumnPref(
          hostId: host('Columns').id,
          order: layout.order,
          hidden: ['owner'],
          widths: [('name', 305)],
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(m.rememberedColumns(host('Columns').id)!.order, layout.order);
      expect(
        m.fileDefaultsRevision,
        isNot(before),
        reason: 'mounted file panels must receive restored columns',
      );
      await m.shutdown();
      m.dispose();
    },
  );
  test(
    'close waits for the layout write and a new model restores it',
    () async {
      final disk = SavedColumns()..ack = Completer<void>();
      final store = CatalogTestStore();
      final first = create(store, disk);
      await loadCatalog(first, store);
      first.rememberColumns(host('Columns').id, layout);
      var retired = false;
      final closing = first.shutdown().then((_) {
        retired = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        retired,
        isFalse,
        reason: 'queued column persistence must finish before the Vault closes',
      );
      disk.ack!.complete();
      await closing;
      first.dispose();
      final nextStore = CatalogTestStore();
      final next = create(nextStore, disk);
      await loadCatalog(next, nextStore);
      expect(next.rememberedColumns(host('Columns').id)!.order, layout.order);
      expect(next.rememberedColumns(host('Columns').id)!.hidden, {'owner'});
      expect(next.rememberedColumns(host('Columns').id)!.widths['name'], 305);
      await next.shutdown();
      next.dispose();
    },
  );
  test('late disk restore never overwrites a newer user layout', () async {
    final disk = SavedColumns(), store = CatalogTestStore();
    final pending = Completer<List<rust.SftpColumnPref>>();
    final m = create(store, disk, load: () => pending.future);
    await loadCatalog(m, store);
    m.rememberColumns(host('Columns').id, layout);
    pending.complete([
      rust.SftpColumnPref(
        hostId: host('Columns').id,
        order: ['name'],
        hidden: [],
        widths: [],
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(m.rememberedColumns(host('Columns').id)!.order, layout.order);
    await m.shutdown();
    m.dispose();
  });
}
