import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

class _ActivitySession extends TerminalSession {
  _ActivitySession(super.id, super.host);
  String? activity;
  @override
  String? get sftpActivity => activity;
}

void main() {
  for (final initialized in [false, true]) {
    testWidgets(
      'pending SFTP request is visible before a listing; initialized=$initialized',
      (tester) async {
        final model = WorkbenchModel()..demo();
        final pane = _ActivitySession('activity', model.focus!.host)
          ..sftpEnabled = initialized
          ..activity = '正在准备传输…';
        pane.files
          ..clear()
          ..add(DemoFile('unchanged', 'keep-visible.txt'));
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: AnimatedBuilder(
                  animation: model,
                  builder: (_, _) => FilesPanel(model: model, pane: pane),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.byKey(const ValueKey('sftp-activity')), findsOneWidget);
          expect(find.text('正在准备传输…'), findsOneWidget);
          expect(
            pane.loadingDirectory,
            false,
            reason: 'preparation feedback does not pretend a new listing has loaded',
          );
          pane.activity = null;
          model.changed();
          await tester.pump();
          expect(find.byKey(const ValueKey('sftp-activity')), findsNothing);
          expect(pane.files.single.name, 'keep-visible.txt');
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          model.dispose();
        }
      },
    );
  }
}
