import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';

import '../test/live_workbench_test.dart' as fixture;
import '../test/native_bridge_test.dart' show waitFor, screen;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real SSH file open launches the isolated OS association with fresh bytes',
    (tester) async {
      final receiptPath = Platform.environment['HSPTERM_PREVIEW_RECEIPT'];
      expect(
        receiptPath,
        isNotNull,
        reason: 'Run through benchmark/preview_association.py; never modify user MIME defaults',
      );
      final receipt = File(receiptPath!);
      final capture = GlobalKey();
      late LiveWorkbenchModel model;
      List<dynamic> viewed = [];
      await fixture.exerciseWorkbench(
        previewCacheSubdirectory: 'cache 中文 space # percent%',
        attach: (m) async {
          model = m;
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: WorkbenchApp(model: model),
            ),
          );
          await tester.pumpAndSettle();
        },
        pumpLayout: () => tester.pumpAndSettle(),
        afterReady: () async {
          final source = model.focus! as LiveTerminalSession;
          final generation = source.controller.generation;
          final width = model.sidebarWidth;
          Future<void> open(String name, int expectedCount) async {
            await tester.pumpAndSettle();
            await tester.tap(find.text(name));
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
            await waitFor(
              () =>
                  receipt.existsSync() &&
                  (jsonDecode(receipt.readAsStringSync()) as List).length ==
                      expectedCount,
              'controlled system viewer receipt',
            );
            viewed = jsonDecode(await receipt.readAsString()) as List;
            final remote = File('${source.path}/$name');
            final expected = await Process.run('sha256sum', [remote.path]);
            expect(expected.exitCode, 0);
            expect(
              viewed.last['sha256'],
              expected.stdout.toString().split(RegExp(r'\s+')).first,
            );
            expect(viewed.last['bytes'], await remote.length());
            expect(source.controller.generation, generation);
            expect(model.sidebarWidth, width);
            expect(model.sessions, hasLength(3));
            expect(tester.takeException(), isNull);
          }

          await open('中文.txt', 1);
          final firstPath = viewed.first['path'] as String;
          expect(firstPath, contains('cache 中文 space # percent%'));
          await File('${source.path}/中文.txt')
              .writeAsString('fresh second preview 中文\n');
          await open('中文.txt', 2);
          expect(viewed.last['path'], isNot(firstPath));
          expect(await File(firstPath).readAsString(), '中文 é');
          final parent = source.path;
          final target = Directory('$parent/linked-target');
          await target.create();
          await File('${target.path}/inside-link.txt')
              .writeAsString('controlled directory link');
          await Link('$parent/link-folder').create(target.path);
          await model.loadDirectory(source, parent, remember: false);
          await tester.pumpAndSettle();
          await tester.tap(find.text('link-folder'));
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(source.path, target.path);
          expect(find.text('inside-link.txt'), findsOneWidget);
          expect(
            (jsonDecode(await receipt.readAsString()) as List),
            hasLength(2),
          );
          await model.loadDirectory(source, parent, remember: false);
          final large = File('${source.path}/large-preview.bin');
          final handle = await large.open(mode: FileMode.write);
          await handle.truncate(100 * 1024 * 1024 + 1);
          await handle.close();
          await model.loadDirectory(source, source.path, remember: false);
          // Archive only synthetic terminal text, never the container's prompt.
          final terminals = model.sessions.cast<LiveTerminalSession>().toList();
          for (var i = 0; i < terminals.length; i++) {
            final terminal = terminals[i];
            if (!terminal.controller.visible) continue;
            await terminal.controller.text(
              r"printf '\033[2J\033[H%s%s\n' WORKBENCH_"
              " $i\n",
            );
            await waitFor(
              () => screen(terminal.controller).startsWith('WORKBENCH_$i'),
              'synthetic preview screenshot viewport',
            );
          }
          await tester.pumpAndSettle();
          await tester.tap(find.text('large-preview.bin'));
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('preview-confirm-large')),
            findsOneWidget,
          );
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${Directory.systemTemp.path}/hspterm-file-preview.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          await tester.tap(find.byKey(const ValueKey('preview-cancel')));
          await tester.pumpAndSettle();
          expect(
            (jsonDecode(await receipt.readAsString()) as List),
            hasLength(2),
          );
          expect(source.controller.generation, generation);
          debugPrint(
            'Verified native GTK file-URI default association, fresh Unicode bytes and large-file cancellation',
          );
        },
      );
      for (final item in viewed) {
        expect(await File(item['path'] as String).exists(), false);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 4)),
    skip: !Platform.isLinux,
  );
}
