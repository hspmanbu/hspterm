import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/painter.dart';
import 'package:hspterm/terminal/typography.dart';
import 'package:hspterm/workbench/typography_settings.dart';
import 'package:hspterm/workbench/typography_store.dart';

class _Gateway implements TypographyGateway {
  TypographySnapshot value = TypographySnapshot(
    scope: 'fixture-scope',
    revision: 'r0',
    settings: const TerminalTypography(),
  );
  Object? loadError, saveError;
  Completer<void>? saving;
  int saves = 0, loads = 0;
  int catalogReads = 0;
  List<String> families = ['Synthetic Mono'];
  Object? catalogError;
  Completer<List<String>>? catalog;
  @override
  Future<TypographySnapshot> load() async {
    loads++;
    if (loadError != null) throw loadError!;
    return value;
  }

  @override
  Future<TypographySnapshot> save(
    TypographySnapshot source,
    TerminalTypography settings,
  ) async {
    if (source.scope != value.scope || source.revision != value.revision) {
      throw StateError('stale fixture');
    }
    saves++;
    await saving?.future;
    if (saveError != null) throw saveError!;
    return value = TypographySnapshot(
      scope: source.scope,
      revision: 'r$saves',
      settings: settings,
    );
  }

  @override
  Future<List<String>> systemFamilies() async {
    catalogReads++;
    if (catalogError != null) throw catalogError!;
    return catalog?.future ?? families;
  }

  @override
  Future<Uint8List> fontBytes(TypographySnapshot source, String id) =>
      throw UnimplementedError('not requested by builtin tests');
  @override
  Future<TypographySnapshot> importFont(
    TypographySnapshot source,
    String label,
    Uint8List bytes,
  ) => throw UnimplementedError('system picker is tested by Native fixture');
  @override
  Future<TypographySnapshot> removeFont(TypographySnapshot source, String id) =>
      throw UnimplementedError('no imported fonts in this fixture');
}

