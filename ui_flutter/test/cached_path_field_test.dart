import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/cached_path_field.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/design.dart';

void main() {
  testWidgets('keyboard selection scrolls the cached candidate into view', (
    tester,
  ) async {
    final controller = TextEditingController(text: '/base');
    final submitted = <String>[];
    final cache = {
      '/base': List.generate(
        30,
        (i) => DemoFile(
          '/base/f$i',
          'f${i.toString().padLeft(2, '0')}',
          folder: true,
        ),
      ),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 30,
            child: CachedPathField(
              controller: controller,
              currentDirectory: '/base',
              cache: cache,
              onSubmitted: submitted.add,
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('remote-path')), '/base/');
    await tester.pumpAndSettle();
    // The box opens unselected (-1); the first ArrowDown highlights the first
    // candidate, so the 11th press reaches '/base/f10'.
    for (var i = 0; i < 11; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    final row = find.byKey(const ValueKey('cached-path-/base/f10'));
    final viewport = tester.getRect(find.byType(ListView));
    final rect = tester.getRect(row);
    expect(rect.top, greaterThanOrEqualTo(viewport.top));
    expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(submitted, ['/base/f10']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets(
    'path text editing never invokes selected-file delete, rename or select-all',
    (tester) async {
      final model = WorkbenchModel()..demo();
      final source = model.focus!;
      source.path = '/home';
      source.directories[source.path] = [
        DemoFile('/home/keep.txt', 'keep.txt'),
        DemoFile('/home/other.txt', 'other.txt'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Scaffold(
            body: FilesPanel(model: model, pane: source),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('keep.txt'));
      await tester.pumpAndSettle();
      // Tapping the breadcrumb strip (its empty area) enters path editing.
      await tester.tap(find.byKey(const ValueKey('sftp-path-bar')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('remote-path'));
      await tester.enterText(field, '/typed');
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 1'), findsOneWidget);
      expect(
        tester.widget<TextField>(field).controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 6),
      );
      // Clicking a file row moves focus out of the path field and exits
      // editing without applying any navigation.
      await tester.tap(find.text('other.txt'));
      await tester.pumpAndSettle();
      expect(field, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(source.files, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  testWidgets('entering edit offers this session visited directories', (
    tester,
  ) async {
    // The live cache is LRU-ordered; the panel enters editing with the
    // current path intact, so the dropdown lists recently visited paths.
    final controller = TextEditingController(text: '/var/www');
    final cache = <String, List<DemoFile>>{
      '/home': [],
      '/var/log': [],
      '/var/www': [],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 200,
            child: CachedPathField(
              controller: controller,
              currentDirectory: '/var/www',
              cache: cache,
              onSubmitted: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Focus triggers RawAutocomplete to build options for the unedited text.
    await tester.tap(find.byKey(const ValueKey('remote-path')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cached-path-/home')), findsOneWidget);
    expect(find.byKey(const ValueKey('cached-path-/var/log')), findsOneWidget);
    // The current directory itself is not offered as a history entry.
    expect(find.byKey(const ValueKey('cached-path-/var/www')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  test('suggestions use cached directory keys and folder metadata, preserving names', () async {
    final cache = <String, List<DemoFile>>{
      '/': [DemoFile('/home', 'home', folder: true)],
      '/home': [
        DemoFile('/home/中文 space', '中文 space', folder: true),
        DemoFile('/home/project', 'project', folder: true),
        DemoFile('/home/file', 'file'),
        DemoFile('/home/link', 'link', symlink: true),
      ],
      '/home/project': [],
      '/home/previous': [],
    };
    final keys = cache.keys.toList();
    Future<List<String>> query(String s) =>
        cachedDirectorySuggestions(s, cache, cancelled: () => false);
    expect(await query('/home/p'), ['/home/previous', '/home/project']);
    expect(await query('/home/中'), ['/home/中文 space']);
    expect(await query('/home/f'), isEmpty);
    expect(await query('/home/l'), isEmpty); // no symlink target probe
    expect(await query('/missing/'), isEmpty);
    expect(await query('relative'), isEmpty);
    expect(await query('/bad\u0000'), isEmpty);
    expect(await query('/${'x' * 4096}'), isEmpty);
    expect(cache.keys, keys); // no cache population, LRU touch or directory IO
  });
  test(
    'large cache work yields, cancels and retains at most twelve sorted paths',
    () async {
      final files = List.generate(
        4096,
        (i) => DemoFile(
          '/base/f$i',
          'f${(4095 - i).toString().padLeft(4, '0')}',
          folder: true,
        ),
      );
      final cache = {'/base': files};
      var cancelled = false;
      final pending = cachedDirectorySuggestions(
        '/base/f',
        cache,
        cancelled: () => cancelled,
      );
      cancelled = true;
      expect(await pending, isEmpty);
      expect(
        await cachedDirectorySuggestions(
          '/base/f',
          cache,
          cancelled: () => false,
        ),
        List.generate(12, (i) => '/base/f${i.toString().padLeft(4, '0')}'),
      );
      expect(files, hasLength(4096));
    },
  );
  testWidgets('tapping a candidate fills the field and navigates immediately', (
    tester,
  ) async {
    final controller = TextEditingController(text: '/home');
    final submitted = <String>[];
    final cache = <String, List<DemoFile>>{
      '/home': [DemoFile('/home/中文 space', '中文 space', folder: true)],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 30,
            child: CachedPathField(
              controller: controller,
              currentDirectory: '/home',
              cache: cache,
              onSubmitted: submitted.add,
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('remote-path')),
      '/home/中',
    );
    await tester.pumpAndSettle();
    expect(submitted, isEmpty);
    expect(find.text('中文 space'), findsOneWidget);
    expect(find.byTooltip('/home/中文 space'), findsOneWidget);
    // New contract: a click selects and navigates in one step, like an
    // explicit Enter on that row. The tap must not fall into onTapOutside
    // (the dropdown shares the field's tap region), which would revert the
    // fill before navigation.
    await tester.tap(find.byKey(const ValueKey('cached-path-/home/中文 space')));
    await tester.pumpAndSettle();
    expect(controller.text, '/home/中文 space');
    expect(submitted, ['/home/中文 space']);
    // The dropdown closed after the selection.
    expect(find.byTooltip('/home/中文 space'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets(
    'enter with the dropdown open submits the typed text, not a candidate',
    (tester) async {
      final controller = TextEditingController(text: '/base');
      final submitted = <String>[];
      final cache = <String, List<DemoFile>>{
        '/base': [
          DemoFile('/base/f0', 'f0', folder: true),
          DemoFile('/base/f1', 'f1', folder: true),
          DemoFile('/base/f2', 'f2', folder: true),
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 30,
              child: CachedPathField(
                controller: controller,
                currentDirectory: '/base',
                cache: cache,
                onSubmitted: submitted.add,
              ),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('remote-path')),
        '/base/',
      );
      await tester.pumpAndSettle();
      // The dropdown lists candidates but none is selected by default; Enter
      // must keep the typed path verbatim instead of silently replacing it
      // with the always-highlighted first candidate.
      expect(
        find.byKey(const ValueKey('cached-path-/base/f0')),
        findsOneWidget,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(submitted, ['/base/']);
      // ArrowUp from the unselected box jumps to the last candidate; Enter
      // then submits it without rewriting the field text.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(submitted, ['/base/', '/base/f2']);
      expect(controller.text, '/base/');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'IME composing and a replaced session cannot leak old candidates',
    (tester) async {
      final controller = TextEditingController(text: '/a');
      final selected = <String>[];
      final cache = <String, List<DemoFile>>{
        '/a': [DemoFile('/a/private-a', 'private-a', folder: true)],
      };
      Future<void> mount(String key, Map<String, List<DemoFile>> cache) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 320,
                  height: 30,
                  child: CachedPathField(
                    key: ValueKey(key),
                    controller: controller,
                    currentDirectory: '/a',
                    cache: cache,
                    onSubmitted: selected.add,
                  ),
                ),
              ),
            ),
          );
      await mount('session-a', cache);
      await tester.tap(find.byKey(const ValueKey('remote-path')));
      controller.value = const TextEditingValue(
        text: '/a/pr',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 3, end: 5),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cached-path-/a/private-a')),
        findsNothing,
      );
      controller.value = const TextEditingValue(
        text: '/a/pr',
        selection: TextSelection.collapsed(offset: 5),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cached-path-/a/private-a')),
        findsOneWidget,
      );
      await mount('session-b', {});
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cached-path-/a/private-a')),
        findsNothing,
      );
      expect(selected, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
