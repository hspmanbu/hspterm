import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/google_drive_account.dart';
import 'package:hspterm/workbench/google_drive_objects.dart';
import 'package:hspterm/workbench/google_drive_objects_panel.dart';

Map<String, dynamic> account({String revision = 'a'}) => {
  'vault_scope': 'synthetic-vault',
  'revision': revision * 64,
  'client_id': 'synthetic-client.apps.googleusercontent.com',
  'authorization_id': 'b' * 32,
};
Map<String, dynamic> settings({Map<String, dynamic>? target}) => {
  'vault_scope': 'synthetic-vault',
  'revision': 'c' * 64,
  'target': target,
  'sync_password_set': target != null,
  'webdav_credential_set': false,
  'proxy_credential_set': false,
  'suggested_collection': 'd' * 32,
  'collection_derived': true,
};
const operation = 'drive-authorization-0123456789abcdef0123456789abcdef';
Map<String, dynamic> discovery() => {
  'operation': operation,
  'account': account(revision: 'e'),
  'settings': settings(),
  'objects': [
    for (final suffix in ['A', 'B'])
      {'id': 'synthetic-$suffix', 'collection': 'd' * 32, 'bytes': 128},
  ],
};

Map<String, dynamic> creationMetadata({
  bool attempted = false,
  bool enabled = false,
}) => {
  'vault_scope': 'synthetic-vault',
  'revision': (attempted ? 'f' : 'a') * 64,
  'id': 'synthetic-generated-id',
  'collection': 'd' * 32,
  'client_id': account()['client_id'],
  'authorization_id': 'b' * 32,
  'bytes': 128,
  'units': 3,
  'enabled': enabled,
  'attempted': attempted,
};
String createdSettings(bool enabled) => jsonEncode(
  settings(
    target: {
      'enabled': enabled,
      'endpoint':
          'https://www.googleapis.com/drive/v3/files/synthetic-generated-id',
      'collection': 'd' * 32,
      'authenticate': false,
      'timeout_seconds': 60,
      'proxy': null,
      'drive': {
        'file_id': 'synthetic-generated-id',
        'client_id': account()['client_id'],
        'authorization_id': 'b' * 32,
      },
    },
  ),
);

class Accounts implements GoogleDriveAccountGateway {
  @override
  Future<String> load() async => jsonEncode(account());
  @override
  Future<String> reserve(Map<String, dynamic> input) =>
      throw StateError('unexpected authorization');
  @override
  Future<String> prepare(String operation) =>
      throw StateError('unexpected browser');
  @override
  Future<String> finish(String operation) =>
      throw StateError('unexpected browser');
  @override
  Future<String> reserveRemoval(
    GoogleDriveAccount source, {
    required bool revoke,
  }) => throw StateError('unexpected deletion');
  @override
  Future<String> remove(String operation) =>
      throw StateError('unexpected deletion');
  @override
  Future<String> cancel(String operation) async => 'ended';
}

class Objects implements GoogleDriveObjectsGateway {
  int reserves = 0, discoveries = 0, cancellations = 0;
  final writes = <Map<String, dynamic>>[];
  Completer<String>? reserveWait, discoveryWait, selectWait, cancelWait;
  int pendingReads = 0,
      creationReservations = 0,
      stages = 0,
      creations = 0,
      discards = 0;
  Map<String, dynamic>? pending;
  Completer<String>? creationWait;
  @override
  Future<String> pendingCreation() async {
    pendingReads++;
    return jsonEncode(pending);
  }

  @override
  Future<String> reserveCreation(
    GoogleDriveAccount account,
    DriveCreation source,
  ) async {
    creationReservations++;
    expect(source.id, 'synthetic-generated-id');
    return operation;
  }

  @override
  Future<String> prepareCreation(String id, Map<String, dynamic> input) async {
    expect(id, operation);
    expect(input['confirm_sensitive_upload'], true);
    stages++;
    pending = creationMetadata(enabled: input['enabled'] as bool);
    return jsonEncode({
      'operation': operation,
      'creation': pending,
      'account': account(revision: 'f'),
    });
  }

