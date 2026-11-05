import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/prototype/files.dart';

class RelativePathsTestModel extends WorkbenchModel {
  @override
  bool get isMock => false;
  bool unavailable = false, directoryChanged = false, closing = false;
  int calls = 0;
  Completer<RemoteRelativePaths>? pending;
  @override
  bool get isClosing => closing;
  @override
  Future<RemoteRelativePaths> relativeRemotePaths(
    TerminalSession source,
    List<String> paths, {
    int? expectedRevision,
  }) async {
    calls++;
    if (pending != null && expectedRevision == null) return pending!.future;
    if (unavailable || (expectedRevision != null && directoryChanged)) {
      throw StateError('工作目录不可确定或已改变');
    }
    return RemoteRelativePaths(11, [
      for (final path in paths) './${path.split('/').last}',
    ]);
  }
}

Future<TerminalSession> mount(
  WidgetTester tester,
  RelativePathsTestModel model,
) async {
  model.openHost(model.hosts.first);
  final source = model.focus!;
  await tester.pumpWidget(
    MaterialApp(
      theme: Desk.theme(false),
      home: Scaffold(
        body: FilesPanel(model: model, pane: source),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return source;
}

Future<void> menu(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('file-README.md'));
  await tester.ensureVisible(row);
  await tester.tap(row, buttons: kSecondaryMouseButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'explicit absolute copy writes only text and never probes cwd while opening a menu',
    (tester) async {
      final model = RelativePathsTestModel();
      final writes = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              writes.add((call.arguments as Map)['text'] as String);
            }
            return null;
          });
      try {
        final source = await mount(tester, model);
        final taskCount = model.transfers.length;
        await menu(tester);
        await tester.tap(find.text('复制路径'));
        await tester.pumpAndSettle();
        expect(model.calls, 0);
        expect(writes, ['${source.path}/README.md']);
        expect(source.entered, isEmpty);
        expect(model.transfers.length, taskCount);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      }
    },
  );
  testWidgets(
    'unknown cwd does not block absolute path actions or trigger capability errors',
    (tester) async {
      final model = RelativePathsTestModel()..unavailable = true;
      var writes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') writes++;
            return null;
          });
      try {
        await mount(tester, model);
        await menu(tester);
        expect(find.text('复制相对路径'), findsNothing);
        expect(find.text('复制路径'), findsOneWidget);
        expect(find.text('发送文件/文件夹名至终端'), findsOneWidget);
        expect(model.calls, 0);
        expect(writes, 0);
        await tester.tapAt(const Offset(1, 1));
        await tester.pumpAndSettle();
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      }
    },
  );
  testWidgets('closing prevents a new popup without starting capability work', (
    tester,
  ) async {
    final model = RelativePathsTestModel()
      ..pending = Completer<RemoteRelativePaths>();
    try {
      await mount(tester, model);
      model.closing = true;
      final row = find.byKey(const ValueKey('file-README.md'));
      await tester.ensureVisible(row);
      await tester.tap(row, buttons: kSecondaryMouseButton);
      await tester.pump();
      model.closing = true;
      model.pending!.complete(RemoteRelativePaths(11, ['./README.md']));
      await tester.pumpAndSettle();
      expect(find.text('复制路径'), findsNothing);
      expect(model.calls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    }
  });
}
