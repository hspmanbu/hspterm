import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/workbench/app.dart';
import 'package:hspterm/prototype/model.dart' show WorkPage;
import 'package:hspterm/prototype/files.dart' show FilesPanel;
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/queue.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/transfers.dart' show TransferPreferences;

import '../test/live_workbench_test.dart' as fixture;
import '../test/native_bridge_test.dart' show waitFor, screen;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real workbench GTK renders independent SSH sessions and associated SFTP',
    (tester) async {
      // GTK runner is real; text entry is a deterministic Flutter test input
      // client, not an assertion about the native Windows/Android IME.
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      final capture = GlobalKey();
      late LiveWorkbenchModel model;
      await fixture.exerciseWorkbench(
        editorWorkSubdirectory: 'external work 中文',
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
        detach: () async {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
        afterReady: () async {
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          // Clear only after split/PTY resize has settled; resize may legitimately
          // pull prior history into the viewport. Archive only synthetic output.
          for (var i = 0; i < model.sessions.length; i++) {
            final session = model.sessions[i] as LiveTerminalSession;
            if (!session.controller.visible) continue;
            await session.controller.text(
              r"printf '\033[2J\033[H%s%s\n' WORKBENCH_"
              " $i",
            );
            await session.controller.key(
              rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
            );
            await waitFor(
              () => screen(session.controller).startsWith('WORKBENCH_$i'),
              'synthetic screenshot viewport',
            );
          }
          final active = model.focus! as LiveTerminalSession;
          await tester.tap(find.byKey(active.view));
          await tester.pump();
          const command = "printf '%s%s\\n' GUI_ INPUT";
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: command,
              selection: TextSelection.collapsed(offset: command.length),
            ),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await waitFor(
            () => screen(active.controller).contains('GUI_INPUT'),
            'real workbench keyboard input',
          );
          await tester.pumpAndSettle();
          expect(find.text('UI 原型 · 模拟数据 · 不连接服务器'), findsNothing);
          expect(find.text('README.txt'), findsOneWidget);
          // Real upload through the native GTK chooser, then inspect the real
          // task group/details in the running workbench. No mocked file bytes.
          final uploadFixture = await Directory.systemTemp.createTemp(
            'hspterm-vault-ui-transfer-',
          );
          try {
            final local = File('${uploadFixture.path}/queue-fixture.txt');
            await local.writeAsString('真实队列 Unicode é');
            await File('${active.path}/queue-fixture.txt')
                .writeAsString('preserve until explicit overwrite');
            await tester.tap(find.byTooltip('上传'));
            await tester.pumpAndSettle();
            final chooser = await Process.start('python3', [
              'benchmark/native_file_picker_x11.py',
              'open',
              local.path,
            ]);
            unawaited(chooser.stdout.drain<void>());
            final errors = chooser.stderr.transform(utf8.decoder).join();
            await tester.tap(find.text('选择文件（可多选）'));
            expect(
              await chooser.exitCode.timeout(const Duration(seconds: 30)),
              0,
              reason: await errors,
            );
            await waitFor(
              () =>
                  model.transferTasks.isNotEmpty &&
                  model.transferTasks.every((t) => !t.busy),
              'real GTK upload queue',
            );
            final task = model.transferTasks.single;
            expect(task.state, 'Partial', reason: task.error);
            expect(
              await File('${active.path}/queue-fixture.txt').readAsString(),
              'preserve until explicit overwrite',
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('展开任务详情').first);
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('批次处理同名冲突…'));
            await tester.tap(find.text('批次处理同名冲突…'));
            await tester.pumpAndSettle();
            expect(find.text('处理 1 个同名冲突？'), findsOneWidget);
            final conflictBoundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final conflictImage = await conflictBoundary.toImage();
            final conflictPng = await conflictImage.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '${Directory.systemTemp.path}/hspterm-transfer-conflicts.png',
            ).writeAsBytes(conflictPng!.buffer.asUint8List());
            conflictImage.dispose();
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            expect(
              await File('${active.path}/queue-fixture.txt').readAsString(),
              'preserve until explicit overwrite',
            );
            for (
              var i = 0;
              i < 100 && find.textContaining('目标已存在，等待').evaluate().isEmpty;
              i++
            ) {
              await tester.pump();
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            await tester.ensureVisible(find.textContaining('目标已存在，等待'));
            await tester.tap(find.textContaining('目标已存在，等待'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('明确从头覆盖'));
            await waitFor(
              () =>
                  model.transferTasks.single.state == 'Complete' &&
                  !model.transferTasks.single.busy,
              'explicit GTK conflict overwrite',
            );
            expect(
              await File('${active.path}/queue-fixture.txt').readAsString(),
              '真实队列 Unicode é',
            );
            await waitFor(
              () => active.files.any((f) => f.name == 'queue-fixture.txt'),
              'directory refresh after upload',
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('▸ 已结束 · 1'));
            await tester.pumpAndSettle();
            expect(
              find.byKey(ValueKey('live-transfer-${task.id}')),
              findsOneWidget,
            );
            expect(find.textContaining('文件 1 · 目录 0'), findsOneWidget);
            expect(tester.takeException(), isNull);
            // A completion marker makes exact GTK coverage recoverable from logs.
            // ignore: avoid_print
            print('Verified native GTK upload and real transfer queue details');
            final subtree = Directory('${uploadFixture.path}/rescan-ui');
            await Directory('${subtree.path}/broken').create(recursive: true);
            await File('${subtree.path}/broken/old').writeAsString('old');
            await File('${subtree.path}/success').writeAsString('completed');
            final target = Directory('${active.path}/rescan-ui');
            await target.create();
            await File('${target.path}/broken').writeAsString('obstacle');
            final rescanId = await model.enqueueFileTransfer(
              active,
              subtree.path,
              target.path,
              true,
            );
            await waitFor(
              () => model.transferTasks.any((t) => t.id == rescanId && !t.busy),
              'GTK directory failure',
            );
            await File('${target.path}/broken').delete();
            await File('${subtree.path}/success').delete();
            await File('${subtree.path}/broken/new 中文').writeAsString('new');
            await tester.pumpAndSettle();
            final row = find.byKey(ValueKey('live-transfer-$rescanId'));
            await tester.ensureVisible(row);
            await tester.tap(
              find.descendant(of: row, matching: find.byTooltip('展开任务详情')),
            );
            for (
              var i = 0;
              i < 100 && find.textContaining('broken · ').evaluate().isEmpty;
              i++
            ) {
              await tester.pump();
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            Future<void> openRescan() async {
              await tester.ensureVisible(find.textContaining('broken · '));
              await tester.tap(find.textContaining('broken · '));
              await tester.pumpAndSettle();
              expect(find.text('重新扫描此失败目录？'), findsOneWidget);
              expect(find.text('明确从头覆盖'), findsNothing);
            }

            await openRescan();
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            expect(await Directory('${target.path}/broken').exists(), false);
            await openRescan();
            final rescanImage =
                await (capture.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final rescanPng = await rescanImage.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '${Directory.systemTemp.path}/hspterm-transfer-rescan.png',
            ).writeAsBytes(rescanPng!.buffer.asUint8List());
            rescanImage.dispose();
            await tester.tap(find.text('重扫并继续'));
            await waitFor(
              () => model.transferTasks.any(
                (t) => t.id == rescanId && !t.busy && t.state == 'Complete',
              ),
              'GTK subtree rescan',
            );
            expect(
              await File('${target.path}/broken/new 中文').readAsString(),
              'new',
            );
            expect(
              await File('${target.path}/success').readAsString(),
              'completed',
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            // ignore: avoid_print
            print(
              'Verified native GTK cancelled and accepted failed-subtree rescan',
            );
            await local.writeAsString('批次更名独立内容');
            final renameId = await model.enqueueFileTransfer(
              active,
              local.path,
              '${active.path}/queue-fixture.txt',
              true,
            );
            await waitFor(
              () => model.transferTasks.any(
                (t) => t.id == renameId && !t.busy && t.conflicts == 1,
              ),
              'GTK rename conflict',
            );
            await tester.pumpAndSettle();
            final renameRow = find.byKey(ValueKey('live-transfer-$renameId'));
            await tester.ensureVisible(renameRow);
            await tester.tap(
              find.descendant(
                of: renameRow,
                matching: find.byTooltip('展开任务详情'),
              ),
            );
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('批次处理同名冲突…'));
            await tester.tap(find.text('批次处理同名冲突…'));
            await tester.pumpAndSettle();
            final renameImage =
                await (capture.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final renamePng = await renameImage.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '${Directory.systemTemp.path}/hspterm-transfer-rename.png',
            ).writeAsBytes(renamePng!.buffer.asUint8List());
            renameImage.dispose();
            await tester.tap(find.text('全部更名另存'));
            await waitFor(
              () => model.transferTasks.any(
                (t) => t.id == renameId && !t.busy && t.state == 'Complete',
              ),
              'GTK batch rename',
            );
            expect(
              await File('${active.path}/queue-fixture (1).txt').readAsString(),
              '批次更名独立内容',
            );
            expect(
              await File('${active.path}/queue-fixture.txt').readAsString(),
              '真实队列 Unicode é',
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            // ignore: avoid_print
            print(
              'Verified native GTK batch rename preserves the original target',
            );
          } finally {
            await uploadFixture.delete(recursive: true);
          }
          // Real directory metadata crosses SSH/SFTP/FRB; the shared widget
          // still creates only visible rows and refreshes mutable directory data.
          final previousPath = active.path;
          final large = Directory('$previousPath/large-sftp-list');
          await large.create();
          for (var base = 0; base < 4096; base += 32) {
            await Future.wait(
              List.generate(32, (i) {
                final name =
                    'item-${(base + i).toString().padLeft(4, '0')}.txt';
                return File('${large.path}/$name').writeAsString('synthetic');
              }),
            );
          }
          await model.loadDirectory(active, large.path);
          await tester.pumpAndSettle();
          expect(active.files, hasLength(4096));
          expect(
            find.byKey(const ValueKey('file-item-0000.txt')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('file-item-4095.txt')),
            findsNothing,
          );
          final fileList = find.descendant(
            of: find.byType(FilesPanel),
            matching: find.byType(ListView),
          );
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: tester.getCenter(fileList),
              scrollDelta: const Offset(0, 600),
            ),
          );
          await tester.pumpAndSettle();
          await File('${large.path}/item-0000.txt')
              .rename('${large.path}/000-renamed.txt');
          await model.loadDirectory(active, large.path, remember: false);
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: tester.getCenter(fileList),
              scrollDelta: const Offset(0, -100000),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('file-000-renamed.txt')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await model.loadDirectory(active, previousPath, remember: false);
          await tester.pumpAndSettle();
          // ignore: avoid_print
          print(
            'Verified native GTK 4096-entry SFTP lazy rows, scroll and refreshed rename',
          );
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('${Directory.systemTemp.path}/hspterm-live-workbench.png')
              .writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
          // Real encrypted bookmark UI, scoped to the captured SSH session.
          final bookmarkGeneration = active.controller.generation;
          final bookmarkPath = active.path;
          final sidebarWidth = model.sidebarWidth;
          await tester.tap(find.byTooltip('目录书签'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('bookmark-add')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('bookmark-name')),
            'GTK 目录书签',
          );
          await tester.tap(find.byKey(const ValueKey('bookmark-save')));
          await tester.pumpAndSettle();
          var bookmarks = await rust.listSftpBookmarks(hostId: active.host.id);
          expect(bookmarks.single.path, bookmarkPath);
          expect(bookmarks.single.hostId, active.host.id);
          final bookmarkBoundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final bookmarkImage = await bookmarkBoundary.toImage();
          final bookmarkPng = await bookmarkImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('${Directory.systemTemp.path}/hspterm-bookmarks.png')
              .writeAsBytes(bookmarkPng!.buffer.asUint8List());
          bookmarkImage.dispose();
          await tester.tap(find.byTooltip('编辑书签 GTK 目录书签'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('bookmark-name')),
            'GTK 全局书签',
          );
          await tester.tap(find.byKey(const ValueKey('bookmark-global')));
          await tester.tap(find.byKey(const ValueKey('bookmark-save')));
          await tester.pumpAndSettle();
          bookmarks = await rust.listSftpBookmarks(hostId: active.host.id);
          expect(bookmarks.single.hostId, isNull);
          await tester.tap(find.byTooltip('删除书签 GTK 全局书签'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(
            await rust.listSftpBookmarks(hostId: active.host.id),
            hasLength(1),
          );
          await tester.tap(find.text('GTK 全局书签'));
          await tester.pumpAndSettle();
          expect(active.path, bookmarkPath);
          expect(active.controller.generation, bookmarkGeneration);
          expect(model.sidebarWidth, sidebarWidth);
          await tester.tap(find.byTooltip('目录书签'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('删除书签 GTK 全局书签'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('删除书签'));
          await tester.pumpAndSettle();
          expect(await rust.listSftpBookmarks(hostId: active.host.id), isEmpty);
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();
          debugPrint(
            'Verified native GTK encrypted global/host bookmarks, edit, navigation and deletion',
          );
          // The real context menu opens an identity-bound editor, not the
          // system preview. All content below is synthetic and disposable.
          final editing = File('${active.path}/editor 中文.txt');
          await editing.writeAsString('original remote text\n');
          await model.loadDirectory(active, active.path, remember: false);
          await tester.pumpAndSettle();
          final editorGeneration = active.controller.generation;
          Future<void> waitEditor(
            Future<bool> Function() condition,
            String reason,
          ) async {
            for (var i = 0; i < 300; i++) {
              await tester.pump();
              if (await condition()) return;
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            fail(reason);
          }

          Future<void> editorReady() async {
            for (var i = 0; i < 200; i++) {
              await tester.pump();
              if (find
                  .byKey(const ValueKey('editor-content'))
                  .evaluate()
                  .isNotEmpty) {
                return;
              }
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            fail('editor did not load');
          }

          await tester.tap(
            find.text('editor 中文.txt'),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('编辑').last);
          await editorReady();
          const savedText = 'GTK 保存 中文 é 😀\nsecond line\n';
          await tester.enterText(
            find.byKey(const ValueKey('editor-content')),
            savedText,
          );
          await tester.pumpAndSettle();
          expect(await editing.readAsString(), 'original remote text\n');
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await waitEditor(
            () async => await editing.readAsString() == savedText,
            'explicit GTK editor save',
          );
          await waitEditor(() async {
            final rows = await rust.listEditorDrafts();
            return rows.single.revision == rows.single.savedRevision;
          }, 'remote CLOSE and local clean acknowledgement');
          await tester.pumpAndSettle();
          final editorImage = await boundary.toImage();
          final editorPng = await editorImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('${Directory.systemTemp.path}/hspterm-remote-editor.png')
              .writeAsBytes(editorPng!.buffer.asUint8List());
          editorImage.dispose();
          final originalLimits = await rust.transferPreferences();
          await rust.saveTransferPreferences(
            value: TransferPreferences(
              concurrency: originalLimits.concurrency,
              uploadBytesPerSecond: 65536,
              downloadBytesPerSecond: originalLimits.downloadBytesPerSecond,
              defaultConflict: originalLimits.defaultConflict,
            ),
          );
          final progressText = 'GTK editor progress 中文\n' * 8192;
          await tester.enterText(
            find.byKey(const ValueKey('editor-content')),
            progressText,
          );
          await tester.tap(find.byKey(const ValueKey('editor-save')));
          await waitEditor(() async {
            final label = find.byKey(const ValueKey('editor-progress'));
            if (label.evaluate().isEmpty) return false;
            final bar = tester.widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('editor-progress-bar')),
            );
            return tester.widget<Text>(label).data!.contains('上传正文') &&
                bar.value != null &&
                bar.value! > 0 &&
                bar.value! < 1;
          }, 'real throttled GTK editor progress');
          await tester.pump();
          final progressImage = await boundary.toImage();
          final progressPng = await progressImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('${Directory.systemTemp.path}/hspterm-editor-progress.png')
              .writeAsBytes(progressPng!.buffer.asUint8List());
          progressImage.dispose();
          await waitEditor(() async {
            final rows = await rust.listEditorDrafts();
            return rows.single.revision == rows.single.savedRevision;
          }, 'throttled editor CLOSE acknowledgement');
          expect(await editing.readAsString(), progressText);
          await rust.saveTransferPreferences(value: originalLimits);
          await tester.pumpAndSettle();
          // Return to the small synthetic document before the recovery checks.
          final progressRevision =
              (await rust.listEditorDrafts()).single.revision;
          await tester.enterText(
            find.byKey(const ValueKey('editor-content')),
            savedText,
          );
          await tester.tap(find.byKey(const ValueKey('editor-save')));
          await waitEditor(() async {
            final rows = await rust.listEditorDrafts();
            return rows.single.revision > progressRevision &&
                rows.single.revision == rows.single.savedRevision;
          }, 'restored small editor document');
          expect(await editing.readAsString(), savedText);
          await tester.pumpAndSettle();
          const keptText = '本机恢复草稿 — 不自动上传\n';
          await tester.enterText(
            find.byKey(const ValueKey('editor-content')),
            keptText,
          );
          await tester.tap(find.byKey(const ValueKey('editor-close')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(model.hasActiveEditors, true);
          await tester.tap(find.byKey(const ValueKey('editor-close')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('保留草稿并关闭'));
          await waitFor(
            () => !model.hasActiveEditors,
            'encrypted editor close',
          );
          await tester.pumpAndSettle();
          expect(await editing.readAsString(), savedText);
          await tester.tap(find.byTooltip('文件视图选项'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('本机编辑草稿…'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(editing.path));
          await editorReady();
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('editor-content')))
                .controller!
                .text,
            keptText,
          );
          expect(
            tester
                .widget<FilledButton>(find.byKey(const ValueKey('editor-save')))
                .onPressed,
            isNull,
          );
          expect(active.controller.generation, editorGeneration);
          expect(await editing.readAsString(), savedText);
          await tester.tap(find.text('关联当前会话：${active.host.name}'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('editor-save')));
          await waitEditor(
            () async => await editing.readAsString() == keptText,
            'explicit recovered editor save',
          );
          await waitEditor(() async {
            final rows = await rust.listEditorDrafts();
            return rows.single.revision == rows.single.savedRevision;
          }, 'recovered clean acknowledgement');
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('editor-close')));
          await waitFor(() => !model.hasActiveEditors, 'clean editor close');
          await tester.pumpAndSettle();
          expect(await rust.listEditorDrafts(), isEmpty);
          expect(active.controller.generation, editorGeneration);
          expect(tester.takeException(), isNull);
          debugPrint(
            'Verified native GTK editor save, cancel close, encrypted offline recovery and explicit rebind',
          );
          await waitEditor(
            () async =>
                find.byKey(const ValueKey('editor-content')).evaluate().isEmpty,
            'editor route fully removed before opening the next context menu',
          );
          await tester.pumpAndSettle();
          // Real OS editor + directory watcher + original SSH session upload.
          // Neither the native chooser nor Mousepad is mocked.
          await tester.ensureVisible(find.text('editor 中文.txt'));
          await tester.pumpAndSettle();
          final rowRect = tester.getRect(
            find.byKey(const ValueKey('file-editor 中文.txt')),
          );
          final visibleRow = rowRect.intersect(
            tester.getRect(find.byType(FilesPanel)),
          );
          final binding = IntegrationTestWidgetsFlutterBinding.instance;
          final previousDeviceEvents =
              binding.shouldPropagateDevicePointerEvents;
          binding.shouldPropagateDevicePointerEvents = true;
          try {
            final contextClick = await Process.run('python3', [
              'benchmark/resize_x11.py',
              '$pid',
              '--sftp-menu',
              '${visibleRow.center.dx.round()}',
              '${visibleRow.center.dy.round()}',
            ]);
            expect(
              contextClick.exitCode,
              0,
              reason: contextClick.stderr.toString(),
            );
            await waitEditor(
              () async => find.text('编辑').evaluate().isNotEmpty,
              'real native mouse file context menu',
            );
          } finally {
            binding.shouldPropagateDevicePointerEvents = previousDeviceEvents;
          }
          await tester.pumpAndSettle();
          await tester.tap(find.text('编辑').last);
          await editorReady();
          final launcher = await Directory.systemTemp.createTemp(
            'hspterm-vault-ui-external-',
          );
          String? workingPath;
          try {
            final executable = '${launcher.path}/editor';
            await Link(executable).create('/usr/bin/mousepad');
            await tester.tap(
              find.byKey(const ValueKey('external-editor-menu')),
            );
            await tester.pumpAndSettle();
            final chooser = await Process.start('python3', [
              'benchmark/native_file_picker_x11.py',
              'open',
              executable,
            ]);
            unawaited(chooser.stdout.drain<void>());
            final errors = chooser.stderr.transform(utf8.decoder).join();
            await tester.tap(find.text('选择外部编辑器…'));
            expect(
              await chooser.exitCode.timeout(const Duration(seconds: 30)),
              0,
              reason: await errors,
            );
            await waitEditor(() async {
              final rows = await rust.listEditorDrafts();
              return rows.single.externalDirectory != null &&
                  find.text('外部编辑中 · 保存更改后自动回传到原服务器').evaluate().isNotEmpty;
            }, 'external editor launched');
            workingPath =
                '${(await rust.listEditorDrafts()).single.externalDirectory}/document.txt';
            expect(
              tester
                  .widget<TextField>(
                    find.byKey(const ValueKey('editor-content')),
                  )
                  .readOnly,
              true,
            );
            final driver = await Process.start('python3', [
              'benchmark/external_editor_x11.py',
              'edit',
              workingPath,
            ]);
            unawaited(driver.stdout.drain<void>());
            final driverErrors = driver.stderr.transform(utf8.decoder).join();
            expect(
              await driver.exitCode.timeout(const Duration(seconds: 40)),
              0,
              reason: await driverErrors,
            );
            const externalText =
                'Mousepad external 中文 é 😀\nsecond saved line\n';
            await waitEditor(() async {
              final rows = await rust.listEditorDrafts();
              return await editing.readAsString() == externalText &&
                  rows.single.revision == rows.single.savedRevision;
            }, 'Mousepad Save automatically uploaded to original SSH');
            await tester.pumpAndSettle();
            expect(
              File(workingPath).existsSync(),
              true,
              reason: 'editor exit never authorizes cache deletion',
            );
            final externalImage = await boundary.toImage();
            final externalPng = await externalImage.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '${Directory.systemTemp.path}/hspterm-external-editor.png',
            ).writeAsBytes(externalPng!.buffer.asUint8List());
            externalImage.dispose();
            await tester.tap(
              find.byKey(const ValueKey('external-editor-menu')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('确认结束并清理工作文件…'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('读取最新修改并清理'));
            await waitEditor(
              () async =>
                  (await rust.listEditorDrafts()).single.externalDirectory ==
                  null,
              'explicit safe external file cleanup',
            );
            expect(File(workingPath).existsSync(), false);
            expect(await editing.readAsString(), externalText);
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('editor-close')));
            await waitFor(
              () => !model.hasActiveEditors,
              'external editor close',
            );
            await tester.pumpAndSettle();
            expect(await rust.listEditorDrafts(), isEmpty);
            expect(active.controller.generation, editorGeneration);
            expect(tester.takeException(), isNull);
            debugPrint(
              'Verified real Mousepad Save, directory events, SSH auto upload, retained work file and explicit cleanup',
            );
          } finally {
            if (workingPath != null) {
              await Process.run('python3', [
                'benchmark/external_editor_x11.py',
                'close',
                workingPath,
              ]);
            }
            await launcher.delete(recursive: true);
          }
          await waitEditor(
            () async =>
                find.byKey(const ValueKey('editor-content')).evaluate().isEmpty,
            'external editor route removed before codec menu',
          );
          final legacy = File('${active.path}/legacy 中文.txt');
          const legacyBytes = [0xd6, 0xd0, 0xce, 0xc4];
          await legacy.writeAsBytes([...legacyBytes, 13, 10]);
          await model.loadDirectory(active, active.path, remember: false);
          await tester.pumpAndSettle();
          await tester.tap(
            find.text('legacy 中文.txt'),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('按指定编码编辑…'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('GBK'));
          await editorReady();
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextField>(find.byKey(const ValueKey('editor-content')))
                .controller!
                .text,
            '中文\r\n',
          );
          await tester.enterText(
            find.byKey(const ValueKey('editor-content')),
            '中文\n中文',
          );
          await tester.tap(find.byKey(const ValueKey('editor-save')));
          await waitEditor(() async {
            final rows = await rust.listEditorDrafts();
            return rows.single.revision == rows.single.savedRevision &&
                rows.single.revision > 1;
          }, 'explicit GBK remote save');
          expect(await legacy.readAsBytes(), [
            ...legacyBytes,
            13,
            10,
            ...legacyBytes,
          ]);
          await tester.pumpAndSettle();
          final codecImage = await boundary.toImage();
          final codecPng = await codecImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('/tmp/hspterm-legacy-editor.png')
              .writeAsBytes(codecPng!.buffer.asUint8List());
          codecImage.dispose();
          await tester.tap(find.byKey(const ValueKey('editor-close')));
          await waitEditor(
            () async =>
                find.byKey(const ValueKey('editor-content')).evaluate().isEmpty,
            'legacy editor close',
          );
          await tester.pumpAndSettle();
          expect(await rust.listEditorDrafts(), isEmpty);
          expect(active.controller.generation, editorGeneration);
          debugPrint(
            'Verified explicit GTK GBK selection, Unicode text and exact CRLF remote bytes',
          );
          // Actual GTK raw-file entry, native editor selection, directory
          // notification and SSH upload. Text is synthetic; no full body enters
          // the Flutter editor/controller even though the source exceeds 16MiB.
          final largeRaw = File('${active.path}/large raw 中文.txt');
          final rawBlock = utf8.encode(
            List.filled(1024, 'raw 中文 é 😀 line\n').join(),
          );
          final rawOutput = largeRaw.openWrite();
          for (var i = 0; i < 800; i++) {
            rawOutput.add(rawBlock);
          }
          await rawOutput.close();
          final rawLength = await largeRaw.length();
          expect(rawLength, greaterThan(16 * 1024 * 1024));
          await model.loadDirectory(active, active.path, remember: false);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('large raw 中文.txt'));
          await tester.tap(
            find.text('large raw 中文.txt'),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('外部编辑大文件…'));
          await waitEditor(
            () async => find
                .byKey(const ValueKey('editor-raw-body'))
                .evaluate()
                .isNotEmpty,
            'raw editor UI ready',
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('editor-content')), findsNothing);
          expect((await rust.listEditorDrafts()).single.rawBytes, rawLength);
          final rawImage = await boundary.toImage();
          final rawPng = await rawImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('/tmp/hspterm-raw-editor.png')
              .writeAsBytes(rawPng!.buffer.asUint8List());
          rawImage.dispose();
          final rawLauncher = await Directory.systemTemp.createTemp(
            'hspterm-vault-ui-raw-',
          );
          String? rawWorkingPath;
          try {
            final executable = '${rawLauncher.path}/editor';
            await Link(executable).create('/usr/bin/mousepad');
            await tester.tap(
              find.byKey(const ValueKey('external-editor-menu')),
            );
            await tester.pumpAndSettle();
            final chooser = await Process.start('python3', [
              'benchmark/native_file_picker_x11.py',
              'open',
              executable,
            ]);
            unawaited(chooser.stdout.drain<void>());
            final errors = chooser.stderr.transform(utf8.decoder).join();
            await tester.tap(find.text('选择外部编辑器…'));
            expect(
              await chooser.exitCode.timeout(const Duration(seconds: 30)),
              0,
              reason: await errors,
            );
            await waitEditor(
              () async =>
                  find.text('外部编辑中 · 保存更改后自动回传到原服务器').evaluate().isNotEmpty,
              'large raw external editor launched',
            );
            rawWorkingPath =
                '${(await rust.listEditorDrafts()).single.externalDirectory}/document.txt';
            expect(await File(rawWorkingPath).length(), rawLength);
            final driver = await Process.start('python3', [
              'benchmark/external_editor_x11.py',
              'edit',
              rawWorkingPath,
            ]);
            unawaited(driver.stdout.drain<void>());
            final driverErrors = driver.stderr.transform(utf8.decoder).join();
            expect(
              await driver.exitCode.timeout(const Duration(seconds: 40)),
              0,
              reason: await driverErrors,
            );
            await waitEditor(() async {
              final rows = await rust.listEditorDrafts();
              return (await largeRaw.length()) < rawLength &&
                  rows.single.revision == rows.single.savedRevision;
            }, 'large raw Mousepad Save uploaded');
            expect(
              await largeRaw.readAsString(),
              'Mousepad external 中文 é 😀\nsecond saved line\n',
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.byKey(const ValueKey('external-editor-menu')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('确认结束并清理工作文件…'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('读取最新修改并清理'));
            await waitEditor(
              () async =>
                  (await rust.listEditorDrafts()).single.externalDirectory ==
                  null,
              'raw explicit cleanup',
            );
            expect(File(rawWorkingPath).existsSync(), false);
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const ValueKey('editor-close')));
            await waitEditor(
              () async => !model.hasActiveEditors,
              'raw editor closed',
            );
            await tester.pumpAndSettle();
            expect(await rust.listEditorDrafts(), isEmpty);
            expect(active.controller.generation, editorGeneration);
            expect(tester.takeException(), isNull);
            debugPrint(
              'Verified GTK >16MiB raw external editing, Mousepad Save, byte-preserving SSH upload and safe cleanup',
            );
          } finally {
            if (rawWorkingPath != null) {
              await Process.run('python3', [
                'benchmark/external_editor_x11.py',
                'close',
                rawWorkingPath,
              ]);
            }
            await rawLauncher.delete(recursive: true);
          }
          final searchParent = active.path;
          final searchDirectory = Directory('$searchParent/recursive 搜索/子目录');
          await searchDirectory.create(recursive: true);
          await File('${searchDirectory.path}/match 中文.txt')
              .writeAsString('metadata search fixture');
          await tester.tap(find.byTooltip('文件视图选项'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('递归查找文件…'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('file-search-query')),
            'match 中文',
          );
          await tester.tap(find.byKey(const ValueKey('file-search-start')));
          await waitEditor(
            () async => find.text('match 中文.txt').evaluate().isNotEmpty,
            'real recursive file search result',
          );
          await tester.pumpAndSettle();
          final searchImage = await boundary.toImage();
          final searchPng = await searchImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('/tmp/hspterm-file-search.png')
              .writeAsBytes(searchPng!.buffer.asUint8List());
          searchImage.dispose();
          await tester.tap(find.text('match 中文.txt'));
          await waitEditor(
            () async =>
                active.path == searchDirectory.path &&
                find
                    .byKey(const ValueKey('file-match 中文.txt'))
                    .evaluate()
                    .isNotEmpty,
            'search result located in original SFTP',
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<Container>(
                  find.byKey(const ValueKey('file-match 中文.txt')),
                )
                .color,
            isNotNull,
          );
          expect(active.controller.generation, editorGeneration);
          expect(tester.takeException(), isNull);
          await model.loadDirectory(active, searchParent, remember: false);
          await tester.pumpAndSettle();
          debugPrint(
            'Verified GTK real recursive filename search and original-session SFTP selection',
          );
          final completionParent = active.path;
          // Real context-menu copy/paste, explicit relay consent and queue.
          // No external clipboard payload or local temp body is used.
          final clipboardRoot = Directory('$completionParent/clipboard UI');
          final clipboardDestination = Directory(
            '${clipboardRoot.path}/destination',
          );
          await clipboardDestination.create(recursive: true);
          const clipboardText = 'SFTP copy 中文 e\u0301\n';
          await File('${clipboardRoot.path}/copy 中文.txt')
              .writeAsString(clipboardText);
          await File('${clipboardDestination.path}/anchor.txt')
              .writeAsString('target directory anchor');
          await model.loadDirectory(
            active,
            clipboardRoot.path,
            remember: false,
          );
          await tester.pumpAndSettle();
          Future<void> fileMenu(String name, String tooltip) async {
            final row = find.byKey(ValueKey('file-$name'));
            await tester.ensureVisible(row);
            await tester.pumpAndSettle();
            final click = await tester.startGesture(
              tester.getCenter(row),
              kind: PointerDeviceKind.mouse,
              buttons: kSecondaryMouseButton,
            );
            await click.up();
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip(tooltip).last);
            await tester.pumpAndSettle();
          }

          await fileMenu('copy 中文.txt', '复制');
          expect(model.remoteFileClipboardDescription, contains('1 项'));
          await model.loadDirectory(
            active,
            clipboardDestination.path,
            remember: false,
          );
          await tester.pumpAndSettle();
          await fileMenu('anchor.txt', '粘贴');
          expect(find.text('复制到当前远端目录？'), findsOneWidget);
          await tester.tap(find.text('取消').last);
          await tester.pumpAndSettle();
          expect(
            await File('${clipboardDestination.path}/copy 中文.txt').exists(),
            false,
          );
          await rust.saveTransferPreferences(
            value: const TransferPreferences(
              concurrency: 3,
              uploadBytesPerSecond: 0,
              downloadBytesPerSecond: 0,
              defaultConflict: 'ask',
            ),
          );
          await fileMenu('anchor.txt', '粘贴');
          await tester.tap(find.text('允许中转并复制'));
          await waitEditor(() async {
            await model.refreshTransfers();
            return model.transferTasks.any(
              (t) =>
                  t.sourceRemote?.endsWith('/copy 中文.txt') == true &&
                  !t.busy &&
                  t.state == 'Complete',
            );
          }, 'real GTK file clipboard copy');
          expect(
            await File('${clipboardDestination.path}/copy 中文.txt')
                .readAsString(),
            clipboardText,
          );
          expect(active.controller.generation, editorGeneration);
          await tester.pumpAndSettle();
          final copiedTask = model.transferTasks.singleWhere(
            (t) => t.sourceRemote?.endsWith('/copy 中文.txt') == true,
          );
          Future<void> showFileTask(String id) async {
            final collapsedDone = find.textContaining(RegExp(r'^▸ 已结束 ·'));
            if (collapsedDone.evaluate().isNotEmpty) {
              await tester.tap(collapsedDone);
              await tester.pumpAndSettle();
            }
            final row = find.byKey(ValueKey('live-transfer-$id'));
            await tester.scrollUntilVisible(
              row,
              160,
              scrollable: find
                  .descendant(
                    of: find.byType(LiveTransferQueue),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.descendant(of: row, matching: find.byTooltip('展开任务详情')),
            );
            await tester.pumpAndSettle();
          }

          await showFileTask(copiedTask.id);
          expect(find.textContaining('远端复制：'), findsOneWidget);
          final copyImage =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final copyPng = await copyImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('/tmp/hspterm-remote-copy.png')
              .writeAsBytes(copyPng!.buffer.asUint8List());
          copyImage.dispose();
          await model.clearEndedTasks();
          final moveSource = File('${clipboardRoot.path}/move 中文.txt');
          const moveText = 'GTK 同账户移动 e\u0301\n';
          await moveSource.writeAsString(moveText);
          await model.loadDirectory(
            active,
            clipboardRoot.path,
            remember: false,
          );
          await tester.pumpAndSettle();
          await fileMenu('move 中文.txt', '剪切');
          expect(model.remoteFileClipboardIsCut, true);
          await model.loadDirectory(
            active,
            clipboardDestination.path,
            remember: false,
          );
          await tester.pumpAndSettle();
          await fileMenu('anchor.txt', '粘贴');
          expect(find.text('移动到当前远端目录？'), findsOneWidget);
          await tester.tap(find.text('取消').last);
          await tester.pumpAndSettle();
          expect(await moveSource.exists(), true);
          await fileMenu('anchor.txt', '粘贴');
          await tester.tap(find.text('确认移动并允许跨服中转'));
          await waitEditor(() async {
            await model.refreshTransfers();
            return model.transferTasks.any(
              (t) =>
                  t.remoteOperation == 'move' &&
                  t.sourceRemote?.endsWith('/move 中文.txt') == true &&
                  !t.busy &&
                  t.state == 'Complete',
            );
          }, 'real GTK cut and confirmed same-account move');
          expect(await moveSource.exists(), false);
          expect(
            await File('${clipboardDestination.path}/move 中文.txt')
                .readAsString(),
            moveText,
          );
          expect(model.remoteFileClipboardDescription, isNull);
          expect(active.controller.generation, editorGeneration);
          final movedTask = model.transferTasks.singleWhere(
            (t) =>
                t.remoteOperation == 'move' &&
                t.sourceRemote?.endsWith('/move 中文.txt') == true,
          );
          await showFileTask(movedTask.id);
          expect(find.textContaining('远端移动：'), findsOneWidget);
          expect(find.text('服务器直接移动；未扫描内部目录，不统计传输字节'), findsOneWidget);
          final moveImage =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final movePng = await moveImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('/tmp/hspterm-remote-move.png')
              .writeAsBytes(movePng!.buffer.asUint8List());
          moveImage.dispose();
          debugPrint(
            'Verified GTK real cut clipboard, cancelled move consent and acknowledged metadata move',
          );

          // Independent destination actions must not replace the file clipboard.
          final explicitTarget = Directory(
            '${clipboardRoot.path}/explicit target 中文',
          );
          await explicitTarget.create();
          await File('${clipboardRoot.path}/copy to 中文.txt')
              .writeAsString('GTK explicit copy e\u0301');
          final explicitMove = File('${clipboardRoot.path}/move to 中文.txt');
          await explicitMove.writeAsString('GTK explicit move e\u0301');
          await model.loadDirectory(
            active,
            clipboardRoot.path,
            remember: false,
          );
          await tester.pumpAndSettle();
          model.copyRemoteFileClipboard(active, [
            active.files.singleWhere((f) => f.name == 'copy 中文.txt'),
          ]);
          final independentRevision = model.remoteFileClipboardRevision;
          final independentDescription = model.remoteFileClipboardDescription;
          Future<void> destinationMenu(String name, String action) async {
            final row = find.byKey(ValueKey('file-$name'));
            await tester.ensureVisible(row);
            await tester.pumpAndSettle();
            final pointer = await tester.startGesture(
              tester.getCenter(row),
              kind: PointerDeviceKind.mouse,
              buttons: kSecondaryMouseButton,
            );
            await pointer.up();
            await tester.pumpAndSettle();
            await tester.tap(find.text(action));
            await tester.pumpAndSettle();
          }

          await destinationMenu('copy to 中文.txt', '复制到…');
          await tester.tap(find.text('关闭').last);
          await tester.pumpAndSettle();
          expect(
            await File('${explicitTarget.path}/copy to 中文.txt').exists(),
            false,
          );
          await destinationMenu('copy to 中文.txt', '复制到…');
          await tester.enterText(
            find.byKey(const ValueKey('remote-destination-path')),
            explicitTarget.path,
          );
          await tester.pumpAndSettle();
          final destinationImage =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final destinationPng = await destinationImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('/tmp/hspterm-remote-destination.png')
              .writeAsBytes(destinationPng!.buffer.asUint8List());
          destinationImage.dispose();
          await tester.tap(find.text('允许中转并复制'));
          await waitEditor(() async {
            await model.refreshTransfers();
            return model.transferTasks.any(
              (t) =>
                  t.sourceRemote?.endsWith('/copy to 中文.txt') == true &&
                  !t.busy &&
                  t.state == 'Complete',
            );
          }, 'real GTK copy-to');
          await tester.pumpAndSettle();
          expect(
            await File('${explicitTarget.path}/copy to 中文.txt').readAsString(),
            'GTK explicit copy e\u0301',
          );
          expect(model.remoteFileClipboardRevision, independentRevision);
          expect(model.remoteFileClipboardDescription, independentDescription);
          expect(
            find.byKey(const ValueKey('remote-destination-path')),
            findsNothing,
          );
          await model.loadDirectory(
            active,
            clipboardRoot.path,
            remember: false,
          );
          await tester.pumpAndSettle();
          await destinationMenu('move to 中文.txt', '移动到…');
          await tester.enterText(
            find.byKey(const ValueKey('remote-destination-path')),
            explicitTarget.path,
          );
          await tester.tap(find.text('确认移动并允许跨服中转'));
          await waitEditor(() async {
            await model.refreshTransfers();
            return model.transferTasks.any(
              (t) =>
                  t.sourceRemote?.endsWith('/move to 中文.txt') == true &&
                  !t.busy &&
                  t.state == 'Complete',
            );
          }, 'real GTK move-to');
          await tester.pumpAndSettle();
          expect(await explicitMove.exists(), false);
          expect(
            await File('${explicitTarget.path}/move to 中文.txt').readAsString(),
            'GTK explicit move e\u0301',
          );
          expect(model.remoteFileClipboardRevision, independentRevision);
          expect(model.remoteFileClipboardDescription, independentDescription);
          expect(active.controller.generation, editorGeneration);
          expect(
            find.byKey(const ValueKey('remote-destination-path')),
            findsNothing,
          );
          debugPrint(
            'Verified GTK explicit copy-to/move-to, cancelled dialog and independent file clipboard',
          );

          final remoteRescanSource = Directory(
            '${clipboardRoot.path}/rescan UI source',
          );
          final remoteRescanTarget = Directory(
            '${explicitTarget.path}/rescan UI source',
          );
          await Directory('${remoteRescanSource.path}/broken')
              .create(recursive: true);
          await remoteRescanTarget.create();
          await File('${remoteRescanSource.path}/success')
              .writeAsString('remote completed sibling');
          await File('${remoteRescanSource.path}/broken/old')
              .writeAsString('old remote child');
          await File('${remoteRescanTarget.path}/broken')
              .writeAsString('remote fixture obstacle');
          await model.loadDirectory(
            active,
            clipboardRoot.path,
            remember: false,
          );
          await tester.pumpAndSettle();
          await destinationMenu('rescan UI source', '复制到…');
          await tester.enterText(
            find.byKey(const ValueKey('remote-destination-path')),
            explicitTarget.path,
          );
          await tester.tap(find.text('允许中转并复制'));
          await waitEditor(() async {
            await model.refreshTransfers();
            return model.transferTasks.any(
              (t) =>
                  t.sourceRemote == remoteRescanSource.path &&
                  !t.busy &&
                  t.state == 'Partial',
            );
          }, 'real GTK remote tree partial');
          await tester.pumpAndSettle();
          final remoteRescanTask = model.transferTasks.singleWhere(
            (t) => t.sourceRemote == remoteRescanSource.path,
          );
          await File('${remoteRescanTarget.path}/broken').delete();
          await File('${remoteRescanSource.path}/success').delete();
          await File('${remoteRescanTarget.path}/success')
              .writeAsString('later remote target change');
          await File('${remoteRescanSource.path}/broken/new 中文')
              .writeAsString('new remote child');
          await showFileTask(remoteRescanTask.id);
          Future<void> openRemoteRescan() async {
            final detail = find.descendant(
              // Only one task is expanded. Its details are a sibling of the
              // keyed title row, and arrive asynchronously through Native.
              of: find.byType(LiveTransferQueue),
              matching: find.textContaining('broken · '),
            );
            await waitEditor(
              () async => detail.evaluate().isNotEmpty,
              'remote directory failure details',
            );
            await tester.ensureVisible(detail);
            await tester.tap(detail);
            await tester.pumpAndSettle();
            expect(find.text('重新扫描此失败目录？'), findsOneWidget);
          }

          await openRemoteRescan();
          await tester.tap(find.text('取消').last);
          await tester.pumpAndSettle();
          expect(
            await Directory('${remoteRescanTarget.path}/broken').exists(),
            false,
          );
          await openRemoteRescan();
          final remoteRescanImage =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final remoteRescanPng = await remoteRescanImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('/tmp/hspterm-remote-rescan.png')
              .writeAsBytes(remoteRescanPng!.buffer.asUint8List());
          remoteRescanImage.dispose();
          await tester.tap(find.text('重扫并继续'));
          await waitEditor(() async {
            await model.refreshTransfers();
            return model.transferTasks.any(
              (t) =>
                  t.id == remoteRescanTask.id &&
                  !t.busy &&
                  t.state == 'Complete',
            );
          }, 'real GTK remote tree rescan');
          await tester.pumpAndSettle();
          expect(
            await File('${remoteRescanTarget.path}/success').readAsString(),
            'later remote target change',
          );
          expect(
            await File('${remoteRescanTarget.path}/broken/new 中文')
                .readAsString(),
            'new remote child',
          );
          expect(
            await File('${remoteRescanTarget.path}/broken/old').readAsString(),
            'old remote child',
          );
          expect(active.controller.generation, editorGeneration);
          expect(model.remoteFileClipboardRevision, independentRevision);
          debugPrint(
            'Verified GTK remote tree failure rescan: cancel, explicit confirmation and completed-sibling preservation',
          );

          await model.clearEndedTasks();
          await model.loadDirectory(active, completionParent, remember: false);
          await tester.pumpAndSettle();
          debugPrint(
            'Verified GTK real file-copy clipboard, cancelled consent and confirmed relay queue',
          );
          final completionPath = '$completionParent/completion 中文 space';
          await Directory(completionPath).create();
          await model.loadDirectory(active, completionParent, remember: false);
          await tester.pumpAndSettle();
          final completionEpoch = active.directoryEpoch;
          final completionGeneration = active.controller.generation;
          final pathField = find.byKey(const ValueKey('remote-path'));
          await tester.enterText(pathField, '$completionParent/completion 中');
          await tester.pumpAndSettle();
          final option = find.byKey(ValueKey('cached-path-$completionPath'));
          expect(option, findsOneWidget);
          expect(active.path, completionParent);
          expect(active.directoryEpoch, completionEpoch);
          final completionImage = await boundary.toImage();
          final completionPng = await completionImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File('${Directory.systemTemp.path}/hspterm-cached-path.png')
              .writeAsBytes(completionPng!.buffer.asUint8List());
          completionImage.dispose();
          await tester.tap(option);
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(pathField).controller!.text,
            completionPath,
          );
          expect(active.path, completionParent);
          expect(active.directoryEpoch, completionEpoch);
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(active.path, completionPath);
          expect(active.controller.generation, completionGeneration);
          expect(model.sidebarWidth, sidebarWidth);
          debugPrint(
            'Verified native GTK session-cache completion without implicit navigation',
          );
          model.show(WorkPage.settings);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('settings-SFTP 与传输')));
          await tester.pumpAndSettle();
          final previewLimit = find.byKey(
            const ValueKey('file-open-confirmation-mib'),
          );
          await tester.ensureVisible(previewLimit);
          await tester.enterText(previewLimit, '50');
          final savePreview = find.byKey(
            const ValueKey('save-file-open-settings'),
          );
          await tester.ensureVisible(savePreview);
          await tester.pumpAndSettle();
          await tester.tap(savePreview);
          for (
            var i = 0;
            i < 100 && (await rust.fileOpenPreferences()).confirmationMib != 50;
            i++
          ) {
            await tester.pump();
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          await tester.pumpAndSettle();
          expect((await rust.fileOpenPreferences()).confirmationMib, 50);
          expect(find.text('大文件预览确认'), findsNothing);
          expect(find.text('文件打开设置已加密保存'), findsOneWidget);
          final previewSettingsImage = await boundary.toImage();
          final previewSettingsPng = await previewSettingsImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File(
            '${Directory.systemTemp.path}/hspterm-file-open-settings.png',
          ).writeAsBytes(previewSettingsPng!.buffer.asUint8List());
          previewSettingsImage.dispose();
          debugPrint(
            'Verified native GTK encrypted file-open confirmation settings',
          );
          final concurrency = find.byKey(
            const ValueKey('transfer-setting-并发顶层任务'),
          );
          await tester.ensureVisible(concurrency);
          await tester.enterText(concurrency, '2');
          final upload = find.byKey(
            const ValueKey('transfer-setting-总体上传限制（字节/秒）'),
          );
          await tester.ensureVisible(upload);
          await tester.enterText(upload, '1048576');
          final policy = find.byKey(
            const ValueKey('transfer-default-conflict'),
          );
          await tester.ensureVisible(policy);
          await tester.tap(policy);
          await tester.pumpAndSettle();
          await tester.tap(find.text('更名另存，保留旧目标').last);
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('save-transfer-settings')),
          );
          await tester.tap(
            find.byKey(const ValueKey('save-transfer-settings')),
          );
          for (
            var i = 0;
            i < 100 && (await rust.transferPreferences()).concurrency != 2;
            i++
          ) {
            await tester.pump();
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          await tester.pumpAndSettle();
          final preferences = await rust.transferPreferences();
          expect(preferences.concurrency, 2);
          expect(preferences.uploadBytesPerSecond, 1048576);
          expect(preferences.defaultConflict, 'rename');
          expect(find.text('同名冲突默认动作'), findsNothing);
          expect(find.text('已加密保存并生效'), findsOneWidget);
          final settingsImage = await boundary.toImage();
          final settingsPng = await settingsImage.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File(
            '${Directory.systemTemp.path}/hspterm-transfer-settings.png',
          ).writeAsBytes(settingsPng!.buffer.asUint8List());
          settingsImage.dispose();
          // Aggregate fixture completion marker only, never configuration contents.
          // ignore: avoid_print
          print('Verified native GTK encrypted transfer settings');
          model.show(WorkPage.workspace);
          await tester.pumpAndSettle();
        },
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Exercise the actual master-password and explicit-save UI, not a preloaded model.
      final directory = await Directory.systemTemp.createTemp(
        'hspterm-vault-ui-',
      );
      try {
        Future<void> pumpUntil(Finder target) async {
          for (var i = 0; i < 200; i++) {
            await tester.pump();
            if (target.evaluate().isNotEmpty) return;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          fail(
            'UI did not reach $target; visible labels: ${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).join(' / ')}',
          );
        }

        await tester.pumpWidget(
          WorkbenchApp(vaultPath: '${directory.path}/ui.vault'),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('vault-password')),
          'fixture-master',
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('vault-password')))
              .controller!
              .text,
          'fixture-master',
        );
        await tester.enterText(
          find.byKey(const ValueKey('vault-confirm')),
          'mismatch',
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('vault-password')))
              .controller!
              .text,
          'fixture-master',
        );
        await tester.tap(find.byKey(const ValueKey('unlock-vault')));
        await pumpUntil(find.textContaining('两次主密码必须一致'));
        expect(await File('${directory.path}/ui.vault').exists(), false);
        await tester.enterText(
          find.byKey(const ValueKey('vault-confirm')),
          'fixture-master',
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('vault-password')))
              .controller!
              .text,
          'fixture-master',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('vault-confirm')))
              .controller!
              .text,
          'fixture-master',
        );
        await tester.tap(find.byKey(const ValueKey('unlock-vault')));
        await pumpUntil(find.byKey(const ValueKey('nav-hosts')));
        expect(find.text('开始新的连接'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('nav-hosts')));
        await tester.pumpAndSettle();
        expect(find.text('本机加密配置'), findsOneWidget);
        expect(find.text('模拟配置 · 仅内存'), findsNothing);
        await tester.enterText(
          find.byKey(const ValueKey('host-主机名称')),
          'Saved through GUI',
        );
        await tester.enterText(
          find.byKey(const ValueKey('host-主机地址')),
          '127.0.0.1',
        );
        await tester.ensureVisible(find.byKey(const ValueKey('host-auth')));
        await tester.tap(find.byKey(const ValueKey('host-auth')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('密码').last);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('host-secret')));
        await tester.enterText(
          find.byKey(const ValueKey('host-secret')),
          'test-only-ui-password',
        );
        expect(
          await rust.listHosts(),
          isEmpty,
          reason: 'draft is not a formally saved host',
        );
        await tester.tap(find.byKey(const ValueKey('save-host')));
        await tester.pumpAndSettle();
        final saved = await rust.listHosts();
        expect(saved.single.name, 'Saved through GUI');
        expect(saved.single.credentialSet, true);
        expect(await rust.hostDrafts(), isEmpty);
        expect(find.text('HSPTerm · SSH'), findsOneWidget);
        expect(
          await File('${directory.path}/ui.vault')
              .readAsString(encoding: latin1),
          isNot(contains('test-only-ui-password')),
        );
        await tester.tap(find.byKey(const ValueKey('new-host')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('host-主机名称')),
          'Generated through GUI',
        );
        await tester.enterText(
          find.byKey(const ValueKey('host-主机地址')),
          '127.0.0.1',
        );
        await tester.ensureVisible(
          find.byKey(const ValueKey('generate-host-key')),
        );
        await tester.tap(find.byKey(const ValueKey('generate-host-key')));
        await pumpUntil(find.text('ssh-ed25519 公钥'));
        expect(
          (await rust.listHosts()).length,
          1,
          reason: 'key generation only saves a draft',
        );
        expect((await rust.hostDrafts()).single.credentialSet, true);
        expect(find.textContaining('-----BEGIN'), findsNothing);
        await tester.tap(find.text('关闭').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('host-secret')))
              .controller!
              .text,
          isEmpty,
        );
        // Drive the actual native GTK save/open dialogs in the private Xvfb
        // display. Only fixture paths are typed; key contents never enter UI.
        Future<Process> picker(String mode, String path) => Process.start(
          'python3',
          ['benchmark/native_file_picker_x11.py', mode, path],
        );
        Future<void> pickerFinished(Process process) async {
          unawaited(process.stdout.drain<void>());
          final errors = process.stderr.transform(utf8.decoder).join();
          expect(
            await process.exitCode.timeout(const Duration(seconds: 30)),
            0,
            reason: await errors,
          );
        }

        final identity = (await rust.hostDrafts()).single.id;
        final expectedPublic = (await rust.hostPublicKey(id: identity))
            .publicKey;
        final privateFile = '${directory.path}/native-export-private';
        await tester.ensureVisible(find.text('导出私钥…'));
        await tester.tap(find.text('导出私钥…'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('key-export-master')),
          'fixture-master',
        );
        final saving = await picker('save', privateFile);
        await tester.tap(find.text('选择文件并导出'));
        await pickerFinished(saving);
        await waitFor(
          () => File(privateFile).existsSync(),
          'native private key export',
        );
        await pumpUntil(find.text('私钥已保存到所选新文件；未写入剪贴板'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('import-host-key')),
        );
        await tester.tap(find.byKey(const ValueKey('import-host-key')));
        await tester.pumpAndSettle();
        final opening = await picker('open', privateFile);
        await tester.tap(find.text('导入密钥'));
        await pickerFinished(opening);
        await pumpUntil(find.text('ssh-ed25519 公钥'));
        expect(
          (await rust.hostPublicKey(id: identity)).publicKey,
          expectedPublic,
        );
        await tester.tap(find.text('关闭').last);
        await tester.pumpAndSettle();
        // Recreate the application and reopen the same encrypted vault. A new
        // draft must remain discoverable even when formal hosts already exist.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          WorkbenchApp(vaultPath: '${directory.path}/ui.vault'),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('vault-password')),
          'fixture-master',
        );
        await tester.tap(find.byKey(const ValueKey('unlock-vault')));
        await pumpUntil(find.byKey(const ValueKey('nav-hosts')));
        expect(find.text('开始新的连接'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('nav-hosts')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('recover-host-draft')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Generated through GUI').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('host-主机名称')))
              .controller!
              .text,
          'Generated through GUI',
        );
        await tester.tap(find.text('认证').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('host-secret')))
              .controller!
              .text,
          isEmpty,
        );
        await tester.tap(find.byKey(const ValueKey('save-host')));
        for (var i = 0; i < 100; i++) {
          await tester.pump();
          if ((await rust.listHosts()).length == 2) break;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect((await rust.listHosts()).length, 2);
        expect(await rust.hostDrafts(), isEmpty);
        debugPrint(
          'Verified native GTK key open/save and persisted draft recovery',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
    skip: !Platform.isLinux,
  );
}
