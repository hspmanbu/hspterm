import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/prototype/model.dart';

class _Model extends WorkbenchModel {
  _Model({String? jump, bool proxyConflict = false}) {
    const proxy = DemoProxy(socks5: true, address: 'proxy.invalid', port: 1080);
    hosts
      ..clear()
      ..addAll([
        DemoHost(
          'target',
          'Target fixture',
          'target.invalid',
          '开发环境',
          credentialSet: true,
          jumpHostId: jump,
          proxy: proxyConflict ? proxy : null,
        ),
        DemoHost(
          'jump',
          'Jump fixture',
          'jump.invalid',
          '开发环境',
          credentialSet: true,
          proxy: proxyConflict ? proxy : null,
        ),
        DemoHost(
          'nested',
          'Already nested fixture',
          'other.invalid',
          '开发环境',
          credentialSet: true,
          jumpHostId: 'jump',
        ),
      ]);
  }
  @override
  bool get isMock => false;
  DemoHost? saved;
  @override
  Future<DemoHost> persistHost(
    DemoHost host, {
    String? secret,
    String? passphrase,
    String? proxyUsername,
    String? proxyPassword,
  }) async => saved = host.snapshot();
}

void main() {
  Future<GlobalKey<HostManagerState>> mount(
    WidgetTester tester,
    _Model model,
  ) async {
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
    await tester.ensureVisible(find.byKey(const ValueKey('host-jump-target')));
    return key;
  }

  testWidgets(
    'jump chooser excludes self and nested saved routes and preserves explicit selection',
    (tester) async {
      final model = _Model();
      final key = await mount(tester, model);
      await tester.tap(find.byKey(const ValueKey('host-jump-target')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Target fixture ·'), findsNothing);
      expect(find.textContaining('Already nested fixture ·'), findsNothing);
      await tester.tap(find.textContaining('Jump fixture ·').last);
      await tester.pumpAndSettle();
      final save = key.currentState!.save();
      await tester.pumpAndSettle();
      expect(await save, true);
      expect(model.saved!.jumpHostId, 'jump');
      expect(model.saved!.copy('copy').jumpHostId, 'jump');
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'deleted jump stays invalid until the user explicitly chooses another route',
    (tester) async {
      final model = _Model(jump: 'deleted');
      final key = await mount(tester, model);
      expect(find.text('失效的跳板配置 · 请重新选择'), findsOneWidget);
      var save = key.currentState!.save();
      await tester.pumpAndSettle();
      expect(await save, false);
      expect(find.textContaining('跳板主机已删除或未保存'), findsOneWidget);
      expect(model.saved, isNull);
      await tester.tap(find.byKey(const ValueKey('host-jump-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('无跳板机').last);
      await tester.pumpAndSettle();
      save = key.currentState!.save();
      await tester.pumpAndSettle();
      expect(await save, true);
      expect(model.saved!.jumpHostId, isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets(
    'target and selected jump cannot silently choose between two proxies',
    (tester) async {
      final model = _Model(jump: 'jump', proxyConflict: true);
      final key = await mount(tester, model);
      final save = key.currentState!.save();
      await tester.pumpAndSettle();
      expect(await save, false);
      expect(find.text('目标与跳板只允许配置一个代理'), findsOneWidget);
      expect(model.saved, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
