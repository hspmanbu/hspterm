import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/agents.dart';
import 'package:hspterm/workbench/agent_dialog.dart';

class Updates extends ValueNotifier<int> {
  Updates() : super(0);
  bool get observing => hasListeners;
}

AgentView fixtureState(String phase) => AgentView(
  phase: phase,
  epoch: '0',
  keyCount: phase == 'Active' ? 1 : 0,
  expiresUnixMillis: null,
  failedStreams: 0,
);
const key = AgentKeyOption(
  hostId: 'host-key',
  name: '所选测试密钥',
  fingerprint: null,
);

class Gateway implements AgentGateway {
  AgentView value = fixtureState('Ready');
  bool keysFail = false, keysEmpty = false;
  int reads = 0, prepared = 0, approvals = 0, cancelled = 0, revoked = 0;
  List<String>? selected;
  AgentSession? original;
  Completer<AgentPreview>? preparing;
  @override
  Future<AgentView> state(AgentSession source) async {
    reads++;
    return value;
  }

  @override
  Future<List<AgentKeyOption>> keys() async {
    if (keysFail) throw StateError('synthetic metadata failure');
    return keysEmpty ? [] : [key];
  }

  AgentPreview preview() => const AgentPreview(
    ticket: 'preview-original',
    target: 'fixture@127.0.0.1:22',
    hostKey: 'SHA256:synthetic-host',
    seconds: 300,
    keys: [
      AgentKeyOption(
        hostId: 'host-key',
        name: '所选测试密钥',
        fingerprint: 'SHA256:synthetic-selected-key',
      ),
    ],
  );
  @override
  Future<AgentPreview> prepare(
    AgentSession source,
    List<String> hosts,
    int seconds,
  ) async {
    prepared++;
    original = source;
    selected = hosts;
    return preparing?.future ?? Future.value(preview());
  }

  @override
  Future<AgentView> approve(AgentSession source, String ticket) async {
    approvals++;
    expect(ticket, 'preview-original');
    expect(identical(source, original), true);
    return value = fixtureState('Active');
  }

  @override
  Future<void> cancel(AgentSession source, String ticket) async {
    cancelled++;
  }

  @override
  Future<AgentView> revoke(AgentSession source) async {
    revoked++;
    return value = fixtureState('Revoked');
  }
}

Future<void> open(
  WidgetTester tester,
  Gateway gateway,
  AgentSession source,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AgentDialog(source: source, gateway: gateway),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> preview(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('agent-key-host-key')));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('agent-prepare')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'empty general Agent key list does not require keys for password direct copy',
    (tester) async {
      final gateway = Gateway()..keysEmpty = true;
      await open(
        tester,
        gateway,
        AgentSession(7, 9, '密码会话', current: () => true),
      );
      expect(
        find.byKey(const ValueKey('agent-direct-copy-help')),
        findsOneWidget,
      );
      expect(find.textContaining('此状态不影响使用已保存密码直传'), findsOneWidget);
      expect(gateway.prepared, 0);
      expect(gateway.approvals, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'explicit selection, risk confirmation and original target are required; closing does not revoke',
    (tester) async {
      final gateway = Gateway();
      final source = AgentSession(7, 9, '原终端', current: () => true);
      await open(tester, gateway, source);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('agent-prepare')))
            .onPressed,
        isNull,
      );
      await preview(tester);
      expect(gateway.selected, ['host-key']);
      expect(gateway.approvals, 0);
      expect(find.textContaining('fixture@127.0.0.1:22'), findsOneWidget);
      expect(
        find.textContaining('SHA256:synthetic-selected-key'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('agent-confirm')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('我信任上述目标，并允许本次限时签名'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('agent-confirm')));
      await tester.pumpAndSettle();
      expect(gateway.approvals, 1);
      expect(gateway.revoked, 0);
      expect(find.text('限时授权中'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(gateway.revoked, 0);
    },
  );
  testWidgets(
    'cancel and original lifecycle changes never authorize another session',
    (tester) async {
      var current = true;
      final lifecycle = ValueNotifier(0);
      final gateway = Gateway();
      final source = AgentSession(
        7,
        9,
        '原终端',
        current: () => current,
        lifecycle: lifecycle,
      );
      await open(tester, gateway, source);
      await preview(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(gateway.cancelled, 1);
      expect(gateway.approvals, 0);
      await tester.tap(find.byKey(const ValueKey('agent-prepare')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我信任上述目标，并允许本次限时签名'));
      current = false;
      lifecycle.value++;
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('agent-confirm')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(gateway.approvals, 0);
      expect(find.textContaining('不会授权到其他会话'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      lifecycle.dispose();
    },
  );
  testWidgets(
    'key-list failure keeps active grant revocable and idle metadata has no polling',
    (tester) async {
      final updates = Updates();
      final lifecycle = Updates();
      final gateway = Gateway()
        ..value = fixtureState('Active')
        ..keysFail = true;
      final source = AgentSession(
        7,
        9,
        '原终端',
        current: () => true,
        updates: updates,
        lifecycle: lifecycle,
      );
      await open(tester, gateway, source);
      expect(find.text('限时授权中'), findsOneWidget);
      expect(find.textContaining('synthetic metadata failure'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('agent-revoke')))
            .onPressed,
        isNotNull,
      );
      final reads = gateway.reads;
      await tester.pump(const Duration(seconds: 10));
      for (var frame = 0; frame < 100; frame++) {
        lifecycle.value++;
      }
      await tester.pump();
      expect(
        gateway.reads,
        reads,
        reason: 'painting notifications must not query native metadata',
      );
      await tester.tap(find.byKey(const ValueKey('agent-revoke')));
      await tester.pumpAndSettle();
      expect(gateway.revoked, 1);
      gateway.keysFail = false;
      updates.value++;
      await tester.pumpAndSettle();
      expect(gateway.reads, greaterThan(reads));
      await tester.pumpWidget(const SizedBox());
      expect(updates.observing, false);
      expect(lifecycle.observing, false);
      updates.dispose();
      lifecycle.dispose();
    },
  );
  testWidgets(
    'default-off cannot authorize, and late prepare is cancelled after dialog disposal',
    (tester) async {
      final gateway = Gateway()..value = fixtureState('NotRequested');
      final source = AgentSession(7, 9, '原终端', current: () => true);
      await open(tester, gateway, source);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('agent-key-host-key')),
            )
            .onChanged,
        isNull,
      );
      gateway.value = fixtureState('Ready');
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      gateway.preparing = Completer<AgentPreview>();
      await tester.tap(find.byKey(const ValueKey('agent-key-host-key')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('agent-prepare')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      gateway.preparing!.complete(gateway.preview());
      await tester.pump();
      expect(gateway.approvals, 0);
      expect(gateway.cancelled, 1);
    },
  );
}
