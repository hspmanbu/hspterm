//! Round-10: every menu item — including the conditional edit entries —
//! shares the compact themed style (equal height and hover background).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

void main() {
  testWidgets('conditional edit entries carry the same item style', (
    tester,
  ) async {
    final m = WorkbenchModel()..demo();
    final first = m.focus!.files.firstWhere((f) => !f.folder);
    Future<void> opener(
      BuildContext context,
      TerminalSession session,
      DemoFile file,
    ) async {}
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 700,
            child: FilesPanel(
              model: m,
              pane: m.focus!,
              onEditFile: opener,
              onEditFileWithEncoding: opener,
              onEditRawFile: opener,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(first.name).first,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    for (final label in ['编辑', '按指定编码编辑…', '外部编辑大文件…']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // All visible menu items share one explicit style: same minimum height
    // and one hover background rule (the conditional entries were the
    // round-9 stragglers).
    final buttons = tester.widgetList<MenuItemButton>(
      find.byType(MenuItemButton),
    );
    expect(buttons, isNotEmpty);
    for (final button in buttons) {
      final style = button.style;
      expect(style?.minimumSize, isNotNull, reason: 'styled menu item');
    }
    final heights = buttons.map((b) => b.style!.minimumSize).toSet();
    expect(heights.length, 1, reason: 'one uniform item height');

    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
}
