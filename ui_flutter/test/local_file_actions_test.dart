import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/workbench/local_file_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Windows paths normalize once and round-trip without URL or double-slash leakage', () {
    for (final input in [
      r'D://dislike.txt',
      r'D:\dislike.txt',
      'D:/dislike.txt',
    ]) {
      final uri = localFileUri(input, windows: true);
      expect(uri.toString(), 'file:///D:/dislike.txt');
      expect(uri.toFilePath(windows: true), r'D:\dislike.txt');
    }
    final unicode = localFileUri('D:/临时目录/a #%.txt', windows: true);
    expect(unicode.toFilePath(windows: true), r'D:\临时目录\a #%.txt');
    final unc = localFileUri(r'\\server\share\a.txt', windows: true);
    expect(unc.host, 'server');
    expect(unc.toFilePath(windows: true), r'\\server\share\a.txt');
  });
  test('Windows opening uses a filesystem path, never file:/// as ShellExecute lpFile', () async {
    if (!Platform.isWindows) {
      return;
    } // Native path routing is tested on Windows CI.
    MethodCall? received;
    const channel = MethodChannel('hspterm/prototype_window');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return null;
        });
    try {
      expect(await openLocalUri(localFileUri('D://dislike.txt')), isTrue);
      expect(received!.method, 'openLocal');
      expect(received!.arguments, {'path': r'D:\dislike.txt'});
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
}
