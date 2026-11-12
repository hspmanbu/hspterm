import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../src/rust/api.dart' as rust;
import '../src/rust/tmux.dart' as tmx;
import '../src/rust/frb_generated.dart';

Future<void>? _rustInitialization;

/// Share initialization across concurrent callers; FRB is isolate-wide.
Future<void> initializeRust() {
  final pending = _rustInitialization;
  if (pending != null) return pending;
  if (RustLib.instance.initialized) return Future.value();
  return _rustInitialization ??= _loadRust().catchError((
    Object error,
    StackTrace stack,
  ) {
    _rustInitialization = null;
    Error.throwWithStackTrace(error, stack);
  });
}

Future<void> _loadRust() async {
  const override = String.fromEnvironment('HSPTERM_LIBRARY');
  final directory = File(Platform.resolvedExecutable).parent.path;
  final candidates = <String>[
    if (override.isNotEmpty) override,
    if (Platform.isWindows) '$directory/hspterm_frb_bridge.dll',
    if (Platform.isLinux) '$directory/lib/libhspterm_frb_bridge.so',
    if (Platform.isAndroid) 'libhspterm_frb_bridge.so',
    if (Platform.isLinux) '../target/debug/libhspterm_frb_bridge.so',
  ];
  final library = candidates.firstWhere(
    (path) => Platform.isAndroid || File(path).existsSync(),
    orElse: () => throw StateError('找不到 Rust 核心库，请按 README 构建原生程序'),
  );
  await RustLib.init(externalLibrary: ExternalLibrary.open(library));
}

abstract class TerminalBackend {
  Future<int> create();
  Stream<rust.BridgeEvent> watch(int id);
  Future<rust.RenderFrame?> frame(int id);
  Future<void> close(int id);
  Future<void> visible(int id, bool visible);
  Future<void> connect(int id, String profileId);
  Future<void> cancel(int id);
  Future<void> resize(
    int id,
    int columns,
    int rows,
    int cellWidth,
    int cellHeight,
  );
  Future<void> key(int id, rust.KeyboardInput input);
  Future<void> text(int id, String text);
  Future<void> focus(int id, bool focus);
  Future<void> scroll(int id, int lines);
  Future<void> mouse(
    int id,
    int column,
    int row,
    int action,
    int button,
    int mods,
  );
  Future<rust.PasteResult> paste(int id, String text, bool confirmed);
  Future<void> hostKey(int id, int requestId, bool accept);
  Future<tmx.TmuxPrompt> tmuxPrompt(int id, int requestId);
  Future<void> answerTmux(
    int id,
    int generation,
    int requestId,
    tmx.TmuxSelection selection,
  );
  Future<rust.SearchSummary> search(
    int id,
    String query,
    bool regex,
    bool caseSensitive,
  );
  Future<rust.SearchLocation> navigate(int id, int ordinal);
  Future<void> seek(int id, int topRow);
  Future<void> lockSize(int id, bool locked);
  Future<void> clipboardEnabled(int id, bool enabled);
  Future<void> exportHistory(int id, String path);
  Future<rust.TerminalMetrics> metrics(int id);
  Future<void> clipboard(int id, int requestId, String text);
}

abstract interface class TerminalTmuxHistoryBackend {
  Future<String> tmuxHistory(int id, int generation, String? pane, int? offset);
}

abstract interface class TerminalSuggestionsBackend {
  Future<rust.TerminalSuggestions?> suggestions(int id, int generation);
  Future<String> chooseSuggestion(
    int id,
    int generation,
    String ticket,
    int index,
    bool execute,
  );

  /// Round-12 candidate delete: tombstones the command behind the live
  /// ticket/index on every host; stale tickets resolve to false.
  Future<bool> deleteSuggestion(int id, String ticket, int index);
}

abstract interface class TerminalCommandsBackend {
  Future<String> copyCommandAt(
    int id,
    int generation,
    int revision,
    int row,
    int column,
  );
  Future<void> navigateCommand(
    int id,
    int generation,
    int revision,
    int topRow,
    bool next,
  );
}

abstract interface class TerminalReconnectNoticeBackend {
  Future<String?> reconnectNotice(int id);
}