void main() {
  test('configuration refresh waits for the real previous font save and then reads current settings', () async {
    final gateway = _Gateway()..saving = Completer<void>();
    final c = TerminalTypographyController(gateway: gateway);
    final source = await c.load();
    final writing = c.save(source.settings.copyWith(size: 18));
    final refreshing = c.load();
    expect(gateway.loads, 1);
    gateway.saving!.complete();
    await writing;
    final result = await refreshing;
    expect(result.settings.size, 18);
    expect(c.value.size, 18);
    expect(gateway.loads, 2);
    expect(gateway.saves, 1);
    await c.shutdown();
    c.dispose();
  });
  test('explicit Nerd candidate preserves primary monospace geometry and licensed symbol fallback', () {
    final settings = TerminalTypography.fromJson({
      ...const TerminalTypography().toJson(),
      'family': 'JetBrainsMonoNerd',
    });
    expect(settings.renderFamily, 'JetBrainsMono');
    expect(settings.fallback.first, 'HSPNerdSymbols');
    expect(settings.size, const TerminalTypography().size);
    expect(settings.features, const TerminalTypography().features);
    expect(
      const TerminalTypography().fallback,
      isNot(contains('HSPNerdSymbols')),
    );
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'large font catalog is lazy, searchable, and selection stays a draft',
    (tester) async {
      final gateway = _Gateway()
        ..families = List.generate(4096, (i) => 'Synthetic Mono $i');
      final c = TerminalTypographyController(gateway: gateway);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TypographySettingsPanel(controller: c),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(gateway.catalogReads, 0);
      expect(
        find.textContaining('Synthetic Mono', skipOffstage: false),
        findsNothing,
      );
      final choice = find.byKey(
        const ValueKey('typography-family-builtin:JetBrainsMono'),
      );
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(gateway.catalogReads, 1);
      expect(
        find
            .textContaining('系统 · Synthetic Mono', skipOffstage: false)
            .evaluate()
            .length,
        lessThan(20),
      );
      await tester.enterText(
        find.byKey(const ValueKey('font-picker-search')),
        'Synthetic Mono 4095',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('font-option-system:Synthetic Mono 4095')),
      );
      await tester.pumpAndSettle();
      expect(c.value.family, 'JetBrainsMono');
      expect(gateway.saves, 0);
      expect(
        find.byKey(
          const ValueKey('typography-family-system:Synthetic Mono 4095'),
        ),
        findsOneWidget,
      );
      final save = find.byKey(const ValueKey('typography-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(c.value.kind, 'system');
      expect(c.value.family, 'Synthetic Mono 4095');
      expect(gateway.saves, 1);
      await tester.pumpWidget(const SizedBox());
      await c.shutdown();
      c.dispose();
    },
  );

  testWidgets(
    'catalog errors keep builtin choices and cancelling preserves the draft',
    (tester) async {
      final gateway = _Gateway()
        ..catalogError = StateError('synthetic font failure');
      final c = TerminalTypographyController(gateway: gateway);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TypographySettingsPanel(controller: c),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final choice = find.byKey(
        const ValueKey('typography-family-builtin:JetBrainsMono'),
      );
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(find.text('系统字体列表暂不可用，仍可选择内置或已导入字体。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('font-option-builtin:NotoSansCJK')),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(c.value.family, 'JetBrainsMono');
      expect(gateway.saves, 0);
      gateway.catalogError = null;
      gateway.catalog = Completer<List<String>>();
      await tester.tap(choice);
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      gateway.catalog!.complete(['Late Synthetic Mono']);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(gateway.catalogReads, 2);
      await tester.pumpWidget(const SizedBox());
      await c.shutdown();
      c.dispose();
    },
  );
  test('layout validation, fallback and cache invalidation do not alter terminal data', () {
    const original = TerminalTypography();
    expect(original.ligatures, false);
    final changed = original.copyWith(
      family: 'Synthetic Mono',
      kind: 'system',
      lineHeight: 1.6,
      padding: 12,
      ligatures: true,
    );
    expect(TerminalTypography.fromJson(changed.toJson()), changed);
    expect(changed.renderFamily, 'Synthetic Mono');
    expect(changed.fallback, contains('NotoSansCJK'));
    expect(
      () => TerminalTypography.fromJson(
        original.copyWith(size: double.infinity).toJson(),
      ),
      throwsFormatException,
    );
    final cache = TerminalPaintCache();
    cache.glyph('A', 0xffffffff, 0, 15);
    expect(cache.glyphCount, 1);
    cache.configure(original);
    expect(cache.glyphCount, 1);
    cache.configure(changed);
    expect(cache.glyphCount, 0);
    cache.glyph('中', 0xffffffff, 0, 15);
    cache.configure(changed.copyWith());
    expect(cache.glyphCount, 1);
    cache.dispose();
  });
  test('failed save keeps render settings; old form cannot overwrite reloaded source', () async {
    final gateway = _Gateway();
    final controller = TerminalTypographyController(gateway: gateway);
    final old = await controller.load();
    gateway.saveError = StateError('synthetic persistence failure');
    await expectLater(
      controller.save(old.settings.copyWith(size: 18), expected: old),
      throwsStateError,
    );
    expect(controller.value, old.settings);
    gateway.saveError = null;
    gateway.value = TypographySnapshot(
      scope: old.scope,
      revision: 'new-from-other-view',
      settings: old.settings.copyWith(padding: 12),
    );
    await controller.load();
    await expectLater(
      controller.save(old.settings, expected: old),
      throwsStateError,
    );
    expect(gateway.saves, 1);
    expect(controller.value.padding, 12);
    await controller.shutdown();
    controller.dispose();
  });
  test(
    'shutdown awaits in-flight persistence and no new writes are admitted',
    () async {
      final gateway = _Gateway()..saving = Completer<void>();
      final controller = TerminalTypographyController(gateway: gateway);
      final original = await controller.load();
      final write = controller.save(
        original.settings.copyWith(size: 17),
        expected: original,
      );
      var stopped = false;
      final stop = controller.shutdown().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, false);
      await expectLater(controller.load(), throwsStateError);
      gateway.saving!.complete();
      await write;
      await stop;
      expect(controller.value.size, 17);
      expect(stopped, true);
      controller.dispose();
    },
  );
  testWidgets(
    'settings selection is a draft until explicit save, and failed load cannot overwrite',
    (tester) async {
      final gateway = _Gateway()
        ..loadError = StateError('synthetic unreadable settings');
      final controller = TerminalTypographyController(gateway: gateway);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TypographySettingsPanel(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('typography-save')))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const ValueKey('typography-error')), findsOneWidget);
      gateway.loadError = null;
      await tester.ensureVisible(
        find.byKey(const ValueKey('typography-reload')),
      );
      await tester.tap(find.byKey(const ValueKey('typography-reload')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(controller.value.ligatures, false);
      expect(gateway.saves, 0);
      await tester.ensureVisible(find.byKey(const ValueKey('typography-save')));
      await tester.tap(find.byKey(const ValueKey('typography-save')));
      await tester.pumpAndSettle();
      expect(controller.value.ligatures, true);
      expect(gateway.saves, 1);
      expect(find.byKey(const ValueKey('typography-status')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await controller.shutdown();
      controller.dispose();
    },
  );
  testWidgets('narrow large text layout keeps font controls scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = TerminalTypographyController(gateway: _Gateway());
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: TypographySettingsPanel(controller: c),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final picker = find.byKey(
      const ValueKey('typography-family-builtin:JetBrainsMono'),
    );
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(
      find.byKey(const ValueKey('font-picker-search')),
      'Synthetic Mono',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('typography-family-system:Synthetic Mono')),
      findsOneWidget,
    );
    expect(c.value.kind, 'builtin');
    await tester.ensureVisible(find.byKey(const ValueKey('typography-import')));
    await tester.pumpWidget(const SizedBox());
    await c.shutdown();
    c.dispose();
  });
}
