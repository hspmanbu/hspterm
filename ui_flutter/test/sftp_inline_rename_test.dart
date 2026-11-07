import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

Future<void> mount(WidgetTester tester, WorkbenchModel model) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AnimatedBuilder(
          animation: model,
          builder: (_, _) => FilesPanel(model: model, pane: model.focus!),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'clicking outside the inline rename editor cancels; only Enter applies',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final source = m.focus!;
      final target = source.files.first;
      final original = target.name;
      await mount(tester, m);
      await tester.tap(find.text(original));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      final editor = find.byKey(const ValueKey('inline-rename'));
      expect(editor, findsOneWidget);
      // Editing another row leaves the editor and keeps the original name.
      final other = source.files.firstWhere((f) => f.name != original);
      await tester.enterText(editor, 'renamed.txt');
      await tester.tap(find.text(other.name));
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      expect(target.name, original);
      // Enter is the only path that applies the new name.
      await tester.tap(find.text(original));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      await tester.enterText(editor, 'renamed.txt');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      expect(target.name, 'renamed.txt');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets('escape cancels the inline rename editor as well', (
    tester,
  ) async {
    final m = WorkbenchModel()..demo();
    final source = m.focus!;
    final target = source.files.first;
    final original = target.name;
    await mount(tester, m);
    await tester.tap(find.text(original));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    final editor = find.byKey(const ValueKey('inline-rename'));
    await tester.enterText(editor, 'discarded.txt');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(editor, findsNothing);
    expect(target.name, original);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
}
