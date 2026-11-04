import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/host_ordering.dart';
import 'package:hspterm/workbench/host_ordering.dart';
import 'package:hspterm/workbench/model.dart' show HostOrderingRefreshFailure;
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/prototype/app.dart';

OrderingView fixture() => OrderingView(
  vaultScope: 'fixture-vault',
  revision: 'fixture-revision',
  groups: [
    const OrderingGroup(id: 'group-default', name: '未分组'),
    const OrderingGroup(id: 'group-dev', name: '开发环境'),
    const OrderingGroup(id: 'group-prod', name: '生产环境'),
  ],
  hosts: [
    const OrderingHost(
      id: 'host-a',
      name: '开发 A',
      detail: 'fixture@a.invalid:22',
      groupId: 'group-dev',
      favorite: false,
    ),
    const OrderingHost(
      id: 'host-b',
      name: '生产 B',
      detail: 'fixture@b.invalid:22',
      groupId: 'group-prod',
      favorite: false,
    ),
    const OrderingHost(
      id: 'host-c',
      name: '主机 C',
      detail: 'fixture@c.invalid:22',
      groupId: 'group-default',
      favorite: false,
    ),
  ],
);
OrderingView applied(HostOrderDraft d) => OrderingView(
  vaultScope: d.source.vaultScope,
  revision: 'saved-revision',
  groups: d.groupIds.map((id) => d.groups[id]!).toList(),
  hosts: d.hostIds.map((id) {
    final h = d.hosts[id]!, p = d.placements[id]!;
    return OrderingHost(
      id: h.id,
      name: h.name,
      detail: h.detail,
      groupId: p.groupId,
      favorite: p.favorite,
    );
  }).toList(),
);

class _Gateway implements HostOrderingGateway {
  OrderingView view = fixture();
  Object? loadError, saveError;
  bool refreshFails = false;
  final saved = <HostOrderDraft>[];
  @override
  Future<OrderingView> load() async {
    if (loadError != null) throw loadError!;
    return view;
  }

  @override
  Future<OrderingView> save(HostOrderDraft draft) async {
    saved.add(draft);
    if (saveError != null) throw saveError!;
    view = applied(draft);
    if (refreshFails) {
      throw HostOrderingRefreshFailure(
        view,
        StateError('synthetic refresh failure'),
      );
    }
    return view;
  }
}

