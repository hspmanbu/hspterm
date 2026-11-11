import 'dart:convert';

import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/remote_inspection.dart';

import 'transfer_connection_selection_test.dart' show session;
import 'support/terminal_cleanup.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/workbench/connection_status.dart';

import 'support/fake_backend.dart';

class _StatusModel extends LiveWorkbenchModel {
  _StatusModel(this.source);
  final LiveTerminalSession source;
  @override
  LiveTerminalSession get focus => source;
}

void main() {
  testWidgets(
    'resource metrics stay on the right and scroll instead of ellipsizing',
    (tester) async {
      final source = session('Fixture', 1, 4);
      final model = _StatusModel(source);
      source.inspection.metrics = true;
      source.inspection.summary = RemoteResourceSummary(
        RemoteResourceSample.parse(
          jsonEncode({
            'version': 1,
            'boot': '01234567-89ab-cdef-0123-456789abcdef',
            'millis': 1000,
            'cpu_total': 100,
            'cpu_idle': 20,
            'memory_total': 1024,
            'memory_available': 256,
            'disk_total': 2048,
            'disk_available': 512,
            'rx': 1024,
            'tx': 512,
          }),
        ),
        null,
      );
      try {
        for (final width in [760.0, 420.0]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: width,
                  height: 34,
                  child: WorkbenchConnectionStatus(model: model),
                ),
              ),
            ),
          );
          await tester.pump();
          final resource = find.descendant(
            of: find.byKey(const ValueKey('remote-inspection-status')),
            matching: find.byType(SingleChildScrollView),
          );
          expect(resource, findsOneWidget);
          expect(
            tester.getRect(resource).right,
            closeTo(
              tester.getRect(find.byType(WorkbenchConnectionStatus)).right,
              1,
            ),
          );
          expect(find.textContaining('内存 75%'), findsOneWidget);
          final connection = tester.widget<Text>(
            find.byKey(const ValueKey('workbench-connection-status')),
          );
          expect(connection.overflow, isNot(TextOverflow.ellipsis));
          expect(tester.takeException(), isNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await drainAsync(tester, model.shutdown());
        model.dispose();
        await closeTerminal(tester, source.controller);
        source.disposeInspection();
      }
    },
  );

  test('RTT is explicit about unknown samples and PTY dimensions come from accepted frames', () {
    expect(
      terminalTransportSummary((
        rttMicros: null,
        columns: null,
        rows: null,
        sizeLocked: null,
      )),
      'RTT — · PTY —',
    );
    expect(
      terminalTransportSummary((
        rttMicros: 1250,
        columns: 132,
        rows: 42,
        sizeLocked: true,
      )),
      'RTT 1.250 ms · PTY 132 × 42（固定）',
    );
  });
  testWidgets(
    'latency updates neither repaint terminal listeners nor pull frames; old generation ignored and disconnect clears sample',
    (tester) async {
      late FakeBackend b;
      late TerminalController c;
      await tester.runAsync(() async {
        b = FakeBackend();
        c = TerminalController(b);
        await c.start();
      });
      c.phase = 'Connected';
      c.generation = 7;
      var terminalNotifications = 0, metricsNotifications = 0;
      c.addListener(() => terminalNotifications++);
      c.transportInfo.addListener(() => metricsNotifications++);
      try {
        c.applyFrame(fixture());
        terminalNotifications = 0;
        metricsNotifications = 0;
        final frames = b.frames;
        b.events.add(
          const rust.BridgeEvent(
            kind: 'latency',
            generation: 7,
            requestId: 0,
            rttMicros: 1500,
          ),
        );
        await tester.pump();
        expect(c.transportInfo.value.rttMicros, 1500);
        expect(metricsNotifications, 1);
        expect(terminalNotifications, 0);
        expect(b.frames, frames);
        b.events.add(
          const rust.BridgeEvent(
            kind: 'latency',
            generation: 7,
            requestId: 0,
            rttMicros: 1500,
          ),
        );
        await tester.pump();
        expect(metricsNotifications, 1);
        b.events.add(
          const rust.BridgeEvent(
            kind: 'latency',
            generation: 6,
            requestId: 0,
            rttMicros: 999999,
          ),
        );
        await tester.pump();
        expect(c.transportInfo.value.rttMicros, 1500);
        b.events.add(
          const rust.BridgeEvent(
            kind: 'status',
            generation: 7,
            requestId: 0,
            text: 'Disconnected',
          ),
        );
        await tester.pump();
        expect(c.transportInfo.value.rttMicros, isNull);
        expect(c.transportInfo.value.columns, c.metadata!.columns);
        expect(c.transportInfo.value.rows, c.metadata!.rows);
      } finally {
        await tester.runAsync(() async {
          await c.shutdown();
          c.dispose();
        });
      }
    },
  );
  testWidgets(
    'accepted unchanged dimensions do not invalidate status metrics and compact scaled text stays within its row',
    (tester) async {
      late FakeBackend b;
      late TerminalController c;
      await tester.runAsync(() async {
        b = FakeBackend();
        c = TerminalController(b);
        await c.start();
      });
      try {
        c.applyFrame(fixture());
        var changes = 0;
        c.transportInfo.addListener(() => changes++);
        c.applyFrame(fixture(line: 'other!'));
        expect(changes, 0);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
                child: Row(
                  children: [
                    const Text('HSPTerm'),
                    Expanded(
                      child: ValueListenableBuilder<TerminalTransportInfo>(
                        valueListenable: c.transportInfo,
                        builder: (context, value, _) => Text(
                          terminalTransportSummary(value),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        await tester.runAsync(() async {
          await c.shutdown();
          c.dispose();
        });
      }
    },
  );
}
