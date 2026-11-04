import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/terminal/view.dart';

import '../test/native_bridge_test.dart' as native;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native runner renders and types into real SSH and TUI sessions',
    (tester) async {
      await native.exerciseNative(
        afterReady: () async {
          await tester.pump();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.descendant(
              of: find.byType(TerminalView),
              matching: find.byType(RepaintBoundary),
            ),
          );
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${Directory.systemTemp.path}/hspterm-phase2-terminal.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        },
        attach: (controller) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: TerminalView(controller: controller)),
            ),
          );
          await tester.tap(find.byType(TerminalView));
          await tester.pump();
        },
        beforeCommand: () async {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
        },
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    timeout: const Timeout(Duration(minutes: 4)),
    skip: !Platform.isLinux,
  );
}
