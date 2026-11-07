import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

Future<void> mount(WidgetTester tester, WorkbenchModel model) async {
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

void main() {
  testWidgets(
    'cascade submenu opens beside the parent menu, parent stays open',
    (tester) async {
      final m = WorkbenchModel()..demo();
      final other = m.sessions.firstWhere((s) => s != m.focus);
      other.disconnected = false;
      final initial = other.files.length;
      final file = m.focus!.files.first;
      await mount(tester, m);

      await tester.tap(
        find.text(file.name).first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();

      // Parent menu open with the cascade entries.
      expect(find.text('复制到'), findsOneWidget);
      expect(find.text('移动到'), findsOneWidget);
      expect(
        find.text('属性'),
        findsOneWidget,
        reason: 'entries below the cascade stay visible',
      );

      // The compact icon toolbar row sits at the top of the menu, left of the
      // first text entry, and its five actions are present.
      for (final tip in ['复制', '剪切', '粘贴', '重命名', '删除']) {
        expect(find.byTooltip(tip), findsOneWidget, reason: 'toolbar: $tip');
      }
      final toolbarCenter = tester.getCenter(find.byTooltip('复制'));
      final textCenter = tester.getCenter(find.text('属性'));
      expect(
        toolbarCenter.dy,
        lessThan(textCenter.dy),
        reason: 'icon row renders above the text entries',
      );

      // Hover opens the submenu.
      final submenuItem = find.text('复制到');
      final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await hover.addPointer();
      await hover.moveTo(tester.getCenter(submenuItem));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        find.text('${other.host.name} · ${other.path}'),
        findsOneWidget,
        reason: 'hover reveals the target host list',
      );
      // The parent menu did not close: its own entries remain.
      expect(find.text('属性'), findsOneWidget);

      // Geometry: the submenu renders to the RIGHT of the parent entry.
      final parentCenter = tester.getCenter(find.text('复制到'));
      final childCenter = tester.getCenter(
        find.text('${other.host.name} · ${other.path}'),
      );
      expect(
        childCenter.dx,
        greaterThan(parentCenter.dx),
        reason: 'submenu opens on the parent menu right side',
      );

      // Clicking the target performs the mock copy through the original path.
      await tester.tap(find.text('${other.host.name} · ${other.path}'));
      await tester.pumpAndSettle();
      expect(other.files.length, initial + 1);
      expect(tester.takeException(), isNull);

      // The icon toolbar dispatches through the same validated path: plain
      // copy only loads the clipboard, nothing is pasted anywhere.
      await tester.tap(
        find.text(file.name).first,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('复制'));
      await tester.pumpAndSettle();
      expect(
        other.files.length,
        initial + 1,
        reason: 'toolbar copy loads the clipboard only',
      );
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );

  testWidgets('no other connected hosts shows a disabled placeholder', (
    tester,
  ) async {
    final m = WorkbenchModel()..demo();
    for (final s in m.sessions) {
      if (s != m.focus) s.disconnected = true;
    }
    final file = m.focus!.files.first;
    await mount(tester, m);
    await tester.tap(
      find.text(file.name).first,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    final hover = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await hover.addPointer();
    await hover.moveTo(tester.getCenter(find.text('复制到')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('没有其他已连接主机'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
}
