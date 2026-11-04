import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart';
import 'package:hspterm/src/rust/host_bulk.dart';
import 'package:hspterm/workbench/host_bulk.dart';
import 'package:hspterm/workbench/model.dart' show HostBulkRefreshFailure;

HostBulkView fixture() => HostBulkView(
  vaultScope: 'fixture-scope',
  revision: 'fixture-revision',
  groups: [const HostGroupConfig(id: 'group-default', name: '未分组')],
  hosts: [
    for (var i = 0; i < 2; i++)
      HostBulkHost(
        id: 'host-$i',
        name: 'Server $i',
        groupId: 'group-default',
        favorite: false,
        openSftp: i == 0,
        followOsc7: false,
        network: HostBulkNetwork(
          useDefaults: false,
          timeoutSeconds: 30,
          keepaliveSeconds: 30,
          keepaliveResponseSeconds: 10,
          keepaliveFailures: 3,
        ),
      ),
  ],
);

class BulkTestGateway implements HostBulkGateway {
  int saves = 0;
  HostBulkPatch? patch;
  Object? failure;
  Object? loadFailure;
  @override
  Future<HostBulkView> load(List<String> ids) async {
    if (loadFailure != null) throw loadFailure!;
    return fixture();
  }

  @override
  Future<HostBulkView> save(
    HostBulkView original,
    HostBulkPatch proposal,
  ) async {
    saves++;
    patch = proposal;
    if (failure != null) throw failure!;
    return fixture();
  }
}

Future<void> mount(WidgetTester tester, BulkTestGateway gateway) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HostBulkDialog(ids: const ['host-0', 'host-1'], gateway: gateway),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  test('impact distinguishes an explicit false and absent values; inherit preserves dormant overrides', () {
    final h = fixture().hosts.first;
    final patch = HostBulkPatch(
      groupId: null,
      favorite: null,
      openSftp: false,
      followOsc7: null,
      network: const HostBulkNetwork(
        useDefaults: true,
        timeoutSeconds: 30,
        keepaliveSeconds: 30,
        keepaliveResponseSeconds: null,
        keepaliveFailures: 3,
      ),
    );
    final impact = hostBulkImpact(h, patch, {'group-default': '未分组'});
    expect(impact.any((s) => s.contains('开 → 关')), true);
    expect(impact.any((s) => s.contains('保留原覆盖值')), true);
    expect(impact.any((s) => s.contains('收藏')), false);
  });
  testWidgets(
    'nothing selected by default; preview and cancellation never write; saved once only',
    (tester) async {
      final g = BulkTestGateway();
      await mount(tester, g);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('host-bulk-apply')))
            .onPressed,
        isNull,
      );
      await tap(tester, 'host-bulk-field-favorite');
      final switchFinder = find.descendant(
        of: find.byType(HostBulkDialog),
        matching: find.byType(SwitchListTile),
      );
      // First host is not a favorite. Explicitly change the selected value.
      tester.widget<SwitchListTile>(switchFinder.first).onChanged!(true);
      await tester.pumpAndSettle();
      expect(find.textContaining('收藏：关 → 开'), findsWidgets);
      await tap(tester, 'host-bulk-apply');
      expect(g.saves, 0);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(g.saves, 0);
      await tap(tester, 'host-bulk-apply');
      await tap(tester, 'host-bulk-confirm');
      expect(g.saves, 1);
      expect(g.patch!.favorite, true);
      expect(g.patch!.network, isNull);
      expect(g.patch!.openSftp, isNull);
      expect(find.byKey(const ValueKey('host-bulk-apply')), findsNothing);
      expect(find.textContaining('已原子保存'), findsOneWidget);
    },
  );
  testWidgets(
    'unknown loaded state is read-only; refresh failure after ACK cannot invite reapply',
    (tester) async {
      final g = BulkTestGateway()
        ..loadFailure = StateError('synthetic unavailable');
      await mount(tester, g);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('host-bulk-apply')))
            .onPressed,
        isNull,
      );
      g.loadFailure = null;
      await tap(tester, 'host-bulk-reload');
      await tap(tester, 'host-bulk-field-follow');
      final value = find.descendant(
        of: find.byType(HostBulkDialog),
        matching: find.byType(SwitchListTile),
      );
      tester.widget<SwitchListTile>(value.first).onChanged!(true);
      await tester.pumpAndSettle();
      g.failure = HostBulkRefreshFailure(
        fixture(),
        StateError('synthetic refresh failed'),
      );
      await tap(tester, 'host-bulk-apply');
      await tap(tester, 'host-bulk-confirm');
      expect(g.saves, 1);
      expect(find.byKey(const ValueKey('host-bulk-apply')), findsNothing);
      expect(find.textContaining('原配置已保存'), findsOneWidget);
    },
  );
  testWidgets(
    'small window and text scale keep confirmation and scrolling usable',
    (tester) async {
      tester.view.physicalSize = const Size(720, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: HostBulkDialog(
              ids: const ['host-0', 'host-1'],
              gateway: BulkTestGateway(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tap(tester, 'host-bulk-field-network');
      await tap(tester, 'host-bulk-inherit');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('host-bulk-apply')), findsOneWidget);
    },
  );
}
