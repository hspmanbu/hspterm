import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/hosts.dart';
import 'package:hspterm/prototype/model.dart';

/// Synthetic presentation fixture only; no Native store, SSH or credentials.
class _FormalPresentation extends WorkbenchModel {
  @override
  bool get isMock => false;
}

void main() {
  testWidgets(
    'formal host form does not mark unsupported TERM, initial path or compression as saved edits',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final m = _FormalPresentation(), key = GlobalKey<HostManagerState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HostManager(key: key, model: m),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('终端').first);
      await tester.pumpAndSettle();
      final term = tester.widget<TextFormField>(
        find.byKey(const ValueKey('host-term-static')),
      );
      expect(term.onChanged, isNull);
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const ValueKey('host-term-static')),
                matching: find.byType(TextField),
              ),
            )
            .readOnly,
        true,
      );
      expect(key.currentState!.dirty, false);
      await tester.tap(find.text('SFTP').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('host-sftp-default')), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '初始远端目录'), findsNothing);
      expect(key.currentState!.dirty, false);
      await tester.tap(find.text('进阶').first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('host-compression-static')),
        findsOneWidget,
      );
      expect(find.widgetWithText(SwitchListTile, '压缩'), findsNothing);
      expect(find.textContaining('Agent转发尚未启用'), findsNothing);
      expect(key.currentState!.dirty, false);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets('explicit mock keeps clearly separate prototype-only controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final m = WorkbenchModel();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HostManager(model: m)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('SFTP').first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '初始远端目录'), findsOneWidget);
    expect(find.byKey(const ValueKey('host-sftp-default')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    m.dispose();
  });
}
