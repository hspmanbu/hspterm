import 'dart:typed_data';
import 'dart:async';

import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/src/rust/tmux.dart' as tmx;
import 'package:hspterm/terminal/backend.dart';

class FakeBackend implements TerminalBackend {
  final events = StreamController<rust.BridgeEvent>.broadcast();
  final clipboardReplies = <String>[];
  final keys = <rust.KeyboardInput>[];
  final navigations = <int>[];
  final searches = <(String, bool, bool)>[];
  final mouseActions = <int>[];
  final mouseModifiers = <int>[];
  final texts = <String>[];
  final pastes = <(String, bool)>[];
  final hostKeyReplies = <(int, bool)>[];
  Future<void>? closeWait;
  int connects = 0, closes = 0, frames = 0, resizes = 0;
  bool shown = true;
  @override
  Future<int> create() async => 1;
  @override
  Stream<rust.BridgeEvent> watch(int id) => events.stream;
  @override
  Future<rust.RenderFrame?> frame(int id) async {
    frames++;
    return null;
  }

  @override
  Future<void> close(int id) async {
    closes++;
    await closeWait;
    await events.close();
  }

  @override
  Future<void> visible(int id, bool visible) async {
    shown = visible;
  }

  @override
  Future<void> connect(int id, String profileId) async {
    connects++;
  }

  @override
  Future<void> cancel(int id) async {}
  @override
  Future<void> resize(
    int id,
    int columns,
    int rows,
    int cellWidth,
    int cellHeight,
  ) async {
    resizes++;
  }

  @override
  Future<void> key(int id, rust.KeyboardInput input) async {
    keys.add(input);
  }

  @override
  Future<void> text(int id, String text) async {
    texts.add(text);
  }

  @override
  Future<void> focus(int id, bool focus) async {}
  @override
  Future<void> scroll(int id, int lines) async {}
  @override
  Future<void> mouse(
    int id,
    int column,
    int row,
    int action,
    int button,
    int mods,
  ) async {
    mouseActions.add(action);
    mouseModifiers.add(mods);
  }

  @override
  Future<rust.PasteResult> paste(int id, String text, bool confirmed) async {
    pastes.add((text, confirmed));
    return rust.PasteResult(
      needsConfirmation: !confirmed && text.contains('\n'),
      lines: 2,
      bytes: text.length,
      bracketed: true,
    );
  }

  @override
  Future<void> hostKey(int id, int requestId, bool accept) async {
    hostKeyReplies.add((requestId, accept));
  }

  tmx.TmuxPrompt? tmux;
  final tmuxAnswers = <tmx.TmuxSelection>[];
  @override
  Future<tmx.TmuxPrompt> tmuxPrompt(int id, int requestId) async =>
      tmux ?? (throw StateError('no fixture tmux prompt'));
  @override
  Future<void> answerTmux(
    int id,
    int generation,
    int requestId,
    tmx.TmuxSelection selection,
  ) async {
    tmuxAnswers.add(selection);
  }

  @override
  Future<rust.SearchSummary> search(
    int id,
    String query,
    bool regex,
    bool caseSensitive,
  ) async {
    searches.add((query, regex, caseSensitive));
    return rust.SearchSummary(
      revision: 1,
      count: query.isEmpty ? 0 : 1,
      markers: Uint32List(128),
      documentRows: 2,
    );
  }

  @override
  Future<rust.SearchLocation> navigate(int id, int ordinal) async {
    navigations.add(ordinal);
    return rust.SearchLocation(
      revision: 1,
      startRow: 0,
      startColumn: 0,
      endRow: 0,
      endColumn: 2,
    );
  }

  @override
  Future<void> seek(int id, int topRow) async {}
  @override
  Future<void> lockSize(int id, bool locked) async {}
  @override
  Future<void> clipboardEnabled(int id, bool enabled) async {}
  @override
  Future<void> exportHistory(int id, String path) async {}
  @override
  Future<rust.TerminalMetrics> metrics(int id) async => rust.TerminalMetrics(
    diskBytes: 0,
    diskReads: 0,
    diskWrites: 0,
    residentHistoryCells: 0,
    historyRows: 0,
    framePulls: frames,
    cellsSent: 0,
    changedRowsSent: 0,
  );
  @override
  Future<void> clipboard(int id, int requestId, String text) async {
    clipboardReplies.add(text);
  }
}

rust.RenderFrame fixture({
  int revision = 1,
  bool full = true,
  bool mouse = false,
  int cursorRow = 1,
  int cursorShape = 2,
  String? line,
  List<rust.RenderHyperlink>? hyperlinks,
}) => rust.RenderFrame(
  revision: revision,
  contentRevision: 1,
  outputLines: 0,
  sizeLocked: false,
  searchRevision: null,
  searchSpans: [],
  columns: line?.length ?? 6,
  rows: 2,
  full: full,
  changedRows: [
    rust.RenderRow(
      index: 0,
      hyperlinks: hyperlinks,
      cells: line != null
          ? [
              for (final value in line.split(''))
                rust.RenderCell(
                  text: value,
                  foreground: 0xffffffff,
                  background: 0xff10151d,
                  flags: 0,
                ),
            ]
          : [
              rust.RenderCell(
                text: '中',
                foreground: 0xffff0000,
                background: 0xff10151d,
                flags: 32,
              ),
              rust.RenderCell(
                text: '',
                foreground: 0xffff0000,
                background: 0xff10151d,
                flags: 64,
              ),
              ...['é', 'a', 'b', 'c'].map(
                (r) => rust.RenderCell(
                  text: r,
                  foreground: 0xffaabbcc,
                  background: 0xff10151d,
                  flags: 0,
                ),
              ),
            ],
    ),
    rust.RenderRow(
      index: 1,
      cells: List.generate(
        line?.length ?? 6,
        (_) => rust.RenderCell(
          text: ' ',
          foreground: 0xffffffff,
          background: 0xff10151d,
          flags: 0,
        ),
      ),
    ),
  ],
  cursorColumn: 0,
  cursorRow: cursorRow,
  cursorVisible: true,
  cursorShape: cursorShape,
  cursorBlink: false,
  cursorColor: 0xffffffff,
  background: 0xff10151d,
  alternateScreen: false,
  mouseReporting: mouse,
  historyLines: 0,
  displayOffset: 0,
);
