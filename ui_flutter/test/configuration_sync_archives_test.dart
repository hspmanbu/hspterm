import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/configuration_sync_archives.dart';

Map<String, dynamic> archive(String suffix, {bool active = false}) => {
  'id': 'local-cloud-sync-ledger-archive-${suffix * 64}',
  'collection': suffix * 32,
  'units': 3,
  'tombstones': 1,
  'active': active,
};
ConfigurationSyncArchives view({
  List<Map<String, dynamic>>? items,
  String scope = 'synthetic-vault',
}) => ConfigurationSyncArchives({
  'vault_scope': scope,
  'revision': 'a' * 64,
  'items': items ?? [archive('a'), archive('b', active: true)],
});

class Gateway implements ConfigurationSyncArchivesGateway {
  @override
  final owner = Object();
  @override
  bool isClosing = false;
  int loads = 0, removals = 0;
  bool fail = false;
  List<String>? deleted;
  @override
  Future<ConfigurationSyncArchives> load() async {
    loads++;
    if (fail) throw StateError('synthetic failure');
    return view();
  }

  @override
  Future<ConfigurationSyncArchives> remove(
    ConfigurationSyncArchives source,
    List<String> ids,
  ) async {
    removals++;
    deleted = List.of(ids);
    return view(items: [archive('b', active: true)]);
  }
}

Widget panel(Gateway gateway) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: ConfigurationSyncArchivesPanel(gateway: gateway),
    ),
  ),
);
void main() {
  testWidgets(
    'active baseline is disabled and cleanup requires explicit confirmation',
    (t) async {
      final g = Gateway();
      await t.pumpWidget(panel(g));
      await t.pumpAndSettle();
      expect(g.loads, 1);
      final active = find.byKey(
        ValueKey('local-cloud-sync-ledger-archive-${'b' * 64}'),
      );
      expect(t.widget<CheckboxListTile>(active).onChanged, isNull);
      await t.tap(
        find.byKey(ValueKey('local-cloud-sync-ledger-archive-${'a' * 64}')),
      );
      await t.pump();
      await t.tap(find.text('清理所选归档'));
      await t.pumpAndSettle();
      expect(find.textContaining('删除标记。再次切回'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(g.removals, 0);
      await t.tap(find.text('清理所选归档'));
      await t.pumpAndSettle();
      await t.tap(find.text('删除本机归档'));
      await t.pumpAndSettle();
      expect(g.removals, 1);
      expect(g.deleted, ['local-cloud-sync-ledger-archive-${'a' * 64}']);
      expect(find.text('本机归档已删除；当前配置和云端文件保留。'), findsOneWidget);
      expect(g.loads, 1); // ACK used directly, no fallible post-delete reread.
    },
  );
  testWidgets(
    'owner change while confirmation is open retires the original selection',
    (t) async {
      final old = Gateway(), next = Gateway();
      await t.pumpWidget(panel(old));
      await t.pumpAndSettle();
      await t.tap(
        find.byKey(ValueKey('local-cloud-sync-ledger-archive-${'a' * 64}')),
      );
      await t.pump();
      await t.tap(find.text('清理所选归档'));
      await t.pumpAndSettle();
      await t.pumpWidget(panel(next));
      await t.pumpAndSettle();
      await t.tap(find.text('删除本机归档'));
      await t.pumpAndSettle();
      expect(old.removals, 0);
      expect(next.removals, 0);
      expect(next.loads, 1);
    },
  );
  testWidgets(
    'failed reads preserve the error and cannot act as an empty deletable list',
    (t) async {
      final g = Gateway()..fail = true;
      await t.pumpWidget(panel(g));
      await t.pumpAndSettle();
      expect(find.text('没有本机基线归档'), findsNothing);
      expect(find.textContaining('读取归档失败'), findsOneWidget);
      final button = t.widget<TextButton>(
        find.widgetWithText(TextButton, '清理所选归档'),
      );
      expect(button.onPressed, isNull);
      expect(g.removals, 0);
    },
  );
  test(
    'metadata rejects unknown fields, repeated objects and inconsistent counts',
    () {
      final raw = {
        'vault_scope': 'synthetic-vault',
        'revision': 'a' * 64,
        'items': [archive('a')],
      };
      expect(
        () => ConfigurationSyncArchives({...raw, 'secret': 'synthetic-secret'}),
        throwsFormatException,
      );
      expect(
        () => ConfigurationSyncArchives({
          ...raw,
          'items': [archive('a'), archive('a')],
        }),
        throwsFormatException,
      );
      final bad = jsonDecode(jsonEncode(archive('a'))) as Map<String, dynamic>;
      bad['tombstones'] = 4;
      expect(() => ConfigurationSyncArchive(bad), throwsFormatException);
    },
  );
}
