//! Round-9 visual captures: the in-name-cell rename editor and the themed
//! context menu render correctly (saved as PNG artifacts for review).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

Future<void> mount(WidgetTester tester, WorkbenchModel model) async {
  await tester.binding.setSurfaceSize(const Size(1000, 760));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 700,
          child: AnimatedBuilder(
            animation: model,
            builder: (_, _) => FilesPanel(model: model, pane: model.focus!),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> savePng(WidgetTester tester, String name) async {
  // Walk up from the panel to the nearest RepaintBoundary; toImage needs
  // the real rasterizer (runAsync).
  RenderObject node = tester.renderObject(find.byType(FilesPanel));
  while (node is! RenderRepaintBoundary) {
    node = node.parent!;
  }
  final boundary = node;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('/tmp/hspterm-r9-shots')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  testWidgets('capture rename editor and context menu', (tester) async {
    final m = WorkbenchModel()..demo();
    final first = m.focus!.files.firstWhere((f) => !f.folder);
    await mount(tester, m);

    // Rename editor open on the first file.
    await tester.tap(find.text(first.name).first);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('inline-rename')),
      findsOneWidget,
      reason: 'editor open before capture',
    );
    await savePng(tester, 'rename-editor');

    // Escape, then open the context menu on the same row.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(first.name).first,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await savePng(tester, 'context-menu');
    expect(find.byTooltip('复制'), findsOneWidget);
    expect(find.text('属性'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
    m.dispose();
  });
}
