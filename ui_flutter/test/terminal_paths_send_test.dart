import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/terminal_paths.dart';

import 'support/fake_backend.dart';
import 'transfer_connection_selection_test.dart' show session;

class PathSessions extends LiveWorkbenchModel {
  PathSessions(this.items);
  final List<LiveTerminalSession> items;
  @override
  List<TerminalSession> get sessions => List.unmodifiable(items);
}

void main() {
  for (final outcome in ['Applied', 'Unavailable', 'Unconfirmed']) {
    testWidgets('path $outcome preserves literal source and never retries', (
      tester,
    ) async {
      final original = session('Original', 1, 4),
          other = session('Other', 2, 7);
      final model = PathSessions([original, other]);
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      final calls = <(int, int, List<String>, bool)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('send'),
                onPressed: () => sendSessionPaths(
                  context,
                  model,
                  original,
                  ["/tmp/a b'\$;.txt", '/tmp/中文'],
                  expectedGeneration: 4,
                  request: (id, generation, paths, cd) async {
                    calls.add((id, generation, paths, cd));
                    return outcome;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('send'));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      expect(calls.single.$1, 1);
      expect(calls.single.$2, 4);
      expect(calls.single.$3, ["/tmp/a b'\$;.txt", '/tmp/中文']);
      expect(calls.single.$4, false);
      expect(
        clipboard,
        outcome == 'Unavailable'
            ? ["'/tmp/a b'\\''\$;.txt' '/tmp/中文'"]
            : isEmpty,
      );
      expect(other.controller.generation, 7);
      if (outcome == 'Unavailable') {
        await tester.tap(find.text('发送说明'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Bash 5.1+'), findsOneWidget);
        expect(original.host.shellIntegration, false);
        expect(
          calls.length,
          1,
          reason: 'help never enables integration or repeats input',
        );
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      await model.shutdown();
      model.dispose();
    });
  }
  testWidgets(
    'stale generation copies without targeting the reconnected session',
    (tester) async {
      final source = session('Reconnected', 1, 5);
      final model = PathSessions([source]);
      var requests = 0;
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('cd'),
                onPressed: () => sendSessionPaths(
                  context,
                  model,
                  source,
                  ['/tmp/a b'],
                  enterDirectory: true,
                  expectedGeneration: 4,
                  request: (_, _, _, _) async {
                    requests++;
                    return 'Applied';
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('cd'));
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(copied, "cd '/tmp/a b'");
      await tester.pumpWidget(const SizedBox());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      await model.shutdown();
      model.dispose();
    },
  );
  test('drag snapshot cannot change when the source row is renamed', () {
    final file = DemoFile(
      'one',
      'original',
      folder: false,
      size: '0',
      kind: 'file',
      modified: 'now',
    );
    final drag = RemoteDrag('source', '/tmp', [file], generation: 4);
    file.name = 'renamed';
    expect(drag.files.single.name, 'original');
    expect(() => drag.files.clear(), throwsUnsupportedError);
  });

  testWidgets('unavailable insert direct-pastes quoted paths when allowed', (
    tester,
  ) async {
    final original = session('Original', 1, 4);
    final model = PathSessions([original]);
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('send'),
              onPressed: () => sendSessionPaths(
                context,
                model,
                original,
                ["/tmp/a b'.txt"],
                expectedGeneration: 4,
                request: (id, generation, paths, cd) async => 'Unavailable',
                directPasteAllowed: () async => true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('send'));
    await tester.pumpAndSettle();
    final backend = original.controller.backend as FakeBackend;
    expect(
      backend.pastes.single.$1,
      "'/tmp/a b'\\''.txt'",
      reason: 'quoted literal, no Enter, no newline',
    );
    expect(backend.pastes.single.$2, isFalse);
    expect(clipboard, isEmpty, reason: 'no clipboard fallback when pasted');
    expect(find.textContaining('普通终端粘贴'), findsOneWidget);
  });

  testWidgets('direct paste disabled keeps the clipboard-only fallback', (
    tester,
  ) async {
    final original = session('Original', 1, 4);
    final model = PathSessions([original]);
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('send'),
              onPressed: () => sendSessionPaths(
                context,
                model,
                original,
                ['/tmp/x'],
                request: (id, generation, paths, cd) async => 'Unavailable',
                directPasteAllowed: () async => false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('send'));
    await tester.pumpAndSettle();
    expect(
      (original.controller.backend as FakeBackend).pastes,
      isEmpty,
      reason: 'never pastes when the preference is off',
    );
    expect(clipboard, ["'/tmp/x'"]);
  });

  testWidgets('disconnected session never direct-pastes', (tester) async {
    final original = session('Original', 1, 4);
    final model = PathSessions([original]);
    original.controller.phase = 'Disconnected';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('send'),
              onPressed: () => sendSessionPaths(
                context,
                model,
                original,
                ['/tmp/x'],
                request: (id, generation, paths, cd) async => 'Unavailable',
                directPasteAllowed: () async => true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('send'));
    await tester.pumpAndSettle();
    expect(
      (original.controller.backend as FakeBackend).pastes,
      isEmpty,
      reason: 'a dead session must not receive pasted paths',
    );
  });

  testWidgets('cd variant never direct-pastes', (tester) async {
    final original = session('Original', 1, 4);
    final model = PathSessions([original]);
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('send'),
              onPressed: () => sendSessionPaths(
                context,
                model,
                original,
                ['/tmp/dir'],
                enterDirectory: true,
                request: (id, generation, paths, cd) async => 'Unavailable',
                directPasteAllowed: () async => true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('send'));
    await tester.pumpAndSettle();
    expect(
      (original.controller.backend as FakeBackend).pastes,
      isEmpty,
      reason: 'cd stays clipboard-only; Enter must stay manual',
    );
    expect(clipboard, ["cd '/tmp/dir'"]);
  });
}
