/// Passive display recognition only. The Rust path resolver remains the
/// authority for the original SSH target/OSC7 CWD and literal POSIX semantics.
/// No filesystem, DNS, remote probes, shell expansion or input injection.
class RemotePathReference {
  const RemotePathReference(this.text, this.path, this.line, this.column);
  final String text, path;
  final int? line, column;
  bool get hasLocation => line != null;
  bool get requiresChoice => hasLocation || !path.contains('/');

  static final _unsafe = RegExp(
    r'''[\s\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069<>'"`\\]''',
  );
  static final _pathStart = RegExp(r'^[/.a-zA-Z0-9_\u0080-\uffff]');
  static final _location = RegExp(
    r'^(.*?):([1-9][0-9]{0,8})(?::([1-9][0-9]{0,8}))?:?$',
  );
  static RemotePathReference? recognize(String text) {
    if (text.isEmpty ||
        text.length > 4096 ||
        _unsafe.hasMatch(text) ||
        text.contains('://')) {
      return null;
    }
    var path = text;
    int? line, column;
    final match = _location.firstMatch(text);
    if (match != null) {
      path = match[1]!;
      line = int.parse(match[2]!);
      column = match[3] == null ? null : int.parse(match[3]!);
    }
    if (path.isEmpty ||
        path == '/' ||
        path.contains(':') ||
        !_pathStart.hasMatch(path) ||
        path.startsWith('//') ||
        path == '.' ||
        path == '..') {
      return null;
    }
    final explicit =
        path.startsWith('/') || path.startsWith('./') || path.startsWith('../');
    final slash = path.contains('/');
    final filename = path.contains('.') && !path.endsWith('.') && path != '...';
    if (!explicit && !slash && !filename) return null;
    // Do not remove terminal punctuation/quotes. They may be legal filename
    // bytes; ambiguous locations are presented with a literal-text alternative.
    return RemotePathReference(text, path, line, column);
  }
}
