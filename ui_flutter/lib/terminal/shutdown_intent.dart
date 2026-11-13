/// Transient, bounded keyboard bookkeeping, solely to suppress reconnect after
/// a user-submitted shutdown command. Never a history source, input proof or log.
class ShutdownIntent {
  String _line = '';
  bool _known = true;
  DateTime? _submitted;
  bool get pending =>
      _submitted != null &&
      DateTime.now().difference(_submitted!) < const Duration(minutes: 10);

  void reset() {
    _line = '';
    _known = true;
    _submitted = null;
  }

  void invalidate() {
    _line = '';
    _known = false;
  }

  void cancelLine() {
    _line = '';
    _known = true;
  }

  void text(String text) {
    if (!_known) return;
    if (text.length + _line.length > 512 ||
        text.contains('\n') ||
        text.contains('\r') ||
        text.runes.any((v) => v < 32 || v == 127)) {
      invalidate();
      return;
    }
    _line += text;
  }

  void backspace() {
    if (_known && _line.isNotEmpty) {
      _line = String.fromCharCodes(_line.runes.toList()..removeLast());
    }
  }

  void enter() {
    if (_known) {
      final command = _line.trim().split(RegExp(r'\s+'));
      if (_isPowerCommand(command)) _submitted = DateTime.now();
      if (_isShutdownCancellation(command)) _submitted = null;
    }
    cancelLine();
  }

  static List<String> _withoutPrivilege(List<String> words) {
    var result = words;
    if (result.isNotEmpty && ['sudo', 'doas'].contains(result.first)) {
      result = result.skip(1).toList();
      while (result.isNotEmpty &&
          ['-n', '-H', '-E', '--'].contains(result.first)) {
        result = result.skip(1).toList();
      }
    }
    return result;
  }

  static String _program(String word) {
    const prefixes = ['/sbin/', '/bin/', '/usr/sbin/', '/usr/bin/'];
    for (final prefix in prefixes) {
      if (word.startsWith(prefix)) return word.substring(prefix.length);
    }
    return word;
  }

  static bool _isPowerCommand(List<String> words) {
    final w = _withoutPrivilege(words);
    if (w.isEmpty ||
        w.any((v) => !RegExp(r'^[a-zA-Z0-9_+:/=-]+$').hasMatch(v))) {
      return false;
    }
    final args = w.skip(1).toList();
    final program = _program(w.first);
    if (['reboot', 'poweroff', 'halt'].contains(program)) {
      return args.every(
        (v) => [
          '-f',
          '--force',
          '-n',
          '--no-sync',
          '-p',
          '--poweroff',
          '--reboot',
          '--halt',
        ].contains(v),
      );
    }
    if (program == 'systemctl') {
      return args.isNotEmpty &&
          ['reboot', 'poweroff', 'halt'].contains(args.first) &&
          args
              .skip(1)
              .every((v) => ['--force', '--no-wall', '--no-block'].contains(v));
    }
    if (program == 'shutdown') {
      return args.isEmpty ||
          args.every(
            (v) =>
                [
                  '-r',
                  '-h',
                  '-H',
                  '-P',
                  '--reboot',
                  '--halt',
                  '--poweroff',
                  '--no-wall',
                  'now',
                ].contains(v) ||
                RegExp(r'^\+?[0-9]+(?::[0-9]{2})?$').hasMatch(v),
          );
    }
    if (program == 'init' || program == 'telinit') {
      return args.length == 1 && ['0', '6'].contains(args.first);
    }
    return false;
  }

  static bool _isShutdownCancellation(List<String> words) {
    final w = _withoutPrivilege(words);
    return w.length == 2 &&
        _program(w.first) == 'shutdown' &&
        ['-c', '--cancel'].contains(w.last);
  }
}
