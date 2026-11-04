import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/command_palette.dart';
import 'package:hspterm/prototype/app.dart';
import 'package:hspterm/prototype/model.dart';

Future<void> _open(
  WidgetTester tester,
  List<AppCommand> commands,
  RecentAppCommands recent,
  List<AppCommand> selected, {
  Listenable? changes,
}) async {
  final notifier = changes ?? ChangeNotifier();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          child: const Text('open'),
          onPressed: () async {
            final command = await showAppCommandPalette(
              context,
              commands: commands,
              recent: recent,
              changes: notifier,
            );
            if (command != null && command.allowed) {
              selected.add(command);
              recent.record(command.id);
              await command.run();
            }
          },
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder key(String id) => find.byKey(ValueKey('app-command-$id'));
void main() {
  test(
    'recent IDs are bounded, unique and never store arbitrary query or labels',
    () {
      final recent = RecentAppCommands();
      for (var i = 0; i < 10; i++) {
        recent.record('operation-$i');
      }
      recent.record('operation-8');
      recent.record('输入秘密 text');
      expect(recent.ids, [
        'operation-8',
        'operation-9',
        'operation-7',
        'operation-6',
        'operation-5',
        'operation-4',
        'operation-3',
        'operation-2',
      ]);
      final commands = [
        AppCommand('operation-2', '主机管理', () {}),
        AppCommand('operation-8', 'Terminal SSH 搜索', () {}),
        AppCommand('hidden', '不可执行', () {}, available: () => false),
      ];
      expect(recent.visible(commands, '').map((c) => c.id), [
        'operation-8',
        'operation-2',
      ]);
      expect(recent.visible(commands, 'ssh').single.id, 'operation-8');
      expect(recent.visible(commands, '主机').single.id, 'operation-2');
    },
  );
  testWidgets(
    'arrow navigation, Enter selection, recent ranking and Escape invoke only selected application action',
    (tester) async {
      final recent = RecentAppCommands(),
          selected = <AppCommand>[],
          invoked = <String>[];
      final commands = [
        for (var i = 0; i < 3; i++)
          AppCommand('op-$i', '操作 $i', () => invoked.add('op-$i')),
      ];
      await _open(tester, commands, recent, selected);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(tester.widget<ListTile>(key('op-1')).selected, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(invoked, ['op-1']);
      expect(selected.single.id, 'op-1');
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(key('op-1')).selected, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(tester.widget<ListTile>(key('op-2')).selected, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(invoked, ['op-1']);
      expect(recent.ids, ['op-1']);
    },
  );
  testWidgets(
    'Chinese search resets selection and unavailable original actions cannot be chosen late',
    (tester) async {
      final changes = ChangeNotifier(),
          selected = <AppCommand>[],
          recent = RecentAppCommands();
      var allowed = true, runs = 0;
      await _open(
        tester,
        [
          AppCommand('search', '终端搜索', () => runs++, available: () => allowed),
          AppCommand('settings', '设置与字体', () => runs++),
        ],
        recent,
        selected,
        changes: changes,
      );
      await tester.enterText(key('query'), '终端');
      await tester.pumpAndSettle();
      expect(key('settings'), findsNothing);
      expect(tester.binding.hasScheduledFrame, false);
      for (var i = 0; i < 100; i++) {
        changes.notifyListeners();
      }
      expect(tester.binding.hasScheduledFrame, false);
      allowed = false;
      changes.notifyListeners();
      await tester.pumpAndSettle();
      expect(key('search'), findsNothing);
      expect(find.text('没有可用的匹配操作'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(runs, 0);
      expect(selected, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      changes.dispose();
    },
  );
  testWidgets('IME composing arrows and Enter never invoke actions', (
    tester,
  ) async {
    final selected = <AppCommand>[];
    await _open(
      tester,
      [AppCommand('a', '操作 A', () {}), AppCommand('b', '操作 B', () {})],
      RecentAppCommands(),
      selected,
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '操作',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selected, isEmpty);
    expect(find.byType(AppCommandPalette), findsOneWidget);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '操作',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected.single.id, 'b');
  });
  testWidgets(
    'keyboard navigation reveals virtual rows and small scaled layout does not overflow',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(800, 960);
      tester.view.devicePixelRatio = 2;
      final selected = <AppCommand>[];
      await _open(
        tester,
        [for (var i = 0; i < 40; i++) AppCommand('op-$i', '操作 $i', () {})],
        RecentAppCommands(),
        selected,
      );
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(key('op-20').hitTestable(), findsOneWidget);
      expect(tester.widget<ListTile>(key('op-20')).selected, true);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'barrier dismissal rejects late callbacks without popping the application page',
    (tester) async {
      final selected = <AppCommand>[];
      await _open(
        tester,
        [AppCommand('late', '迟到操作', () {})],
        RecentAppCommands(),
        selected,
      );
      final tap = tester.widget<ListTile>(key('late')).onTap!;
      await tester.tapAt(const Offset(1, 1));
      await tester.pump();
      tap();
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(find.text('open'), findsOneWidget);
      expect(find.byType(AppCommandPalette), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'actual application panel selects hosts with keyboard and restores recents without creating sessions',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = WorkbenchModel();
      await tester.pumpWidget(PrototypeApp(model: model));
      await tester.pumpAndSettle();
      Future<void> open() async {
        await tester.tap(find.byKey(const ValueKey('app-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('应用命令面板'));
        await tester.pumpAndSettle();
      }

      await open();
      await tester.enterText(key('query'), '主机');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(model.page, WorkPage.hosts);
      expect(model.sessions, isEmpty);
      await open();
      expect(tester.widget<ListTile>(key('hosts')).selected, true);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
