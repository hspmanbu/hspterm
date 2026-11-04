import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';

import '../test/native_bridge_test.dart' show waitFor, screen;
import '../test/support/local_sshd.dart';

import 'package:hspterm/src/rust/api.dart' as rust;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK imported font, saved layout and PTY resize retain the original SSH identity',
    (tester) async {
      await initializeRust();
      final server = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> snapshot(String name) async {
        await tester.pumpAndSettle();
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/hspterm-typography-$name.png')
              .writeAsBytes(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      }

      try {
        await rust.unlockVault(
          path: '${server.directory.path}/typography.vault',
          password: 'synthetic-typography-master',
        );
        await model.load();
        await model.typography.load();
        expect(await model.typography.gateway.systemFamilies(), isNotEmpty);
        final bytes = (await rootBundle.load(
          'assets/fonts/JetBrainsMono-Regular.ttf',
        )).buffer.asUint8List();
        final imported = await model.typography.importFont(
          'Synthetic imported mono',
          bytes,
        );
        final family = imported.fonts.single.id;
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            '合成字体 SSH',
            '127.0.0.1',
            '未分组',
            user: server.username,
            port: server.port,
            auth: '私钥',
            openSftp: false,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        model.openHost(host);
        final session = model.focus! as LiveTerminalSession,
            terminal = session.controller;
        await waitFor(
          () => terminal.connected || terminal.phase == 'Failed',
          'font SSH',
        );
        expect(terminal.connected, true, reason: terminal.error);
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        final id = terminal.id, generation = terminal.generation;
        await terminal.text(
          "printf '\\033[2J\\033[HHSPTerm font fixture 0123 => !=\\n中文 é ┌─┐\\n'",
        );
        await terminal.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => screen(terminal).contains('HSPTerm font fixture'),
          'font banner',
        );
        final oldColumns = terminal.metadata!.columns;
        model.show(WorkPage.settings);
        await tester.pumpAndSettle();
        final fontChoice = find.byKey(
          const ValueKey('typography-family-builtin:JetBrainsMono'),
        );
        await tester.ensureVisible(fontChoice);
        await tester.tap(fontChoice);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('font-picker-search')),
          'Synthetic imported mono',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('font-option-imported:$family')));
        await tester.pumpAndSettle();
        tester
            .widget<DropdownButtonFormField<double>>(
              find.byKey(const ValueKey('typography-字号-15.0')),
            )
            .onChanged!(18);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('typography-save')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('typography-save')));
        await tester.pumpAndSettle();
        expect(model.typography.value.family, family);
        expect(model.fontSize, 18);
        expect(find.byKey(const ValueKey('typography-status')), findsOneWidget);
        await snapshot('settings');
        model.show(WorkPage.workspace);
        await tester.pumpAndSettle();
        await waitFor(
          () =>
              terminal.metadata != null &&
              terminal.metadata!.columns > 0 &&
              terminal.metadata!.columns != oldColumns,
          'font PTY resize',
        );
        expect(terminal.id, id);
        expect(terminal.generation, generation);
        expect(terminal.connected, true);
        expect(screen(terminal), contains('HSPTerm font fixture'));
        final native = await model.typography.gateway.load();
        expect(native.settings.family, family);
        expect(native.settings.size, 18);
        final hostSource = model.typography.snapshot!;
        await model.typography.saveHost(
          host.id,
          hostSource.settings.copyWith(size: 21, padding: 4),
          expected: hostSource,
        );
        await tester.pumpAndSettle();
        expect(model.typography.forHost(host.id).size, 21);
        expect(model.typography.value.size, 18);
        expect(terminal.id, id);
        expect(terminal.generation, generation);
        await snapshot('host-override');
        await model.typography.saveHost(host.id, null);
        await tester.pumpAndSettle();
        expect(model.typography.forHost(host.id).size, 18);
        expect(terminal.connected, true);
        await terminal.text("printf 'font-stty='; stty size");
        await terminal.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => screen(terminal).contains(
            'font-stty=${terminal.metadata!.rows} ${terminal.metadata!.columns}',
          ),
          'actual remote PTY geometry',
        );
        await terminal.text("printf 'font-resize-still-connected\\n'");
        await terminal.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => screen(terminal).contains('font-resize-still-connected'),
          'font live input',
        );
        await snapshot('terminal');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
