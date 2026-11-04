import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/terminal/view.dart';

import '../test/codex_cli_test.dart' show exerciseCodex;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Codex normal/alternate screens render and accept Flutter keys',
    (tester) async {
      var capture = 0;
      await exerciseCodex(
        attach: (controller) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: TerminalView(controller: controller)),
            ),
          );
          await tester.tap(find.byType(TerminalView));
          await tester.pump();
        },
        physicalKey: (name, mods) async {
          final key = switch (name) {
            'ArrowUp' => LogicalKeyboardKey.arrowUp,
            'ArrowDown' => LogicalKeyboardKey.arrowDown,
            'ArrowLeft' => LogicalKeyboardKey.arrowLeft,
            'ArrowRight' => LogicalKeyboardKey.arrowRight,
            'Enter' => LogicalKeyboardKey.enter,
            'Tab' => LogicalKeyboardKey.tab,
            'Escape' => LogicalKeyboardKey.escape,
            'a' => LogicalKeyboardKey.keyA,
            'e' => LogicalKeyboardKey.keyE,
            'b' => LogicalKeyboardKey.keyB,
            'f' => LogicalKeyboardKey.keyF,
            'c' => LogicalKeyboardKey.keyC,
            _ => throw StateError('Unmapped test key $name'),
          };
          final modifiers = [
            if (mods & 1 != 0) LogicalKeyboardKey.shiftLeft,
            if (mods & 2 != 0) LogicalKeyboardKey.altLeft,
            if (mods & 4 != 0) LogicalKeyboardKey.controlLeft,
          ];
          for (final mod in modifiers) {
            await tester.sendKeyDownEvent(mod);
          }
          await tester.sendKeyEvent(key);
          for (final mod in modifiers.reversed) {
            await tester.sendKeyUpEvent(mod);
          }
          await tester.pump();
        },
        capture: () async {
          await tester.pump();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.descendant(
              of: find.byType(TerminalView),
              matching: find.byType(RepaintBoundary),
            ),
          );
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${Directory.systemTemp.path}/hspterm-codex-${capture++}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        },
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    timeout: const Timeout(Duration(minutes: 4)),
    skip: !Platform.isLinux || !File("/usr/bin/codex").existsSync(),
  );
}
