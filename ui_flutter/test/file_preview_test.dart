import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/previews.dart' as data;
import 'package:hspterm/workbench/file_preview.dart';
import 'package:hspterm/workbench/model.dart';

import 'support/fake_backend.dart';

class DeferredCacheModel extends LiveWorkbenchModel {
  final ready = Completer<void>();
  @override
  Future<void> initializePreviewCache() => ready.future;
}

data.FilePreview state(
  String phase, {
  String? path,
  int? total,
  int confirmationMib = 100,
}) => data.FilePreview(
  token: 'fixture',
  phase: phase,
  received: 0,
  total: total,
  confirmationMib: confirmationMib,
  localPath: path,
  remotePath: '/fixture.txt',
  name: 'fixture.txt',
);

class Backend implements FilePreviewBackend {
  Backend(this.run);
  final Future<data.FilePreview> Function(bool) run;
  final calls = <bool>[];
  int cancels = 0, polls = 0;
  @override
  Future<data.FilePreview> prepare(String token, bool allowLarge) {
    calls.add(allowLarge);
    return run(allowLarge);
  }

  @override
  data.FilePreview progress(String token) {
    polls++;
    return state('Downloading');
  }

  @override
  Future<void> cancel(String token) async {
    cancels++;
  }
}

Future<void> mount(
  WidgetTester tester,
  Backend backend,
  Future<void> Function(String) opener,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Desk.theme(false),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => FilePreviewDialog(
              token: 'fixture',
              host: 'Fixture host',
              name: 'fixture.txt',
              backend: backend,
              opener: opener,
              onCleanupError: (e) => fail('unexpected cleanup error: $e'),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets(
    'cache initialization cannot retarget a stale file to a new SSH generation',
    (tester) async {
      final model = DeferredCacheModel();
      final backend = FakeBackend();
      final source = LiveTerminalSession(
        'source',
        DemoHost('fixture', 'Fixture', 'fixture.invalid', '未分组'),
        backend,
      );
      source.controller
        ..id = 1
        ..phase = 'Connected'
        ..generation = 4;
      source.path = '/files';
      final file = DemoFile('/files/readme.txt', 'readme.txt');
      source.directories[source.path] = [file];
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      final pending = showFilePreview(context, model, source, file);
      final result = expectLater(
        pending,
        throwsA(predicate((e) => e.toString().contains('会话已改变'))),
      );
      source.controller.generation++;
      model.ready.complete();
      await result;
      source.directories[source.path] = [DemoFile(file.id, file.name)];
      await expectLater(
        showFilePreview(context, model, source, file),
        throwsA(predicate((e) => e.toString().contains('目录内容已更新'))),
      );
      final next = DeferredCacheModel();
      source.directories[source.path] = [file];
      final navigation = showFilePreview(context, next, source, file);
      final changedDirectory = expectLater(
        navigation,
        throwsA(predicate((e) => e.toString().contains('目录内容已更新'))),
      );
      source.directoryEpoch++;
      next.ready.complete();
      await changedDirectory;
      await next.shutdown();
      next.dispose();
      expect(backend.texts, isEmpty);
      await source.controller.shutdown();
      source.controller.dispose();
      await model.shutdown();
      model.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('cancel suppresses late external launch and stops polling', (
    tester,
  ) async {
    final result = Completer<data.FilePreview>();
    final backend = Backend((_) => result.future);
    var launches = 0;
    await mount(tester, backend, (_) async {
      launches++;
    });
    await tester.tap(find.byKey(const ValueKey('preview-cancel')));
    await tester.pumpAndSettle();
    result.complete(state('Ready', path: '/fixture/preview.txt'));
    await tester.pump();
    expect(backend.cancels, 1);
    expect(launches, 0);
    final polls = backend.polls;
    await tester.pump(const Duration(seconds: 1));
    expect(backend.polls, polls);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'large preview requires explicit consent then retains successful cache',
    (tester) async {
      final ready = Completer<data.FilePreview>();
      final backend = Backend(
        (allow) => allow
            ? ready.future
            : Future.value(
                state('NeedsConfirmation', total: 100 * 1024 * 1024 + 1),
              ),
      );
      var launches = 0;
      await mount(tester, backend, (_) async {
        launches++;
      });
      await tester.pumpAndSettle();
      expect(backend.calls, [false]);
      expect(launches, 0);
      expect(find.text('打开大文件？'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('preview-confirm-large')));
      await tester.tap(find.byKey(const ValueKey('preview-confirm-large')));
      expect(backend.calls, [false, true]);
      ready.complete(state('Ready', path: '/fixture/preview.txt'));
      await tester.pumpAndSettle();
      expect(backend.calls, [false, true]);
      expect(launches, 1);
      expect(backend.cancels, 0);
      expect(find.byType(FilePreviewDialog), findsNothing);
    },
  );
  testWidgets('always confirm describes and gates even an empty file', (
    tester,
  ) async {
    final backend = Backend(
      (_) async => state('NeedsConfirmation', total: 0, confirmationMib: 0),
    );
    var launches = 0;
    await mount(tester, backend, (_) async {
      launches++;
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('已设置每次打开都确认'), findsOneWidget);
    expect(find.text('确认打开远端文件？'), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-confirm-large')), findsOneWidget);
    expect(launches, 0);
    await tester.tap(find.byKey(const ValueKey('preview-cancel')));
    await tester.pumpAndSettle();
    expect(backend.calls, [false]);
    expect(backend.cancels, 1);
    expect(launches, 0);
  });
  testWidgets(
    'failed system association can retry without idle polling or redownload',
    (tester) async {
      final backend = Backend(
        (_) async => state('Ready', path: '/fixture/preview.txt'),
      );
      var launches = 0;
      await mount(tester, backend, (_) async {
        if (++launches == 1) throw StateError('controlled no association');
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('controlled no association'), findsOneWidget);
      final polls = backend.polls;
      await tester.pump(const Duration(seconds: 1));
      expect(backend.polls, polls);
      await tester.tap(find.text('重新尝试打开'));
      await tester.pumpAndSettle();
      expect(backend.calls, [false]);
      expect(launches, 2);
      expect(backend.cancels, 0);
      expect(find.byType(FilePreviewDialog), findsNothing);
    },
  );
}
