import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/transfers.dart';
import 'package:hspterm/workbench/transfer_settings.dart';

void main() {
  testWidgets(
    'manual reconnect recovery is opt in and saved only after explicit submit',
    (tester) async {
      TransferPreferences? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TransferSettingsPanel(
                load: () async => const TransferPreferences(
                  concurrency: 3,
                  uploadBytesPerSecond: 0,
                  downloadBytesPerSecond: 0,
                ),
                save: (v) async {
                  saved = v;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        false,
      );
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(saved, isNull);
      final button = find.byKey(const ValueKey('save-transfer-settings'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(saved!.resumeOnReconnect, true);
    },
  );

  testWidgets(
    'real transfer settings validate, explicitly save and report failure',
    (tester) async {
      TransferPreferences? saved;
      bool fail = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TransferSettingsPanel(
                load: () async => const TransferPreferences(
                  concurrency: 3,
                  uploadBytesPerSecond: 12345,
                  downloadBytesPerSecond: 0,
                  defaultConflict: 'rename',
                ),
                save: (value) async {
                  if (fail) {
                    throw StateError('controlled storage error');
                  }
                  saved = value;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder field(String s) => find.byKey(ValueKey('transfer-setting-$s'));
      expect(find.text('12345'), findsOneWidget);
      expect(find.text('更名另存，保留旧目标'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('transfer-default-conflict')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('跳过同名文件').last);
      await tester.pumpAndSettle();
      await tester.enterText(field('并发顶层任务'), '0');
      await tester.ensureVisible(
        find.byKey(const ValueKey('save-transfer-settings')),
      );
      await tester.tap(find.byKey(const ValueKey('save-transfer-settings')));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('请输入 1–32 之间的整数'), findsOneWidget);
      await tester.enterText(field('并发顶层任务'), '2');
      await tester.enterText(field('总体上传限制（字节/秒）'), '65536');
      expect(saved, isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('save-transfer-settings')),
      );
      await tester.tap(find.byKey(const ValueKey('save-transfer-settings')));
      await tester.pumpAndSettle();
      expect(saved!.concurrency, 2);
      expect(saved!.uploadBytesPerSecond, 65536);
      expect(saved!.defaultConflict, 'skip');
      expect(saved!.resumeOnReconnect, false);
      expect(find.text('已加密保存并生效'), findsOneWidget);
      await tester.enterText(field('并发顶层任务'), '');
      await tester.pump();
      expect(field('并发顶层任务'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('save-transfer-settings')),
      );
      await tester.tap(find.byKey(const ValueKey('save-transfer-settings')));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1–32 之间的整数'), findsOneWidget);
      expect(saved!.concurrency, 2);
      await tester.enterText(field('并发顶层任务'), '2');
      fail = true;
      await tester.enterText(field('总体上传限制（字节/秒）'), '0');
      await tester.ensureVisible(
        find.byKey(const ValueKey('save-transfer-settings')),
      );
      await tester.tap(find.byKey(const ValueKey('save-transfer-settings')));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败，原有配置继续生效'), findsOneWidget);
      expect(find.text('已加密保存并生效'), findsNothing);
      expect(saved!.uploadBytesPerSecond, 65536);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed load is retryable and cannot save defaults over unread data',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransferSettingsPanel(
              load: () async {
                if (++attempts == 1) {
                  throw StateError('controlled read failure');
                }
                return const TransferPreferences(
                  concurrency: 3,
                  uploadBytesPerSecond: 0,
                  downloadBytesPerSecond: 0,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('save-transfer-settings')),
        findsNothing,
      );
      await tester.tap(find.text('重新读取传输配置'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('save-transfer-settings')),
        findsOneWidget,
      );
      expect(attempts, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
