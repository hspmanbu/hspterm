import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/terminal/ime_buffer.dart';

void main() {
  test('Windows composing snapshots and repeated commits send Chinese exactly once', () {
    final input = TerminalImeBuffer();
    final sent = StringBuffer();
    for (final text in ['n', 'ni', "ni'h", "ni'ha", "ni'hao"]) {
      final delta = input.update(
        TextEditingValue(
          text: '\u200b$text',
          composing: TextRange(start: 1, end: text.length + 1),
        ),
      );
      expect(delta.erase, 0);
      expect(delta.text, '');
    }
    for (var i = 0; i < 4; i++) {
      final delta = input.update(
        const TextEditingValue(
          text: '\u200b你好',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      sent.write(delta.text);
      expect(delta.erase, 0);
    }
    expect(sent.toString(), '你好');
    final next = input.update(const TextEditingValue(text: '\u200b你好世界'));
    expect(next.text, '世界');
    expect(next.erase, 0);
  });
  test('ASCII snapshots, surrogate pairs, deletion and next input epoch are incremental', () {
    final input = TerminalImeBuffer();
    expect(input.update(const TextEditingValue(text: '\u200ba')).text, 'a');
    expect(input.update(const TextEditingValue(text: '\u200bab')).text, 'b');
    expect(input.update(const TextEditingValue(text: '\u200bab😀')).text, '😀');
    final erase = input.update(const TextEditingValue(text: '\u200bab'));
    expect(erase.erase, 1);
    expect(erase.text, '');
    input.reset();
    expect(input.update(const TextEditingValue(text: '\u200ba')).text, 'a');
  });
  test('partial phrase commits do not send the composing tail', () {
    final input = TerminalImeBuffer();
    final first = input.update(
      const TextEditingValue(
        text: '\u200b你好shi',
        composing: TextRange(start: 3, end: 6),
      ),
    );
    expect(first.text, '你好');
    expect(first.preedit, 'shi');
    expect(input.update(const TextEditingValue(text: '\u200b你好世界')).text, '世界');
  });
}
