import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart';
import 'package:hspterm/workbench/file_search.dart';
import 'package:hspterm/workbench/file_search_controller.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/prototype/files.dart';

RemoteFile match(int i) => RemoteFile(
  name: '匹配$i.txt',
  path: '/root/子目录/匹配$i.txt',
  directory: false,
  symlink: false,
  size: 12,
);
RemoteFileSearchPage page({bool done = true, int offset = 0, int count = 1}) =>
    RemoteFileSearchPage(
      files: List.generate(count, (i) => match(offset + i)),
      scanned: offset + count,
      directories: 2,
      done: done,
    );

class SearchFake implements FileSearchBackend {
  final opens = <(int, int, int, String, String, bool)>[];
  final reads = <(int, int, int)>[];
  final closes = <(int, int, int)>[];
  Completer<String>? openGate;
  Completer<RemoteFileSearchPage>? pageGate;
  final pageEntered = Completer<void>();
  bool failClose = false;
  final pages = <RemoteFileSearchPage>[];
  @override
  Future<String> open(
    int id,
    int generation,
    int request,
    String path,
    String query,
    bool caseSensitive,
  ) async {
    opens.add((id, generation, request, path, query, caseSensitive));
    return openGate?.future ?? '/canonical/root';
  }

  @override
  Future<RemoteFileSearchPage> page(int id, int generation, int request) async {
    reads.add((id, generation, request));
    if (!pageEntered.isCompleted) pageEntered.complete();
    return pageGate?.future ??
        (pages.isEmpty
            ? RemoteFileSearchPage(
                files: const [],
                scanned: 0,
                directories: 1,
                done: true,
              )
            : pages.removeAt(0));
  }

  @override
  Future<void> close(int id, int generation, int request) async {
    closes.add((id, generation, request));
    if (failClose) throw StateError('synthetic channel close failure');
  }
}

FileSearchController controller(
  SearchFake backend, {
  bool Function()? current,
}) => FileSearchController(
  id: 21,
  generation: 7,
  path: '/root',
  isCurrent: current ?? () => true,
  backend: backend,
);
void main() {
  testWidgets(
    'choosing a distant result opens its directory, selects it and scrolls it into view',
    (tester) async {
      final model = WorkbenchModel()..demo();
      final source = model.focus!
        ..path = '/base'
        ..sftpEnabled = true;
      source.directories['/base'] = [];
      source.directories['/target'] = List.generate(1000, (i) {
        final name = '项目${i.toString().padLeft(4, '0')}.txt';
        return DemoFile('/target/$name', name);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilesPanel(
              model: model,
              pane: source,
              onSearchFiles: (_, captured) async {
                expect(identical(captured, source), true);
                return source.directories['/target']!.last;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('文件视图选项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('递归查找文件…'));
      await tester.pumpAndSettle();
      expect(source.path, '/target');
      final row = find.byKey(const ValueKey('file-项目0999.txt'));
      expect(row, findsOneWidget);
      final viewport = tester.getRect(find.byType(ListView));
      final rect = tester.getRect(row);
      expect(rect.top, greaterThanOrEqualTo(viewport.top));
      expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + 1));
      expect(tester.widget<Container>(row).color, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  test('only explicit search pulls pages and fresh dialogs use increasing source-scoped requests', () async {
    final fake = SearchFake()
      ..pages.addAll([page(done: false), page(offset: 1)]);
    final c = controller(fake);
    expect(fake.opens, isEmpty);
    await c.start('中文', caseSensitive: true);
    expect(c.results.length, 2);
    expect(c.done, true);
    expect(c.running, false);
    expect(c.root, '/canonical/root');
    expect(fake.opens.single.$1, 21);
    expect(fake.opens.single.$2, 7);
    expect(fake.opens.single.$5, '中文');
    expect(fake.opens.single.$6, true);
    expect(fake.closes.single, (21, 7, fake.opens.single.$3));
    await c.close();
    c.dispose();
    final second = controller(fake);
    await second.start('next');
    expect(fake.opens.last.$3, greaterThan(fake.opens.first.$3));
    await second.close();
    second.dispose();
  });
  test(
    'cancel joins a delayed page and drops results arriving after cancellation',
    () async {
      final fake = SearchFake()..pageGate = Completer();
      final c = controller(fake);
      final work = c.start('file');
      await fake.pageEntered.future;
      var joined = false;
      final cancellation = c.cancel().then((_) => joined = true);
      await Future<void>.delayed(Duration.zero);
      expect(joined, false);
      fake.pageGate!.complete(page());
      await cancellation;
      await work;
      expect(c.results, isEmpty);
      expect(c.done, false);
      expect(c.running, false);
      expect(
        fake.closes.every(
          (v) => v.$1 == 21 && v.$2 == 7 && v.$3 == fake.opens.single.$3,
        ),
        true,
      );
      await c.close();
      c.dispose();
    },
  );
  test('source generation loss rejects late results without opening another connection', () async {
    var current = true;
    final fake = SearchFake()..pageGate = Completer();
    final c = controller(fake, current: () => current);
    final work = c.start('file');
    await fake.pageEntered.future;
    current = false;
    fake.pageGate!.complete(page());
    await work;
    expect(c.results, isEmpty);
    expect(c.error, contains('原SSH会话'));
    expect(c.done, false);
    expect(fake.opens.length, 1);
    await c.close();
    c.dispose();
  });
  test('close during open waits for cleanup and never starts a page or publishes a late root', () async {
    final fake = SearchFake()..openGate = Completer();
    final c = controller(fake);
    final work = c.start('file');
    final closing = c.close();
    fake.openGate!.complete('/late/root');
    await closing;
    await work;
    expect(fake.reads, isEmpty);
    expect(c.root, '/root');
    await c.start('must not reopen');
    expect(fake.opens.length, 1);
    c.dispose();
  });
  test('cancellation from an initial listener prevents even the first network open', () async {
    final fake = SearchFake();
    final c = controller(fake);
    var requested = false;
    c.addListener(() {
      if (c.running && !requested) {
        requested = true;
        unawaited(c.cancel());
      }
    });
    await c.start('file');
    expect(fake.opens, isEmpty);
    expect(c.running, false);
    await c.close();
    c.dispose();
  });
  test('bounded results remain visibly incomplete instead of claiming a complete huge search', () async {
    final fake = SearchFake();
    for (var i = 0; i < 41; i++) {
      fake.pages.add(page(offset: i * 256, count: 256, done: false));
    }
    final c = controller(fake);
    await c.start('file');
    expect(c.results.length, FileSearchController.maxResults);
    expect(c.done, false);
    expect(c.error, contains('尚未搜索完整'));
    expect(fake.reads.length, 40);
    await c.close();
    c.dispose();
  });
  test('close failures are reported and are not silently discarded by dialog ownership', () async {
    final fake = SearchFake()..failClose = true;
    final c = controller(fake);
    await c.start('file');
    expect(c.error, contains('释放搜索通道失败'));
    await expectLater(c.close(), throwsStateError);
    c.dispose();
  });
  testWidgets('search form and virtual results fit a small scaled window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = SearchFake()..pages.add(page());
    final c = controller(fake);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: RemoteFileSearchDialog(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('file-search-query')),
      '中文',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('file-search-start')));
    await tester.tap(find.byKey(const ValueKey('file-search-start')));
    await tester.pumpAndSettle();
    expect(c.done, true);
    expect(c.results.single.name, '匹配0.txt');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await c.close();
    c.dispose();
  });
}
