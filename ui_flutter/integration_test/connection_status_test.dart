import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/run_log.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/workbench/model.dart';

import '../test/support/local_sshd.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK formal footer shows original ACK RTT and actual PTY dimensions and survives a compact view',
    (tester) async {
      await initializeRust();
      final ssh = await LocalSshd.start();
      final model = LiveWorkbenchModel();
      final capture = GlobalKey();
      Future<void> until(
        bool Function() condition, [
        String stage = 'condition',
      ]) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('connection status GTK fixture timed out: $stage');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump();
      }

      Future<void> shot(String name) async {
        await tester.pumpAndSettle();
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/hspterm-connection-status-$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      }

      try {
        await rust.createConfigurationVault(
          path: '${ssh.directory.path}/status.vault',
          password: 'synthetic-status-master',
        );
        await model.load();
        model.confirmHostKey = (_, _) async => true;
        final host = await model.persistHost(
          DemoHost(
            model.nextId(),
            '状态栏夹具',
            '127.0.0.1',
            '未分组',
            user: ssh.username,
            port: ssh.port,
            auth: '私钥',
            openSftp: false,
            useNetworkDefaults: false,
            keepaliveSeconds: 1,
            keepaliveResponseSeconds: 1,
          ),
          secret: ssh.privateKey,
          passphrase: 'test-only-passphrase',
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: WorkbenchApp(model: model),
          ),
        );
        model.openHost(host);
        await tester.pump();
        final c = (model.focus! as LiveTerminalSession).controller;
        final trust = find.widgetWithText(FilledButton, '信任并保存');
        await until(
          () =>
              trust.evaluate().isNotEmpty || c.connected || c.phase == 'Failed',
          'host-key confirmation or connection',
        );
        if (trust.evaluate().isNotEmpty) {
          await tester.tap(trust);
          await tester.pump();
        }
        await until(
          () => c.connected || c.phase == 'Failed',
          'SSH connection after consent',
        );
        expect(c.connected, true, reason: c.error);
        await until(
          () => c.transportInfo.value.columns != null,
          'terminal frame dimensions, visible=${c.visible}, frames=${c.frameCount}',
        );
        await until(() {
          final log = AppRunLog.instance.export('');
          return log.contains('memoryTrigger=firstTerminalSettled');
        }, 'first terminal memory milestones');
        final memoryLog = AppRunLog.instance.export('');
        expect(memoryLog, contains('memoryTrigger=firstSshConnecting'));
        expect(memoryLog, contains('memoryTrigger=firstSshConnected'));
        expect(memoryLog, contains('memoryTrigger=firstTerminalPaint'));
        await until(
          () => c.transportInfo.value.rttMicros != null,
          'heartbeat RTT, phase=${c.phase}',
        );
        final finder = find.byKey(
          const ValueKey('workbench-connection-status'),
        );
        expect(tester.widget<Text>(finder).data, contains('RTT'));
        expect(
          tester.widget<Text>(finder).data,
          contains(
            'PTY ${c.transportInfo.value.columns} × ${c.transportInfo.value.rows}',
          ),
        );
        final id = c.id, generation = c.generation;
        await shot('wide');
        await tester.binding.setSurfaceSize(const Size(720, 540));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await shot('compact');
        expect(c.id, id);
        expect(c.generation, generation);
        expect(c.connected, true);
      } finally {
        await tester.binding.setSurfaceSize(null);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await model.shutdown();
        model.dispose();
        await ssh.close();
      }
    },
  );
}
