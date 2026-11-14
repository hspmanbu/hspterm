import 'package:hspterm/terminal/paste_editor.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/view.dart';

void main() {
  testWidgets(
    'paste preview has local line numbers, resize grip and reserved scroll rail',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(1600, 1200);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
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
      final inputContext = tester.element(input);
      expect(field.style!.fontFamily, 'JetBrainsMono');
      expect(field.style!.letterSpacing, 0);
      expect(field.style!.wordSpacing, 0);
      expect(field.autocorrect, false);
      expect(field.enableSuggestions, false);
      expect(field.textInputAction, TextInputAction.newline);
      expect(TextSelectionTheme.of(inputContext).selectionColor!.a, 1);

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
      final grip = find.byKey(const ValueKey('paste-resize-handle'));
      final drag = await tester.startGesture(
        tester.getCenter(grip),
        kind: ui.PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(0, 20));
      await tester.pump();
      final trackingHeight = tester.getSize(input).height;
      await drag.moveBy(const Offset(0, 30));
      await tester.pump();
      expect(tester.getSize(input).height - trackingHeight, closeTo(30, 1));
      await drag.up();
      await tester.pumpAndSettle();
      final bar = tester.widget<RawScrollbar>(find.byType(RawScrollbar));
      expect(identical(bar.controller, field.scrollController), isTrue);
      expect(bar.interactive, isTrue);
      expect(
        find.descendant(
          of: find.byType(PasteEditor),
          matching: find.byWidgetPredicate((w) => w is RawScrollbar),
        ),
        findsOneWidget,
      );
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
