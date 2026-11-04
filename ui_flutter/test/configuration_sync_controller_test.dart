import 'support/terminal_cleanup.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:hspterm/workbench/configuration_sync_reference_model.dart';
import 'package:hspterm/workbench/configuration_sync_references.dart';
import 'package:hspterm/workbench/configuration_sync.dart';

Map<String, dynamic> referenceOption() => {
  'id': 'host-${'a' * 32}',
  'label': '主机引用夹具',
  'local_available': true,
  'remote_available': true,
  'local_deleted': false,
  'remote_deleted': false,
  'winner': 'local',
  'local_group': 'group-default',
  'remote_group': 'group-default',
  'local_jump': null,
  'remote_jump': 'host-${'b' * 32}',
};

class _Gateway implements ConfigurationSyncGateway {
  final stream = StreamController<String>.broadcast(sync: true);
  int sequence = 0,
      reserves = 0,
      prepares = 0,
      confirms = 0,
      cancels = 0,
      closes = 0,
      commits = 0,
      updates = 0;
  String phase = 'idle', operation = '', review = 'review-1';
  bool risky = false, eligible = true, retry = false, references = false;
  int referenceReads = 0, resolutions = 0;
  final referenceWrites = <List<Map<String, String>>>[];
  Completer<void>? prepareGate, reserveGate;
  String snapshot() => jsonEncode({
    'owner': 'owner-fixture',
    'vault_scope': 'scope-fixture',
    'sequence': sequence,
    'eligible': eligible,
    'operation': operation.isEmpty ? null : operation,
    'phase': phase,
    'error': phase == 'cancelled' ? 'cancelled' : null,
    'commits': commits,
    'configuration_updates': updates,
    'remote_published': false,
    'write_unknown': false,
    'review': {'review', 'references'}.contains(phase)
        ? {
            'token': review,
            'endpoint': 'https://fixture.invalid/object',
            'collection': '0123456789abcdef0123456789abcdef',
            'uploads': phase != 'references',
            'references': phase == 'references',
            'summary': {
              'conflicts': risky ? 1 : 0,
              'incoming_winners': risky ? 1 : 0,
              'deleted': 0,
              'sensitive_changes': risky ? 1 : 0,
              'incoming_deletions': 0,
              'credential_changes': risky ? 1 : 0,
            },
          }
        : null,
  });
  void publish(String next) {
    phase = next;
    sequence++;
    stream.add(jsonEncode({'kind': 'state', 'value': jsonDecode(snapshot())}));
  }

  void edit({String scope = 'scope-fixture'}) => stream.add(
    jsonEncode({
      'kind': 'configurationEdited',
      'owner': 'owner-fixture',
      'vault_scope': scope,
    }),
  );
  @override
  Future<String> open() async => 'owner-fixture';
  @override
  Stream<String> events(String owner) => stream.stream;
  @override
  Future<String> status(String owner) async => snapshot();
  @override
  Future<String> reserve(String owner) async {
    reserves++;
    operation = 'operation-$reserves';
    publish('reserved');
    await reserveGate?.future;
    return operation;
  }

  @override
  Future<String> prepare(String owner, String operation) async {
    prepares++;
    publish('reading');
    await prepareGate?.future;
    if (phase != 'cancelled') publish(references ? 'references' : 'review');
    return snapshot();
  }

  @override
  Future<String> confirm(String owner, String operation, String review) async {
    confirms++;
    if (retry) {
      retry = false;
      this.review = 'review-2';
      publish('review');
    } else {
      commits++;
      publish('committed');
    }
    return snapshot();
  }

  @override
  Future<String> referenceChoices(
    String owner,
    String operation,
    String review,
  ) async {
    referenceReads++;
    return jsonEncode([referenceOption()]);
  }

  @override
  Future<String> resolveReferences(
    String owner,
    String operation,
    String review,
    List<Map<String, String>> choices,
  ) async {
    resolutions++;
    referenceWrites.add([for (final choice in choices) Map.from(choice)]);
    references = false;
    this.review = 'resolved-review-$resolutions';
    risky = true;
    publish('review');
    return snapshot();
  }

