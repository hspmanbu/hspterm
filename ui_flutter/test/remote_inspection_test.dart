import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/workbench/remote_inspection.dart';
import 'package:hspterm/workbench/remote_inspection_panel.dart';

import 'support/fake_backend.dart';
import 'support/terminal_cleanup.dart';

String _sample({
  int millis = 1000,
  int total = 100,
  int idle = 20,
  String? boot,
}) => jsonEncode({
  'version': 1,
  'boot': boot ?? '01234567-89ab-cdef-0123-456789abcdef',
  'millis': millis,
  'cpu_total': total,
  'cpu_idle': idle,
  'memory_total': 1024,
  'memory_available': 256,
  'disk_total': 2048,
  'disk_available': 512,
  'rx': total * 1024,
  'tx': total * 512,
});
String _processes() => jsonEncode({
  'version': 1,
  'boot': '01234567-89ab-cdef-0123-456789abcdef',
  'revision': '1-1',
  'processes': [
    {
      'pid': 123,
      'name': 'synthetic-task',
      'state': 'S',
      'start': 55,
      'ticks': 7,
      'rss': 4096,
      'uid': 1000,
    },
  ],
  'truncated': false,
  'skipped': 0,
  'can_signal': true,
});

class _Gateway implements RemoteInspectionGateway {
  final configurations = <(int, int, bool, bool)>[];
  int samples = 0, lists = 0, signals = 0;
  Completer<String>? waiting;
  bool failSignal = false;
  @override
  Future<void> configure(
    InspectionSource s,
    bool metrics,
    bool processes,
  ) async {
    configurations.add((s.id, s.generation, metrics, processes));
  }

  @override
  Future<String> sample(InspectionSource s) async {
    samples++;
    return waiting?.future ?? _sample();
  }

  @override
  Future<String> processes(InspectionSource s) async {
    lists++;
    return _processes();
  }

  @override
  Future<void> terminate(InspectionSource s, String revision, int pid) async {
    expect(revision, '1-1');
    expect(pid, 123);
    signals++;
    if (failSignal) throw StateError('synthetic unknown response');
  }
}

Future<(TerminalController, RemoteInspectionController, _Gateway)>
_fixture() async {
  final terminal = TerminalController(FakeBackend());
  await terminal.start();
  terminal.phase = 'Connected';
  terminal.generation = 7;
  final gateway = _Gateway();
  return (
    terminal,
    RemoteInspectionController(terminal, gateway: gateway),
    gateway,
  );
}

Future<void> _close(
  WidgetTester tester,
  TerminalController terminal,
  RemoteInspectionController c,
) async {
  await c.shutdown();
  c.dispose();
  await closeTerminal(tester, terminal);
}

