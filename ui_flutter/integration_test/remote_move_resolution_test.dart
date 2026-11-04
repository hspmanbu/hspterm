import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/queue.dart';

import '../test/native_bridge_test.dart' show waitFor;
import '../test/remote_transfer_bridge_test.dart' show remoteTask;
import '../test/support/local_sshd.dart';
import '../test/support/lost_rename_reply_sftp.dart';

/// This small GTK harness hosts the formal queue/dialog with real Native tasks
/// and SSH controllers. It does not synthesize transfer states or move replies.
class _ConnectedQueue extends LiveWorkbenchModel {
  final connected = <LiveTerminalSession>[];
  @override
  List<TerminalSession> get sessions => connected;
  @override
  LiveTerminalSession? get focus => connected.firstOrNull;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'GTK checks a lost rename reply and explicitly ends waiting without touching either file',
    (tester) async {
      await initializeRust();
      final server = await LocalSshd.start(sftpFixture: lostRenameReplySftp);
      final model = _ConnectedQueue()..allTasks = true;
      final capture = GlobalKey();
      try {
        await rust.unlockVault(
          path: '${server.directory.path}/resolution GTK.vault',
          password: 'synthetic GTK resolution master',
        );
        await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: 'Lost reply GTK fixture',
            address: '127.0.0.1',
            port: server.port,
            username: server.username,
            privateKey: true,
          ),
          secret: server.privateKey,
          passphrase: 'test-only-passphrase',
        );
        final profile = (await rust.listHosts()).single;
        final host = DemoHost(
          profile.id,
          'Lost reply GTK fixture',
          '127.0.0.1',
          'fixture',
          user: server.username,
          port: server.port,
        );
        for (var i = 0; i < 2; i++) {
          final session = LiveTerminalSession(
            'gtk-$i',
            host,
            const NativeTerminalBackend(),
          );
          model.connected.add(session);
          session.controller.confirmHostKey = (_) async => true;
          await session.controller.start();
          await session.controller.connect(profile.id);
          await waitFor(
            () => session.controller.connected,
            'GTK resolution SSH',
          );
        }
        final a = model.connected[0].controller,
            b = model.connected[1].controller;
        final source = File('${server.directory.path}/source 中文.bin');
        final target = File('${server.directory.path}/target 中文.bin');
        final original = List.filled(65536, 71),
            recreated = List.filled(65536, 82);
        await source.writeAsBytes(original);
        final id = await rust.enqueueRemoteMove(
          sourceId: a.id!,
          targetId: b.id!,
          source: source.path,
          destination: target.path,
          expectedSourceGeneration: a.generation,
          expectedTargetGeneration: b.generation,
        );
        await remoteTask(id, (t) => !t.busy && t.remoteMovePhase == 'Intent');
        await model.refreshTransfers();
        expect(await source.exists(), false);
        expect(await target.readAsBytes(), original);
        await source.writeAsBytes(recreated);
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: Desk.theme(false),
              home: Scaffold(
                body: AnimatedBuilder(
                  animation: model,
                  builder: (_, _) => Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 420,
                      child: LiveTransferQueue(model: model),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> inspect() async {
          await tester.tap(find.byTooltip('检查未确认移动'));
          for (var i = 0; i < 300; i++) {
            await tester.pump();
            if (find.text('普通文件 · 65536 字节（元数据）').evaluate().length == 2) break;
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          expect(find.text('普通文件 · 65536 字节（元数据）'), findsNWidgets(2));
          await tester.pumpAndSettle();
        }

        await inspect();
        await tester.tap(find.text('关闭').last);
        await tester.pumpAndSettle();
        expect(
          model.transferTasks.singleWhere((t) => t.id == id).remoteMovePhase,
          'Intent',
        );
        expect(
          () => rust.reserveEditor(
            id: a.id!,
            generation: a.generation,
            path: source.path,
          ),
          throwsA(anything),
        );
        await inspect();
        final image =
            await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/hspterm-move-resolution.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        await tester.tap(find.text('结束本机等待'));
        for (var i = 0; i < 300; i++) {
          await tester.pump();
          if (model.transferTasks
                  .singleWhere((t) => t.id == id)
                  .remoteMovePhase ==
              'UserEnded') {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        await tester.pumpAndSettle();
        expect(
          model.transferTasks.singleWhere((t) => t.id == id).state,
          'Cancelled',
        );
        await tester.tap(find.textContaining('已结束'));
        await tester.pumpAndSettle();
        expect(find.text('已人工结束 · 结果未判定'), findsOneWidget);
        expect(find.text('已完成'), findsNothing);
        expect(await source.readAsBytes(), recreated);
        expect(await target.readAsBytes(), original);
        expect(
          await File('${server.directory.path}/sftp_fixture.py.rename-count')
              .readAsLines(),
          ['1'],
        );
        expect(a.reconnectCount, 0);
        expect(b.reconnectCount, 0);
        expect(tester.takeException(), isNull);
        debugPrint(
          'Verified GTK real lost OpenSSH rename reply, cancelled inspection, explicit local ending and both original/recreated files preserved',
        );
        final offlineSource = File(
          '${server.directory.path}/offline source 中文.bin',
        );
        final offlineTarget = File(
          '${server.directory.path}/offline target 中文.bin',
        );
        await offlineSource.writeAsBytes(original);
        final offlineId = await rust.enqueueRemoteMove(
          sourceId: a.id!,
          targetId: b.id!,
          source: offlineSource.path,
          destination: offlineTarget.path,
          expectedSourceGeneration: a.generation,
          expectedTargetGeneration: b.generation,
        );
        await remoteTask(
          offlineId,
          (t) => !t.busy && t.remoteMovePhase == 'Intent',
        );
        await offlineSource.writeAsBytes(recreated);
        await rust.deleteHosts(ids: [profile.id]);
        expect(await rust.listHosts(), isEmpty);
        await a.shutdown();
        await b.shutdown();
        server.process.kill();
        await server.process.exitCode;
        await model.refreshTransfers();
        await tester.pumpAndSettle();
        Future<void> offlineReview() async {
          await tester.tap(find.byTooltip('检查未确认移动'));
          for (var i = 0; i < 300; i++) {
            await tester.pump();
            if (find.textContaining('仍可仅结束本机等待').evaluate().isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          await tester.pumpAndSettle();
          expect(find.textContaining('仍可仅结束本机等待'), findsOneWidget);
          expect(find.text('尚未核对当前远端属性'), findsNWidgets(2));
        }

        await offlineReview();
        await tester.tap(find.text('关闭').last);
        await tester.pumpAndSettle();
        expect(
          model.transferTasks
              .singleWhere((t) => t.id == offlineId)
              .remoteMovePhase,
          'Intent',
        );
        await offlineReview();
        final offlineImage =
            await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final offlinePng = await offlineImage.toByteData(
          format: ui.ImageByteFormat.png,
        );
        await File('/tmp/hspterm-move-offline-end.png')
            .writeAsBytes(offlinePng!.buffer.asUint8List());
        offlineImage.dispose();
        await tester.tap(find.text('结束本机等待'));
        for (var i = 0; i < 300; i++) {
          await tester.pump();
          if (model.transferTasks
                  .singleWhere((t) => t.id == offlineId)
                  .remoteMovePhase ==
              'UserEnded') {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        await tester.pumpAndSettle();
        expect(
          model.transferTasks.singleWhere((t) => t.id == offlineId).state,
          'Cancelled',
        );
        expect(await offlineSource.readAsBytes(), recreated);
        expect(await offlineTarget.readAsBytes(), original);
        expect(
          await File('${server.directory.path}/sftp_fixture.py.rename-count')
              .readAsLines(),
          ['1', '1'],
        );
        expect(await rust.listHosts(), isEmpty);
        expect(tester.takeException(), isNull);
        debugPrint(
          'Verified GTK local review, cancel and explicit ending after host deletion, SSH shutdown and server shutdown; no metadata success invented',
        );
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
