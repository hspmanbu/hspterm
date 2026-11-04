import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/terminal_preferences.dart';

TerminalPreferencesSnapshot fixture() => TerminalPreferencesSnapshot(
  'fixture-scope',
  'a' * 64,
  TerminalPreferencesValue(
    historyLines: 100000,
    shape: 'block',
    blink: false,
    osc52: true,
    rightPaste: false,
    foreground: 0xd8dee9,
    background: 0x10151d,
    cursor: 0xd8dee9,
    ansi: TerminalPreferencesValue.dark,
  ),
);

class PreferencesTestGateway implements TerminalPreferencesGateway {
  TerminalPreferencesSnapshot? initial;
  int saves = 0;
  Object? error;
  Object? loadError;
  TerminalPreferencesValue? received;
  @override
  Future<TerminalPreferencesSnapshot> load() async {
    if (loadError != null) throw loadError!;
    return initial ?? fixture();
  }

  @override
  Future<TerminalPreferencesSnapshot> save(
    TerminalPreferencesSnapshot source,
    TerminalPreferencesValue value,
  ) async {
    saves++;
    received = value;
    if (error != null) throw error!;
    return TerminalPreferencesSnapshot(source.scope, 'b' * 64, value);
  }
}

Future<void> mount(WidgetTester tester, PreferencesTestGateway gateway) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TerminalPreferencesPanel(gateway: gateway),
        ),
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
  test('portable geometry is immutable and rejects local font mapping or invalid dimensions', () {
    final raw = fixture().value.toJson();
    raw['typography'] = {
      'size': 19.5,
      'line_height': 1.6,
      'padding': 7.0,
      'ligatures': true,
      'builtin_family': 'JetBrainsMonoNerd',
    };
    final parsed = TerminalPreferencesValue.parse(raw);
    expect(parsed.toJson()['typography'], raw['typography']);
    expect(() => parsed.typography!['size'] = 20, throwsUnsupportedError);
    expect(
      () => TerminalPreferencesValue.parse({
        ...raw,
        'typography': {
          ...raw['typography'] as Map<String, dynamic>,
          'builtin_family': 'private-local-font',
        },
      }),
      throwsFormatException,
    );
    expect(
      () => TerminalPreferencesValue.parse({
        ...raw,
        'typography': {
          ...raw['typography'] as Map<String, dynamic>,
          'family': 'private-local-font',
        },
      }),
      throwsFormatException,
    );
    expect(
      () => TerminalPreferencesValue.parse({
        ...raw,
        'typography': {
          ...raw['typography'] as Map<String, dynamic>,
          'size': double.nan,
        },
      }),
      throwsFormatException,
    );
  });
  testWidgets(
    'saving cursor or clipboard preferences preserves shared typography from the original snapshot',
    (tester) async {
      final raw = fixture().value.toJson();
      raw['typography'] = {
        'size': 19.5,
        'line_height': 1.6,
        'padding': 7.0,
        'ligatures': true,
      };
      final gateway = PreferencesTestGateway()
        ..initial = TerminalPreferencesSnapshot(
          'fixture-scope',
          'a' * 64,
          TerminalPreferencesValue.parse(raw),
        );
      await mount(tester, gateway);
      await tap(tester, 'terminal-osc52');
      await tap(tester, 'terminal-preferences-save');
      await tap(tester, 'terminal-preferences-confirm');
      expect(gateway.saves, 1);
      expect(gateway.received!.osc52, false);
      expect(gateway.received!.typography, raw['typography']);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('preference parser rejects unknown fields, invalid palette and unsupported values', () {
    final value = fixture().value.toJson();
    value['future'] = true;
    expect(() => TerminalPreferencesValue.parse(value), throwsFormatException);
    final palette = fixture().value.toJson();
    (palette['colors'] as Map)['ansi'] = [0];
    expect(
      () => TerminalPreferencesValue.parse(palette),
      throwsFormatException,
    );
    final range = fixture().value.toJson();
    range['history_lines'] = 1000001;
    expect(() => TerminalPreferencesValue.parse(range), throwsFormatException);
  });
  testWidgets(
    'explicit preview, cancellation and invalid history cannot save defaults',
    (tester) async {
      final gateway = PreferencesTestGateway();
      await mount(tester, gateway);
      await tap(tester, 'terminal-osc52');
      await tap(tester, 'terminal-preferences-save');
      expect(gateway.saves, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(gateway.saves, 0);
      await tester.enterText(
        find.byKey(const ValueKey('terminal-history-limit')),
        '-1',
      );
      await tap(tester, 'terminal-preferences-save');
      expect(gateway.saves, 0);
      await tester.enterText(
        find.byKey(const ValueKey('terminal-history-limit')),
        '25000',
      );
      await tap(tester, 'terminal-preferences-save');
      await tap(tester, 'terminal-preferences-confirm');
      expect(gateway.saves, 1);
      expect(gateway.received!.osc52, false);
      expect(gateway.received!.historyLines, 25000);
      expect(find.textContaining('已加密保存'), findsOneWidget);
    },
  );
  testWidgets(
    'unknown loaded state cannot overwrite; saved ACK with malformed reply requires reload',
    (tester) async {
      final gateway = PreferencesTestGateway()
        ..loadError = StateError('synthetic bad version');
      await mount(tester, gateway);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('terminal-preferences-save')),
            )
            .onPressed,
        isNull,
      );
      gateway.loadError = null;
      await tap(tester, 'terminal-preferences-reload');
      await tap(tester, 'terminal-right-paste');
      gateway.error = const TerminalPreferencesAckFailure();
      await tap(tester, 'terminal-preferences-save');
      await tap(tester, 'terminal-preferences-confirm');
      expect(gateway.saves, 1);
      expect(find.text('原设置已保存'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('terminal-preferences-save')),
            )
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets(
    'light palette and custom RGB preserve unrelated defaults at compact width',
    (tester) async {
      tester.view.physicalSize = const Size(720, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final g = PreferencesTestGateway();
      await mount(tester, g);
      final light = find.text('浅色配色预设');
      await tester.ensureVisible(light);
      await tester.tap(light);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('terminal-color-2')),
        '123456',
      );
      await tap(tester, 'terminal-preferences-save');
      await tap(tester, 'terminal-preferences-confirm');
      expect(g.received!.background, 0xf6f8fb);
      expect(g.received!.cursor, 0x123456);
      expect(g.received!.historyLines, 100000);
      expect(g.received!.osc52, true);
      expect(tester.takeException(), isNull);
    },
  );
}