void main() {
  testWidgets(
    'shutdown revokes first and waits for the actual in-flight request',
    (tester) async {
      final (terminal, c, g) = await _fixture();
      await c.configure(metrics: true, processes: false);
      g.waiting = Completer<String>();
      final work = c.refreshMetrics();
      await tester.pump();
      var closed = false;
      final closing = c.shutdown().then((_) => closed = true);
      await tester.pump();
      expect(g.configurations.last, (terminal.id, 7, false, false));
      expect(closed, false);
      g.waiting!.complete(_sample());
      await work;
      await closing;
      expect(c.summary, isNull);
      c.dispose();
      await closeTerminal(tester, terminal);
    },
  );
  test('adjacent monotonic samples calculate rates and refuse boot changes, resets and stale intervals', () {
    final a = RemoteResourceSample.parse(_sample());
    final b = RemoteResourceSample.parse(
      _sample(millis: 6000, total: 200, idle: 40),
    );
    final summary = RemoteResourceSummary(b, a);
    expect(summary.cpu, 80);
    expect(summary.rxPerSecond, 20480);
    expect(
      RemoteResourceSummary(
        RemoteResourceSample.parse(_sample(millis: 50000)),
        a,
      ).cpu,
      isNull,
    );
    expect(
      RemoteResourceSummary(
        RemoteResourceSample.parse(_sample(millis: 6000, total: 50, idle: 10)),
        a,
      ).cpu,
      isNull,
    );
    expect(
      RemoteResourceSummary(
        RemoteResourceSample.parse(
          _sample(millis: 6000, boot: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
        ),
        a,
      ).cpu,
      isNull,
    );
    expect(
      () => RemoteResourceSample.parse(_sample(total: 1, idle: 2)),
      throwsFormatException,
    );
  });
  testWidgets(
    'no startup request or timer; only enabled focused sampling runs and leaving focus stops it',
    (tester) async {
      final (terminal, c, g) = await _fixture();
      c.setActive(true);
      await tester.pump(const Duration(seconds: 20));
      expect(g.samples, 0);
      expect(g.configurations, isEmpty);
      c.setActive(false);
      await c.configure(metrics: true, processes: false);
      await tester.pump(const Duration(seconds: 20));
      expect(g.samples, 0);
      c.setActive(true);
      // Explicitly advance the fake event clock: a duration-less pump only
      // drains microtasks and does not execute the zero-delay sampling timer.
      await tester.pump(Duration.zero);
      await tester.pump();
      expect(g.samples, 1);
      expect(c.summary, isNotNull);
      c.setActive(false);
      await tester.pump(const Duration(seconds: 20));
      expect(g.samples, 1);
      expect((terminal.backend as FakeBackend).texts, isEmpty);
      await _close(tester, terminal, c);
    },
  );
  testWidgets(
    'revocation cancels publication of a late sample without waiting for that request to finish',
    (tester) async {
      final (terminal, c, g) = await _fixture();
      await c.configure(metrics: true, processes: false);
      g.waiting = Completer<String>();
      final work = c.refreshMetrics();
      await tester.pump();
      await c.configure(metrics: false, processes: false);
      expect(g.configurations.last, (terminal.id, 7, false, false));
      g.waiting!.complete(_sample());
      await work;
      expect(c.summary, isNull);
      expect(c.metrics, false);
      await _close(tester, terminal, c);
    },
  );
  testWidgets(
    'unknown signal consumes original list, cannot replay, and new generation clears all local consent',
    (tester) async {
      final (terminal, c, g) = await _fixture();
      await c.configure(metrics: false, processes: true);
      // compute performs real isolate work; let the test binding run it.
      await tester.runAsync(c.refreshProcesses);
      final list = c.processList!;
      g.failSignal = true;
      await expectLater(
        c.terminate(list, list.processes.single),
        throwsStateError,
      );
      expect(c.processList, isNull);
      expect(c.result, contains('可能已经发送'));
      await expectLater(
        c.terminate(list, list.processes.single),
        throwsStateError,
      );
      expect(g.signals, 1);
      terminal.generation = 8;
      terminal.report(StateError('synthetic lifecycle change'));
      expect(c.processesAllowed, false);
      await _close(tester, terminal, c);
    },
  );
  testWidgets(
    'small scaled consent dialog stays scrollable and closing never starts a probe',
    (tester) async {
      tester.view.physicalSize = const Size(720, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final (terminal, c, g) = await _fixture();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: Scaffold(
                body: Center(
                  child: RemoteInspectionPanel(
                    controller: c,
                    label: 'Synthetic host',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(g.configurations, isEmpty);
      expect(g.samples, 0);
      expect(g.lists, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await _close(tester, terminal, c);
    },
  );
  testWidgets(
    'process action requires separate explicit confirmation and cancel sends no signal',
    (tester) async {
      final (terminal, c, g) = await _fixture();
      await c.configure(metrics: false, processes: true);
      await tester.runAsync(c.refreshProcesses);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemoteInspectionPanel(controller: c, label: 'Synthetic host'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final end = find.text('结束…');
      await tester.ensureVisible(end);
      await tester.tap(end);
      await tester.pumpAndSettle();
      expect(g.signals, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(g.signals, 0);
      await tester.ensureVisible(end);
      await tester.tap(end);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remote-process-confirm')));
      await tester.pumpAndSettle();
      expect(g.signals, 1);
      expect(c.result, contains('不代表进程已退出'));
      await tester.pumpWidget(const SizedBox());
      await _close(tester, terminal, c);
    },
  );
}
