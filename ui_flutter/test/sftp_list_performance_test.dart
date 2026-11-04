import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/design.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

/// Count deterministic work rather than asserting timings on a shared machine.
class CountedFile extends DemoFile {
  CountedFile(super.id, super.name);
  static int reads = 0;
  @override
  String get name {
    reads++;
    return super.name;
  }
}

void main() {
  testWidgets(
    'large SFTP listing sorts once and scrolling only builds visible rows',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 720);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final m = WorkbenchModel()..demo();
      final session = m.focus!;
      const count = 4096;
      final files = List.generate(count, (i) {
        final name = 'file-${(count - i).toString().padLeft(6, '0')}.txt';
        return CountedFile('/fixture/$name', name);
      });
      session.directories[session.path] = files;
      Widget app() => MaterialApp(
        theme: Desk.theme(false),
        home: Scaffold(
          body: FilesPanel(model: m, pane: session),
        ),
      );
      CountedFile.reads = 0;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final initialReads = CountedFile.reads;
      // ignore: avoid_print
      print('SFTP 4096-entry initial name reads: $initialReads');
      expect(initialReads, lessThan(count * 150));
      expect(find.text('file-004096.txt'), findsNothing);
      expect(find.byType(Text).evaluate().length, lessThan(250));
      CountedFile.reads = 0;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(ListView)),
          scrollDelta: const Offset(0, 600),
        ),
      );
      await tester.pumpAndSettle();
      // ignore: avoid_print
      print('SFTP 4096-entry scroll name reads: ${CountedFile.reads}');
      expect(CountedFile.reads, lessThan(count * 2));
      await tester.tap(find.byTooltip('筛选文件'));
      await tester.pumpAndSettle();
      final filter = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '筛选当前目录',
      );
      await tester.enterText(filter, 'file-000001');
      await tester.pumpAndSettle();
      expect(find.text('1 项'), findsOneWidget);
      expect(find.text('file-000001.txt'), findsOneWidget);
      await tester.enterText(filter, '');
      await tester.pumpAndSettle();
      files.last.name = 'AAA changed.txt';
      await tester.pumpWidget(app());
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      scrollable.position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('AAA changed.txt'), findsOneWidget);
      await tester.tap(find.text('AAA changed.txt'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 1'), findsOneWidget);
      files.removeLast();
      session.directories[session.path] = [
        ...files,
        DemoFile('/fixture/replacement', 'AAA replacement.txt'),
      ];
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 1'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
}
