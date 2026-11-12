import 'dart:io';

import 'remote_reference.dart';

import '../src/rust/api.dart' show RenderCell, RenderHyperlink;

/// Display-only recognition; never resolves DNS, probes or accesses a URL.
class TerminalLink {
  const TerminalLink(
    this.text,
    this.address,
    this.port,
    this.uri, {
    this.remoteFileUri,
    this.remotePath,
  });
  final String text, address;
  final int? port;
  final Uri? uri;

  /// Kept outside browser/forwarding URI fields. Native validates the original
  /// SSH endpoint before resolving this into its associated remote SFTP path.
  final String? remoteFileUri;
  final RemotePathReference? remotePath;
  bool get loopback =>
      address.toLowerCase() == 'localhost' ||
      (InternetAddress.tryParse(address)?.isLoopback ?? false);
  bool get canForward => loopback && port != null;
  static TerminalLink? parse(String text) {
    try {
      if (text.isEmpty ||
          text.length > 4096 ||
          RegExp(
            r'[\s\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]',
          ).hasMatch(text)) {
        return null;
      }
      final ip = InternetAddress.tryParse(text);
      if (ip != null) return TerminalLink(text, ip.address, null, null);
      final uri = Uri.tryParse(text);
      if (uri != null && uri.scheme == 'file') {
        if (!text.toLowerCase().startsWith('file://') ||
            !uri.path.startsWith('/') ||
            uri.userInfo.isNotEmpty ||
            uri.hasPort ||
            uri.hasQuery ||
            uri.hasFragment) {
          return null;
        }
        return TerminalLink(text, '', null, null, remoteFileUri: text);
      }
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        if (uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
          return null;
        }
        return TerminalLink(
          text,
          uri.host.replaceAll(RegExp(r'^\[|\]$'), ''),
          uri.port,
          uri,
        );
      }
      final recognized = RemotePathReference.recognize(text);
      final path =
          recognized != null &&
              InternetAddress.tryParse(recognized.path) == null &&
              recognized.path.toLowerCase() != 'localhost'
          ? recognized
          : null;
      TerminalLink? pathOnly() => path == null
          ? null
          : TerminalLink(text, '', null, null, remotePath: path);
      // Scheme-free host:port or [IPv6]:port. Never guess a URL scheme.
      final endpoint = Uri.tryParse('tcp://$text');
      if (endpoint == null ||
          !endpoint.hasPort ||
          endpoint.path.isNotEmpty ||
          endpoint.userInfo.isNotEmpty ||
          endpoint.hasQuery ||
          endpoint.hasFragment ||
          endpoint.port < 1 ||
          endpoint.port > 65535) {
        return pathOnly();
      }
      final host = endpoint.host.replaceAll(RegExp(r'^\[|\]$'), '');
      if (host.isEmpty ||
          (InternetAddress.tryParse(host) == null &&
              !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,252}$').hasMatch(host))) {
        return pathOnly();
      }
      return TerminalLink(text, host, endpoint.port, null, remotePath: path);
    } on FormatException {
      return null;
    }
  }

  /// Maps UTF-16 token positions back to terminal cells; combining text and a
  /// wide-character spacer never shift subsequent URLs by a screen column.
  static TerminalLink? atGrid(
    List<List<RenderCell>> rows,
    int row,
    int column, {
    List<List<RenderHyperlink>>? hyperlinks,
  }) {
    if (row < 0 ||
        row >= rows.length ||
        column < 0 ||
        column >= rows[row].length) {
      return null;
    }
    if (rows[row][column].flags & 256 != 0) return null;
    if (hyperlinks != null && row < hyperlinks.length) {
      for (final span in hyperlinks[row]) {
        if (column < span.start || column >= span.end) continue;
        final value = span.uri;
        // Explicit OSC 8 always wins over auto-detected label text. Unsafe or
        // truncated targets must not silently activate a different label URL.
        if (span.start < 0 || span.end > rows[row].length || value == null) {
          return null;
        }
        final parsed = parse(value);
        if (parsed?.uri != null || parsed?.remoteFileUri != null) return parsed;
        // Salvage a prose annotation only when the visible token is the SAME
        // literal absolute path. Unsafe schemes never activate a label URL.
        final annotation = RegExp(r'^[^:/\\\s\x00-\x1f]{1,40}: +(/[^\s]+)$')
            .firstMatch(value);
        final path = annotation == null ? null : parse(annotation[1]!);
        if (path?.remotePath == null) return null;
        final label = atGrid(rows, row, column);
        return label?.remotePath?.path == path!.remotePath!.path ? label : null;
      }
    }
    bool wraps(int index) => rows[index].any((c) => c.flags & 16 != 0);
    bool delimiter(RenderCell c) =>
        c.flags & (64 | 1024) == 0 &&
        (c.text.isEmpty || RegExp(r'''[\s<>'"`]''').hasMatch(c.text));
    var start = row, end = row;
    while (start > 0 && wraps(start - 1)) {
      if (rows[start]
          .take(start == row ? column + 1 : rows[start].length)
          .any(delimiter)) {
        break;
      }
      if (row - start >= 15) return null;
      start--;
    }
    while (wraps(end)) {
      if (rows[end].skip(end == row ? column : 0).any(delimiter)) break;
      if (end + 1 >= rows.length || end - start >= 15) return null;
      end++;
    }
    if (start == end) return at(rows[row], column);
    final merged = <RenderCell>[];
    var offset = column;
    for (var i = start; i <= end; i++) {
      if (i < row) offset += rows[i].length;
      if (merged.length + rows[i].length > 4096) return null;
      merged.addAll(rows[i]);
    }
    return at(merged, offset);
  }

  static TerminalLink? at(List<RenderCell> row, int column) {
    if (column < 0 || column >= row.length || row.length > 4096) return null;
    // Concealed terminal text must not leak through hover or link actions.
    if (row.any((cell) => cell.flags & 256 != 0)) return null;
    final text = StringBuffer();
    final starts = <int>[];
    var offset = 0;
    for (final cell in row) {
      starts.add(offset);
      final value = cell.flags & (64 | 1024) != 0 ? '' : cell.text;
      if (offset + value.length > 16384) return null;
      text.write(value);
      offset += value.length;
    }
    final line = text.toString();
    final hit = starts[column];
    for (final match in RegExp(r'''[^\s<>'"`]+''').allMatches(line)) {
      if (hit < match.start || hit >= match.end) continue;
      var token = match.group(0)!;
      final fileToken = token.toLowerCase().startsWith('file://');
      if (fileToken) {
        // Do not turn the prefix before a quote/prose delimiter into a
        // different valid filename. Complex names can use OSC8 or selection.
        bool delimiter(int i) =>
            i >= 0 && i < line.length && '''<>'"`'''.contains(line[i]);
        if (delimiter(match.start - 1) || delimiter(match.end)) {
          return null;
        }
        return parse(token);
      }
      final rawPath = RemotePathReference.recognize(token);
      if (rawPath != null) {
        bool quoted(int i) =>
            i >= 0 && i < line.length && "<>'\"`".contains(line[i]);
        if (quoted(match.start - 1) || quoted(match.end)) return null;
        return parse(token);
      }
      while (token.isNotEmpty && '.,;!?'.contains(token[token.length - 1])) {
        token = token.substring(0, token.length - 1);
      }
      // Remove only unbalanced surrounding prose delimiters.
      while (token.startsWith('(')) {
        token = token.substring(1);
      }
      while (token.endsWith(')') &&
          ')'.allMatches(token).length > '('.allMatches(token).length) {
        token = token.substring(0, token.length - 1);
      }
      if (token.toLowerCase().startsWith('file://')) return null;
      final parsed = parse(token);
      // Prose stripping is URL-only; never turn a changed token into a file.
      return parsed?.remotePath == null ? parsed : null;
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is TerminalLink && other.text == text;
  @override
  int get hashCode => text.hashCode;
}
