import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';

import '../test/native_bridge_test.dart' show waitFor, screen;
import '../test/support/local_sshd.dart';

String quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK selects a literal terminal path and locates the hidden remote file in its own SFTP',
    (tester) async {
      await initializeRust();
      final server = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/path gtk.vault',
          password: 'synthetic path gtk master',
        );
        await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Path GTK fixture',
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            privateKey: true,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        await model.load();
        model.confirmHostKey = (_, _) async => true;
        model.openHost(model.hosts.single);
        model.openHost(model.hosts.single);
        final other = model.sessions[0] as LiveTerminalSession,
            source = model.sessions[1] as LiveTerminalSession;
        await waitFor(
          () => source.controller.connected && other.controller.connected,
          'GTK path transports',
        );
        final directory = await Directory('${server.directory.path}/OSC7 目录')
            .create();
        for (var i = 0; i < 260; i++) {
          await Directory(
            '${directory.path}/folder-${i.toString().padLeft(3, '0')}',
          ).create();
        }
        const filename = ".hidden '\$;.txt";
        final file = await File('${directory.path}/$filename')
            .writeAsString('preserved synthetic path body');
        await model.loadDirectory(source, server.directory.path);
        model.sidebar = false;
        final width = model.sidebarWidth, otherPath = other.path;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 350));
        final controller = source.controller,
            id = source.controller.id!,
            generation = source.controller.generation;
        final uri = Uri(
          scheme: 'file',
          host: '127.0.0.1',
          path: directory.path,
        ).toString();
        await controller.text(
          "unset PROMPT_COMMAND; PS1=''; printf '\\033[2J\\033[H\\033]7;%s\\007%s\\n%s%s\\n' ${quote(uri)} ${quote(filename)} GTK_ PATH",
        );
        await controller.key(
          rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () =>
              screen(controller).startsWith(filename) &&
              screen(controller).contains('GTK_PATH'),
          'GTK passive OSC7 output',
        );
        await tester.pumpAndSettle();
        final metric = TextPainter(
          text: TextSpan(
            text: 'M',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: model.fontSize,
              height: 1,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final cellWidth = metric.width;
        metric.dispose();
        final origin = tester.getTopLeft(find.byKey(source.view));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.down(origin + Offset(cellWidth * .5, 10));
        await mouse.moveTo(
          origin + Offset(cellWidth * (filename.length - .5), 10),
        );
        await mouse.up();
        await tester.pumpAndSettle();
        expect(controller.selectedText(), filename);
        await tester.tapAt(
          origin + const Offset(8, 10),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('在关联 SFTP 中定位'));
        await waitFor(
          () => source.path == directory.path && !source.loadingDirectory,
          'GTK explicit path location',
        );
        await tester.pumpAndSettle();
        final row = find.byKey(const ValueKey('file-$filename'));
        expect(row, findsOneWidget);
        expect(tester.widget<Container>(row).color, isNotNull);
        expect(source.pendingFileLocation, isNull);
        expect(model.sidebar, true);
        expect(model.sidebarWidth, width);
        expect(model.focus, same(source));
        expect(other.path, otherPath);
        expect(controller.id, id);
        expect(controller.generation, generation);
        expect(screen(controller).startsWith(filename), true);
        expect(await file.readAsString(), 'preserved synthetic path body');
        expect(await rust.listTransferTasks(), isEmpty);
        expect(tester.takeException(), isNull);
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/hspterm-terminal-path.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        // Real OSC8 file URI: passive hover does not load SFTP; explicit
        // Ctrl+Click locates the remote object, never opens a local file.
        final fileUri = Uri(
          scheme: 'file',
          host: '127.0.0.1',
          path: file.path,
        ).toString();
        await controller.text(
          "printf '\\033[2J\\033[H\\033]8;;%s\\033\\\\REMOTE_FILE_URI\\033]8;;\\033\\\\\\n' ${quote(fileUri)}",
        );
        await controller.key(
          const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () =>
              screen(controller).startsWith('REMOTE_FILE_URI') &&
              controller.hyperlinks
                  .expand((r) => r)
                  .any((s) => s.uri == fileUri),
          'real file URI metadata',
        );
        model.sidebar = false;
        model.changed();
        await tester.pumpAndSettle();
        final beforeLocation = source.pathLocationEpoch,
            beforeDirectory = source.directoryEpoch;
        final linkPoint =
            tester.getTopLeft(find.byKey(source.view)) + const Offset(5, 10);
        // GTK already knows this mouse from the selection above. Re-adding
        // the same device would violate MouseTracker's event lifecycle.
        final fileMouse = mouse;
        await fileMouse.moveTo(linkPoint + const Offset(1, 0));
        await tester.pump(const Duration(milliseconds: 700));
        expect(source.pathLocationEpoch, beforeLocation);
        expect(source.directoryEpoch, beforeDirectory);
        expect(model.sidebar, false);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tapAt(linkPoint);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await fileMouse.removePointer();
        await waitFor(
          () =>
              source.directoryEpoch > beforeDirectory &&
              !source.loadingDirectory,
          'explicit original file URI location',
        );
        await tester.pumpAndSettle();
        expect(source.pathLocationEpoch, beforeLocation + 1);
        expect(source.path, directory.path);
        expect(other.path, otherPath);
        expect(model.sidebar, true);
        expect(controller.id, id);
        expect(controller.generation, generation);
        expect(await rust.listTransferTasks(), isEmpty);
        expect(find.byKey(const ValueKey('file-$filename')), findsOneWidget);
        final fileImage = await boundary.toImage();
        final fileBytes = await fileImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        await File('/tmp/hspterm-terminal-file-uri.png')
            .writeAsBytes(fileBytes!.buffer.asUint8List());
        fileImage.dispose();
        expect(tester.takeException(), isNull);
        // Actual pointer selection + formal menu + Native OpenSSH/SFTP, not synthetic rows.
        debugPrint(
          'Verified GTK terminal selection to original-session SFTP, hidden row after 260 folders, no transfer/PTY injection or reconnection',
        );
        await tester.tap(find.byKey(const ValueKey('nav-hosts')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'SFTP'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OSC7 跟随'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        await waitFor(
          () => model.hosts.single.followOsc7,
          'GTK saved encrypted follow preference',
        );
        expect((await rust.listHosts()).single.followOsc7, true);
        final sourceTab = model.tabs.firstWhere(
          (t) => t.sessionId == source.id,
        );
        await tester.tap(find.byKey(ValueKey('tab-${sourceTab.id}')));
        await tester.pumpAndSettle();
        final followed = await Directory('${server.directory.path}/followed 中文')
            .create();
        final followUri = Uri(
          scheme: 'file',
          host: '127.0.0.1',
          path: followed.path,
        ).toString();
        await controller.text(
          "printf '\\033]7;%s\\007%s%s\\n' ${quote(followUri)} CWD_ FOLLOW",
        );
        await controller.key(
          rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
        );
        await waitFor(
          () => source.path == followed.path && !source.loadingDirectory,
          'GTK saved OSC7 option drives original SFTP',
        );
        await tester.pumpAndSettle();
        expect(model.sidebarWidth, width);
        expect(other.path, otherPath);
        expect(controller.id, id);
        expect(controller.generation, generation);
        expect(await rust.listTransferTasks(), isEmpty);
        expect(tester.takeException(), isNull);
        final followBoundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final followImage = await followBoundary.toImage();
        final followBytes = await followImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        await File('/tmp/hspterm-directory-follow.png')
            .writeAsBytes(followBytes!.buffer.asUint8List());
        followImage.dispose();
        debugPrint(
          'Verified GTK advanced-category single save to encrypted follow option and passive OSC7 navigation without changing SSH/SFTP identity',
        );
      } finally {
        await model.shutdown();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        model.dispose();
        await server.close();
      }
    },
  );
}