  @override
  Future<void> cancel(String owner, String operation) async {
    cancels++;
    publish('cancelled');
  }

  @override
  Future<void> close(String owner) async {
    closes++;
    await stream.close();
  }
}

class _OpenFailureGateway extends _Gateway {
  bool fail = true;
  int opens = 0;
  @override
  Future<String> open() async {
    opens++;
    if (fail) throw StateError('synthetic local metadata failure');
    return super.open();
  }
}

void main() {
  test('reference metadata rejects duplicate units and cannot carry credential payloads', () {
    expect(parseSyncReferences(jsonEncode([referenceOption()])), hasLength(1));
    expect(
      () => parseSyncReferences(
        jsonEncode([referenceOption(), referenceOption()]),
      ),
      throwsFormatException,
    );
    final secret = referenceOption()
      ..['credential'] = 'synthetic-must-not-cross-ffi';
    expect(
      () => parseSyncReferences(jsonEncode([secret])),
      throwsFormatException,
    );
  });
  test('reference repair cannot confirm directly, publishes nothing, and requires a new review', () async {
    final gateway = _Gateway()..references = true;
    final controller = ConfigurationSyncController(gateway: gateway);
    await controller.start();
    await controller.synchronize();
    final original = controller.state!;
    expect(original.phase, 'references');
    expect(original.review!.needsConsent, isTrue);
    await controller.confirm(original);
    expect(gateway.confirms, 0);
    final choices = await controller.loadReferenceChoices(original);
    expect(gateway.referenceReads, 1);
    expect(gateway.confirms, 0);
    await controller.resolveReferences(original, {choices.single.id: 'remote'});
    expect(gateway.resolutions, 1);
    expect(gateway.commits, 0);
    expect(controller.state!.phase, 'review');
    expect(controller.state!.review!.token, isNot(original.review!.token));
    await controller.confirm(original);
    expect(gateway.confirms, 0);
    await controller.confirm(controller.state!);
    expect(gateway.confirms, 1);
    await controller.shutdown();
    controller.dispose();
  });
  testWidgets(
    'reference choices are real controls and stale source disables submission',
    (tester) async {
      final gateway = _Gateway()..references = true;
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      await controller.synchronize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfigurationSyncReferencesDialog(
              controller: controller,
              original: controller.state!,
            ),
          ),
        ),
      );
      await tester.pump();
      // The real compute isolate and fake widget clock must both advance.
      for (var step = 0; step < 500 && controller.busy; step++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(controller.busy, false);
      await tester.pumpAndSettle();
      expect(find.text('主机引用夹具'), findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsOneWidget);
      expect(gateway.resolutions, 0);
      expect(gateway.confirms, 0);
      gateway.review = 'new-review';
      gateway.publish('references');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '校验选择并重新审阅'),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );

  testWidgets(
    'fixed local target can retry failed metadata startup without network or duplicate owners',
    (tester) async {
      final gateway = _OpenFailureGateway();
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      expect(controller.available, false);
      expect(controller.canRetryStart, true);
      gateway.fail = false;
      await controller.retryStart();
      await controller.retryStart();
      expect(controller.available, true);
      expect(gateway.opens, 2);
      expect(gateway.reserves, 0);
      expect(gateway.prepares, 0);
      await tester.pump(const Duration(minutes: 10));
      expect(gateway.reserves, 0);
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  test('an uncertain OAuth refresh is not reported as a completed configuration write', () {
    final gateway = _Gateway();
    final value = jsonDecode(gateway.snapshot()) as Map<String, dynamic>;
    value['phase'] = 'cancelled';
    value['error'] = 'cancelled';
    value['authorization_unknown'] = true;
    final state = ConfigurationSyncState(value);
    expect(state.authorizationUnknown, true);
    expect(state.writeUnknown, false);
    expect(syncFailureLabel(state), contains('令牌刷新结果未确认'));
    expect(state.commits, 0);
  });
  testWidgets('startup and an idle clock never synchronize persisted state', (
    tester,
  ) async {
    final gateway = _Gateway();
    final controller = ConfigurationSyncController(gateway: gateway);
    await controller.start();
    await tester.pump(const Duration(minutes: 10));
    expect(gateway.prepares, 0);
    expect(gateway.reserves, 0);
    await drainAsync(tester, controller.shutdown());
    controller.dispose();
  });
  testWidgets(
    'actual edits debounce to one exchange while a foreign scope is ignored',
    (tester) async {
      final gateway = _Gateway();
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      gateway.edit(scope: 'foreign-scope');
      await tester.pump(const Duration(seconds: 2));
      expect(gateway.prepares, 0);
      for (var i = 0; i < 20; i++) {
        gateway.edit();
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump(const Duration(milliseconds: 739));
      expect(gateway.prepares, 0);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pump();
      expect(gateway.prepares, 1);
      expect(gateway.confirms, 1);
      expect(controller.state?.phase, 'committed');
      await tester.pump(const Duration(minutes: 5));
      expect(gateway.prepares, 1);
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  testWidgets(
    'automatic credential conflicts stop at review and manual sync always reviews',
    (tester) async {
      final gateway = _Gateway()..risky = true;
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      gateway.edit();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(gateway.confirms, 0);
      expect(controller.state?.review?.needsConsent, isTrue);
      await controller.confirm(controller.state!);
      expect(gateway.confirms, 1);
      gateway.risky = false;
      await controller.synchronize();
      expect(controller.state?.phase, 'review');
      expect(gateway.confirms, 1);
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  testWidgets(
    'a changed server review cannot reuse a previously captured confirmation',
    (tester) async {
      final gateway = _Gateway()..retry = true;
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      await controller.synchronize();
      final old = controller.state!;
      await controller.confirm(old);
      expect(controller.state?.review?.token, 'review-2');
      await controller.confirm(old);
      expect(gateway.confirms, 1);
      await controller.confirm(controller.state!);
      expect(gateway.confirms, 2);
      expect(controller.state?.phase, 'committed');
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  testWidgets(
    'shutdown cancels then waits for the actual pending worker before closing the stream',
    (tester) async {
      final gateway = _Gateway()..prepareGate = Completer<void>();
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      final work = controller.synchronize();
      await tester.pump();
      expect(gateway.prepares, 1);
      var closed = false;
      final shutdown = controller.shutdown().then((_) => closed = true);
      await tester.pump();
      expect(closed, isFalse);
      expect(gateway.cancels, 1);
      expect(gateway.closes, 0);
      gateway.prepareGate!.complete();
      await tester.pump();
      await work;
      await drainAsync(tester, shutdown);
      expect(closed, isTrue);
      expect(gateway.closes, 1);
      controller.dispose();
    },
  );
  testWidgets(
    'disabling the target cancels pending automatic work and does not start HTTP',
    (tester) async {
      final gateway = _Gateway();
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      gateway.edit();
      gateway.eligible = false;
      gateway.publish('idle');
      await tester.pump(const Duration(seconds: 2));
      expect(gateway.prepares, 0);
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  testWidgets(
    'disabling while reserve is pending cancels without HTTP preparation',
    (tester) async {
      final gateway = _Gateway()..reserveGate = Completer<void>();
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      gateway.edit();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(gateway.reserves, 1);
      expect(gateway.prepares, 0);
      gateway.eligible = false;
      gateway.publish('reserved');
      gateway.reserveGate!.complete();
      await tester.pump();
      await drainAsync(tester, controller.shutdown());
      expect(gateway.prepares, 0);
      expect(gateway.cancels, greaterThanOrEqualTo(1));
      controller.dispose();
    },
  );
  testWidgets(
    'housekeeping-only ACK does not reload the host list and empty cancel is never sticky-busy',
    (tester) async {
      var refreshes = 0;
      final gateway = _Gateway();
      final controller = ConfigurationSyncController(
        gateway: gateway,
        onCommitted: () async {
          refreshes++;
        },
      );
      await controller.start();
      await controller.cancel();
      expect(controller.busy, isFalse);
      await controller.synchronize();
      await controller.confirm(controller.state!);
      expect(refreshes, 0);
      gateway.updates++;
      gateway.publish('committed');
      await tester.pump();
      expect(refreshes, 1);
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
}
