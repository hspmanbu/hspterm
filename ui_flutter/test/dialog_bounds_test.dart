import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/design.dart';

void main() {
  for (final physicalBounds in <List<double>?>[
    null,
    [400, 100, 1000, 700],
  ]) {
    testWidgets(
      'Windows geometry adapter opens a reachable dialog with bounds=$physicalBounds',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        var calls = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('hspterm/prototype_window'),
          (call) async {
            expect(call.method, 'ensureDialogVisible');
            calls++;
            return physicalBounds;
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  child: const Text('open'),
                  onPressed: () =>
                      confirm(context, 'Windows dialog', 'body ' * 300),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(find.text('Windows dialog'), findsOneWidget);
        final visible = physicalBounds == null
            ? const Rect.fromLTWH(0, 0, 800, 500)
            : const Rect.fromLTWH(200, 50, 500, 350);
        expect(visible.contains(tester.getCenter(find.text('确认'))), true);
        await tester.tap(find.text('确认'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets('confirm stays fully visible in a small window', (tester) async {
    tester.view.physicalSize = const Size(420, 320);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  confirmed = await confirm(
                    context,
                    '删除确认',
                    '很长的一段正文' * 120,
                    danger: true,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The dialog exists, its content scrolls, and BOTH action buttons stay
    // laid out inside the 420x320 window.
    expect(find.text('删除确认'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确认'), findsOneWidget);
    final dialog = tester.renderObject<RenderBox>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    expect(
      dialog.size.height,
      lessThan(320),
      reason: 'the scrollable body is height-bounded by the viewport',
    );
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('showBoundedDialog constrains oversized custom dialogs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showBoundedDialog<void>(
                  context,
                  (c) => const AlertDialog(
                    scrollable: true,
                    title: Text('t'),
                    content: SizedBox(width: 600, height: 800),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final content = tester.renderObject<RenderBox>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SizedBox),
      ),
    );
    expect(
      content.size.width,
      lessThan(360),
      reason: 'the oversized 600px body is squeezed inside the tiny window',
    );
    expect(
      tester.getSize(find.byType(SingleChildScrollView)).height,
      lessThan(300),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'offscreen client area keeps scaled actions inside the visible monitor',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      const visible = Rect.fromLTWH(260, 120, 530, 360);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: DialogViewport(
              visibleArea: visible,
              builder: (_) => AlertDialog(
                scrollable: true,
                title: const Text('Visible dialog'),
                content: Text('long text ' * 300),
                actions: [
                  TextButton(onPressed: () {}, child: const Text('Confirm')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(visible.contains(tester.getCenter(find.text('Confirm'))), true);
      expect(tester.takeException(), isNull);
    },
  );
}
