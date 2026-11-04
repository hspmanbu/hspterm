import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/app.dart';
import 'package:hspterm/prototype/model.dart';

void consistent(WorkbenchModel m) {
  final groups = m.layoutGroups;
  expect(groups.map((g) => g.id).toSet().length, groups.length);
  expect(groups.map((g) => g.id).toSet(), m.tabGroups.keys.toSet());
  for (final g in groups) {
    expect(g.tabs, isNotEmpty);
    expect(g.tabs.where((t) => t.id == g.selectedId), hasLength(1));
    var unpinned = false;
    for (final t in g.tabs) {
      if (!t.pinned) unpinned = true;
      if (unpinned) expect(t.pinned, false);
    }
  }
  expect(m.tabs.map((t) => t.id).toSet().length, m.tabs.length);
  expect(
    m.tabs.map((t) => t.sessionId).toSet(),
    m.sessions.map((s) => s.id).toSet(),
  );
  expect(m.tabs.length, m.sessions.length);
  if (groups.isEmpty) {
    expect(m.root, isNull);
    expect(m.focus, isNull);
    expect(m.maximizedGroupId, isNull);
  } else {
    expect(m.tabGroups.containsKey(m.focusedGroupId), true);
    if (m.maximizedGroupId != null) {
      expect(m.tabGroups.containsKey(m.maximizedGroupId), true);
    }
  }
}

Future<void> mount(WidgetTester tester, WorkbenchModel m) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  await tester.pumpWidget(PrototypeApp(model: m));
  await tester.pumpAndSettle();
}

