import 'dart:convert';
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
    'GTK encrypted hotkey settings and real Kitty TUI preserve remote priority and local key-release ownership',
    (tester) async {
      await initializeRust();
      final server = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> until(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('palette hotkey GTK fixture timed out');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump();
      }

      Future<void> chord(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(key);
        await tester.pumpAndSettle();
        await tester.sendKeyUpEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/hspterm-palette-shortcut-$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      try {
        await rust.unlockVault(
          path: '${server.directory.path}/hotkey.vault',
          password: 'synthetic-palette-hotkey-master',
        );
        await model.load();
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            '合成快捷键 SSH',
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
          'palette hotkey SSH',
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
          r"PS1='fixture$ '; printf '\033[2J\033[H%s\n' 'HSPTerm hotkey - synthetic SSH'",
        );
        await c.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => screen(c).contains('HSPTerm hotkey - synthetic SSH'),
          'private screenshot banner',
        );
        final program = File('${server.directory.path}/palette_capture.py');
        await program.writeAsString(r'''
import os, select, sys, termios, time, tty
saved = termios.tcgetattr(0)
body = bytearray()
try:
    tty.setraw(0)
    sys.stdout.write('\x1b[>11u\x1b[2J\x1b[HKitty ownership fixture ' + sys.argv[2] + '\r\n')
    sys.stdout.flush()
    end = time.monotonic() + 5
    while time.monotonic() < end:
        ready, _, _ = select.select([0], [], [], max(0, end-time.monotonic()))
        if ready:
            chunk = os.read(0, 4096)
            if not chunk: break
            body.extend(chunk)
finally:
    sys.stdout.write('\x1b[<u')
    sys.stdout.flush()
    termios.tcsetattr(0, termios.TCSANOW, saved)
with open(sys.argv[1], 'wb') as report:
    report.write(body)
print('\r\nOWNERSHIP_CAPTURE_DONE', flush=True)
''');
        Future<File> startCapture(String name) async {
          final report = File('${server.directory.path}/$name.bytes');
          await c.text("python3 '${program.path}' '${report.path}' '$name'");
          await c.key(
            const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
          );
          await waitFor(
            () => screen(c).contains('Kitty ownership fixture $name'),
            'Kitty fixture ready',
          );
          await tester.pumpAndSettle();
          source.view.currentState!.focusTerminal();
          await tester.pump();
          return report;
        }

        final remote = await startCapture('remote');
        await chord(LogicalKeyboardKey.keyP);
        expect(find.byType(AppCommandPalette), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await waitFor(remote.existsSync, 'remote-owned input result');
        final remoteBytes = await remote.readAsBytes();
        expect(
          remoteBytes,
          isNotEmpty,
          reason: 'remote priority must deliver its original press/release',
        );
        expect(
          ascii.decode(remoteBytes).contains('\x1b[13;1:3u'),
          true,
          reason:
              'fixture must actually negotiate Kitty all-key release reports',
        );
        await waitFor(
          () => screen(c).contains('OWNERSHIP_CAPTURE_DONE'),
          'remote fixture completion',
        );
        model.show(WorkPage.settings);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-快捷键')));
        await until(
          () =>
              find
                  .byKey(const ValueKey('palette-binding-application'))
                  .evaluate()
                  .isNotEmpty &&
              tester
                      .widget<SwitchListTile>(
                        find.byKey(
                          const ValueKey('palette-binding-application'),
                        ),
                      )
                      .onChanged !=
                  null,
        );
        await tester.tap(
          find.byKey(const ValueKey('palette-binding-application')),
        );
        await tester.pump();
        await tester.tap(find.byType(DropdownButton<String>));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('palette-key-option-F8')),
          200,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('F8').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('palette-settings-save')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('palette-settings-save')));
        await tester.pumpAndSettle();
        expect(
          (await rust.commandPaletteShortcut()).applicationInTerminal,
          false,
        );
        await screenshot('confirmation');
        await tester.tap(find.byKey(const ValueKey('palette-confirm-save')));
        await until(
          () => find
              .byKey(const ValueKey('palette-settings-status'))
              .evaluate()
              .isNotEmpty,
        );
        expect((await rust.commandPaletteShortcut()).key, 'F8');
        expect(model.paletteBinding.applicationInTerminal, true);
        model.show(WorkPage.workspace);
        await tester.pumpAndSettle();
        final local = await startCapture('local');
        await chord(LogicalKeyboardKey.f8);
        expect(find.byType(AppCommandPalette), findsOneWidget);
        await tester.enterText(
          find.byKey(const ValueKey('app-command-query')),
          '终端搜索',
        );
        await tester.pumpAndSettle();
        await screenshot('active');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        source.view.currentState!.hideSearch();
        source.view.currentState!.focusTerminal();
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await waitFor(local.existsSync, 'local-owned input result');
        expect(
          ascii.decode(await local.readAsBytes()),
          '\x1b[57442;5u\x1b[57441;6u\x1b[57441;5:3u\x1b[57442;1:3u',
          reason:
              'Only the original modifier presses and their balanced releases '
              'may reach SSH; F8 and late Enter release stay local',
        );
        expect(c.id, id);
        expect(c.generation, generation);
        expect(c.connected, true);
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
