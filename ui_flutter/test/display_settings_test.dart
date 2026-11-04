import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/display.dart';
import 'package:hspterm/workbench/display_settings.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/prototype/settings.dart';

DisplayConfig config({
  bool enabled = false,
  List<DisplayRule> rules = const [],
}) => DisplayConfig(
  enabled: enabled,
  semantic: false,
  rainbow: false,
  sameWord: false,
  sameWordCaseSensitive: true,
  allowInAlternateScreen: false,
  rules: rules,
);

class DisplayFixture implements DisplaySettingsGateway {
  bool fail = false;
  int writes = 0, tests = 0;
  DisplaySettingsView value = DisplaySettingsView(
    vaultScope: 'synthetic-scope',
    revision: 0,
    overrideConfig: null,
    effective: config(),
  );
  @override
  Future<List<rust.HostConfig>> hosts() async => [];
  @override
  Future<DisplaySettingsView> load(String? host) async {
    if (fail) throw StateError('synthetic read error');
    return value;
  }

  @override
  Future<DisplaySettingsView> save(
    String? host,
    String scope,
    int revision,
    DisplayConfig? next,
  ) async {
    writes++;
    return value = DisplaySettingsView(
      vaultScope: scope,
      revision: revision + 1,
      overrideConfig: next,
      effective: next ?? config(),
    );
  }

  @override
  Future<List<DisplayRuleMatch>> test(
    DisplayConfig config,
    String sample,
  ) async {
    tests++;
    return config.rules
        .map((r) => DisplayRuleMatch(id: r.id, count: 1))
        .toList();
  }

  @override
  Future<List<DisplayRule>> importRules(String source) async => [];
}

void main() {
  testWidgets(
    'formal display edits survive cancelled category navigation and stop prompting after save',
    (tester) async {
      final fixture = DisplayFixture();
      final model = WorkbenchModel();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              model: model,
              initialCategory: '彩色高亮',
              displaySettingsBuilder: (_) =>
                  DisplaySettingsPanel(gateway: fixture),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('display-enabled')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-快捷键')));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的设置？'), findsOneWidget);
      await tester.tap(find.text('返回编辑'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('display-enabled')),
            )
            .value,
        true,
      );
      expect(fixture.writes, 0);
      await tester.ensureVisible(find.byKey(const ValueKey('display-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('display-save')));
      await tester.pumpAndSettle();
      expect(fixture.writes, 1);
      await tester.tap(find.byKey(const ValueKey('settings-快捷键')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.byKey(const ValueKey('settings-content-快捷键')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'read failure cannot overwrite unknown settings; toggles only persist on explicit save',
    (tester) async {
      final fixture = DisplayFixture()..fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DisplaySettingsPanel(gateway: fixture),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('display-save'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      fixture.fail = false;
      await tester.tap(find.text('重新载入'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('display-enabled')));
      await tester.pumpAndSettle();
      expect(fixture.writes, 0);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(fixture.writes, 1);
      expect(fixture.value.effective.enabled, true);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'rule editor validates through Rust gateway without saving configuration or stealing terminal keys',
    (tester) async {
      final fixture = DisplayFixture();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DisplaySettingsPanel(gateway: fixture),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final add = find.byKey(const ValueKey('display-add-rule'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('display-rule-name')),
        'Failure',
      );
      await tester.enterText(
        find.byKey(const ValueKey('display-rule-pattern')),
        'ERROR',
      );
      final color = find.byKey(const ValueKey('display-rule-foreground'));
      await tester.ensureVisible(color);
      await tester.enterText(color, 'E57373');
      final accept = find.byKey(const ValueKey('display-rule-accept'));
      await tester.ensureVisible(accept);
      await tester.tap(accept);
      await tester.pumpAndSettle();
      expect(fixture.tests, 1);
      expect(fixture.writes, 0);
      expect(find.byType(DisplayRuleEditor), findsNothing);
      final save = find.byKey(const ValueKey('display-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(fixture.value.effective.rules.single.foreground, 0xffe57373);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow settings expose rule actions through a menu without overflowing or saving implicitly',
    (tester) async {
      tester.view.physicalSize = const Size(480, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = DisplayFixture();
      final c = config(
        rules: [
          const DisplayRule(
            id: 'narrow',
            name: '窄窗口规则',
            pattern: 'ERROR',
            regex: false,
            caseSensitive: true,
            enabled: true,
            forceColor: false,
            foreground: 0xffe57373,
            underline: false,
          ),
        ],
      );
      fixture.value = DisplaySettingsView(
        vaultScope: 'synthetic-scope',
        revision: 1,
        overrideConfig: c,
        effective: c,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DisplaySettingsPanel(gateway: fixture),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final menu = find.byKey(const ValueKey('display-rule-menu-narrow'));
      await tester.ensureVisible(menu);
      await tester.pumpAndSettle();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除规则'));
      await tester.pumpAndSettle();
      expect(find.text('窄窗口规则'), findsNothing);
      expect(fixture.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

// Compact settings use the same real action routes without reserving four icons.
