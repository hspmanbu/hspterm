import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/prototype/model.dart';

class _HostModel extends WorkbenchModel {
  _HostModel() {
    hosts
      ..clear()
      ..add(
        DemoHost(
          'network',
          'Network fixture',
          'ssh.invalid',
          '开发环境',
          credentialSet: true,
        ),
      );
  }
  @override
  bool get isMock => false;
  DemoHost? saved;
  int writes = 0;
  @override
  Future<DemoHost> persistHost(
    DemoHost host, {
    String? secret,
    String? passphrase,
    String? proxyUsername,
    String? proxyPassword,
  }) async {
    writes++;
    saved = host.snapshot();
    return saved!;
  }
}

void main() {
  testWidgets(
    'scaled narrow host network fields scroll without overflow or losing values',
    (tester) async {
      tester.view.physicalSize = const Size(960, 720);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = _HostModel();
      final key = GlobalKey<HostManagerState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HostManager(key: key, model: model),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('网络'));
      await tester.pumpAndSettle();
      for (final (name, value) in [
        ('host-timeout', '3600'),
        ('host-keepalive', '86400'),
        ('host-keepalive-failures', '100'),
      ]) {
        final field = find.byKey(ValueKey(name));
        await tester.ensureVisible(field);
        await tester.enterText(field, value);
      }
      final save = key.currentState!.save();
      await tester.pumpAndSettle();
      expect(await save, true);
      expect(model.saved!.timeoutSeconds, 3600);
      expect(model.saved!.keepaliveSeconds, 86400);
      expect(model.saved!.keepaliveFailures, 100);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'host timeout and disabled heartbeat survive single save and validate inline',
    (tester) async {
      final model = _HostModel();
      final key = GlobalKey<HostManagerState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HostManager(key: key, model: model),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('网络'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('host-timeout')), '17');
      await tester.enterText(find.byKey(const ValueKey('host-keepalive')), '0');
      await tester.enterText(
        find.byKey(const ValueKey('host-keepalive-failures')),
        '5',
      );
      final save = key.currentState!.save();
      await tester.pumpAndSettle();
      expect(await save, true);
      expect(model.saved!.timeoutSeconds, 17);
      expect(model.saved!.keepaliveSeconds, 0);
      expect(model.saved!.keepaliveFailures, 5);
      final copy = model.saved!.copy('copy');
      expect(copy.timeoutSeconds, 17);
      expect(copy.keepaliveSeconds, 0);
      expect(copy.keepaliveFailures, 5);
      await tester.tap(find.text('网络'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('host-timeout')))
            .controller!
            .text,
        '17',
      );
      await tester.enterText(find.byKey(const ValueKey('host-timeout')), '0');
      await tester.enterText(
        find.byKey(const ValueKey('host-keepalive-failures')),
        '101',
      );
      final invalid = key.currentState!.save();
      await tester.pumpAndSettle();
      expect(await invalid, false);
      expect(model.writes, 1);
      expect(find.text('总超时须为 1–3600 秒'), findsOneWidget);
      expect(find.text('心跳失败阈值须为 1–100'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
