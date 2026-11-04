import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/windows_unlock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('real Vault tokens are stable and guarded open never creates, overwrites or redirects a Vault', () async {
    final dir = await Directory.systemTemp.createTemp(
      'hspterm-unlock-identity-',
    );
    final first = '${dir.path}/first.vault',
        other = '${dir.path}/other.vault',
        missing = '${dir.path}/missing.vault';
    const master = 'synthetic-windows-unlock-master';
    try {
      await rust.createConfigurationVault(path: first, password: master);
      final a = WindowsUnlockSource.decode(await rust.secureUnlockSource());
      expect(await rust.vaultUnlockHint(path: first), a.token);
      await expectLater(
        rust.createConfigurationVault(path: first, password: master),
        throwsA(anything),
      );
      expect(
        WindowsUnlockSource.decode(await rust.secureUnlockSource()).scope,
        a.scope,
      );
      await rust.createConfigurationVault(path: other, password: master);
      final b = WindowsUnlockSource.decode(await rust.secureUnlockSource());
      expect(b.token, isNot(a.token));
      await expectLater(
        rust.unlockExistingVault(path: first, password: master, token: b.token),
        throwsA(anything),
      );
      expect(
        WindowsUnlockSource.decode(await rust.secureUnlockSource()).scope,
        b.scope,
      );
      await expectLater(
        rust.unlockExistingVault(
          path: missing,
          password: master,
          token: a.token,
        ),
        throwsA(anything),
      );
      expect(await File(missing).exists(), false);
      await rust.unlockExistingVault(
        path: first,
        password: master,
        token: a.token,
      );
      final reopened = WindowsUnlockSource.decode(
        await rust.secureUnlockSource(),
      );
      expect(reopened.token, a.token);
      expect(reopened.scope, isNot(a.scope));
      await expectLater(
        rust.verifySecureUnlock(
          vaultScope: a.scope,
          token: a.token,
          password: master,
        ),
        throwsA(anything),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isLinux);
  test('mock Windows channel plus real core opens the original existing library without saving plaintext', () async {
    final dir = await Directory.systemTemp.createTemp(
      'hspterm-unlock-channel-',
    );
    final path = '${dir.path}/fixture.vault';
    const master = 'synthetic-protected-channel-master';
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await rust.createConfigurationVault(path: path, password: master);
      final source = WindowsUnlockSource.decode(
        await rust.secureUnlockSource(),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowsUnlockChannel, (call) async {
            expect(call.method, 'unprotect');
            expect((call.arguments as Map)['token'], source.token);
            return Uint8List.fromList(utf8.encode(master));
          });
      await openWindowsProtectedVault(path);
      final opened = WindowsUnlockSource.decode(
        await rust.secureUnlockSource(),
      );
      expect(opened.token, source.token);
      expect(opened.scope, isNot(source.scope));
      expect(
        utf8.decode(await File(path).readAsBytes(), allowMalformed: true),
        isNot(contains(master)),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowsUnlockChannel, null);
      await dir.delete(recursive: true);
    }
  }, skip: !Platform.isLinux);
}
