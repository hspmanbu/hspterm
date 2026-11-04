import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/prototype/model.dart';

class ShellIntegrationTestHosts extends WorkbenchModel {
  @override
  bool get isMock => false;
  final drafts = <DemoHost>[];
  @override
  Future<void> persistDraft(
    DemoHost host, {
    String? secret,
    String? passphrase,
    String? proxyUsername,
    String? proxyPassword,
  }) async {
    drafts.add(host.snapshot());
  }
}

Future<void> mount(
  WidgetTester tester,
  ShellIntegrationTestHosts model,
  GlobalKey<HostManagerState> key,
) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HostManager(key: key, model: model),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('终端').first);
  await tester.pumpAndSettle();
  await tester.ensureVisible(
    find.byKey(const ValueKey('host-shell-integration')),
  );
}

void main() {
  testWidgets(
    'per-host integration requires explicit consent and stays a draft before save',
    (tester) async {
      final model = ShellIntegrationTestHosts();
      final key = GlobalKey<HostManagerState>();
      await mount(tester, model, key);
      final original = model.hosts.first;
      expect(key.currentState!.shellIntegration, false);
      await tester.tap(find.byKey(const ValueKey('host-shell-integration')));
      await tester.pumpAndSettle();
      expect(find.text('为此主机启用可选 Shell 集成？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(key.currentState!.shellIntegration, false);
      expect(key.currentState!.dirty, false);
      await tester.tap(find.byKey(const ValueKey('host-shell-integration')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许此主机使用'));
      await tester.pumpAndSettle();
      expect(key.currentState!.shellIntegration, true);
      expect(key.currentState!.dirty, true);
      expect(original.shellIntegration, false);
      expect(key.currentState!.snapshot().shellIntegration, true);
      final copy = key.currentState!.snapshot().copy('new-host-fixture');
      expect(copy.shellIntegration, false);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets('an old consent dialog cannot enable a later host form', (
    tester,
  ) async {
    final model = ShellIntegrationTestHosts();
    final key = GlobalKey<HostManagerState>();
    await mount(tester, model, key);
    await tester.tap(find.byKey(const ValueKey('host-shell-integration')));
    await tester.pumpAndSettle();
    key.currentState!.load(model.hosts.last);
    await tester.tap(find.text('允许此主机使用'));
    await tester.pumpAndSettle();
    expect(key.currentState!.shellIntegration, false);
    expect(key.currentState!.dirty, false);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
}
