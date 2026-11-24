// Measures Flutter's exact UndoHistory storage primitive used by TextField.
// No text layout, SSH, account or user document; it isolates retention only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('synthetic framework undo retention diagnostic', (tester) async {
    final value = TextEditingController();
    final focus = FocusNode();
    final undo = UndoHistoryController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: UndoHistory<TextEditingValue>(
          value: value,
          focusNode: focus,
          controller: undo,
          onTriggered: (v) => value.value = v,
          child: const SizedBox(),
        ),
      ),
    );
    const bytes = 2 * 1024 * 1024;
    final prefix = List.filled(bytes, 'a').join();
    value.value = TextEditingValue(
      text: '$prefix\n',
      selection: const TextSelection.collapsed(offset: 0),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final before = ProcessInfo.currentRss;
    for (var i = 0; i < 48; i++) {
      value.value = TextEditingValue(
        text: '$prefix$i\n',
        selection: TextSelection.collapsed(offset: prefix.length),
      );
      await tester.pump(const Duration(milliseconds: 600));
    }
    final retained = ProcessInfo.currentRss;
    var steps = 0;
    while (undo.value.canUndo && steps < 100) {
      undo.undo();
      steps++;
    }
    expect(steps, greaterThanOrEqualTo(48));
    final report = {
      'mode': 'Flutter test VM, storage primitive only, not app or Windows RSS',
      'document_code_units': bytes,
      'changes': 48,
      'undo_steps': steps,
      'rss_before': before,
      'rss_retained': retained,
      'rss_delta': retained - before,
    };
    stdout.writeln(jsonEncode(report));
    const output = String.fromEnvironment('UNDO_REPORT');
    if (output.isNotEmpty) File(output).writeAsStringSync(jsonEncode(report));
    await tester.pumpWidget(const SizedBox());
    undo.dispose();
    focus.dispose();
    value.dispose();
  });
}
