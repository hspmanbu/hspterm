import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/appearance.dart';

AppearanceSnapshot snapshot({
  bool light = false,
  String scope = 'synthetic-vault',
}) => AppearanceSnapshot({
  'vault_scope': scope,
  'revision': (light ? 'b' : 'a') * 64,
  'theme': light ? 'light' : 'dark',
});

class Gateway implements AppearanceGateway {
  int loads = 0, saves = 0;
  bool failRead = false, failSave = false;
  Completer<AppearanceSnapshot>? ack;
  @override
  Future<AppearanceSnapshot> load() async {
    loads++;
    if (failRead) throw StateError('synthetic read failure');
    return snapshot();
  }

  @override
  Future<AppearanceSnapshot> save(AppearanceSnapshot source, bool light) async {
    saves++;
    if (failSave) throw StateError('synthetic SQL failure');
    return ack?.future ?? snapshot(light: light);
  }
}

void main() {
  testWidgets(
    'theme selection is disabled until read and applies only the actual save ACK',
    (t) async {
      final g = Gateway()..ack = Completer<AppearanceSnapshot>();
      final c = AppearanceController(gateway: g);
      expect(c.available, false);
      await c.choose(true);
      expect(g.saves, 0);
      await c.load();
      expect(c.value!.light, false);
      final save = c.choose(true);
      await t.pump();
      expect(c.value!.light, false);
      expect(c.busy, true);
      expect(c.available, false);
      await c.choose(false);
      expect(g.saves, 1);
      g.ack!.complete(snapshot(light: true));
      await save;
      expect(c.value!.light, true);
      expect(c.available, true);
      await c.shutdown();
      c.dispose();
    },
  );
  testWidgets(
    'failed read or save cannot silently overwrite defaults and explicit reload recovers',
    (t) async {
      final g = Gateway()..failRead = true;
      final c = AppearanceController(gateway: g);
      await c.load();
      expect(c.value, null);
      expect(c.available, false);
      await c.choose(true);
      expect(g.saves, 0);
      g.failRead = false;
      await c.load();
      g.failSave = true;
      await c.choose(true);
      expect(c.error, isNotNull);
      expect(c.available, false);
      g.failSave = false;
      await c.load();
      expect(c.available, true);
      await c.shutdown();
      c.dispose();
    },
  );
  testWidgets(
    'close waits for in-flight theme SQL and retains its successful ACK',
    (t) async {
      final g = Gateway()..ack = Completer<AppearanceSnapshot>();
      final c = AppearanceController(gateway: g);
      await c.load();
      final save = c.choose(true);
      var closed = false;
      final closing = c.shutdown().then((_) => closed = true);
      await t.pump();
      expect(closed, false);
      g.ack!.complete(snapshot(light: true));
      await save;
      await closing;
      expect(c.value!.light, true);
      c.resumeAfterCancelledShutdown();
      expect(c.available, true);
      await c.shutdown();
      c.dispose();
    },
  );
  testWidgets(
    'read error presents a real reload action and does not preview a false saved theme',
    (t) async {
      final g = Gateway()..failRead = true;
      final c = AppearanceController(gateway: g);
      await c.load();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AppearanceStatusPanel(controller: c)),
        ),
      );
      expect(find.textContaining('上次确认的主题'), findsOneWidget);
      g.failRead = false;
      await t.tap(find.text('重新读取外观设置'));
      await t.pumpAndSettle();
      expect(find.text('当前界面主题：深色 · 石墨'), findsOneWidget);
      await t.pumpWidget(const SizedBox.shrink());
      await c.shutdown();
      c.dispose();
    },
  );
}
