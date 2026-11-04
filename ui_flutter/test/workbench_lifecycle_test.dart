import 'package:hspterm/src/rust/shortcut_settings.dart';

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/store.dart';

import 'support/fake_backend.dart';

class _Catalog extends Fake implements HostStore {
  @override
  Future<List<rust.HostConfig>> hosts() async => [
    rust.HostConfig(
      id: 'host-00000000000000000000000000000001',
      name: 'Lifecycle fixture',
      address: '127.0.0.1',
      port: 22,
      username: 'fixture',
      privateKey: true,
      groupId: 'group-default',
      favorite: false,
      note: '',
      credentialSet: true,
      timeoutSeconds: 30,
      keepaliveSeconds: 30,
      keepaliveFailures: 3,
      openSftp: false,
    ),
  ];
  @override
  Future<List<rust.HostGroupConfig>> groups() async => [
    rust.HostGroupConfig(id: 'group-default', name: '未分组'),
  ];
  @override
  Future<List<rust.HostConfig>> drafts() async => [];
}

class _PendingBackend extends FakeBackend {
  final created = Completer<int>();
  @override
  Future<int> create() => created.future;
}

class _FailedCloseOnce extends FakeBackend {
  bool fail = true;
  @override
  Future<void> close(int id) async {
    closes++;
    if (fail) {
      fail = false;
      throw StateError('synthetic failed checkpoint');
    }
    await events.close();
  }
}

LiveWorkbenchModel retryModel(FakeBackend backend) => LiveWorkbenchModel(
  store: _Catalog(),
  backendFactory: () => backend,
  paletteLoader: () async => const PaletteShortcutView(
    vaultScope: 'fake-scope',
    revision: 'fake-revision',
    enabled: true,
    key: 'KeyP',
    modifiers: 5,
    applicationInTerminal: false,
  ),
);

class _DelayedSave extends WorkbenchModel {
  final saved = Completer<void>();
  @override
  Future<DemoHost> persistHost(
    DemoHost host, {
    String? secret,
    String? passphrase,
    String? proxyUsername,
    String? proxyPassword,
  }) async {
    await saved.future;
    return super.persistHost(
      host,
      secret: secret,
      passphrase: passphrase,
      proxyUsername: proxyUsername,
      proxyPassword: proxyPassword,
    );
  }
}

void main() {
  test(
    'removed tabs retain failed native cleanup until explicit retry',
    () async {
      final backend = _FailedCloseOnce();
      final model = retryModel(backend);
      await model.load();
      model.openHost(model.hosts.single);
      await Future<void>.delayed(Duration.zero);
      model.closeTab(model.tabs.single.id);
      await Future<void>.delayed(Duration.zero);
      expect(model.sessions, isEmpty);
      expect(model.hasRetiringSessions, true);
      expect(model.hasActiveSessions, true);
      await model.retryRetiringSessions();
      expect(model.hasRetiringSessions, false);
      expect(backend.closes, 2);
      await model.shutdown();
      model.dispose();
    },
  );
  test(
    'application retries terminal retirement without reopening a transport',
    () async {
      final backend = _FailedCloseOnce();
      final model = retryModel(backend);
      await model.load();
      model.openHost(model.hosts.single);
      await Future<void>.delayed(Duration.zero);
      final source = model.focus! as LiveTerminalSession;
      final connects = backend.connects;
      await expectLater(model.shutdown(), throwsStateError);
      expect(source.controller.isClosing, true);
      expect(source.controller.id, 1);
      expect(source.controller.connected, false);
      expect(model.hasActiveSessions, true);
      await model.shutdown();
      expect(source.controller.shutdownComplete, true);
      expect(backend.closes, 2);
      expect(backend.connects, connects);
      model.dispose();
    },
  );

  testWidgets('an in-flight explicit save cannot be discarded by navigation', (
    tester,
  ) async {
    final model = _DelayedSave();
    final key = GlobalKey<HostManagerState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostManager(key: key, model: model),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('host-主机名称')),
      'Save in flight',
    );
    final save = key.currentState!.save();
    await tester.pump();
    expect(
      await key.currentState!.canLeave().timeout(const Duration(seconds: 1)),
      false,
    );
    expect(find.byType(AlertDialog), findsNothing);
    model.saved.complete();
    expect(await save, true);
    expect(await key.currentState!.canLeave(), true);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    model.dispose();
  });
  test(
    'closing a tab during native creation releases the eventual handle',
    () async {
      final backend = _PendingBackend();
      final model = LiveWorkbenchModel(
        store: _Catalog(),
        paletteLoader: () async => const PaletteShortcutView(
          vaultScope: 'fake-scope',
          revision: 'fake-revision',
          enabled: true,
          key: 'KeyP',
          modifiers: 5,
          applicationInTerminal: false,
        ),
        backendFactory: () => backend,
      );
      await model.load();
      model.openHost(model.hosts.single);
      model.closeTab(model.tabs.single.id);
      expect(model.sessions, isEmpty);
      backend.created.complete(7);
      await model.shutdown();
      expect(backend.closes, 1);
      expect(backend.connects, 0);
      model.dispose();
    },
  );

  test(
    'application shutdown waits for pending native creation and release',
    () async {
      final backend = _PendingBackend();
      final model = LiveWorkbenchModel(
        store: _Catalog(),
        paletteLoader: () async => const PaletteShortcutView(
          vaultScope: 'fake-scope',
          revision: 'fake-revision',
          enabled: true,
          key: 'KeyP',
          modifiers: 5,
          applicationInTerminal: false,
        ),
        backendFactory: () => backend,
      );
      await model.load();
      model.openHost(model.hosts.single);
      var finished = false;
      final closing = model.shutdown().then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      expect(finished, false);
      backend.created.complete(8);
      await closing;
      expect(backend.closes, 1);
      expect(backend.connects, 0);
      model.dispose();
    },
  );

  test(
    'disposing the old display cannot hide a newly mounted session view',
    () async {
      final backend = FakeBackend();
      final model = LiveWorkbenchModel(
        store: _Catalog(),
        paletteLoader: () async => const PaletteShortcutView(
          vaultScope: 'fake-scope',
          revision: 'fake-revision',
          enabled: true,
          key: 'KeyP',
          modifiers: 5,
          applicationInTerminal: false,
        ),
        backendFactory: () => backend,
      );
      await model.load();
      model.openHost(model.hosts.single);
      await Future<void>.delayed(Duration.zero);
      final session = model.focus! as LiveTerminalSession;
      final oldView = session.attachView();
      final currentView = session.attachView();
      session.detachView(oldView);
      expect(session.controller.visible, true);
      expect(backend.closes, 0);
      session.detachView(currentView);
      expect(session.controller.visible, false);
      await model.shutdown();
      expect(backend.closes, 1);
      model.dispose();
    },
  );
}
