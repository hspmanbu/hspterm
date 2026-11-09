import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/prototype/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/history_controls.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/workbench/history_controls.dart';

HistoryControls fixture({
  bool enabled = true,
  int count = 3,
  String revision = 'original',
}) => HistoryControls(
  vaultScope: 'fixture-scope',
  revision: revision,
  enabled: enabled,
  total: count,
  hosts: [HistoryHostCount(id: 'fixture-host', name: '合成主机', count: count)],
);

class _Gateway implements HistoryControlsGateway {
  @override
  Future<List<rust.CommandSearchRow>> searchCommands(
    String query,
    String? hostId,
  ) async => const [];

  @override
  Future<int> deleteCommands(List<String> texts, String? hostId) async => 0;

  HistoryControls value = fixture();
  Object? loadError, saveError;
  Completer<void>? saving;
  final changes = <(HistoryControls, bool?)>[];
  final clears = <(HistoryControls, String?)>[];
  @override
  Future<HistoryControls> load() async {
    if (loadError != null) throw loadError!;
    return value;
  }

  @override
  Future<HistoryControls> setEnabled(
    HistoryControls source,
    bool enabled,
  ) async {
    changes.add((source, enabled));
    await saving?.future;
    if (saveError != null) throw saveError!;
    return value = fixture(
      enabled: enabled,
      count: value.total,
      revision: 'saved',
    );
  }

  @override
  Future<HistoryControls> clear(HistoryControls source, String? hostId) async {
    clears.add((source, hostId));
    if (saveError != null) throw saveError!;
    return value = fixture(
      enabled: value.enabled,
      count: 0,
      revision: 'cleared',
    );
  }
}