  @override
  Future<String> finishCreation(String id) async {
    expect(id, operation);
    creations++;
    if (creationWait != null) return creationWait!.future;
    final enabled = pending!['enabled'] as bool;
    pending = null;
    return createdSettings(enabled);
  }

  @override
  Future<void> discardCreation(DriveCreation source) async {
    discards++;
    pending = null;
  }

  String outcome = 'cancelled';
  @override
  Future<String> reserve(GoogleDriveAccount source) async {
    reserves++;
    return reserveWait?.future ?? operation;
  }

  @override
  Future<String> discover(String id) async {
    expect(id, operation);
    discoveries++;
    return discoveryWait?.future ?? jsonEncode(discovery());
  }

  @override
  Future<String> select(String id, Map<String, dynamic> input) async {
    expect(id, operation);
    writes.add(Map.from(input));
    return selectWait?.future ??
        jsonEncode(
          settings(
            target: {
              'enabled': input['enabled'],
              'endpoint':
                  'https://www.googleapis.com/drive/v3/files/${input['id']}',
              'collection': 'd' * 32,
              'authenticate': false,
              'timeout_seconds': 60,
              'proxy': null,
              'drive': {
                'file_id': input['id'],
                'client_id': account()['client_id'],
                'authorization_id': 'b' * 32,
              },
            },
          ),
        );
  }

  @override
  Future<String> cancel(String id) async {
    expect(id, operation);
    cancellations++;
    return cancelWait?.future ?? outcome;
  }
}

Future<(GoogleDriveAccountController, GoogleDriveObjectsController, Objects)>
fixture() async {
  final accounts = GoogleDriveAccountController(gateway: Accounts());
  await accounts.load();
  final gateway = Objects();
  final controller = GoogleDriveObjectsController(
    accounts: accounts,
    gateway: gateway,
  );
  return (accounts, controller, gateway);
}

Future<void> close(
  GoogleDriveAccountController a,
  GoogleDriveObjectsController c,
) async {
  await c.shutdown();
  c.dispose();
  await a.shutdown();
  a.dispose();
}