Future<void> dragTab(WidgetTester tester, String id, Offset target) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byKey(ValueKey('tab-$id'))),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(const Offset(0, 16));
  await tester.pump();
  await gesture.moveTo(target);
  await tester.pump(const Duration(milliseconds: 120));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  test('three connections are three tabs in one group; quick-connect creates no placeholder session', () {
    final m = WorkbenchModel()..demo();
    expect(m.tabs, hasLength(3));
    expect(m.layoutGroups.single.tabs, hasLength(3));
    final sessions = m.sessions;
    for (final t in m.tabs) {
      m.selectTab(t.id);
      expect(m.focus, same(m.session(t)));
    }
    m.newTab();
    expect(m.startPage, true);
    expect(m.sessions, orderedEquals(sessions));
    m.selectTab(m.tabs[1].id);
    expect(m.startPage, false);
    consistent(m);
    m.dispose();
  });
  for (final side in TabPlacement.values.where(
    (v) => v != TabPlacement.center,
  )) {
    test(
      '${side.name} split moves one existing session; merge/close preserve others',
      () {
        final m = WorkbenchModel()..demo();
        final tabs = m.tabs, sessions = m.sessions, group = m.focusedGroupId!;
        sessions[1].draft = '中文 draft';
        sessions[1].path = '/tmp/B';
        m.moveTab(tabs[1].id, group, placement: side);
        expect(m.tabGroups, hasLength(2));
        expect(m.groupOf(tabs[2].id)!.id, group);
        expect(m.sessions, orderedEquals(sessions));
        final tree = m.root;
        m.maximize(m.focusedGroupId!);
        m.maximize(m.focusedGroupId!);
        expect(m.root, same(tree));
        m.moveTab(tabs[2].id, m.groupOf(tabs[1].id)!.id);
        m.selectTab(tabs[1].id);
        expect(m.focus, same(sessions[1]));
        expect(m.focus!.draft, '中文 draft');
        expect(m.focus!.path, '/tmp/B');
        m.mergeGroups();
        expect(m.layoutGroups.single.tabs, hasLength(3));
        expect(m.focus, same(sessions[1]));
        m.closeTab(tabs[0].id);
        expect(m.sessions, orderedEquals(sessions.skip(1)));
        expect(sessions[1].connectionGeneration, 1);
        consistent(m);
        m.dispose();
      },
    );
  }
  test('last-tab move prunes nested empty groups; disconnect, reconnect and close are distinct', () {
    final m = WorkbenchModel()..demo();
    final a = m.tabs[0], b = m.tabs[1], c = m.tabs[2];
    m.moveTab(b.id, m.focusedGroupId!, placement: TabPlacement.right);
    m.moveTab(c.id, m.groupOf(b.id)!.id, placement: TabPlacement.bottom);
    expect(m.layoutGroups, hasLength(3));
    final session = m.session(b);
    m.setDisconnected(b.id, true);
    expect(m.session(b), same(session));
    expect(m.tabs, hasLength(3));
    m.setDisconnected(b.id, false);
    expect(session.connectionGeneration, 2);
    m.moveTab(b.id, m.groupOf(a.id)!.id);
    expect(m.layoutGroups, hasLength(2));
    m.closeTab(c.id);
    expect(m.layoutGroups, hasLength(1));
    expect(m.tabs, hasLength(2));
    m.moveTab(a.id, 'unknown');
    m.moveTab('unknown', m.focusedGroupId!);
    m.closeTab(a.id);
    m.moveTab(b.id, m.focusedGroupId!, placement: TabPlacement.right);
    expect(m.layoutGroups, hasLength(1));
    m.closeTab(b.id);
    consistent(m);
    expect(m.startPage, true);
    m.dispose();
  });
  test('focused session owns SFTP/queue; sidebar geometry survives moves and focus changes', () {
    final m = WorkbenchModel()..demo();
    final a = m.tabs.first, b = m.tabs[1];
    m.allTasks = false;
    m.sidebar = false;
    m.sidebarWidth = 411;
    m.queueHeight = 267;
    m.session(b).path = '/srv/B';
    m.moveTab(b.id, m.focusedGroupId!, placement: TabPlacement.right);
    expect(m.focus!.path, '/srv/B');
    expect(m.visibleTransfers, isEmpty);
    m.selectTab(a.id);
    expect(m.visibleTransfers, hasLength(6));
    m.mergeGroups();
    expect(m.sidebar, false);
    expect(m.sidebarWidth, 411);
    expect(m.queueHeight, 267);
    consistent(m);
    m.dispose();
  });
  test(
    '500 deterministic mixed operations keep one tab and one owner per session',
    () {
      final m = WorkbenchModel()..demo(), random = Random(3127);
      final identities = {for (final s in m.sessions) s.id: s};
      for (var i = 0; i < 500; i++) {
        if (m.tabs.length < 2 || random.nextInt(10) == 0) {
          m.openHost(m.hosts[random.nextInt(m.hosts.length)]);
          identities[m.focus!.id] = m.focus!;
        } else {
          final t = m.tabs[random.nextInt(m.tabs.length)],
              g = m.layoutGroups[random.nextInt(m.layoutGroups.length)];
          switch (random.nextInt(7)) {
            case 0:
              m.closeTab(t.id);
            case 1:
              m.mergeGroups();
            case 2:
              m.togglePin(t.id);
            case 3:
              m.maximize(g.id);
            case 4:
              m.selectTab(t.id);
            case 5:
              m.moveTab(t.id, g.id, beforeTabId: g.tabs.first.id);
            case 6:
              m.moveTab(
                t.id,
                g.id,
                placement: TabPlacement
                    .values[random.nextInt(TabPlacement.values.length)],
              );
          }
        }
        consistent(m);
        for (final s in m.sessions) {
          expect(s, same(identities[s.id]));
          expect(s.connectionGeneration, 1);
        }
      }
      m.dispose();
    },
  );
  testWidgets(
    'normal tabs show one session and keep draft across view reconstruction',
    (tester) async {
      final m = WorkbenchModel()..demo();
      await mount(tester, m);
      final a = m.tabs.first, b = m.tabs[1], session = m.session(a);
      expect(find.byKey(ValueKey('preview-${session.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('preview-${m.session(b).id}')), findsNothing);
      await tester.enterText(
        find.byKey(ValueKey('mock-input-${session.id}')),
        '中文 A',
      );
      await tester.tap(find.byKey(ValueKey('tab-${b.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('preview-${session.id}')), findsNothing);
      await tester.tap(find.byKey(ValueKey('tab-${a.id}')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(ValueKey('mock-input-${session.id}')))
            .controller!
            .text,
        '中文 A',
      );
      expect(m.session(a), same(session));
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'actual drags split at edge, move between groups, switch, maximize and recombine',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final a = m.tabs.first,
          b = m.tabs[1],
          c = m.tabs.last,
          initial = m.focusedGroupId!;
      final identities = m.sessions;
      await mount(tester, m);
      var rect = tester.getRect(
        find.byKey(ValueKey('terminal-group-$initial')),
      );
      await dragTab(tester, b.id, Offset(rect.right - 12, rect.center.dy));
      expect(m.tabGroups, hasLength(2));
      final right = m.groupOf(b.id)!.id;
      expect(
        find.byKey(ValueKey('preview-${m.session(a).id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('preview-${m.session(b).id}')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('preview-${m.session(c).id}')), findsNothing);
      rect = tester.getRect(find.byKey(ValueKey('terminal-group-$right')));
      await dragTab(tester, c.id, rect.center);
      expect(m.groupOf(c.id)!.id, right);
      expect(m.focus, same(m.session(c)));
      expect(find.byKey(ValueKey('preview-${m.session(b).id}')), findsNothing);
      await tester.tap(find.byKey(ValueKey('tab-${b.id}')));
      await tester.pumpAndSettle();
      expect(m.focus, same(m.session(b)));
      final tree = m.root;
      await tester.tap(find.byKey(ValueKey('maximize-$right')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('preview-${m.session(a).id}')), findsNothing);
      await tester.tap(find.text('恢复布局'));
      await tester.pumpAndSettle();
      expect(m.root, same(tree));
      final left = tester.getRect(
        find.byKey(ValueKey('terminal-group-$initial')),
      );
      await dragTab(tester, c.id, left.center);
      await dragTab(tester, b.id, left.center);
      expect(m.tabGroups, hasLength(1));
      expect(m.sessions, orderedEquals(identities));
      for (final t in [a, b, c]) {
        expect(find.byKey(ValueKey('tab-${t.id}')), findsOneWidget);
      }
      expect(
        find.byKey(ValueKey('preview-${m.session(b).id}')),
        findsOneWidget,
      );
      consistent(m);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'overflow navigation reveals selected tab after scrolling and regrouping',
    (tester) async {
      final m = WorkbenchModel();
      for (var i = 0; i < 24; i++) {
        m.openHost(m.hosts.first);
        m.tabs.last.name = 'Terminal $i';
      }
      await mount(tester, m);
      void visible(String id) {
        final tab = find.byKey(ValueKey('tab-$id'));
        final viewport = find
            .ancestor(of: tab, matching: find.byType(SingleChildScrollView))
            .first;
        final rect = tester.getRect(viewport), center = tester.getCenter(tab);
        expect(center.dx, inInclusiveRange(rect.left, rect.right));
      }

      visible(m.tabs.last.id);
      m.selectTab(m.tabs.first.id);
      await tester.pumpAndSettle();
      visible(m.tabs.first.id);
      await tester.tap(
        find.byKey(ValueKey('tab-overflow-${m.focusedGroupId}')),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Terminal 23').last,
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Terminal 23').last);
      await tester.pumpAndSettle();
      visible(m.tabs.last.id);
      final last = m.tabs.last;
      m.moveTab(last.id, m.focusedGroupId!, placement: TabPlacement.right);
      await tester.pumpAndSettle();
      m.moveTab(m.tabs.first.id, m.groupOf(last.id)!.id);
      await tester.pumpAndSettle();
      visible(m.focusedGroup!.selectedId);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'menu renames, pins, disconnects/reconnects; closing affects one session',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final t = m.tabs.first, session = m.session(t);
      await mount(tester, m);
      Future<void> menu(String text) async {
        await tester.tapAt(
          tester.getCenter(find.byKey(ValueKey('tab-${t.id}'))),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(text));
        await tester.pumpAndSettle();
      }

      await menu('重命名终端');
      await tester.enterText(find.byType(TextField).last, '专用终端 A');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(t.name, '专用终端 A');
      await menu('固定标签');
      expect(t.pinned, true);
      await menu('断开连接 · 保留标签');
      expect(session.disconnected, true);
      expect(m.sessions, hasLength(3));
      await menu('手动重新连接 · 模拟');
      expect(session.disconnected, false);
      expect(session.connectionGeneration, 2);
      await menu('关闭终端标签');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(m.sessions, hasLength(3));
      await menu('关闭终端标签');
      await tester.tap(find.text('关闭终端'));
      await tester.pumpAndSettle();
      expect(m.sessions, hasLength(2));
      consistent(m);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
}
