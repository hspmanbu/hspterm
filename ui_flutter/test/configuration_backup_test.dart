import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/configuration_backup.dart';
import 'package:hspterm/workbench/configuration_backup_panel.dart';

Map<String, dynamic> fixture({String mode = 'merge'}) => {
  'vault_scope': 'synthetic-vault-scope',
  'revision': 'synthetic-revision',
  'mode': mode,
  'local_hosts': 1,
  'incoming_hosts': 2,
  'items': [
    for (final (id, local, remote, state) in [
      ('host-existing', true, true, 'conflict'),
      ('host-new', false, true, 'added'),
      ('host-local', true, false, 'local_only'),
    ])
      {
        'id': id,
        'label': '合成 $id',
        'category': 'SSH 主机及关联配置',
        'state': state,
        'local_present': local,
        'incoming_present': remote,
        'default_incoming': mode == 'replace' || !local,
        'local_summary': local ? 'fixture@local:22 · 认证材料不显示' : null,
        'incoming_summary': remote ? 'fixture@remote:22 · 认证材料不显示' : null,
        'sensitive_change': true,
      },
  ],
};
ConfigurationRestore restoreFixture({String mode = 'merge'}) =>
    ConfigurationRestore(
      jsonEncode({
        'ticket': 'synthetic-ticket',
        'preview': fixture(mode: mode),
      }),
    );

class _Gateway implements ConfigurationBackupGateway {
  int applies = 0, exports = 0;
  final cancelled = <String>[];
  List<String>? chosen;
  Object? loadError;
  Completer<ConfigurationRestore>? preparing;
  @override
  Future<ConfigurationPreview> summary() async {
    if (loadError != null) throw loadError!;
    return ConfigurationPreview(fixture());
  }

  @override
  Future<void> export(
    ConfigurationPreview source,
    String path,
    String password,
    String backupPassword,
  ) async {
    exports++;
  }

  @override
  Future<ConfigurationRestore> prepare(
    String path,
    String password,
    String mode,
  ) => preparing?.future ?? Future.value(restoreFixture(mode: mode));
  @override
  Future<ConfigurationRestore> repreview(String ticket, String mode) async =>
      restoreFixture(mode: mode);
  @override
  Future<void> apply(
    String ticket,
    List<String> incoming,
    String password,
  ) async {
    applies++;
    chosen = incoming;
  }

  @override
  Future<void> cancel(String ticket) async {
    cancelled.add(ticket);
  }
}

class _Files implements ConfigurationBackupFiles {
  @override
  Future<String?> open() async => 'synthetic-selected-backup.hspbackup';
  @override
  Future<String?> save() async => 'synthetic-output-backup.hspbackup';
}

void main() {
  test(
    'merge defaults, per-item selection, mode preview and one explicit apply',
    () async {
      final gateway = _Gateway();
      var refreshed = 0;
      final c = ConfigurationBackupController(
        gateway: gateway,
        onRestored: () async {
          refreshed++;
        },
      );
      final owner = c.attach();
      await c.load();
      await c.prepare(owner, 'synthetic-backup', 'synthetic-password', 'merge');
      expect(c.selectedIncoming, {'host-new'});
      expect(gateway.applies, 0);
      await c.mode(owner, 'replace');
      expect(c.selectedIncoming.length, 3);
      c.select('host-local', false);
      final source = c.preview!;
      final chosen = Set<String>.of(c.selectedIncoming);
      await c.apply(owner, source, chosen, 'synthetic-master');
      expect(gateway.applies, 1);
      expect(gateway.chosen!.toSet(), {'host-existing', 'host-new'});
      expect(refreshed, 1);
      expect(c.preview, isNull);
      expect(c.committed, true);
      await c.shutdown();
      c.dispose();
    },
  );
  test('committed restore with refresh failure cannot invite a second restore submission', () async {
    final gateway = _Gateway();
    var fail = true;
    final c = ConfigurationBackupController(
      gateway: gateway,
      onRestored: () async {
        if (fail) throw StateError('synthetic refresh failure');
      },
    );
    final owner = c.attach();
    await c.prepare(owner, 'synthetic-backup', 'synthetic-password', 'merge');
    await c.apply(
      owner,
      c.preview!,
      Set.of(c.selectedIncoming),
      'synthetic-master',
    );
    expect(c.committed, true);
    expect(c.preview, isNull);
    expect(c.error, contains('恢复已经提交'));
    expect(gateway.applies, 1);
    fail = false;
    await c.refreshCommitted();
    expect(gateway.applies, 1);
    expect(c.error, isNull);
    await c.shutdown();
    c.dispose();
  });
  test('leaving during native decrypt retires the late ticket and shutdown waits for cleanup', () async {
    final gateway = _Gateway()..preparing = Completer<ConfigurationRestore>();
    final c = ConfigurationBackupController(
      gateway: gateway,
      onRestored: () async {},
    );
    final owner = c.attach();
    final loading = c.prepare(
      owner,
      'synthetic-backup',
      'synthetic-password',
      'merge',
    );
    c.detach(owner);
    var closed = false;
    final closing = c.shutdown().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, false);
    gateway.preparing!.complete(restoreFixture());
    await loading;
    await closing;
    expect(c.preview, isNull);
    expect(gateway.cancelled, ['synthetic-ticket']);
    expect(gateway.applies, 0);
    c.dispose();
  });
  test(
    'changed selection or replaced preview invalidates a frozen confirmation',
    () async {
      final gateway = _Gateway();
      final c = ConfigurationBackupController(
        gateway: gateway,
        onRestored: () async {},
      );
      final owner = c.attach();
      await c.prepare(owner, 'synthetic-backup', 'synthetic-password', 'merge');
      final old = c.preview!;
      final selected = Set.of(c.selectedIncoming);
      c.selectAll(true);
      await c.apply(owner, old, selected, 'synthetic-master');
      expect(gateway.applies, 0);
      expect(c.error, contains('原恢复选择已改变'));
      await c.closePreview();
      expect(gateway.cancelled, ['synthetic-ticket']);
      await c.shutdown();
      c.dispose();
    },
  );
  testWidgets(
    'failed read disables export and preview choices remain navigable at narrow width',
    (tester) async {
      tester.view.physicalSize = const Size(640, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gateway = _Gateway()
        ..loadError = StateError('synthetic unreadable config');
      final c = ConfigurationBackupController(
        gateway: gateway,
        onRestored: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConfigurationBackupPanel(controller: c, files: _Files()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('backup-export')))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const ValueKey('backup-error')), findsOneWidget);
      gateway.loadError = null;
      await c.load();
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('backup-open')));
      await tester.tap(find.byKey(const ValueKey('backup-open')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('backup-file-password')),
        'synthetic-password',
      );
      await tester.tap(find.byKey(const ValueKey('backup-password-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('backup-differences')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('backup-cancel-preview')),
      );
      await tester.tap(find.byKey(const ValueKey('backup-cancel-preview')));
      await tester.pumpAndSettle();
      expect(gateway.applies, 0);
      expect(c.preview, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await c.shutdown();
      c.dispose();
    },
  );
}
