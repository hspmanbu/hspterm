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
  test('FFI wrapper is removed from existing action text', () {
    expect(appMessage('操作失败：AnyhowException(没有可靠目录)'), '操作失败：没有可靠目录');
  });
}
