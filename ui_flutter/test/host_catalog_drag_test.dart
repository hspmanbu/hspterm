import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/host_catalog_drag.dart';

import 'host_ordering_test.dart' show fixture;

void main() {
  test('drag captures one original scope only on start and keeps stable selected order', () async {
    var loads = 0;
    final drag = HostCatalogDrag(
      owner: Object(),
      ids: ['host-b', 'host-a'],
      load: () async {
        loads++;
        return fixture();
      },
    );
    expect(loads, 0);
    drag.start();
    final view = fixture();
    final target = view.hosts.last.id;
    final draft = await drag.proposal(
      HostCatalogIntent(hostId: target, after: true),
    );
    expect(loads, 1);
    expect(draft.source.vaultScope, view.vaultScope);
    expect(draft.source.revision, view.revision);
    expect(draft.hostIds.skip(draft.hostIds.length - 2), ['host-a', 'host-b']);
    expect(draft.placements['host-a']!.groupId, view.hosts.first.groupId);
  });
  test('explicit destination changes group or favorite only; groups reorder without host moves', () async {
    final owner = Object();
    final drag = HostCatalogDrag(
      owner: owner,
      ids: ['host-a'],
      load: () async => fixture(),
    )..start();
    final grouped = await drag.proposal(
      const HostCatalogIntent(groupId: 'group-prod'),
    );
    expect(grouped.placements['host-a']!.groupId, 'group-prod');
    final starred = await drag.proposal(
      const HostCatalogIntent(favorite: true),
    );
    expect(starred.placements['host-a']!.favorite, true);
    expect(starred.placements['host-a']!.groupId, 'group-dev');
    final group = HostCatalogDrag(
      owner: owner,
      groupId: 'group-prod',
      load: () async => fixture(),
    )..start();
    final order = await group.proposal(
      const HostCatalogIntent(groupId: 'group-default'),
    );
    expect(order.groupIds.first, 'group-prod');
    expect(order.hostOrderChanged, false);
  });
  test(
    'unknown/missing/self target and failed snapshot never produce an edit',
    () async {
      final d = HostCatalogDrag(
        owner: Object(),
        ids: ['host-a'],
        load: () async => fixture(),
      );
      await expectLater(
        d.proposal(const HostCatalogIntent(favorite: true)),
        throwsStateError,
      );
      d.start();
      await expectLater(
        d.proposal(const HostCatalogIntent(hostId: 'host-a')),
        throwsStateError,
      );
      await expectLater(
        d.proposal(const HostCatalogIntent(groupId: 'missing')),
        throwsStateError,
      );
      final failed = HostCatalogDrag(
        owner: Object(),
        ids: ['host-a'],
        load: () async => throw StateError('synthetic read failure'),
      )..start();
      await expectLater(
        failed.proposal(const HostCatalogIntent(favorite: true)),
        throwsStateError,
      );
    },
  );
  testWidgets(
    'actual drag accepts its own owner; another host manager cannot receive it',
    (tester) async {
      final owner = Object();
      var accepted = 0, loaded = 0;
      final data = HostCatalogDrag(
        owner: owner,
        ids: ['host-a'],
        load: () async {
          loaded++;
          return fixture();
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                HostCatalogDragSource(
                  key: const ValueKey('source'),
                  drag: data,
                  label: 'fixture',
                  child: const SizedBox(
                    width: 150,
                    height: 50,
                    child: Text('source'),
                  ),
                ),
                HostCatalogDrop(
                  key: const ValueKey('foreign'),
                  owner: Object(),
                  accept: (_) => true,
                  onDrop: (d, a) async {
                    accepted++;
                  },
                  child: const SizedBox(
                    width: 150,
                    height: 60,
                    child: Text('foreign'),
                  ),
                ),
                HostCatalogDrop(
                  key: const ValueKey('own'),
                  owner: owner,
                  accept: (_) => true,
                  onDrop: (d, a) async {
                    accepted++;
                    await d.proposal(const HostCatalogIntent(favorite: true));
                  },
                  child: const SizedBox(
                    width: 150,
                    height: 60,
                    child: Text('own'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(loaded, 0);
      Future<void> dragTo(String target) async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('source'))),
        );
        await gesture.moveBy(const Offset(10, 0));
        await tester.pump();
        await gesture.moveTo(tester.getCenter(find.byKey(ValueKey(target))));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await dragTo('foreign');
      expect(accepted, 0);
      await dragTo('own');
      expect(accepted, 1);
      expect(loaded, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