Future<void> _mount(WidgetTester tester, _Gateway gateway) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: HistoryControlsPanel(gateway: gateway),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder keyed(String key) => find.byKey(ValueKey(key));
void main() {
  testWidgets(
    'preferences save only explicitly; failures retain choice and allow manual retry',
    (tester) async {
      final g = _Gateway();
      await _mount(tester, g);
      await tester.tap(keyed('history-enabled'));
      await tester.pump();
      expect(g.changes, isEmpty);
      g.saveError = StateError('synthetic save failure');
      await tester.tap(keyed('history-save'));
      await tester.pumpAndSettle();
      expect(g.changes.single.$1.vaultScope, 'fixture-scope');
      expect(g.changes.single.$1.revision, 'original');
      expect(
        tester.widget<SwitchListTile>(keyed('history-enabled')).value,
        false,
      );
      expect(keyed('history-error'), findsOneWidget);
      g.saveError = null;
      await tester.tap(keyed('history-save'));
      await tester.pumpAndSettle();
      expect(g.changes.length, 2);
      expect(g.changes.last.$1.revision, 'original');
      expect(g.value.enabled, false);
      expect(
        tester.widget<FilledButton>(keyed('history-save')).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'clear confirmation keeps original host/scope and never commits an unsaved preference',
    (tester) async {
      final g = _Gateway();
      await _mount(tester, g);
      await tester.tap(keyed('history-enabled'));
      await tester.pump();
      await tester.ensureVisible(keyed('history-clear-fixture-host'));
      await tester.tap(keyed('history-clear-fixture-host'));
      await tester.pumpAndSettle();
      expect(find.text('清空此主机命令历史？'), findsOneWidget);
      expect(g.clears, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(g.clears, isEmpty);
      await tester.tap(keyed('history-clear-fixture-host'));
      await tester.pumpAndSettle();
      await tester.tap(keyed('history-confirm-clear'));
      await tester.pumpAndSettle();
      expect(g.clears.single.$2, 'fixture-host');
      expect(g.clears.single.$1.revision, 'original');
      expect(g.value.total, 0);
      expect(g.value.enabled, true);
      expect(
        tester.widget<SwitchListTile>(keyed('history-enabled')).value,
        false,
      );
      expect(g.changes, isEmpty);
      await tester.ensureVisible(keyed('history-save'));
      await tester.tap(keyed('history-save'));
      await tester.pumpAndSettle();
      expect(g.changes.single.$1.revision, 'cleared');
      expect(g.value.enabled, false);
    },
  );
  testWidgets(
    'empty global clear still requires confirmation and saves an epoch; failure has no auto retry',
    (tester) async {
      final g = _Gateway()
        ..value = fixture(count: 0)
        ..saveError = StateError('synthetic stale snapshot');
      await _mount(tester, g);
      await tester.tap(keyed('history-clear-all'));
      await tester.pumpAndSettle();
      expect(find.text('清空全部命令历史？'), findsOneWidget);
      await tester.tap(keyed('history-confirm-clear'));
      await tester.pumpAndSettle();
      expect(g.clears.single.$2, isNull);
      expect(keyed('history-error'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(g.clears.length, 1);
      g.saveError = null;
      await tester.tap(keyed('history-reload'));
      await tester.pumpAndSettle();
      await tester.tap(keyed('history-clear-all'));
      await tester.pumpAndSettle();
      await tester.tap(keyed('history-confirm-clear'));
      await tester.pumpAndSettle();
      expect(g.clears.length, 2);
      expect(g.value.revision, 'cleared');
    },
  );
  testWidgets(
    'unread settings cannot overwrite defaults or clear; explicit reload recovers',
    (tester) async {
      final g = _Gateway()..loadError = StateError('synthetic unreadable');
      await _mount(tester, g);
      expect(
        tester.widget<FilledButton>(keyed('history-save')).onPressed,
        isNull,
      );
      expect(
        tester.widget<OutlinedButton>(keyed('history-clear-all')).onPressed,
        isNull,
      );
      expect(
        tester.widget<SwitchListTile>(keyed('history-enabled')).onChanged,
        isNull,
      );
      g.loadError = null;
      await tester.tap(keyed('history-reload'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(keyed('history-enabled')).onChanged,
        isNotNull,
      );
      expect(g.changes, isEmpty);
      expect(g.clears, isEmpty);
    },
  );
  testWidgets(
    'history draft survives category navigation and a clear does not discard its unsaved switch',
    (tester) async {
      final gateway = _Gateway();
      final model = WorkbenchModel();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              model: model,
              initialCategory: '历史命令联想',
              historySettingsBuilder: (_) =>
                  HistoryControlsPanel(gateway: gateway),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(keyed('history-enabled'));
      await tester.pump();
      await tester.tap(keyed('history-clear-all'));
      await tester.pumpAndSettle();
      await tester.tap(keyed('history-confirm-clear'));
      await tester.pumpAndSettle();
      await tester.tap(keyed('settings-快捷键'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(keyed('settings-历史命令联想'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(keyed('history-enabled')).value,
        false,
      );
      expect(gateway.value.enabled, true);
      expect(gateway.value.total, 0);
      await tester.tap(keyed('settings-apply'));
      await tester.pumpAndSettle();
      await tester.tap(keyed('settings-快捷键'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(keyed('settings-content-快捷键'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'pending history save cannot be discarded by changing settings category',
    (tester) async {
      final gateway = _Gateway()..saving = Completer<void>();
      final model = WorkbenchModel();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              model: model,
              initialCategory: '历史命令联想',
              historySettingsBuilder: (_) =>
                  HistoryControlsPanel(gateway: gateway),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(keyed('history-enabled'));
      await tester.pump();
      await tester.tap(keyed('settings-apply'));
      await tester.pump();
      await tester.tap(keyed('settings-快捷键'));
      await tester.pump();
      expect(keyed('history-enabled'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(gateway.changes.length, 1);
      gateway.saving!.complete();
      await tester.pumpAndSettle();
      await tester.tap(keyed('settings-快捷键'));
      await tester.pumpAndSettle();
      expect(keyed('settings-content-快捷键'), findsOneWidget);
      expect(gateway.value.enabled, false);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'host search is local and narrow scaled controls have no overflow',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final (size, scale) in [
        (const Size(400, 720), 1.0),
        (const Size(800, 1440), 2.0),
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = scale;
        final g = _Gateway();
        await _mount(tester, g);
        await tester.ensureVisible(keyed('history-host-search'));
        await tester.enterText(keyed('history-host-search'), '无匹配');
        await tester.pumpAndSettle();
        expect(keyed('history-clear-fixture-host'), findsNothing);
        expect(g.changes, isEmpty);
        expect(g.clears, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
  );
}
