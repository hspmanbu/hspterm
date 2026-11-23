import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/tmux.dart' as tmx;
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/workbench/model.dart';
import 'package:hspterm/workbench/tmux_choice.dart';

import 'support/fake_backend.dart';

tmx.TmuxPrompt prompt({
  int generation = 7,
  bool restoreAvailable = false,
  bool? readonlyDefault,
}) => tmx.TmuxPrompt(
  restoreAvailable: restoreAvailable,
  readonlyDefault: readonlyDefault,
  requestId: 12,
  generation: generation,
  columns: 80,
  rows: 24,
  version: 'tmux 3.4',
  sessions: [
    const tmx.TmuxSessionInfo(id: r'$0', name: 'fixture 中文', attached: 2),
  ],
);
void main() {
  for (final available in [false, true]) {
    testWidgets(
      'ordinary Shell restore is explicit and session-scoped (available=$available)',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final s = LiveTerminalSession(
          'source',
          DemoHost('h', 'Fixture', 'example.invalid', 'g'),
          FakeBackend(),
        );
        s.controller
          ..id = 1
          ..generation = 7
          ..phase = 'Connecting';
        tmx.TmuxSelection? selected;
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => selected = await showTmuxChoice(
                    context,
                    s.controller,
                    prompt(restoreAvailable: available),
                  ),
                  child: const Text('choose'),
                ),
              ),
            ),
          );
          await tester.tap(find.text('choose'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('tmux-kind')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('明确改用普通 SSH Shell').last);
          await tester.pumpAndSettle();
          final restore = find.byKey(
            const ValueKey('tmux-restore-on-reconnect'),
          );
          if (available) {
            expect(find.text('本会话重连恢复普通Shell'), findsOneWidget);
            expect(tester.widget<CheckboxListTile>(restore).value, false);
            await tester.ensureVisible(restore);
            await tester.tap(restore);
            await tester.pump();
          } else {
            expect(restore, findsNothing);
          }
          await tester.tap(find.byKey(const ValueKey('tmux-confirm')));
          await tester.pumpAndSettle();
          expect(selected!.kind, 1);
          expect(selected!.restoreOnReconnect, available);
          expect(selected!.sessionId, null);
          expect(selected!.ensureLocale, false);
          expect(selected!.lockSize, false);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await s.controller.shutdown();
          s.controller.dispose();
        }
      },
    );
  }
  for (final readonly in [false, true]) {
    testWidgets(
      'host readonly default=$readonly is shown without takeover consent',
      (tester) async {
        final s = LiveTerminalSession(
          'source',
          DemoHost('h', 'Fixture', 'example.invalid', 'g'),
          FakeBackend(),
        );
        s.controller
          ..id = 1
          ..generation = 7
          ..phase = 'Connecting';
        tmx.TmuxSelection? selected;
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => selected = await showTmuxChoice(
                    context,
                    s.controller,
                    prompt(readonlyDefault: readonly),
                  ),
                  child: const Text('choose'),
                ),
              ),
            ),
          );
          await tester.tap(find.text('choose'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<SwitchListTile>(
                  find.byKey(const ValueKey('tmux-readonly')),
                )
                .value,
            readonly,
          );
          expect(find.byKey(const ValueKey('tmux-takeover')), findsNothing);
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const ValueKey('tmux-confirm')),
                )
                .onPressed,
            isNotNull,
          );
          await tester.tap(find.byKey(const ValueKey('tmux-confirm')));
          await tester.pumpAndSettle();
          expect(selected!.readonly, readonly);
          expect(selected!.takeoverConfirmed, !readonly);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await s.controller.shutdown();
          s.controller.dispose();
        }
      },
    );
  }

  test('default tmux names use the first free positive suffix', () {
    expect(nextTmuxSessionName([]), 'hspterm1');
    expect(
      nextTmuxSessionName(['hspterm', 'hspterm1', 'hspterm2', 'hspterm4']),
      'hspterm3',
    );
    expect(nextTmuxSessionName(['hspterm2', 'fixture']), 'hspterm1');
  });
  testWidgets(
    'new-session restore explains retained creation and future takeover',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final s = LiveTerminalSession(
        'source',
        DemoHost('h', 'Fixture', 'example.invalid', 'g'),
        FakeBackend(),
      );
      s.controller
        ..id = 1
        ..generation = 7
        ..phase = 'Connecting';
      tmx.TmuxSelection? selected;
      final p = prompt(restoreAvailable: true);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await showTmuxChoice(
                  context,
                  s.controller,
                  tmx.TmuxPrompt(
                    requestId: p.requestId,
                    generation: p.generation,
                    columns: p.columns,
                    rows: p.rows,
                    version: p.version,
                    sessions: const [],
                    restoreAvailable: true,
                  ),
                );
              },
              child: const Text('choose'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('choose'));
      await tester.pumpAndSettle();
      final restore = find.byKey(const ValueKey('tmux-restore-on-reconnect'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pump();
      expect(find.textContaining('接管原会话'), findsOneWidget);
      expect(find.textContaining('已创建的会话保留'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tmux-confirm')));
      await tester.pumpAndSettle();
      expect(selected!.kind, 2);
      expect(selected!.restoreOnReconnect, true);
      expect(selected!.readonly, false);
      expect(selected!.sessionId, null);
      await tester.pumpWidget(const SizedBox());
      await s.controller.shutdown();
      s.controller.dispose();
    },
  );
  testWidgets(
    'remembering an attachment is explicit and readonly changes reset future takeover consent',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final s = LiveTerminalSession(
        'source',
        DemoHost('h', 'Fixture', 'example.invalid', 'g'),
        FakeBackend(),
      );
      s.controller
        ..id = 1
        ..generation = 7
        ..phase = 'Connecting';
      tmx.TmuxSelection? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await showTmuxChoice(
                  context,
                  s.controller,
                  prompt(restoreAvailable: true),
                );
              },
              child: const Text('choose'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('choose'));
      await tester.pumpAndSettle();
      final restore = find.byKey(const ValueKey('tmux-restore-on-reconnect'));
      expect(tester.widget<CheckboxListTile>(restore).value, false);
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(restore).value, true);
      await tester.tap(find.byKey(const ValueKey('tmux-readonly')));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(restore).value, false);
      await tester.tap(find.byKey(const ValueKey('tmux-readonly')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tmux-confirm')));
      await tester.pumpAndSettle();
      expect(selected!.restoreOnReconnect, true);
      expect(selected!.readonly, true);
      await tester.pumpWidget(const SizedBox());
      await s.controller.shutdown();
      s.controller.dispose();
    },
  );
  test('latest layout resends once per connection and duplicate status has no idle resize', () async {
    final backend = FakeBackend();
    final controller = TerminalController(backend);
    await controller.start();
    controller.resize(132, 36, 9, 20);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(backend.resizes, 1);
    void status(String phase, int generation) => backend.events.add(
      rust.BridgeEvent(
        kind: 'status',
        text: phase,
        generation: generation,
        requestId: 0,
      ),
    );
    status('Connected', 1);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(backend.resizes, 2);
    status('Connected', 1);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(backend.resizes, 2);
    status('Disconnected', 1);
    await Future<void>.delayed(Duration.zero);
    status('Connected', 2);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(backend.resizes, 3);
    await controller.shutdown().timeout(const Duration(seconds: 3));
    controller.dispose();
  });
  test(
    'new names preserve Unicode while rejecting shell and tmux metacharacters',
    () {
      expect(validTmuxName('开发 session-1'), true);
      for (final bad in [
        '',
        ' space',
        'space ',
        'a.b',
        'a:b',
        r'$(cmd)',
        "a'",
        'a\nb',
        '中' * 22,
      ]) {
        expect(validTmuxName(bad), false);
      }
    },
  );
  testWidgets(
    'control attachment needs no takeover checkbox and size lock is per selection',
    (tester) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final s = LiveTerminalSession(
        'source',
        DemoHost('h', 'Fixture', 'example.invalid', 'g'),
        FakeBackend(),
      );
      s.controller
        ..id = 1
        ..generation = 7
        ..phase = 'Connecting';
      tmx.TmuxSelection? result;
      Future<tmx.TmuxSelection?>? pending;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                pending = showTmuxChoice(context, s.controller, prompt()).then((
                  v,
                ) {
                  result = v;
                  return v;
                });
              },
              child: const Text('choose'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('choose'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tmux-readonly')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('tmux-confirm')))
            .onPressed,
        isNotNull,
      );
      expect(find.byKey(const ValueKey('tmux-takeover')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tmux-lock-size')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tmux-confirm')));
      await tester.pumpAndSettle();
      await pending;
      expect(result!.sessionId, r'$0');
      expect(result!.readonly, false);
      expect(result!.takeoverConfirmed, true);
      expect(result!.lockSize, true);
      await tester.pumpWidget(const SizedBox());
      await s.controller.shutdown();
      s.controller.dispose();
    },
  );
  testWidgets(
    'closing the original source retires only its pending choice without answering another connection',
    (tester) async {
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final s = LiveTerminalSession(
        'source',
        DemoHost('h', 'Fixture', 'example.invalid', 'g'),
        FakeBackend(),
      );
      s.controller
        ..id = 1
        ..generation = 7
        ..phase = 'Connecting';
      Future<tmx.TmuxSelection?>? pending;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                pending = showTmuxChoice(context, s.controller, prompt());
              },
              child: const Text('choose'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('choose'));
      await tester.pumpAndSettle();
      await s.controller.shutdown();
      await tester.pumpAndSettle();
      expect(await pending, isNull);
      expect(find.text('选择此终端的 tmux 会话'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      s.controller.dispose();
    },
  );
  test('duplicate prompt, status-event ordering and late selection never cause duplicate or new-root input', () async {
    final b = FakeBackend()..tmux = prompt(generation: 1);
    final c = TerminalController(b);
    final reply = Completer<tmx.TmuxSelection?>();
    var calls = 0;
    c.chooseTmux = (_) {
      calls++;
      return reply.future;
    };
    await c.start();
    final event = rust.BridgeEvent(kind: 'tmux', generation: 1, requestId: 12);
    b.events.add(event);
    b.events.add(event);
    for (var i = 0; i < 10 && calls == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(c.phase, 'Connecting');
    expect(c.generation, 1);
    expect(calls, 1);
    b.events.add(
      const rust.BridgeEvent(
        kind: 'status',
        generation: 2,
        requestId: 0,
        text: 'Connecting',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    reply.complete(
      const tmx.TmuxSelection(
        kind: 3,
        sessionId: r'$0',
        readonly: true,
        takeoverConfirmed: false,
        lockSize: false,
      ),
    );
    for (var i = 0; i < 10 && b.tmuxAnswers.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(b.tmuxAnswers.single.kind, 0);
    expect(c.generation, 2);
    expect(b.texts, isEmpty);
    expect(b.keys, isEmpty);
    expect(b.connects, 0);
    await c.shutdown();
    c.dispose();
  });
}
