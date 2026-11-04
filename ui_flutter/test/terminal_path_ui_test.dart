import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/view.dart';

import 'support/fake_backend.dart';

void main() {
  testWidgets(
    'a synchronous location rejection is reported after the menu closes',
    (tester) async {
      final backend = FakeBackend();
      final controller = TerminalController(backend)
        ..phase = 'Connected'
        ..id = 1;
      controller.applyFrame(fixture());
      controller.select(const Point(0, 0), const Point(3, 0));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              controller: controller,
              onLocatePath: (_) {
                throw StateError('原会话已断开');
              },
            ),
          ),
        ),
      );
      await tester.tap(
        find.byType(TerminalView),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      controller.phase = 'Disconnected';
      await tester.tap(find.text('在关联 SFTP 中定位'));
      await tester.pumpAndSettle();
      expect(controller.error, contains('原会话已断开'));
      expect(tester.takeException(), isNull);
      expect(backend.texts, isEmpty);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await backend.events.close();
    },
  );

  testWidgets(
    'local selected-path action preserves text and respects remote mouse capture',
    (tester) async {
      final backend = FakeBackend();
      final controller = TerminalController(backend)
        ..phase = 'Connected'
        ..id = 1;
      controller.applyFrame(fixture(mouse: true));
      controller.select(const Point(0, 0), const Point(3, 0));
      final text = controller.selectedText();
      final located = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              controller: controller,
              onLocatePath: (value) async {
                located.add(value);
              },
            ),
          ),
        ),
      );
      await tester.pump();
      final terminal = find.byType(TerminalView);
      await tester.tap(terminal, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('在关联 SFTP 中定位'), findsNothing);
      expect(backend.mouseActions, isNotEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(terminal, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('在关联 SFTP 中定位'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(located, [text]);
      expect(backend.texts, isEmpty);
      expect(backend.pastes, isEmpty);
      expect(controller.selectedText(), text);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await backend.events.close();
    },
  );

  testWidgets('an open menu cannot retarget a reconnected terminal', (
    tester,
  ) async {
    final backend = FakeBackend();
    final controller = TerminalController(backend)
      ..phase = 'Connected'
      ..id = 1;
    controller.applyFrame(fixture());
    controller.select(const Point(0, 0), const Point(3, 0));
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            controller: controller,
            onLocatePath: (_) async {
              calls++;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TerminalView), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    controller.generation++;
    await tester.tap(find.text('在关联 SFTP 中定位'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await backend.events.close();
  });

  testWidgets(
    'file location selects a hidden distant row once without changing other sessions',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 700);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = WorkbenchModel()..demo();
      final source = model.focus!;
      source.directories[source.path] = List.generate(
        250,
        (i) => DemoFile(
          '${source.path}/${i == 249 ? '.zz-hidden' : 'row-${i.toString().padLeft(3, '0')}'}',
          i == 249 ? '.zz-hidden' : 'row-${i.toString().padLeft(3, '0')}',
          folder: i != 249,
        ),
      );
      final last = source.files.last;
      source.pendingFileLocation = RemoteFileLocation(
        source.path,
        last.id,
        source.connectionGeneration,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Desk.theme(false),
          home: Scaffold(
            body: FilesPanel(model: model, pane: source),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('file-${last.name}'));
      expect(row, findsOneWidget);
      expect(tester.widget<Container>(row).color, isNotNull);
      expect(source.pendingFileLocation, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
