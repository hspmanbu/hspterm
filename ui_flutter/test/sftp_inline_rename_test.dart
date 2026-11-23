import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  testWidgets('editing row keeps a slow drag-selection inside the field', (
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
    final field = find.byKey(const ValueKey('inline-rename-field'));
    expect(field, findsOneWidget);
    // While editing, the row carries none of the three drag wrappers: no
    // Draggable sits above the editor, so no onDragStarted can ever fire
    // for this row's pointer.
    var draggableAncestor = false;
    tester.element(field).visitAncestorElements((element) {
      if (element.widget is Draggable) {
        draggableAncestor = true;
        return false;
      }
      return true;
    });
    expect(draggableAncestor, isFalse);
    // Other rows keep their drag wrapper; only the editing row lost it.
    expect(find.byType(Draggable<RemoteDrag>), findsWidgets);
    // Record every pointer cancel so a stray cancelPointer into the editor
    // (native drag handoff) fails the test.
    final cancels = <PointerCancelEvent>[];
    void route(PointerEvent event) {
      if (event is PointerCancelEvent) cancels.add(event);
    }

    GestureBinding.instance.pointerRouter.addGlobalRoute(route);
    final controller = tester.widget<TextField>(field).controller!;
    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
    );
    final RenderEditable render = tester
        .state<EditableTextState>(editable)
        .renderEditable;
    // Start inside the actual text, not in the wide field's empty right half.
    // Keep the original 1px moves so the drag recognizer regression remains.
    final start = render.localToGlobal(
      render.getLocalRectForCaret(const TextPosition(offset: 4)).center,
    );
    // Slow mouse drag: several 1 px moves. The row drag accepts at 1.0 px
    // while the field's pan selection needs 2.0 px, so a wrapper above the
    // editor would swallow the gesture and freeze the selection.
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final afterDown = controller.selection.extentOffset;
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(-1, 0));
      await tester.pump();
    }
    final afterDrag = controller.selection.extentOffset;
    await gesture.up();
    await tester.pumpAndSettle();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(route);
    // The text field won the arena: the selection extent followed the
    // pointer leftward, editing survived and no cancel reached the editor.
    expect(field, findsOneWidget);
    expect(afterDrag, lessThan(afterDown));
    expect(cancels, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
}
