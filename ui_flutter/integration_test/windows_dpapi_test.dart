import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/workbench/windows_unlock.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows real DPAPI cache is Vault-bound and contains no synthetic master plaintext',
    (tester) async {
      await initializeRust();
      final dir = await Directory.systemTemp.createTemp('hspterm-real-dpapi-');
      final path = '${dir.path}/fixture.vault';
      const master = 'synthetic-real-Windows-DPAPI-master';
      const gateway = NativeWindowsUnlockGateway();
      WindowsUnlockSource? source;
      try {
        await tester.pumpWidget(const MaterialApp(home: SizedBox()));
        await rust.createConfigurationVault(path: path, password: master);
        source = await gateway.source();
        expect(
          await gateway.available(source.token),
          false,
          reason: 'Fixture must not replace an existing cache',
        );
        await gateway.verify(source, master);
        final password = Uint8List.fromList(utf8.encode(master));
        try {
          await gateway.protect(source.token, password);
        } finally {
          password.fillRange(0, password.length, 0);
        }
        expect(await gateway.available(source.token), true);
        final cache = File(
          '${Platform.environment['LOCALAPPDATA']}/HSPTerm/SecureUnlock/${source.token}.dpapi',
        );
        final encrypted = await cache.readAsBytes();
        expect(
          utf8.decode(encrypted, allowMalformed: true),
          isNot(contains(master)),
        );
        await openWindowsProtectedVault(path);
        expect((await gateway.source()).token, source.token);
        await gateway.remove(source.token);
        expect(await gateway.available(source.token), false);
        await expectLater(openWindowsProtectedVault(path), throwsA(anything));
        expect(await File(path).exists(), true);
      } finally {
        if (source != null) await gateway.remove(source.token);
        await tester.pumpWidget(const SizedBox());
        // Rust still owns the last opened database on Windows; process exit
        // releases its handle. Do not force-delete an in-use fixture database.
        if (!Platform.isWindows) await dir.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
