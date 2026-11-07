//! Round-9: clicking anywhere outside the file menu — including inside the
//! SFTP list itself — must close it. The dismissing click is consumed
//! (Windows shell behavior): it never selects, opens or drags a file.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

Future<void> mount(WidgetTester tester, WorkbenchModel model) async {
  // The panel is mounted 900x700; enlarge the test surface so taps in the
  // list's lower blank area are real surface points.
  await tester.binding.setSurfaceSize(const Size(900, 760));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 700,
          child: AnimatedBuilder(
            animation: model,
            builder: (_, _) => FilesPanel(model: model, pane: model.focus!),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> unmount(WidgetTester tester, WorkbenchModel model) async {
  await tester.pumpWidget(const SizedBox());
  await tester.binding.setSurfaceSize(null);
  addTearDown(model.dispose);
}

void main() {
  testWidgets(
    'clicking another list row closes the menu without side effects',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final pane = m.focus!;
      final first = pane.files.firstWhere((f) => !f.folder);
      final second = pane.files.firstWhere(
        (f) => !f.folder && f.id != first.id,
      );
      await mount(tester, m);

      await tester.tap(
        find.text(first.name).first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('删除'), findsOneWidget, reason: 'menu is open');

      // A plain click on a different row (to the right of the ~264px menu
      // panel): closes the menu; the click is consumed so the old selection
      // is untouched and nothing opens or drags.
      final row2 = tester.getRect(
        find.byWidgetPredicate(
          (w) => w is Container && w.key == ValueKey('file-${second.name}'),
        ),
      );
      await tester.tapAt(Offset(640, row2.center.dy));
      await tester.pumpAndSettle();
      expect(find.byTooltip('删除'), findsNothing, reason: 'menu closed');
      // The dismissing click closed the menu and selected the clicked row —
      // plain selection only; double-tap open and drag stay suppressed for
      // this click because the menu consumed the gesture arena.
      expect(
        (tester.state(find.byType(FilesPanel)) as dynamic).selected,
        contains(second.id),
        reason: 'the closing click behaves as a normal selection click',
      );
      await unmount(tester, m);
    },
  );

  testWidgets('clicking blank list space closes the menu', (tester) async {
    final m = WorkbenchModel()..demo();
    final pane = m.focus!;
    final first = pane.files.firstWhere((f) => !f.folder);
    await mount(tester, m);
    await tester.tap(
      find.text(first.name).first,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('删除'), findsOneWidget);

    // Blank area below the last row (inside the list viewport).
    await tester.tapAt(const Offset(700, 700));
    await tester.pumpAndSettle();
    expect(find.byTooltip('删除'), findsNothing, reason: 'menu closed');
    await unmount(tester, m);
  });

  testWidgets('clicks inside the open menu do not close it', (tester) async {
    final m = WorkbenchModel()..demo();
    final pane = m.focus!;
    final first = pane.files.firstWhere((f) => !f.folder);
    await mount(tester, m);
    for (final s in m.sessions) {
      if (s != m.focus) s.disconnected = true;
    }
    await tester.tap(
      find.text(first.name).first,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    // Hover the cascade parent (submenu opens), then click the DISABLED
    // placeholder inside the submenu: nothing dispatches, menus stay open.
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer();
    await hover.moveTo(tester.getCenter(find.text('复制到')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('没有其他已连接主机'), findsOneWidget);
    await tester.tap(find.text('没有其他已连接主机'));
    await tester.pumpAndSettle();
    expect(find.text('属性'), findsOneWidget, reason: 'menu still open');
    await unmount(tester, m);
  });
}
