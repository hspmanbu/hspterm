import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// Filesystem paths stay paths until the platform boundary. In particular,
/// Windows shell APIs must never receive file:/// URLs as lpFile.
String normalizeLocalPath(String path, {bool? windows}) {
  final win = windows ?? Platform.isWindows;
  final context = p.Context(style: win ? p.Style.windows : p.Style.posix);
  return context.normalize(context.absolute(path));
}

Uri localFileUri(String path, {bool directory = false, bool? windows}) {
  final win = windows ?? Platform.isWindows;
  final normalized = normalizeLocalPath(path, windows: win);
  return directory
      ? Uri.directory(normalized, windows: win)
      : Uri.file(normalized, windows: win);
}

Future<bool> openLocalUri(Uri uri) async {
  if (Platform.isWindows && uri.scheme == 'file') {
    // url_launcher_windows versions differ in file-URL handling. Use the
    // runner's Unicode filesystem path API for files and directories alike.
    await const MethodChannel('hspterm/prototype_window').invokeMethod<void>(
      'openLocal',
      {'path': normalizeLocalPath(uri.toFilePath(windows: true))},
    );
    return true;
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
