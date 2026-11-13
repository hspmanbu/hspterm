import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:hspterm/prototype/files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/remote_destination.dart';

import 'support/fake_backend.dart';

// Dialog routing only. Native OpenSSH/SQLite submission and partial retry are
// independently checked in live_workbench_test, not simulated as actual copies.
class _Model extends LiveWorkbenchModel {
  final fixtures = <LiveTerminalSession>[];
  final submitted = <RemoteFileSelection>[];
  RemoteFileSelection? partial;
  int? targetGeneration;
  String? destination;
  bool? relay, direct;
  @override
  List<TerminalSession> get sessions => fixtures;
  @override
  Future<List<String>> enqueueRemoteFileSelection(
    RemoteFileSelection clip,
    TerminalSession target,
    String directory,
    int expectedGeneration, {
    required bool allowMemoryRelay,
    bool allowDirect = false,
    bool Function()? shouldStop,
  }) async {
    submitted.add(clip);
    targetGeneration = expectedGeneration;
    destination = directory;
    relay = allowMemoryRelay;
    direct = allowDirect;
    final rest = partial;
    partial = null;
    if (rest != null) {
      throw RemoteFileSubmissionFailure(
        ['first'],
        rest,
        StateError('blocked second source'),
      );
    }
    return ['next'];
  }
}

Future<_Model> _fixture() async {
  final model = _Model();
  for (var i = 0; i < 2; i++) {
    final session = LiveTerminalSession(
      'session-$i',
      DemoHost('host-$i', 'fixture $i', 'loopback', 'fixture'),
      FakeBackend(),
    );
    // No transport is started in this dialog-only fixture.
    session.controller
      ..id = i + 1
      ..generation = 7 + i
      ..phase = 'Connected'
      ..connectionLabel = 'loopback:$i';
    session.sftpEnabled = true;
    session.path = '/source $i';
    session.directories[session.path] = [
      DemoFile('a', 'a 中文.txt'),
      DemoFile('b', 'b.txt'),
    ];
    model.fixtures.add(session);
  }
  return model;
}

