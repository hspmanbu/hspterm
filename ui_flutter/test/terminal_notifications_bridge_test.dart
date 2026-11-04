import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hspterm/prototype/model.dart';
import 'package:hspterm/src/rust/api.dart' as rust;
import 'package:hspterm/terminal/backend.dart';
import 'package:hspterm/terminal/notifications.dart';
import 'package:hspterm/workbench/model.dart';

import 'native_bridge_test.dart' show waitFor, screen;
import 'support/local_sshd.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initializeRust);
  test('hidden real SSH emits bounded redacted OSC/quiet notices, SFTP does not, disable changes the live policy without reconnect', () async {
    final ssh = await LocalSshd.start();
    final model = LiveWorkbenchModel();
    try {
      await rust.createConfigurationVault(
        path: '${ssh.directory.path}/notices.vault',
        password: 'synthetic-notification-master',
      );
      await model.load();
      model.confirmHostKey = (_, _) async => true;
      final host = await model.persistHost(
        DemoHost(
          model.nextId(),
          'Notification fixture',
          '127.0.0.1',
          '未分组',
          user: ssh.username,
          port: ssh.port,
          auth: '私钥',
          openSftp: false,
        ),
        secret: ssh.privateKey,
        passphrase: 'test-only-passphrase',
      );
      model.openHost(host);
      final session = model.focus! as LiveTerminalSession;
      final c = session.controller;
      await waitFor(
        () => c.connected || c.phase == 'Failed',
        'notification fixture SSH',
      );
      expect(c.connected, true, reason: c.error);
      expect(c.visible, false);
      final id = c.id, generation = c.generation, frames = c.frameCount;
      final source = jsonDecode(
        await rust.loadTerminalPreferences(),
      ) as Map<String, dynamic>;
      final values = Map<String, dynamic>.from(
        source['value'] as Map<String, dynamic>,
      );
      values['notifications'] = const TerminalNotificationSettings(
        quietSeconds: 5,
      ).toJson();
      await rust.saveTerminalPreferences(
        proposal: jsonEncode({
          'vault_scope': source['vault_scope'],
          'revision': source['revision'],
          'value': values,
        }),
      );
      final received = <RemoteTerminalNotice>[];
      c.notices.addListener(() {
        if (c.notices.value != null) received.add(c.notices.value!);
      });
      await c.text(
        r"printf '\033]777;notify;synthetic title;synthetic private body\007'",
      );
      await c.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => received.any((n) => n.kind == 'osc'),
        'hidden OSC notification',
      );
      expect(received.firstWhere((n) => n.kind == 'osc').body, isEmpty);
      await waitFor(
        () => received.any((n) => n.kind == 'quiet'),
        'one-shot actual quiet timer',
      );
      expect(
        c.frameCount,
        frames,
        reason: 'notifications must not fetch hidden frames',
      );
      final count = received.length;
      await model.loadDirectory(session, '.');
      expect(
        received.length,
        count,
        reason: 'SFTP is not a notification source',
      );
      final beforeDisable = c.notificationPolicy;
      final current = jsonDecode(
        await rust.loadTerminalPreferences(),
      ) as Map<String, dynamic>;
      final disabled = Map<String, dynamic>.from(
        current['value'] as Map<String, dynamic>,
      );
      disabled['notifications'] = const TerminalNotificationSettings(
        enabled: false,
      ).toJson();
      await rust.saveTerminalPreferences(
        proposal: jsonEncode({
          'vault_scope': current['vault_scope'],
          'revision': current['revision'],
          'value': disabled,
        }),
      );
      await waitFor(
        () => c.notificationPolicy != beforeDisable,
        'retired live notification policy',
      );
      await c.setVisible(true);
      await c.text(
        r"printf '\033]9;disabled remote message\007'; printf '%s%s\n' NOTICES_ DISABLED_ACK",
      );
      await c.key(
        const rust.KeyboardInput(key: 'Enter', modifiers: 0, kind: 0),
      );
      await waitFor(
        () => screen(c).contains('NOTICES_DISABLED_ACK'),
        'processed disabled notice batch',
      );
      expect(received.length, count);
      expect(c.id, id);
      expect(c.generation, generation);
      expect(c.connected, true);
    } finally {
      await model.shutdown();
      model.dispose();
      await ssh.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
