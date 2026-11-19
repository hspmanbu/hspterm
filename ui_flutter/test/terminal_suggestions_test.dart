import 'package:flutter/gestures.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/controller.dart';
import 'package:hspterm/terminal/suggestions.dart';
import 'package:hspterm/terminal/suggestions_overlay.dart';
import 'package:hspterm/terminal/view.dart';

import 'support/fake_backend.dart';
import 'support/terminal_cleanup.dart';

class SuggestionsBackend extends FakeBackend
    implements TerminalSuggestionsBackend {
  rust.TerminalSuggestions? value = choices('one');
  Completer<rust.TerminalSuggestions?>? pending;
  int queries = 0;
  final observedTexts = <List<String>>[];
  final selected = <(int, int, String, int, bool)>[];
  final deleted = <(int, String, int)>[];
  @override
  Future<bool> deleteSuggestion(int id, String ticket, int index) async {
    deleted.add((id, ticket, index));
    return true;
  }

  @override
  Future<rust.TerminalSuggestions?> suggestions(int id, int generation) async {
    queries++;
    observedTexts.add(List.of(texts));
    return pending == null ? value : pending!.future;
  }

  @override
  Future<String> chooseSuggestion(
    int id,
    int generation,
    String ticket,
    int index,
    bool execute,
  ) async {
    selected.add((id, generation, ticket, index, execute));
    return 'Applied';
  }
}

rust.TerminalSuggestions choices(String ticket, {int revision = 1}) =>
    rust.TerminalSuggestions(
      ticket: ticket,
      prompt: 1,
      revision: revision,
      choices: ['git status', 'git log'],
    );
Future<TerminalController> controller(SuggestionsBackend backend) async {
  final value = TerminalController(backend);
  await value.start();
  value.phase = 'Connected';
  value.generation = 1;
  value.applyFrame(fixture());
  return value;
}

