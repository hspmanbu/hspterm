import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/terminal/view.dart';

import '../test/osc8_bridge_test.dart' show exerciseOsc8, osc8Target;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK real OSC8 label hover and explicit Ctrl click use full original URI without network preview',
    (tester) async {
      final opened = <String>[];
      await exerciseOsc8(
        attach: (c) async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: TerminalView(
                  controller: c,
                  onOpenLink: (link) async {
                    opened.add(link.text);
                  },
                ),
              ),
            ),
          );
          await tester.pump();
        },
        afterLinked: (c) async {
          await tester.pump();
          expect(opened, isEmpty);
          final point =
              tester.getTopLeft(find.byType(TerminalView)) + const Offset(5, 5);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: point);
          await mouse.moveTo(point + const Offset(1, 1));
          await tester.pump(const Duration(milliseconds: 700));
          expect(find.byTooltip(osc8Target), findsOneWidget);
          expect(opened, isEmpty);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.tapAt(point);
          await tester.pump();
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          expect(opened, [osc8Target]);
          await mouse.removePointer();
          expect(c.connected, true);
          expect(tester.takeException(), isNull);
        },
        detach: () async {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    },
  );
}
