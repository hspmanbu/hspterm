import 'dart:async';

import 'package:flutter/foundation.dart';

import '../src/rust/api.dart' as rust;
import 'backend.dart';
import 'controller.dart';

/// View-owned candidate state, separate from grid painting. Only numeric proof
/// metadata and already-qualified history choices; no log/serialization/export.
class TerminalSuggestionsController extends ChangeNotifier {
  TerminalSuggestionsController(this.terminal) {
    terminal.shellInputChanges.addListener(refresh);
    terminal.addListener(_lifecycle);
  }
  final TerminalController terminal;
  rust.TerminalSuggestions? view;
  int selected = 0;
  bool busy = false;
  bool _wanted = false, _disposed = false, _running = false, _again = false;
  int _epoch = 0;
  Timer? _timer;
  (int, int, int)? _dismissed;
  bool get eligible =>
      !_disposed &&
      _wanted &&
      terminal.connected &&
      terminal.visible &&
      terminal.backend is TerminalSuggestionsBackend;
  bool get showing =>
      eligible && !busy && view != null && view!.choices.isNotEmpty;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _clear() {
    final had = view != null;
    view = null;
    selected = 0;
    if (had) _notify();
  }

  void setWanted(bool value) {
    if (_wanted == value) return;
    _wanted = value;
    if (!value) {
      _epoch++;
      _again = false;
      _timer?.cancel();
      _timer = null;
      _clear();
    } else {
      refresh();
    }
  }

  void _lifecycle() {
    if (!eligible) {
      _epoch++;
      _clear();
    }
  }

  /// Hide the old prefix before forwarding another user key/IME commit. No
  /// additional per-key RPC: native invalidations and one bounded timer merge.
  void inputChanged() {
    _epoch++;
    _clear();
  }

  void dismiss() {
    final current = view;
    if (current != null) {
      _dismissed = (terminal.generation, current.prompt, current.revision);
    }
    _epoch++;
    _clear();
  }

  void move(int step) {
    if (!showing) return;
    selected = (selected + step) % view!.choices.length;
    _notify();
  }

  void refresh() {
    if (!eligible || busy) return;
    _epoch++;
    _again = true;
    _clear();
    if (_running || _timer != null) return;
    _timer = Timer(const Duration(milliseconds: 16), () {
      _timer = null;
      unawaited(_load());
    });
  }

  Future<void> _load() async {
    if (_running || !eligible) return;
    _running = true;
    try {
      _again = false;
      await terminal.flushInput();
      final native = terminal.id,
          generation = terminal.generation,
          epoch = _epoch;
      if (!eligible || native == null) return;
      final gateway = terminal.backend as TerminalSuggestionsBackend;
      final next = await gateway.suggestions(native, generation);
      if (!eligible ||
          native != terminal.id ||
          generation != terminal.generation ||
          epoch != _epoch) {
        return;
      }
      if (next == null ||
          next.choices.isEmpty ||
          _dismissed == (generation, next.prompt, next.revision)) {
        _clear();
        return;
      }
      view = next;
      selected = 0;
      _notify();
    } catch (_) {
      // Optional suggestions fail closed; raw keyboard input still works. Never
      // print an exception which might contain a candidate or input payload.
      _clear();
    } finally {
      _running = false;
      if (_again && eligible && !_disposed) {
        _timer ??= Timer(const Duration(milliseconds: 16), () {
          _timer = null;
          unawaited(_load());
        });
      }
    }
  }

  Future<String> choose({
    required bool execute,
    int? index,
    String? expectedTicket,
  }) async {
    final source = view, choice = index ?? selected;
    if (!showing ||
        source == null ||
        (expectedTicket != null && source.ticket != expectedTicket) ||
        choice < 0 ||
        choice >= source.choices.length) {
      return 'Unavailable';
    }
    final gateway = terminal.backend as TerminalSuggestionsBackend;
    final generation = terminal.generation, native = terminal.id;
    _epoch++;
    busy = true;
    _clear();
    _notify();
    try {
      return await terminal.controlledInput((id, current) {
        if (_disposed || !_wanted || id != native || current != generation) {
          return Future.value('Unavailable');
        }
        return gateway.chooseSuggestion(
          id,
          current,
          source.ticket,
          choice,
          execute,
        );
      });
    } catch (_) {
      return 'Unconfirmed';
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _epoch++;
    _timer?.cancel();
    view = null;
    terminal.shellInputChanges.removeListener(refresh);
    terminal.removeListener(_lifecycle);
    super.dispose();
  }
}
