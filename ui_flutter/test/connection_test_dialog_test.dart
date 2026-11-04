import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/prototype/host_connection_test_dialog.dart';
import 'package:hspterm/prototype/model.dart';

class _ProbeModel extends WorkbenchModel {
  _ProbeModel() {
    hosts
      ..clear()
      ..add(
        DemoHost(
          'probe',
          'Probe fixture',
          'saved.invalid',
          '开发环境',
          credentialSet: true,
        ),
      );
  }
  @override
  bool get isMock => false;
  final result = Completer<void>(), released = Completer<void>();
  DemoHost? captured;
  Future<void>? cancellationTarget;
  int started = 0, cancelled = 0;
  @override
  Future<void> testSavedHost(DemoHost host) {
    started++;
    captured = host;
    return result.future;
  }

  @override
  Future<void> cancelHostTest({Future<void>? expected}) async {
    cancelled++;
    cancellationTarget = expected;
    await released.future;
    if (!result.isCompleted) {
      result.completeError(StateError('synthetic cancellation'));
    }
  }
}

void main() {
  testWidgets(
    'long target metadata remains scrollable with close accessible in a scaled small window',
    (tester) async {
      tester.view.physicalSize = const Size(960, 720);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = _ProbeModel();
      model.hosts.single
        ..name = '主机说明'.padRight(300, '长')
        ..address = '${'a' * 240}.invalid'
        ..user = 'u' * 128;
      model.result.complete();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => HostConnectionTestDialog(
                    model: model,
                    host: model.hosts.single.snapshot(),
                  ),
                ),
                child: const Text('打开测试'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开测试'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('host-test-success')),
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'dirty host test does not implicitly save or start network work',
    (tester) async {
      final model = _ProbeModel();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HostManager(model: model)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('host-主机地址')),
        'unsaved.invalid',
      );
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      expect(model.started, 0);
      expect(find.textContaining('请先点击保存'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'handshake result describes its scope and captures the original target',
    (tester) async {
      final model = _ProbeModel();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HostManager(model: model)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试连接'));
      await tester.pump();
      expect(model.started, 1);
      model.hosts.single.address = 'later.invalid';
      expect(model.captured!.address, 'saved.invalid');
      model.result.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('host-test-success')), findsOneWidget);
      expect(find.textContaining('不验证目标账号登录认证'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(model.cancelled, 0);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'cancel waits for release and targets only the originating probe future',
    (tester) async {
      final model = _ProbeModel();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HostManager(model: model)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试连接'));
      await tester.pump();
      await tester.tap(find.text('取消测试'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(model.cancelled, 1);
      expect(identical(model.cancellationTarget, model.result.future), true);
      expect(find.byType(AlertDialog), findsOneWidget);
      model.released.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
