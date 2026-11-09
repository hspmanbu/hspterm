import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/app_notice.dart';

void main() {
  testWidgets(
    'action notices close automatically after six seconds and expose close control',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAppNotice(
                  context,
                  'synthetic notice',
                  level: AppNoticeLevel.warning,
                  action: SnackBarAction(label: '说明', onPressed: () {}),
                ),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snack.persist, false);
      expect(snack.showCloseIcon, true);
      expect(snack.duration, const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('synthetic notice'), findsNothing);
      resetAppNoticeDedupe();
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('synthetic notice'), findsNothing);
    },
  );

  testWidgets(
    'info and success notices stay quiet (no SnackBar) and dedupe repeats',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextButton(
                    onPressed: () => showAppNotice(context, 'quiet info'),
                    child: const Text('info'),
                  ),
                  TextButton(
                    onPressed: () => showAppNotice(
                      context,
                      'quiet success',
                      level: AppNoticeLevel.success,
                    ),
                    child: const Text('success'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('info'));
      await tester.tap(find.text('success'));
      await tester.pumpAndSettle();
      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'ordinary operations never raise a SnackBar',
      );
      expect(quietNoticeNotifier.value?.message, 'quiet success');
      expect(quietNoticeNotifier.value?.level, AppNoticeLevel.success);
    },
  );

  test('FFI wrapper is removed from existing action text', () {
    expect(appMessage('操作失败：AnyhowException(没有可靠目录)'), '操作失败：没有可靠目录');
  });
}