class NativeTerminalBackend
    implements
        TerminalBackend,
        TerminalCommandsBackend,
        TerminalTmuxHistoryBackend,
        TerminalReconnectNoticeBackend,
        TerminalSuggestionsBackend {
  @override
  Future<String> tmuxHistory(
    int id,
    int generation,
    String? pane,
    int? offset,
  ) => rust.terminalTmuxHistory(
    id: id,
    generation: generation,
    pane: pane,
    offset: offset,
  );
  @override
  Future<rust.TerminalSuggestions?> suggestions(int id, int generation) =>
      rust.terminalSuggestions(id: id, generation: generation);
  @override
  Future<String> chooseSuggestion(
    int id,
    int generation,
    String ticket,
    int index,
    bool execute,
  ) => rust.chooseTerminalSuggestion(
    id: id,
    generation: generation,
    ticket: ticket,
    index: index,
    execute: execute,
  );
  @override
  Future<bool> deleteSuggestion(int id, String ticket, int index) async =>
      await rust.deleteTerminalSuggestion(
        id: id,
        ticket: ticket,
        index: index,
      ) !=
      0;
  const NativeTerminalBackend();
  @override
  Future<String?> reconnectNotice(int id) =>
      rust.transferReconnectNotice(id: id);
  @override
  Future<String> copyCommandAt(
    int id,
    int generation,
    int revision,
    int row,
    int column,
  ) => rust.copyTerminalCommandAt(
    id: id,
    generation: generation,
    revision: revision,
    row: row,
    column: column,
  );
  @override
  Future<void> navigateCommand(
    int id,
    int generation,
    int revision,
    int topRow,
    bool next,
  ) => rust.navigateTerminalCommand(
    id: id,
    generation: generation,
    revision: revision,
    topRow: topRow,
    next: next,
  );
  @override
  Future<int> create() => rust.createConfiguredTerminal(
    columns: 80,
    rows: 24,
    defaultHistoryLines: Platform.isAndroid ? 30000 : 100000,
  );
  @override
  Stream<rust.BridgeEvent> watch(int id) => rust.watchEvents(id: id);
  @override
  Future<rust.RenderFrame?> frame(int id) => rust.takeFrame(id: id);
  @override
  Future<void> close(int id) => rust.destroyTerminal(id: id);
  @override
  Future<void> visible(int id, bool value) =>
      rust.setVisible(id: id, visible: value);
  @override
  Future<void> connect(int id, String profileId) =>
      rust.connectTerminal(id: id, profileId: profileId);
  @override
  Future<void> cancel(int id) => rust.cancelConnection(id: id);
  @override
  Future<void> resize(
    int id,
    int columns,
    int rows,
    int cellWidth,
    int cellHeight,
  ) => rust.resizeTerminal(
    id: id,
    columns: columns,
    rows: rows,
    cellWidth: cellWidth,
    cellHeight: cellHeight,
  );
  @override
  Future<void> key(int id, rust.KeyboardInput input) =>
      rust.sendKey(id: id, input: input);
  @override
  Future<void> text(int id, String text) => rust.sendText(id: id, text: text);
  @override
  Future<void> focus(int id, bool focus) =>
      rust.sendFocus(id: id, focused: focus);
  @override
  Future<void> scroll(int id, int lines) =>
      rust.scrollTerminal(id: id, lines: lines);
  @override
  Future<void> mouse(
    int id,
    int column,
    int row,
    int action,
    int button,
    int mods,
  ) => rust.sendMouse(
    id: id,
    column: column,
    row: row,
    action: action,
    button: button,
    mods: mods,
  );
  @override
  Future<rust.PasteResult> paste(int id, String text, bool confirmed) =>
      rust.pasteText(id: id, text: text, confirmed: confirmed);
  @override
  Future<void> hostKey(int id, int requestId, bool accept) =>
      rust.answerHostKey(id: id, requestId: requestId, accept: accept);
  @override
  Future<tmx.TmuxPrompt> tmuxPrompt(int id, int requestId) =>
      rust.terminalTmuxPrompt(id: id, requestId: requestId);
  @override
  Future<void> answerTmux(
    int id,
    int generation,
    int requestId,
    tmx.TmuxSelection selection,
  ) => rust.answerTerminalTmux(
    id: id,
    generation: generation,
    requestId: requestId,
    selection: selection,
  );
  @override
  Future<rust.SearchSummary> search(
    int id,
    String query,
    bool regex,
    bool caseSensitive,
  ) => rust.searchTerminal(
    id: id,
    query: query,
    regularExpression: regex,
    caseSensitive: caseSensitive,
  );
  @override
  Future<rust.SearchLocation> navigate(int id, int ordinal) =>
      rust.navigateSearch(id: id, ordinal: ordinal);
  @override
  Future<void> seek(int id, int topRow) =>
      rust.seekTerminal(id: id, topRow: topRow);
  @override
  Future<void> lockSize(int id, bool locked) =>
      rust.lockTerminalSize(id: id, locked: locked);
  @override
  Future<void> clipboardEnabled(int id, bool enabled) =>
      rust.setClipboardEnabled(id: id, enabled: enabled);
  @override
  Future<void> exportHistory(int id, String path) =>
      rust.exportTerminalHistory(id: id, path: path);
  @override
  Future<rust.TerminalMetrics> metrics(int id) => rust.terminalMetrics(id: id);
  @override
  Future<void> clipboard(int id, int requestId, String text) =>
      rust.answerClipboard(id: id, requestId: requestId, text: text);
}
