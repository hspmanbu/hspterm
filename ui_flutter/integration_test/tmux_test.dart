import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';

import '../test/support/tmux_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK real isolated tmux choice, takeover consent, actual control mode and PTY lock',
    (tester) async {
      await initializeRust();
      final f = await TmuxFixture.start();
      final capture = GlobalKey();
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      Future<void> until(bool Function() condition) async {
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (!condition()) {
          if (DateTime.now().isAfter(end)) {
            throw StateError('isolated tmux GTK fixture timed out');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump();
      }

      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final image =
            await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('/tmp/hspterm-tmux-$name.png')
            .writeAsBytes(data.buffer.asUint8List());
        image.dispose();
      }

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: f.model),
          ),
        );
        f.model.openHost(f.host);
        await until(
          () =>
              find.byKey(const ValueKey('tmux-confirm')).evaluate().isNotEmpty,
        );
        await tester.tap(find.byKey(const ValueKey('tmux-readonly')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('tmux-confirm')))
              .onPressed,
          isNull,
        );
        await tester.ensureVisible(find.byKey(const ValueKey('tmux-takeover')));
        await tester.tap(find.byKey(const ValueKey('tmux-takeover')));
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('tmux-lock-size')),
        );
        await tester.tap(find.byKey(const ValueKey('tmux-lock-size')));
        await tester.pump();
        await screenshot('consent');
        await tester.tap(find.byKey(const ValueKey('tmux-confirm')));
        final c = (f.model.focus! as LiveTerminalSession).controller;
        await until(
          () =>
              c.connected &&
              c.tmuxReadonly == false &&
              c.metadata?.sizeLocked == true,
        );
        var mode = '';
        for (var i = 0; i < 50; i++) {
          mode = await f.command([
            'list-clients',
            '-t',
            'fixture',
            '-F',
            '#{client_readonly}',
          ]);
          if (mode == '0') break;
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          mode,
          '0',
          reason: 'the actual private tmux server confirms control, not merely exec ACK',
        );
        await screenshot('active');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await f.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );
}
