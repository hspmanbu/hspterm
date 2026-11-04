import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/typography.dart';
import 'package:hspterm/workbench/typography_settings.dart';
import 'package:hspterm/workbench/typography_store.dart';

const _a = 'host-00000000000000000000000000000001';
const _b = 'host-00000000000000000000000000000002';
final _font = 'a' * 64;

class _Gateway implements TypographyGateway, HostTypographyGateway {
  TypographySnapshot current = TypographySnapshot(
    scope: 'fixture',
    revision: 'r0',
    settings: const TerminalTypography(),
  );
  int writes = 0;
  @override
  Future<TypographySnapshot> load() async => current;
  void check(TypographySnapshot source) {
    if (source.scope != current.scope || source.revision != current.revision) {
      throw StateError('stale fixture');
    }
  }

  @override
  Future<TypographySnapshot> saveHost(
    TypographySnapshot source,
    String id,
    TerminalTypography? style,
  ) async {
    check(source);
    final hosts = {...source.hosts};
    if (style == null) {
      hosts.remove(id);
    } else {
      hosts[id] = style;
    }
    return current = TypographySnapshot(
      scope: source.scope,
      revision: 'r${++writes}',
      settings: source.settings,
      fonts: source.fonts,
      hosts: hosts,
    );
  }

  @override
  Future<TypographySnapshot> save(
    TypographySnapshot source,
    TerminalTypography value,
  ) async {
    check(source);
    return current = TypographySnapshot(
      scope: source.scope,
      revision: 'r${++writes}',
      settings: value,
      fonts: source.fonts,
      hosts: source.hosts,
    );
  }

  @override
  Future<List<String>> systemFamilies() async => [];
  @override
  Future<Uint8List> fontBytes(TypographySnapshot source, String id) =>
      throw UnimplementedError('controlled loader supplies the fixture font');
  @override
  Future<TypographySnapshot> importFont(
    TypographySnapshot source,
    String label,
    Uint8List bytes,
  ) => throw UnimplementedError('no import in this fixture');
  @override
  Future<TypographySnapshot> removeFont(TypographySnapshot source, String id) =>
      throw UnimplementedError('no removal in this fixture');
}

