import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/staging_cleanup.dart';
import 'package:hspterm/workbench/staging_cleanup_port.dart';

class Fixture implements StagingCleanupPort {
  final calls = <String>[];
  bool unknown = false, fail = false;
  @override
  Future<Map<String, dynamic>> stagingTasks(int offset) async => {
    'items': [
      {
        'id': 'old-task',
        'host': 'original-target',
        'name': 'test',
        'busy': false,
      },
    ],
    'next': null,
  };
  @override
  Future<Map<String, dynamic>> stagingInventory(
    String id,
    int offset,
  ) async => {
    'items': [
      {'index': 7, 'path': "/target/a'\nfile", 'phase': 'Writing', 'bytes': 4},
    ],
    'next': null,
    'unconfirmed': unknown,
  };
  @override
  Future<Map<String, dynamic>> prepareStaging(
    String id,
    String host,
    int index,
  ) async {
    calls.add('inspect:$id:$host:$index');
    return {
      'ticket': 'one-use',
      'path': "/target/a'\nfile",
      'missing': false,
      'bytes': 4,
      'uncertain': false,
    };
  }

  @override
  Future<void> applyStaging(
    String id,
    String host,
    String ticket,
    bool uncertain,
  ) async {
    calls.add('delete:$id:$host:$ticket:$uncertain');
    if (fail) throw StateError('删除结果未确认');
  }

  @override
  Future<Map<String, dynamic>> prepareStagingEnd(String id) async => {
    'ticket': 'local-end',
    'path': '/target/private',
  };
  @override
  Future<void> endStagingWait(String id, String ticket) async {
    calls.add('end:$id:$ticket');
    unknown = false;
  }
}

Future<void> open(WidgetTester tester, Fixture port) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: StagingCleanupDialog(port: port)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('"test"'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'inventory is local until inspection, escaped path and explicit one-use consent',
    (tester) async {
      final port = Fixture();
      await open(tester, port);
      expect(port.calls, isEmpty);
      expect(find.text('"/target/a\'\\nfile"'), findsOneWidget);
      await tester.tap(find.text('检查'));
      await tester.pumpAndSettle();
      expect(port.calls, ['inspect:old-task:original-target:7']);
      final button = find.widgetWithText(FilledButton, '确认删除此暂存文件');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(port.calls.last, 'delete:old-task:original-target:one-use:true');
      expect(find.widgetWithText(FilledButton, '确认删除此暂存文件'), findsNothing);
    },
  );
  testWidgets(
    'failed delete discards button ticket and requires a fresh review',
    (tester) async {
      final port = Fixture()..fail = true;
      await open(tester, port);
      await tester.tap(find.text('检查'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      final button = find.widgetWithText(FilledButton, '确认删除此暂存文件');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('删除结果未确认'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '确认删除此暂存文件'), findsNothing);
      expect(port.calls.where((s) => s.startsWith('delete:')).length, 1);
    },
  );
  testWidgets(
    'unknown delete blocks remote replay; local ending requires its own confirmation',
    (tester) async {
      final port = Fixture()..unknown = true;
      await open(tester, port);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '检查'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('结束本机等待…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(port.calls, isEmpty);
      await tester.tap(find.text('结束本机等待…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认结束等待'));
      await tester.pumpAndSettle();
      expect(port.calls, ['end:old-task:local-end']);
    },
  );
}
