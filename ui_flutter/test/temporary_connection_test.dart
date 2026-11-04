import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/temporary_connection.dart';
import 'package:hspterm/terminal/controller.dart';

import 'support/fake_backend.dart';

void main() {
  DemoHost host() => DemoHost(
    'saved-fixture',
    'Saved fixture',
    'saved.invalid',
    '未分组',
    user: 'fixture',
    credentialSet: true,
  );
  testWidgets(
    'temporary form validates metadata and returns only the explicitly selected method',
    (tester) async {
      TemporaryConnectionInput? input;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const Scaffold();
            },
          ),
        ),
      );
      final pending = showTemporaryConnection(
        ctx,
        host(),
      ).then((v) => input = v);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('temporary-port')), '0');
      await tester.tap(find.text('连接一次'));
      await tester.pumpAndSettle();
      expect(find.text('端口范围为 1–65535'), findsOneWidget);
      expect(input, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('temporary-address')),
        '127.0.0.1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('temporary-port')),
        '2222',
      );
      await tester.tap(find.byKey(const ValueKey('temporary-auth')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本次密码').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('temporary-password')),
        'synthetic-once-password',
      );
      await tester.tap(find.text('连接一次'));
      await tester.pumpAndSettle();
      await pending;
      expect(input!.target.address, '127.0.0.1');
      expect(input!.target.port, 2222);
      expect(input!.target.auth, TemporaryAuth.password);
      expect(input!.password, 'synthetic-once-password');
      expect(input!.keyFile, isNull);
      input!.forgetSecrets();
      expect(input!.password, isNull);
    },
  );
  testWidgets(
    'switching methods drops hidden secrets; explicit file-picker errors remain local and cancel returns nothing',
    (tester) async {
      TemporaryConnectionInput? input;
      var completed = false;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const Scaffold();
            },
          ),
        ),
      );
      final pending =
          showTemporaryConnection(
            ctx,
            host(),
            pickKey: () async => throw StateError('synthetic picker failure'),
          ).then((v) {
            input = v;
            completed = true;
          });
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('temporary-auth')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本次密码').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('temporary-password')),
        'synthetic-hidden-password',
      );
      await tester.tap(find.byKey(const ValueKey('temporary-auth')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本次私钥文件').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('选择私钥文件'));
      await tester.pumpAndSettle();
      expect(find.text('无法选择私钥文件，请重试'), findsOneWidget);
      expect(completed, false);
      await tester.tap(find.byKey(const ValueKey('temporary-auth')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('本次密码').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('temporary-password')),
            )
            .controller!
            .text,
        isEmpty,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await pending;
      expect(input, isNull);
    },
  );
  test('an explicit reconnect driver cannot fall back to saved credentials and repeated Enter does not open multiple confirmations', () async {
    final backend = FakeBackend(), dialog = Completer<void>();
    final c = TerminalController(backend);
    try {
      await c.start();
      c.profileId = 'saved-fixture';
      c.phase = 'Disconnected';
      var confirmations = 0;
      c.reconnectRequest = () async {
        confirmations++;
        await dialog.future;
      };
      final first = c.reconnect();
      await Future<void>.delayed(Duration.zero);
      await c.reconnect();
      expect(confirmations, 1);
      expect(backend.connects, 0);
      dialog.complete();
      await first;
      expect(backend.connects, 0);
      c.reconnectRequest = null;
      c.connectRequest = (_, _) async =>
          throw StateError('synthetic one-off failure');
      await c.connect('saved-fixture');
      expect(c.phase, 'Failed');
      expect(
        backend.connects,
        0,
        reason:
            'failed explicit driver never falls back to stored authentication',
      );
    } finally {
      await c.shutdown();
      c.dispose();
    }
  });
}
