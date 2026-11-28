import 'support/terminal_cleanup.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:hspterm/workbench/configuration_sync_reference_model.dart';
import 'package:hspterm/workbench/configuration_sync_references.dart';
import 'package:hspterm/workbench/configuration_sync.dart';
import 'package:hspterm/workbench/configuration_sync_panel.dart';

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
      updates = 0,
      intervalLoads = 0,
      intervalSaves = 0;
  String phase = 'idle', operation = '', review = 'review-1';
  int networkFailures = 0;
  int sourceChangedFailures = 0;
  String? error;
  bool risky = false,
      eligible = true,
      retry = false,
      references = false,
      writeUnknown = false;
  int checkInterval = 0;
  final List<String> diverged = [], directions = [], savedIntervals = [];
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
    'error': phase == 'cancelled' ? 'cancelled' : error,
    'commits': commits,
    'configuration_updates': updates,
    'remote_published': false,
    'write_unknown': writeUnknown,
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
              'diverged': diverged,
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
    // Mirrors the native gate: a fresh reservation clears the sticky
    // unconfirmed-write marker until a new failure sets it again.
    writeUnknown = false;
    publish('reserved');
    await reserveGate?.future;
    return operation;
  }

  @override
  Future<String> prepare(String owner, String operation) async {
    prepares++;
    if (networkFailures > 0) {
      networkFailures--;
      error = 'network';
      publish('failed');
      throw StateError('synthetic network failure');
    }
    if (sourceChangedFailures > 0) {
      sourceChangedFailures--;
      error = 'source_changed';
      publish('failed');
      throw StateError('synthetic source change');
    }
    error = null;
    publish('reading');
    await prepareGate?.future;
    if (phase != 'cancelled') publish(references ? 'references' : 'review');
    return snapshot();
  }

  @override
  Future<String> confirm(String owner, String operation, String review) async {
    // Mirrors the native gate: unresolved both-modified units cannot be
    // published or applied before an explicit whole-direction choice.
    if (diverged.isNotEmpty) return snapshot();
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
  Future<String> resolveDirection(
    String owner,
    String operation,
    String review,
    String direction,
  ) async {
    directions.add(direction);
    references = false;
    diverged.clear();
    risky = direction == 'remote';
    this.review = 'direction-review-${directions.length}';
    publish('review');
    return snapshot();
  }

  @override
  Future<int> loadCheckInterval() async {
    intervalLoads++;
    return checkInterval;
  }

  @override
  Future<void> saveCheckInterval(int minutes) async {
    intervalSaves++;
    savedIntervals.add('$minutes');
    checkInterval = minutes;
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
  test(
    'a typed data mismatch explains the sync password, not a collection id',
    () {
      final gateway = _Gateway()..error = 'data';
      final value = jsonDecode(gateway.snapshot()) as Map<String, dynamic>;
      value['phase'] = 'failed';
      final state = ConfigurationSyncState(value);
      expect(state.error, 'data');
      expect(syncFailureLabel(state), contains('同步密码或数据版本不匹配'));
      expect(syncFailureLabel(state), contains('与创建该数据集时一致的同步密码'));
      expect(syncFailureLabel(state), isNot(contains('集合标识')));
    },
  );
  test(
    'first-read failures distinguish a wrong password from a legacy dataset id',
    () {
      final gateway = _Gateway()..error = 'first_read_decrypt';
      final value = jsonDecode(gateway.snapshot()) as Map<String, dynamic>;
      value['phase'] = 'failed';
      final password = ConfigurationSyncState(value);
      expect(password.error, 'first_read_decrypt');
      expect(syncFailureLabel(password), contains('无法读取云端配置'));
      expect(syncFailureLabel(password), isNot(contains('旧版标识')));
      gateway.error = 'first_read_legacy_collection';
      final legacy = ConfigurationSyncState(
        jsonDecode(gateway.snapshot()) as Map<String, dynamic>,
      );
      expect(legacy.error, 'first_read_legacy_collection');
      expect(syncFailureLabel(legacy), contains('旧版标识'));
      expect(syncFailureLabel(legacy), contains('原创建设备'));
      expect(syncFailureLabel(legacy), isNot(contains('同步密码不一致')));
    },
  );
  testWidgets(
    'startup and an idle clock never synchronize persisted state without a check interval',
    (tester) async {
      final gateway = _Gateway();
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      await tester.pump(const Duration(minutes: 10));
      expect(gateway.prepares, 0);
      expect(gateway.reserves, 0);
      expect(gateway.intervalLoads, 1);
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  testWidgets(
    'a configured check interval fires automatic sync and a pending review stops it',
    (tester) async {
      final gateway = _Gateway()..checkInterval = 1;
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      expect(controller.checkIntervalMinutes, 1);
      await tester.pump(const Duration(minutes: 1));
      expect(gateway.reserves, 1);
      expect(gateway.confirms, 1);
      expect(controller.state?.phase, 'committed');
      // A both-modified unit stops the automatic loop at the review; the tick
      // must not cancel the pending candidate while the user decides.
      gateway.diverged.add('host-${'a' * 32}');
      gateway.risky = true;
      await tester.pump(const Duration(minutes: 1));
      expect(gateway.reserves, 2);
      expect(gateway.confirms, 1);
      expect(controller.state?.phase, 'review');
      expect(controller.state?.review!.needsDirection, isTrue);
      await tester.pump(const Duration(minutes: 3));
      expect(gateway.reserves, 2);
      // Saving a new interval restarts the timer from the confirmed value.
      await controller.setCheckIntervalMinutes(0);
      expect(gateway.savedIntervals, ['0']);
      gateway.risky = false;
      gateway.diverged.clear();
      await tester.pump(const Duration(minutes: 10));
      expect(gateway.reserves, 2);
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  testWidgets('divergence direction finishes without a second review', (
    tester,
  ) async {
    final gateway = _Gateway()..risky = true;
    gateway.diverged.add('host-${'a' * 32}');
    final controller = ConfigurationSyncController(gateway: gateway);
    await controller.start();
    await controller.synchronize();
    final original = controller.state!;
    expect(original.review!.needsDirection, isTrue);
    await controller.confirm(original);
    expect(gateway.confirms, 0);
    await controller.resolveDirection(original, 'local');
    expect(gateway.directions, ['local']);
    expect(controller.state?.review, isNull);
    expect(gateway.confirms, 1);
    expect(controller.state?.phase, 'committed');
    await drainAsync(tester, controller.shutdown());
    controller.dispose();
  });
  testWidgets(
    'edits only mark the device dirty; the exchange waits for the check interval or a manual sync',
    (tester) async {
      final gateway = _Gateway()..checkInterval = 10;
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      gateway.edit(scope: 'foreign-scope');
      await tester.pump(const Duration(seconds: 2));
      expect(gateway.prepares, 0);
      expect(controller.pendingEdits, isFalse);
      for (var i = 0; i < 20; i++) {
        gateway.edit();
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(controller.pendingEdits, isTrue);
      // No 750ms debounce chain anymore: minutes of idle edits never start an
      // exchange by themselves.
      await tester.pump(const Duration(minutes: 2));
      expect(gateway.prepares, 0);
      expect(gateway.reserves, 0);
      expect(controller.pendingEdits, isTrue);
      // The next periodic check picks the dirty state up and completes it.
      await tester.pump(const Duration(minutes: 8));
      await tester.pump();
      expect(gateway.prepares, 1);
      expect(gateway.confirms, 1);
      expect(controller.state?.phase, 'committed');
      expect(controller.pendingEdits, isFalse);
      await tester.pump(const Duration(minutes: 5));
      expect(gateway.prepares, 1);
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  testWidgets(
    'an unconfirmed cloud write re-reads automatically instead of waiting for a manual retry',
    (tester) async {
      final gateway = _Gateway();
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      // Finish marks the failed state with write_unknown set.
      gateway.writeUnknown = true;
      gateway.error = 'write_unknown';
      gateway.publish('failed');
      await tester.pump();
      expect(controller.state?.writeUnknown, isTrue);
      expect(
        controller.state == null ? '' : syncFailureLabel(controller.state),
        contains('自动重新读取'),
      );
      // Before the short backoff elapses nothing is re-sent.
      await tester.pump(const Duration(seconds: 29));
      expect(gateway.reserves, 0);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(gateway.reserves, 1);
      expect(gateway.confirms, 1);
      expect(controller.state?.phase, 'committed');
      expect(controller.state?.writeUnknown, isFalse);
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  testWidgets(
    'credential-only incoming updates are silent; real divergence needs one direction',
    (tester) async {
      final gateway = _Gateway()..risky = true;
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      await controller.synchronize();
      expect(gateway.confirms, 1);
      expect(controller.state?.phase, 'committed');
      gateway.diverged.add('host-${'a' * 32}');
      await controller.synchronize();
      expect(controller.state?.review?.needsConsent, true);
      expect(gateway.confirms, 1);
      await controller.resolveDirection(controller.state!, 'remote');
      expect(gateway.directions, ['remote']);
      expect(gateway.confirms, 2);
      expect(controller.state?.phase, 'committed');
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  testWidgets('a stale direction cannot overwrite a newer candidate', (
    tester,
  ) async {
    final gateway = _Gateway()..diverged.add('host-${'a' * 32}');
    final controller = ConfigurationSyncController(gateway: gateway);
    await controller.start();
    await controller.synchronize();
    final old = controller.state!;
    gateway.review = 'new-candidate';
    gateway.publish('review');
    await controller.resolveDirection(old, 'local');
    expect(gateway.directions, isEmpty);
    await controller.resolveDirection(controller.state!, 'local');
    expect(gateway.directions, ['local']);
    expect(controller.state?.phase, 'committed');
    await drainAsync(tester, controller.shutdown());
    controller.dispose();
  });
  testWidgets('network failures retry from fresh reads at most three times', (
    tester,
  ) async {
    final gateway = _Gateway()..networkFailures = 2;
    final controller = ConfigurationSyncController(gateway: gateway);
    await controller.start();
    final work = controller.synchronize();
    await tester.pump();
    expect(controller.retrying, true);
    expect(gateway.prepares, 1);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(gateway.prepares, 2);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    await work;
    expect(gateway.prepares, 3);
    expect(controller.state?.phase, 'committed');
    expect(controller.retrying, false);
    gateway.networkFailures = 3;
    final failing = controller.synchronize();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    await failing;
    expect(gateway.prepares, 6);
    expect(controller.state?.phase, 'failed');
    expect(controller.retrying, false);
    await tester.pump(const Duration(seconds: 10));
    expect(gateway.prepares, 6);
    await drainAsync(tester, controller.shutdown());
    controller.dispose();
  });
  testWidgets('source changes do not auto-retry on a dense backoff loop', (
    tester,
  ) async {
    final gateway = _Gateway()..sourceChangedFailures = 3;
    final controller = ConfigurationSyncController(gateway: gateway);
    await controller.start();
    final work = controller.synchronize();
    await tester.pump();
    // The exchange compared the local source before and after the network
    // read; a persistent source_changed failure must not be retried every
    // 2/4 seconds. Pacing falls back to the check interval or a manual sync.
    expect(gateway.prepares, 1);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(gateway.prepares, 1);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    await work;
    expect(gateway.prepares, 1);
    expect(controller.state?.phase, 'failed');
    expect(controller.state?.error, 'source_changed');
    expect(controller.retrying, false);
    await tester.pump(const Duration(seconds: 10));
    expect(gateway.prepares, 1);
    await drainAsync(tester, controller.shutdown());
    controller.dispose();
  });
  testWidgets('cancelling retry backoff never starts another request', (
    tester,
  ) async {
    final gateway = _Gateway()..networkFailures = 3;
    final controller = ConfigurationSyncController(gateway: gateway);
    await controller.start();
    final work = controller.synchronize();
    await tester.pump();
    expect(gateway.prepares, 1);
    expect(controller.retrying, true);
    final cancel = controller.cancel();
    await tester.pump();
    await cancel;
    await work;
    await tester.pump(const Duration(seconds: 10));
    expect(gateway.prepares, 1);
    expect(controller.retrying, false);
    await drainAsync(tester, controller.shutdown());
    controller.dispose();
  });
  testWidgets(
    'reading cloud history never confirms or uploads a local candidate',
    (tester) async {
      final gateway = _Gateway()..diverged.add('host-${'a' * 32}');
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      expect(await controller.refreshHistory(), true);
      expect(gateway.prepares, 1);
      expect(gateway.confirms, 0);
      expect(gateway.commits, 0);
      expect(gateway.cancels, 1);
      expect(controller.state?.review, isNull);
      expect(controller.historyRead, true);
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  testWidgets(
    'direction dialog has three choices and no second review confirmation',
    (tester) async {
      final gateway = _Gateway()..diverged.add('host-${'a' * 32}');
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      await controller.synchronize();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showConfigurationSyncReview(context, controller),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('取消同步'), findsOneWidget);
      expect(find.text('本地覆盖云端'), findsOneWidget);
      await tester.tap(find.text('云端覆盖本地'));
      await tester.pumpAndSettle();
      expect(gateway.directions, ['remote']);
      expect(gateway.confirms, 1);
      expect(controller.state?.phase, 'committed');
      expect(find.text('确认同步'), findsNothing);
      await tester.pumpWidget(const SizedBox());
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
      final gateway = _Gateway()..checkInterval = 1;
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      gateway.edit();
      expect(controller.pendingEdits, isTrue);
      gateway.eligible = false;
      gateway.publish('idle');
      await tester.pump(const Duration(minutes: 2));
      expect(gateway.prepares, 0);
      expect(gateway.reserves, 0);
      expect(controller.checkTimerArmed, isFalse);
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
      final work = controller.synchronize();
      await tester.pump();
      await tester.pump();
      expect(gateway.reserves, 1);
      expect(gateway.prepares, 0);
      gateway.eligible = false;
      gateway.publish('reserved');
      gateway.reserveGate!.complete();
      await tester.pump();
      await work;
      await drainAsync(tester, controller.shutdown());
      expect(gateway.prepares, 0);
      expect(gateway.cancels, greaterThanOrEqualTo(1));
      controller.dispose();
    },
  );
  testWidgets(
    'disabling the target immediately hides the failure banner until re-enabled',
    (tester) async {
      final gateway = _Gateway()..error = 'data';
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ConfigurationSyncBanner(controller: controller)),
        ),
      );
      await tester.pump();
      expect(find.text('立即同步'), findsNothing);
      gateway.publish('failed');
      await tester.pump();
      expect(find.textContaining('同步密码或数据版本不匹配'), findsOneWidget);
      expect(find.text('立即同步'), findsOneWidget);
      // A stale request-level notice rides along in the smaller line.
      controller.error = '同步请求未完成；请查看状态后明确重试。';
      controller.notifyListeners();
      await tester.pump();
      expect(find.text('同步请求未完成；请查看状态后明确重试。'), findsOneWidget);
      // Unchecking the target must drop the residual failed state, the
      // controller notice and the greyed manual retry all at once.
      gateway.eligible = false;
      gateway.publish('failed');
      await tester.pump();
      expect(controller.state?.eligible, false);
      expect(controller.error, isNull);
      expect(find.text('立即同步'), findsNothing);
      expect(find.textContaining('同步密码或数据版本不匹配'), findsNothing);
      // Re-enabling restores the banner from the still-failed state.
      gateway.eligible = true;
      gateway.publish('failed');
      await tester.pump();
      expect(find.textContaining('同步密码或数据版本不匹配'), findsOneWidget);
      expect(find.text('立即同步'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await drainAsync(tester, controller.shutdown());
      controller.dispose();
    },
  );
  testWidgets(
    'disabling the target stops the periodic timer and re-enabling re-arms it',
    (tester) async {
      final gateway = _Gateway()..checkInterval = 1;
      final controller = ConfigurationSyncController(gateway: gateway);
      await controller.start();
      expect(controller.checkIntervalMinutes, 1);
      expect(controller.checkTimerArmed, isTrue);
      await tester.pump(const Duration(minutes: 1));
      expect(gateway.reserves, 1);
      gateway.eligible = false;
      gateway.publish('idle');
      await tester.pump();
      expect(controller.checkTimerArmed, isFalse);
      await tester.pump(const Duration(minutes: 5));
      expect(gateway.reserves, 1);
      gateway.eligible = true;
      gateway.publish('idle');
      await tester.pump();
      expect(controller.checkTimerArmed, isTrue);
      await tester.pump(const Duration(minutes: 1));
      expect(gateway.reserves, 2);
      expect(gateway.confirms, 2);
      await drainAsync(tester, controller.shutdown());
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
