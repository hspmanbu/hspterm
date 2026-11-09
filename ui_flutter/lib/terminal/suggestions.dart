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

  /// -1 means no candidate is selected: the box opens unselected, Enter/Tab
  /// keep their normal shell meaning until the user picks something with the
  /// arrow keys or the mouse.
  int selected = -1;
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
    selected = -1;
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
    final count = view!.choices.length;
    // The first arrow key from an unselected box jumps to the first (down) or
    // last (up) candidate; afterwards movement wraps around as before.
    selected = selected < 0
        ? (step > 0 ? 0 : count - 1)
        : (selected + step) % count;
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
      // A fresh candidate list always starts unselected.
      selected = -1;
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

  /// Round-12 candidate delete: tombstones the exact command behind the
  /// live ticket/index on every host, then refreshes so the deleted row
  /// disappears immediately. Nothing runs and the shell input is untouched.
  Future<bool> deleteCandidate(int index) async {
    final source = view;
    if (!showing ||
        source == null ||
        index < 0 ||
        index >= source.choices.length) {
      return false;
    }
    final gateway = terminal.backend as TerminalSuggestionsBackend;
    final native = terminal.id;
    if (native == null) return false;
    final deleted = await gateway.deleteSuggestion(
      native,
      source.ticket,
      index,
    );
    refresh();
    return deleted;
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
