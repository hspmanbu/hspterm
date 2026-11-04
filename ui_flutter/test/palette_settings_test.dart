import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/shortcut_settings.dart';
import 'package:hspterm/workbench/model.dart' show PaletteShortcutSavedFailure;
import 'package:hspterm/workbench/palette_settings.dart';

PaletteShortcutView fixture() => const PaletteShortcutView(
  vaultScope: 'fixture-scope',
  revision: 'original',
  enabled: true,
  key: 'KeyP',
  modifiers: 5,
  applicationInTerminal: false,
);

class _Gateway implements PaletteSettingsGateway {
  PaletteShortcutView value = fixture();
  Object? loadError, saveError;
  bool savedFailure = false;
  final saved = <PaletteShortcutView>[];
  @override
  Future<PaletteShortcutView> load() async {
    if (loadError != null) throw loadError!;
    return value;
  }

  @override
  Future<PaletteShortcutView> save(PaletteShortcutView proposal) async {
    saved.add(proposal);
    if (saveError != null) throw saveError!;
    value = PaletteShortcutView(
      vaultScope: proposal.vaultScope,
      revision: 'saved',
      enabled: proposal.enabled,
      key: proposal.key,
      modifiers: proposal.modifiers,
      applicationInTerminal: proposal.applicationInTerminal,
    );
    if (savedFailure) throw PaletteShortcutSavedFailure(value);
    return value;
  }
}

Finder key(String name) => find.byKey(ValueKey(name));
Future<void> _mount(WidgetTester tester, _Gateway gateway) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PaletteSettingsPanel(gateway: gateway),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> confirm(WidgetTester tester) async {
  await tester.ensureVisible(key('palette-settings-save'));
  await tester.tap(key('palette-settings-save'));
  await tester.pumpAndSettle();
  await tester.tap(key('palette-confirm-save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'explicit preview freezes original scope and cancellation does not persist routing',
    (tester) async {
      final g = _Gateway();
      await _mount(tester, g);
      await tester.tap(key('palette-binding-application'));
      await tester.pump();
      expect(g.saved, isEmpty);
      await tester.ensureVisible(key('palette-settings-save'));
      await tester.tap(key('palette-settings-save'));
      await tester.pumpAndSettle();
      expect(find.text('保存应用命令面板快捷键？'), findsOneWidget);
      expect(g.saved, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(g.saved, isEmpty);
      await confirm(tester);
      expect(g.saved.single.vaultScope, 'fixture-scope');
      expect(g.saved.single.revision, 'original');
      expect(g.saved.single.applicationInTerminal, true);
    },
  );
  testWidgets(
    'failed load cannot overwrite defaults; reserved chord is rejected before save',
    (tester) async {
      final g = _Gateway()..loadError = StateError('synthetic load failure');
      await _mount(tester, g);
      expect(
        tester.widget<FilledButton>(key('palette-settings-save')).onPressed,
        isNull,
      );
      g.loadError = null;
      await tester.tap(key('palette-settings-reload'));
      await tester.pumpAndSettle();
      final menu = find.byType(DropdownButton<String>);
      tester.widget<DropdownButton<String>>(menu).onChanged!('KeyC');
      await tester.pump();
      await tester.ensureVisible(key('palette-settings-save'));
      await tester.tap(key('palette-settings-save'));
      await tester.pumpAndSettle();
      expect(key('palette-settings-error'), findsOneWidget);
      expect(g.saved, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
  testWidgets(
    'failure retains proposal but acknowledged save cannot replay after context changes',
    (tester) async {
      final g = _Gateway()..saveError = StateError('synthetic save failure');
      await _mount(tester, g);
      await tester.tap(key('palette-binding-application'));
      await tester.pump();
      await confirm(tester);
      expect(g.saved.length, 1);
      expect(
        tester.widget<SwitchListTile>(key('palette-binding-application')).value,
        true,
      );
      g.saveError = null;
      g.savedFailure = true;
      await confirm(tester);
      expect(g.saved.length, 2);
      expect(
        tester.widget<FilledButton>(key('palette-settings-save')).onPressed,
        isNull,
      );
      expect(find.textContaining('已保存到原配置库'), findsOneWidget);
    },
  );
  testWidgets('controls fit a small scaled viewport', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(tester, _Gateway());
    await tester.tap(key('palette-binding-application'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
