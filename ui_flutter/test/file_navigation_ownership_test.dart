import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

class _NavigationModel extends WorkbenchModel {
  final reads = <Completer<void>>[];
  int deleted = 0, created = 0;
  bool defer = false;

  @override
  Future<void> loadDirectory(
    TerminalSession source,
    String path, {
    bool remember = true,
  }) async {
    if (defer) {
      final completion = Completer<void>();
      reads.add(completion);
      await completion.future;
      // A superseded native reader returns normally without publishing.
      return;
    }
    await super.loadDirectory(source, path, remember: remember);
  }

  @override
  Future<void> deleteRemoteFiles(
    TerminalSession source,
    List<DemoFile> files,
  ) async {
    deleted++;
  }

  @override
  Future<void> createRemoteDirectory(
    TerminalSession source,
    String name,
  ) async {
    created++;
  }
}

Future<void> _mount(WidgetTester tester, _NavigationModel model) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 700,
          child: FilesPanel(model: model, pane: model.focus!),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('superseded back reads do not consume history', (tester) async {
    final model = _NavigationModel()..openHost(WorkbenchModel().hosts.first);
    final source = model.focus!..path = '/current';
    source.back.addAll(['/first', '/previous']);
    model.defer = true;
    await _mount(tester, model);
    await tester.tap(find.byTooltip('后退'));
    await tester.tap(find.byTooltip('后退'));
    expect(model.reads, hasLength(2));
    model.reads[1].complete();
    await tester.pump();
    model.reads[0].complete();
    await tester.pumpAndSettle();
    expect(source.back, ['/first', '/previous']);
    expect(source.forward, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back and forward preserve the departure directory', (
    tester,
  ) async {
    final model = _NavigationModel()..openHost(WorkbenchModel().hosts.first);
    final source = model.focus!..path = '/current';
    source.back.add('/previous');
    await _mount(tester, model);
    await tester.tap(find.byTooltip('后退'));
    await tester.pumpAndSettle();
    expect(source.path, '/previous');
    expect(source.back, isEmpty);
    expect(source.forward, ['/current']);
    await tester.tap(find.byTooltip('前进'));
    await tester.pumpAndSettle();
    expect(source.path, '/current');
    expect(source.back, ['/previous']);
    expect(source.forward, isEmpty);
  });

  testWidgets('delete confirmation cannot adopt a reconnected generation', (
    tester,
  ) async {
    final model = _NavigationModel()..openHost(WorkbenchModel().hosts.first);
    final source = model.focus!;
    final file = source.files.firstWhere((file) => !file.folder);
    await _mount(tester, model);
    await tester.tap(find.byKey(ValueKey('file-${file.name}')));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    source.connectionGeneration++;
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(model.deleted, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new folder rejects a directory change during route retirement', (
    tester,
  ) async {
    final model = _NavigationModel()..openHost(WorkbenchModel().hosts.first);
    final source = model.focus!;
    await _mount(tester, model);
    await tester.tap(find.byTooltip('新建文件夹'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '文件夹名称'), 'created');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pump();
    source.path = '/different';
    await tester.pumpAndSettle();
    expect(model.created, 0);
    expect(tester.takeException(), isNull);
  });
}
