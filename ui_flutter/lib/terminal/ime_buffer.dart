import 'package:flutter/services.dart';

/// The platform owns its text model during composition. Never replace it with
/// an empty model after each notification: Windows TSF can replay that model.
class TerminalImeBuffer {
  static const empty = TextEditingValue(
    text: '\u200b',
    selection: TextSelection.collapsed(offset: 1),
  );
  TextEditingValue value = empty;
  String _sent = '';
  bool get composing => value.composing.isValid && !value.composing.isCollapsed;
  void reset() {
    value = empty;
    _sent = '';
  }

  ({String text, int erase, String preedit}) update(TextEditingValue next) {
    value = next;
    final range = next.composing;
    final active =
        range.isValid && !range.isCollapsed && range.end <= next.text.length;
    final stable = (active ? next.text.substring(0, range.start) : next.text)
        .replaceAll('\u200b', '');
    final preedit = active ? next.text.substring(range.start, range.end) : '';
    // A partially committed phrase may precede the next composing segment.
    // Defer replacement/deletion of already committed text until IME confirms.
    if (active && !stable.startsWith(_sent)) {
      return (text: '', erase: 0, preedit: preedit);
    }
    final old = _sent.runes.toList(), fresh = stable.runes.toList();
    var common = 0;
    while (common < old.length &&
        common < fresh.length &&
        old[common] == fresh[common]) {
      common++;
    }
    final result = (
      text: String.fromCharCodes(fresh.skip(common)),
      erase: old.length - common,
      preedit: preedit,
    );
    _sent = stable;
    return result;
  }
}