Future<Future<HostOrderingResult?> Function()> _open(
  WidgetTester tester,
  _Gateway gateway,
) async {
  Future<HostOrderingResult?>? pending;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () {
            pending = showDialog<HostOrderingResult>(
              context: context,
              barrierDismissible: false,
              builder: (_) => HostOrderingDialog(gateway: gateway),
            );
          },
          child: const Text('open-ordering'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open-ordering'));
  await tester.pumpAndSettle();
  return () => pending!;
}

Future<void> drag(
  WidgetTester tester,
  Finder grip,
  Finder target, {
  bool after = false,
}) async {
  await tester.ensureVisible(grip);
  final from = tester.getCenter(grip), rect = tester.getRect(target);
  final to = Offset(rect.center.dx, after ? rect.bottom - 4 : rect.top + 4);
  final gesture = await tester.startGesture(from);
  await gesture.moveBy(const Offset(0, 20));
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

class _NamedGroups extends WorkbenchModel {
  @override
  List<String> get hostGroups => ['未分组', '全部主机', '收藏'];
  @override
  List<(String, String)> get hostGroupEntries => [
    ('group-default', '未分组'),
    ('group-all-name', '全部主机'),
    ('group-favorite-name', '收藏'),
  ];
}

void main() {
  test('draft keeps a frozen source, moves stable blocks and searches all groups without touching metadata', () {
    final view = fixture(), d = HostOrderDraft(fixture());
    final frozen = HostOrderDraft(view);
    view.hosts.clear();
    expect(frozen.source.hosts.length, 3);
    d.moveHosts(['host-a', 'host-c'], 'host-b', true);
    expect(d.hostIds, ['host-b', 'host-a', 'host-c']);
    d.moveHosts(['host-a', 'host-c'], 'host-a', false);
    expect(d.hostIds, ['host-b', 'host-a', 'host-c']);
    d.moveGroup('group-prod', 'group-default', false);
    d.assign(['host-a', 'host-c'], group: 'group-prod', favorite: true);
    expect(d.visible('group-dev', ''), isEmpty);
    expect(d.visible('group-dev', '主机'), ['host-c']);
    expect(d.visible('favorites', ''), ['host-a', 'host-c']);
    expect(d.moved, 2);
    expect(d.starred, 2);
    expect(d.dirty, true);
    final proposal = d.copy();
    d.assign(['host-a'], favorite: false);
    expect(proposal.placements['host-a']!.favorite, true);
    expect(proposal.source.vaultScope, 'fixture-vault');
    expect(proposal.source.revision, 'fixture-revision');
    expect(proposal.hosts['host-a']!.detail, 'fixture@a.invalid:22');
  });
  testWidgets(
    'group, host and favorite drag stay local until explicit preview confirmation',
    (tester) async {
      final g = _Gateway();
      final result = await _open(tester, g);
      await drag(
        tester,
        find.byKey(const ValueKey('host-grip-host-a')),
        find.byKey(const ValueKey('order-group-group-prod')),
      );
      expect(g.saved, isEmpty);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('order-host-host-a')),
          matching: find.textContaining('生产环境'),
        ),
        findsOneWidget,
      );
      await drag(
        tester,
        find.byKey(const ValueKey('host-grip-host-a')),
        find.byKey(const ValueKey('order-group-favorites')),
      );
      await drag(
        tester,
        find.byKey(const ValueKey('group-grip-group-prod')),
        find.byKey(const ValueKey('order-group-group-default')),
      );
      await drag(
        tester,
        find.byKey(const ValueKey('host-grip-host-c')),
        find.byKey(const ValueKey('order-host-host-a')),
      );
      await tester.tap(find.byKey(const ValueKey('order-save')));
      await tester.pumpAndSettle();
      expect(find.text('保存分组与排序？'), findsOneWidget);
      expect(g.saved, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, '取消').last);
      await tester.pumpAndSettle();
      expect(g.saved, isEmpty);
      await tester.tap(find.byKey(const ValueKey('order-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();
      expect(await result(), isA<HostOrderingResult>());
      final d = g.saved.single;
      expect(d.groupIds.first, 'group-prod');
      expect(d.hostIds, ['host-c', 'host-a', 'host-b']);
      expect(d.placements['host-a']!.groupId, 'group-prod');
      expect(d.placements['host-a']!.favorite, true);
      expect(d.source.revision, 'fixture-revision');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed save retains proposal and permits explicit retry with the original snapshot',
    (tester) async {
      final g = _Gateway()..saveError = StateError('synthetic failure');
      final result = await _open(tester, g);
      await tester.tap(find.byKey(const ValueKey('order-favorite-host-a')));
      await tester.pump();
      Future<void> submit() async {
        await tester.tap(find.byKey(const ValueKey('order-save')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存更改'));
        await tester.pumpAndSettle();
      }

      await submit();
      expect(find.byKey(const ValueKey('ordering-error')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('order-save')))
            .onPressed,
        isNotNull,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(g.saved.length, 1);
      g.saveError = null;
      await submit();
      expect(g.saved.length, 2);
      expect(g.saved.last.source.revision, g.saved.first.source.revision);
      expect(g.saved.last.placements['host-a']!.favorite, true);
      expect(await result(), isA<HostOrderingResult>());
    },
  );
  testWidgets(
    'post-save refresh failure is acknowledged as saved and never replays old data',
    (tester) async {
      final g = _Gateway()..refreshFails = true;
      final result = await _open(tester, g);
      await tester.tap(find.byKey(const ValueKey('order-favorite-host-a')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('order-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();
      expect(find.textContaining('主机排序已保存'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('order-save')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect((await result())!.refreshRequired, true);
      expect(g.saved.length, 1);
    },
  );
  testWidgets(
    'load failure cannot save an empty fallback and can be explicitly retried',
    (tester) async {
      final g = _Gateway()..loadError = StateError('synthetic unavailable');
      await _open(tester, g);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('order-save')))
            .onPressed,
        isNull,
      );
      expect(g.saved, isEmpty);
      g.loadError = null;
      await tester.tap(find.text('重新载入'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('order-host-host-a')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('cancel with unsaved changes asks before discarding', (
    tester,
  ) async {
    final g = _Gateway();
    final result = await _open(tester, g);
    await tester.tap(find.byKey(const ValueKey('order-favorite-host-b')));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的排序修改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(HostOrderingDialog), findsOneWidget);
    expect(g.saved, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(await result(), isNull);
  });
  testWidgets(
    'saved group names cannot collide with navigation and search spans all groups',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final m = _NamedGroups()..show(WorkPage.hosts);
      m.hosts
        ..clear()
        ..addAll([
          DemoHost('a', 'First fixture', 'a.invalid', '全部主机'),
          DemoHost('b', 'Other fixture', 'b.invalid', '收藏'),
          DemoHost('c', 'Starred fixture', 'c.invalid', '未分组', favorite: true),
        ]);
      await tester.pumpWidget(PrototypeApp(model: m));
      await tester.pumpAndSettle();
      final filter = find.byKey(const ValueKey('host-group-filter'));
      expect(
        tester
            .widget<DropdownButton<String>>(filter)
            .items!
            .map((i) => i.value)
            .toSet()
            .length,
        5,
      );
      void select(String id) =>
          tester.widget<DropdownButton<String>>(filter).onChanged!(id);
      select('group-favorite-name');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('host-row-a')), findsNothing);
      expect(find.byKey(const ValueKey('host-row-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('host-row-c')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('host-search')),
        'a.invalid',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('host-row-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('host-row-b')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('host-search')), '');
      select('favorites');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('host-row-b')), findsNothing);
      expect(find.byKey(const ValueKey('host-row-c')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets('dense ordering layout tolerates narrow and scaled windows', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final (size, scale) in [
      (const Size(1280, 800), 1.0),
      (const Size(640, 480), 1.0),
      (const Size(800, 720), 2.0),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = scale;
      await _open(tester, _Gateway());
      final check = find.descendant(
        of: find.byKey(const ValueKey('order-host-host-a')),
        matching: find.byType(Checkbox),
      );
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });
}
