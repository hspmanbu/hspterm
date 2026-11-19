import 'paste_editor.dart';
import '../prototype/design.dart';
import 'application_keys.dart';
import 'ime_buffer.dart';
import '../app_notice.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/rust/api.dart' as rust;
import '../run_log.dart';
import 'controller.dart';
import 'suggestions.dart';
import 'suggestions_overlay.dart';
import 'painter.dart';
import 'scrollbar.dart';
import 'tmux_history.dart';
import 'links.dart';
import 'typography.dart';

class TerminalView extends StatefulWidget {
  const TerminalView({
    super.key,
    required this.controller,
    this.fontSize = 15,
    this.typography,
    this.onLocatePath,
    this.onOpenLink,
    this.onPasteImage,
  });
  final TerminalController controller;
  final Future<void> Function()? onPasteImage;
  final double fontSize;
  final TerminalTypography? typography;
  final Future<void> Function(String)? onLocatePath;
  final Future<void> Function(TerminalLink)? onOpenLink;
  @override
  State<TerminalView> createState() => TerminalViewState();
}

class TerminalViewState extends State<TerminalView>
    with WidgetsBindingObserver, TextInputClient {
  final _paintKey = GlobalKey();
  List<double>? _viewportTransform() {
    final box = _paintKey.currentContext?.findRenderObject();
    return box is RenderBox && box.attached
        ? box.getTransformTo(null).storage
        : null;
  }

  final _searchField = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: "terminal search");
  bool _searchOpen = false;
  bool _suppressPassiveMouse = false;
  late TerminalSuggestionsController _suggestions;
  final _suggestionOwned = <PhysicalKeyboardKey>{};
  final _focus = FocusNode(debugLabel: 'SSH terminal');
  final _cache = TerminalPaintCache();
  final _blink = ValueNotifier(true);
  final _preedit = ValueNotifier('');
  final _hoverLink = ValueNotifier<TerminalLink?>(null);
  TextInputConnection? _connection;
  Timer? _blinkTimer;
  bool _active = true, _tickerVisible = true;
  Point<int>? _anchor;
  Point<int>? _pressCell;
  bool _pressPlain = false;
  int _button = 3;
  bool _remoteDrag = false;
  int? _dragMouseModifiers;
  Size _cell = const Size(9, 20);
  static const _empty = TextEditingValue(
    text: '\u200b',
    selection: TextSelection.collapsed(offset: 1),
  );
  final _ime = TerminalImeBuffer();
  TextEditingValue get _editing => _ime.value;

  double get _zoom => c.fontZoom;
  set _zoom(double value) {
    c.fontZoom = value;
  }

  String? _shownOperationError;
  rust.KeyboardInput? _pendingTextKey;
  // Recovery for characters the platform text path dropped (Windows TSF can
  // skip updateEditingValue for the first key after toggling Caps Lock):
  // without a fallback the pending key would be silently overwritten by the
  // next press. The late-update strip keeps delivery exactly-once.
  Timer? _pendingTextTimer;
  int _pendingTextSetMs = 0;
  String? _flushedDirectText;
  int _flushedDirectMs = 0;
  int _inputSeq = 0;
  static const _flushStripWindowMs = 400;
  @visibleForTesting
  static Duration pendingFlushDelay = const Duration(milliseconds: 150);

  /// Metadata-only input diagnostics gate (HSPTERM_INPUT_TRACE=1). Never
  /// records characters, only phases/modifier bits/sequence numbers.
  @visibleForTesting
  static bool traceInput = Platform.environment['HSPTERM_INPUT_TRACE'] == '1';
  @visibleForTesting
  static int Function() debugNowMs = () =>
      DateTime.now().millisecondsSinceEpoch;
  TerminalController get c => widget.controller;

  /// Grid cell size in logical pixels; tests use it to aim pointer events.
  @visibleForTesting
  Size get cellSize => _cell;

  void _traceInput(String phase, {int? kind}) {
    if (!traceInput) return;
    AppRunLog.instance.event(
      AppLogEvent.inputTrace,
      terminal: c.id,
      count: ++_inputSeq,
      fields: {'result': phase, 'kind': ?kind},
    );
  }

  /// Sends a still-pending printable key straight to the terminal because the
  /// platform text path never delivered it. Arms a one-shot strip marker so a
  /// late updateEditingValue for the same character is deduplicated.
  void _deliverPendingDirect(rust.KeyboardInput input, String reason) {
    _pendingTextKey = null;
    _pendingTextTimer?.cancel();
    _pendingTextTimer = null;
    _flushedDirectText = input.text;
    _flushedDirectMs = debugNowMs();
    _traceInput('direct-$reason');
    _snapToBottomForInput();
    _run(c.key(input));
  }

  /// Flushes a stale pending key before a new one replaces it. The minimum
  /// age keeps IME composition starts (which arrive within a frame) the owner
  /// of their key; a dropped WM_CHAR never arrives at any age.
  void _flushStalePendingTextKey() {
    final stale = _pendingTextKey;
    if (stale == null || _ime.composing) return;
    if (debugNowMs() - _pendingTextSetMs < 30) return;
    _deliverPendingDirect(stale, 'stale');
  }

  void _onPendingTextTimer() {
    _pendingTextTimer = null;
    final pending = _pendingTextKey;
    if (pending == null) return;
    _deliverPendingDirect(pending, 'timer');
    _syncSuggestions();
  }

  void _cancelPendingTextKey() {
    if (_pendingTextKey != null) _traceInput('reset');
    _pendingTextKey = null;
    _pendingTextTimer?.cancel();
    _pendingTextTimer = null;
    _flushedDirectText = null;
  }

  TerminalTypography get _typography =>
      (widget.typography ?? TerminalTypography(size: widget.fontSize)).copyWith(
        size: ((widget.typography?.size ?? widget.fontSize) + _zoom).clamp(
          9,
          36,
        ),
      );
  void focusTerminal() => _focus.requestFocus();

  Map<String, int> get debugCacheStats => {
    "paints": _cache.paints,
    "row_builds": _cache.rowBuilds,
    "glyphs": _cache.glyphCount,
    "row_pictures": _cache.rowCount,
  };
  void _run(Future<void> future) => unawaited(future.catchError(c.report));

  /// Every input path assumes the user is typing at the live prompt, so a
  /// view scrolled back into history snaps to the bottom with exactly the
  /// semantics of the回底 button. Scrollback navigation, wheel paging, page
  /// keys and suggestion navigation never call this. A tmux read-only viewer
  /// never snaps: the controller interceptor may swallow the input, and a
  /// read-only attach ignores it remotely anyway.
  void _snapToBottomForInput() {
    final f = c.metadata;
    if (f == null ||
        f.displayOffset == 0 ||
        f.alternateScreen ||
        !c.connected) {
      return;
    }
    if (c.tmuxReadonly == true) return;
    _run(c.seek(f.historyLines));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focus.addListener(_focusChanged);
    _searchFocus.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        hideSearch();
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.enter) {
        _run(
          c.navigateSearch(HardwareKeyboard.instance.isShiftPressed ? -1 : 1),
        );
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    c.addListener(_changed);
    _suggestions = TerminalSuggestionsController(c);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerVisible = TickerMode.valuesOf(context).enabled;
    _visibility();
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      oldWidget.controller.composing = false;
      oldWidget.controller.removeListener(_changed);
      _suggestions.dispose();
      _suggestions = TerminalSuggestionsController(c);
      c.addListener(_changed);
      _cache.clear();
      _cancelPendingTextKey();
      _ime.reset();
      c.composing = false;
      _preedit.value = '';
      _connection?.setEditingState(_empty);
      _visibility();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop focus loss reports `inactive`: the window is still on screen,
    // so the terminal keeps rendering (2026-11-06 feedback — a blank pane on
    // blur looked broken). Only genuinely hidden states stop painting.
    _active =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _visibility();
  }

  void _visibility() {
    _run(c.setVisible(_active && _tickerVisible));
    _changed();
  }

  void _syncSuggestions() {
    final f = c.metadata;
    _suggestions.setWanted(
      _focus.hasFocus &&
          _active &&
          _tickerVisible &&
          c.visible &&
          c.connected &&
          !_searchOpen &&
          _pendingTextKey == null &&
          !(_editing.composing.isValid && !_editing.composing.isCollapsed) &&
          f != null &&
          f.displayOffset == 0 &&
          !f.alternateScreen &&
          !f.mouseReporting,
    );
  }

  /// Round-12 candidate delete from the overlay row button.
  Future<void> _deleteSuggestion(int index, String ticket) async {
    final deleted = await _suggestions.deleteCandidate(index);
    if (!mounted || !deleted) return;
    showAppNotice(context, '已删除该历史记录', level: AppNoticeLevel.success);
  }

  Future<void> _chooseSuggestion(
    bool execute, {
    int? index,
    String? ticket,
  }) async {
    final result = await _suggestions.choose(
      execute: execute,
      index: index,
      expectedTicket: ticket,
    );
    if (!mounted || result == 'Applied') return;
    showAppNotice(
      context,
      result == 'Unavailable'
          ? '普通Shell输入状态已改变，未发送候选。请继续正常输入。'
          : '候选提交结果未确认，请检查终端；未自动重试。',
      level: AppNoticeLevel.warning,
    );
  }

  void _changed() {
    if (c.error == null) _shownOperationError = null;
    if (c.connected && c.error != null && c.error != _shownOperationError) {
      final message = c.error!;
      _shownOperationError = message;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !c.connected || c.error != message) return;
        showAppNotice(context, message, level: AppNoticeLevel.error);
        c.dismissError(message);
        _shownOperationError = null;
      });
    }
    _syncSuggestions();
    _hoverLink.value = null;
    final f = c.metadata;
    final animate =
        c.visible &&
        _focus.hasFocus &&
        f != null &&
        f.cursorVisible &&
        f.cursorBlink &&
        f.cursorRow >= 0 &&
        f.cursorRow < f.rows;
    if (animate && _blinkTimer == null) {
      _blinkTimer = Timer.periodic(
        const Duration(milliseconds: 600),
        (_) => _blink.value = !_blink.value,
      );
    }
    if (!animate) {
      _blinkTimer?.cancel();
      _blinkTimer = null;
      _blink.value = true;
    }
    _syncImeGeometry(f);
  }

  /// Reports the terminal caret to the platform IME. The composing rect is the
  /// one Windows uses to place the candidate window: anchor it on the line
  /// below the cursor so candidates appear under the composed text. The caret
  /// rect stays for the macOS accent menu.
  void _syncImeGeometry(rust.RenderFrame? f) {
    if (!(_connection?.attached ?? false)) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    _connection!.setEditableSizeAndTransform(
      box.size,
      box.getTransformTo(null),
    );
    if (f == null) return;
    final row = f.cursorRow.clamp(0, f.rows - 1);
    _connection!.setCaretRect(
      Rect.fromLTWH(
        f.cursorColumn * _cell.width,
        row * _cell.height,
        _cell.width,
        _cell.height,
      ),
    );
    _connection!.setComposingRect(
      Rect.fromLTWH(
        f.cursorColumn * _cell.width,
        (row + 1) * _cell.height,
        _cell.width,
        _cell.height,
      ),
    );
  }

  void _focusChanged() {
    if (_focus.hasFocus) {
      _ime.reset();
      c.composing = false;
      _preedit.value = '';
      _connection = TextInput.attach(
        this,
        TextInputConfiguration(
          // Windows rejects setClient with a null viewId before creating its
          // text model. Control keys still work, hiding the missing IME client.
          viewId: View.of(context).viewId,
          inputType: TextInputType.text,
          inputAction: TextInputAction.done,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
        ),
      );
      _connection!
        ..setEditingState(_editing)
        ..show();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (_connection?.attached ?? false)) {
          _syncImeGeometry(c.metadata);
        }
      });
    } else {
      _connection?.close();
      _connection = null;
      c.composing = false;
      _preedit.value = '';
      // A keystroke pending only its platform delivery is stale once focus
      // leaves; recovering it later would type into an unfocused terminal.
      _cancelPendingTextKey();
    }
    final id = c.id;
    if (id != null && c.connected) _run(c.focus(_focus.hasFocus));
    _changed();
    if (mounted) setState(() {});
  }

  int get _mods =>
      (HardwareKeyboard.instance.isShiftPressed ? 1 : 0) |
      (HardwareKeyboard.instance.isAltPressed ? 2 : 0) |
      (HardwareKeyboard.instance.isControlPressed ? 4 : 0) |
      (HardwareKeyboard.instance.isMetaPressed ? 8 : 0) |
      (HardwareKeyboard.instance.lockModesEnabled.contains(
            KeyboardLockMode.capsLock,
          )
          ? 64
          : 0) |
      (HardwareKeyboard.instance.lockModesEnabled.contains(
            KeyboardLockMode.numLock,
          )
          ? 128
          : 0);
  static final _keys = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.shiftLeft: 'ShiftLeft',
    LogicalKeyboardKey.controlLeft: 'ControlLeft',
    LogicalKeyboardKey.altLeft: 'AltLeft',
    LogicalKeyboardKey.metaLeft: 'MetaLeft',
    LogicalKeyboardKey.shiftRight: 'ShiftRight',
    LogicalKeyboardKey.controlRight: 'ControlRight',
    LogicalKeyboardKey.altRight: 'AltRight',
    LogicalKeyboardKey.metaRight: 'MetaRight',
    LogicalKeyboardKey.capsLock: 'CapsLock',
    LogicalKeyboardKey.numLock: 'NumLock',
    LogicalKeyboardKey.scrollLock: 'ScrollLock',
    LogicalKeyboardKey.enter: 'Enter',
    LogicalKeyboardKey.numpadEnter: 'Enter',
    LogicalKeyboardKey.tab: 'Tab',
    LogicalKeyboardKey.escape: 'Escape',
    LogicalKeyboardKey.backspace: 'Backspace',
    LogicalKeyboardKey.delete: 'Delete',
    LogicalKeyboardKey.insert: 'Insert',
    LogicalKeyboardKey.arrowUp: 'ArrowUp',
    LogicalKeyboardKey.arrowDown: 'ArrowDown',
    LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
    LogicalKeyboardKey.arrowRight: 'ArrowRight',
    LogicalKeyboardKey.home: 'Home',
    LogicalKeyboardKey.end: 'End',
    LogicalKeyboardKey.pageUp: 'PageUp',
    LogicalKeyboardKey.pageDown: 'PageDown',
    LogicalKeyboardKey.f1: 'F1',
    LogicalKeyboardKey.f2: 'F2',
    LogicalKeyboardKey.f3: 'F3',
    LogicalKeyboardKey.f4: 'F4',
    LogicalKeyboardKey.f5: 'F5',
    LogicalKeyboardKey.f6: 'F6',
    LogicalKeyboardKey.f7: 'F7',
    LogicalKeyboardKey.f8: 'F8',
    LogicalKeyboardKey.f9: 'F9',
    LogicalKeyboardKey.f10: 'F10',
    LogicalKeyboardKey.f11: 'F11',
    LogicalKeyboardKey.f12: 'F12',
  };
  bool _isModifier(LogicalKeyboardKey key) => {
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  }.contains(key);

  /// Plain caret-only movement (arrows/Home/End, no modifiers) never edits
  /// the remote Readline line, so the candidate prefix is still exact and the
  /// native proof survives it. Hiding here could never be undone: no input
  /// revision changes, so no reload would bring the box back.
  bool _caretOnlyKey(LogicalKeyboardKey key, int mods) =>
      mods == 0 &&
      (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.home ||
          key == LogicalKeyboardKey.end);
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final mods = _mods, down = event is! KeyUpEvent, key = event.logicalKey;
    if (down && !_isModifier(key) && key != LogicalKeyboardKey.escape) {
      _suppressPassiveMouse = false;
    }
    // Any fresh press first recovers a character the platform dropped, so a
    // following Enter/Backspace cannot overtake it.
    if (event is KeyDownEvent) _flushStalePendingTextKey();
    final composing =
        _editing.composing.isValid && !_editing.composing.isCollapsed;
    final local = ApplicationKeyScope.terminal(
      context,
      event,
      composing: composing,
    );
    if (local != KeyEventResult.ignored) {
      if (event is KeyUpEvent) _suggestionOwned.remove(event.physicalKey);
      return local;
    }
    if (event is KeyUpEvent && _suggestionOwned.remove(event.physicalKey)) {
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent &&
        _suggestionOwned.contains(event.physicalKey)) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) _suggestionOwned.remove(event.physicalKey);
    final suggestionKeys =
        !composing &&
        mods == 0 &&
        _suggestions.showing &&
        {
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.tab,
          LogicalKeyboardKey.escape,
        }.contains(key);
    // Enter/Tab keep their normal shell meaning (submit / readline completion)
    // while no candidate is explicitly selected; only arrows/Esc own the box.
    final commitKey =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab;
    if (suggestionKeys && (!commitKey || _suggestions.selected >= 0)) {
      if (down) {
        ApplicationKeyScope.claim(context, event);
        _suggestionOwned.add(event.physicalKey);
        if (key == LogicalKeyboardKey.arrowUp) {
          _suggestions.move(-1);
        } else if (key == LogicalKeyboardKey.arrowDown) {
          _suggestions.move(1);
        } else if (key == LogicalKeyboardKey.escape) {
          _suggestions.dismiss();
        } else {
          _run(_chooseSuggestion(key != LogicalKeyboardKey.tab));
        }
      }
      return KeyEventResult.handled;
    }
    if (down && !_isModifier(key) && !_caretOnlyKey(key, mods)) {
      _suggestions.inputChanged();
    }
    if (composing && mods & 6 == 0) return KeyEventResult.ignored;
    if (!composing &&
        widget.onPasteImage != null &&
        c.imagePasteBinding.matches(event)) {
      if (event is KeyDownEvent) {
        ApplicationKeyScope.claim(context, event);
        _run(widget.onPasteImage!());
      }
      return KeyEventResult.handled;
    }
    if (mods & 4 != 0 &&
            mods & 1 != 0 &&
            (key == LogicalKeyboardKey.keyC ||
                key == LogicalKeyboardKey.keyV) ||
        mods & 1 != 0 && key == LogicalKeyboardKey.insert) {
      if (down) {
        if (key == LogicalKeyboardKey.keyC) {
          _run(copy());
        } else {
          _run(paste());
        }
      }
      return KeyEventResult.handled;
    }
    if (mods & 63 == 4 &&
        key == LogicalKeyboardKey.keyC &&
        c.selectedText().isNotEmpty) {
      if (down) _run(copy());
      return KeyEventResult.handled;
    }
    if (mods & 63 == 1 &&
        (key == LogicalKeyboardKey.pageUp ||
            key == LogicalKeyboardKey.pageDown)) {
      if (down && c.id != null) {
        _run(
          c.scroll(
            (key == LogicalKeyboardKey.pageUp ? 1 : -1) *
                (c.metadata?.rows ?? 24),
          ),
        );
      }
      return KeyEventResult.handled;
    }
    if (down &&
        !composing &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      _ime.reset();
      _connection?.setEditingState(_empty);
    }
    final special = _keys[key];
    if (down && key == LogicalKeyboardKey.escape) {
      // Interrupts can leave the remote app briefly accepting plain input
      // before its mouse modes are reset. Do not interleave unsolicited SGR
      // hover reports with Escape; a fresh intentional action restores them.
      _suppressPassiveMouse = true;
    }
    final label = key.keyLabel.toLowerCase();
    if (special == null && label.runes.length != 1) {
      return KeyEventResult.ignored;
    }
    if (special == null && mods & 14 == 0 && down) {
      _pendingTextKey = rust.KeyboardInput(
        key: label,
        text: event.character ?? (key == LogicalKeyboardKey.space ? ' ' : null),
        modifiers: mods,
        kind: event is KeyRepeatEvent ? 1 : 0,
        shifted: event.character,
        base: label,
      );
      _pendingTextSetMs = debugNowMs();
      _pendingTextTimer?.cancel();
      _pendingTextTimer = Timer(pendingFlushDelay, _onPendingTextTimer);
      _traceInput('set', kind: mods);
      _syncSuggestions();
      return key == LogicalKeyboardKey.space
          ? KeyEventResult.skipRemainingHandlers
          : KeyEventResult.ignored;
    }
    if (_isModifier(key) && event is KeyDownEvent) {
      final target = c, id = c.id, generation = c.generation;
      ApplicationKeyScope.forwardedModifier(context, event, (release) {
        if (!target.connected ||
            target.id != id ||
            target.generation != generation) {
          return;
        }
        unawaited(
          target
              .key(rust.KeyboardInput(key: special!, modifiers: _mods, kind: 2))
              .catchError(target.report),
        );
      });
    }
    // The main key path snaps for real input only: no key-up (kind 2) and
    // no bare modifier press/release.
    if (event is! KeyUpEvent && !_isModifier(key)) _snapToBottomForInput();
    _run(
      c.key(
        rust.KeyboardInput(
          key: special ?? label,
          text: event.character,
          modifiers: mods,
          kind: event is KeyUpEvent
              ? 2
              : event is KeyRepeatEvent
              ? 1
              : 0,
          shifted: event.character,
          base: label.runes.length == 1 ? label : null,
        ),
      ),
    );
    return KeyEventResult.handled;
  }

  Future<void> copy() async {
    final text = c.selectedText();
    if (text.isNotEmpty) await Clipboard.setData(ClipboardData(text: text));
  }

  void _copySelectionIfWanted() {
    if (!c.copyOnSelection) return;
    final text = c.selectedText();
    if (text.isEmpty || text.trim().isEmpty) return;
    _run(Clipboard.setData(ClipboardData(text: text)));
  }

  Future<void> paste() async {
    final source = c, id = c.id, generation = c.generation;
    bool current() =>
        mounted &&
        identical(source, c) &&
        source.id == id &&
        source.generation == generation &&
        source.connected;
    if (id == null || !current()) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!current()) return;
    final text = data?.text;
    if (text == null || text.isEmpty) {
      await widget.onPasteImage?.call();
      return;
    }
    final result = await source.paste(text, false);
    if (!result.needsConfirmation && current()) _snapToBottomForInput();
    if (!mounted || !result.needsConfirmation || !current()) return;
    final confirmed = await showAppDialog<String>(
      context: context,
      builder: (_) => TerminalPastePreview(
        text: text,
        target: source.connectionLabel,
        lines: result.lines,
        bytes: result.bytes,
      ),
    );
    if (confirmed != null && current()) {
      await source.paste(confirmed, true);
      _snapToBottomForInput();
    }
  }

  Point<int> _point(Offset position) => Point(
    (position.dx / _cell.width).floor().clamp(
      0,
      (c.metadata?.columns ?? 80) - 1,
    ),
    (position.dy / _cell.height).floor().clamp(0, (c.metadata?.rows ?? 24) - 1),
  );
  bool get _capture =>
      c.metadata?.mouseReporting == true && _mods & 1 == 0 && c.connected;
  void _mouse(Offset position, int action, int button) {
    if (action == 0 || action == 3 || action == 4) {
      _suppressPassiveMouse = false;
    }
    if (_suppressPassiveMouse && action == 2 && button == 3) return;
    final id = c.id;
    final p = _point(position);
    if (id != null && c.connected) {
      _run(
        c.mouse(
          p.x,
          p.y,
          action,
          button,
          _remoteDrag ? (_dragMouseModifiers ?? _mods) : _mods,
        ),
      );
    }
  }

  /// Remote mouse forwarding only while the capture is credible: with the
  /// plain-shell proof ready, leftover TUI mouse mode gets no events.
  bool get _forwardRemoteMouse => _capture && !c.shellInputReady;

  /// nyaterm-style caret placement for plain shells: without mouse
  /// reporting, a plain primary click (no shift, no drag) on the cursor's
  /// own row replays ArrowLeft/ArrowRight so the remote REPL (bash, zsh,
  /// hermes CLI, …) walks its caret to the clicked cell. Wide glyphs count
  /// one step and clicks on their trailing spacer snap to the glyph's
  /// lead, mirroring how a caret actually moves through CJK text.
  void _clickToCursor(Point<int> cell) {
    final frame = c.metadata;
    if (frame == null || !c.connected || c.id == null) return;
    if (frame.mouseReporting || frame.alternateScreen) return;
    final cursorRow = frame.cursorRow;
    if (cell.y != cursorRow) return;
    if (cursorRow < 0 || cursorRow >= c.rows.length) return;
    final cells = c.rows[cursorRow];
    if (cells.isEmpty) return;
    // A click or a caret on a wide glyph's trailing half belongs to the
    // glyph's lead cell; the Rust core already snaps the reported cursor
    // column, this also defends frames from an older core.
    int snap(int column) {
      var c = column;
      if (c < 0) c = 0;
      if (c >= cells.length) c = cells.length - 1;
      return cells[c].flags & 64 != 0 && c > 0 ? c - 1 : c;
    }
    final target = snap(cell.x);
    final cursor = snap(frame.cursorColumn);
    var steps = 0;
    for (var x = min(cursor, target); x < max(cursor, target); x++) {
      // Wide leads are one character; their trailing spacers (64) and
      // wrap markers (1024) are not characters of their own.
      if (cells[x].flags & (64 | 1024) == 0) steps++;
    }
    if (steps == 0) return;
    _snapToBottomForInput();
    final key = target > cursor ? 'ArrowRight' : 'ArrowLeft';
    for (var i = 0; i < steps; i++) {
      _run(c.key(rust.KeyboardInput(key: key, modifiers: 0, kind: 0)));
    }
  }

  void down(PointerDownEvent event) {
    _suppressPassiveMouse = false;
    _suggestions.dismiss();
    _focus.requestFocus();
    _button = event.buttons & kPrimaryMouseButton != 0
        ? 0
        : event.buttons & kMiddleMouseButton != 0
        ? 1
        : 2;
    // Right-click paste stays local even while the remote reports mouse
    // events: TUI programs almost never bind button 3, and terminal users
    // expect right-click paste in CLI tools like codex. Shift+right-click
    // still opens the local menu path below.
    if (_capture && _button == 2 && c.rightClickPaste && _mods & 1 == 0) {
      _anchor = null;
      _run(paste());
      return;
    }
    final tmuxLocal =
        c.tmuxReadonly != null &&
        c.tmuxLocalSelection &&
        _button == 0 &&
        !HardwareKeyboard.instance.isAltPressed &&
        _point(event.localPosition).x < (c.metadata?.columns ?? 80) - 2;
    _remoteDrag = _forwardRemoteMouse && !tmuxLocal;
    // Alt is the local selection override here, not an application modifier.
    // Keep the choice for the whole gesture, including release after Alt-up.
    _dragMouseModifiers =
        c.tmuxReadonly != null &&
            c.tmuxLocalSelection &&
            _button == 0 &&
            HardwareKeyboard.instance.isAltPressed
        ? _mods & ~2
        : _mods;
    if (_remoteDrag) {
      _mouse(event.localPosition, 0, _button);
      return;
    }
    final point = _point(event.localPosition);
    final link = TerminalLink.atGrid(
      c.rows,
      point.y,
      point.x,
      hyperlinks: c.hyperlinks,
    );
    if (_button == 0 &&
        HardwareKeyboard.instance.isControlPressed &&
        link != null &&
        (link.canForward ||
            link.uri != null ||
            link.remoteFileUri != null ||
            link.remotePath != null) &&
        widget.onOpenLink != null) {
      _anchor = null;
      _button = 3;
      _run(widget.onOpenLink!(link));
      return;
    }
    if (_button == 0) {
      _anchor = _point(event.localPosition);
      // Remember the plain press for caret placement on release; the
      // no-shift requirement is captured once, for the whole gesture.
      _pressCell = _anchor;
      _pressPlain = _mods & 1 == 0;
      c.clearSelection();
    }
    if (_button == 2) {
      if (c.rightClickPaste && _mods & 1 == 0) {
        _anchor = null;
        _run(paste());
        return;
      }
      final source = c, generation = c.generation, terminalId = c.id;
      final commandFrame = c.metadata;
      final commandRow = commandFrame == null
          ? null
          : commandFrame.historyLines - commandFrame.displayOffset + point.y;
      final selectedPath = c.selectedText();
      final locate = widget.onLocatePath;
      final openLink = widget.onOpenLink;
      final selectedReference = TerminalLink.parse(selectedPath);
      showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(
          event.position.dx,
          event.position.dy,
          event.position.dx,
          event.position.dy,
        ),
        items: [
          const PopupMenuItem(value: 'copy', child: Text('复制')),
          const PopupMenuItem(value: 'paste', child: Text('粘贴')),
          const PopupMenuItem(value: 'search', child: Text('搜索终端历史')),
          if (c.commandOperationsAvailable && commandFrame != null) ...[
            const PopupMenuItem(
              value: 'commandCopy',
              child: Text('复制所在命令的输出（OSC133）'),
            ),
            const PopupMenuItem(
              value: 'commandPrevious',
              child: Text('上一命令标记'),
            ),
            const PopupMenuItem(value: 'commandNext', child: Text('下一命令标记')),
          ],
          if (link != null) ...[
            const PopupMenuItem(value: 'copyLink', child: Text('复制链接文本')),
            if (link.address.isNotEmpty)
              const PopupMenuItem(
                value: 'copyAddress',
                child: Text('复制 IP / 地址'),
              ),
            if (openLink != null &&
                (link.canForward ||
                    link.uri != null ||
                    link.remoteFileUri != null ||
                    link.remotePath != null))
              PopupMenuItem(
                value: 'openLink',
                child: Text(
                  link.remoteFileUri != null
                      ? '在关联 SFTP 中定位文件链接'
                      : link.remotePath != null
                      ? '在关联 SFTP 中定位路径…'
                      : link.canForward
                      ? '确认后临时转发'
                      : '确认后打开链接',
                ),
              ),
          ],
          if (openLink != null &&
              selectedReference?.remotePath?.hasLocation == true &&
              c.connected)
            const PopupMenuItem(
              value: 'locateReference',
              child: Text('定位选中路径（含行列提示）…'),
            ),
          if (locate != null && selectedPath.isNotEmpty && c.connected)
            const PopupMenuItem(value: 'locate', child: Text('在关联 SFTP 中定位')),
        ],
      ).then((v) {
        if (!mounted ||
            !identical(source, c) ||
            generation != c.generation ||
            terminalId != c.id) {
          return;
        }
        if (v == 'locateReference' &&
            selectedReference != null &&
            openLink != null) {
          _run(openLink(selectedReference));
        }
        if (v == 'search') showSearch();
        if (v == 'copy') _run(copy());
        if (v == 'paste') _run(paste());
        if (commandFrame != null && commandRow != null) {
          if (v == 'commandCopy') {
            _run(() async {
              final text = await source.copyCommandAt(
                commandRow,
                point.x,
                commandFrame.contentRevision,
              );
              if (text != null &&
                  mounted &&
                  identical(source, c) &&
                  generation == c.generation &&
                  terminalId == c.id) {
                await Clipboard.setData(ClipboardData(text: text));
              }
            }());
          }
          if (v == 'commandPrevious' || v == 'commandNext') {
            _run(
              source.navigateCommand(
                v == 'commandNext',
                commandFrame.historyLines - commandFrame.displayOffset,
                commandFrame.contentRevision,
              ),
            );
          }
        }
        if (link != null && v == 'copyLink') {
          _run(Clipboard.setData(ClipboardData(text: link.text)));
        }
        if (link != null && v == 'copyAddress') {
          _run(Clipboard.setData(ClipboardData(text: link.address)));
        }
        if (v == 'openLink' && link != null && openLink != null) {
          _run(openLink(link));
        }
        if (v == 'locate' && locate != null) {
          _run(Future<void>.sync(() => locate(selectedPath)));
        }
      });
    }
  }

  void showSearch() {
    _suggestions.setWanted(false);
    setState(() => _searchOpen = true);
    _searchFocus.requestFocus();
  }

  void hideSearch() {
    setState(() => _searchOpen = false);
    _run(c.setSearch(''));
    _focus.requestFocus();
  }

  Future<void> exportHistory() async {
    final editor = TextEditingController();
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('导出当前终端历史'),
        content: TextField(
          controller: editor,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '保存为 UTF-8 文件路径',
            helperText: '只写入新文件；不自动覆盖已有文件。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导出'),
          ),
        ],
      ),
    );
    final path = editor.text;
    editor.dispose();
    final id = c.id;
    if (confirmed == true && id != null && path.isNotEmpty) {
      try {
        await c.backend.exportHistory(id, path);
      } catch (error) {
        c.report(error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final typography = _typography;
    final metric = TextPainter(
      text: TextSpan(text: 'M', style: typography.textStyle()),
      textDirection: TextDirection.ltr,
    )..layout();
    _cell = Size(
      max(1.0, metric.width),
      max(1.0, (typography.size * typography.lineHeight).ceilToDouble()),
    );
    metric.dispose();
    return LayoutBuilder(
      builder: (context, constraints) {
        c.resize(
          ((constraints.maxWidth - 12) / _cell.width).floor(),
          (constraints.maxHeight / _cell.height).floor(),
          _cell.width,
          _cell.height,
        );
        return Stack(
          children: [
            Positioned.fill(
              right: 12,
              child: Focus(
                focusNode: _focus,
                onKeyEvent: _key,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: down,
                  onPointerUp: (e) {
                    if (_remoteDrag) _mouse(e.localPosition, 1, _button);
                    _remoteDrag = false;
                    // A finished primary-button drag selects; honor the
                    // select-to-copy preference unless it is all whitespace.
                    final pressCell = _pressCell;
                    final plainPress =
                        _button == 0 && pressCell != null && _pressPlain;
                    _pressCell = null;
                    final selected = _anchor != null && _button == 0;
                    _anchor = null;
                    _button = 3;
                    if (selected) _copySelectionIfWanted();
                    // A no-drag plain click on the cursor's row becomes
                    // caret movement instead of an empty selection.
                    if (plainPress && pressCell == _point(e.localPosition)) {
                      _clickToCursor(pressCell);
                    }
                  },
                  onPointerCancel: (e) {
                    if (_remoteDrag) _mouse(e.localPosition, 1, _button);
                    _remoteDrag = false;
                    _anchor = null;
                    _pressCell = null;
                    _button = 3;
                  },
                  onPointerMove: (e) {
                    if (_remoteDrag) {
                      _mouse(e.localPosition, 2, _button);
                    } else if (_anchor != null) {
                      c.select(_anchor!, _point(e.localPosition));
                    } else if (_forwardRemoteMouse) {
                      _mouse(e.localPosition, 2, _button);
                    }
                  },
                  onPointerHover: (e) {
                    if (_forwardRemoteMouse) {
                      _mouse(e.localPosition, 2, 3);
                    } else {
                      final point = _point(e.localPosition);
                      _hoverLink.value = TerminalLink.atGrid(
                        c.rows,
                        point.y,
                        point.x,
                        hyperlinks: c.hyperlinks,
                      );
                    }
                  },
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
                      GestureBinding.instance.pointerSignalResolver.register(
                        e,
                        (event) {
                          if (HardwareKeyboard.instance.isControlPressed) {
                            setState(
                              () => _zoom =
                                  (_typography.size +
                                          (e.scrollDelta.dy < 0 ? 1 : -1))
                                      .clamp(9, 36) -
                                  (widget.typography?.size ?? widget.fontSize),
                            );
                          } else if (_forwardRemoteMouse) {
                            _mouse(
                              e.localPosition,
                              e.scrollDelta.dy < 0 ? 3 : 4,
                              3,
                            );
                          } else if (c.id != null) {
                            _run(c.scroll(e.scrollDelta.dy < 0 ? 3 : -3));
                          }
                        },
                      );
                    }
                  },
                  child: ValueListenableBuilder<TerminalLink?>(
                    valueListenable: _hoverLink,
                    builder: (_, link, child) => MouseRegion(
                      onExit: (_) => _hoverLink.value = null,
                      cursor: link != null && widget.onOpenLink != null
                          ? SystemMouseCursors.click
                          : SystemMouseCursors.basic,
                      child: Tooltip(message: link?.text ?? '', child: child!),
                    ),
                    child: RepaintBoundary(
                      child: CustomPaint(
                        key: _paintKey,
                        painter: TerminalPainter(
                          c,
                          _cache,
                          typography.size,
                          _cell,
                          _blink,
                          _focus.hasFocus,
                          _preedit,
                          typography: typography,
                          devicePixelRatio: MediaQuery.devicePixelRatioOf(
                            context,
                          ),
                          viewportTransform: _viewportTransform,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: 12,
              child: c.tmuxReadonly == null
                  ? HistoryScrollbar(controller: c)
                  : TmuxHistoryScrollbar(controller: c),
            ),
            TerminalSuggestionsOverlay(
              controller: _suggestions,
              viewport: Size(constraints.maxWidth, constraints.maxHeight),
              cell: _cell,
              cursorColumn: c.metadata?.cursorColumn ?? 0,
              cursorRow: c.metadata?.cursorRow ?? 0,
              choose: (index, ticket) =>
                  _run(_chooseSuggestion(true, index: index, ticket: ticket)),
              delete: (index, ticket) => _run(_deleteSuggestion(index, ticket)),
            ),
            if (_searchOpen)
              Positioned(
                top: 0,
                right: 16,
                left: constraints.maxWidth > 700
                    ? constraints.maxWidth - 650
                    : 0,
                child: Material(
                  elevation: 4,
                  color: const Color(0xff263445),
                  child: ListenableBuilder(
                    listenable: c,
                    builder: (context, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const ValueKey('terminal-search-field'),
                                controller: _searchField,
                                focusNode: _searchFocus,
                                autofocus: true,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  labelText: '当前终端搜索',
                                ),
                                onChanged: (value) => _run(c.setSearch(value)),
                                onSubmitted: (_) => _run(c.navigateSearch(1)),
                              ),
                            ),
                            IconButton(
                              tooltip: '正则表达式',
                              isSelected: c.searchRegex,
                              onPressed: () => _run(
                                c.setSearch(
                                  _searchField.text,
                                  regex: !c.searchRegex,
                                ),
                              ),
                              icon: const Text('.*'),
                            ),
                            IconButton(
                              tooltip: '区分大小写',
                              isSelected: c.searchCaseSensitive,
                              onPressed: () => _run(
                                c.setSearch(
                                  _searchField.text,
                                  caseSensitive: !c.searchCaseSensitive,
                                ),
                              ),
                              icon: const Text('Aa'),
                            ),
                            Text(
                              c.searchBusy
                                  ? '搜索中…'
                                  : '${c.activeSearch == null ? 0 : c.searchOrdinal + 1}/${c.searchSummary?.count ?? 0}',
                            ),
                            IconButton(
                              tooltip: '上一个匹配',
                              onPressed: () => _run(c.navigateSearch(-1)),
                              icon: const Icon(Icons.keyboard_arrow_up),
                            ),
                            IconButton(
                              tooltip: '下一个匹配',
                              onPressed: () => _run(c.navigateSearch(1)),
                              icon: const Icon(Icons.keyboard_arrow_down),
                            ),
                            IconButton(
                              tooltip: '关闭搜索',
                              onPressed: hideSearch,
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        if (c.searchError != null)
                          Text(
                            c.searchError!,
                            style: const TextStyle(color: Colors.orangeAccent),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned(
              right: 28,
              bottom: 8,
              child: ListenableBuilder(
                listenable: c,
                builder: (context, _) => c.newOutputLines > 0
                    ? FilledButton.tonal(
                        onPressed: () => _run(c.seek(c.metadata!.historyLines)),
                        child: Text('${c.newOutputLines} 行新输出 · 回到底部'),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  TextEditingValue get currentTextEditingValue => _editing;
  @override
  AutofillScope? get currentAutofillScope => null;
  @override
  void updateEditingValue(TextEditingValue value) {
    if (!_focus.hasFocus || !(_connection?.attached ?? false)) return;
    final change = _ime.update(value);
    c.composing = _ime.composing;
    _suggestions.inputChanged();
    _preedit.value = change.preedit;
    var text = change.text;
    if (text.isNotEmpty) _suppressPassiveMouse = false;
    final flushed = _flushedDirectText;
    _flushedDirectText = null;
    if (flushed != null &&
        text.startsWith(flushed) &&
        debugNowMs() - _flushedDirectMs <= _flushStripWindowMs) {
      // The platform delivered (late) a character the fallback already sent
      // directly; strip it so the terminal receives exactly one copy.
      text = text.substring(flushed.length);
      _traceInput('strip', kind: text.runes.length);
    }
    final pending = _pendingTextKey;
    _pendingTextKey = null;
    _pendingTextTimer?.cancel();
    _pendingTextTimer = null;
    // A deletion or committed edit is real input at the prompt: snap a
    // scrolled-back view down before the bytes go out.
    if (change.erase > 0 || text.isNotEmpty) _snapToBottomForInput();
    for (var i = 0; i < change.erase; i++) {
      _run(c.key(rust.KeyboardInput(key: 'Backspace', modifiers: 0, kind: 0)));
    }
    if (text.isNotEmpty) {
      if (change.erase == 0 &&
          pending != null &&
          pending.text == text &&
          text.runes.length == 1) {
        _traceInput('consumed');
        _run(c.key(pending));
      } else {
        _traceInput('commit', kind: text.runes.length);
        _run(c.text(text));
      }
    }
    _syncSuggestions();
  }

  @override
  void performAction(TextInputAction action) {
    if (!_focus.hasFocus || _ime.composing) return;
    _snapToBottomForInput();
    _run(c.key(rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0)));
    _ime.reset();
    _connection?.setEditingState(_empty);
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}
  @override
  void connectionClosed() {
    _connection = null;
    _focus.unfocus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.composing = false;
    c.removeListener(_changed);
    _suggestions.dispose();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _searchFocus.dispose();
    _searchField.dispose();
    _connection?.close();
    _pendingTextTimer?.cancel();
    _blinkTimer?.cancel();
    _blink.dispose();
    _preedit.dispose();
    _hoverLink.dispose();
    _cache.dispose();
    super.dispose();
  }
}

/// The route owns this editor until it unmounts, including the exit animation.
/// Only an explicit final text result can be sent to the original session.
class TerminalPastePreview extends StatefulWidget {
  const TerminalPastePreview({
    super.key,
    required this.text,
    required this.target,
    required this.lines,
    required this.bytes,
  });
  final String text, target;
  final int lines, bytes;
  @override
  State<TerminalPastePreview> createState() => _TerminalPastePreviewState();
}

class _TerminalPastePreviewState extends State<TerminalPastePreview> {
  late final editor = TextEditingController(text: widget.text);
  late int _lines = widget.lines, _bytes = widget.bytes;
  @override
  void dispose() {
    editor.clear();
    editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(
      '确认粘贴 · $_lines 行 / $_bytes 字节',
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    content: SizedBox(
      width: 600,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '目标：${widget.target} · 多行内容可能执行多条命令',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          PasteEditor(
            controller: editor,
            onChanged: (text) => setState(() {
              var lines = 1;
              for (var i = 0; i < text.length; i++) {
                if (text.codeUnitAt(i) == 10 ||
                    (text.codeUnitAt(i) == 13 &&
                        (i + 1 == text.length ||
                            text.codeUnitAt(i + 1) != 10))) {
                  lines++;
                }
              }
              _lines = lines;
              _bytes = utf8.encode(text).length;
            }),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('terminal-paste-confirm'),
        onPressed: () {
          if (editor.value.composing.isValid &&
              !editor.value.composing.isCollapsed) {
            return;
          }
          final confirmed = editor.text;
          editor.clear();
          Navigator.pop(context, confirmed);
        },
        child: const Text('发送'),
      ),
    ],
  );
}
