import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';

void main() {
  setUpAll(initializeRust);
  test('native settings acknowledge only encrypted metadata and reject an old reopened Vault proposal', () async {
    final root = await Directory.systemTemp.createTemp(
      'hspterm-sync-settings-fixture-',
    );
    try {
      final path = '${root.path}/config.vault';
      await rust.unlockVault(
        path: path,
        password: 'synthetic-sync-settings-master',
      );
      final before = jsonDecode(
        await rust.loadConfigurationSyncSettings(),
      ) as Map<String, dynamic>;
      expect(before['target'], isNull);
      final proposal = {
        'vault_scope': before['vault_scope'],
        'revision': before['revision'],
        'target': {
          'enabled': true,
          'endpoint': 'https://private-fixture.invalid/object',
          'collection': '0123456789abcdef0123456789abcdef',
          'authenticate': false,
          'timeout_seconds': 60,
          'proxy': null,
        },
        'secrets': {
          'sync_password': 'synthetic-native-sync-password',
          'webdav': {'action': 'remove'},
          'proxy': {'action': 'remove'},
        },
        'confirm_target_change': false,
      };
      final saved = await rust.saveConfigurationSyncSettings(
        proposal: jsonEncode(proposal),
      );
      expect(saved.contains('synthetic-native-sync-password'), isFalse);
      expect(jsonDecode(saved)['sync_password_set'], isTrue);
      final summary = await rust.configurationBackupSummary();
      expect(summary.contains('local-cloud-sync-'), isFalse);
      final bytes = await File(path).readAsBytes();
      expect(
        latin1.decode(bytes).contains('synthetic-native-sync-password'),
        isFalse,
      );
      await rust.unlockVault(
        path: path,
        password: 'synthetic-sync-settings-master',
      );
      await expectLater(
        rust.saveConfigurationSyncSettings(proposal: jsonEncode(proposal)),
        throwsA(anything),
      );
      expect(
        jsonDecode(
          await rust.loadConfigurationSyncSettings(),
        )['sync_password_set'],
        isTrue,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}
