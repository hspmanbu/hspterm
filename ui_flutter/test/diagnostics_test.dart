import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/runtime_errors.dart';
import 'package:hspterm/prototype/app.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/diagnostics.dart';
import 'package:hspterm/workbench/diagnostics.dart';

class DiagnosticsTestGateway implements DiagnosticsGateway {
  int loads = 0, clears = 0;
  bool failed = false, refreshAfterClearFails = false;
  DiagnosticSnapshot current = DiagnosticSnapshot(
    capacity: 1000,
    dropped: 3,
    events: [
      const DiagnosticEvent(
        sequence: 1,
        elapsedMs: 20,
        terminalId: 2,
        generation: 1,
        code: DiagnosticCode.stateConnected,
      ),
      const DiagnosticEvent(
        sequence: 2,
        elapsedMs: 30,
        terminalId: 3,
        generation: 2,
        code: DiagnosticCode.connectionRejected,
      ),
      const DiagnosticEvent(
        sequence: 3,
        elapsedMs: 40,
        terminalId: null,
        generation: null,
        code: DiagnosticCode.vaultOpened,
      ),
    ],
  );
  @override
  Future<DiagnosticSnapshot> load() async {
    loads++;
    if (failed || (clears > 0 && refreshAfterClearFails)) {
      throw StateError('synthetic unavailable');
    }
    return current;
  }

  @override
  Future<void> clear() async {
    clears++;
    current = const DiagnosticSnapshot(capacity: 1000, dropped: 0, events: []);
  }
}

Future<void> mount(WidgetTester tester, DiagnosticsTestGateway gateway) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: DiagnosticsPanel(gateway: gateway)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'fixed UI faults are read only on explicit refresh and clear with diagnostics',
    (tester) async {
      RuntimeFaults.instance.clear();
      final gateway = DiagnosticsTestGateway();
      try {
        await mount(tester, gateway);
        RuntimeFaults.instance.record(RuntimeFault.asynchronous);
        await tester.pump(const Duration(seconds: 30));
        expect(gateway.loads, 1);
        expect(
          find.byKey(const ValueKey('diagnostics-runtime-faults')),
          findsNothing,
        );
        await tap(tester, 'diagnostics-refresh');
        expect(find.textContaining('未获处理的异步异常：1'), findsOneWidget);
        await tap(tester, 'diagnostics-clear');
        await tap(tester, 'diagnostics-confirm-clear');
        expect(RuntimeFaults.instance.counts, isEmpty);
        expect(gateway.clears, 1);
        expect(
          find.byKey(const ValueKey('diagnostics-runtime-faults')),
          findsNothing,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        RuntimeFaults.instance.clear();
      }
    },
  );

  testWidgets(
    'formal diagnostics builder is reached through the real settings category',
    (tester) async {
      final model = WorkbenchModel()..show(WorkPage.settings);
      final gateway = DiagnosticsTestGateway();
      await tester.pumpWidget(
        PrototypeApp(
          model: model,
          diagnosticsBuilder: (_) => DiagnosticsPanel(gateway: gateway),
        ),
      );
      await tester.pumpAndSettle();
      expect(gateway.loads, 0);
      await tester.ensureVisible(find.text('运行诊断'));
      await tester.tap(find.text('运行诊断'));
      await tester.pumpAndSettle();
      expect(gateway.loads, 1);
      expect(find.text('本次运行诊断 · 仅内存'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'read once, filter locally and leave idle without native polling',
    (tester) async {
      final g = DiagnosticsTestGateway();
      await mount(tester, g);
      expect(g.loads, 1);
      expect(find.text('已观察：已连接'), findsOneWidget);
      await tap(tester, 'diagnostics-errors');
      expect(find.text('连接请求未成功'), findsOneWidget);
      expect(find.text('已观察：已连接'), findsNothing);
      expect(g.loads, 1);
      await tester.pump(const Duration(minutes: 5));
      expect(g.loads, 1);
      expect(tester.binding.hasScheduledFrame, false);
      await tap(tester, 'diagnostics-refresh');
      expect(g.loads, 2);
    },
  );
  testWidgets('clear is explicit and ACK is separate from subsequent refresh', (
    tester,
  ) async {
    final g = DiagnosticsTestGateway();
    await mount(tester, g);
    await tap(tester, 'diagnostics-clear');
    expect(g.clears, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(g.clears, 0);
    g.refreshAfterClearFails = true;
    await tap(tester, 'diagnostics-clear');
    await tap(tester, 'diagnostics-confirm-clear');
    expect(g.clears, 1);
    expect(find.text('本次运行诊断已清空。'), findsOneWidget);
    expect(find.textContaining('已清空诊断，但刷新失败'), findsOneWidget);
    expect(find.text('已观察：已连接'), findsNothing);
  });
  testWidgets(
    'load failure is explicit, capacity is bounded and compact layout remains scrollable',
    (tester) async {
      tester.view.physicalSize = const Size(720, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final g = DiagnosticsTestGateway()..failed = true;
      await mount(tester, g);
      expect(find.textContaining('未读取最新诊断'), findsOneWidget);
      g.failed = false;
      g.current = DiagnosticSnapshot(
        capacity: 1000,
        dropped: 0,
        events: List.generate(
          1000,
          (i) => DiagnosticEvent(
            sequence: i + 1,
            elapsedMs: i,
            terminalId: i % 3,
            generation: 1,
            code: DiagnosticCode.stateConnected,
          ),
        ),
      );
      await tap(tester, 'diagnostics-refresh');
      expect(find.textContaining('当前 1000 / 1000'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.byType(ListTile).evaluate().length, lessThan(1000));
    },
  );
}
