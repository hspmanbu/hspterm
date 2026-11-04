import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/command_palette.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';

import '../test/native_bridge_test.dart' show waitFor, screen;
import '../test/support/local_sshd.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK actual palette navigates application actions and keeps original live SSH identity',
    (tester) async {
      await initializeRust();
      final server = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> open() async {
        await tester.tap(find.byKey(const ValueKey('app-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('应用命令面板'));
        await tester.pumpAndSettle();
      }

      Future<void> screenshot(String name) async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/hspterm-command-palette-$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      try {
        await rust.unlockVault(
          path: '${server.directory.path}/palette.vault',
          password: 'synthetic-palette-master',
        );
        await model.load();
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            '合成命令面板 SSH',
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
        final source = model.focus! as LiveTerminalSession,
            c = source.controller;
        await waitFor(
          () => c.connected || c.phase == 'Failed',
          'command palette real SSH',
        );
        expect(c.connected, true, reason: c.error);
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        final id = c.id, generation = c.generation;
        await c.text(
          r"PS1='fixture$ '; printf '\033[2J\033[H%s\n' 'HSPTerm command palette - synthetic SSH'",
        );
        await c.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => screen(c).contains('HSPTerm command palette - synthetic SSH'),
          'synthetic SSH screenshot banner',
        );
        await tester.pumpAndSettle();
        await open();
        expect(
          find.byKey(const ValueKey('app-command-terminal-search')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('app-command-terminal-copy')),
          findsNothing,
        );
        await tester.enterText(
          find.byKey(const ValueKey('app-command-query')),
          '终端搜索',
        );
        await tester.pumpAndSettle();
        await screenshot('search');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byType(AppCommandPalette), findsNothing);
        // Return from the existing terminal search before reopening the palette.
        source.view.currentState!.hideSearch();
        await tester.pumpAndSettle();
        await open();
        expect(
          tester
              .widget<ListTile>(
                find.byKey(const ValueKey('app-command-terminal-search')),
              )
              .selected,
          true,
        );
        await screenshot('recent');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(c.id, id);
        expect(c.generation, generation);
        expect(model.sessions.single, same(source));
        // Commands were captured for the original visible view. A focus change
        // while the modal is open must hide them rather than target a new SSH.
        final originalTab = model.tabs.single.id;
        model.openHost(host);
        final other = model.focus! as LiveTerminalSession;
        final otherTab = model.tabs.last.id;
        await waitFor(
          () =>
              other.controller.connected || other.controller.phase == 'Failed',
          'second palette SSH',
        );
        expect(
          other.controller.connected,
          true,
          reason: other.controller.error,
        );
        model.selectTab(originalTab);
        await tester.pumpAndSettle();
        await open();
        await tester.enterText(
          find.byKey(const ValueKey('app-command-query')),
          '终端搜索',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('app-command-terminal-search')),
          findsOneWidget,
        );
        model.selectTab(otherTab);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('app-command-terminal-search')),
          findsNothing,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(find.byType(AppCommandPalette), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        model.selectTab(originalTab);
        await tester.pumpAndSettle();
        expect(c.id, id);
        expect(c.generation, generation);
        expect(c.connected, true);
        await c.text(r"printf '%s%s\n' PALETTE_ ALIVE");
        await c.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => screen(c).contains('PALETTE_ALIVE'),
          'same SSH after palette',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        await server.close();
      }
    },
  );
}