void main() {
  test('new collection stages exact metadata before a separate explicit publication', () async {
    final (a, c, g) = await fixture();
    await c.discover(a.account!);
    await c.prepareNew(
      c.discovery!,
      password: 'synthetic-new-e2e',
      enabled: false,
      confirmTargetChange: false,
      confirmSensitiveUpload: true,
    );
    expect(g.stages, 1);
    expect(g.creations, 0);
    expect(c.saved, isNull);
    expect(c.creation!.id, 'synthetic-generated-id');
    expect(c.discovery, isNull);
    expect(a.account!.revision, 'f' * 64);
    await c.finishCreation(c.creation!);
    expect(g.creations, 1);
    expect(g.creationReservations, 0);
    expect(c.creation, isNull);
    expect(c.saved!.target!['enabled'], isFalse);
    await close(a, c);
  });
  test('resuming a persisted creation uses the original ID and never discovers or allocates another', () async {
    final (a, c, g) = await fixture();
    g.pending = creationMetadata(attempted: true);
    await c.loadCreation();
    expect(g.reserves, 0);
    expect(g.stages, 0);
    expect(g.creations, 0);
    await c.finishCreation(c.creation!);
    expect(g.creationReservations, 1);
    expect(g.creations, 1);
    expect(g.discoveries, 0);
    expect(g.stages, 0);
    expect(c.saved!.target!['endpoint'], endsWith('/synthetic-generated-id'));
    await close(a, c);
  });
  test('unknown creation keeps original recovery metadata and reports no saved target', () async {
    final (a, c, g) = await fixture();
    g.pending = creationMetadata(attempted: true);
    await c.loadCreation();
    g.creationWait = Completer();
    g.outcome = 'create_unknown';
    final work = c.finishCreation(c.creation!);
    await Future<void>.delayed(Duration.zero);
    g.creationWait!.completeError(StateError('synthetic-secret-response'));
    await work;
    expect(c.saved, isNull);
    expect(c.creation!.id, 'synthetic-generated-id');
    expect(c.error, contains('原 ID'));
    expect(c.error, isNot(contains('synthetic-secret-response')));
    expect(g.stages, 0);
    expect(g.discoveries, 0);
    await close(a, c);
  });
  test('discard is explicit local-only and malformed metadata never becomes an empty success', () async {
    final (a, c, g) = await fixture();
    g.pending = creationMetadata(attempted: true);
    await c.loadCreation();
    await c.discardCreation(c.creation!);
    expect(g.discards, 1);
    expect(g.creations, 0);
    expect(c.creation, isNull);
    final bad = creationMetadata()
      ..['password'] = 'synthetic-must-not-be-returned';
    expect(() => DriveCreation(bad), throwsFormatException);
    await close(a, c);
  });

  test(
    'same collection keeps distinct object IDs and rejects duplicate IDs',
    () {
      final source = DriveDiscovery(discovery());
      expect(source.objects, hasLength(2));
      expect(source.objects[0].collection, source.objects[1].collection);
      final invalid = discovery();
      (invalid['objects'] as List)[1]['id'] = 'synthetic-A';
      expect(() => DriveDiscovery(invalid), throwsFormatException);
    },
  );
  test('discovery is explicit; rotation metadata and exact selection have no automatic upload', () async {
    final (a, c, g) = await fixture();
    expect(g.reserves, 0);
    await c.discover(a.account!);
    expect(g.discoveries, 1);
    expect(g.writes, isEmpty);
    expect(a.account!.revision, 'e' * 64);
    final source = c.discovery!;
    await c.select(
      source,
      source.objects[1],
      enabled: false,
      password: 'synthetic-e2e',
      confirmTargetChange: false,
    );
    expect(g.writes.single['id'], 'synthetic-B');
    expect(c.saved!.target!['enabled'], isFalse);
    expect(c.discovery, isNull);
    expect(g.cancellations, 1);
    await close(a, c);
  });
  test(
    'exit during reservation waits for late ID and never starts discovery',
    () async {
      final (a, c, g) = await fixture();
      g.reserveWait = Completer();
      g.cancelWait = Completer();
      final work = c.discover(a.account!);
      await Future<void>.delayed(Duration.zero);
      bool finished = false;
      final shutdown = c.shutdown().then((_) => finished = true);
      expect(finished, isFalse);
      g.reserveWait!.complete(operation);
      await Future<void>.delayed(Duration.zero);
      expect(g.discoveries, 0);
      expect(finished, isFalse);
      g.cancelWait!.complete('cancelled');
      await work;
      await shutdown;
      expect(g.cancellations, 1);
      expect(c.discovery, isNull);
      await close(a, c);
    },
  );
  test(
    'unknown refresh never becomes a saved target or leaks raw errors',
    () async {
      final (a, c, g) = await fixture();
      g.discoveryWait = Completer();
      g.outcome = 'authorization_unknown';
      final work = c.discover(a.account!);
      await Future<void>.delayed(Duration.zero);
      g.discoveryWait!.completeError(StateError('synthetic-secret-http-body'));
      await work;
      expect(c.error, contains('刷新凭据结果未确认'));
      expect(c.error, isNot(contains('synthetic-secret-http-body')));
      expect(c.saved, isNull);
      expect(c.canDiscover, isTrue);
      await close(a, c);
    },
  );
  testWidgets(
    'settings opening performs no HTTP, selection is explicit and narrow layout scrolls',
    (tester) async {
      final (a, c, g) = await fixture();
      tester.view.physicalSize = const Size(680, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GoogleDriveObjectsPanel(controller: c),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(g.reserves, 0);
      await tester.tap(find.byKey(const ValueKey('drive-objects-discover')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('drive-objects-select')), findsNothing);
      final second = find.textContaining('synthetic-B');
      await tester.ensureVisible(second);
      await tester.tap(second);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('drive-objects-select')),
        findsOneWidget,
      );
      expect(g.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await close(a, c);
    },
  );
}
