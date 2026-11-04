import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/explorer_cache_cleanup.dart';

void main() {
  testWidgets(
    'orphan cleanup requires explicit confirmation and defaults to cancel',
    (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<bool>(
                  context: context,
                  builder: (_) => const ExplorerCacheCleanupConfirmation(
                    names: ['export-fixture'],
                  ),
                );
              },
              child: const Text('review'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('review'));
      await tester.pumpAndSettle();
      expect(find.text('清理 1 个孤立导出副本？'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
            .autofocus,
        isTrue,
      );
      expect(result, isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    },
  );

  testWidgets('bounded cleanup inventory scrolls in a small window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(560, 380);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExplorerCacheCleanupConfirmation(
            names: List.generate(128, (i) => 'export-fixture-$i'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('清理本机副本'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });
}