class _Loader extends TerminalFontLoader {
  Completer<void>? pending;
  bool fail = false, ready = false;
  int requests = 0;
  @override
  bool isReady(String id) => ready;
  @override
  Future<void> ensure(
    TypographyGateway gateway,
    TypographySnapshot source,
    TerminalTypography value,
  ) async {
    if (value.kind != 'imported') return;
    requests++;
    await pending?.future;
    if (fail) throw StateError('synthetic font load failure');
    ready = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'host save and runtime zoom preserve other hosts and global inheritance',
    () async {
      final gateway = _Gateway();
      final c = TerminalTypographyController(
        gateway: gateway,
        loader: _Loader(),
      );
      await c.load();
      c.zoom(1);
      final original = c.snapshot!;
      const override = TerminalTypography(
        family: 'NotoSansCJK',
        size: 23,
        padding: 2,
      );
      await c.saveHost(_a, override, expected: original);
      expect(
        c.value.size,
        16,
        reason: 'host-only save must not reset global runtime zoom',
      );
      expect(c.forHost(_a), override);
      expect(c.forHost(_b).size, 16);
      c.zoom(-1, hostId: _a);
      expect(c.forHost(_a).size, 22);
      expect(c.forHost(_b).size, 16);
      await expectLater(
        c.saveHost(_b, override, expected: original),
        throwsStateError,
      );
      await c.saveHost(_a, null);
      expect(c.forHost(_a).size, 16);
      expect(c.snapshot!.hosts, isEmpty);
      await c.shutdown();
      c.dispose();
    },
  );
  test('lazy font IO is coalesced, never starts from rendering, and shutdown waits for its worker', () async {
    final loader = _Loader()..pending = Completer<void>();
    final gateway = _Gateway()
      ..current = TypographySnapshot(
        scope: 'fixture',
        revision: 'r0',
        settings: const TerminalTypography(),
        fonts: [ImportedTerminalFont(_font, 'Synthetic mono', 100)],
        hosts: {
          _a: TerminalTypography(kind: 'imported', family: _font, size: 24),
        },
      );
    final c = TerminalTypographyController(gateway: gateway, loader: loader);
    await c.load();
    for (var i = 0; i < 1000; i++) {
      expect(c.forHost(_a).size, 24);
    }
    expect(loader.requests, 0);
    final first = c.ensureHost(_a), second = c.ensureHost(_a);
    expect(identical(first, second), true);
    expect(loader.requests, 1);
    expect(c.forHost(_a).kind, 'builtin');
    expect(c.hostNotice(_a), isNotNull);
    var closed = false;
    final closing = c.shutdown().then((_) => closed = true);
    await Future<void>.value();
    expect(closed, false);
    loader.pending!.complete();
    await first;
    await closing;
    expect(c.forHost(_a).family, _font);
    expect(c.hostNotice(_a), isNull);
    c.dispose();
  });
  test('old font failures cannot replace a new scope and explicit retry is bounded to user action', () async {
    final loader = _Loader()..fail = true;
    final gateway = _Gateway()
      ..current = TypographySnapshot(
        scope: 'fixture',
        revision: 'r0',
        settings: const TerminalTypography(),
        fonts: [ImportedTerminalFont(_font, 'Synthetic mono', 100)],
        hosts: {_a: TerminalTypography(kind: 'imported', family: _font)},
      );
    final c = TerminalTypographyController(gateway: gateway, loader: loader);
    await c.load();
    await c.ensureHost(_a);
    expect(c.hostNotice(_a), contains('未能载入'));
    await c.ensureHost(_a);
    expect(loader.requests, 1);
    loader.pending = Completer<void>();
    final pending = c.ensureHost(_a, retry: true);
    gateway.current = TypographySnapshot(
      scope: 'different',
      revision: 'r-new',
      settings: const TerminalTypography(),
    );
    await c.load();
    loader.pending!.complete();
    await pending;
    expect(c.hostNotice(_a), isNull);
    expect(c.forHost(_a).family, 'JetBrainsMono');
    expect(loader.requests, 2);
    await c.shutdown();
    c.dispose();
  });
  testWidgets(
    'host panel saves explicit override or inheritance without writing global settings',
    (tester) async {
      final gateway = _Gateway();
      final c = TerminalTypographyController(
        gateway: gateway,
        loader: _Loader(),
      );
      await c.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TypographySettingsPanel(
                controller: c,
                hostId: _a,
                hostLabel: 'Synthetic host',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('typography-inherit')),
            )
            .value,
        true,
      );
      expect(find.byKey(const ValueKey('typography-import')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('typography-inherit')));
      await tester.pumpAndSettle();
      tester
          .widget<DropdownButtonFormField<double>>(
            find.byKey(const ValueKey('typography-字号-15.0')),
          )
          .onChanged!(21);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('typography-save')));
      await tester.tap(find.byKey(const ValueKey('typography-save')));
      await tester.pumpAndSettle();
      expect(c.snapshot!.hosts[_a]!.size, 21);
      expect(c.snapshot!.settings.size, 15);
      await tester.ensureVisible(
        find.byKey(const ValueKey('typography-inherit')),
      );
      await tester.tap(find.byKey(const ValueKey('typography-inherit')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('typography-save')));
      await tester.tap(find.byKey(const ValueKey('typography-save')));
      await tester.pumpAndSettle();
      expect(c.snapshot!.hosts, isEmpty);
      expect(gateway.writes, 2);
      await tester.pumpWidget(const SizedBox());
      await c.shutdown();
      c.dispose();
    },
  );
}
