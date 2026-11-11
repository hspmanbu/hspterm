import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/explorer_drag_handoff.dart';

void main() {
  testWidgets(
    'ordinary drag keeps Flutter targets without admitting native export',
    (tester) async {
      var external = 0, internal = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExplorerDragHandoff<int>(
                  enabled: true,
                  capture: (_) => 7,
                  onLeave: (_, _) async {
                    external++;
                  },
                  child: const Draggable<int>(
                    data: 7,
                    feedback: SizedBox.shrink(),
                    child: ColoredBox(
                      color: Colors.transparent,
                      child: SizedBox(width: 100, height: 100),
                    ),
                  ),
                ),
                DragTarget<int>(
                  onAcceptWithDetails: (details) {
                    internal = details.data;
                  },
                  builder: (_, _, _) => const SizedBox(width: 200, height: 200),
                ),
              ],
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        const Offset(40, 40),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(const Offset(180, 40));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(internal, 7);
      expect(external, 0);
    },
  );
  testWidgets(
    'first edge crossing freezes source and cancels preparation on release',
    (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final pending = Completer<void>();
      final selected = ['original'];
      late ExplorerDragLease lease;
      List<String>? received;
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExplorerDragHandoff<List<String>>(
              enabled: true,
              capture: (value) {
                lease = value;
                return List.of(selected);
              },
              onLeave: (snapshot, _) async {
                calls++;
                received = snapshot;
                await pending.future;
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        const Offset(30, 30),
        kind: PointerDeviceKind.mouse,
      );
      selected[0] = 'different';
      await gesture.moveTo(const Offset(420, 40));
      await tester.pump();
      await gesture.moveTo(const Offset(450, 50));
      expect(calls, 1);
      expect(received, ['original']);
      await gesture.up();
      expect(lease.released, true);
      pending.complete();
      await tester.pumpAndSettle();
    },
  );
  testWidgets('native handoff survives pointer cancel and view disposal', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late ExplorerDragLease lease;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExplorerDragHandoff<ExplorerDragLease>(
            enabled: true,
            capture: (value) {
              lease = value;
              return value;
            },
            onLeave: (value, _) async {
              value.handedOff = true;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      const Offset(30, 30),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(const Offset(420, 40));
    await gesture.cancel();
    await tester.pumpWidget(const SizedBox());
    expect(lease.handedOff, true);
    expect(lease.released, false);
  });
}
