import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

/// Routing fixture only. Actual bytes, endpoint binding and SQLite recovery
/// are exercised by remote_transfer_bridge_test and live_workbench_test.
class _ClipboardRouting extends WorkbenchModel {
  final copied = <TerminalSession>[];
  final pasted = <(TerminalSession, String, int, int)>[];
  int revision = 0;
  bool cutting = false;
  @override
  bool get remoteFileClipboardIsCut => cutting;
  @override
  bool get isMock => false;
  @override
  String? get remoteFileClipboardDescription =>
      revision == 0 ? null : '1 项 · routing fixture';
  @override
  int get remoteFileClipboardRevision => revision;
  @override
  void copyRemoteFileClipboard(
    TerminalSession session,
    List<DemoFile> files, {
    bool cut = false,
  }) {
    copied.add(session);
    cutting = cut;
    revision++;
  }

  @override
  Future<List<String>> pasteRemoteFileClipboard(
    TerminalSession target,
    String directory,
    int expectedGeneration, {
    required bool allowMemoryRelay,
    bool allowDirect = false,
    required int expectedClipboardRevision,
  }) async {
    if ((!cutting && !allowMemoryRelay) ||
        revision != expectedClipboardRevision) {
      throw StateError('routing fixture revision changed');
    }
    pasted.add((
      target,
      directory,
      expectedGeneration,
      expectedClipboardRevision,
    ));
    return ['routing-task'];
  }
}

void main() {
  testWidgets(
    'copy-to and move-to route the original selection independently of clipboard actions',
    (tester) async {
      final m = _ClipboardRouting()..demo();
      final source = m.focus!;
      final file = source.files.firstWhere((f) => !f.folder);
      final routed = <(TerminalSession, List<DemoFile>, bool)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 380,
              child: FilesPanel(
                model: m,
                pane: source,
                onTransferTo: (_, session, files, move) async =>
                    routed.add((session, files, move)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final action in ['复制到…', '移动到…']) {
        final pointer = await tester.startGesture(
          tester.getCenter(find.text(file.name)),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await pointer.up();
        await tester.pumpAndSettle();
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
      }
      expect(routed.map((r) => r.$1), everyElement(same(source)));
      expect(routed.map((r) => r.$2), everyElement([file]));
      expect(routed.map((r) => r.$3), [false, true]);
      expect(m.copied, isEmpty);
      expect(m.pasted, isEmpty);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'cut confirms source removal and explicit cross-server relay permission',
    (tester) async {
      final m = _ClipboardRouting()..demo();
      final pane = m.focus!;
      final file = pane.files.firstWhere((f) => !f.folder);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 380,
              child: FilesPanel(model: m, pane: pane),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> command(String label) async {
        final pointer = await tester.startGesture(
          tester.getCenter(find.text(file.name)),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await pointer.up();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(label).last);
        await tester.pumpAndSettle();
      }

      await command('剪切');
      expect(m.remoteFileClipboardIsCut, true);
      expect(m.pasted, isEmpty);
      await command('粘贴');
      expect(find.text('移动到当前远端目录？'), findsOneWidget);
      expect(find.text('允许中转并复制'), findsNothing);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(m.pasted, isEmpty);
      await command('粘贴');
      await tester.tap(find.text('确认移动并允许跨服中转'));
      await tester.pumpAndSettle();
      expect(m.pasted.single, (
        pane,
        pane.path,
        pane.connectionGeneration,
        m.revision,
      ));
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'a file menu cannot redirect to a different session with the same path and generation',
    (tester) async {
      final m = _ClipboardRouting()..demo();
      final a = m.focus!, b = m.sessions.firstWhere((s) => !identical(s, a));
      b.path = a.path;
      b.connectionGeneration = a.connectionGeneration;
      final file = a.files.firstWhere((f) => !f.folder);
      Widget app(TerminalSession pane) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 380,
            child: FilesPanel(model: m, pane: pane),
          ),
        ),
      );
      Future<void> menu(String name) async {
        final pointer = await tester.startGesture(
          tester.getCenter(find.text(name)),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await pointer.up();
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(app(a));
      await tester.pumpAndSettle();
      await menu(file.name);
      await tester.pumpWidget(app(b));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('复制').last);
      await tester.pumpAndSettle();
      expect(m.copied, isEmpty);
      expect(find.textContaining('目录或会话已切换'), findsOneWidget);
      await menu(file.name);
      await tester.tap(find.byTooltip('复制').last);
      await tester.pumpAndSettle();
      expect(m.copied.single, same(b));
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'remote file paste requires explicit consent and binds the displayed clipboard revision',
    (tester) async {
      final m = _ClipboardRouting()..demo();
      final pane = m.focus!;
      final file = pane.files.firstWhere((f) => !f.folder);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 380,
              child: FilesPanel(model: m, pane: pane),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> command(String label) async {
        final pointer = await tester.startGesture(
          tester.getCenter(find.text(file.name)),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await pointer.up();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip(label).last);
        await tester.pumpAndSettle();
      }

      await command('复制');
      await command('粘贴');
      expect(m.pasted, isEmpty);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(m.pasted, isEmpty);
      await command('粘贴');
      m.revision++;
      await tester.tap(find.text('允许中转并复制'));
      await tester.pumpAndSettle();
      expect(m.pasted, isEmpty);
      await command('粘贴');
      await tester.tap(find.text('允许中转并复制'));
      await tester.pumpAndSettle();
      expect(m.pasted.single, (
        pane,
        pane.path,
        pane.connectionGeneration,
        m.revision,
      ));
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets(
    'file context menu remains usable after an editor dialog closes',
    (tester) async {
      final model = WorkbenchModel()..demo();
      final session = model.focus!;
      final file = session.files.firstWhere((f) => !f.folder);
      var opened = 0;
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 380,
              child: FilesPanel(
                model: model,
                pane: session,
                onEditFile: (context, _, _) async {
                  opened++;
                  await showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Fixture editor'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close fixture'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        final pointer = await tester.startGesture(
          tester.getCenter(find.text(file.name)),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pump(const Duration(milliseconds: 160));
        expect(
          find.text('编辑'),
          findsNothing,
          reason: 'a modal route must not interrupt the held pointer sequence',
        );
        await pointer.up();
        await tester.pumpAndSettle();
        expect(find.text('编辑'), findsOneWidget);
        await tester.tap(find.text('编辑'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Close fixture'));
        await tester.pumpAndSettle();
      }
      expect(opened, 2);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
