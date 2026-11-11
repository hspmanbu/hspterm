import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/view.dart';

void main() {
  testWidgets(
    'paste preview has local line numbers, resize grip and reserved scroll rail',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TerminalPastePreview(
              text: 'first\n\n中文',
              target: 'fixture',
              lines: 3,
              bytes: 13,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('terminal-paste-editor'));
      final field = tester.widget<TextField>(input);
      expect(field.style!.fontSize, 14);
      expect(field.selectionHeightStyle, ui.BoxHeightStyle.max);
      expect(field.selectionWidthStyle, ui.BoxWidthStyle.max);
      expect(find.byKey(const ValueKey('paste-line-numbers')), findsOneWidget);
      final before = tester.getSize(input).height;
      await tester.drag(
        find.byKey(const ValueKey('paste-resize-handle')),
        const Offset(0, 40),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(input).height, greaterThan(before));
      final bar = tester.widget<RawScrollbar>(find.byType(RawScrollbar));
      expect(identical(bar.controller, field.scrollController), isTrue);
      expect(bar.interactive, isTrue);
      expect(
        tester.getRect(input).right,
        lessThan(tester.getRect(find.byType(RawScrollbar)).right - 15),
      );
      await tester.enterText(input, 'edited\n\n你好');
      await tester.pump();
      expect(field.controller!.text, 'edited\n\n你好');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
