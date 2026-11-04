import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/src/rust/forwardings.dart';
import 'package:hspterm/src/rust/forwardings/runtime.dart';
import 'package:hspterm/workbench/forwarding_dialog.dart';

RuleConfig config({
  String id = 'r1',
  String name = 'Local test',
  String kind = 'local',
}) => RuleConfig(
  id: id,
  name: name,
  kind: kind,
  bindAddress: '127.0.0.1',
  bindPort: 0,
  targetAddress: kind == 'dynamic' ? null : '127.0.0.1',
  targetPort: kind == 'dynamic' ? null : 8080,
  enabled: true,
  restoreOnReconnect: false,
);

class FakeGateway implements ForwardingGateway {
  List<RuleConfig> rules = [config()];
  final runs = <RunStatus>[];
  bool failLoad = false, failSave = false;
  final starts = <(int, int, String)>[], stops = <(int, int, String)>[];
  int saved = 0, queries = 0;
  Future<void>? listWait;
  RuleDraft _draft = const RuleDraft(revision: 0, fields: null);
  bool failDraft = false;
  @override
  Future<RuleDraft> draft(String host) async => _draft;
  @override
  Future<RuleDraft> saveDraft(
    String host,
    int revision,
    DraftFields? fields,
  ) async {
    if (failDraft) throw StateError('synthetic draft failure');
    if (_draft.revision != revision) throw StateError('stale draft');
    return _draft = RuleDraft(revision: revision + 1, fields: fields);
  }

  @override
  Future<List<RuleConfig>> commitDraft(String host, int revision) async {
    if (_draft.revision != revision) throw StateError('stale draft');
    final f = _draft.fields!;
    final rule = RuleConfig(
      id: f.original?.id ?? '',
      name: f.name,
      kind: f.kind,
      bindAddress: f.bindAddress,
      bindPort: int.parse(f.bindPort),
      targetAddress: f.kind == 'dynamic' ? null : f.targetAddress,
      targetPort: f.kind == 'dynamic' ? null : int.parse(f.targetPort),
      enabled: f.enabled,
      restoreOnReconnect: f.restoreOnReconnect,
    );
    final saved = await save(host, [
      for (final r in rules)
        if (r.id != f.original?.id) r,
      rule,
    ]);
    await saveDraft(host, revision, null);
    return saved;
  }

  @override
  Future<List<RuleConfig>> load(String host) async {
    if (failLoad) throw StateError('synthetic read failure');
    return rules;
  }

  @override
  Future<List<RuleConfig>> save(String host, List<RuleConfig> values) async {
    if (failSave) throw StateError('synthetic save failure');
    saved++;
    rules = [
      for (final r in values)
        RuleConfig(
          id: r.id.isEmpty ? 'r$saved' : r.id,
          name: r.name,
          kind: r.kind,
          bindAddress: r.bindAddress,
          bindPort: r.bindPort,
          targetAddress: r.targetAddress,
          targetPort: r.targetPort,
          enabled: r.enabled,
          restoreOnReconnect: r.restoreOnReconnect,
        ),
    ];
    return rules;
  }

  @override
  Future<List<RunStatus>> list(ForwardingSession session) async {
    queries++;
    await listWait;
    return runs;
  }

  @override
  Future<RunStatus> start(ForwardingSession session, String rule) async {
    starts.add((session.id, session.generation, rule));
    final value = RunStatus(
      token: 'token-${session.id}',
      generation: session.generation,
      ruleId: rule,
      name: 'runtime survives config deletion',
      kind: 'local',
      phase: 'listening',
      bindAddress: '127.0.0.1',
      bindPort: 54321,
      accepted: 0,
      active: 0,
      failed: 0,
    );
    runs.add(value);
    return value;
  }

  @override
  Future<void> stop(ForwardingSession session, String token) async {
    stops.add((session.id, session.generation, token));
    runs.clear();
  }
}

