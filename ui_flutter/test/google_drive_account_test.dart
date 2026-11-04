import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/google_drive_account.dart';

const clientId = 'synthetic-desktop.apps.googleusercontent.com';
String metadata({bool authorized = false, String scope = 'synthetic-vault'}) =>
    jsonEncode({
      'vault_scope': scope,
      'revision': (authorized ? 'b' : 'a') * 64,
      'client_id': authorized ? clientId : null,
      'authorization_id': authorized ? 'c' * 32 : null,
    });
String browserUrl() => Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
  'client_id': clientId,
  'redirect_uri': 'http://127.0.0.1:43001/oauth2/callback',
  'response_type': 'code',
  'scope': 'https://www.googleapis.com/auth/drive.appdata',
  'state': 'a' * 43,
  'code_challenge': 'b' * 43,
  'code_challenge_method': 'S256',
  'access_type': 'offline',
  'prompt': 'consent select_account',
}).toString();

class Gateway implements GoogleDriveAccountGateway {
  int loads = 0,
      reservations = 0,
      preparations = 0,
      finishes = 0,
      cancellations = 0,
      removals = 0;
  bool? revoked;
  String saved = metadata(), url = browserUrl();
  Completer<String>? reserveWait, finishWait, cancelWait;
  @override
  Future<String> load() async {
    loads++;
    return saved;
  }

  @override
  Future<String> reserve(Map<String, dynamic> input) async {
    reservations++;
    expect(input['client_secret'], 'synthetic-client-secret');
    return reserveWait?.future ?? 'synthetic-operation';
  }

  @override
  Future<String> prepare(String operation) async {
    preparations++;
    return url;
  }

  @override
  Future<String> finish(String operation) async {
    finishes++;
    return finishWait?.future ?? metadata(authorized: true);
  }

  @override
  Future<String> reserveRemoval(
    GoogleDriveAccount source, {
    required bool revoke,
  }) async {
    revoked = revoke;
    return 'synthetic-removal';
  }

  @override
  Future<String> remove(String operation) async {
    removals++;
    return metadata();
  }

  @override
  Future<String> cancel(String operation) async {
    cancellations++;
    return cancelWait?.future ?? 'cancelled';
  }
}

Future<void> authorize(
  GoogleDriveAccountController c, {
  GoogleDriveAccount? source,
}) => c.authorize(
  source: source ?? c.account!,
  clientId: clientId,
  clientSecret: 'synthetic-client-secret',
  confirmReplace: true,
);

void main() {
  testWidgets('panel metadata load and idle do not reserve or open a browser', (
    t,
  ) async {
    final g = Gateway();
    var opened = 0;
    final c = GoogleDriveAccountController(
      gateway: g,
      browser: (_) async {
        opened++;
        return true;
      },
    );
    expect(g.loads, 0);
    await c.load();
    await t.pump(const Duration(minutes: 10));
    expect(g.loads, 1);
    expect(g.reservations, 0);
    expect(opened, 0);
    expect(c.busy, false);
    await c.shutdown();
    c.dispose();
  });
  testWidgets(
    'only a validated original Google URL is opened and save ACK is kept',
    (t) async {
      final g = Gateway();
      final opened = <Uri>[];
      final c = GoogleDriveAccountController(
        gateway: g,
        browser: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      await c.load();
      await authorize(c);
      expect(opened.single.host, 'accounts.google.com');
      expect(g.finishes, 1);
      expect(g.cancellations, 1);
      expect(c.account!.authorized, true);
      expect(c.error, null);
      expect(c.busy, false);
      expect(c.notice, contains('加密保存'));
      await c.shutdown();
      c.dispose();
    },
  );
  testWidgets(
    'malformed or failed browser launch cannot consume code or save credentials',
    (t) async {
      for (final invalid in [false, true]) {
        final g = Gateway();
        var opened = 0;
        if (invalid) {
          g.url = browserUrl().replaceFirst(
            'accounts.google.com',
            'attacker.invalid',
          );
        }
        final c = GoogleDriveAccountController(
          gateway: g,
          browser: (_) async {
            opened++;
            return false;
          },
        );
        await c.load();
        await authorize(c);
        expect(opened, invalid ? 0 : 1);
        expect(g.finishes, 0);
        expect(g.cancellations, 1);
        expect(c.account!.authorized, false);
        expect(c.error, isNotNull);
        expect(c.error, isNot(contains('synthetic-client-secret')));
        await c.shutdown();
        c.dispose();
      }
    },
  );
  testWidgets(
    'shutdown waits for reserve to return its token and retires it before opening browser',
    (t) async {
      final g = Gateway()..reserveWait = Completer<String>();
      var opened = 0;
      final c = GoogleDriveAccountController(
        gateway: g,
        browser: (_) async {
          opened++;
          return true;
        },
      );
      await c.load();
      final running = authorize(c);
      await t.pump();
      var closed = false;
      final closing = c.shutdown().then((_) => closed = true);
      await t.pump();
      expect(closed, false);
      g.reserveWait!.complete('synthetic-delayed-operation');
      await running;
      await closing;
      expect(g.cancellations, 1);
      expect(g.preparations, 0);
      expect(opened, 0);
      c.resumeAfterCancelledShutdown();
      await c.load();
      expect(c.available, true);
      await c.shutdown();
      c.dispose();
    },
  );
  testWidgets(
    'cancel and route shutdown wait for original callback worker instead of losing it',
    (t) async {
      final g = Gateway()
        ..finishWait = Completer<String>()
        ..cancelWait = Completer<String>();
      final c = GoogleDriveAccountController(
        gateway: g,
        browser: (_) async => true,
      );
      await c.load();
      final running = authorize(c);
      await t.pump();
      expect(g.finishes, 1);
      var closed = false;
      final closing = c.shutdown().then((_) => closed = true);
      await t.pump();
      expect(closed, false);
      g.finishWait!.completeError(StateError('synthetic cancelled callback'));
      await t.pump();
      expect(closed, false);
      g.cancelWait!.complete('cancelled');
      await running;
      await closing;
      expect(g.cancellations, 1);
      expect(c.account!.authorized, false);
      c.dispose();
    },
  );
  testWidgets(
    'stale source cannot authorize and remove and revoke remain distinct',
    (t) async {
      final g = Gateway()..saved = metadata(authorized: true);
      final c = GoogleDriveAccountController(
        gateway: g,
        browser: (_) async => true,
      );
      await c.load();
      final old = GoogleDriveAccount(
        jsonDecode(metadata(scope: 'foreign-vault')) as Map<String, dynamic>,
      );
      await authorize(c, source: old);
      expect(g.reservations, 0);
      await c.remove(c.account!, revoke: false);
      expect(g.revoked, false);
      expect(c.notice, contains('未撤销'));
      await c.load();
      await c.remove(c.account!, revoke: true);
      expect(g.revoked, true);
      expect(c.notice, contains('已确认撤销'));
      await c.shutdown();
      c.dispose();
    },
  );
  test('metadata parser rejects secret fields and inconsistent identities', () {
    final v = jsonDecode(metadata()) as Map<String, dynamic>;
    expect(
      () => GoogleDriveAccount({...v, 'refresh_token': 'synthetic-token'}),
      throwsFormatException,
    );
    expect(
      () => GoogleDriveAccount({...v, 'client_id': clientId}),
      throwsFormatException,
    );
    expect(
      validDesktopClientId('a.apps.googleusercontent.com.attacker.invalid'),
      false,
    );
  });
}
