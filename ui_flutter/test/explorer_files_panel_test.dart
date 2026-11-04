import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/platform/explorer_drop.dart';
import 'package:hspterm/prototype/files.dart';
import 'package:hspterm/prototype/model.dart';

import 'explorer_drop_test.dart' show ExplorerNativeFixture;

/// UI routing only. Real SFTP/FIFO/bytes are covered by Native transfer fixtures.
class RoutingModel extends WorkbenchModel {
  @override
  bool get isMock => false;
  final accepted = <(TerminalSession, String, String, int?)>[];
  bool changeGenerationAfterFirst = false;
  Completer<void>? firstPending;
  @override
  Future<String> enqueueFileTransfer(
    TerminalSession session,
    String local,
    String remote,
    bool upload, {
    int? expectedGeneration,
  }) async {
    expect(upload, true);
    accepted.add((session, local, remote, expectedGeneration));
    if (accepted.length == 1 && firstPending != null) {
      await firstPending!.future;
    }
    if (changeGenerationAfterFirst) {
      session.connectionGeneration++;
      changed();
    }
    return 'synthetic-${accepted.length}';
  }
}

Future<void> page(WidgetTester tester, RoutingModel model) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: AnimatedBuilder(
        animation: model,
        builder: (_, _) => SizedBox(
          width: 600,
          child: FilesPanel(model: model, pane: model.focus!),
        ),
      ),
    ),
  ),
);

void windowsTest(String name, WidgetTesterCallback body) {
  testWidgets(name, (tester) async {
    final original = debugDefaultTargetPlatformOverride;
    try {
      await body(tester);
    } finally {
      // Retire this view and drain channel work inside its own fake zone before
      // restoring the platform and before Flutter verifies global invariants.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      debugDefaultTargetPlatformOverride = original;
    }
  });
}

void main() {
  windowsTest(
    'accepted Explorer batch survives sidebar unmount and keeps its frozen destination',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final native = ExplorerNativeFixture()..install(tester);
      final model = RoutingModel()..demo();
      final source = model.focus!..disconnected = false;
      final directory = source.path;
      model.firstPending = Completer<void>();
      await page(tester, model);
      await tester.pumpAndSettle();
      final region = tester.getRect(find.byType(ExplorerFileDropRegion));
      final header =
          Offset(region.left + 5, region.top + 5) *
          tester.view.devicePixelRatio;
      await native.send(
        tester,
        native.event(
          'drop',
          paths: [r'C:\one', r'C:\two', r'C:\three'],
          physical: header,
        ),
      );
      expect(model.accepted, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      source.navigate('/different-view');
      model.firstPending!.complete();
      await tester.pump();
      expect(model.accepted.map((e) => e.$3), [
        '$directory/one',
        '$directory/two',
        '$directory/three',
      ]);
      expect(source.entered, isEmpty);
      model.dispose();
    },
  );
  windowsTest(
    'Explorer folder target routes each frozen local path to the original generation without terminal input',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final native = ExplorerNativeFixture()..install(tester);
      final model = RoutingModel()..demo();
      final source = model.focus!..disconnected = false;
      await page(tester, model);
      await tester.pumpAndSettle();
      final folder = source.files.firstWhere((f) => f.folder);
      final center =
          tester.getCenter(find.byKey(ValueKey('file-${folder.name}'))) *
          tester.view.devicePixelRatio;
      final generation = source.connectionGeneration;
      await native.send(
        tester,
        native.event('hover', sequence: 1, physical: center),
      );
      await native.send(
        tester,
        native.event(
          'drop',
          physical: center,
          paths: [r'C:\local\a b.txt', r'C:\local\bundle'],
        ),
      );
      await tester.pump();
      expect(model.accepted.map((e) => e.$1), everyElement(same(source)));
      expect(model.accepted.map((e) => e.$3), [
        '${source.path}/${folder.name}/a b.txt',
        '${source.path}/${folder.name}/bundle',
      ]);
      expect(model.accepted.map((e) => e.$4), everyElement(generation));
      expect(source.entered, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      model.dispose();
    },
  );

  windowsTest(
    'Explorer hover enters a folder only after delay and reconnect stops the remaining upload batch',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final native = ExplorerNativeFixture()..install(tester);
      final model = RoutingModel()..demo();
      final source = model.focus!..disconnected = false;
      await page(tester, model);
      await tester.pumpAndSettle();
      final original = source.path;
      final folder = source.files.firstWhere((f) => f.folder);
      final center =
          tester.getCenter(find.byKey(ValueKey('file-${folder.name}'))) *
          tester.view.devicePixelRatio;
      await native.send(
        tester,
        native.event('hover', sequence: 2, physical: center),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(source.path, original);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pumpAndSettle();
      expect(source.path, '$original/${folder.name}');
      expect(model.accepted, isEmpty);
      model.changeGenerationAfterFirst = true;
      final region = tester.getRect(find.byType(ExplorerFileDropRegion));
      // The list header is a current-directory drop target, away from a folder.
      final empty =
          Offset(region.left + 5, region.top + 5) *
          tester.view.devicePixelRatio;
      await native.send(
        tester,
        native.event(
          'drop',
          drag: 2,
          physical: empty,
          paths: [r'C:\one', r'C:\two', r'C:\three'],
        ),
      );
      await tester.pump();
      expect(model.accepted, hasLength(1));
      expect(find.textContaining('另有 2 项未确认入队'), findsOneWidget);
      expect(source.entered, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      model.dispose();
    },
  );
}
