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
    bool refresh = false,
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
  Future<RemoteDeleteResult> deleteRemoteFiles(
    TerminalSession source,
    List<DemoFile> files,
  ) async {
    deleted++;
    return RemoteDeleteResult(
      succeeded: files.map((f) => f.id).toList(),
      failed: const [],
    );
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
  // The back/forward buttons were removed with the breadcrumb revision; the
  // navigation ownership invariants stay covered through breadcrumb-driven
  // navigate() calls.
  testWidgets('superseded directory reads do not consume history', (
    tester,
  ) async {
    final model = _NavigationModel()..openHost(WorkbenchModel().hosts.first);
    final source = model.focus!..path = '/current';
    source.back.addAll(['/first', '/previous']);
    model.defer = true;
    await _mount(tester, model);
    final state = tester.state(find.byType(FilesPanel));
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    (state as dynamic).navigate('/late');
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    (state as dynamic).navigate('/early');
    expect(model.reads, hasLength(2));
    model.reads[1].complete();
    await tester.pump();
    model.reads[0].complete();
    await tester.pumpAndSettle();
    expect(source.back, ['/first', '/previous']);
    expect(source.forward, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('navigation keeps the departure directory in history', (
    tester,
  ) async {
    final model = _NavigationModel()..openHost(WorkbenchModel().hosts.first);
    final source = model.focus!..path = '/current';
    await _mount(tester, model);
    await tester.tap(find.byKey(const ValueKey('sftp-path-bar')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('remote-path')),
      '/previous',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(source.path, '/previous');
    expect(source.back, ['/current']);
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