Future<void> _mount(
  WidgetTester tester,
  _Model m, {
  bool move = false,
  RemoteDirectoryResolver? resolve,
}) async {
  final source = m.fixtures.first;
  final selection = m.prepareRemoteFileSelection(
    source,
    source.files,
    cut: move,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => RemoteDestinationDialog(
                model: m,
                selection: selection,
                targets: [RemoteDestinationTarget(m.fixtures.last)],
                resolveDirectory: resolve ?? (_, path) async => path,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'file Copy To menu requests server direct only and preserves partial acceptance',
    (tester) async {
      final m = await _fixture();
      final source = m.fixtures.first, target = m.fixtures.last;
      for (final session in m.fixtures) {
        session.disconnected = false;
        session.connectionGeneration = session.controller.generation;
      }
      m.partial = m.prepareRemoteFileSelection(source, [source.files.last]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilesPanel(model: m, pane: source),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(source.files.first.name).first);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.text(source.files.last.name).first);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(
        find.text(source.files.first.name).first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制到'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('${target.host.name} · ${target.path}'));
      await tester.pumpAndSettle();
      expect(m.relay, isFalse);
      expect(m.direct, isTrue);
      expect(m.destination, target.path);
      expect(m.submitted, hasLength(1));
      expect(m.submitted.single.paths, hasLength(2));
      expect(find.byType(RemoteDestinationDialog), findsOneWidget);
      expect(find.text('待提交 1 项 · 已入队 1 项'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('remote-destination-relay-policy')),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(
        m.submitted,
        hasLength(1),
        reason: 'failure must not silently resubmit via local relay',
      );
      await tester.pumpWidget(const SizedBox());
      await m.shutdown();
      m.dispose();
    },
  );

  testWidgets('IME candidate text cannot be submitted as a destination', (
    tester,
  ) async {
    final m = await _fixture();
    var resolutions = 0;
    await _mount(
      tester,
      m,
      resolve: (_, path) async {
        resolutions++;
        return path;
      },
    );
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('remote-destination-path')),
    );
    field.controller!.value = const TextEditingValue(
      text: '/候选',
      composing: TextRange(start: 1, end: 3),
    );
    await tester.tap(find.text('仅尝试安全直传'));
    await tester.pumpAndSettle();
    expect(resolutions, 0);
    expect(m.submitted, isEmpty);
    expect(find.textContaining('请先提交输入法候选'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await m.shutdown();
    m.dispose();
  });
  testWidgets(
    'direct-only policy stays explicit and is forwarded without relay consent',
    (tester) async {
      final m = await _fixture();
      await _mount(tester, m);
      final relay = tester.widget<CheckboxListTile>(
        find.byKey(const ValueKey('remote-destination-relay-policy')),
      );
      expect(relay.value, isFalse);
      expect(find.text('允许中转并复制'), findsNothing);
      await tester.tap(find.text('仅尝试安全直传'));
      await tester.pumpAndSettle();
      expect(m.relay, false);
      expect(m.direct, isTrue);
      expect(m.submitted, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await m.shutdown();
      m.dispose();
    },
  );
  testWidgets(
    'source reconnect during metadata resolution cannot publish late work',
    (tester) async {
      final m = await _fixture();
      final pending = Completer<String>();
      await _mount(tester, m, resolve: (_, _) => pending.future);
      await tester.tap(find.text('仅尝试安全直传'));
      await tester.pump();
      m.fixtures.first.controller.generation++;
      pending.complete('/resolved');
      await tester.pumpAndSettle();
      expect(m.submitted, isEmpty);
      expect(find.textContaining('源或目标SSH已关闭或改变'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await m.shutdown();
      m.dispose();
    },
  );
  testWidgets(
    'fixed source, explicit relay consent, target generation and clipboard independence',
    (tester) async {
      final m = await _fixture();
      m.copyRemoteFileClipboard(m.fixtures.first, [
        m.fixtures.first.files.first,
      ]);
      final revision = m.remoteFileClipboardRevision;
      await _mount(tester, m);
      await tester.ensureVisible(
        find.byKey(const ValueKey('remote-destination-relay-policy')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('remote-destination-relay-policy')),
      );
      await tester.pumpAndSettle();
      m.fixtures.first.path = '/later navigation';
      await tester.enterText(
        find.byKey(const ValueKey('remote-destination-path')),
        '/target with trailing space ',
      );
      expect(m.submitted, isEmpty);
      await tester.tap(find.text('允许中转并复制'));
      await tester.pumpAndSettle();
      expect(find.byType(RemoteDestinationDialog), findsNothing);
      expect(m.submitted.single.paths, [
        '/source 0/a 中文.txt',
        '/source 0/b.txt',
      ]);
      expect(m.destination, '/target with trailing space ');
      expect(m.targetGeneration, 8);
      expect(m.relay, true);
      expect(m.remoteFileClipboardRevision, revision);
      await tester.pumpWidget(const SizedBox());
      await m.shutdown();
      m.dispose();
    },
  );

  testWidgets('partial move submission retries only the unaccepted selection', (
    tester,
  ) async {
    final m = await _fixture();
    m.partial = m.prepareRemoteFileSelection(m.fixtures.first, [
      m.fixtures.first.files.last,
    ], cut: true);
    await _mount(tester, m, move: true);
    await tester.ensureVisible(
      find.byKey(const ValueKey('remote-destination-relay-policy')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('remote-destination-relay-policy')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认移动并允许跨服中转'));
    await tester.pumpAndSettle();
    expect(find.text('待提交 1 项 · 已入队 1 项'), findsOneWidget);
    expect(m.relay, true);
    await tester.tap(find.text('确认移动并允许跨服中转'));
    await tester.pumpAndSettle();
    expect(m.submitted, hasLength(2));
    expect(m.submitted.last.paths, ['/source 0/b.txt']);
    expect(find.byType(RemoteDestinationDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await m.shutdown();
    m.dispose();
  });

  testWidgets('stale target cannot redirect onto a reconnected SSH transport', (
    tester,
  ) async {
    final m = await _fixture();
    var resolved = 0;
    await _mount(
      tester,
      m,
      resolve: (_, path) async {
        resolved++;
        return path;
      },
    );
    m.fixtures.last.controller.generation++;
    await tester.tap(find.text('仅尝试安全直传'));
    await tester.pumpAndSettle();
    expect(m.submitted, isEmpty);
    expect(resolved, 0);
    expect(find.textContaining('源或目标SSH已关闭或改变'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await m.shutdown();
    m.dispose();
  });

  testWidgets('stop during late metadata resolution never enqueues a file', (
    tester,
  ) async {
    final m = await _fixture();
    final pending = Completer<String>();
    await _mount(tester, m, resolve: (_, _) => pending.future);
    await tester.tap(find.text('仅尝试安全直传'));
    await tester.pump();
    await tester.tap(find.text('停止继续入队'));
    pending.complete('/resolved');
    await tester.pumpAndSettle();
    expect(m.submitted, isEmpty);
    expect(find.textContaining('已停止，未继续提交任务'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await m.shutdown();
    m.dispose();
  });

  testWidgets(
    'small scaled dialog scrolls and closing has no filesystem action',
    (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final m = await _fixture();
      await _mount(tester, m);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(m.submitted, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await m.shutdown();
      m.dispose();
    },
  );
}
