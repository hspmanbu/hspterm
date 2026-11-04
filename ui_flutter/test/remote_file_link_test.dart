import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/terminal/links.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/terminal_links.dart';

import 'support/fake_backend.dart';

// Routing-only fixture; real endpoint/URI decoding and SFTP are independently
// exercised by terminal_path_bridge_test.dart over private OpenSSH.
class _Model extends LiveWorkbenchModel {
  final located = <(TerminalSession, String)>[];
  late final source = LiveTerminalSession(
    'source',
    DemoHost('host', 'Fixture', '127.0.0.1', 'group'),
    FakeBackend(),
  );
  @override
  List<TerminalTab> get tabs => [TerminalTab('tab', source.id, 'Fixture')];
  @override
  Future<void> locateTerminalPath(TerminalSession source, String text) async {
    located.add((source, text));
  }
}

void main() {
  testWidgets(
    'file links locate the captured SSH source and never enter browser or forwarding flow',
    (tester) async {
      final model = _Model();
      final c = model.source.controller
        ..id = 1
        ..generation = 4
        ..phase = 'Connected';
      final launched = <Uri>[];
      Future<void>? pending;
      Object? failure;
      const target = 'file:///C:/Users/fixture%20name/file.txt';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              child: const Text('open'),
              onPressed: () {
                failure = null;
                pending = openTerminalLink(
                  context,
                  model,
                  model.source,
                  TerminalLink.parse(target)!,
                  launcher: (uri) async {
                    launched.add(uri);
                    return true;
                  },
                );
                unawaited(
                  pending!.catchError((Object error) {
                    failure = error;
                  }),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await pending;
      expect(failure, isNull);
      expect(model.located.single, (model.source, target));
      expect(launched, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      c.phase = 'Disconnected';
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(failure, isA<StateError>());
      expect(model.located.length, 1);
      expect(launched, isEmpty);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      model.dispose();
    },
  );
  for (final choice in ['定位文件', '按原文路径定位', '取消']) {
    testWidgets(
      'path location choice $choice remains in its captured SSH and never opens a browser',
      (tester) async {
        final model = _Model();
        final controller = model.source.controller
          ..id = 1
          ..generation = 4
          ..phase = 'Connected';
        final launched = <Uri>[];
        Future<void>? pending;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  pending = openTerminalLink(
                    context,
                    model,
                    model.source,
                    TerminalLink.parse('/tmp/fixture.rs:12:3')!,
                    launcher: (uri) async {
                      launched.add(uri);
                      return true;
                    },
                  );
                },
                child: const Text('locate'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('locate'));
        await tester.pumpAndSettle();
        expect(model.located, isEmpty);
        expect(launched, isEmpty);
        expect(find.textContaining('第 12 行'), findsOneWidget);
        await tester.tap(find.text(choice));
        await tester.pumpAndSettle();
        await pending;
        if (choice == '取消') {
          expect(model.located, isEmpty);
        } else {
          expect(model.located.single, (
            model.source,
            choice == '定位文件' ? '/tmp/fixture.rs' : '/tmp/fixture.rs:12:3',
          ));
        }
        expect(launched, isEmpty);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        model.dispose();
      },
    );
  }
  testWidgets(
    'a path confirmation cannot act on a reconnected terminal generation',
    (tester) async {
      final model = _Model();
      final controller = model.source.controller
        ..id = 1
        ..generation = 4
        ..phase = 'Connected';
      Future<void>? pending;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                pending = openTerminalLink(
                  context,
                  model,
                  model.source,
                  TerminalLink.parse('./fixture.rs:12')!,
                );
              },
              child: const Text('locate'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('locate'));
      await tester.pumpAndSettle();
      controller.generation = 5;
      await tester.tap(find.text('定位文件'));
      await tester.pumpAndSettle();
      await pending;
      expect(model.located, isEmpty);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      model.dispose();
    },
  );
}
