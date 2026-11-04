import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/store.dart';

const _key = KeyDetails('fixture-public-key', 'fixture-fingerprint', 'ed25519');

class _FormalHosts extends WorkbenchModel {
  _FormalHosts() {
    hosts
      ..clear()
      ..add(DemoHost('host-fixture', 'Before save', 'example.invalid', '开发环境'));
  }
  int keyPreparations = 0;
  String? savedSecret;
  @override
  bool get isMock => false;
  @override
  Future<void> persistDraft(
    DemoHost host, {
    String? secret,
    String? passphrase,
    String? proxyUsername,
    String? proxyPassword,
  }) async {}
  @override
  Future<DemoHost> persistHost(
    DemoHost host, {
    String? secret,
    String? passphrase,
    String? proxyUsername,
    String? proxyPassword,
  }) async {
    savedSecret = secret;
    saveHost(host);
    return host;
  }

  @override
  Future<KeyDetails> prepareKey(
    DemoHost host, {
    String? path,
    String? passphrase,
  }) async {
    keyPreparations++;
    throw KeyPreparationRefreshFailure(_key, StateError('fixture refresh'));
  }
}

class _KeyStore extends Fake implements HostStore {
  int generated = 0, imported = 0;
  rust.HostKeyInfo get key => rust.HostKeyInfo(
    publicKey: _key.publicKey,
    fingerprint: _key.fingerprint,
    algorithm: _key.algorithm,
  );
  @override
  Future<rust.HostKeyInfo> generate(
    rust.HostConfig host,
    String? passphrase,
  ) async {
    generated++;
    return key;
  }

  @override
  Future<rust.HostKeyInfo> importKey(
    rust.HostConfig host,
    String path,
    String? passphrase,
  ) async {
    imported++;
    return key;
  }

  @override
  Future<List<rust.HostConfig>> hosts() async =>
      throw StateError('fixture refresh');
}

Future<void> _mount(
  WidgetTester tester,
  WorkbenchModel model,
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
}

void main() {
  testWidgets(
    'choosing the same row preserves fields saved by the leave prompt',
    (tester) async {
      final model = _FormalHosts(), key = GlobalKey<HostManagerState>();
      await _mount(tester, model, key);
      await tester.enterText(
        find.byKey(const ValueKey('host-主机名称')),
        'After save',
      );
      await tester.tap(find.byKey(const ValueKey('host-row-host-fixture')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(key.currentState!.name.text, 'After save');
      expect(key.currentState!.dirty, false);
      expect(model.hosts.single.name, 'After save');
      expect(await key.currentState!.save(), true);
      expect(model.hosts.single.name, 'After save');
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'a missing target after leave does not restore its stale object',
    (tester) async {
      final model = _FormalHosts(), key = GlobalKey<HostManagerState>();
      await _mount(tester, model, key);
      final stale = model.hosts.single;
      model.hosts.clear();
      key.currentState!.name.text = 'Keep current form';
      await key.currentState!.choose(stale);
      expect(key.currentState!.name.text, 'Keep current form');
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets('key ACK clears old secret even when catalog refresh fails', (
    tester,
  ) async {
    final model = _FormalHosts(), key = GlobalKey<HostManagerState>();
    await _mount(tester, model, key);
    await tester.tap(find.text('认证').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('host-secret')),
      'old-fixture-secret',
    );
    await tester.enterText(
      find.byKey(const ValueKey('host-passphrase')),
      'old-fixture-phrase',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('generate-host-key')));
    await tester.tap(find.byKey(const ValueKey('generate-host-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '生成新密钥'));
    await tester.pumpAndSettle();
    expect(find.text(_key.fingerprint), findsOneWidget);
    expect(model.keyPreparations, 1);
    expect(key.currentState!.secret.text, isEmpty);
    expect(key.currentState!.passphrase.text, isEmpty);
    expect(key.currentState!.dirty, true);
    expect(key.currentState!.saveError, contains('密钥已写入加密草稿'));
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pumpAndSettle();
    final save = key.currentState!.save();
    await tester.pumpAndSettle();
    expect(await save, true);
    expect(model.savedSecret, isNull);
    expect(model.keyPreparations, 1);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });

  for (final importing in [false, true]) {
    test(
      'key ${importing ? 'import' : 'generation'} ACK survives metadata refresh failure',
      () async {
        final store = _KeyStore();
        final observed = LiveWorkbenchModel(store: store);
        try {
          await expectLater(
            observed.prepareKey(
              DemoHost('host-fixture', 'Fixture', 'example.invalid', '未分组'),
              path: importing ? '/fixture-only/key' : null,
            ),
            throwsA(
              isA<KeyPreparationRefreshFailure>().having(
                (error) => error.saved.fingerprint,
                'acknowledged fingerprint',
                _key.fingerprint,
              ),
            ),
          );
          expect(store.generated, importing ? 0 : 1);
          expect(store.imported, importing ? 1 : 0);
        } finally {
          observed.dispose();
        }
      },
    );
  }
}
