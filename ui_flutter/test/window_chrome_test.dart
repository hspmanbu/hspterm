import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/prototype/tabs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/window_chrome.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows maximize region reports scaled physical client bounds once and clears on disposal',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(1200, 800);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        const channel = MethodChannel('hspterm/prototype_window');
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                Positioned(
                  left: 20,
                  top: 10,
                  child: NativeMaximizeRegion(
                    child: SizedBox(width: 40, height: 30),
                  ),
                ),
              ],
            ),
          ),
        );
        await tester.pump();
        expect(calls.single.method, 'maximizeRect');
        expect(calls.single.arguments, [40.0, 20.0, 120.0, 80.0]);
        await tester.pump();
        expect(calls.length, 1);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(calls.last.arguments, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  testWidgets(
    'Ubuntu keeps existing native window behavior without Windows region calls',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        const channel = MethodChannel('hspterm/prototype_window');
        var calls = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (_) async {
            calls++;
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: NativeMaximizeRegion(child: SizedBox(width: 40, height: 30)),
          ),
        );
        await tester.pump();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(calls, 0);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  testWidgets(
    'caption drag, double click and Windows system menu route distinct actions',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final actions = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowDragRegion(
                onAction: (action) async {
                  actions.add(action);
                },
                child: const SizedBox(width: 300, height: 43),
              ),
            ),
          ),
        );
        final region = find.byType(WindowDragRegion);
        await tester.drag(region, const Offset(50, 0));
        await tester.pumpAndSettle();
        expect(actions, ['drag']);
        actions.clear();
        await tester.tap(region);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(region);
        await tester.pumpAndSettle();
        expect(actions, ['maximize']);
        actions.clear();
        await tester.tap(region, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        expect(actions, ['systemMenu']);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'empty top strip is draggable while terminal tab gestures retain session identity',
    (tester) async {
      final model = WorkbenchModel();
      model.openHost(model.hosts.first);
      addTearDown(model.dispose);
      final session = model.sessions.single;
      final tab = model.tabs.single;
      final actions = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 750,
              height: 43,
              child: TerminalTabStrip(
                model: model,
                group: model.layoutGroups.single,
                onWindowAction: (action) async {
                  actions.add(action);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final empty = find.byType(WindowDragRegion);
      expect(empty, findsOneWidget);
      final drag = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('tab-${tab.id}'))),
      );
      await drag.moveBy(const Offset(0, 20));
      await tester.pump();
      await drag.moveTo(tester.getCenter(empty));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(actions, isEmpty);
      expect(model.sessions.single, same(session));
      expect(model.tabs.single, same(tab));
      await tester.drag(empty, const Offset(35, 0));
      await tester.pumpAndSettle();
      expect(actions, ['drag']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('split area strips have no window caption gestures', (
    tester,
  ) async {
    final model = WorkbenchModel();
    model.openHost(model.hosts.first);
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 750,
            height: 43,
            child: TerminalTabStrip(
              model: model,
              group: model.layoutGroups.single,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(WindowDragRegion), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
