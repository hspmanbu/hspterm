import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/previews.dart';
import 'package:hspterm/workbench/file_open_settings.dart';

void main() {
  testWidgets(
    'file open settings validate and only change after explicit successful save',
    (tester) async {
      FileOpenPreferences? saved;
      var fail = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FileOpenSettingsPanel(
                load: () async =>
                    const FileOpenPreferences(confirmationMib: 100),
                save: (value) async {
                  if (fail) throw StateError('controlled storage error');
                  saved = value;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('file-open-confirmation-mib'));
      final button = find.byKey(const ValueKey('save-file-open-settings'));
      expect(find.text('100'), findsOneWidget);
      await tester.enterText(field, '');
      await tester.pump();
      expect(field, findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('请输入 0–4294967295 之间的整数'), findsOneWidget);
      expect(saved, isNull);
      await tester.enterText(field, '4294967296');
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('请输入 0–4294967295 之间的整数'), findsOneWidget);
      await tester.enterText(field, '50');
      expect(saved, isNull);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(saved!.confirmationMib, 50);
      expect(find.text('文件打开设置已加密保存'), findsOneWidget);
      fail = true;
      await tester.enterText(field, '0');
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(saved!.confirmationMib, 50);
      expect(find.text('文件打开设置已加密保存'), findsNothing);
      expect(find.textContaining('原有文件打开设置继续生效'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unreadable file open settings cannot be overwritten with defaults',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileOpenSettingsPanel(
              load: () async {
                if (++attempts == 1) {
                  throw StateError('controlled future version');
                }
                return const FileOpenPreferences(confirmationMib: 0);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('save-file-open-settings')),
        findsNothing,
      );
      await tester.tap(find.text('重新读取文件打开设置'));
      await tester.pumpAndSettle();
      expect(find.text('0'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('save-file-open-settings')),
        findsOneWidget,
      );
      expect(attempts, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
