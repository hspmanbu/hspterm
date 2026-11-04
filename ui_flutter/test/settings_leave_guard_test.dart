import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/app.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/prototype/settings.dart';
import 'package:hspterm/prototype/settings_leave.dart';

class _DraftEditor extends StatefulWidget {
  const _DraftEditor();
  @override
  State<_DraftEditor> createState() => _DraftEditorState();
}

class _DraftEditorState extends State<_DraftEditor> {
  bool dirty = false;
  @override
  Widget build(BuildContext context) =>
      Column(
        children: [
          TextField(
            key: const ValueKey('fixture-draft'),
            onChanged: (_) => setState(() => dirty = true),
          ),
          TextButton(
            onPressed: () => setState(() => dirty = false),
            child: const Text('save-fixture'),
          ),
        ],
      ).guardSettings(
        label: 'Fixture',
        dirty: () => dirty,
        busy: () => false,
        apply: () async => setState(() => dirty = false),
      );
}

void main() {
  testWidgets(
    'an unavailable source after a failed acknowledgement cannot silently pass a second Apply',
    (tester) async {
      final registry = SettingsLeaveRegistry();
      var dirty = true, confirmed = false, attempts = 0;
      final owner = Object();
      registry.register(
        owner,
        'receipt',
        () => dirty,
        () => false,
        apply: () async {
          attempts++;
          dirty = false;
        },
        confirmed: () => confirmed,
      );
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(await registry.applyAll(context), false);
      expect(await registry.applyAll(context), false);
      expect(attempts, 2);
      confirmed = true;
      expect(await registry.applyAll(context), true);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Apply leaves failed drafts open and never repeats an acknowledged save',
    (tester) async {
      final registry = SettingsLeaveRegistry();
      var first = true, second = true, writes = 0;
      final one = Object(), two = Object();
      registry.register(
        one,
        'first',
        () => first,
        () => false,
        category: '外观',
        apply: () async {
          writes++;
          first = false;
        },
      );
      registry.register(
        two,
        'second',
        () => second,
        () => false,
        category: 'SSH 连接',
        apply: () async {},
      );
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(await registry.applyAll(context), false);
      expect(registry.failedCategory, 'SSH 连接');
      expect(writes, 1);
      registry.register(
        two,
        'second',
        () => second,
        () => false,
        category: 'SSH 连接',
        apply: () async {
          second = false;
        },
      );
      expect(await registry.applyAll(context), true);
      expect(writes, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Cancel discards local drafts and OK applies before leaving settings',
    (tester) async {
      final model = WorkbenchModel()..show(WorkPage.settings);
      await tester.pumpWidget(
        PrototypeApp(
          model: model,
          displaySettingsBuilder: (_) => const _DraftEditor(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-彩色高亮')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('fixture-draft')),
        'cancel fixture',
      );
      await tester.tap(find.byKey(const ValueKey('settings-cancel')));
      await tester.pumpAndSettle();
      expect(model.page, WorkPage.workspace);
      expect(find.byType(AlertDialog), findsNothing);
      model.show(WorkPage.settings);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-彩色高亮')));
      await tester.pumpAndSettle();
      expect(find.text('cancel fixture'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('fixture-draft')),
        'ok fixture',
      );
      await tester.tap(find.byKey(const ValueKey('settings-ok')));
      await tester.pumpAndSettle();
      expect(model.page, WorkPage.workspace);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'category changes retain drafts and common Apply saves hidden editors',
    (tester) async {
      final model = WorkbenchModel();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              model: model,
              initialCategory: '彩色高亮',
              displaySettingsBuilder: (_) => const _DraftEditor(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('fixture-draft')),
        'unsaved fixture',
      );
      await tester.tap(find.byKey(const ValueKey('settings-快捷键')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('fixture-draft')), findsNothing);
      expect(
        find.byKey(const ValueKey('fixture-draft'), skipOffstage: false),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('settings-彩色高亮')));
      await tester.pumpAndSettle();
      expect(find.text('unsaved fixture'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-快捷键')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-apply')));
      await tester.pumpAndSettle();
      final key = tester.state<SettingsPageState>(find.byType(SettingsPage));
      expect(await key.canLeave(), true);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'whole settings page cannot bypass the same guard by navigating to hosts',
    (tester) async {
      final model = WorkbenchModel()..show(WorkPage.settings);
      await tester.pumpWidget(
        PrototypeApp(
          model: model,
          displaySettingsBuilder: (_) => const _DraftEditor(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-彩色高亮')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('fixture-draft')),
        'unsaved fixture',
      );
      await tester.tap(find.byKey(const ValueKey('nav-hosts')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的设置？'), findsOneWidget);
      await tester.tap(find.text('返回编辑'));
      await tester.pumpAndSettle();
      expect(model.page, WorkPage.settings);
      await tester.tap(find.text('save-fixture'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-hosts')));
      await tester.pumpAndSettle();
      expect(model.page, WorkPage.hosts);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'an in-flight save blocks leave without offering to discard its submitted mutation',
    (tester) async {
      final registry = SettingsLeaveRegistry();
      bool busy = true;
      bool? allowed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsLeaveScope(
              registry: registry,
              child: Builder(
                builder: (context) => Column(
                  children: [
                    const SizedBox().guardSettings(
                      label: 'Fixture',
                      dirty: () => false,
                      busy: () => busy,
                    ),
                    TextButton(
                      onPressed: () async {
                        allowed = await registry.canLeave(context);
                      },
                      child: const Text('leave'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      expect(allowed, false);
      expect(find.byType(AlertDialog), findsNothing);
      busy = false;
      await tester.tap(find.text('leave'));
      await tester.pumpAndSettle();
      expect(allowed, true);
    },
  );
  testWidgets(
    'notification-style activation respects drafts before selecting its original tab',
    (tester) async {
      final model = WorkbenchModel();
      model.openHost(model.hosts.first);
      final target = model.tabs.single.id;
      model.show(WorkPage.settings);
      final key = GlobalKey<PrototypeAppState>();
      await tester.pumpWidget(
        PrototypeApp(
          key: key,
          model: model,
          displaySettingsBuilder: (_) => const _DraftEditor(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-彩色高亮')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('fixture-draft')),
        'kept draft',
      );
      final cancelled = key.currentState!.activateTab(target);
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回编辑'));
      await tester.pumpAndSettle();
      expect(await cancelled, false);
      expect(model.page, WorkPage.settings);
      expect(find.text('kept draft'), findsOneWidget);
      final accepted = key.currentState!.activateTab(target);
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃并离开'));
      await tester.pumpAndSettle();
      expect(await accepted, true);
      expect(model.page, WorkPage.workspace);
      expect(model.focus?.id, model.tabById(target)?.sessionId);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'a tab closed during the draft decision cannot consume navigation',
    (tester) async {
      final model = WorkbenchModel();
      model.openHost(model.hosts.first);
      final target = model.tabs.single.id;
      model.show(WorkPage.settings);
      final key = GlobalKey<PrototypeAppState>();
      await tester.pumpWidget(
        PrototypeApp(
          key: key,
          model: model,
          displaySettingsBuilder: (_) => const _DraftEditor(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-彩色高亮')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('fixture-draft')),
        'still here',
      );
      final requested = key.currentState!.activateTab(target);
      await tester.pumpAndSettle();
      model.closeTab(target);
      await tester.pump();
      await tester.tap(find.text('放弃并离开'));
      await tester.pumpAndSettle();
      expect(await requested, false);
      expect(model.page, WorkPage.settings);
      expect(find.text('still here'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'external category requests preserve pending drafts without prompting',
    (tester) async {
      final model = WorkbenchModel();
      final key = GlobalKey<SettingsPageState>();
      Widget page(String category) => MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            key: key,
            model: model,
            initialCategory: category,
            displaySettingsBuilder: (_) => const _DraftEditor(),
          ),
        ),
      );
      await tester.pumpWidget(page('彩色高亮'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('fixture-draft')),
        'external draft',
      );
      await tester.pumpWidget(page('外观'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('settings-content-外观')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-彩色高亮')));
      await tester.pumpAndSettle();
      expect(find.text('external draft'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