Future<void> open(
  WidgetTester tester,
  FakeGateway gateway, {
  List<ForwardingSession> sessions = const [],
  double scale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Desk.theme(false),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ForwardingDialog(
                hostId: 'saved-host',
                hostName: 'Fixture',
                sessions: sessions,
                gateway: gateway,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'incomplete encrypted draft is retained, explicitly recovered and committed only by Save',
    (tester) async {
      final gateway = FakeGateway()..rules = [];
      await open(tester, gateway);
      await tester.tap(find.byKey(const ValueKey('forward-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('forward-name')),
        'unfinished draft',
      );
      await tester.enterText(
        find.byKey(const ValueKey('forward-target-port')),
        'incomplete',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(gateway._draft.fields!.targetPort, 'incomplete');
      expect(gateway.saved, 0);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保留草稿并关闭'));
      await tester.pumpAndSettle();
      expect(gateway.rules, isEmpty);
      await tester.tap(find.byKey(const ValueKey('forward-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复草稿'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('forward-target-port')),
            )
            .controller!
            .text,
        'incomplete',
      );
      await tester.enterText(
        find.byKey(const ValueKey('forward-target-port')),
        '443',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('forward-save')));
      await tester.tap(find.byKey(const ValueKey('forward-save')));
      await tester.pumpAndSettle();
      expect(gateway.saved, 1);
      expect(gateway.rules.single.name, 'unfinished draft');
      expect(gateway._draft.fields, isNull);
      expect(gateway.starts, isEmpty);
    },
  );
  testWidgets(
    'a draft persistence failure keeps the editor and blocks formal Save until retry succeeds',
    (tester) async {
      final gateway = FakeGateway()..failDraft = true;
      await open(tester, gateway);
      await tester.tap(find.byTooltip('编辑规则'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('forward-name')),
        'changed name',
      );
      final save = find.byKey(const ValueKey('forward-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.textContaining('synthetic draft failure'), findsOneWidget);
      expect(gateway.saved, 0);
      expect(save, findsOneWidget);
      gateway.failDraft = false;
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(gateway.saved, 1);
      expect(gateway.rules.single.name, 'changed name');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'configuration read failure cannot overwrite saved rules with empty defaults',
    (tester) async {
      final gateway = FakeGateway()..failLoad = true;
      await open(tester, gateway);
      expect(find.textContaining('synthetic read failure'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('forward-add')))
            .onPressed,
        isNull,
      );
      gateway.failLoad = false;
      await tester.tap(find.byTooltip('刷新状态'));
      await tester.pumpAndSettle();
      expect(find.text('本地 L · Local test'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const ValueKey('forward-add')))
            .onPressed,
        isNotNull,
      );
      expect(gateway.saved, 0);
    },
  );
  testWidgets(
    'an explicit selected terminal keeps runtime stop available after config deletion',
    (tester) async {
      final gateway = FakeGateway();
      await open(
        tester,
        gateway,
        sessions: const [
          ForwardingSession(11, 3, '终端 A'),
          ForwardingSession(22, 7, '终端 B'),
        ],
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('forward-start-r1')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('forward-session')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('终端 B').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forward-start-r1')));
      await tester.pumpAndSettle();
      expect(gateway.starts, [(22, 7, 'r1')]);
      await tester.ensureVisible(find.byTooltip('删除规则'));
      await tester.tap(find.byTooltip('删除规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除规则'));
      await tester.pumpAndSettle();
      expect(gateway.rules, isEmpty);
      final stop = find.byKey(const ValueKey('forward-stop-token-22'));
      await tester.ensureVisible(stop);
      await tester.tap(stop);
      await tester.pumpAndSettle();
      expect(gateway.stops, [(22, 7, 'token-22')]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unreadable or deleted saved config does not hide stop for its live instance',
    (tester) async {
      final gateway = FakeGateway()..failLoad = true;
      const session = ForwardingSession(11, 3, '原终端');
      await gateway.start(session, 'r1');
      await open(tester, gateway, sessions: const [session]);
      final stop = find.byKey(const ValueKey('forward-stop-token-11'));
      await tester.ensureVisible(stop);
      await tester.tap(stop);
      await tester.pumpAndSettle();
      expect(gateway.stops, [(11, 3, 'token-11')]);
      expect(gateway.saved, 0);
    },
  );
  testWidgets(
    'connection lifecycle changes disable stale starts without polling on ordinary UI notifications',
    (tester) async {
      final gateway = FakeGateway();
      final changes = ChangeNotifier();
      var current = true;
      final source = ForwardingSession(
        11,
        3,
        'fixed',
        changes: changes,
        isCurrent: () => current,
      );
      await gateway.start(source, 'r1');
      await open(tester, gateway, sessions: [source]);
      final reads = gateway.queries;
      for (var i = 0; i < 100; i++) {
        changes.notifyListeners();
      }
      await tester.pump();
      expect(gateway.queries, reads);
      current = false;
      changes.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.textContaining('原连接已断开'), findsOneWidget);
      final start = find.byKey(const ValueKey('forward-start-r1'));
      await tester.ensureVisible(start);
      expect(tester.widget<OutlinedButton>(start).onPressed, isNull);
      final stopped = find.byKey(const ValueKey('forward-stop-token-11'));
      await tester.ensureVisible(stopped);
      expect(tester.widget<TextButton>(stopped).onPressed, isNull);
      final after = gateway.queries;
      await tester.pump(const Duration(seconds: 5));
      expect(gateway.queries, after);
      await tester.pumpWidget(const SizedBox.shrink());
      changes.dispose();
    },
  );
  testWidgets(
    'metadata notifications coalesce in flight and stop observing when the dialog closes',
    (tester) async {
      final gateway = FakeGateway();
      final updates = ChangeNotifier();
      final source = ForwardingSession(11, 3, 'fixed', updates: updates);
      await open(tester, gateway, sessions: [source]);
      final before = gateway.queries;
      final gate = Completer<void>();
      gateway.listWait = gate.future;
      updates.notifyListeners();
      await tester.pump();
      expect(gateway.queries, before + 1);
      for (var i = 0; i < 100; i++) {
        updates.notifyListeners();
      }
      await gateway.start(source, 'r1');
      gate.complete();
      await tester.pumpAndSettle();
      expect(gateway.queries, before + 2);
      expect(
        find.textContaining('runtime survives config deletion'),
        findsOneWidget,
      );
      final idle = gateway.queries;
      await tester.pump(const Duration(seconds: 5));
      expect(gateway.queries, idle);
      await tester.pumpWidget(const SizedBox.shrink());
      updates.notifyListeners();
      await tester.pump();
      expect(gateway.queries, idle);
      updates.dispose();
    },
  );
  testWidgets(
    'editor validates fields and saves actual rule data without starting anything',
    (tester) async {
      final gateway = FakeGateway()..rules = [];
      await open(tester, gateway);
      await tester.tap(find.byKey(const ValueKey('forward-add')));
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('forward-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(gateway.saved, 0);
      await tester.enterText(
        find.byKey(const ValueKey('forward-name')),
        '私有服务',
      );
      await tester.enterText(
        find.byKey(const ValueKey('forward-port')),
        '65536',
      );
      await tester.enterText(
        find.byKey(const ValueKey('forward-target-port')),
        '80',
      );
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('端口范围 0–65535'), findsOneWidget);
      expect(gateway.saved, 0);
      await tester.enterText(find.byKey(const ValueKey('forward-port')), '0');
      final restore = find.byKey(const ValueKey('forward-restore'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(gateway.rules.single.name, '私有服务');
      expect(gateway.rules.single.targetPort, 80);
      expect(gateway.rules.single.restoreOnReconnect, true);
      expect(gateway.starts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'restoring a non-loopback listener requires explicit informed consent before saving',
    (tester) async {
      final gateway = FakeGateway();
      await open(tester, gateway);
      await tester.tap(find.byTooltip('编辑规则'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('forward-bind')),
        '0.0.0.0',
      );
      final restore = find.byKey(const ValueKey('forward-restore'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('forward-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('允许重连后恢复非回环监听？'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(gateway.saved, 0);
      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许并保存'));
      await tester.pumpAndSettle();
      expect(gateway.saved, 1);
      expect(gateway.rules.single.restoreOnReconnect, true);
      expect(gateway.rules.single.bindAddress, '0.0.0.0');
      expect(gateway.starts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'small window and increased text scale stay scrollable without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = FakeGateway();
      await open(tester, gateway, scale: 1.6);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const ValueKey('forward-add')));
      await tester.tap(find.byKey(const ValueKey('forward-add')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