void main() {
  testWidgets(
    'suggestions follow live cursor and remain wholly above or below input',
    (tester) async {
      final backend = SuggestionsBackend();
      final current = await controller(backend);
      final suggestions = TerminalSuggestionsController(current)
        ..setWanted(true);
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 600,
                  height: 360,
                  child: Stack(
                    children: [
                      TerminalSuggestionsOverlay(
                        controller: suggestions,
                        viewport: const Size(600, 360),
                        cell: const Size(10, 160),
                        cursorColumn: 0,
                        cursorRow: 0,
                        choose: (_, _) {},
                        delete: (_, _) {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 30));
        await tester.pump();
        final popup = find.byKey(const ValueKey('terminal-suggestions-popup'));
        final origin = tester.getTopLeft(find.byType(Stack).first);
        expect(
          tester.getRect(popup).bottom,
          lessThanOrEqualTo(origin.dy + 160),
        );
        // No TerminalView setState or candidate refresh: metadata alone moves it.
        current.applyFrame(fixture(revision: 2, cursorRow: 0));
        await tester.pump();
        expect(
          tester.getRect(popup).top,
          greaterThanOrEqualTo(origin.dy + 160),
        );
        expect(
          tester.getRect(popup).bottom,
          lessThanOrEqualTo(origin.dy + 360),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        suggestions.dispose();
        await closeTerminal(tester, current);
      }
    },
  );

  testWidgets(
    'stale cursor rows beyond the live viewport clamp instead of hiding',
    (tester) async {
      final backend = SuggestionsBackend();
      final current = await controller(backend);
      final suggestions = TerminalSuggestionsController(current)
        ..setWanted(true);
      try {
        // A frame from before a shrink: 40 rows with the cursor on the last
        // row, while the overlay's live viewport only fits 12 rows of 20px.
        current.applyFrame(
          rust.RenderFrame(
            revision: 2,
            contentRevision: 1,
            outputLines: 0,
            sizeLocked: false,
            sameWordEnabled: null,
            sameWordCaseSensitive: null,
            decorationsLimited: null,
            searchRevision: null,
            searchSpans: [],
            columns: 6,
            rows: 40,
            full: true,
            changedRows: const [],
            cursorColumn: 0,
            cursorRow: 39,
            cursorVisible: true,
            cursorShape: 2,
            cursorBlink: false,
            osc52Enabled: null,
            rightClickPaste: null,
            copyOnSelection: null,
            imagePasteShortcut: null,
            cursorColor: 0xffffffff,
            background: 0xff10151d,
            alternateScreen: false,
            mouseReporting: false,
            historyLines: 0,
            displayOffset: 0,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 600,
                  height: 240,
                  child: Stack(
                    children: [
                      TerminalSuggestionsOverlay(
                        controller: suggestions,
                        viewport: const Size(600, 240),
                        cell: const Size(10, 20),
                        cursorColumn: 0,
                        cursorRow: 39,
                        choose: (_, _) {},
                        delete: (_, _) {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 30));
        await tester.pump();
        final popup = find.byKey(const ValueKey('terminal-suggestions-popup'));
        expect(popup, findsOneWidget, reason: '位置过时不应丢掉候选框');
        final rect = tester.getRect(popup);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(240));
        // At the clamped last row the box must pop up above the input row.
        expect(rect.bottom, lessThanOrEqualTo(11 * 20.0));
      } finally {
        await tester.pumpWidget(const SizedBox());
        suggestions.dispose();
        await closeTerminal(tester, current);
      }
    },
  );

  testWidgets(
    'candidate delete keeps its slot but reveals only on row hover or keyboard selection',
    (tester) async {
      final backend = SuggestionsBackend(),
          key = GlobalKey<TerminalViewState>();
      final current = await controller(backend);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 300,
              child: TerminalView(key: key, controller: current),
            ),
          ),
        ),
      );
      key.currentState!.focusTerminal();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump();
      final icon = find.byIcon(Icons.delete_outline).first;
      final opacity = find
          .ancestor(of: icon, matching: find.byType(Opacity))
          .first;
      expect(tester.widget<Opacity>(opacity).opacity, 0);
      final buttonSize = tester.getSize(icon);
      final row = find.byKey(
        ValueKey('history-candidate-0-${backend.value!.ticket}'),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(700, 500));
      await mouse.moveTo(tester.getTopLeft(row) + const Offset(12, 10));
      await tester.pump();
      expect(tester.widget<Opacity>(opacity).opacity, 1);
      expect(tester.getSize(icon), buttonSize);
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump();
      expect(tester.widget<Opacity>(opacity).opacity, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(tester.widget<Opacity>(opacity).opacity, 1);
      await tester.tap(icon);
      await tester.pump();
      expect(backend.deleted.single.$3, 0);
      expect(backend.selected, isEmpty);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      await closeTerminal(tester, current);
    },
  );

  testWidgets(
    'controlled path actions hide stale candidates and queries wait for keys appended during ACK',
    (tester) async {
      final backend = SuggestionsBackend();
      final terminal = await controller(backend);
      final state = TerminalSuggestionsController(terminal);
      state.setWanted(true);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(state.showing, true);
      final ack = Completer<String>();
      final operation = terminal.controlledInput((_, _) => ack.future);
      expect(state.showing, false);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(backend.queries, 1);
      state.inputChanged();
      final typed = terminal.text('after');
      ack.complete('Applied');
      await operation;
      await typed;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(backend.observedTexts.last, ['after']);
      expect(backend.selected, isEmpty);
      state.dispose();
      await closeTerminal(tester, terminal);
    },
  );

  testWidgets(
    'coalesced changes select best match, move, Tab fill and stale mouse ticket is refused',
    (tester) async {
      final backend = SuggestionsBackend();
      final current = await controller(backend);
      final state = TerminalSuggestionsController(current);
      state.setWanted(true);
      for (var n = 0; n < 50; n++) {
        state.refresh();
      }
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      expect(backend.queries, 1);
      expect(state.showing, true);
      expect(state.selected, -1, reason: 'a fresh box opens unselected');
      state.move(1);
      expect(state.selected, 0, reason: 'first arrow down picks the first row');
      state.move(1);
      expect(state.selected, 1);
      state.move(-1);
      expect(state.selected, 0, reason: 'arrows move normally afterwards');
      expect(
        await state.choose(execute: false, expectedTicket: 'old'),
        'Unavailable',
      );
      expect(backend.selected, isEmpty);
      expect(await state.choose(execute: false), 'Applied');
      expect(backend.selected.single.$4, 0);
      expect(backend.selected.single.$5, false);
      state.dispose();
      await closeTerminal(tester, current);
    },
  );
  testWidgets(
    'late query cannot publish after lost focus and empty input resumes raw routing',
    (tester) async {
      final backend = SuggestionsBackend();
      backend.pending = Completer<rust.TerminalSuggestions?>();
      final current = await controller(backend);
      final active = TerminalSuggestionsController(current);
      active.setWanted(true);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();
      active.setWanted(false);
      backend.pending!.complete(choices('late'));
      await tester.pump();
      await tester.pump();
      expect(active.view, isNull);
      final reads = backend.queries;
      await tester.pump(const Duration(seconds: 3));
      expect(backend.queries, reads);
      active.dispose();
      await closeTerminal(tester, current);
    },
  );
  testWidgets(
    'visible local candidates own arrows and Tab release, while Escape restores normal Enter',
    (tester) async {
      final backend = SuggestionsBackend(),
          key = GlobalKey<TerminalViewState>();
      final current = await controller(backend);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 300,
              child: TerminalView(key: key, controller: current),
            ),
          ),
        ),
      );
      key.currentState!.focusTerminal();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump();
      expect(find.text('git status'), findsOneWidget);
      // Unselected Enter/Tab pass through to the shell untouched.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(backend.selected, isEmpty);
      expect(
        backend.keys.any((key) => key.key == 'Enter' && key.kind == 0),
        true,
        reason: 'unselected Enter submits the shell input',
      );
      backend.keys.clear();
      // Bring the box back (Enter above cleared it) and select with arrows.
      current.shellInputChanges.value++;
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump();
      expect(find.text('git status'), findsOneWidget);
      // First arrow down selects row 0; Tab then fills that candidate.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(backend.selected.single.$4, 0);
      expect(backend.selected.single.$5, false);
      expect(backend.keys, isEmpty);
      backend.value = choices('two', revision: 2);
      current.shellInputChanges.value++;
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(backend.selected.length, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        backend.keys.any((key) => key.key == 'Enter' && key.kind == 0),
        true,
      );
      await tester.pumpWidget(const SizedBox());
      await closeTerminal(tester, current);
    },
  );
  testWidgets('IME preedit hides candidates and never becomes remote input', (
    tester,
  ) async {
    final backend = SuggestionsBackend();
    final current = await controller(backend);
    final key = GlobalKey<TerminalViewState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(key: key, controller: current),
        ),
      ),
    );
    key.currentState!.focusTerminal();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump();
    expect(find.text('git status'), findsOneWidget);
    key.currentState!.updateEditingValue(
      const TextEditingValue(
        text: 'zhong',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();
    final reads = backend.queries;
    current.shellInputChanges.value++;
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('git status'), findsNothing);
    expect(backend.queries, reads);
    expect(backend.texts, isEmpty);
    key.currentState!.updateEditingValue(
      const TextEditingValue(
        text: '中',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    expect(backend.texts, ['中']);
    expect(backend.selected, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await closeTerminal(tester, current);
  });
}
